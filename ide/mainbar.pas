{
 /***************************************************************************
                          mainbar.pp  -  Toolbar
                          ----------------------
  TMainIDEBar is the main window of the IDE, containing the menu and the
  component palette.

 ***************************************************************************/

 ***************************************************************************
 *                                                                         *
 *   This source is free software; you can redistribute it and/or modify   *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 *   This code is distributed in the hope that it will be useful, but      *
 *   WITHOUT ANY WARRANTY; without even the implied warranty of            *
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *
 *   General Public License for more details.                              *
 *                                                                         *
 *   A copy of the GNU General Public License is available on the World    *
 *   Wide Web at <http://www.gnu.org/copyleft/gpl.html>. You can also      *
 *   obtain it by writing to the Free Software Foundation,                 *
 *   Inc., 51 Franklin Street - Fifth Floor, Boston, MA 02110-1335, USA.   *
 *                                                                         *
 ***************************************************************************
}
unit MainBar;

{$mode objfpc}{$H+}

interface

{$I ide.inc}

uses
{$IFDEF IDE_MEM_CHECK}
  MemCheck,
{$ENDIF}
  Classes, SysUtils, Math,
  // LCL
  Forms, Controls, Menus, ComCtrls, ExtCtrls, LMessages, LCLDiagServer,
{$IF DEFINED(LCLGtk) OR DEFINED(LCLQt)}
  LCLIntf,
{$ENDIF}
  // LazUtils
  LazLoggerBase, LazFileCache,
  // BuildIntf
  ComponentReg,
  // IDEIntf
  MenuIntf, LazIDEIntf, IDEWindowIntf, IDEImagesIntf, IDECommands,
  // IdeConfig
  CoolBarOptions,
  // IDE
  LazarusIDEStrConsts, IdeCoolbarData, EnvGuiOptions;

type
  // Mirror of AnchorDocking.IDockManagerActions. Same GUID and layout so
  // Supports() matches at runtime — this lets mainbar avoid a compile-time
  // dep on the anchordocking package (which isn't linked into lazbuild).
  TDockResizeRequest = record
    DesiredTopAreaHeight: Integer;
    DesiredBottomAreaHeight: Integer;
    DesiredLeftAreaWidth: Integer;
    DesiredRightAreaWidth: Integer;
    Valid: Boolean;
  end;

  IDockManagerActions = interface
    ['{7A8B2C4E-1D6F-4A3B-9E5C-8F2A1D4B7C3E}']
    function NotifyAfterRestoreLayout: TDockResizeRequest;
  end;

  { TMainIDEBar }

  TMainIDEBar = class(TForm, IDockManagerActions)
  private
    OptionsPopupMenu: TPopupMenu;
    FMainOwningComponent: TComponent;
    FOldWindowState: TWindowState;
    FOnActive: TNotifyEvent;
    FDidPostRestore: Boolean;
    procedure CreatePopupMenus(TheOwner: TComponent);
    function CalculateCoolbarHeight: Integer;
    function CalcNonClientHeight: Integer;
    function FindCompScrollBox: TScrollBox;
  protected
    procedure DoActive;
    procedure DoShow; override;
    procedure WndProc(var Message: TLMessage); override;
    procedure Resizing(State: TWindowState); override;
  public
    ApplicationIsActivate: boolean;
    LastCompPaletteForm: TCustomForm;
    //Coolbar and PopUpMenus
    CoolBar: TCoolBar;
    OptionsMenuItem: TMenuItem;
    NewUFSetDefaultMenuItem: TMenuItem;
    ComponentPageControl: TPageControl; // component palette
    //GlobalMouseSpeedButton: TSpeedButton; <- what is this
    MainSplitter: TSplitter;        // splitter between the Coolbar and MainMenu
    // MainMenu
    mnuMainMenu: TMainMenu;
    //mnuMain: TIDEMenuSection;

    // file menu
    //mnuFile: TIDEMenuSection;
      //itmFileNew: TIDEMenuSection;
        itmFileNewUnit: TIDEMenuCommand;
        itmFileNewForm: TIDEMenuCommand;
        itmFileNewOther: TIDEMenuCommand;
      //itmFileOpenSave: TIDEMenuSection;
        itmFileOpen: TIDEMenuCommand;
        itmFileRevert: TIDEMenuCommand;
        itmFileOpenUnit: TIDEMenuCommand;
        //itmFileRecentOpen: TIDEMenuSection;
        itmFileSave: TIDEMenuCommand;
        itmFileSaveAs: TIDEMenuCommand;
        itmFileSaveAll: TIDEMenuCommand;
        itmFileExportHtml: TIDEMenuCommand;
        itmFileClose: TIDEMenuCommand;
      //itmFileDirectories: TIDEMenuSection;
        itmFileCleanDirectory: TIDEMenuCommand;
      //itmFileIDEStart: TIDEMenuSection;
        itmFileRestart: TIDEMenuCommand;
        itmFileQuit: TIDEMenuCommand;

    // edit menu
    //mnuEdit: TIDEMenuSection;
      //itmEditReUndo: TIDEMenuSection;
        itmEditUndo: TIDEMenuCommand;
        itmEditRedo: TIDEMenuCommand;
      //itmEditClipboard: TIDEMenuSection;
        itmEditCut: TIDEMenuCommand;
        itmEditCopy: TIDEMenuCommand;
        itmEditPaste: TIDEMenuCommand;
        itmEditMultiPaste: TIDEMenuCommand;
      //itmEditSelect: TIDEMenuSection;
        itmEditSelectAll: TIDEMenuCommand;
        itmEditSelectToBrace: TIDEMenuCommand;
        itmEditSelectCodeBlock: TIDEMenuCommand;
        itmEditSelectWord: TIDEMenuCommand;
        itmEditSelectLine: TIDEMenuCommand;
        itmEditSelectParagraph: TIDEMenuCommand;
      //itmEditBlockActions: TIDEMenuSection;
        itmEditIndentBlock: TIDEMenuCommand;
        itmEditUnindentBlock: TIDEMenuCommand;
        itmEditUpperCaseBlock: TIDEMenuCommand;
        itmEditLowerCaseBlock: TIDEMenuCommand;
        itmEditSwapCaseBlock: TIDEMenuCommand;
        itmEditSortBlock: TIDEMenuCommand;
        itmEditTabsToSpacesBlock: TIDEMenuCommand;
        itmEditSelectionBreakLines: TIDEMenuCommand;
      //itmEditInsertions: TIDEMenuSection;

    // search menu
    //mnuSearch: TIDEMenuSection;
      //itmSearchFindReplace: TIDEMenuSection;
        itmSearchFind: TIDEMenuCommand;
        itmSearchFindNext: TIDEMenuCommand;
        itmSearchFindPrevious: TIDEMenuCommand;
        itmSearchFindInFiles: TIDEMenuCommand;
        itmSearchReplace: TIDEMenuCommand;
        itmIncrementalFind: TIDEMenuCommand;
      //itmJumpings: TIDEMenuSection;
        itmGotoLine: TIDEMenuCommand;
        itmJumpBack: TIDEMenuCommand;
        itmJumpForward: TIDEMenuCommand;
        itmAddJumpPoint: TIDEMenuCommand;
        itmJumpToNextError: TIDEMenuCommand;
        itmJumpToPrevError: TIDEMenuCommand;
        itmJumpToInterface: TIDEMenuCommand;
        itmJumpToInterfaceUses: TIDEMenuCommand;
        itmJumpToImplementation: TIDEMenuCommand;
        itmJumpToImplementationUses: TIDEMenuCommand;
        itmJumpToInitialization: TIDEMenuCommand;
      //itmBookmarks: TIDEMenuSection;
        itmSetFreeBookmark: TIDEMenuCommand;
        itmJumpToNextBookmark: TIDEMenuCommand;
        itmJumpToPrevBookmark: TIDEMenuCommand;
      //itmCodeToolSearches: TIDEMenuSection;
        itmFindDeclaration: TIDEMenuCommand;
        itmFindBlockOtherEnd: TIDEMenuCommand;
        itmFindBlockStart: TIDEMenuCommand;
        itmOpenFileAtCursor: TIDEMenuCommand;
        itmGotoIncludeDirective: TIDEMenuCommand;
        itmSearchFindIdentifierRefs: TIDEMenuCommand;
        itmSearchProcedureList: TIDEMenuCommand;

    // view menu
    //mnuView: TIDEMenuSection;
      //itmViewMainWindows: TIDEMenuSection;
        itmViewToggleFormUnit: TIDEMenuCommand;
        itmViewInspector: TIDEMenuCommand;
        itmViewSourceEditor: TIDEMenuCommand;
        itmViewCodeExplorer: TIDEMenuCommand;
        itmViewFPDocEditor: TIDEMenuCommand;
        itmViewCodeBrowser: TIDEMenuCommand;
        itmSourceUnitDependencies: TIDEMenuCommand;
        itmViewRestrictionBrowser: TIDEMenuCommand;
        itmViewComponents: TIDEMenuCommand;
        itmJumpHistory: TIDEMenuCommand;
        itmMacroListView: TIDEMenuCommand;
      //itmViewSecondaryWindows: TIDEMenuSection;
        itmViewAnchorEditor: TIDEMenuCommand;
        itmViewTabOrder: TIDEMenuCommand;
        itmViewMessage: TIDEMenuCommand;
        itmViewSearchResults: TIDEMenuCommand;
        //itmViewDebugWindows: TIDEMenuSection;
          itmViewWatches: TIDEMenuCommand;
          itmViewBreakpoints: TIDEMenuCommand;
          itmViewLocals: TIDEMenuCommand;
          itmRunMenuInspect: TIDEMenuCommand;
          itmViewRegisters: TIDEMenuCommand;
          itmViewCallStack: TIDEMenuCommand;
          itmViewThreads: TIDEMenuCommand;
          itmViewAssembler: TIDEMenuCommand;
          itmViewMemViewer: TIDEMenuCommand;
          itmViewDebugOutput: TIDEMenuCommand;
          itmViewDebugEvents: TIDEMenuCommand;
          itmViewPseudoTerminal: TIDEMenuCommand;
          itmViewDbgHistory: TIDEMenuCommand;
        //itmViewIDEInternalsWindows: TIDEMenuSection;
          itmViewFPCInfo: TIDEMenuCommand;
          itmViewIDEInfo: TIDEMenuCommand;
          itmViewNeedBuild: TIDEMenuCommand;
          itmSearchInFPDocFiles: TIDEMenuCommand;

    // source menu
    //mnuSource: TIDEMenuSection;
      //itmSourceBlockActions: TIDEMenuSection;
        itmSourceCommentBlock: TIDEMenuCommand;
        itmSourceUncommentBlock: TIDEMenuCommand;
        itmSourceToggleComment: TIDEMenuCommand;
        itmSourceEncloseBlock: TIDEMenuCommand;
        itmSourceEncloseInIFDEF: TIDEMenuCommand;
        itmSourceCompleteCodeInteractive: TIDEMenuCommand;
        itmSourceUseUnit: TIDEMenuCommand;
      //itmSourceCodeToolChecks: TIDEMenuSection;
        itmSourceSyntaxCheck: TIDEMenuCommand;
        itmSourceGuessUnclosedBlock: TIDEMenuCommand;
        {$IFDEF GuessMisplacedIfdef}
        itmSourceGuessMisplacedIFDEF: TIDEMenuCommand;
        {$ENDIF}
      //itmSourceInsertCVSKeyWord: TIDEMenuSection;
        itmSourceInsertCVSAuthor: TIDEMenuCommand;
        itmSourceInsertCVSDate: TIDEMenuCommand;
        itmSourceInsertCVSHeader: TIDEMenuCommand;
        itmSourceInsertCVSID: TIDEMenuCommand;
        itmSourceInsertCVSLog: TIDEMenuCommand;
        itmSourceInsertCVSName: TIDEMenuCommand;
        itmSourceInsertCVSRevision: TIDEMenuCommand;
        itmSourceInsertCVSSource: TIDEMenuCommand;
      //itmSourceInsertGeneral: TIDEMenuSection;
        itmSourceInsertGPLNotice: TIDEMenuCommand;
        itmSourceInsertGPLNoticeTranslated: TIDEMenuCommand;
        itmSourceInsertLGPLNotice: TIDEMenuCommand;
        itmSourceInsertLGPLNoticeTranslated: TIDEMenuCommand;
        itmSourceInsertModifiedLGPLNotice: TIDEMenuCommand;
        itmSourceInsertModifiedLGPLNoticeTranslated: TIDEMenuCommand;
        itmSourceInsertMITNotice: TIDEMenuCommand;
        itmSourceInsertMITNoticeTranslated: TIDEMenuCommand;
        itmSourceInsertUsername: TIDEMenuCommand;
        itmSourceInsertDateTime: TIDEMenuCommand;
        itmSourceInsertChangeLogEntry: TIDEMenuCommand;
        itmSourceInsertGUID: TIDEMenuCommand;
        itmSourceInsertTodo: TIDEMenuCommand;
      itmSourceInsertFilename: TIDEMenuCommand;
    // itmSourceTools
      itmSourceUnitInfo: TIDEMenuCommand;

    // refactor menu
    //mnuRefactor: TIDEMenuSection;
      //itmRefactorCodeTools: TIDEMenuSection;
        itmRefactorRenameIdentifier: TIDEMenuCommand;
        itmRefactorExtractProc: TIDEMenuCommand;
        itmRefactorInvertAssignment: TIDEMenuCommand;
      //itmRefactorAdvanced: TIDEMenuSection;
        itmRefactorShowAbstractMethods: TIDEMenuCommand;
        itmRefactorShowEmptyMethods: TIDEMenuCommand;
        itmRefactorShowUnusedUnits: TIDEMenuCommand;
        itmRefactorFindOverloads: TIDEMenuCommand;
      //itmRefactorTools: TIDEMenuSection;
        itmRefactorMakeResourceString: TIDEMenuCommand;

    // project menu
    //mnuProject: TIDEMenuSection;
      //itmProjectNewSection: TIDEMenuSection;
        itmProjectNew: TIDEMenuCommand;
        itmProjectNewFromFile: TIDEMenuCommand;
      //itmProjectOpenSection: TIDEMenuSection;
        itmProjectOpen: TIDEMenuCommand;
        //itmProjectRecentOpen: TIDEMenuSection;
        itmProjectClose: TIDEMenuCommand;
      //itmProjectSaveSection: TIDEMenuSection;
        itmProjectSave: TIDEMenuCommand;
        itmProjectSaveAs: TIDEMenuCommand;
        itmProjectResaveFormsWithI18n: TIDEMenuCommand;
        itmProjectPublish: TIDEMenuCommand;
      //itmProjectWindowSection: TIDEMenuSection;
        itmProjectInspector: TIDEMenuCommand;
        itmProjectOptions: TIDEMenuCommand;
        //itmProjectCompilerOptions: TIDEMenuCommand;
      //itmProjectAddRemoveSection: TIDEMenuSection;
        itmProjectAddTo: TIDEMenuCommand;
        itmProjectRemoveFrom: TIDEMenuCommand;
        itmProjectRenameLowerCase: TIDEMenuCommand;
        itmProjectViewUnits: TIDEMenuCommand;
        itmProjectViewForms: TIDEMenuCommand;
        itmProjectViewSource: TIDEMenuCommand;

    // run menu
    //mnuRun: TIDEMenuSection;
      //itmRunBuilding: TIDEMenuSection;
        itmRunMenuCompile: TIDEMenuCommand;
        itmRunMenuBuild: TIDEMenuCommand;
        itmRunMenuQuickCompile: TIDEMenuCommand;
        itmRunMenuCleanUpAndBuild: TIDEMenuCommand;
        itmRunMenuBuildManyModes: TIDEMenuCommand;
        itmRunMenuAbortBuild: TIDEMenuCommand;
      //itmRunnning: TIDEMenuSection;
        itmRunMenuRunWithoutDebugging: TIDEMenuCommand;
        itmRunMenuRunWithDebugging: TIDEMenuCommand;
        itmRunMenuRun: TIDEMenuCommand;
        itmRunMenuPause: TIDEMenuCommand;
        itmRunMenuShowExecutionPoint: TIDEMenuCommand;
        itmRunMenuStepInto: TIDEMenuCommand;
        itmRunMenuStepOver: TIDEMenuCommand;
        itmRunMenuStepOut: TIDEMenuCommand;
        itmRunMenuContinueLastStep: TIDEMenuCommand;
        itmRunMenuStepToCursor: TIDEMenuCommand;
        itmRunMenuRunToCursor: TIDEMenuCommand;
        itmRunMenuStop: TIDEMenuCommand;
        itmRunMenuAttach: TIDEMenuCommand;
        itmRunMenuDetach: TIDEMenuCommand;
        itmRunMenuRunParameters: TIDEMenuCommand;
        itmRunMenuResetDebugger: TIDEMenuCommand;
      //itmRunBuildingFile: TIDEMenuSection;
        itmRunMenuBuildFile: TIDEMenuCommand;
        itmRunMenuRunFile: TIDEMenuCommand;
        itmRunMenuConfigBuildFile: TIDEMenuCommand;
      //itmRunDebugging: TIDEMenuSection;
        itmRunMenuEvaluate: TIDEMenuCommand;
        itmRunMenuAddWatch: TIDEMenuCommand;
        //itmRunMenuAddBreakpoint: TIDEMenuSection;
          itmRunMenuAddBpSource: TIDEMenuCommand;
          itmRunMenuAddBpAddress: TIDEMenuCommand;
          itmRunMenuAddBpWatchPoint: TIDEMenuCommand;

    // packages menu
    //mnuComponents: TIDEMenuSection;
      //itmPkgOpening: TIDEMenuSection;
        itmPkgNewPackage: TIDEMenuCommand;
        itmPkgOpenLoadedPackage: TIDEMenuCommand;
        itmPkgOpenPackageFile: TIDEMenuCommand;
        itmPkgOpenPackageOfCurUnit: TIDEMenuCommand;
        //itmPkgOpenRecent: TIDEMenuSection;
      //itmPkgUnits: TIDEMenuSection;
        itmPkgAddCurFileToPkg: TIDEMenuCommand;
        itmPkgAddNewComponentToPkg: TIDEMenuCommand;
      //itmPkgGraphSection: TIDEMenuSection;
        itmPkgPkgGraph: TIDEMenuCommand;
        itmPkgPackageLinks: TIDEMenuCommand;
        itmPkgEditInstallPkgs: TIDEMenuCommand;

    // tools menu
    //mnuTools: TIDEMenuSection;
      //itmOptionsDialogs: TIDEMenuSection;
        itmEnvGeneralOptions: TIDEMenuCommand;
        itmToolRescanFPCSrcDir: TIDEMenuCommand;
        itmEnvCodeTemplates: TIDEMenuCommand;
        itmEnvCodeToolsDefinesEditor: TIDEMenuCommand;
      //itmCustomTools: TIDEMenuSection;
        itmToolConfigure: TIDEMenuCommand;
      //itmSecondaryTools: TIDEMenuSection;
        itmToolDiff: TIDEMenuCommand;
      //itmDelphiConversion: TIDEMenuSection;
        itmToolCheckLFM: TIDEMenuCommand;
        itmToolConvertDelphiUnit: TIDEMenuCommand;
        itmToolConvertDelphiProject: TIDEMenuCommand;
        itmToolConvertDelphiPackage: TIDEMenuCommand;
        itmToolConvertDFMtoLFM: TIDEMenuCommand;
        itmToolConvertEncoding: TIDEMenuCommand;
      //itmBuildingLazarus: TIDEMenuSection;
        itmToolBuildLazarus: TIDEMenuCommand;
        itmToolConfigureBuildLazarus: TIDEMenuCommand;

    // windows menu
    //mnuWindow: TIDEMenuSection;
      //itmWindowManagers: TIDEMenuSection;
        itmWindowManager: TIDEMenuCommand;
        itmWindowManageDesktops: TIDEMenuCommand;

    // help menu
    //mnuHelp: TIDEMenuSection;
      //itmOnlineHelps: TIDEMenuSection;
        itmHelpOnlineHelp: TIDEMenuCommand;
        itmHelpReportingBug: TIDEMenuCommand;
        //itmHelpConfigureHelp: TIDEMenuCommand;
      //itmInfoHelps: TIDEMenuSection;
        itmHelpAboutLazarus: TIDEMenuCommand;
      //itmHelpTools: TIDEMenuSection;

    constructor Create(TheOwner: TComponent); override;
    procedure MainIDEBarDropFiles(Sender: TObject; const FileNames: array of String);
    procedure CoolBarOnChange(Sender: TObject);
    procedure MainSplitterMoved(Sender: TObject);
    procedure SetMainIDEHeightEvent(Sender: TObject);
    procedure MainBarActive(Sender: TObject);
    procedure Setup(TheOwner: TComponent);
    procedure SetupHints;
    procedure UpdateIDEComponentPalette(IfFormChanged: boolean);
    procedure HideIDE;
    procedure UnhideIDE;
    property OnActive: TNotifyEvent read FOnActive write FOnActive;
    procedure UpdateDockCaption({%H-}Exclude: TControl); override;
    procedure RefreshCoolbar;
    procedure SetMainIDEHeight;
    procedure DoSetMainIDEHeight(const AIDEIsMaximized: Boolean; ANewHeight: Integer = 0);
    procedure DoSetViewComponentPalette(aVisible: Boolean);
    procedure AllowCompilation(aAllow: Boolean);
    procedure InitPaletteAndCoolBar;
    function NotifyAfterRestoreLayout: TDockResizeRequest;
  end;

var
  MainIDEBar: TMainIDEBar = nil;

implementation

{ TMainIDEBar }

procedure TMainIDEBar.MainIDEBarDropFiles(Sender: TObject;
  const FileNames: array of String);
begin
  // the Drop event comes before the Application activate event or not at all
  // => invalidate file state
  InvalidateFileStateCache;
  LazarusIDE.DoDropFiles(Sender,FileNames);
end;

procedure TMainIDEBar.DoActive;
begin
  if Assigned(FOnActive) then
    FOnActive(Self);
end;

procedure TMainIDEBar.DoShow;
begin
  inherited DoShow;
  DebugLn('[TMainIDEBar.DoShow] Form is being shown, enabling resize timers');
  IDEWindowIntf.SetLayoutOperationInProgress(False); //TODO maybe this should be the responsibility of the docking manager!
  DebugLn('[TMainIDEBar.DoShow] Layout timers are now enabled');
end;

procedure TMainIDEBar.DoSetMainIDEHeight(const AIDEIsMaximized: Boolean; ANewHeight: Integer);
begin
  // No-op: height is managed by LCL/GTK natively in docked-only mode.
  // Post-restore adjustments happen once in NotifyAfterRestoreLayout.
end;

function TMainIDEBar.NotifyAfterRestoreLayout: TDockResizeRequest;
var
  CoolH, PalH, NonClient, Target, MinContent, I, BandBottom: Integer;
begin
  // Compute a stable target height for the dock site that hosts TMainIDEBar.
  // The controls' .Height fields are unreliable here: if the previous restore
  // collapsed the top strip, CoolBar.Height / ComponentPageControl.Height read
  // as 1px. Use content-based measures (band geometry, scaled defaults) that
  // survive a collapsed parent.
  Result := Default(TDockResizeRequest);
  if FDidPostRestore then Exit;
  FDidPostRestore := True;

  CoolH := 0;
  if (CoolBar <> nil) and CoolBar.Visible then
  begin
    for I := 0 to CoolBar.Bands.Count-1 do
    begin
      BandBottom := CoolBar.Bands[I].Top + CoolBar.Bands[I].Height;
      if BandBottom > CoolH then CoolH := BandBottom;
    end;
    if CoolH < Scale96ToForm(26) then CoolH := Scale96ToForm(26);
  end;

  PalH := 0;
  if (ComponentPageControl <> nil) and ComponentPageControl.Visible then
    PalH := Scale96ToForm(54); // one row of buttons + tab chrome

  NonClient := CalcNonClientHeight;
  MinContent := Scale96ToForm(110);
  Target := CoolH + PalH;
  if Target < MinContent then Target := MinContent;
  Target := Target + NonClient;
  if Target <= 0 then Exit;

  Result.Valid := True;
  Result.DesiredTopAreaHeight := Target;
  DebugLn('[TMainIDEBar.NotifyAfterRestoreLayout] coolbarContent=%d paletteContent=%d nonClient=%d minContent=%d target=%d',
    [CoolH, PalH, NonClient, MinContent, Target]);
end;

function TMainIDEBar.CalculateCoolbarHeight: Integer;
var
  NewHeight: Integer;
  I: Integer;
  CompScrollBox: TScrollBox;
  SBControl: TControl;
  CoolbarH: Integer;
begin
  Result := 0;
  if (EnvironmentGuiOpts=Nil) or (CoolBar=Nil) or (ComponentPageControl=Nil) then
  begin
    DebugLn('CalculateCoolbarHeight: Can''t calculate yet');
    Exit;
  end;

  CoolbarH := 0;
  // IDE Coolbar height
  if EnvironmentGuiOpts.Desktop.IDECoolBarOptions.Visible then
  begin
    for I := 0 to CoolBar.Bands.Count-1 do
    begin
      NewHeight := CoolBar.Bands[I].Top + CoolBar.Bands[I].Height;
      Assert(NewHeight >= 0, Format('TMainIDEBar.CalculateCoolbarHeight, IDE Coolbar: '+
        'NewHeight %d < 0. Band Top=%d, Band Height=%d.',
        [NewHeight, CoolBar.Bands[I].Top, CoolBar.Bands[I].Height]) );
      Result := Max(Result, NewHeight);
      DebugLn('[CalculateCoolbarHeight.Coolbar] Band[',dbgs(I),'] Top=',dbgs(CoolBar.Bands[I].Top),
        ' Height=',dbgs(CoolBar.Bands[I].Height),' NewHeight=',dbgs(NewHeight),' Result=',dbgs(Result));
    end;
    CoolbarH := Result;
  end;

  // Component palette height
  if EnvironmentGuiOpts.Desktop.ComponentPaletteOptions.Visible
  and Assigned(ComponentPageControl.ActivePage) then
  begin
    CompScrollBox := FindCompScrollBox;
    if CompScrollBox=Nil then
    begin
      DebugLn('[CalculateCoolbarHeight] No CompScrollBox found, returning coolbar height=',dbgs(Result));
      Exit;
    end;
    DebugLn('[CalculateCoolbarHeight.Palette] CompScrollBox.ControlCount=',dbgs(CompScrollBox.ControlCount),
      ' PageControl.Height=',dbgs(ComponentPageControl.Height),
      ' ScrollBox.ClientHeight=',dbgs(CompScrollBox.ClientHeight));
    for I := 0 to CompScrollBox.ControlCount-1 do
    begin
      SBControl := CompScrollBox.Controls[I];
      NewHeight := SBControl.Top + SBControl.Height +  //button height
        //page control non-client height (tabs, borders).
        ComponentPageControl.Height - CompScrollBox.ClientHeight;
      Assert(NewHeight >= 0, Format('TMainIDEBar.CalculateCoolbarHeight, Component palette : '+
        'NewHeight %d < 0. Cntrl.Top=%d, Cntrl.Height=%d, '+
        'PageControl.Height=%d, ScrollBox.ClientHeight=%d.',
        [NewHeight, SBControl.Top, SBControl.Height,
         ComponentPageControl.Height, CompScrollBox.ClientHeight]) );
      Result := Max(Result, NewHeight);
      DebugLn('[CalculateCoolbarHeight.Palette] Cntrl[',dbgs(I),'] Top=',dbgs(SBControl.Top),
        ' Height=',dbgs(SBControl.Height),' PageCtrlH-SBCliH=',
        dbgs(ComponentPageControl.Height - CompScrollBox.ClientHeight),
        ' NewHeight=',dbgs(NewHeight),' Result=',dbgs(Result));

      if not EnvironmentGuiOpts.Desktop.AutoAdjustIDEHeightFullCompPal then
        Break;  //we need only one button (we calculate one line only)
    end;
  end;

  DebugLn('[CalculateCoolbarHeight] FINAL: CoolbarH=',dbgs(CoolbarH),' PaletteH=',dbgs(Result));
end;

function TMainIDEBar.CalcNonClientHeight: Integer;
{$IF DEFINED(LCLGtk) OR DEFINED(LCLQt)}
var
  WindowRect, WindowClientRect: TRect;
{$ENDIF}
begin
  {
    This function is a bug-workaround for various LCL widgetsets.
    Every widgetset handles constrained height differently.
    In an ideal word (when the bugs are fixed), this function shouldn't be
    needed at all - it should return always 0.

    Currently tested: Win32, Gtk2, Carbon, Qt.

    List of bugs related to this workaround:
      http://bugs.freepascal.org/view.php?id=28033
      http://bugs.freepascal.org/view.php?id=28034
      http://bugs.freepascal.org/view.php?id=28036
  }
  if not Showing then
    Exit(0);

  {$IF DEFINED(LCLGtk) OR DEFINED(LCLQt)}
  //Gtk + Qt
  //retrieve real main menu height because
  // - Gtk, Qt:  SM_CYMENU does not work
  LclIntf.GetWindowRect(Handle, WindowRect{%H-});
  LclIntf.GetClientRect(Handle, WindowClientRect{%H-});
  LclIntf.ClientToScreen(Handle, WindowClientRect.TopLeft);

  Result := WindowClientRect.Top - WindowRect.Top;

  Assert(Result >= 0, 'TMainIDEBar.CalcNonClientHeight: Result '+IntToStr(Result)+' is below zero.');

  {$ELSE}
  //other widgetsets
  //Carbon tested - behaves correctly
  //Cocoa tested - behaves correctly
  //Win32 tested - behaves correctly
  //Gtk2 tested - behaves correctly
  //Qt5 tested - behaves correctly
  //Qt6 tested - behaves correctly
  Result := 0;
  {$ENDIF}
end;

function TMainIDEBar.FindCompScrollBox: TScrollBox;
var
  I: Integer;
begin
  for I := 0 to ComponentPageControl.ActivePage.ControlCount-1 do
    if (ComponentPageControl.ActivePage.Controls[I] is TScrollBox) then
      Exit(TScrollBox(ComponentPageControl.ActivePage.Controls[I]));
  Result := nil;
end;

procedure TMainIDEBar.SetMainIDEHeightEvent(Sender: TObject);
begin
  DebugLn('[SetMainIDEHeight] caller=SetMainIDEHeightEvent');
  SetMainIDEHeight;
end;

procedure TMainIDEBar.MainBarActive(Sender: TObject);
var
  i, FormCount: integer;
  AForm: TCustomForm;
begin
  if EnvironmentGuiOpts.Desktop.SingleTaskBarButton and not ApplicationIsActivate
  and (WindowState=wsNormal) then
  begin
    ApplicationIsActivate:=true;
    FormCount:=0;
    for i:=Screen.CustomFormCount-1 downto 0 do
    begin
      AForm:=Screen.CustomForms[i];
      if (AForm.Parent=nil) and (AForm<>Self) and (AForm.IsVisible)
      and not IsFormDesign(AForm)
      and not (fsModal in AForm.FormState) then
        inc(FormCount);
    end;
    while LazarusIDE.LastActivatedWindows.Count>0 do
    begin
      AForm:=TCustomForm(LazarusIDE.LastActivatedWindows[0]);
      if Assigned(AForm) and (not (CsDestroying in AForm.ComponentState)) and
      AForm.IsVisible then
        AForm.BringToFront;
      LazarusIDE.LastActivatedWindows.Delete(0);
    end;
    Self.BringToFront;
  end;
end;

procedure TMainIDEBar.WndProc(var Message: TLMessage);
begin
  inherited WndProc(Message);
  if (Message.Msg=LM_ACTIVATE) and (Message.Result=0) and (Lo(Message.WParam) <> WA_INACTIVE) then
    DoActive;
end;

procedure TMainIDEBar.UpdateDockCaption(Exclude: TControl);
begin
  // keep IDE caption
end;

constructor TMainIDEBar.Create(TheOwner: TComponent);
begin
  // This form has no resource => must be constructed using CreateNew
  inherited CreateNew(TheOwner, 1);
  DebugLogging := True;
  DebugLn('(mainbar) [TMainIDEBar.Create] after CreateNew Bounds=',dbgs(BoundsRect));
  AllowDropFiles:=true;
  Scaled:=true;
  OnDropFiles:=@MainIDEBarDropFiles;
  if Assigned(IDEDockMaster) then
    IDEDockMaster.SetMainDockWindow(Self);
  {$IFNDEF LCLGtk2}
  try
    Icon.LoadFromResourceName(HInstance, 'WIN_MAIN');
  except
  end;
  {$ENDIF}
end;

procedure TMainIDEBar.HideIDE;
begin
  if WindowState=wsMinimized then exit;
  FOldWindowState:=WindowState;
  WindowState:=wsMinimized;
end;

procedure TMainIDEBar.UnhideIDE;
begin
  WindowState:=FOldWindowState;
end;

procedure TMainIDEBar.CreatePopupMenus(TheOwner: TComponent);
begin
  OptionsPopupMenu := TPopupMenu.Create(TheOwner);
  OptionsPopupMenu.Images := IDEImages.Images_16;
  OptionsMenuItem := TMenuItem.Create(TheOwner);
  OptionsMenuItem.Name := 'miToolbarOption';
  OptionsMenuItem.Caption := lisMenuGeneralOptions;
  OptionsMenuItem.Enabled := True;
  OptionsMenuItem.Visible := True;
  OptionsMenuItem.ImageIndex := IDEImages.LoadImage('menu_environment_options');
  OptionsPopupMenu.Items.Add(OptionsMenuItem);
end;

procedure TMainIDEBar.Setup(TheOwner: TComponent);
begin
  DebugLn('[TMainIDEBar.Setup]');
  FMainOwningComponent := TheOwner;
  OnActive:=@MainBarActive;

  MainSplitter := TSplitter.Create(TheOwner);
  MainSplitter.Parent := Self;
  MainSplitter.Align := alLeft;
  MainSplitter.MinSize := 50;
  MainSplitter.OnMoved := @MainSplitterMoved;

  // IDE Coolbar
  CoolBar := TCoolBar.Create(TheOwner);
  CoolBar.Parent := Self;
  if EnvironmentGuiOpts.Desktop.ComponentPaletteOptions.Visible then
  begin
    CoolBar.Align := alLeft;
    CoolBar.Width := Scale96ToForm(EnvironmentGuiOpts.Desktop.IDECoolBarOptions.Width);
  end
  else
    CoolBar.Align := alClient;

  // IDE Coolbar object wraps the actual CoolBar.
  IDECoolBar := TIDECoolBar.Create(CoolBar);
  IDECoolBar.IsVisible := EnvironmentGuiOpts.Desktop.IDECoolBarOptions.Visible;
  CoolBar.OnChange := @CoolBarOnChange;
  CreatePopupMenus(TheOwner);
  CoolBar.PopupMenu := OptionsPopupMenu;

  // Component palette
  ComponentPageControl := TPageControl.Create(TheOwner);
  ComponentPageControl.Name := 'ComponentPageControl';
  ComponentPageControl.Align := alClient;
  ComponentPageControl.Visible := EnvironmentGuiOpts.Desktop.ComponentPaletteOptions.Visible;
  ComponentPageControl.Parent := Self;
end;

procedure TMainIDEBar.SetupHints;
var
  CurShowHint: boolean;
  AControl: TControl;
  i, j: integer;
begin
  if EnvironmentGuiOpts=nil then exit;
  // update all hints in the component palette
  CurShowHint:=EnvironmentGuiOpts.ShowHintsForComponentPalette;
  for i:=0 to ComponentPageControl.PageCount-1 do begin
    for j:=0 to ComponentPageControl.Page[i].ControlCount-1 do begin
      AControl:=ComponentPageControl.Page[i].Controls[j];
      AControl.ShowHint:=CurShowHint;
    end;
  end;
  // update all hints in main ide toolbars
  //??? CurShowHint:=EnvironmentGuiOpts.ShowHintsForMainSpeedButtons;
end;

procedure TMainIDEBar.UpdateIDEComponentPalette(IfFormChanged: boolean);
var
  LastActiveForm: TCustomForm;
begin
  // Package manager updates the palette initially.
  LastActiveForm := LazarusIDE.LastFormActivated;
  if not LazarusIDE.IDEStarted
  or (IfFormChanged and (LastCompPaletteForm=LastActiveForm)) then
    exit;
  LastCompPaletteForm := LastActiveForm;
  IDEComponentPalette.HideControls :=
    (LastActiveForm<>nil) and (LastActiveForm.Designer<>nil)
    and (LastActiveForm.Designer.LookupRoot<>nil)
    and not (LastActiveForm.Designer.LookupRoot is TControl);
  {$IFDEF VerboseComponentPalette}
  DebugLn(['* TMainIDEBar.UpdateIDEComponentPalette: Updating palette *',
           ', HideControls=', IDEComponentPalette.HideControls]);
  {$ENDIF}
  IDEComponentPalette.Update(False);
  SetupHints;
end;

procedure TMainIDEBar.InitPaletteAndCoolBar;
begin
  RefreshCoolbar;
  ComponentPageControl.OnChange(Self);//refresh component palette with button reposition
  DebugLn('[SetMainIDEHeight] caller=InitPaletteAndCoolBar');
  SetMainIDEHeight;
  if IDEDockMaster<>nil then
    IDEDockMaster.ResetSplitters;
end;

procedure TMainIDEBar.RefreshCoolbar;
var
  I: Integer;
  CoolBand: TCoolBand;
  CoolBarOpts: TIDECoolBarOptions;
  CurToolBar: TIDEToolBar;
begin
  CoolBarOpts := EnvironmentGuiOpts.Desktop.IDECoolBarOptions;
  //read general settings
  if not (CoolBarOpts.GrabStyle in [0..5]) then
    CoolBarOpts.GrabStyle := 4;
  Coolbar.GrabStyle := TGrabStyle(CoolBarOpts.GrabStyle);
  if not (CoolBarOpts.GrabWidth in [1..50]) then
    CoolBarOpts.GrabWidth := 5;
  Coolbar.GrabWidth := CoolBarOpts.GrabWidth;
  Coolbar.BandBorderStyle := TBorderStyle(CoolBarOpts.BorderStyle);
  Coolbar.Width := CoolBarOpts.Width;
  //read toolbars
  CoolBar.Bands.Clear;
  IDECoolBar.CopyFromOptions(CoolBarOpts);
  IDECoolBar.Sort;
  for I := 0 to IDECoolBar.ToolBars.Count - 1 do
  begin
    CurToolBar:=IDECoolBar.ToolBars[I];
    CurToolBar.ToolBar.BeginUpdate;
    try
      CoolBand := CoolBar.Bands.Add;
      CoolBand.Break := CurToolBar.CurrentOptions.Break;
      CoolBand.Control := CurToolBar.ToolBar;
      CoolBand.MinWidth := 25;
      CoolBand.MinHeight := 22;
      CoolBand.FixedSize := True;
      CurToolBar.UseCurrentOptions;
    finally
      CurToolBar.ToolBar.EndUpdate;
    end;
  end;
  CoolBar.AutoAdjustLayout(lapAutoAdjustForDPI, 96, PixelsPerInch, 0, 0);
  CoolBar.AutosizeBands;

  CoolBar.Visible := CoolBarOpts.Visible;
  MainSplitter.Align := alLeft;
  MainSplitter.Visible := Coolbar.Visible and ComponentPageControl.Visible;
end;

procedure TMainIDEBar.Resizing(State: TWindowState);
begin
  inherited Resizing(State);
end;

procedure TMainIDEBar.MainSplitterMoved(Sender: TObject);
begin
  EnvironmentGuiOpts.Desktop.IDECoolBarOptions.Width := ScaleFormTo96(CoolBar.Width);
  DebugLn('[SetMainIDEHeight] caller=MainSplitterMoved');
  SetMainIDEHeight;
end;

procedure TMainIDEBar.CoolBarOnChange(Sender: TObject);
begin
  IDECoolBar.CopyFromRealCoolbar(Coolbar);
  IDECoolBar.CopyToOptions(EnvironmentGuiOpts.Desktop.IDECoolBarOptions);
  DebugLn('[SetMainIDEHeight] caller=CoolBarOnChange');
  SetMainIDEHeight;
end;

procedure TMainIDEBar.SetMainIDEHeight;
begin
  DoSetMainIDEHeight(WindowState = wsMaximized);
end;

procedure TMainIDEBar.DoSetViewComponentPalette(aVisible: Boolean);
begin
  if aVisible = ComponentPageControl.Visible then Exit;
  ComponentPageControl.Visible := aVisible;
  EnvironmentGuiOpts.Desktop.ComponentPaletteOptions.Visible := aVisible;
  if aVisible then
  begin
    if CoolBar.Align = alClient then
    begin
      CoolBar.Width := 230;
      EnvironmentGuiOpts.Desktop.IDECoolBarOptions.Width := 230;
    end;
    CoolBar.Align := alLeft;
    CoolBar.Vertical := False;
    MainSplitter.Align := alLeft;
  end
  else
    CoolBar.Align := alClient;
  MainSplitter.Visible := Coolbar.Visible and aVisible;

  if aVisible then//when showing component palette, it must be visible to calculate it correctly
    //this will cause the IDE to flicker, but it's better than to have wrongly calculated IDE height
    DoSetMainIDEHeight(WindowState = wsMaximized, 55);
  DebugLn('[SetMainIDEHeight] caller=DoSetViewComponentPalette');
  SetMainIDEHeight;
end;

procedure TMainIDEBar.AllowCompilation(aAllow: Boolean);
// Enables or disables IDE GUI controls associated with compiling and building.
// ToDo: Perhaps it is worth combining with TDebugManager.UpdateButtonsAndMenuItems and TMainIDE.UpdateProjectCommands?
begin
  // Run menu
  itmRunMenuRunWithoutDebugging.Enabled := aAllow;
  itmRunMenuRunWithDebugging   .Enabled := aAllow;
  itmRunMenuRun                .Enabled := aAllow;
  itmRunMenuCompile            .Enabled := aAllow;
  itmRunMenuBuild              .Enabled := aAllow;
  itmRunMenuBuildManyModes     .Enabled := aAllow;
  itmRunMenuQuickCompile       .Enabled := aAllow;
  itmRunMenuCleanUpAndBuild    .Enabled := aAllow;
  itmRunMenuAbortBuild         .Enabled := not aAllow;
  // Package menu
  itmPkgEditInstallPkgs        .Enabled := aAllow;
  // Tools menu
  itmToolRescanFPCSrcDir       .Enabled := aAllow;
  itmToolBuildLazarus          .Enabled := aAllow;
  //itmToolConfigureBuildLazarus .Enabled := aAllow; // this dialog itself disables build buttons

  // IDE CoolBar
  IDECommandList.FindIDECommand(ecProjectChangeBuildMode).Enabled := aAllow;
end;

end.

