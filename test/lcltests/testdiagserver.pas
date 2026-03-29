{
 Test all with:
     ./rundiagtests --format=plain --suite=TTestDiagServer

 Test specific with:
     ./rundiagtests --format=plain --suite=TestServerBindsAndAccepts
     ./rundiagtests --format=plain --suite=TestPingCommand
     ./rundiagtests --format=plain --suite=TestEventsCommand
}
unit TestDiagServer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, Sockets, ssockets,
  LCLDiagServer;

type

  { TTestDiagServer }

  TTestDiagServer = class(TTestCase)
  private
    FServer: TLCLDiagServer;
    FPort: Integer;
    FRingBackup: TLCLEventRing;
    procedure StartServer;
    procedure StopServer;
    function ConnectClient: TInetSocket;
    function SendRecv(ASock: TInetSocket; const ACmd: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestServerBindsAndAccepts;
    procedure TestServerPortRetrieval;
    procedure TestServerPortFallback;
    procedure TestPingCommand;
    procedure TestPingHasVersion;
    procedure TestPingHasPid;
    procedure TestUnknownCommand;
    procedure TestEventsCommandEmpty;
    procedure TestEventsCommandWithData;
    procedure TestEventsCommandSinceSeq;
    procedure TestEventsCommandMaxLimit;
    procedure TestStatsCommand;
    procedure TestStatsAfterPush;
    procedure TestMultipleCommands;
    procedure TestMultipleClients;
    procedure TestEmptyLineIgnored;
    procedure TestMalformedJSON;
    procedure TestFormsCommandNoScreen;
    procedure TestPropsCommandMissing;
  end;

implementation

{ ===== Helpers ============================================================= }

procedure TTestDiagServer.SetUp;
begin
  { Save and replace the global DiagRing so tests don't interfere
    with the one installed at unit initialization }
  FRingBackup := DiagRing;
  DiagRing := TLCLEventRing.Create(256);
  FServer := nil;
  FPort := 14747;  { Use a high port to avoid conflicts }
end;

procedure TTestDiagServer.TearDown;
begin
  StopServer;
  FreeAndNil(DiagRing);
  DiagRing := FRingBackup;
end;

procedure TTestDiagServer.StartServer;
begin
  FServer := TLCLDiagServer.Create(FPort);
  FServer.Start;
  FServer.WaitReady;
  { If binding failed, try next port range }
  if FServer.Port < 0 then begin
    FreeAndNil(FServer);
    FPort := FPort + 100;
    FServer := TLCLDiagServer.Create(FPort);
    FServer.Start;
    FServer.WaitReady;
  end;
  AssertTrue('Server bound to a port', FServer.Port > 0);
  FPort := FServer.Port;
end;

procedure TTestDiagServer.StopServer;
begin
  if FServer <> nil then begin
    FServer.StopListening;
    FServer.WaitFor;
    FreeAndNil(FServer);
  end;
end;

function TTestDiagServer.ConnectClient: TInetSocket;
begin
  Result := TInetSocket.Create('127.0.0.1', FPort);
end;

function TTestDiagServer.SendRecv(ASock: TInetSocket; const ACmd: string): string;
var
  Buf: array[0..8191] of Byte;
  Line: string;
  N: Integer;
begin
  Line := ACmd + #10;
  ASock.WriteBuffer(Line[1], Length(Line));

  { Read until we get a newline }
  Result := '';
  repeat
    N := ASock.Read(Buf{%H-}, SizeOf(Buf));
    if N <= 0 then Break;
    Result := Result + Copy(PChar(@Buf[0]), 1, N);
  until Pos(#10, Result) > 0;

  { Strip trailing newline }
  if (Length(Result) > 0) and (Result[Length(Result)] = #10) then
    SetLength(Result, Length(Result) - 1);
end;

{ ===== Server Lifecycle Tests ============================================== }

procedure TTestDiagServer.TestServerBindsAndAccepts;
var
  Sock: TInetSocket;
begin
  StartServer;
  Sock := ConnectClient;
  try
    AssertNotNull('Client connected', Sock);
  finally
    Sock.Free;
  end;
end;

procedure TTestDiagServer.TestServerPortRetrieval;
begin
  StartServer;
  AssertTrue('Port is positive', FServer.Port > 0);
  AssertTrue('Port is in expected range', FServer.Port >= FPort);
  AssertTrue('Port within fallback range', FServer.Port < FPort + 10);
end;

procedure TTestDiagServer.TestServerPortFallback;
var
  Server2: TLCLDiagServer;
begin
  StartServer;
  { Start a second server on the same port — it should fall back }
  Server2 := TLCLDiagServer.Create(FPort);
  try
    Server2.Start;
    Server2.WaitReady;
    AssertTrue('Second server bound', Server2.Port > 0);
    AssertTrue('Second server on different port', Server2.Port <> FServer.Port);
  finally
    Server2.StopListening;
    Server2.WaitFor;
    Server2.Free;
  end;
end;

{ ===== Ping Command Tests ================================================== }

procedure TTestDiagServer.TestPingCommand;
var
  Sock: TInetSocket;
  Resp: string;
begin
  StartServer;
  Sock := ConnectClient;
  try
    Resp := SendRecv(Sock, '{"id":1,"cmd":"ping"}');
    AssertTrue('has id', Pos('"id":1', Resp) > 0);
    AssertTrue('has result', Pos('"result"', Resp) > 0);
    AssertTrue('has app', Pos('"app"', Resp) > 0);
  finally
    Sock.Free;
  end;
end;

procedure TTestDiagServer.TestPingHasVersion;
var
  Sock: TInetSocket;
  Resp: string;
begin
  StartServer;
  Sock := ConnectClient;
  try
    Resp := SendRecv(Sock, '{"id":1,"cmd":"ping"}');
    AssertTrue('has version field', Pos('"version"', Resp) > 0);
    AssertTrue('version is 1.0', Pos('"1.0"', Resp) > 0);
  finally
    Sock.Free;
  end;
end;

procedure TTestDiagServer.TestPingHasPid;
var
  Sock: TInetSocket;
  Resp: string;
  Pid: Int64;
begin
  StartServer;
  Sock := ConnectClient;
  try
    Resp := SendRecv(Sock, '{"id":1,"cmd":"ping"}');
    Pid := ExtractJInt(Resp, 'pid');
    AssertTrue('pid is positive', Pid > 0);
    AssertEquals('pid matches current process', GetProcessID, Pid);
  finally
    Sock.Free;
  end;
end;

{ ===== Error Handling Tests ================================================ }

procedure TTestDiagServer.TestUnknownCommand;
var
  Sock: TInetSocket;
  Resp: string;
begin
  StartServer;
  Sock := ConnectClient;
  try
    Resp := SendRecv(Sock, '{"id":99,"cmd":"bogus"}');
    AssertTrue('has error field', Pos('"error"', Resp) > 0);
    AssertTrue('mentions unknown', Pos('unknown command', Resp) > 0);
  finally
    Sock.Free;
  end;
end;

procedure TTestDiagServer.TestEmptyLineIgnored;
var
  Sock: TInetSocket;
  Resp, Line: string;
begin
  StartServer;
  Sock := ConnectClient;
  try
    { Send empty lines then a real command }
    Line := #10 + #10 + '{"id":1,"cmd":"ping"}' + #10;
    Sock.WriteBuffer(Line[1], Length(Line));

    Resp := '';
    repeat
      SetLength(Line, 4096);
      SetLength(Line, Sock.Read(Line[1], Length(Line)));
      if Length(Line) = 0 then Break;
      Resp := Resp + Line;
    until Pos(#10, Resp) > 0;

    AssertTrue('got ping response', Pos('"result"', Resp) > 0);
  finally
    Sock.Free;
  end;
end;

procedure TTestDiagServer.TestMalformedJSON;
var
  Sock: TInetSocket;
  Resp: string;
begin
  StartServer;
  Sock := ConnectClient;
  try
    { Send garbage, then a valid command }
    Resp := SendRecv(Sock, 'this is not json');
    { Server should respond with an error or empty for unrecognized cmd }
    AssertTrue('got some response', Length(Resp) > 0);
    { Follow up with valid command to prove connection still works }
    Resp := SendRecv(Sock, '{"id":2,"cmd":"ping"}');
    AssertTrue('ping still works', Pos('"result"', Resp) > 0);
  finally
    Sock.Free;
  end;
end;

{ ===== Events Command Tests ================================================ }

procedure TTestDiagServer.TestEventsCommandEmpty;
var
  Sock: TInetSocket;
  Resp: string;
begin
  StartServer;
  Sock := ConnectClient;
  try
    Resp := SendRecv(Sock, '{"id":1,"cmd":"events","since_seq":0,"max":100}');
    AssertTrue('has count', Pos('"count"', Resp) > 0);
    AssertEquals('zero events', 0, ExtractJInt(Resp, 'count'));
  finally
    Sock.Free;
  end;
end;

procedure TTestDiagServer.TestEventsCommandWithData;
var
  Sock: TInetSocket;
  Resp: string;
begin
  StartServer;
  DiagRing.Push('[WMSize] MainIDEBar w=1920 h=85');
  DiagRing.Push('[DisableAutoSizing] CoolBar1');
  DiagRing.Push('[EnableAutoSizing] CoolBar1');

  Sock := ConnectClient;
  try
    Resp := SendRecv(Sock, '{"id":1,"cmd":"events","since_seq":0,"max":100}');
    AssertEquals('3 events', 3, ExtractJInt(Resp, 'count'));
    AssertTrue('has WMSize', Pos('WMSize', Resp) > 0);
    AssertTrue('has MainIDEBar', Pos('MainIDEBar', Resp) > 0);
  finally
    Sock.Free;
  end;
end;

procedure TTestDiagServer.TestEventsCommandSinceSeq;
var
  Sock: TInetSocket;
  Resp: string;
begin
  StartServer;
  DiagRing.Push('event-A');
  DiagRing.Push('event-B');
  DiagRing.Push('event-C');

  Sock := ConnectClient;
  try
    Resp := SendRecv(Sock, '{"id":1,"cmd":"events","since_seq":2,"max":100}');
    AssertEquals('1 event after seq 2', 1, ExtractJInt(Resp, 'count'));
    AssertTrue('has event-C', Pos('event-C', Resp) > 0);
    AssertEquals('no event-A', 0, Pos('event-A', Resp));
  finally
    Sock.Free;
  end;
end;

procedure TTestDiagServer.TestEventsCommandMaxLimit;
var
  Sock: TInetSocket;
  Resp: string;
  I: Integer;
begin
  StartServer;
  for I := 1 to 50 do
    DiagRing.Push('bulk-' + IntToStr(I));

  Sock := ConnectClient;
  try
    Resp := SendRecv(Sock, '{"id":1,"cmd":"events","since_seq":0,"max":10}');
    AssertEquals('limited to 10', 10, ExtractJInt(Resp, 'count'));
  finally
    Sock.Free;
  end;
end;

{ ===== Stats Command Tests ================================================= }

procedure TTestDiagServer.TestStatsCommand;
var
  Sock: TInetSocket;
  Resp: string;
begin
  StartServer;
  Sock := ConnectClient;
  try
    Resp := SendRecv(Sock, '{"id":1,"cmd":"stats"}');
    AssertTrue('has result', Pos('"result"', Resp) > 0);
    AssertTrue('has total_pushed', Pos('"total_pushed"', Resp) > 0);
    AssertTrue('has buffer_capacity', Pos('"buffer_capacity"', Resp) > 0);
  finally
    Sock.Free;
  end;
end;

procedure TTestDiagServer.TestStatsAfterPush;
var
  Sock: TInetSocket;
  Resp, Inner: string;
  P: Integer;
begin
  StartServer;
  DiagRing.Push('x');
  DiagRing.Push('y');

  Sock := ConnectClient;
  try
    Resp := SendRecv(Sock, '{"id":1,"cmd":"stats"}');
    { Extract the inner result object }
    P := Pos('"result":', Resp);
    AssertTrue('has result', P > 0);
    Inner := Copy(Resp, P + 9, Length(Resp));
    AssertEquals('total_pushed', 2, ExtractJInt(Inner, 'total_pushed'));
    AssertEquals('buffer_used', 2, ExtractJInt(Inner, 'buffer_used'));
  finally
    Sock.Free;
  end;
end;

{ ===== Multiple Commands / Clients ========================================= }

procedure TTestDiagServer.TestMultipleCommands;
var
  Sock: TInetSocket;
  Resp: string;
begin
  StartServer;
  Sock := ConnectClient;
  try
    Resp := SendRecv(Sock, '{"id":1,"cmd":"ping"}');
    AssertTrue('first ping ok', Pos('"id":1', Resp) > 0);

    Resp := SendRecv(Sock, '{"id":2,"cmd":"stats"}');
    AssertTrue('stats ok', Pos('"id":2', Resp) > 0);

    Resp := SendRecv(Sock, '{"id":3,"cmd":"ping"}');
    AssertTrue('second ping ok', Pos('"id":3', Resp) > 0);
  finally
    Sock.Free;
  end;
end;

procedure TTestDiagServer.TestMultipleClients;
var
  Sock1, Sock2: TInetSocket;
  Resp1, Resp2: string;
begin
  StartServer;
  Sock1 := ConnectClient;
  Sock2 := ConnectClient;
  try
    Resp1 := SendRecv(Sock1, '{"id":10,"cmd":"ping"}');
    Resp2 := SendRecv(Sock2, '{"id":20,"cmd":"ping"}');
    AssertTrue('client 1 got id 10', Pos('"id":10', Resp1) > 0);
    AssertTrue('client 2 got id 20', Pos('"id":20', Resp2) > 0);
  finally
    Sock2.Free;
    Sock1.Free;
  end;
end;

{ ===== Edge Case: Commands requiring Screen (unavailable in tests) ========= }

procedure TTestDiagServer.TestFormsCommandNoScreen;
var
  Sock: TInetSocket;
  Resp: string;
begin
  StartServer;
  Sock := ConnectClient;
  try
    { forms command tries to walk Screen — may error or return empty }
    Resp := SendRecv(Sock, '{"id":1,"cmd":"forms"}');
    AssertTrue('got response', Length(Resp) > 0);
    AssertTrue('has id', Pos('"id":1', Resp) > 0);
  finally
    Sock.Free;
  end;
end;

procedure TTestDiagServer.TestPropsCommandMissing;
var
  Sock: TInetSocket;
  Resp: string;
begin
  StartServer;
  Sock := ConnectClient;
  try
    Resp := SendRecv(Sock, '{"id":1,"cmd":"props","path":"NonExistent/Control"}');
    AssertTrue('has error', Pos('"error"', Resp) > 0);
    AssertTrue('mentions not found', Pos('not found', Resp) > 0);
  finally
    Sock.Free;
  end;
end;

initialization
  RegisterTest(TTestDiagServer);

end.
