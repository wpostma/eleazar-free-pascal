# LCL Component Hierarchy: Enable/Disable and Related Method Pairs

The Lazarus Component Library (LCL) is highly derivative of the VCL (Visual Component Library) from Borland and Embarcadero's Delphi.

This document maps all complementary method pairs in the LCL (Lazarus Component Library) that work together to control component behavior, documents the parent-propagation protocol, and catalogs known bugs where pairs are mismatched or unprotected.

It is the author's opinion that the LCL lacks the rigor and the careful design inherent in the VCL's original design, and that problems in here, especially problems with DisableAutoSizing, EnableAutoSizing, render the LCL fundamentally broken, in its current released state.

## Overview

The LCL uses several patterns of paired methods to temporarily suspend and resume functionality:
- **Enable/Disable** - Component visibility/interaction
- **Begin/End** - Update operations
- **Lock/Unlock** - Bounds operations
- **OnChanging/OnChanged** - Event hooks

All counter-based pairs share the same fundamental contract: every Disable/Begin/Lock MUST be matched by exactly one Enable/End/Unlock. If an exception is raised between the two calls and there is no `try/finally`, the counter is permanently corrupted.

---

## Class Hierarchy

### Base Classes

```
TComponent (RTL base)
  |
TLCLComponent (LCL-specific)
  |
TControl (Visual component base)
  +-- TGraphicControl (no native window handle)
  +-- TWinControl (has native window handle)
       +-- TCustomControl
       +-- TCustomScrollBar
       +-- TCustomGroupBox
       +-- TCustomComboBox
       +-- TCustomListBox
       +-- TCustomEdit
       +-- TCustomStaticText
       +-- TButtonControl
       +-- TCustomCalendar
       +-- TCustomForm
       +-- ... (many more)
```

---

## Method Pairs by Category

### 1. **AutoSizing Pair** (Bounds/Layout Control)

**Classes:** `TControl` and descendants

**Purpose:** Temporarily suspend automatic sizing calculations while making multiple property changes

**Actual Effect:** Crashes, hangs, stack overflows, and non-responding applications.  At least as used in mainbar.pas. See RESIZE_LOOP_SEGFAULT.md.


#### Declarations (controls.pp)
```pascal
procedure DisableAutoSizing(const Reason: string);
procedure EnableAutoSizing(const Reason: string);
```

The `Reason` parameter is always required. It appears in every `DebugLn` call unconditionally. Under `{$IFDEF DebugDisableAutoSizing}`, reasons are also accumulated in `FAutoSizingLockReasons: TStrings` for post-mortem debugging, but this has RAM cost and is off by default.

**Implementation Mechanism:**
- Uses `FAutoSizingLockCount` to track nesting depth
- Lock count incremented by `DisableAutoSizing`
- Lock count decremented by `EnableAutoSizing`
- When count reaches 0, pending auto-size operations are processed

**Usage Pattern:**
```pascal
DisableAutoSizing('MyModule.MyProcedure');
try
  Control.Width := 200;
  Control.Height := 100;
  // ... other size-related changes
finally
  EnableAutoSizing('MyModule.MyProcedure');
end;
```

**Used By:**
- `TAnchorSide.SetSide()` (controls.pp)
- `TCustomButtonPanel` (buttonpanel.pas: multiple methods)
- `TCustomTaskDialog` (taskdlgemulation.pp)
- `TWinControl.InsertControl/RemoveControl` (wincontrol.inc)
- `TCustomForm.BeginFormUpdate/EndFormUpdate` (customform.inc)
- `TAnchorDockMaster` (anchordocking.pas — extensively)

**Debug Support:**
- `DebugLn` fires unconditionally on every Disable/Enable call with who, count, parent, reason, and action taken
- Conditional `{$IFDEF DebugDisableAutoSizing}` enables in-memory reason tracking via `FAutoSizingLockReasons: TStrings`
- `procedure WriteAutoSizeReasons(NotIfEmpty: Boolean)` dumps accumulated reasons (debug builds only)

**Related:**
- Property: `AutoSizingLockCount: Integer` (read-only)
- Virtual: `procedure DoAllAutoSize;` — Called to process pending resizes when count reaches 0 and Parent is nil

---

### 1a. **Parent-Propagation Protocol**

This is the most architecturally significant (and dangerous) aspect of `DisableAutoSizing`/`EnableAutoSizing`. Understanding it is essential for debugging layout bugs.

#### How It Works

**DisableAutoSizing:**
- Increments `FAutoSizingLockCount`
- **Only when count transitions 0 -> 1 AND Parent <> nil:** calls `Parent.DisableAutoSizing('child:' + DbgSName(Self))`
- This propagates recursively up the parent chain — grandparent, great-grandparent, etc.
- Nested calls (count already > 0) do NOT propagate again

**EnableAutoSizing:**
- Decrements `FAutoSizingLockCount`
- If count is still > 0: exits (other locks still active)
- **When count transitions to 0 AND Parent <> nil:** calls `Parent.EnableAutoSizing('child:' + DbgSName(Self))`
- **When count transitions to 0 AND Parent = nil:** calls `DoAllAutoSize` directly
- The Enable side has different fallback logic from the Disable side (see below)

#### Asymmetry Between Disable and Enable

| Condition | DisableAutoSizing | EnableAutoSizing |
|---|---|---|
| count transition AND Parent <> nil | Propagate to Parent | Propagate to Parent |
| count transition AND Parent = nil | **Does nothing** | **Calls DoAllAutoSize** |

This asymmetry means:
- If Parent is nil at Disable time but non-nil at Enable time, Enable propagates to a parent that was never Disabled (potential underflow/exception on parent)
- If Parent is non-nil at Disable time but nil at Enable time, the old parent stays locked forever (the Enable goes to `DoAllAutoSize` instead of back to the parent)

#### Reparenting Protocol: Insert() and Remove()

The LCL compensates for reparenting via `TWinControl.Insert()` and `TWinControl.Remove()`:

**Insert() (wincontrol.inc):** When a child with `FAutoSizingLockCount > 0` is inserted:
```pascal
if AControl.FAutoSizingLockCount > 0 then
  DisableAutoSizing('TControl.DisableAutoSizing');
```
The NEW parent gets one `DisableAutoSizing` call to account for the child's existing lock.

**Remove() (wincontrol.inc):** When a child with `FAutoSizingLockCount > 0` is removed:
```pascal
if AControl.FAutoSizingLockCount > 0 then
  EnableAutoSizing('TControl.DisableAutoSizing');
```
The OLD parent gets one `EnableAutoSizing` call to release the child's lock.

**SetParent()** wraps the whole operation:
```pascal
procedure TControl.SetParent(NewParent: TWinControl);
begin
  if FParent = NewParent then exit;
  DisableAutoSizing('TControl.SetParent');
  try
    if FParent <> nil then FParent.RemoveControl(Self);
    if NewParent <> nil then NewParent.InsertControl(Self);
  finally
    EnableAutoSizing('TControl.SetParent');
  end;
end;
```

**Verdict:** The reparenting protocol is correct — lock counts are properly maintained when a control moves between parents via SetParent/InsertControl/RemoveControl. The asymmetry documented above is only dangerous when Parent changes outside of SetParent (e.g., direct FParent assignment, or Parent becoming nil due to destruction during a Disable/Enable window).

---

### 2. **Bounds Update Pair** (SetBounds Prevention)

**Classes:** `TWinControl` and descendants

**Purpose:** Prevent `SetBounds` from executing while batching boundary changes

#### Declarations (controls.pp)
```pascal
procedure BeginUpdateBounds;  // disable SetBounds
procedure EndUpdateBounds;    // enable SetBounds
```

**Implementation:** Counter-based (`FUpdateBoundsLock`). Blocks physical bounds changes during updates.

**Failure Mode:** If `EndUpdateBounds` is missed, the control can never be moved or resized again. The control silently ignores all `SetBounds` calls. No error, no warning.

**Related Pair:**

```pascal
procedure LockRealizeBounds;    // disable sending bounds to widgetset
procedure UnlockRealizeBounds;  // enable sending bounds to widgetset
```

**Implementation:** Counter-based. Blocks only the GTK/Qt/Win32 side — internal LCL bounds are still updated, but the widget doesn't move on screen. If `UnlockRealizeBounds` is missed, the control's on-screen position diverges from its LCL position permanently.

---

### 3. **Alignment Control Pair**

**Classes:** `TWinControl` and descendants

**Purpose:** Temporarily disable child alignment calculations

#### Declarations (controls.pp)
```pascal
procedure DisableAlign;
procedure EnableAlign;
```

**Implementation:** Counter-based (`FAlignCount`). When `DisableAlign` is active, child controls are not re-aligned when bounds change.

**Interaction with AutoSizing:** `DisableAlign` calls `DisableAutoSizing('TWinControl.DisableAlign')`. `EnableAlign` calls `EnableAutoSizing('TWinControl.DisableAlign')`. This means DisableAlign/EnableAlign is a SUPERSET of DisableAutoSizing/EnableAutoSizing — it locks both alignment and auto-sizing.

**Note on reason string:** The `EnableAlign` call uses the reason string `'TWinControl.DisableAlign'` (not `'TWinControl.EnableAlign'`). This is correct — the reason should identify the original lock, not the unlock operation.

**Usage Pattern:**
```pascal
WinControl.DisableAlign;
try
  // Add or modify child controls
finally
  WinControl.EnableAlign;
end;
```

---

### 4. **Form Update Pair**

**Classes:** `TCustomForm` and descendants

**Purpose:** Bracket form construction to defer handle creation and showing until the form is fully built

#### Declarations (customform.inc)
```pascal
procedure BeginFormUpdate;
procedure EndFormUpdate;
```

**Implementation:**
- Counter-based (`FFormUpdateCount`)
- `BeginFormUpdate`: when count transitions 0 -> 1, calls `DisableAutoSizing('TCustomForm.BeginFormUpdate')`
- `EndFormUpdate`: when count transitions 1 -> 0, runs a multi-phase sequence:
  1. **Phase 1:** Set `wcfDeferShowing` on all child controls to prevent `gtk_widget_show` during auto-sizing
  2. **Phase 2:** Call `EnableAutoSizing` — this triggers handle creation, bounds computation, and realization, but showing is blocked by the defer flag
  3. **Phase 3:** Clear `wcfDeferShowing` and call `UpdateShowing` to display the form

**LCL-only weakness:** This multi-phase dance was added to fix a GTK-specific bug where showing half-built forms caused `size-allocate` storms. The VCL doesn't need this because Win32 handles `WM_SIZE` differently. The `wcfDeferShowing` flag is a Lazarus invention that interacts with `UpdateShowing` in ways that are fragile — if any code path clears the flag early or calls `Show` directly, the phasing breaks.

**Called automatically by:** `TCustomForm.CreateNew` (BeginFormUpdate) and `TCustomForm.AfterConstruction` (EndFormUpdate). This means form construction is always bracketed.

---

### 5. **Enabled/Disabled Pair** (Component Activity)

**Classes:** `TControl` and descendants

**Purpose:** Control whether component responds to user input and events

#### Declarations (controls.pp)
```pascal
procedure SetEnabled(Value: Boolean); virtual;
function GetEnabled: Boolean; virtual;

procedure EnabledChanging; virtual;
procedure EnabledChanged; virtual;
```

**Property:**
```pascal
property Enabled: Boolean read GetEnabled write SetEnabled
  stored IsEnabledStored default True;
```

**Event Hooks:**
- `chtOnEnabledChanging` — Called before enabled state changes
- `chtOnEnabledChanged` — Called after enabled state changes
- `CM_ENABLEDCHANGED` message for child notification

**VCL heritage:** This is a direct VCL design. No LCL-specific weakness here. The `IsEnabled` function checks the parent chain, which is the correct Delphi behavior.

**Utility Functions:**
```pascal
function IsEnabled: Boolean;           // checks parent too (inheritance)
```

---

### 6. **Visibility State Pair**

**Classes:** `TControl` and descendants

**Virtual Methods:**
```pascal
procedure VisibleChanging; virtual;
procedure VisibleChanged; virtual;
```

Similar to the Enabled pair — provides hooks around visibility changes. VCL-compatible.

---

### 7. **Update Pairs** (Collection/Container Operations)

Used across multiple specialized components for batch updates.

#### TDockManager (controls.pp)
```pascal
procedure BeginUpdate; virtual;
procedure EndUpdate; virtual;
```

#### TCustomListView (comctrls.pp)
```pascal
procedure BeginUpdate; virtual;
procedure EndUpdate; virtual;
```

Platform-specific implementations in gtk/gtk2/gtk3/qt/qt5/qt6/win32/wince widgetset units.

#### TStatusBar, TCustomPage, TCustomTabControl, TCustomListView Items, TCustomTreeView, TCustomProgressBar, TCustomTrackBar
All follow the same `BeginUpdate`/`EndUpdate` pattern with counter-based locking.

**LCL weakness in TCustomTreeView:** The `EndUpdate` calls `Invalidate` which on GTK can trigger synchronous repaints, potentially re-entering update logic. The VCL's `EndUpdate` on Win32 is safe because `InvalidateRect` is always asynchronous.

---

### 8. **Image/Resource Updates**

#### TImageList (imglist.pp)
```pascal
procedure BeginUpdate;
procedure EndUpdate;
```

#### TBitmap (graphics.pp)
```pascal
procedure BeginUpdate(ACanvasOnly: Boolean = False);
procedure EndUpdate(AStreamIsValid: Boolean = False);
```

**LCL-specific:** The `ACanvasOnly` and `AStreamIsValid` parameters are Lazarus additions to optimize partial updates. The VCL's `TBitmap` has no `BeginUpdate`/`EndUpdate` at all — this is entirely LCL-only.

---

### 9. **Toolbar/Control Bar Updates**

#### TToolBar (toolwin.pp)
```pascal
procedure BeginUpdate; virtual;
procedure EndUpdate; virtual;
```

---

### 10. **Component-Specific Pairs**

#### TCustomTimer (customtimer.pas)
```pascal
procedure SetEnabled(Value: Boolean); virtual;
```
Note: Uses property-based enable, not separate Disable method.

#### TCustomCheckListBox (checklst.pas)
```pascal
procedure SetItemEnabled(AIndex: Integer; const AValue: Boolean);
```
Note: Per-item enable/disable, not component-wide.

#### TDBNavigator (dbctrls.pp)
```pascal
procedure BeginUpdateButtons; virtual;
procedure EndUpdateButtons; virtual;
```

---

## Common Patterns

### Pattern 1: Counter-Based Locking (Most Common)
```pascal
FLockCount: Integer;

procedure DisableXxx;
begin
  Inc(FLockCount);
  // Optional: propagate to parent on 0->1 transition
end;

procedure EnableXxx;
begin
  Dec(FLockCount);
  if FLockCount = 0 then
    // Process pending changes
    // Optional: propagate to parent on N->0 transition
end;
```

**Failure modes:**
- Missed Enable: counter stays > 0 forever, functionality permanently disabled
- Double Enable (underflow): counter goes negative, enables when it shouldn't
- Exception between Disable and Enable without try/finally: counter stuck

### Pattern 2: Flag-Based Locking (Less Common)
```pascal
FUpdateFlag: Boolean;

procedure BeginUpdate;
begin
  FUpdateFlag := True;
end;

procedure EndUpdate;
begin
  FUpdateFlag := False;
  if FPendingChanges then
    RefreshUI;
end;
```

**Advantage over counters:** Can't underflow. **Disadvantage:** Can't nest.

### Pattern 3: Callback Hooks (Notification Only)
```pascal
procedure EnabledChanging;  // Called BEFORE change
procedure EnabledChanged;   // Called AFTER change
```

No locking. No counter. Pure notification.

---

## Nested Lock Safety

Most LCL pairs support nested/re-entrant calling:

```pascal
Control.DisableAutoSizing('Reason1');
// ...
Control.DisableAutoSizing('Reason2');  // Safe - increments counter
// ...
Control.EnableAutoSizing('Reason2');   // Decrements - still locked
Control.EnableAutoSizing('Reason1');   // Decrements to 0 - now processes
```

**HOWEVER:** Nested locking is only safe if:
1. Every Disable has a matching Enable (use try/finally!)
2. Parent doesn't change between Disable and Enable (see parent-propagation protocol above)
3. No code between Disable and Enable can raise an exception without a try/finally guard

---

## Known Bugs: Missing try/finally Protection

The following callsites call `DisableAutoSizing` or `DisableAlign` without a `try/finally` protecting the matching Enable call. If an exception is raised between Disable and Enable, the lock count is permanently corrupted.

### Critical: No Enable Call At All

| File | Line | Call | Issue |
|------|------|------|-------|
| `designer/menueditor.pp` | 892 | `sb.DisableAutoSizing('TShadowMenu.DeleteBox')` | No EnableAutoSizing anywhere in function. Recursive. Permanent leak. |
| `ide/main.pp` | 6181 | `CodeExplorerView.DisableAutoSizing(...)` | No matching Enable in function |
| `ide/main.pp` | 6208 | `RestrictionBrowserView.DisableAutoSizing(...)` | No matching Enable |
| `ide/main.pp` | 6224 | `ComponentListForm.DisableAutoSizing(...)` | No matching Enable |
| `ide/main.pp` | 6236 | `JumpHistoryViewWin.DisableAutoSizing(...)` | No matching Enable |
| `ide/fpdoceditwindow.pas` | 239 | `FPDocEditor.DisableAutoSizing(...)` | No matching Enable |

**Note:** The `ide/main.pp` cases with `State=iwgfDisabled` are part of an IDE windowing pattern where the caller (typically the anchor dock master) is expected to call `EnableAutoSizing` later. These are intentional deferred locks, not bugs — but they rely on the caller always following through, and there is no enforcement mechanism.

### Critical: Disable Before try Block

| File | Line | Call | Issue |
|------|------|------|-------|
| `designer/designer.pp` | 4283 | `Form.DisableAutoSizing(...)` | `TFPList.Create` between Disable and try |
| `ide/componentpalette.pas` | 273 | `PageControl.DisableAutoSizing(...)` | `Scale96ToForm` calls between Disable and try |
| `ide/sourceeditor.pp` | 8638 | `DisableAutoSizing(...)` | `IncUpdateLock` between Disable and try |

### Critical: No try/finally At All

| File | Line | Call | Issue |
|------|------|------|-------|
| `designer/menueditor.pp` | 2003 | `DisableAutoSizing('')` | Loop with SetBounds calls, no try/finally |
| `ide/packages/idedebugger/debuggertreeview.pas` | 754 | `DisableAutoSizing('')` | Inherited call could throw, no try/finally |
| `examples/cooltoolbar/unit1.pas` | 156 | `CoolBar1.DisableAutoSizing('')` | INI reads could throw, no try/finally |
| `lcl/include/wincontrol.inc` | 6836 | `DisableAlign` in `DoFlipChildren` | Loop with property assignments, no try/finally |

### Critical: Exit Without Enable on Exception Path

| File | Line | Call | Issue |
|------|------|------|-------|
| `ide/customformeditor.pp` | 1360 | `DisableAutoSizing(...)` | Exception handler at line 1376 exits without Enable |
| `designer/jitforms.pp` | 1088 | `DisableAutoSizing(...)` | Outside all try blocks, no Enable in function |

### Moderate: Cross-Function Pairing

| File | Lines | Call | Issue |
|------|-------|------|-------|
| `ide/sourceeditor.pp` | 8260, 8276 | `FNotebook.DisableAutoSizing('')` / `EnableAutoSizing('')` | Disable in `IncUpdateLockInternal`, Enable in `DecUpdateLockInternal`. No try/finally possible across function boundary. |

### Minor: Typo in Reason String

| File | Line | Issue |
|------|------|-------|
| `ide/sourceeditor.pp` | 8641 | Reason is `'TSourceNotebook.MoveEdito DestWinr'` — truncated/garbled |

---

## Design Weaknesses: LCL vs. VCL

### LCL-Only: Parent Propagation in DisableAutoSizing

The VCL's `DisableAlign`/`EnableAlign` (the closest VCL equivalent) does NOT propagate to parents. It only affects the control it's called on. The LCL added parent propagation to handle cross-platform auto-sizing, but this creates the asymmetry and reparenting hazards documented above. The VCL approach is simpler and safer but less capable.

### LCL-Only: wcfDeferShowing

The `wcfDeferShowing` flag in `TWinControlFlag` is entirely LCL-only. It was added to work around GTK's `size-allocate` signals firing during handle creation. The VCL doesn't need this because Win32's `WM_SIZE` is posted asynchronously. This flag interacts with `UpdateShowing`, `EndFormUpdate`, and `DoAllAutoSize` in ways that create a fragile implicit protocol.

### LCL-Only: DebugDisableAutoSizing Conditional Compilation

The `{$IFDEF DebugDisableAutoSizing}` two-path compilation for reason tracking has no VCL equivalent. As of the recent refactor, the `Reason` parameter is always present in the function signature and always logged via `DebugLn`, but in-memory reason accumulation (`FAutoSizingLockReasons`) remains behind the define to avoid RAM cost in release builds.

### LCL-Only: DoAllAutoSize Loop

The VCL's auto-sizing is a single pass. The LCL's `DoAllAutoSize` loops up to 100 times trying to converge, with each iteration potentially triggering GTK signals that restart the loop. This is an LCL design required by the cross-platform reality but absent from the VCL.

### Inherited from VCL: Counter-Based Locking Without Contracts

The fundamental pattern — increment a counter, do work, decrement the counter, hope nothing goes wrong in between — is inherited from the VCL. Delphi has the same class of bugs. The LCL makes it worse by adding parent propagation and cross-platform signal re-entrancy, but the core weakness (no enforcement that Disable and Enable are paired) is a VCL legacy.

---

## Files Analyzed

- `lcl/controls.pp` — Core control declarations
- `lcl/include/control.inc` — DisableAutoSizing/EnableAutoSizing implementation
- `lcl/include/wincontrol.inc` — Insert/Remove, InsertControl/RemoveControl, DisableAlign/EnableAlign, DoAllAutoSize
- `lcl/include/customform.inc` — BeginFormUpdate/EndFormUpdate
- `lcl/comctrls.pp` — Common controls (ListView, TreeView, etc.)
- `lcl/stdctrls.pp` — Standard controls
- `lcl/extctrls.pp` — Extended controls
- `lcl/dbctrls.pp` — Data-aware controls
- `lcl/imglist.pp` — Image lists
- `lcl/graphics.pp` — Graphics primitives
- `lcl/buttonpanel.pas` — Button panel
- `lcl/customtimer.pas` — Timer component
- `lcl/checklst.pas` — Checked list box
- `lcl/taskdlgemulation.pp` — Task dialog
- `lcl/toolwin.pp` — Toolbar/toolwindow
- `ide/main.pp` — Main IDE
- `ide/sourceeditor.pp` — Source editor
- `ide/mainbar.pas` — Main IDE bar
- `ide/componentpalette.pas` — Component palette
- `designer/designer.pp` — Form designer
- `designer/menueditor.pp` — Menu editor
- `designer/jitforms.pp` — JIT form creation
- `components/anchordocking/anchordocking.pas` — Anchor docking
- `components/ideintf/idewindowintf.pas` — IDE window interface
- Widgetset implementations in `lcl/interfaces/*/`
