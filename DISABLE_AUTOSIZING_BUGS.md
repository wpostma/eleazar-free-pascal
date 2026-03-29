# DisableAutoSizing / BeginFormUpdate: Missing Guards and Misuse

Two classes of bug involving counter-based lock pairs in the LCL:

1. **Missing `try..finally`** — if an exception fires between Disable
   and Enable, the lock count is permanently stuck and the control tree
   silently stops laying out. Four instances found, all fixed. These are
   genuine code quality issues that affect all platforms.

2. **Wrong calling context** — `DisableAutoSizing`/`EnableAutoSizing`
   is safe in normal code but can cause infinite recursion inside GTK
   `size-allocate` signal handlers on **GNOME/Mutter**. `EnableAutoSizing`
   calls `DoAllAutoSize` → `RealizeBoundsRecursive` → GTK fires
   `size-allocate` back → infinite recursion. **This does not reproduce
   on KDE Plasma** — KWin handles the re-entrant sizing without looping.
   See [RESIZE_LOOP_SEGFAULT.md](RESIZE_LOOP_SEGFAULT.md).

**Related documents:**
- [lazarus-antipatterns.md](lazarus-antipatterns.md) §1 (resize recursion),
  §8 (DisableAutoSizing architecture critique)
- [RESIZE_LOOP_SEGFAULT.md](RESIZE_LOOP_SEGFAULT.md) (full crash autopsy)

---

## The Two Lock Pairs

### DisableAutoSizing / EnableAutoSizing

**Purpose:** Batch multiple layout changes. Increments
`FAutoSizingLockCount`; when it reaches 1, propagates to Parent.
`EnableAutoSizing` decrements; when it reaches 0, calls `DoAllAutoSize`
(if no Parent) or propagates Enable to Parent.

**Implementation:** `control.inc` (`TControl.DisableAutoSizing`,
`TControl.EnableAutoSizing`)

**Danger:** A stuck lock silently disables all auto-sizing for the
control and its entire parent chain. No error, no warning. The form
just never lays out correctly.

### BeginFormUpdate / EndFormUpdate

**Purpose:** Defer child control sizing/showing during form
construction. `FFormUpdateCount` counter-based.

**Implementation:** `customform.inc:2879-2889`

**Danger:** If stuck > 0, form stays in "under construction" state.
Child controls never get sized or shown.

---

## Bug #1: TCustomButtonPanel.DoShowButtons

**File:** `lcl/buttonpanel.pas:188-220`
**Status:** FIXED

**Was:**
```pascal
DisableAutoSizing('TCustomButtonPanel.DoShowButtons');
for btn := Low(btn) to High(btn) do
begin
  if FButtons[btn] = nil
  then CreateButton(btn);  // can throw
  ...
end;
UpdateButtonOrder;
UpdateButtonLayout;
EnableAutoSizing('TCustomButtonPanel.DoShowButtons');  // may not reach
```

**Now:**
```pascal
DisableAutoSizing('TCustomButtonPanel.DoShowButtons');
try
  ...
finally
  EnableAutoSizing('TCustomButtonPanel.DoShowButtons');
end;
```

---

## Bug #2: TCustomButtonPanel.DoShowGlyphs

**File:** `lcl/buttonpanel.pas:228-244`
**Status:** FIXED

Same pattern — `GlyphShowMode` assignment between unguarded
Disable/Enable. Wrapped in `try..finally`.

---

## Bug #3: TCustomDockForm.Create

**File:** `lcl/include/customdockform.inc:56-66`
**Status:** FIXED

`BeginFormUpdate` before `CreateNew` + property assignments, with
`EndFormUpdate` after. If `CreateNew` throws, form stuck in update mode.
Wrapped in `try..finally`.

---

## Bug #4: TCalculatorForm.Create

**File:** `lcl/forms/calcform.pas:676-682`
**Status:** FIXED

`BeginFormUpdate` before `CreateNew` + `InitForm`, with `EndFormUpdate`
after. Same problem, same fix.

---

## Bug #5: Calling DisableAutoSizing from GTK Signal Handlers

**File:** `ide/mainbar.pas` — `DoSetMainIDEHeight`
**Status:** FIXED (by removing the call from `Resizing`, not by
removing the pair)

The upstream code called `DoSetMainIDEHeight` from
`TMainIDEBar.Resizing`, which is on the GTK `size-allocate` callback
chain. `DoSetMainIDEHeight` contains a correct
`DisableAutoSizing`/`try`/`finally`/`EnableAutoSizing` pair (written
by Juha). But when called from inside `size-allocate` on GNOME/Mutter:

```
Resizing → DoSetMainIDEHeight → EnableAutoSizing → DoAllAutoSize
  → RealizeBoundsRecursive → GTK size-allocate → Resizing → ...
```

On GNOME, the height spirals to 32,000px, exceptions fire, and the IDE
crashes during shutdown with a use-after-free in the Object Inspector.
On KDE Plasma, this loop does not occur — KWin handles the re-entrant
`size-allocate` without spiraling.

**The fix:** Remove the call from `Resizing`. The
`DisableAutoSizing`/`EnableAutoSizing` pair in `DoSetMainIDEHeight`
is correct and remains. `DoSetMainIDEHeight` is now only called from
safe contexts (`SetMainIDEHeight`, `InitPaletteAndCoolBar`, etc.).

**The lesson:** `DisableAutoSizing`/`EnableAutoSizing` must never be
used inside the `gtksize_allocateCB` → `DeliverMessage` → `WndProc`
call path. `EnableAutoSizing` calls `DoAllAutoSize` which sends bounds
back to GTK, creating unbounded re-entrancy.

See [RESIZE_LOOP_SEGFAULT.md](RESIZE_LOOP_SEGFAULT.md) for the full
200-frame GDB backtrace and three-layer crash analysis.

---

## Patterns Found But Safe

### Conditional pair in coolbar.inc

```pascal
if aCountM1 >= 0 then DisableAutoSizing('TCustomCoolBar.CalculateAndAlign');
inc(FUpdateCount);
try
  InvalidatePreferredSize;
  AdjustSize;
finally
  if aCountM1 >= 0 then EnableAutoSizing('TCustomCoolBar.CalculateAndAlign');
  dec(FUpdateCount);
end;
```

Conditions match on both sides. Safe.

### Nested control Insert/Remove in wincontrol.inc

```pascal
// InsertControl
if AControl.FAutoSizingLockCount>0 then
  DisableAutoSizing('TControl.DisableAutoSizing');

// RemoveControl
if AControl.FAutoSizingLockCount>0 then
  EnableAutoSizing('TControl.DisableAutoSizing');
```

Fragile — relies on symmetric Insert/Remove lifecycle. If a control is
inserted but never removed, parent stays locked. If removed twice,
underflow. Works in practice but has no safety net.

---

## Correct Pattern (Reference)

```pascal
DisableAutoSizing('ClassName.MethodName');
try
  // ... operations that may throw ...
finally
  EnableAutoSizing('ClassName.MethodName');
end;
```

**Additional rules:**
1. The Reason string must always be provided (not behind `{$IFDEF}`)
2. Never call from inside a GTK signal handler (`size-allocate`,
   `configure-event`, etc.)
3. One `DebugLn` per call — see `lazarus-antipatterns.md` §7b

---

## Consequences of a Stuck Lock

When `FAutoSizingLockCount` remains > 0:

1. `DoAllAutoSize` never executes on this control
2. Child controls don't resize
3. Layout freezes silently
4. Parent chain is also locked (propagation)
5. **No error message** — just broken layout
6. Appears to be a layout algorithm failure, not a missing Enable call

When `FFormUpdateCount` remains > 0:

1. Form stays in "under construction" state
2. `UpdateShowing` is blocked
3. Child controls never become visible
4. Form appears blank or partially drawn

---

## Diagnostic Aids

### DebugDisableAutoSizing define

Compile with `-dDebugDisableAutoSizing` to get `FAutoSizingLockReasons`
tracking (a TStringList of reason strings). Useful for finding orphaned
Disable calls but leaks memory for every mismatch.

### HandleException logging

`application.inc` now logs every exception that reaches
`TApplication.HandleException` with class, message, and full
`DumpExceptionBackTrace`:
- `[HandleException][FIRST]` — original exception
- `[HandleException][CIRCULAR-HALT]` — second exception (during error
  dialog), triggers `Halt`
- `[HandleException][TRIPLE]` — third+ exception, bails out

This catches the case where a stuck auto-sizing lock causes a sizing
exception, which then cascades through the modal dialog event loop into
a circular exception and forced shutdown.

---

## Remaining Audit

Search for unguarded pairs:

```bash
rg "DisableAutoSizing" lcl/ --include="*.pas" --include="*.pp" --include="*.inc" -l
```

Then for each file, verify every `DisableAutoSizing` has a matching
`EnableAutoSizing` inside a `try..finally`. Same for
`BeginFormUpdate`/`EndFormUpdate`.
