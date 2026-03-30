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
  Classes, SysUtils, Forms, Controls,
  LCLDiagServer,
  LazIDEIntf, SrcEditorIntf, ProjectIntf;

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

procedure RunOnMainThread(AProc: TDiagMainProc; AParam: PtrInt);
begin
  if GetCurrentThreadId = MainThreadID then begin
    AProc(AParam);
    Exit;
  end;
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
