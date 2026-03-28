# Lazarus BigIDE Build Notes

## Build Command

```bash
make clean bigide
```

Uses whatever `fpc` is on PATH. To specify explicitly:

```bash
make clean bigide PP=/var/otherdev/freepascal/compiler/ppcx64
```

Currently building with FPC 3.3.1 (trunk) installed to `/usr/local/lib/fpc/3.3.1/`.
FPC source tree: `/var/otherdev/freepascal`
FPC config: `/usr/local/lib/fpc/etc/fpc.cfg`

## Output Binaries

| Binary | Size | Purpose |
|--------|------|---------|
| `lazarus` | 185 MB | Full IDE with docking + all packages |
| `lazbuild` | 55 MB | Command-line project/package builder (nogui) |
| `startlazarus` | 46 MB | Launcher/updater utility |
| `components/chmhelp/lhelp/lhelp` | 5 MB | CHM help viewer |

## BigIDE vs All

`make all` builds a minimal IDE (134 MB). `make bigide` adds ~30 extra packages
via `{$IFDEF BigIDE}` in `ide/lazarus.pp:75-87`. The critical difference: **docking
support (single-window mode) is only in bigide**.

## IDE Architecture

### Class Hierarchy (top-level)

```
TLazIDEInterface              components/ideintf/lazideintf.pas
  └─ TMainIDEInterface        ide/mainintf.pas:119
      └─ TMainIDEBase         ide/mainbase.pas:105
          └─ TMainIDE         ide/main.pp:187        ← central controller
```

`TMainIDEBar` (`ide/mainbar.pas:61`) is the actual main window form (menu + toolbar).

### Startup Flow

1. `lazarus.pp` → `TMainIDE.Create` → applies saved desktop
2. `TMainIDE.StartIDE` (`ide/main.pp:1691`) → `RestoreIDEWindows`
3. Desktop loads from XML, checks for `IDEDockMaster`
4. If AnchorDocking compiled in (bigide): `ProvideIDEDockMaster` checks
   `anchordockingoptions.xml` → `EnableAnchorDock` setting
5. First run shows "Modern (single window) vs Classic (floating)" dialog

## Core IDE Components

| Component | File | Class |
|-----------|------|-------|
| **Main Window** | `ide/mainbar.pas:61` | `TMainIDEBar` |
| **Central Controller** | `ide/main.pp:187` | `TMainIDE` |
| **Source Editor** | `ide/sourceeditor.pp:240` | `TSourceEditor` |
| **Source Editor Manager** | `ide/sourceeditor.pp:1156` | `TSourceEditorManager` |
| **Source Notebook (tabs)** | `ide/sourceeditor.pp:686` | `TSourceNotebook` |
| **Form Designer** | `designer/designer.pp:106` | `TDesigner` |
| **Form Editor** | `ide/customformeditor.pp:76` | `TCustomFormEditor` |
| **Object Inspector** | `components/ideintf/objectinspector.pp:628` | `TObjectInspectorDlg` |
| **Component Palette** | `ide/componentpalette.pas:98` | `TComponentPalette` |
| **Project Inspector** | `ide/projectinspector.pas:128` | `TProjectInspectorForm` |
| **Messages Window** | `ide/etmessageswnd.pas:49` | `TMessagesView` |
| **Code Explorer** | `ide/codeexplorer.pas:119` | `TCodeExplorerView` |
| **Package Manager** | `packager/pkgmanager.pas:95` | `TPkgManager` |
| **Debug Manager** | `ide/debugmanager.pas:117` | `TDebugManager` |

### Debugger Windows (in `ide/packages/idedebugger/`)

| Window | File | Class |
|--------|------|-------|
| Watch List | `watchesdlg.pp:76` | `TWatchesDlg` |
| Call Stack | `callstackdlg.pp:59` | `TCallStackDlg` |
| Breakpoints | `breakpointsdlg.pp:57` | `TBreakPointsDlg` |
| Local Variables | `localsdlg.pp:64` | `TLocalsDlg` |
| Inspect | `inspectdlg.pas:60` | `TIDEInspectDlg` |
| Assembler | `assemblerdlg.pp:71` | `TAssemblerDlg` |

## BigIDE Extra Packages

These are compiled in only with `make bigide` (`{$IFDEF BigIDE}`):

### Docking & Layout
| Unit | Directory | Description |
|------|-----------|-------------|
| AnchorDockingDsgn | `components/anchordocking/design/` | Single-window docking system |
| DockedFormEditor | `components/dockedformeditor/` | Form designer inside docked layout |

### Editor & Code Tools
| Unit | Directory | Description |
|------|-----------|-------------|
| AllSynEditDsgn | `components/synedit/design/` | Design-time SynEdit highlighter registration |
| jcfidelazarus | `components/jcf2/IdePlugin/lazarus/` | JEDI Code Format — Pascal code beautifier |
| EditorMacroScript | `components/macroscript/` | Editor macro recording via PascalScript |
| pascalscript | `components/PascalScript/Source/` | Pascal scripting engine |
| charactermap_ide_pkg | `components/charactermap/design/` | Character map insert tool |

### Testing
| Unit | Directory | Description |
|------|-----------|-------------|
| FPCUnitTestRunner | `components/fpcunit/` | GUI test runner for FPCUnit |
| FPCUnitIDE | `components/fpcunit/ide/` | FPCUnit IDE integration + TestInsight |

### Data & Database
| Unit | Directory | Description |
|------|-----------|-------------|
| SQLDBLaz | `components/sqldb/` | FCL SQL database components |
| DBFLaz | `components/tdbf/` | DBase (DBF) data access |
| MemDSLaz | `components/memds/` | In-memory dataset |
| SDFLaz | `components/sdf/` | Self-Describing Format data access |
| RunTimeTypeInfoControls | `components/rtticontrols/` | RTTI-based property controls |

### Visualization & UI
| Unit | Directory | Description |
|------|-----------|-------------|
| TAChartLazarusPkg | `components/tachart/` | Charting/graphing library |
| DateTimeCtrlsDsgn | `components/datetimectrls/design/` | Date/time picker controls |
| DateTimeCtrls | `components/datetimectrls/` | Date/time controls runtime |
| TurboPowerIPro | `components/turbopower_ipro/` | HTML rendering component |
| TurboPowerIProDsgn | `components/turbopower_ipro/design/` | HTML component design-time |

### Printing
| Unit | Directory | Description |
|------|-----------|-------------|
| Printer4Lazarus | `components/printers/` | Cross-platform printer support |
| Printers4LazIDE | `components/printers/design/` | IDE source code printing |

### Project & Package Management
| Unit | Directory | Description |
|------|-----------|-------------|
| ProjTemplates | `components/projecttemplates/` | Project template system |
| LazProjectGroups | `components/projectgroups/` | Multi-project groups |
| OnlinePackageManager | `components/onlinepackagemanager/` | Online package installer |
| ExampleProjects | `components/exampleswindow/` | Example project browser |

### Web & Transpiler
| Unit | Directory | Description |
|------|-----------|-------------|
| Pas2jsDsgn | `components/pas2js/` | Pascal-to-JavaScript support |
| SimpleWebServerGUI | `components/simplewebservergui/` | Dev web server for pas2js |

### Help & Debugging
| Unit | Directory | Description |
|------|-----------|-------------|
| chmhelppkg | `components/chmhelp/packages/idehelp/` | CHM help file viewer |
| ExternHelp | `components/externhelp/` | External help system |
| LeakView | `components/leakview/` | Heap trace memory leak viewer |
| TodoListLaz | `components/todolist/` | TODO/DONE task list panel |
| InstantFPCLaz | `components/instantfpc/` | Instant FPC compilation |

## Docking System Detail

### Key Files
- `components/anchordocking/anchordocking.pas` — core docking engine (311 KB)
- `components/anchordocking/anchordockstorage.pas` — save/load layouts
- `components/anchordocking/design/registeranchordocking.pas` — IDE integration
- `components/anchordocking/design/anchordesktopoptions.pas` — global options
- `components/anchordocking/design/anchordockdsgninitialsetupframe.pas` — first-run dialog

### Decision Flow
1. `ProvideIDEDockMaster` (`registeranchordocking.pas:535`) loads `anchordockingoptions.xml`
2. If `EnableAnchorDock = True` → creates `TIDEAnchorDockMaster` → docked mode
3. If `EnableAnchorDock = False` → `IDEDockMaster` stays nil → floating windows
4. No command-line flag — docking is compile-time (bigide) + config-time (xml)
5. Can toggle later: Tools → Options → Anchor Docking → Enable

## Widget Sets

Default on Linux: GTK2. Override with `LCL_PLATFORM`:

```bash
make clean bigide LCL_PLATFORM=gtk2   # default
make clean bigide LCL_PLATFORM=gtk3   # experimental
make clean bigide LCL_PLATFORM=qt5    # needs qtbase5-dev
make clean bigide LCL_PLATFORM=qt6    # needs qt6-base-dev
```

Available backends in `lcl/interfaces/`:
gtk (obsolete), gtk2, gtk3, qt, qt5, qt6, cocoa, carbon, win32, wince,
customdrawn, fpgui, nogui, mui, testmock

## Ubuntu 24.04 Dependencies

### Installed (sufficient for GTK2 bigide build)
- build-essential, git, gdb, binutils
- libgtk2.0-dev (2.24.33), libgtk-3-dev (3.24.41)
- libcairo2-dev, libpango1.0-dev, libglib2.0-dev
- libgdk-pixbuf-2.0-dev, libatk1.0-dev, libx11-dev

### Optional (for Qt widget sets)
- qtbase5-dev, libqt5x11extras5-dev (Qt5)
- qt6-base-dev (Qt6)

### Not needed
- No ancient GTK vendoring required — GTK2 and GTK3 are in Ubuntu Noble repos
- GTK1 backend exists but is obsolete
