unit LCLDiagServer;
{
  LCL Diagnostic Socket Server
  Provides a localhost TCP server that exposes the live LCL control tree,
  a circular event ring buffer (hooked into DebugLn), and per-control
  diagnostic state. Gated behind {$IFDEF ENABLE_LCL_SOCKET_DIAG}.

  When the define is off, this unit compiles to two empty procedures.
}

{$mode objfpc}{$H+}

interface

{$IFDEF ENABLE_LCL_SOCKET_DIAG}

uses
  Classes, SysUtils, ssockets;

type
  TLCLDiagEvent = record
    SeqNo: QWord;
    Timestamp: TDateTime;
    Text: string;
  end;

  { TLCLEventRing - Thread-safe circular buffer of diagnostic events }

  TLCLEventRing = class
  private
    FBuffer: array of TLCLDiagEvent;
    FCapacity: Integer;
    FHead: Integer;
    FCount: Integer;
    FNextSeq: QWord;
    FLock: TRTLCriticalSection;
  public
    constructor Create(ACapacity: Integer);
    destructor Destroy; override;
    procedure Push(const AText: string);
    function QueryJSON(ASinceSeq: QWord; AMax: Integer): string;
    function StatsJSON: string;
    property Capacity: Integer read FCapacity;
    property Count: Integer read FCount;
    property NextSeq: QWord read FNextSeq;
  end;

  { TLCLDiagServer - Localhost TCP server for diagnostic queries }

  TLCLDiagServer = class(TThread)
  private
    FPort: Integer;
    FInetServer: TInetServer;
    FReady: PRTLEvent;
    procedure DoConnect(Sender: TObject; Data: TSocketStream);
  protected
    procedure Execute; override;
  public
    constructor Create(APort: Integer);
    destructor Destroy; override;
    procedure WaitReady;
    procedure StopListening;
    property Port: Integer read FPort;
  end;

{ JSON helper functions (used by tests) }
function JSONEscape(const S: string): string;
function JStr(const AKey, AValue: string): string; inline;
function JInt(const AKey: string; AValue: Int64): string; inline;
function JBool(const AKey: string; AValue: Boolean): string; inline;
function ExtractJStr(const AJSON, AKey: string): string;
function ExtractJInt(const AJSON, AKey: string): Int64;
function ExtractJBool(const AJSON, AKey: string): Boolean;

var
  DiagRing: TLCLEventRing;

{$ENDIF}

procedure LCLDiagStartServer;
procedure LCLDiagStopServer;

implementation

{$IFDEF ENABLE_LCL_SOCKET_DIAG}

uses
  Sockets, DateUtils,
  Forms, Controls, LCLClasses,
  LazLoggerBase, LazLogger;

{ ===== JSON helpers ========================================================= }

function JSONEscape(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if S[I] < #32 then
        Result := Result + '\u' + IntToHex(Ord(S[I]), 4)
      else
        Result := Result + S[I];
    end;
end;

function JStr(const AKey, AValue: string): string; inline;
begin
  Result := '"' + AKey + '":"' + JSONEscape(AValue) + '"';
end;

function JInt(const AKey: string; AValue: Int64): string; inline;
begin
  Result := '"' + AKey + '":' + IntToStr(AValue);
end;

function JBool(const AKey: string; AValue: Boolean): string; inline;
const
  BoolStr: array[Boolean] of string = ('false', 'true');
begin
  Result := '"' + AKey + '":' + BoolStr[AValue];
end;

function ExtractJStr(const AJSON, AKey: string): string;
var
  P, Q: Integer;
  K: string;
begin
  Result := '';
  K := '"' + AKey + '"';
  P := Pos(K, AJSON);
  if P = 0 then Exit;
  P := P + Length(K);
  while (P <= Length(AJSON)) and (AJSON[P] in [' ', ':', #9]) do Inc(P);
  if (P > Length(AJSON)) or (AJSON[P] <> '"') then Exit;
  Inc(P);
  Q := P;
  while (Q <= Length(AJSON)) and (AJSON[Q] <> '"') do begin
    if AJSON[Q] = '\' then Inc(Q);
    Inc(Q);
  end;
  Result := Copy(AJSON, P, Q - P);
end;

function ExtractJInt(const AJSON, AKey: string): Int64;
var
  P: Integer;
  K, Num: string;
begin
  Result := 0;
  K := '"' + AKey + '"';
  P := Pos(K, AJSON);
  if P = 0 then Exit;
  P := P + Length(K);
  while (P <= Length(AJSON)) and (AJSON[P] in [' ', ':', #9]) do Inc(P);
  Num := '';
  while (P <= Length(AJSON)) and (AJSON[P] in ['0'..'9', '-']) do begin
    Num := Num + AJSON[P];
    Inc(P);
  end;
  if Num <> '' then Result := StrToInt64Def(Num, 0);
end;

function ExtractJBool(const AJSON, AKey: string): Boolean;
var
  P: Integer;
  K: string;
begin
  Result := False;
  K := '"' + AKey + '"';
  P := Pos(K, AJSON);
  if P = 0 then Exit;
  P := P + Length(K);
  while (P <= Length(AJSON)) and (AJSON[P] in [' ', ':', #9]) do Inc(P);
  Result := (P <= Length(AJSON)) and (AJSON[P] = 't');
end;

{ ===== Ring Buffer ========================================================== }

constructor TLCLEventRing.Create(ACapacity: Integer);
begin
  inherited Create;
  FCapacity := ACapacity;
  SetLength(FBuffer, FCapacity);
  FHead := 0;
  FCount := 0;
  FNextSeq := 1;
  InitCriticalSection(FLock);
end;

destructor TLCLEventRing.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited;
end;

procedure TLCLEventRing.Push(const AText: string);
begin
  EnterCriticalSection(FLock);
  try
    FBuffer[FHead].SeqNo := FNextSeq;
    FBuffer[FHead].Timestamp := Now;
    FBuffer[FHead].Text := AText;
    Inc(FNextSeq);
    FHead := (FHead + 1) mod FCapacity;
    if FCount < FCapacity then Inc(FCount);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLCLEventRing.QueryJSON(ASinceSeq: QWord; AMax: Integer): string;
var
  I, Start, N, ItemCount: Integer;
  E: TLCLDiagEvent;
  Items: string;
begin
  Items := '';
  ItemCount := 0;
  EnterCriticalSection(FLock);
  try
    if FCount = 0 then begin
      Result := '{"count":0,"events":[]}';
      Exit;
    end;
    Start := (FHead - FCount + FCapacity) mod FCapacity;
    N := FCount;
    for I := 0 to N - 1 do begin
      E := FBuffer[(Start + I) mod FCapacity];
      if E.SeqNo <= ASinceSeq then Continue;
      if ItemCount > 0 then Items := Items + ',';
      Items := Items + '{' +
        JInt('seq', E.SeqNo) + ',' +
        JStr('ts', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', E.Timestamp)) + ',' +
        JStr('text', E.Text) + '}';
      Inc(ItemCount);
      if (AMax > 0) and (ItemCount >= AMax) then Break;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  Result := '{"count":' + IntToStr(ItemCount) + ',"events":[' + Items + ']}';
end;

function TLCLEventRing.StatsJSON: string;
var
  OldestSeq: QWord;
begin
  EnterCriticalSection(FLock);
  try
    if FCount > 0 then
      OldestSeq := FBuffer[(FHead - FCount + FCapacity) mod FCapacity].SeqNo
    else
      OldestSeq := 0;
    Result := '{' +
      JInt('total_pushed', Int64(FNextSeq) - 1) + ',' +
      JInt('buffer_capacity', FCapacity) + ',' +
      JInt('buffer_used', FCount) + ',' +
      JInt('oldest_seq', Int64(OldestSeq)) + ',' +
      JInt('newest_seq', Int64(FNextSeq) - 1) + '}';
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ ===== Control Tree Walking ================================================= }

function ControlToJSON(AControl: TControl; ADepth, AMaxDepth: Integer): string;
  forward;

function ChildrenJSON(AWC: TWinControl; ADepth, AMaxDepth: Integer): string;
var
  I: Integer;
begin
  Result := '';
  if ADepth >= AMaxDepth then Exit;
  try
    for I := 0 to AWC.ControlCount - 1 do begin
      if AWC.Controls[I] = nil then Continue;
      if Result <> '' then Result := Result + ',';
      Result := Result + ControlToJSON(AWC.Controls[I], ADepth + 1, AMaxDepth);
    end;
  except
  end;
end;

function ControlToJSON(AControl: TControl; ADepth, AMaxDepth: Integer): string;
var
  Kids: string;
begin
  try
    Result := '{' +
      JStr('class', AControl.ClassName) + ',' +
      JStr('name', AControl.Name) + ',' +
      JBool('visible', AControl.Visible) + ',' +
      JBool('debugLogging', AControl.DebugLogging) + ',' +
      JInt('left', AControl.Left) + ',' +
      JInt('top', AControl.Top) + ',' +
      JInt('width', AControl.Width) + ',' +
      JInt('height', AControl.Height) + ',' +
      JInt('autoSizeLock', AControl.AutoSizingLockCount);

    if AControl is TWinControl then begin
      Result := Result + ',' +
        JBool('handleAllocated', TWinControl(AControl).HandleAllocated) + ',' +
        JBool('showing', TWinControl(AControl).Showing) + ',' +
        JInt('controlCount', TWinControl(AControl).ControlCount);
      Kids := ChildrenJSON(TWinControl(AControl), ADepth, AMaxDepth);
      if Kids <> '' then
        Result := Result + ',"children":[' + Kids + ']';
    end;

    Result := Result + '}';
  except
    on E: Exception do
      Result := '{' + JStr('error', E.Message) + '}';
  end;
end;

function BuildTreeJSON(AMaxDepth: Integer): string;
var
  I: Integer;
  Items: string;
begin
  Items := '';
  try
    if Screen = nil then begin
      Result := '{' + JStr('error', 'Screen not available') + '}';
      Exit;
    end;
    for I := 0 to Screen.CustomFormCount - 1 do begin
      if Items <> '' then Items := Items + ',';
      Items := Items + ControlToJSON(Screen.CustomForms[I], 0, AMaxDepth);
    end;
    Result := '{' +
      JInt('formCount', Screen.CustomFormCount) + ',' +
      '"forms":[' + Items + ']}';
  except
    on E: Exception do
      Result := '{' + JStr('error', E.Message) + '}';
  end;
end;

function FindControlByPath(const APath: string): TControl;
var
  Parts: TStringList;
  I, J: Integer;
  Current: TWinControl;
  Found: Boolean;
begin
  Result := nil;
  if (APath = '') or (Screen = nil) then Exit;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '/';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := APath;
    if Parts.Count = 0 then Exit;

    Current := nil;
    for I := 0 to Screen.CustomFormCount - 1 do
      if Screen.CustomForms[I].Name = Parts[0] then begin
        Current := Screen.CustomForms[I];
        Break;
      end;
    if Current = nil then Exit;
    if Parts.Count = 1 then begin Result := Current; Exit; end;

    for I := 1 to Parts.Count - 1 do begin
      Found := False;
      for J := 0 to Current.ControlCount - 1 do begin
        if Current.Controls[J].Name = Parts[I] then begin
          if I = Parts.Count - 1 then begin
            Result := Current.Controls[J];
            Exit;
          end;
          if Current.Controls[J] is TWinControl then
            Current := TWinControl(Current.Controls[J])
          else
            Exit;
          Found := True;
          Break;
        end;
      end;
      if not Found then Exit;
    end;
    Result := Current;
  finally
    Parts.Free;
  end;
end;

function BuildPropsJSON(const APath: string): string;
var
  C: TControl;
begin
  C := FindControlByPath(APath);
  if C = nil then begin
    Result := '{' + JStr('error', 'control not found: ' + APath) + '}';
    Exit;
  end;
  Result := ControlToJSON(C, 0, 1);
end;

{ ===== Connection Handler =================================================== }

type
  TLCLDiagConnection = class(TThread)
  private
    FStream: TSocketStream;
    FServer: TLCLDiagServer;
    procedure HandleLine(const ALine: string; out AResponse: string);
    procedure SendStr(const S: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AStream: TSocketStream; AServer: TLCLDiagServer);
  end;

  { Hook object — TLazLoggerWriteEvent is 'of object', so we need an instance }
  TDiagDebugLnHook = class
  private
    FPrev: TLazLoggerWriteEvent;
  public
    procedure OnDebugLn(Sender: TObject; S: string; var Handled: Boolean);
  end;

var
  DiagServer: TLCLDiagServer;
  DiagHook: TDiagDebugLnHook;

{ ---- TDiagDebugLnHook ---- }

procedure TDiagDebugLnHook.OnDebugLn(Sender: TObject; S: string;
  var Handled: Boolean);
begin
  if DiagRing <> nil then
    DiagRing.Push(S);
  if Assigned(FPrev) then
    FPrev(Sender, S, Handled);
end;

{ ---- TLCLDiagConnection ---- }

constructor TLCLDiagConnection.Create(AStream: TSocketStream;
  AServer: TLCLDiagServer);
begin
  inherited Create(False);
  FreeOnTerminate := True;
  FStream := AStream;
  FServer := AServer;
end;

procedure TLCLDiagConnection.SendStr(const S: string);
begin
  if Length(S) > 0 then
    FStream.WriteBuffer(S[1], Length(S));
end;

procedure TLCLDiagConnection.HandleLine(const ALine: string;
  out AResponse: string);
var
  Cmd, Path: string;
  Id, Depth, SinceSeq, Max: Int64;
  C: TControl;
  DebugVal: Boolean;
begin
  Cmd := ExtractJStr(ALine, 'cmd');
  Id := ExtractJInt(ALine, 'id');

  if Cmd = 'ping' then begin
    AResponse := '{' + JInt('id', Id) + ',"result":{' +
      JStr('version', '1.0') + ',' +
      JStr('app', 'Eleazar') + ',' +
      JInt('pid', GetProcessID) + ',' +
      JInt('port', FServer.Port) + '}}';
  end

  else if Cmd = 'tree' then begin
    Depth := ExtractJInt(ALine, 'depth');
    if Depth <= 0 then Depth := 10;
    AResponse := '{' + JInt('id', Id) + ',"result":' +
      BuildTreeJSON(Depth) + '}';
  end

  else if Cmd = 'props' then begin
    Path := ExtractJStr(ALine, 'path');
    AResponse := '{' + JInt('id', Id) + ',"result":' +
      BuildPropsJSON(Path) + '}';
  end

  else if Cmd = 'events' then begin
    SinceSeq := ExtractJInt(ALine, 'since_seq');
    Max := ExtractJInt(ALine, 'max');
    if Max <= 0 then Max := 200;
    if DiagRing <> nil then
      AResponse := '{' + JInt('id', Id) + ',"result":' +
        DiagRing.QueryJSON(QWord(SinceSeq), Max) + '}'
    else
      AResponse := '{' + JInt('id', Id) + ',"result":{"count":0,"events":[]}}';
  end

  else if Cmd = 'stats' then begin
    if DiagRing <> nil then
      AResponse := '{' + JInt('id', Id) + ',"result":' +
        DiagRing.StatsJSON + '}'
    else
      AResponse := '{' + JInt('id', Id) + ',"result":{}}';
  end

  else if Cmd = 'set_debug' then begin
    Path := ExtractJStr(ALine, 'path');
    DebugVal := ExtractJBool(ALine, 'value');
    C := FindControlByPath(Path);
    if C <> nil then begin
      C.DebugLogging := DebugVal;
      AResponse := '{' + JInt('id', Id) + ',' + JStr('result', 'ok') + '}';
    end else
      AResponse := '{' + JInt('id', Id) + ',' +
        JStr('error', 'control not found: ' + Path) + '}';
  end

  else if Cmd = 'forms' then begin
    AResponse := '{' + JInt('id', Id) + ',"result":' +
      BuildTreeJSON(0) + '}';
  end

  else
    AResponse := '{' + JInt('id', Id) + ',' +
      JStr('error', 'unknown command: ' + Cmd) + '}';
end;

procedure TLCLDiagConnection.Execute;
var
  Buf: array[0..4095] of Byte;
  LineBuf, Response: string;
  N, I: Integer;
begin
  try
    LineBuf := '';
    while not Terminated do begin
      N := FStream.Read(Buf{%H-}, SizeOf(Buf));
      if N <= 0 then Break;
      for I := 0 to N - 1 do begin
        if Buf[I] = 10 then begin
          if LineBuf <> '' then begin
            HandleLine(Trim(LineBuf), Response);
            SendStr(Response + #10);
          end;
          LineBuf := '';
        end else if Buf[I] <> 13 then
          LineBuf := LineBuf + Chr(Buf[I]);
      end;
    end;
  except
  end;
  try FStream.Free; except end;
end;

{ ---- TLCLDiagServer ---- }

constructor TLCLDiagServer.Create(APort: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPort := APort;
  FReady := RTLEventCreate;
end;

destructor TLCLDiagServer.Destroy;
begin
  StopListening;
  RTLeventdestroy(FReady);
  inherited;
end;

procedure TLCLDiagServer.DoConnect(Sender: TObject; Data: TSocketStream);
begin
  TLCLDiagConnection.Create(Data, Self);
end;

procedure TLCLDiagServer.Execute;
var
  I: Integer;
  Srv: TInetServer;
  Bound: Boolean;
begin
  Bound := False;
  Srv := nil;
  for I := 0 to 9 do begin
    try
      Srv := TInetServer.Create('127.0.0.1', FPort + I);
      Srv.Listen;
      FPort := FPort + I;
      Bound := True;
      Break;
    except
      FreeAndNil(Srv);
    end;
  end;

  if not Bound then begin
    FPort := -1;
    RTLeventSetEvent(FReady);
    Exit;
  end;

  FInetServer := Srv;
  FInetServer.OnConnect := @DoConnect;
  RTLeventSetEvent(FReady);

  try
    FInetServer.StartAccepting;
  except
  end;

  FreeAndNil(FInetServer);
end;

procedure TLCLDiagServer.WaitReady;
begin
  RTLeventWaitFor(FReady);
end;

procedure TLCLDiagServer.StopListening;
begin
  if Assigned(FInetServer) then begin
    FInetServer.StopAccepting;
  end;
end;

{ ===== Public API =========================================================== }

procedure LCLDiagStartServer;
var
  EnvPort: string;
  Port: Integer;
begin
  if DiagServer <> nil then Exit;

  EnvPort := GetEnvironmentVariable('LCL_DIAG_PORT');
  if EnvPort <> '' then
    Port := StrToIntDef(EnvPort, 4747)
  else
    Port := 4747;

  DiagServer := TLCLDiagServer.Create(Port);
  DiagServer.Start;
  DiagServer.WaitReady;

  if DiagServer.Port > 0 then
    DebugLn(['[LCLDiag] Socket inspector listening on localhost:',
      DiagServer.Port])
  else
    DebugLn('[LCLDiag] Failed to bind socket inspector');
end;

procedure LCLDiagStopServer;
begin
  if DiagServer <> nil then begin
    DiagServer.StopListening;
    DiagServer.WaitFor;
    FreeAndNil(DiagServer);
  end;
end;

{ ===== Initialization / Finalization ======================================== }

procedure InstallHook;
var
  EnvSize: string;
  RingSize: Integer;
begin
  EnvSize := GetEnvironmentVariable('LCL_DIAG_RING_SIZE');
  if EnvSize <> '' then
    RingSize := StrToIntDef(EnvSize, 65536)
  else
    RingSize := 65536;

  DiagRing := TLCLEventRing.Create(RingSize);

  DiagHook := TDiagDebugLnHook.Create;
  if DebugLogger is TLazLoggerFile then begin
    DiagHook.FPrev := TLazLoggerFile(DebugLogger).OnDebugLn;
    TLazLoggerFile(DebugLogger).OnDebugLn := @DiagHook.OnDebugLn;
  end;
end;

procedure UninstallHook;
begin
  if DebugLogger is TLazLoggerFile then
    TLazLoggerFile(DebugLogger).OnDebugLn := DiagHook.FPrev;
  LCLDiagStopServer;
  FreeAndNil(DiagHook);
  FreeAndNil(DiagRing);
end;

initialization
  InstallHook;

finalization
  UninstallHook;

{$ELSE}

procedure LCLDiagStartServer;
begin
end;

procedure LCLDiagStopServer;
begin
end;

{$ENDIF}

end.
