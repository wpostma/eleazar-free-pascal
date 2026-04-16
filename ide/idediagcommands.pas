unit IDEDiagCommands;
{
  IDE-level diagnostic commands for the LCL socket inspector.
  Registers handlers for source editor, project, and file operations.
  All handlers execute on the main thread via QueueAsyncCall + RTLEvent.

  Thread safety: each handler packs inputs/outputs into a stack-allocated
  TDiagRequest record, passes its address as PtrInt, and blocks until the
  main thread is done. No global state is shared between threads.
}

{$mode objfpc}{$H+}

interface

procedure RegisterIDEDiagCommands;

implementation

uses
  Classes, SysUtils, Types, Forms, Controls, Graphics, GraphType, IntfGraphics, FPimage,
  LCLDiagServer,
  LazIDEIntf, SrcEditorIntf, ProjectIntf,
  EnvGuiOptions;

{ ===== Request record — all cross-thread data lives here =================== }

type
  PDiagRequest = ^TDiagRequest;
  TDiagRequest = record
    Line: string;      // input: raw JSON command from client
    Result: string;    // output: JSON result for client
  end;

{ ===== Main-thread synchronization ========================================= }

{ Uses TThread.Synchronize to run a procedure on the main thread.
  The calling thread blocks until completion. Data is passed via
  a stack-allocated TDiagRequest record whose address is stored
  in the runner object before the Synchronize call. }

type
  TDiagMainProc = procedure(Data: PtrInt);

  TMainThreadRunner = class
  private
    FProc: TDiagMainProc;
    FData: PtrInt;
  public
    procedure DoCall;
  end;

var
  MainRunner: TMainThreadRunner;

procedure TMainThreadRunner.DoCall;
begin
  FProc(FData);
end;

function MainThreadIsModal: Boolean;
begin
  Result := (Application <> nil) and (Application.ModalLevel > 0);
end;

procedure RunOnMainThread(AProc: TDiagMainProc; AParam: PtrInt);
begin
  if GetCurrentThreadId = MainThreadID then begin
    AProc(AParam);
    Exit;
  end;
  { If a modal dialog is up, Synchronize will deadlock — the main thread
    is stuck in the modal loop and won't process our call. }
  if MainThreadIsModal then
    raise Exception.Create('main thread blocked by modal dialog (ModalLevel='
      + IntToStr(Application.ModalLevel) + ')');
  { TThread.Synchronize blocks the calling thread until the main thread
    completes DoCall. So the writes to FProc/FData below are safe:
    the calling thread is blocked while the main thread reads them,
    and concurrent callers serialize through Synchronize's queue. }
  MainRunner.FProc := AProc;
  MainRunner.FData := AParam;
  TThread.Synchronize(nil, @MainRunner.DoCall);
end;

{ ===== Command: editors ==================================================== }

procedure DoEditors(Data: PtrInt);
var
  Req: PDiagRequest;
  I: Integer;
  Ed: TSourceEditorInterface;
  Items: string;
begin
  Req := PDiagRequest(Data);
  if SourceEditorManagerIntf = nil then begin
    Req^.Result := '{' + JStr('error', 'no source editor manager') + '}';
    Exit;
  end;
  Items := '';
  for I := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do begin
    Ed := SourceEditorManagerIntf.SourceEditors[I];
    if Items <> '' then Items := Items + ',';
    Items := Items + '{' +
      JStr('filename', Ed.FileName) + ',' +
      JBool('modified', Ed.Modified) + ',' +
      JBool('readOnly', Ed.ReadOnly) + ',' +
      JInt('lines', Ed.LineCount) + ',' +
      JInt('cursorLine', Ed.CursorTextXY.Y) + ',' +
      JInt('cursorCol', Ed.CursorTextXY.X) + '}';
  end;
  Req^.Result := '{' +
    JInt('count', SourceEditorManagerIntf.SourceEditorCount) + ',' +
    '"editors":[' + Items + ']}';
end;

function HandleEditors(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  Req.Line := ALine;
  RunOnMainThread(@DoEditors, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: active_editor ============================================== }

procedure DoActiveEditor(Data: PtrInt);
var
  Req: PDiagRequest;
  Ed: TSourceEditorInterface;
begin
  Req := PDiagRequest(Data);
  if SourceEditorManagerIntf = nil then begin
    Req^.Result := '{' + JStr('error', 'no source editor manager') + '}';
    Exit;
  end;
  Ed := SourceEditorManagerIntf.ActiveEditor;
  if Ed = nil then begin
    Req^.Result := '{"active":false}';
    Exit;
  end;
  Req^.Result := '{' +
    JBool('active', True) + ',' +
    JStr('filename', Ed.FileName) + ',' +
    JBool('modified', Ed.Modified) + ',' +
    JBool('readOnly', Ed.ReadOnly) + ',' +
    JInt('lines', Ed.LineCount) + ',' +
    JInt('cursorLine', Ed.CursorTextXY.Y) + ',' +
    JInt('cursorCol', Ed.CursorTextXY.X) + ',' +
    JInt('topLine', Ed.TopLine) + ',' +
    JBool('selectionAvailable', Ed.SelectionAvailable) + '}';
end;

function HandleActiveEditor(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  Req.Line := ALine;
  RunOnMainThread(@DoActiveEditor, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: get_source ================================================= }

procedure DoGetSource(Data: PtrInt);
var
  Req: PDiagRequest;
  Filename: string;
  Ed: TSourceEditorInterface;
begin
  Req := PDiagRequest(Data);
  Filename := ExtractJStr(Req^.Line, 'filename');
  if SourceEditorManagerIntf = nil then begin
    Req^.Result := '{' + JStr('error', 'no source editor manager') + '}';
    Exit;
  end;
  Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(Filename);
  if Ed = nil then begin
    Req^.Result := '{' + JStr('error', 'file not open: ' + Filename) + '}';
    Exit;
  end;
  Req^.Result := '{' +
    JStr('filename', Ed.FileName) + ',' +
    JInt('lines', Ed.LineCount) + ',' +
    JStr('source', Ed.SourceText) + '}';
end;

function HandleGetSource(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  if ExtractJStr(ALine, 'filename') = '' then begin
    Result := '{' + JStr('error', 'missing filename') + '}';
    Exit;
  end;
  Req.Line := ALine;
  RunOnMainThread(@DoGetSource, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: set_source ================================================= }

procedure DoSetSource(Data: PtrInt);
var
  Req: PDiagRequest;
  Filename, Source: string;
  Ed: TSourceEditorInterface;
begin
  Req := PDiagRequest(Data);
  Filename := ExtractJStr(Req^.Line, 'filename');
  Source := ExtractJStr(Req^.Line, 'source');
  if SourceEditorManagerIntf = nil then begin
    Req^.Result := '{' + JStr('error', 'no source editor manager') + '}';
    Exit;
  end;
  Ed := SourceEditorManagerIntf.SourceEditorIntfWithFilename(Filename);
  if Ed = nil then begin
    Req^.Result := '{' + JStr('error', 'file not open: ' + Filename) + '}';
    Exit;
  end;
  Ed.BeginUndoBlock;
  try
    Ed.SourceText := Source;
  finally
    Ed.EndUndoBlock;
  end;
  Req^.Result := '{' + JStr('result', 'ok') + ',' +
    JInt('lines', Ed.LineCount) + '}';
end;

function HandleSetSource(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  if ExtractJStr(ALine, 'filename') = '' then begin
    Result := '{' + JStr('error', 'missing filename') + '}';
    Exit;
  end;
  Req.Line := ALine;
  RunOnMainThread(@DoSetSource, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: get_selection ============================================== }

procedure DoGetSelection(Data: PtrInt);
var
  Req: PDiagRequest;
  Ed: TSourceEditorInterface;
begin
  Req := PDiagRequest(Data);
  if SourceEditorManagerIntf = nil then begin
    Req^.Result := '{' + JStr('error', 'no source editor manager') + '}';
    Exit;
  end;
  Ed := SourceEditorManagerIntf.ActiveEditor;
  if Ed = nil then begin
    Req^.Result := '{' + JStr('error', 'no active editor') + '}';
    Exit;
  end;
  Req^.Result := '{' +
    JStr('filename', Ed.FileName) + ',' +
    JBool('hasSelection', Ed.SelectionAvailable) + ',' +
    JInt('blockBeginLine', Ed.BlockBegin.Y) + ',' +
    JInt('blockBeginCol', Ed.BlockBegin.X) + ',' +
    JInt('blockEndLine', Ed.BlockEnd.Y) + ',' +
    JInt('blockEndCol', Ed.BlockEnd.X) + ',' +
    JStr('selection', Ed.Selection) + '}';
end;

function HandleGetSelection(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  Req.Line := ALine;
  RunOnMainThread(@DoGetSelection, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: set_selection ============================================== }

procedure DoSetSelection(Data: PtrInt);
var
  Req: PDiagRequest;
  NewText: string;
  Ed: TSourceEditorInterface;
begin
  Req := PDiagRequest(Data);
  NewText := ExtractJStr(Req^.Line, 'text');
  if SourceEditorManagerIntf = nil then begin
    Req^.Result := '{' + JStr('error', 'no source editor manager') + '}';
    Exit;
  end;
  Ed := SourceEditorManagerIntf.ActiveEditor;
  if Ed = nil then begin
    Req^.Result := '{' + JStr('error', 'no active editor') + '}';
    Exit;
  end;
  Ed.BeginUndoBlock;
  try
    Ed.Selection := NewText;
  finally
    Ed.EndUndoBlock;
  end;
  Req^.Result := '{' + JStr('result', 'ok') + '}';
end;

function HandleSetSelection(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  Req.Line := ALine;
  RunOnMainThread(@DoSetSelection, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: cursor ===================================================== }

procedure DoGetCursor(Data: PtrInt);
var
  Req: PDiagRequest;
  Ed: TSourceEditorInterface;
begin
  Req := PDiagRequest(Data);
  if SourceEditorManagerIntf = nil then begin
    Req^.Result := '{' + JStr('error', 'no source editor manager') + '}';
    Exit;
  end;
  Ed := SourceEditorManagerIntf.ActiveEditor;
  if Ed = nil then begin
    Req^.Result := '{' + JStr('error', 'no active editor') + '}';
    Exit;
  end;
  Req^.Result := '{' +
    JStr('filename', Ed.FileName) + ',' +
    JInt('line', Ed.CursorTextXY.Y) + ',' +
    JInt('col', Ed.CursorTextXY.X) + ',' +
    JInt('topLine', Ed.TopLine) + '}';
end;

procedure DoSetCursor(Data: PtrInt);
var
  Req: PDiagRequest;
  Ed: TSourceEditorInterface;
  Line, Col: Int64;
  P: TPoint;
begin
  Req := PDiagRequest(Data);
  Line := ExtractJInt(Req^.Line, 'line');
  Col := ExtractJInt(Req^.Line, 'col');
  if SourceEditorManagerIntf = nil then begin
    Req^.Result := '{' + JStr('error', 'no source editor manager') + '}';
    Exit;
  end;
  Ed := SourceEditorManagerIntf.ActiveEditor;
  if Ed = nil then begin
    Req^.Result := '{' + JStr('error', 'no active editor') + '}';
    Exit;
  end;
  if Line <= 0 then Line := 1;
  if Col <= 0 then Col := 1;
  P.Y := Line;
  P.X := Col;
  Ed.CursorTextXY := P;
  Req^.Result := '{' + JStr('result', 'ok') + ',' +
    JInt('line', Ed.CursorTextXY.Y) + ',' +
    JInt('col', Ed.CursorTextXY.X) + '}';
end;

function HandleCursor(const ALine: string): string;
var
  Req: TDiagRequest;
  Line, Col: Int64;
begin
  Req.Line := ALine;
  Line := ExtractJInt(ALine, 'line');
  Col := ExtractJInt(ALine, 'col');
  if (Line > 0) or (Col > 0) then
    RunOnMainThread(@DoSetCursor, PtrInt(@Req))
  else
    RunOnMainThread(@DoGetCursor, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: insert_line ================================================ }

procedure DoInsertLine(Data: PtrInt);
var
  Req: PDiagRequest;
  Ed: TSourceEditorInterface;
  Line: Int64;
  Text: string;
begin
  Req := PDiagRequest(Data);
  Line := ExtractJInt(Req^.Line, 'line');
  Text := ExtractJStr(Req^.Line, 'text');
  if Line <= 0 then Line := 1;
  if SourceEditorManagerIntf = nil then begin
    Req^.Result := '{' + JStr('error', 'no source editor manager') + '}';
    Exit;
  end;
  Ed := SourceEditorManagerIntf.ActiveEditor;
  if Ed = nil then begin
    Req^.Result := '{' + JStr('error', 'no active editor') + '}';
    Exit;
  end;
  Ed.BeginUndoBlock;
  try
    Ed.InsertLine(Line, Text, False);
  finally
    Ed.EndUndoBlock;
  end;
  Req^.Result := '{' + JStr('result', 'ok') + ',' +
    JInt('lines', Ed.LineCount) + '}';
end;

function HandleInsertLine(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  Req.Line := ALine;
  RunOnMainThread(@DoInsertLine, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: replace_lines ============================================== }

procedure DoReplaceLines(Data: PtrInt);
var
  Req: PDiagRequest;
  Ed: TSourceEditorInterface;
  StartLine, EndLine: Int64;
  Text: string;
begin
  Req := PDiagRequest(Data);
  StartLine := ExtractJInt(Req^.Line, 'start_line');
  EndLine := ExtractJInt(Req^.Line, 'end_line');
  Text := ExtractJStr(Req^.Line, 'text');
  if StartLine <= 0 then StartLine := 1;
  if EndLine < StartLine then EndLine := StartLine;
  if SourceEditorManagerIntf = nil then begin
    Req^.Result := '{' + JStr('error', 'no source editor manager') + '}';
    Exit;
  end;
  Ed := SourceEditorManagerIntf.ActiveEditor;
  if Ed = nil then begin
    Req^.Result := '{' + JStr('error', 'no active editor') + '}';
    Exit;
  end;
  Ed.BeginUndoBlock;
  try
    Ed.ReplaceLines(StartLine, EndLine, Text, False);
  finally
    Ed.EndUndoBlock;
  end;
  Req^.Result := '{' + JStr('result', 'ok') + ',' +
    JInt('lines', Ed.LineCount) + '}';
end;

function HandleReplaceLines(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  Req.Line := ALine;
  RunOnMainThread(@DoReplaceLines, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: open_file ================================================== }

procedure DoOpenFile(Data: PtrInt);
var
  Req: PDiagRequest;
  Filename: string;
  Res: TModalResult;
begin
  Req := PDiagRequest(Data);
  Filename := ExtractJStr(Req^.Line, 'filename');
  if LazarusIDE = nil then begin
    Req^.Result := '{' + JStr('error', 'IDE not available') + '}';
    Exit;
  end;
  Res := LazarusIDE.DoOpenEditorFile(Filename, -1, -1, [ofAddToRecent]);
  if Res = mrOk then
    Req^.Result := '{' + JStr('result', 'ok') + ',' +
      JStr('filename', Filename) + '}'
  else
    Req^.Result := '{' + JStr('error', 'open failed') + ',' +
      JInt('modalResult', Res) + '}';
end;

function HandleOpenFile(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  if ExtractJStr(ALine, 'filename') = '' then begin
    Result := '{' + JStr('error', 'missing filename') + '}';
    Exit;
  end;
  Req.Line := ALine;
  RunOnMainThread(@DoOpenFile, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: close_file ================================================= }

procedure DoCloseFile(Data: PtrInt);
var
  Req: PDiagRequest;
  Filename: string;
  Save: Boolean;
  Res: TModalResult;
begin
  Req := PDiagRequest(Data);
  Filename := ExtractJStr(Req^.Line, 'filename');
  Save := ExtractJBool(Req^.Line, 'save');
  if LazarusIDE = nil then begin
    Req^.Result := '{' + JStr('error', 'IDE not available') + '}';
    Exit;
  end;
  if Save then
    Res := LazarusIDE.DoCloseEditorFile(Filename, [cfSaveFirst])
  else
    Res := LazarusIDE.DoCloseEditorFile(Filename, []);
  if Res = mrOk then
    Req^.Result := '{' + JStr('result', 'ok') + '}'
  else
    Req^.Result := '{' + JStr('error', 'close failed') + ',' +
      JInt('modalResult', Res) + '}';
end;

function HandleCloseFile(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  if ExtractJStr(ALine, 'filename') = '' then begin
    Result := '{' + JStr('error', 'missing filename') + '}';
    Exit;
  end;
  Req.Line := ALine;
  RunOnMainThread(@DoCloseFile, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: save_file ================================================== }

procedure DoSaveFile(Data: PtrInt);
var
  Req: PDiagRequest;
  Filename: string;
  Res: TModalResult;
begin
  Req := PDiagRequest(Data);
  Filename := ExtractJStr(Req^.Line, 'filename');
  if LazarusIDE = nil then begin
    Req^.Result := '{' + JStr('error', 'IDE not available') + '}';
    Exit;
  end;
  Res := LazarusIDE.DoSaveEditorFile(Filename, []);
  if Res = mrOk then
    Req^.Result := '{' + JStr('result', 'ok') + '}'
  else
    Req^.Result := '{' + JStr('error', 'save failed') + ',' +
      JInt('modalResult', Res) + '}';
end;

function HandleSaveFile(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  if ExtractJStr(ALine, 'filename') = '' then begin
    Result := '{' + JStr('error', 'missing filename') + '}';
    Exit;
  end;
  Req.Line := ALine;
  RunOnMainThread(@DoSaveFile, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: save_all =================================================== }

procedure DoSaveAll(Data: PtrInt);
var
  Req: PDiagRequest;
  Res: TModalResult;
begin
  Req := PDiagRequest(Data);
  if LazarusIDE = nil then begin
    Req^.Result := '{' + JStr('error', 'IDE not available') + '}';
    Exit;
  end;
  Res := LazarusIDE.DoSaveAll([]);
  if Res = mrOk then
    Req^.Result := '{' + JStr('result', 'ok') + '}'
  else
    Req^.Result := '{' + JStr('error', 'save_all failed') + ',' +
      JInt('modalResult', Res) + '}';
end;

function HandleSaveAll(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  Req.Line := ALine;
  RunOnMainThread(@DoSaveAll, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: open_project =============================================== }

procedure DoOpenProject(Data: PtrInt);
var
  Req: PDiagRequest;
  Filename: string;
  Res: TModalResult;
begin
  Req := PDiagRequest(Data);
  Filename := ExtractJStr(Req^.Line, 'filename');
  if LazarusIDE = nil then begin
    Req^.Result := '{' + JStr('error', 'IDE not available') + '}';
    Exit;
  end;
  Res := LazarusIDE.DoOpenProjectFile(Filename, [ofAddToRecent]);
  if Res = mrOk then
    Req^.Result := '{' + JStr('result', 'ok') + ',' +
      JStr('filename', Filename) + '}'
  else
    Req^.Result := '{' + JStr('error', 'open project failed') + ',' +
      JInt('modalResult', Res) + '}';
end;

function HandleOpenProject(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  if ExtractJStr(ALine, 'filename') = '' then begin
    Result := '{' + JStr('error', 'missing filename') + '}';
    Exit;
  end;
  Req.Line := ALine;
  RunOnMainThread(@DoOpenProject, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: project_info =============================================== }

procedure DoProjectInfo(Data: PtrInt);
var
  Req: PDiagRequest;
  Proj: TLazProject;
begin
  Req := PDiagRequest(Data);
  if LazarusIDE = nil then begin
    Req^.Result := '{' + JStr('error', 'IDE not available') + '}';
    Exit;
  end;
  Proj := LazarusIDE.ActiveProject;
  if Proj = nil then begin
    Req^.Result := '{"hasProject":false}';
    Exit;
  end;
  Req^.Result := '{' +
    JBool('hasProject', True) + ',' +
    JStr('projectFile', Proj.ProjectInfoFile) + ',' +
    JStr('title', Proj.Title) + ',' +
    JBool('modified', Proj.Modified) + ',' +
    JInt('fileCount', Proj.FileCount) + '}';
end;

function HandleProjectInfo(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  Req.Line := ALine;
  RunOnMainThread(@DoProjectInfo, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: project_files ============================================== }

procedure DoProjectFiles(Data: PtrInt);
var
  Req: PDiagRequest;
  Proj: TLazProject;
  I: Integer;
  PF: TLazProjectFile;
  Items: string;
begin
  Req := PDiagRequest(Data);
  if LazarusIDE = nil then begin
    Req^.Result := '{' + JStr('error', 'IDE not available') + '}';
    Exit;
  end;
  Proj := LazarusIDE.ActiveProject;
  if Proj = nil then begin
    Req^.Result := '{' + JStr('error', 'no project open') + '}';
    Exit;
  end;
  Items := '';
  for I := 0 to Proj.FileCount - 1 do begin
    PF := Proj.Files[I];
    if Items <> '' then Items := Items + ',';
    Items := Items + '{' +
      JStr('filename', PF.Filename) + ',' +
      JBool('isPartOfProject', PF.IsPartOfProject) + '}';
  end;
  Req^.Result := '{' +
    JInt('count', Proj.FileCount) + ',' +
    '"files":[' + Items + ']}';
end;

function HandleProjectFiles(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  Req.Line := ALine;
  RunOnMainThread(@DoProjectFiles, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: tool_status ================================================ }

procedure DoToolStatus(Data: PtrInt);
var
  Req: PDiagRequest;
const
  StatusNames: array[TLazToolStatus] of string = (
    'idle', 'exiting', 'builder', 'debugger',
    'codetools', 'codetools_aborting', 'custom');
begin
  Req := PDiagRequest(Data);
  if LazarusIDE = nil then begin
    Req^.Result := '{' + JStr('error', 'IDE not available') + '}';
    Exit;
  end;
  Req^.Result := '{' +
    JStr('status', StatusNames[LazarusIDE.ToolStatus]) + ',' +
    JBool('idle', LazarusIDE.ToolStatus = itNone) + '}';
end;

function HandleToolStatus(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  Req.Line := ALine;
  RunOnMainThread(@DoToolStatus, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: list_desktops ============================================== }

procedure DoListDesktops(Data: PtrInt);
var
  Req: PDiagRequest;
  I: Integer;
  D: TCustomDesktopOpt;
  Items, ActiveName: string;
begin
  Req := PDiagRequest(Data);
  Items := '';
  ActiveName := '';
  if EnvironmentGuiOpts.ActiveDesktop <> nil then
    ActiveName := EnvironmentGuiOpts.ActiveDesktop.Name;
  for I := 0 to EnvironmentGuiOpts.Desktops.Count - 1 do begin
    D := EnvironmentGuiOpts.Desktops[I];
    if Items <> '' then Items := Items + ',';
    Items := Items + '{' +
      JStr('name', D.Name) + ',' +
      JBool('isDocked', D.IsDocked) + ',' +
      JBool('compatible', D.Compatible) + ',' +
      JBool('active', D.Name = ActiveName) + '}';
  end;
  Req^.Result := '{' +
    JInt('count', EnvironmentGuiOpts.Desktops.Count) + ',' +
    JStr('active', ActiveName) + ',' +
    '"desktops":[' + Items + ']}';
end;

function HandleListDesktops(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  Req.Line := ALine;
  RunOnMainThread(@DoListDesktops, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: switch_desktop ============================================= }

procedure DoSwitchDesktop(Data: PtrInt);
var
  Req: PDiagRequest;
  Name: string;
  D: TCustomDesktopOpt;
begin
  Req := PDiagRequest(Data);
  Name := ExtractJStr(Req^.Line, 'name');
  D := EnvironmentGuiOpts.Desktops.Find(Name);
  if D = nil then begin
    Req^.Result := '{' + JStr('error', 'desktop not found: ' + Name) + '}';
    Exit;
  end;
  if not D.Compatible then begin
    Req^.Result := '{' + JStr('error', 'desktop not compatible (docked/undocked mismatch): ' + Name) + '}';
    Exit;
  end;
  if not (D is TDesktopOpt) then begin
    Req^.Result := '{' + JStr('error', 'desktop is not a TDesktopOpt: ' + Name) + '}';
    Exit;
  end;
  EnvironmentGuiOpts.UseDesktop(TDesktopOpt(D));
  Req^.Result := '{' + JStr('result', 'ok') + ',' +
    JStr('desktop', Name) + '}';
end;

function HandleSwitchDesktop(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  if ExtractJStr(ALine, 'name') = '' then begin
    Result := '{' + JStr('error', 'missing name') + '}';
    Exit;
  end;
  Req.Line := ALine;
  RunOnMainThread(@DoSwitchDesktop, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: undock ===================================================== }

procedure DoUndock(Data: PtrInt);
var
  Req: PDiagRequest;
  Path: string;
  C: TControl;
  R: TRect;
begin
  Req := PDiagRequest(Data);
  Path := ExtractJStr(Req^.Line, 'path');
  C := FindControlByPath(Path);
  if C = nil then begin
    Req^.Result := '{' + JStr('error', 'control not found: ' + Path) + '}';
    Exit;
  end;
  { Float at current screen position }
  R := C.BoundsRect;
  R.TopLeft := C.ClientToScreen(Point(0, 0));
  R.Right := R.Left + C.Width;
  R.Bottom := R.Top + C.Height;
  if C.ManualFloat(R) then
    Req^.Result := '{' + JStr('result', 'ok') + ',' +
      JStr('path', Path) + ',' +
      JInt('left', R.Left) + ',' +
      JInt('top', R.Top) + ',' +
      JInt('width', C.Width) + ',' +
      JInt('height', C.Height) + '}'
  else
    Req^.Result := '{' + JStr('error', 'ManualFloat failed for ' + Path) + '}';
end;

function HandleUndock(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  if ExtractJStr(ALine, 'path') = '' then begin
    Result := '{' + JStr('error', 'missing path') + '}';
    Exit;
  end;
  Req.Line := ALine;
  RunOnMainThread(@DoUndock, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: dock ======================================================= }

function SideToAlign(const S: string): TAlign;
begin
  if S = 'left' then Result := alLeft
  else if S = 'right' then Result := alRight
  else if S = 'top' then Result := alTop
  else if S = 'bottom' then Result := alBottom
  else if S = 'client' then Result := alClient
  else Result := alNone;
end;

procedure DoDock(Data: PtrInt);
var
  Req: PDiagRequest;
  SourcePath, TargetPath, Side: string;
  Src, Tgt: TControl;
  A: TAlign;
begin
  Req := PDiagRequest(Data);
  SourcePath := ExtractJStr(Req^.Line, 'path');
  TargetPath := ExtractJStr(Req^.Line, 'target');
  Side := ExtractJStr(Req^.Line, 'side');
  Src := FindControlByPath(SourcePath);
  if Src = nil then begin
    Req^.Result := '{' + JStr('error', 'source not found: ' + SourcePath) + '}';
    Exit;
  end;
  Tgt := FindControlByPath(TargetPath);
  if Tgt = nil then begin
    Req^.Result := '{' + JStr('error', 'target not found: ' + TargetPath) + '}';
    Exit;
  end;
  if not (Tgt is TWinControl) then begin
    Req^.Result := '{' + JStr('error', 'target is not a TWinControl: ' + TargetPath) + '}';
    Exit;
  end;
  A := SideToAlign(Side);
  if Src.ManualDock(TWinControl(Tgt), nil, A) then
    Req^.Result := '{' + JStr('result', 'ok') + ',' +
      JStr('source', SourcePath) + ',' +
      JStr('target', TargetPath) + ',' +
      JStr('side', Side) + '}'
  else
    Req^.Result := '{' + JStr('error', 'ManualDock failed') + '}';
end;

function HandleDock(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  if ExtractJStr(ALine, 'path') = '' then begin
    Result := '{' + JStr('error', 'missing path') + '}';
    Exit;
  end;
  if ExtractJStr(ALine, 'target') = '' then begin
    Result := '{' + JStr('error', 'missing target') + '}';
    Exit;
  end;
  Req.Line := ALine;
  RunOnMainThread(@DoDock, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: resize ===================================================== }

procedure DoResize(Data: PtrInt);
var
  Req: PDiagRequest;
  Path: string;
  C: TControl;
  W, H: Int64;
begin
  Req := PDiagRequest(Data);
  Path := ExtractJStr(Req^.Line, 'path');
  W := ExtractJInt(Req^.Line, 'w');
  H := ExtractJInt(Req^.Line, 'h');
  C := FindControlByPath(Path);
  if C = nil then begin
    Req^.Result := '{' + JStr('error', 'control not found: ' + Path) + '}';
    Exit;
  end;
  C.SetBounds(C.Left, C.Top, W, H);
  Req^.Result := '{' + JStr('result', 'ok') + ',' +
    JStr('path', Path) + ',' +
    JInt('width', C.Width) + ',' +
    JInt('height', C.Height) + '}';
end;

function HandleResize(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  if ExtractJStr(ALine, 'path') = '' then begin
    Result := '{' + JStr('error', 'missing path') + '}';
    Exit;
  end;
  Req.Line := ALine;
  RunOnMainThread(@DoResize, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: move ======================================================= }

procedure DoMove(Data: PtrInt);
var
  Req: PDiagRequest;
  Path: string;
  C: TControl;
  L, T: Int64;
begin
  Req := PDiagRequest(Data);
  Path := ExtractJStr(Req^.Line, 'path');
  L := ExtractJInt(Req^.Line, 'left');
  T := ExtractJInt(Req^.Line, 'top');
  C := FindControlByPath(Path);
  if C = nil then begin
    Req^.Result := '{' + JStr('error', 'control not found: ' + Path) + '}';
    Exit;
  end;
  C.SetBounds(L, T, C.Width, C.Height);
  Req^.Result := '{' + JStr('result', 'ok') + ',' +
    JStr('path', Path) + ',' +
    JInt('left', C.Left) + ',' +
    JInt('top', C.Top) + '}';
end;

function HandleMove(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  if ExtractJStr(ALine, 'path') = '' then begin
    Result := '{' + JStr('error', 'missing path') + '}';
    Exit;
  end;
  Req.Line := ALine;
  RunOnMainThread(@DoMove, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: dock_state ================================================= }

procedure BuildDockStateRecursive(AControl: TControl; const APath: string;
  var AItems: string; var ACount: Integer);
var
  MyPath: string;
  I: Integer;
  WC: TWinControl;
begin
  if AControl = nil then Exit;
  try
    if APath = '' then
      MyPath := AControl.Name
    else if AControl.Name <> '' then
      MyPath := APath + '/' + AControl.Name
    else
      MyPath := APath + '/<unnamed>';

    if AItems <> '' then AItems := AItems + ',';
    AItems := AItems + '{' +
      JStr('path', MyPath) + ',' +
      JStr('class', AControl.ClassName) + ',' +
      JStr('caption', AControl.Caption) + ',' +
      JBool('visible', AControl.Visible) + ',' +
      JInt('left', AControl.Left) + ',' +
      JInt('top', AControl.Top) + ',' +
      JInt('width', AControl.Width) + ',' +
      JInt('height', AControl.Height);
    if AControl.HostDockSite <> nil then
      AItems := AItems + ',' + JStr('hostDockSite', AControl.HostDockSite.Name);
    if AControl.Parent <> nil then
      AItems := AItems + ',' + JStr('parent', AControl.Parent.Name);
    AItems := AItems + '}';
    Inc(ACount);

    if AControl is TWinControl then begin
      WC := TWinControl(AControl);
      for I := 0 to WC.ControlCount - 1 do
        if Pos('AnchorDock', WC.Controls[I].ClassName) > 0 then
          BuildDockStateRecursive(WC.Controls[I], MyPath, AItems, ACount);
    end;
  except
  end;
end;

procedure DoDockState(Data: PtrInt);
var
  Req: PDiagRequest;
  I, Count: Integer;
  Items: string;
begin
  Req := PDiagRequest(Data);
  Items := '';
  Count := 0;
  try
    if Screen <> nil then
      for I := 0 to Screen.CustomFormCount - 1 do
        if Pos('AnchorDock', Screen.CustomForms[I].ClassName) > 0 then
          BuildDockStateRecursive(Screen.CustomForms[I], '', Items, Count)
        else if Screen.CustomForms[I].HostDockSite <> nil then
          BuildDockStateRecursive(Screen.CustomForms[I], '', Items, Count);
  except
  end;
  Req^.Result := '{' + JInt('count', Count) + ',' +
    '"nodes":[' + Items + ']}';
end;

function HandleDockState(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  Req.Line := ALine;
  RunOnMainThread(@DoDockState, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Command: screenshot =================================================
  Paints a TCustomForm, downscales to a grayscale PNG quantized to N levels,
  saves under /tmp/lclserver/images/, returns the file path plus size info. }

var
  ScreenshotSeq: Integer = 0;

function SanitizeForFilename(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['A'..'Z','a'..'z','0'..'9','_','-'] then
      Result := Result + S[I]
    else
      Result := Result + '_';
  if Length(Result) > 40 then
    Result := Copy(Result, 1, 40);
  if Result = '' then Result := 'control';
end;

type
  TMarkRect = record
    Path: string;
    Rect: TRect;        // in output (small) image coords
    SrcRect: TRect;     // in form bitmap coords
  end;
  TMarkRectArray = array of TMarkRect;

procedure SplitCSV(const S: string; out Parts: TStringArray);
var
  I, Start, N: Integer;
begin
  N := 0;
  SetLength(Parts, 0);
  if S = '' then Exit;
  Start := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = ',') then
    begin
      if I > Start then
      begin
        SetLength(Parts, N + 1);
        Parts[N] := Trim(Copy(S, Start, I - Start));
        Inc(N);
      end;
      Start := I + 1;
    end;
end;

procedure CollectDockSitesRec(Parent: TWinControl; var Paths: TStringArray);
  function BuildPath(C: TControl): string;
  begin
    if C.Parent = nil then
      Result := C.Name
    else
      Result := BuildPath(C.Parent) + '/' + C.Name;
  end;
var
  I, N: Integer;
  Child: TControl;
begin
  if Parent = nil then Exit;
  for I := 0 to Parent.ControlCount - 1 do
  begin
    Child := Parent.Controls[I];
    if (Child.ClassName = 'TAnchorDockHostSite') and (Child.Name <> '') then
    begin
      N := Length(Paths);
      SetLength(Paths, N + 1);
      Paths[N] := BuildPath(Child);
    end;
    if Child is TWinControl then
      CollectDockSitesRec(TWinControl(Child), Paths);
  end;
end;

procedure DrawRedRect(Img: TLazIntfImage; R: TRect; Thickness: Integer);
var
  Red: TFPColor;
  X, Y, W, H, T: Integer;
begin
  Red := FPColor($FFFF, 0, 0, $FFFF);
  W := Img.Width;
  H := Img.Height;
  T := Thickness;
  if T < 1 then T := 1;
  // Clamp
  if R.Left < 0 then R.Left := 0;
  if R.Top < 0 then R.Top := 0;
  if R.Right > W then R.Right := W;
  if R.Bottom > H then R.Bottom := H;
  if (R.Right <= R.Left) or (R.Bottom <= R.Top) then Exit;
  // Top + bottom edges
  for Y := 0 to T - 1 do
  begin
    if (R.Top + Y) < H then
      for X := R.Left to R.Right - 1 do
        Img.Colors[X, R.Top + Y] := Red;
    if (R.Bottom - 1 - Y) >= 0 then
      for X := R.Left to R.Right - 1 do
        Img.Colors[X, R.Bottom - 1 - Y] := Red;
  end;
  // Left + right edges
  for X := 0 to T - 1 do
  begin
    if (R.Left + X) < W then
      for Y := R.Top to R.Bottom - 1 do
        Img.Colors[R.Left + X, Y] := Red;
    if (R.Right - 1 - X) >= 0 then
      for Y := R.Top to R.Bottom - 1 do
        Img.Colors[R.Right - 1 - X, Y] := Red;
  end;
end;

procedure DoScreenshot(Data: PtrInt);
const
  DefaultMaxW = 640;
  DefaultMaxH = 480;
  DefaultLevels = 4;
  HardCapW = 2048;
  HardCapH = 2048;
  OutDir = '/tmp/lclserver/images/';
var
  Req: PDiagRequest;
  Path, MarksStr: string;
  MaxW, MaxH, Levels: Int64;
  MarkDockSites: Boolean;
  MarkPaths: TStringArray;
  Marks: TMarkRectArray;
  MarkCount, MI: Integer;
  MC: TControl;
  ScrPt: TPoint;
  BmpX, BmpY: Integer;
  MarksJSON: string;
  C: TControl;
  Frm: TCustomForm;
  FullW, FullH, OutW, OutH: Integer;
  Bmp: TBitmap;
  FullImg, SmallImg: TLazIntfImage;
  X, Y, SrcX, SrcY: Integer;
  Col: TFPColor;
  Lum, Band, Step, LevelsI: Integer;
  GrayVal: Word;
  PNG: TPortableNetworkGraphic;
  FName, Stamp, SafeName: string;
  Seq: Integer;
  FileBytes: Int64;
  FS: TFileStream;
begin
  Req := PDiagRequest(Data);
  Path := ExtractJStr(Req^.Line, 'path');
  MaxW := ExtractJInt(Req^.Line, 'max_width');
  MaxH := ExtractJInt(Req^.Line, 'max_height');
  Levels := ExtractJInt(Req^.Line, 'levels');
  MarksStr := ExtractJStr(Req^.Line, 'marks');
  MarkDockSites := ExtractJBool(Req^.Line, 'mark_dock_sites');
  if MaxW <= 0 then MaxW := DefaultMaxW;
  if MaxH <= 0 then MaxH := DefaultMaxH;
  if Levels <= 1 then Levels := DefaultLevels;
  if MaxW > HardCapW then MaxW := HardCapW;
  if MaxH > HardCapH then MaxH := HardCapH;
  if Levels > 256 then Levels := 256;

  if Path = '' then begin
    Req^.Result := '{' + JStr('error', 'missing path') + '}';
    Exit;
  end;
  C := FindControlByPath(Path);
  if C = nil then begin
    Req^.Result := '{' + JStr('error', 'control not found: ' + Path) + '}';
    Exit;
  end;
  if not (C is TCustomForm) then begin
    Req^.Result := '{' + JStr('error', 'only TCustomForm supported in v1: ' + C.ClassName) + '}';
    Exit;
  end;
  Frm := TCustomForm(C);
  if (not Frm.HandleAllocated) or (not Frm.Showing) or (not Frm.Visible) then begin
    Req^.Result := '{' + JStr('error', 'form not visible: ' + Path) + '}';
    Exit;
  end;

  FullW := Frm.Width;
  FullH := Frm.Height;
  if (FullW <= 0) or (FullH <= 0) then begin
    Req^.Result := '{' + JStr('error', 'form has no area') + '}';
    Exit;
  end;

  // Preserve aspect ratio within (MaxW, MaxH).
  OutW := FullW;
  OutH := FullH;
  if OutW > MaxW then begin
    OutH := (OutH * MaxW) div OutW;
    OutW := MaxW;
  end;
  if OutH > MaxH then begin
    OutW := (OutW * MaxH) div OutH;
    OutH := MaxH;
  end;
  if OutW < 1 then OutW := 1;
  if OutH < 1 then OutH := 1;

  // Build the list of mark paths: explicit "marks" CSV + optional dock sites.
  SplitCSV(MarksStr, MarkPaths);
  if MarkDockSites and (Frm is TWinControl) then
    CollectDockSitesRec(TWinControl(Frm), MarkPaths);

  // Resolve each path to a rectangle in both form-bitmap and scaled-output coords.
  // Form bitmap origin is (Frm.Left, Frm.Top) in screen coords: PaintTo paints
  // the outer form (including chrome) into (0,0) of a Frm.Width x Frm.Height bitmap.
  MarkCount := 0;
  SetLength(Marks, Length(MarkPaths));
  for MI := 0 to Length(MarkPaths) - 1 do
  begin
    if MarkPaths[MI] = '' then Continue;
    MC := FindControlByPath(MarkPaths[MI]);
    if (MC = nil) or (MC.Width <= 0) or (MC.Height <= 0) then Continue;
    if MC.Parent <> nil then
      ScrPt := MC.Parent.ClientToScreen(Point(MC.Left, MC.Top))
    else
      ScrPt := Point(MC.Left, MC.Top);
    BmpX := ScrPt.X - Frm.Left;
    BmpY := ScrPt.Y - Frm.Top;
    Marks[MarkCount].Path := MarkPaths[MI];
    Marks[MarkCount].SrcRect := Rect(BmpX, BmpY, BmpX + MC.Width, BmpY + MC.Height);
    Marks[MarkCount].Rect := Rect(
      (BmpX * OutW) div FullW,
      (BmpY * OutH) div FullH,
      ((BmpX + MC.Width) * OutW) div FullW,
      ((BmpY + MC.Height) * OutH) div FullH);
    Inc(MarkCount);
  end;
  SetLength(Marks, MarkCount);

  Bmp := nil; FullImg := nil; SmallImg := nil; PNG := nil;
  FileBytes := 0;
  try
    Bmp := TBitmap.Create;
    Bmp.SetSize(FullW, FullH);
    Frm.PaintTo(Bmp.Canvas, 0, 0);
    FullImg := Bmp.CreateIntfImage;

    SmallImg := TLazIntfImage.Create(OutW, OutH, [riqfRGB, riqfAlpha]);
    LevelsI := Levels;
    if LevelsI < 2 then LevelsI := 2;
    Step := 65535 div (LevelsI - 1);

    for Y := 0 to OutH - 1 do
    begin
      SrcY := (Y * FullH) div OutH;
      if SrcY >= FullH then SrcY := FullH - 1;
      for X := 0 to OutW - 1 do
      begin
        SrcX := (X * FullW) div OutW;
        if SrcX >= FullW then SrcX := FullW - 1;
        Col := FullImg.Colors[SrcX, SrcY];
        // Luminance in 16-bit space: 0.299 R + 0.587 G + 0.114 B
        Lum := (299 * Col.red + 587 * Col.green + 114 * Col.blue) div 1000;
        if Lum < 0 then Lum := 0;
        if Lum > 65535 then Lum := 65535;
        Band := Lum div Step;
        if Band >= LevelsI then Band := LevelsI - 1;
        GrayVal := Band * Step;
        SmallImg.Colors[X, Y] := FPColor(GrayVal, GrayVal, GrayVal, $FFFF);
      end;
    end;

    // Overlay red rectangles for each resolved mark (drawn after grayscaling
    // so the red survives the quantization step).
    for MI := 0 to MarkCount - 1 do
      DrawRedRect(SmallImg, Marks[MI].Rect, 2);

    // Compose filename
    ForceDirectories(OutDir);
    Inc(ScreenshotSeq);
    Seq := ScreenshotSeq;
    Stamp := FormatDateTime('yyyymmdd_hhnnss', Now);
    SafeName := SanitizeForFilename(Path);
    FName := OutDir + Stamp + '_' + Format('%.6d', [Seq]) + '_' + SafeName + '.png';

    PNG := TPortableNetworkGraphic.Create;
    PNG.LoadFromIntfImage(SmallImg);
    PNG.SaveToFile(FName);

    // File byte count
    if FileExists(FName) then
    begin
      FS := TFileStream.Create(FName, fmOpenRead or fmShareDenyNone);
      try
        FileBytes := FS.Size;
      finally
        FS.Free;
      end;
    end;

    // Build marks JSON: [{"path":..,"src":[l,t,r,b],"out":[l,t,r,b]},...]
    MarksJSON := '';
    for MI := 0 to MarkCount - 1 do
    begin
      if MI > 0 then MarksJSON := MarksJSON + ',';
      MarksJSON := MarksJSON + '{' +
        JStr('path', Marks[MI].Path) + ',' +
        '"src":[' + IntToStr(Marks[MI].SrcRect.Left) + ',' +
                    IntToStr(Marks[MI].SrcRect.Top) + ',' +
                    IntToStr(Marks[MI].SrcRect.Right) + ',' +
                    IntToStr(Marks[MI].SrcRect.Bottom) + '],' +
        '"out":[' + IntToStr(Marks[MI].Rect.Left) + ',' +
                    IntToStr(Marks[MI].Rect.Top) + ',' +
                    IntToStr(Marks[MI].Rect.Right) + ',' +
                    IntToStr(Marks[MI].Rect.Bottom) + ']}';
    end;

    Req^.Result := '{' + JStr('result', 'ok') + ',' +
      JStr('path', Path) + ',' +
      JStr('file', FName) + ',' +
      JInt('actualWidth', FullW) + ',' +
      JInt('actualHeight', FullH) + ',' +
      JInt('outWidth', OutW) + ',' +
      JInt('outHeight', OutH) + ',' +
      JInt('levels', LevelsI) + ',' +
      JInt('bytes', FileBytes) + ',' +
      JInt('markCount', MarkCount) + ',' +
      '"marks":[' + MarksJSON + ']}';
  except
    on E: Exception do
      Req^.Result := '{' + JStr('error', 'screenshot failed: ' + E.Message) + '}';
  end;
  PNG.Free;
  SmallImg.Free;
  FullImg.Free;
  Bmp.Free;
end;

function HandleScreenshot(const ALine: string): string;
var
  Req: TDiagRequest;
begin
  if ExtractJStr(ALine, 'path') = '' then begin
    Result := '{' + JStr('error', 'missing path') + '}';
    Exit;
  end;
  Req.Line := ALine;
  RunOnMainThread(@DoScreenshot, PtrInt(@Req));
  Result := Req.Result;
end;

{ ===== Registration ======================================================== }

procedure DoRegisterAll;
begin
  RegisterDiagCommand('editors', @HandleEditors);
  RegisterDiagCommand('active_editor', @HandleActiveEditor);
  RegisterDiagCommand('get_source', @HandleGetSource);
  RegisterDiagCommand('set_source', @HandleSetSource);
  RegisterDiagCommand('get_selection', @HandleGetSelection);
  RegisterDiagCommand('set_selection', @HandleSetSelection);
  RegisterDiagCommand('cursor', @HandleCursor);
  RegisterDiagCommand('insert_line', @HandleInsertLine);
  RegisterDiagCommand('replace_lines', @HandleReplaceLines);
  RegisterDiagCommand('open_file', @HandleOpenFile);
  RegisterDiagCommand('close_file', @HandleCloseFile);
  RegisterDiagCommand('save_file', @HandleSaveFile);
  RegisterDiagCommand('save_all', @HandleSaveAll);
  RegisterDiagCommand('open_project', @HandleOpenProject);
  RegisterDiagCommand('project_info', @HandleProjectInfo);
  RegisterDiagCommand('project_files', @HandleProjectFiles);
  RegisterDiagCommand('tool_status', @HandleToolStatus);
  RegisterDiagCommand('list_desktops', @HandleListDesktops);
  RegisterDiagCommand('switch_desktop', @HandleSwitchDesktop);
  RegisterDiagCommand('undock', @HandleUndock);
  RegisterDiagCommand('dock', @HandleDock);
  RegisterDiagCommand('resize', @HandleResize);
  RegisterDiagCommand('move', @HandleMove);
  RegisterDiagCommand('dock_state', @HandleDockState);
  RegisterDiagCommand('screenshot', @HandleScreenshot);
end;

procedure RegisterIDEDiagCommands;
begin
  DoRegisterAll;
end;

initialization
  MainRunner := TMainThreadRunner.Create;

finalization
  FreeAndNil(MainRunner);

end.
