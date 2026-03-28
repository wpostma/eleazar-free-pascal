unit TestFormLifecycle;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  Forms, Controls, StdCtrls, LCLType,
  LazLoggerBase;

type

  { TFormLifecycleLog }

  TFormLifecycleLog = class
  private
    FEntries: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Log(const AMsg: string);
    procedure Clear;
    function HasEntry(const AMsg: string): Boolean;
    function IndexOf(const AMsg: string): Integer;
    function EntryBefore(const ABefore, AAfter: string): Boolean;
    function Count: Integer;
    function Text: string;
    function Entry(AIndex: Integer): string;
  end;

  { TLifecycleTestForm - form that logs its lifecycle events }

  TLifecycleTestForm = class(TCustomForm)
  private
    FLog: TFormLifecycleLog;
  protected
    procedure CreateWnd; override;
    procedure InitializeWnd; override;
    procedure DoShow; override;
    procedure DoFirstShow; override;
    procedure Activate; override;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    destructor Destroy; override;
    property Log: TFormLifecycleLog read FLog write FLog;
  end;

  { TLifecycleTestButton - button that logs its lifecycle events }

  TLifecycleTestButton = class(TButton)
  private
    FLog: TFormLifecycleLog;
  protected
    procedure CreateWnd; override;
    procedure InitializeWnd; override;
  public
    property Log: TFormLifecycleLog read FLog write FLog;
  end;

  { TTestFormLifecycle }

  TTestFormLifecycle = class(TTestCase)
  private
    FLog: TFormLifecycleLog;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestEmptyFormCreate;
    procedure TestEmptyFormCreateAndShow;
    procedure TestFormWithButtonCreate;
    procedure TestFormWithButtonCreateAndShow;
    procedure TestPhaseOrder_CreateBeforeShow;
    procedure TestNoHandleDuringFormUpdate;
    procedure TestNoShowDuringFormUpdate;
    procedure TestChildHandleAfterFormHandle;
    procedure TestPoDefault_CentersOnMonitor;
    procedure TestPoScreenCenter_CentersOnMonitor;
  end;

implementation

{ TFormLifecycleLog }

constructor TFormLifecycleLog.Create;
begin
  inherited Create;
  FEntries := TStringList.Create;
end;

destructor TFormLifecycleLog.Destroy;
begin
  FreeAndNil(FEntries);
  inherited Destroy;
end;

procedure TFormLifecycleLog.Log(const AMsg: string);
begin
  FEntries.Add(AMsg);
end;

procedure TFormLifecycleLog.Clear;
begin
  FEntries.Clear;
end;

function TFormLifecycleLog.HasEntry(const AMsg: string): Boolean;
begin
  Result := FEntries.IndexOf(AMsg) >= 0;
end;

function TFormLifecycleLog.IndexOf(const AMsg: string): Integer;
begin
  Result := FEntries.IndexOf(AMsg);
end;

function TFormLifecycleLog.EntryBefore(const ABefore, AAfter: string): Boolean;
var
  iBefore, iAfter: Integer;
begin
  iBefore := FEntries.IndexOf(ABefore);
  iAfter := FEntries.IndexOf(AAfter);
  Result := (iBefore >= 0) and (iAfter >= 0) and (iBefore < iAfter);
end;

function TFormLifecycleLog.Count: Integer;
begin
  Result := FEntries.Count;
end;

function TFormLifecycleLog.Text: string;
begin
  Result := FEntries.Text;
end;

function TFormLifecycleLog.Entry(AIndex: Integer): string;
begin
  Result := FEntries[AIndex];
end;

{ TLifecycleTestForm }

constructor TLifecycleTestForm.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);
  if Assigned(FLog) then
    FLog.Log('Form.CreateNew');
end;

destructor TLifecycleTestForm.Destroy;
begin
  if Assigned(FLog) then
    FLog.Log('Form.Destroy');
  inherited Destroy;
end;

procedure TLifecycleTestForm.CreateWnd;
begin
  if Assigned(FLog) then
    FLog.Log('Form.CreateWnd');
  inherited CreateWnd;
  if Assigned(FLog) then
    FLog.Log('Form.CreateWnd.Done');
end;

procedure TLifecycleTestForm.InitializeWnd;
begin
  if Assigned(FLog) then
    FLog.Log('Form.InitializeWnd');
  inherited InitializeWnd;
end;

procedure TLifecycleTestForm.DoShow;
begin
  if Assigned(FLog) then
    FLog.Log('Form.DoShow');
  inherited DoShow;
end;

procedure TLifecycleTestForm.DoFirstShow;
begin
  if Assigned(FLog) then
    FLog.Log('Form.DoFirstShow');
  inherited DoFirstShow;
end;

procedure TLifecycleTestForm.Activate;
begin
  if Assigned(FLog) then
    FLog.Log('Form.Activate');
  inherited Activate;
end;

{ TLifecycleTestButton }

procedure TLifecycleTestButton.CreateWnd;
begin
  if Assigned(FLog) then
    FLog.Log('Button.CreateWnd');
  inherited CreateWnd;
  if Assigned(FLog) then
    FLog.Log('Button.CreateWnd.Done');
end;

procedure TLifecycleTestButton.InitializeWnd;
begin
  if Assigned(FLog) then
    FLog.Log('Button.InitializeWnd');
  inherited InitializeWnd;
end;

{ TTestFormLifecycle }

procedure TTestFormLifecycle.SetUp;
begin
  FLog := TFormLifecycleLog.Create;
end;

procedure TTestFormLifecycle.TearDown;
begin
  FreeAndNil(FLog);
end;

procedure TTestFormLifecycle.TestEmptyFormCreate;
var
  F: TLifecycleTestForm;
begin
  // Creating a form without showing it should NOT allocate a handle
  F := TLifecycleTestForm.CreateNew(nil);
  try
    F.Log := FLog;
    FLog.Log('Form.Created');
    AssertFalse('Handle should not be allocated after CreateNew',
      F.HandleAllocated);
    AssertFalse('Form should not be Visible after CreateNew',
      F.Visible);
    AssertFalse('Form should not be Showing after CreateNew',
      F.Showing);
  finally
    F.Free;
  end;
end;

procedure TTestFormLifecycle.TestEmptyFormCreateAndShow;
var
  F: TLifecycleTestForm;
begin
  // Creating and showing a form should follow the lifecycle
  F := TLifecycleTestForm.CreateNew(nil);
  try
    F.Log := FLog;
    FLog.Log('Before.Show');

    F.Show;
    FLog.Log('After.Show');

    AssertTrue('Handle should be allocated after Show',
      F.HandleAllocated);
    AssertTrue('CreateWnd should have been called',
      FLog.HasEntry('Form.CreateWnd'));
    AssertTrue('InitializeWnd should have been called',
      FLog.HasEntry('Form.InitializeWnd'));

    // Phase order: CreateWnd must happen before DoShow
    if FLog.HasEntry('Form.DoShow') then
      AssertTrue('CreateWnd must come before DoShow',
        FLog.EntryBefore('Form.CreateWnd', 'Form.DoShow'));
  finally
    F.Close;
    F.Free;
  end;
end;

procedure TTestFormLifecycle.TestFormWithButtonCreate;
var
  F: TLifecycleTestForm;
  B: TLifecycleTestButton;
begin
  // Creating a form with a child button should NOT allocate any handles
  F := TLifecycleTestForm.CreateNew(nil);
  try
    F.Log := FLog;
    B := TLifecycleTestButton.Create(F);
    B.Log := FLog;
    B.Parent := F;
    FLog.Log('Button.Parented');

    AssertFalse('Form handle should not be allocated',
      F.HandleAllocated);
    AssertFalse('Button handle should not be allocated',
      B.HandleAllocated);
    AssertFalse('Button.CreateWnd should NOT have been called during parenting',
      FLog.HasEntry('Button.CreateWnd'));
  finally
    F.Free;
  end;
end;

procedure TTestFormLifecycle.TestFormWithButtonCreateAndShow;
var
  F: TLifecycleTestForm;
  B: TLifecycleTestButton;
begin
  // Create form, add button, then show. Both handles allocated at show time.
  F := TLifecycleTestForm.CreateNew(nil);
  try
    F.Log := FLog;
    B := TLifecycleTestButton.Create(F);
    B.Log := FLog;
    B.Parent := F;

    AssertFalse('No handles before Show', F.HandleAllocated);

    FLog.Log('Before.Show');
    F.Show;
    FLog.Log('After.Show');

    AssertTrue('Form handle should be allocated after Show',
      F.HandleAllocated);
    AssertTrue('Button handle should be allocated after Show',
      B.HandleAllocated);
    AssertTrue('Form.CreateWnd should have been called',
      FLog.HasEntry('Form.CreateWnd'));
    AssertTrue('Button.CreateWnd should have been called',
      FLog.HasEntry('Button.CreateWnd'));
  finally
    F.Close;
    F.Free;
  end;
end;

procedure TTestFormLifecycle.TestPhaseOrder_CreateBeforeShow;
var
  F: TLifecycleTestForm;
  B: TLifecycleTestButton;
begin
  // Verify: Form.CreateWnd → Button.CreateWnd → Form.DoShow
  F := TLifecycleTestForm.CreateNew(nil);
  try
    F.Log := FLog;
    B := TLifecycleTestButton.Create(F);
    B.Log := FLog;
    B.Parent := F;

    F.Show;

    AssertTrue('Form.CreateWnd must happen before Button.CreateWnd',
      FLog.EntryBefore('Form.CreateWnd', 'Button.CreateWnd'));

    if FLog.HasEntry('Form.DoShow') then begin
      AssertTrue('Form.CreateWnd must happen before Form.DoShow',
        FLog.EntryBefore('Form.CreateWnd', 'Form.DoShow'));
      AssertTrue('Button.CreateWnd must happen before Form.DoShow',
        FLog.EntryBefore('Button.CreateWnd', 'Form.DoShow'));
    end;
  finally
    F.Close;
    F.Free;
  end;
end;

procedure TTestFormLifecycle.TestNoHandleDuringFormUpdate;
var
  F: TLifecycleTestForm;
  B: TLifecycleTestButton;
begin
  // During BeginFormUpdate, inserting children must NOT create handles
  F := TLifecycleTestForm.CreateNew(nil);
  try
    F.Log := FLog;
    F.BeginFormUpdate;
    try
      B := TLifecycleTestButton.Create(F);
      B.Log := FLog;
      B.Parent := F;
      B.Visible := True;

      AssertFalse('Form handle must not exist during FormUpdate',
        F.HandleAllocated);
      AssertFalse('Button handle must not exist during FormUpdate',
        B.HandleAllocated);
      AssertFalse('Button.CreateWnd must not be called during FormUpdate',
        FLog.HasEntry('Button.CreateWnd'));
    finally
      F.EndFormUpdate;
    end;
  finally
    F.Free;
  end;
end;

procedure TTestFormLifecycle.TestNoShowDuringFormUpdate;
var
  F: TLifecycleTestForm;
begin
  // Form must not become Showing during BeginFormUpdate even if Visible is set
  F := TLifecycleTestForm.CreateNew(nil);
  try
    F.Log := FLog;
    F.BeginFormUpdate;
    try
      F.Visible := True;
      AssertFalse('Form must not be Showing during FormUpdate',
        F.Showing);
      AssertFalse('DoShow must not fire during FormUpdate',
        FLog.HasEntry('Form.DoShow'));
    finally
      F.EndFormUpdate;
    end;
  finally
    F.Close;
    F.Free;
  end;
end;

procedure TTestFormLifecycle.TestChildHandleAfterFormHandle;
var
  F: TLifecycleTestForm;
  B: TLifecycleTestButton;
begin
  // When the form creates its handle, children get handles too,
  // but AFTER the form's own handle is done.
  F := TLifecycleTestForm.CreateNew(nil);
  try
    F.Log := FLog;
    B := TLifecycleTestButton.Create(F);
    B.Log := FLog;
    B.Parent := F;

    // Explicitly allocate handle without showing
    F.HandleNeeded;

    AssertTrue('Form handle should exist', F.HandleAllocated);
    AssertTrue('Button handle should exist', B.HandleAllocated);
    AssertTrue('Form.CreateWnd called', FLog.HasEntry('Form.CreateWnd'));
    AssertTrue('Button.CreateWnd called', FLog.HasEntry('Button.CreateWnd'));
    // Button handle is created during Form.CreateWnd (child handle pass),
    // so Form.CreateWnd starts before Button.CreateWnd
    AssertTrue('Form.CreateWnd starts before Button.CreateWnd',
      FLog.EntryBefore('Form.CreateWnd', 'Button.CreateWnd'));
  finally
    F.Free;
  end;
end;

procedure TTestFormLifecycle.TestPoDefault_CentersOnMonitor;
var
  F: TLifecycleTestForm;
  WorkArea: TRect;
  aMonitor: TMonitor;
  ExpectedX, ExpectedY: Integer;
begin
  // poDefault should center the form on the primary monitor's work area
  F := TLifecycleTestForm.CreateNew(nil);
  try
    F.Log := FLog;
    F.Position := poDefault;
    F.Width := 400;
    F.Height := 300;

    F.Show;

    aMonitor := Screen.PrimaryMonitor;
    if aMonitor <> nil then
      WorkArea := aMonitor.WorkareaRect
    else
      WorkArea := Screen.WorkAreaRect;

    ExpectedX := WorkArea.Left + (WorkArea.Width - F.Width) div 2;
    ExpectedY := WorkArea.Top + (WorkArea.Height - F.Height) div 2;

    AssertTrue('poDefault: Left should be near center of monitor',
      Abs(F.Left - ExpectedX) < 50);
    AssertTrue('poDefault: Top should be near center of monitor',
      Abs(F.Top - ExpectedY) < 50);
  finally
    F.Close;
    F.Free;
  end;
end;

procedure TTestFormLifecycle.TestPoScreenCenter_CentersOnMonitor;
var
  F: TLifecycleTestForm;
  WorkArea: TRect;
  aMonitor: TMonitor;
  ExpectedX, ExpectedY: Integer;
begin
  // poScreenCenter should center the form on its monitor
  F := TLifecycleTestForm.CreateNew(nil);
  try
    F.Log := FLog;
    F.Position := poScreenCenter;
    F.Width := 400;
    F.Height := 300;

    F.Show;

    // poScreenCenter with DefaultMonitor=dmActiveForm and no active form
    // falls through to primary monitor in MoveToDefaultPosition
    aMonitor := Screen.PrimaryMonitor;
    if aMonitor <> nil then
      WorkArea := aMonitor.BoundsRect
    else
      WorkArea := Rect(0, 0, Screen.Width, Screen.Height);

    ExpectedX := WorkArea.Left + (WorkArea.Width - F.Width) div 2;
    ExpectedY := WorkArea.Top + (WorkArea.Height - F.Height) div 2;

    WriteLn(StdErr, '[TestPoScreenCenter] Form=', F.Left, ',', F.Top,
      ' Expected=', ExpectedX, ',', ExpectedY,
      ' WorkArea=', WorkArea.Left, ',', WorkArea.Top, ' ', WorkArea.Right - WorkArea.Left, 'x', WorkArea.Bottom - WorkArea.Top,
      ' FormSize=', F.Width, 'x', F.Height);

    AssertTrue('poScreenCenter: Left should be near center (actual=' + IntToStr(F.Left) + ' expected=' + IntToStr(ExpectedX) + ')',
      Abs(F.Left - ExpectedX) < 50);
    AssertTrue('poScreenCenter: Top should be near center (actual=' + IntToStr(F.Top) + ' expected=' + IntToStr(ExpectedY) + ')',
      Abs(F.Top - ExpectedY) < 50);
  finally
    F.Close;
    F.Free;
  end;
end;

initialization
  RegisterTest(TTestFormLifecycle);

end.
