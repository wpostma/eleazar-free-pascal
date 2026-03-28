# Lazarus Antipatterns

Bugs and architectural problems found while working on the Lazarus IDE codebase.

## A Note on Humility

This document was written while debugging a fresh-install hang on a dual-monitor
Linux desktop. The tone is harsh. Some of that harshness is earned — a fresh
install that hangs forever is a real bug. But some of it came from the arrogance
of outsiders who barged into a 25-year-old codebase, declared everything broken,
and started "fixing" things without fully understanding why they were the way
they were.

The `Resizing` → `DoSetMainIDEHeight` loop that we called "insanely shitty code"
had been working for years on single-monitor setups with saved configurations.
The `DoAllAutoSize` loop we called a "Rube Goldberg machine" handles edge cases
in dozens of widget sets across five operating systems. The `gdk_window_get_root_origin`
call we replaced works fine on every X11 setup except during initial window mapping
on certain compositors.

When we added our own fixes — re-entrancy guards, deferred showing, height
change tracking — we introduced our own bugs. The `FLastResizeHeight` check
broke window moves. The `wcfDeferShowing` flag changed timing assumptions that
other code depended on. We knocked shelves over while rearranging the store.

**The lesson:** In a system this old, every line of code survived years of bug
reports. Before adding a guard, understand what the unguarded path was doing
and who relied on it. Before calling something garbage, check whether it works
on the platforms and configurations you haven't tested. Before rewriting a
phase system, understand that the "wrong" design might be the only one that
converges across GTK2, Qt5, Win32, and Cocoa.

Write tests first. Change one thing at a time. Verify on the actual application
before declaring victory. And when your fix makes things worse, write that down
too.

---

## Table of Contents

1. [Endless Recursion in Event Callbacks](#1-endless-recursion-in-event-callbacks)
2. [Default Window Positions Span All Monitors](#2-default-window-positions-span-all-monitors)
3. [Synchronous X11 Round-Trip Inside GTK Signal Handler](#3-synchronous-x11-round-trip-inside-gtk-signal-handler)
4. [Editorial: The Fresh Install Is Completely Broken](#4-editorial-the-fresh-install-is-completely-broken)
5. [AutoSize Phase System: Phases That Aren't Phases](#5-autosize-phase-system-phases-that-arent-phases)
6. [WM Constraints That Fight the User](#6-wm-constraints-that-fight-the-user)

---

## 1. Endless Recursion in Event Callbacks

**Status:** Active bug, causes IDE hang on fresh install
**Unit:** `ide/mainbar.pas` — `TMainIDEBar`
**Severity:** Critical — IDE is unusable with no saved config

### Symptoms

On a fresh install (no `~/.lazarus` directory or no saved window geometry),
the IDE hangs immediately after startup. The process is alive but pegs
the CPU and never shows a window. A core dump reveals an unbounded
call stack:

```
RealizeBoundsRecursive → RealizeBoundsRecursive → RealizeBoundsRecursive → ...
```

### Root Cause

`TMainIDEBar.Resizing` (line 798) is called by GTK's `size-allocate` signal.
It calls `DoSetMainIDEHeight` (line 804), which modifies `ClientHeight` and
`Constraints`, then calls `EnableAutoSizing` (line 468). This triggers
`DoAllAutoSize` → `RealizeBoundsRecursive`, which walks the control tree
and realizes bounds on child controls. Realizing bounds causes GTK to fire
another `size-allocate` signal, which re-enters `Resizing`, and the cycle
repeats forever.

### Call Chain

```
GTK size-allocate signal
  → gtksize_allocateCB              (gtk2callback.inc:2535)
    → SendSizeNotificationToLCL     (gtk2proc.inc:6826)
      → DeliverMessage              (gtk2proc.inc:3755)
        → TMainIDEBar.WndProc       (mainbar.pas:614)
          → TCustomForm.WMSize      (customform.inc:668)
            → TMainIDEBar.Resizing  (mainbar.pas:798)
              → DoSetMainIDEHeight  (mainbar.pas:804)
                → sets ClientHeight and Constraints  (mainbar.pas:455-464)
                → EnableAutoSizing  (mainbar.pas:468)
                  → DoAllAutoSize   (wincontrol.inc:3685)
                    → RealizeBoundsRecursive  (wincontrol.inc:8728)
                      → triggers GTK size-allocate on child widgets
                        → ... re-enters at the top
```

### The Antipattern

**Mutating widget geometry inside a geometry-notification callback without
a re-entrancy guard.**

GTK (and most widget toolkits) will fire size/position notifications
whenever a widget's allocation changes. If the handler responds by
changing the allocation again, the toolkit fires the notification again.
Without a guard, this is an infinite loop.

This is not a GTK bug. GTK is correctly notifying the application that a
size changed. The bug is that Lazarus changes the size again in response,
with no check for whether it's already in the middle of handling a resize.

The LCL already has a pattern for this: `wcfRealizingBounds` in
`FWinControlFlags` (see `wincontrol.inc:8722`). But `TMainIDEBar.Resizing`
does not check any such flag before calling `DoSetMainIDEHeight`.

### Why It Only Hits Fresh Installs

On a fresh install, there is no saved window geometry in
`environmentoptions.xml`. The IDE creates the main bar with default
dimensions. When GTK first maps and allocates the window, the calculated
height may differ from what `DoSetMainIDEHeight` wants, so
`DoSetMainIDEHeight` adjusts it, triggering the loop. On subsequent
launches with saved geometry, the initial allocation matches the desired
height, so `DoSetMainIDEHeight` is a no-op and the loop never starts.

### Proposed Fix

Add a re-entrancy guard to `TMainIDEBar`:

```pascal
{ In TMainIDEBar class declaration (mainbar.pas) }
private
  FResizing: Boolean;

{ In TMainIDEBar.Resizing }
procedure TMainIDEBar.Resizing(State: TWindowState);
begin
  if FResizing then Exit;          // ← break the cycle
  FResizing := True;
  try
    if LazarusIDE.IDEStarted then
      case State of
        wsMaximized, wsNormal: begin
          DoSetMainIDEHeight(State = wsMaximized);
        end;
      end;
    inherited Resizing(State);
  finally
    FResizing := False;
  end;
end;
```

This is the minimal fix. The `FResizing` flag prevents `Resizing` from
re-entering when `DoSetMainIDEHeight` triggers another `size-allocate`
signal. The `try/finally` ensures the flag is cleared even if an exception
occurs.

An alternative approach would be to guard `DoSetMainIDEHeight` itself,
but `Resizing` is the better place because:
1. It's the entry point from the widget toolkit callback chain
2. `DoSetMainIDEHeight` is also called from `SetMainIDEHeight` (line 814)
   which has its own call path and should not be blocked
3. The guard at the outermost layer prevents any re-entrant size changes,
   not just the specific ones in `DoSetMainIDEHeight`

### General Rule

**Never mutate geometry (size, position, constraints) inside a
geometry-notification handler without a re-entrancy guard.** This applies
to any LCL `WMSize`, `WMMove`, `Resizing`, or `DoAllAutoSize` override.
If your handler might change the thing it was notified about, add a
boolean flag to prevent re-entry.

### Files Involved

| File | Role |
|------|------|
| `ide/mainbar.pas:798` | `TMainIDEBar.Resizing` — the re-entrant method |
| `ide/mainbar.pas:440` | `DoSetMainIDEHeight` — mutates geometry |
| `lcl/include/wincontrol.inc:8720` | `RealizeBoundsRecursive` — walks control tree |
| `lcl/include/wincontrol.inc:3685` | `DoAllAutoSize` — triggers realization |
| `lcl/interfaces/gtk2/gtk2callback.inc:2535` | `gtksize_allocateCB` — GTK entry point |
| `lcl/interfaces/gtk2/gtk2proc.inc:6826` | `SendSizeNotificationToLCL` — delivers to LCL |

---

## 2. Default Window Positions Span All Monitors

**Status:** Fixed
**Units:** `components/ideintf/idewindowintf.pas`, `ide/main.pp`
**Severity:** High — IDE unusable on multi-monitor setups with fresh config

### Symptoms

On first launch with no saved configuration, the main IDE window spans the
full width of all monitors (e.g., 5120px across two 2560px monitors). Other
IDE windows are scattered at positions calculated relative to this absurd
width. The result is windows that are off-screen, overlapping across monitor
boundaries, or impossibly wide.

### Root Cause

`TIDEWindowCreatorList.GetScreenrectForDefaults` (`idewindowintf.pas:2335`)
used `Screen.WorkAreaRect`, which on multi-monitor setups returns the
bounding rectangle of ALL monitors combined. All default window positions
are calculated as percentages or offsets of this rectangle.

The main IDE bar was registered with `Right:='100%'`, meaning 100% of the
combined desktop width — the full span of every monitor.

Additionally, `TSimpleWindowLayout.ValidateAndSetCoordinates` used
`Screen.DesktopWidth`/`Screen.DesktopHeight` (all monitors combined) for
boundary checking, with only a 60-pixel margin. A window could be placed
anywhere across all monitors as long as 60 pixels were visible.

### The Antipattern

**Using `Screen.WorkAreaRect` or `Screen.DesktopWidth` for default
positioning instead of the primary monitor's work area.**

`Screen.WorkAreaRect` is the bounding box of all monitors. On a single
monitor, it happens to be the same as the monitor's work area. On
multi-monitor setups, it spans everything. This is useful for validating
that a restored window is still reachable, but it is wrong for calculating
where a new window should appear.

### Fixes Applied

**A. `GetScreenrectForDefaults` now uses primary monitor:**

```pascal
function TIDEWindowCreatorList.GetScreenrectForDefaults: TRect;
var
  aMonitor: TMonitor;
begin
  aMonitor := Screen.PrimaryMonitor;
  if aMonitor <> nil then
    Result := aMonitor.WorkareaRect
  else
    Result := Screen.WorkAreaRect;
  // ... fallback for unrecognized screen
end;
```

**B. Main IDE bar defaults to 75% of primary monitor, centered:**

```pascal
FormCreator.Left:='12%';    // was: (empty, defaulting to 0)
FormCreator.Right:='88%';   // was: '100%'
FormCreator.Bottom:='+90';
```

This gives a 75% width centered on the primary monitor with 12.5% margin
on each side.

**C. `ValidateAndSetCoordinates` uses primary monitor with 200px margins:**

- Uses `Screen.PrimaryMonitor.WorkareaRect` instead of `Screen.Desktop*`
- Clamps window size to `(work area - 200px)` in each dimension
- Enforces window is fully within the primary monitor's work area
- No window edge closer than the work area boundary

**D. Object Inspector starts at x=10 instead of x=0** to avoid being
jammed into the screen edge.

### General Rule

**Always use `Screen.PrimaryMonitor.WorkareaRect` (or the target monitor's
work area) for default positioning. Reserve `Screen.WorkAreaRect` and
`Screen.DesktopWidth` only for validating that a saved position is still
reachable on some monitor.**

### Files Changed

| File | Change |
|------|--------|
| `components/ideintf/idewindowintf.pas` | `GetScreenrectForDefaults` uses primary monitor |
| `components/ideintf/idewindowintf.pas` | `ValidateAndSetCoordinates` clamps to primary monitor, 200px margins |
| `ide/main.pp:1615-1617` | Main IDE bar: `Left='12%'`, `Right='88%'` instead of `Right='100%'` |
| `ide/main.pp:2247-2248` | Object Inspector: `Left='10'` instead of `Left='0'` |

---

## 3. Synchronous X11 Round-Trip Inside GTK Signal Handler

**Status:** Active bug, causes IDE to hang indefinitely on startup
**Unit:** `lcl/interfaces/gtk2/gtk2proc.inc`
**Severity:** Critical — IDE never shows a window on fresh install

### Symptoms

On first launch with no saved configuration, the IDE process starts, prints
some diagnostic output, then hangs forever. No window ever appears. The
process is alive (not crashed), consuming zero CPU, blocked on a `poll()`
system call. It will stay there until killed.

### Root Cause

`GetWidgetRelativePosition` (`gtk2proc.inc:7215-7229`) calls
`gdk_window_get_root_origin()` on any widget that is a GTK_WINDOW and
reports `GTK_WIDGET_MAPPED`. This function issues a synchronous
`XGetWindowProperty` request for `_NET_FRAME_EXTENTS`, then calls
`poll()` waiting for the X server's reply.

The problem: this is called from inside a `size-allocate` signal handler
(`gtksize_allocateCB` → `SendSizeNotificationToLCL` →
`GetWidgetRelativePosition`). During initial window setup, GTK fires
`size-allocate` after the widget is "mapped" from GTK's perspective but
before the window manager has finished decorating the window and setting
`_NET_FRAME_EXTENTS`. The X server has nothing to reply with. The call
blocks forever.

### Call Chain

```
GTK size-allocate signal
  → gtksize_allocateCB           (gtk2callback.inc:2535)
    → SendSizeNotificationToLCL  (gtk2proc.inc:6698)
      → GetWidgetRelativePosition (gtk2proc.inc:7215)
        → gdk_window_get_root_origin  (gtk2proc.inc:7219)
          → gdk_window_get_frame_extents  (libgdk)
            → XGetWindowProperty    (libX11)
              → xcb_wait_for_reply64  (libxcb)
                → poll()  ← BLOCKED FOREVER
```

### The Antipattern

**Never make a synchronous X11 round-trip inside a GTK signal handler.**

GTK signal handlers run inside the event loop. Synchronous X11 calls
(`XGetWindowProperty`, `XInternAtom`, `XGetGeometry`, etc.) block the
event loop until the X server replies. If the X server is waiting for the
application to process its own events first (which is common during window
mapping), you get a deadlock.

This is not a subtle race condition. This is a basic rule of X11/GTK
programming that has been documented for decades: signal handlers must
not block.

### The Irony

The code already has the correct fallback. Lines 7222-7228:

```pascal
end else begin
  // the gtk has not yet put the window to the final position
  // => the gtk/gdk position is not reliable
  // => use the LCL coords
  LCLControl:=GetLCLObject(aWidget) as TWinControl;
  Left:=LCLControl.Left;
  Top:=LCLControl.Top;
end;
```

The author knew that asking GDK for the position during setup is
unreliable. They wrote the safe path. But the condition
`GTK_WIDGET_MAPPED(aWidget)` takes the dangerous path because GTK
considers the widget "mapped" before the window manager has finished
with it. The check is wrong. The safe path is never reached when it
should be.

### Proposed Fix

Do not call `gdk_window_get_root_origin` during a `size-allocate`
callback. Either:

**Option A: Check if we're inside a size-allocate handler:**

```pascal
if GtkWidgetIsA(aWidget,GTK_TYPE_WINDOW) then begin
  GdkWindow:=GetControlWindow(aWidget);
  if (GdkWindow<>nil) and (GTK_WIDGET_MAPPED(aWidget))
  and not (wcfRealizingBounds in TWinControl(GetLCLObject(aWidget)).FWinControlFlags) then begin
    gdk_window_get_root_origin(GdkWindow, @GtkLeft, @GtkTop);
    Left := GtkLeft;
    Top := GtkTop;
  end else begin
    LCLControl:=GetLCLObject(aWidget) as TWinControl;
    Left:=LCLControl.Left;
    Top:=LCLControl.Top;
  end;
end;
```

**Option B: Use `gdk_window_get_position` instead, which does not
round-trip to the X server:**

```pascal
gdk_window_get_position(GdkWindow, @GtkLeft, @GtkTop);
```

This returns the cached GDK position, which may not include window
manager decorations, but at least it doesn't deadlock.

**Option C: Just always use the LCL coords during size-allocate.** The
whole point of `SendSizeNotificationToLCL` is to update the LCL with
the new size. Asking the X server for the position at this exact moment
is both dangerous and unnecessary — the position hasn't changed, only
the size has.

### Files Involved

| File | Role |
|------|------|
| `lcl/interfaces/gtk2/gtk2proc.inc:7215-7229` | `GetWidgetRelativePosition` — the blocking call |
| `lcl/interfaces/gtk2/gtk2proc.inc:6698` | `SendSizeNotificationToLCL` — calls GetWidgetRelativePosition |
| `lcl/interfaces/gtk2/gtk2callback.inc:2535` | `gtksize_allocateCB` — GTK entry point |

---

## 4. Editorial: The Fresh Install Is Completely Broken

Three bugs. Three separate, fundamental programming errors. All triggered
by the most basic possible scenario: **start the IDE for the first time on
a Linux desktop with two monitors.**

Not an obscure configuration. Not a race condition under load. Not a
corner case with unusual hardware. Two monitors, a fresh home directory,
and the default build. That's it.

### Bug 1: Infinite recursion

You change the window size inside the "window size changed" callback.
GTK notifies you the size changed again. You change it again. Forever.

This is the first thing every GUI programming tutorial warns you about.
Every toolkit has this footgun. The fix is a one-line boolean flag. This
code has been shipping for years.

### Bug 2: Default positions span all monitors

`Screen.WorkAreaRect` returns the bounding rectangle of all monitors.
On a dual-monitor setup, that's 5120 pixels wide. The main IDE bar is
registered at `Right:='100%'` — 100% of 5120 pixels. Every window
position is calculated relative to this absurd rectangle.

Nobody with two monitors ever tested a fresh install. Or if they did,
they assumed the window manager would fix it, or they already had a
saved config from last time, or they filed a bug and it was ignored.

### Bug 3: Synchronous X11 call blocks forever

`gdk_window_get_root_origin` does a synchronous round-trip to the X
server. It's called from inside a GTK `size-allocate` signal handler,
during initial window mapping, when the window manager hasn't set
`_NET_FRAME_EXTENTS` yet. The X server blocks. The event loop blocks.
The IDE hangs. Forever.

The code has a safe fallback path for exactly this situation. It's on
the next line. But the condition check (`GTK_WIDGET_MAPPED`) takes the
wrong branch because GTK's definition of "mapped" doesn't mean "the
window manager is done with it."

### The Pattern

All three bugs share the same root cause: **the code was tested on the
developer's machine with their saved configuration.** The first-launch
path is different from the subsequent-launch path. Nobody automated
testing of a fresh install. Nobody tested with multiple monitors.

This is especially damaging for an IDE. The fresh install experience is
the first thing every new user sees. If the IDE hangs on first launch,
the user doesn't file a bug — they close the terminal and pick a
different IDE.

### Recommendations

1. **CI must test fresh installs.** Delete the config directory, launch
   the IDE, verify it shows a window, verify it shuts down cleanly.
   This should be a blocking test.

2. **CI must test with virtual multi-monitor setups.** Xvfb supports
   multiple screens. Xephyr can simulate multi-monitor. There is no
   excuse for not testing this.

3. **Every GTK signal handler should be audited for:**
   - Re-entrant geometry mutations (set a flag, check it)
   - Synchronous X11 calls (`XGetWindowProperty`, `XInternAtom`,
     `XGetGeometry`, `XQueryTree`, `gdk_window_get_root_origin`,
     `gdk_window_get_frame_extents`)
   - Any call that blocks waiting for the X server

4. **Default window positions should be reviewed by someone with more
   than one monitor.** "100% of screen width" is never correct for a
   default window position on any platform.

5. **The LCL GTK2 backend needs a `InsideSizeAllocate` flag** that is
   set during `gtksize_allocateCB` and checked before any synchronous
   X11 call. This is a systemic fix, not a per-callsite fix.

### Yossi's Suit

There's an old joke. Yossi goes to a tailor to try on a new custom-made
suit. The sleeves are too long. "No problem," says the tailor. "Just bend
them at the elbow and hold them out in front of you. See, now it's fine."

"But the collar is up around my ears!"

"It's nothing. Just hunch your back a little…no, a little more…that's it."

"But I'm stepping on my cuffs!" Yossi cries in desperation.

"Nu, bend your knees a little to take up the slack. There you go. Look in
the mirror — the suit fits perfectly."

So, twisted like a pretzel, Yossi lurches out onto the street. Janine and
Suzy see him go by. "Oh look," says Janine, "that poor man."

"Yes," says Suzy, "but what a beautiful suit!"

*(From Oy! The Ultimate Book of Jewish Jokes, by David Minkoff)*

This is the LCL. The API looks beautiful — `TForm`, `TButton`,
`Position := poDefault`, `Constraints.MinHeight`. But to get a window
on screen without it hanging, fighting the window manager, spanning all
monitors, or looping 600,000 times, you have to bend your elbows
(don't create handles during construction), hunch your back (don't set
constraints because the WM will fight you), and bend your knees (don't
resize during resize, don't show during show, don't call
`gdk_window_get_root_origin` during `size-allocate`).

Every bug is "fixed" by making the caller contort. Every layer adds
another "just hunch a little more." The suit looks fine on paper.
Poor Yossi is twisted into a pretzel.

**Don't bend the user to fit the code. Fix the suit.**

---

## 5. AutoSize Phase System: Phases That Aren't Phases

**Status:** Architectural problem
**Unit:** `lcl/include/wincontrol.inc` — `TWinControl.DoAllAutoSize`
**Severity:** Root cause of all startup bugs

### The Lie

The LCL defines five auto-size phases as an enum:

```pascal
TControlAutoSizePhase = (
  caspNone,
  caspChangingProperties,
  caspCreatingHandles,    // Create/destroy handles.
  caspComputingBounds,
  caspRealizingBounds,
  caspShowing             // Make handles visible.
);
```

This looks like a well-designed phase system. It implies that handle
creation, bounds computation, bounds realization, and showing are
distinct, ordered phases that can be tracked and gated independently.

### The Reality

`DoAllAutoSize` runs ALL of them in a single loop:

```
DoAllAutoSize:
  1. CheckHandleAllocated(Self)        ← create handles
  while not AutoSizeDelayed:
    2. inherited DoAllAutoSize         ← compute bounds
    3. RealizeBoundsRecursive          ← send bounds to GTK
    4. UpdateShowingRecursive(children) ← show children
    5. if cfAutoSizeNeeded: goto 2     ← REPEAT UP TO 100 TIMES
  6. UpdateShowing                     ← show self (triggers gtk_widget_show)
```

Step 3 (`RealizeBoundsRecursive`) sends bounds to GTK, which fires
`size-allocate` signals. Those signals can set `cfAutoSizeNeeded`,
which sends the loop back to step 2. This can iterate **100 times**
before the code gives up and sets `wcfKillIntfSetBounds` to force
convergence.

Each iteration fires GTK signals, which call back into LCL code,
which can trigger more auto-sizing on other controls, which can
re-enter `DoAllAutoSize` on parent or sibling controls.

The phases exist as enum values but provide zero actual separation.
`UpdateShowing` checks `caspShowing in AutoSizePhases` but
`AutoSizePhases` always includes all phases because `DoAllAutoSize`
runs them all together. The check is meaningless.

### Why This Matters

1. **GTK gets hit with 100 iterations of bounds changes** before a
   single window is shown. Each one triggers signals, each signal
   can trigger callbacks, each callback can trigger more auto-sizing.

2. **Showing happens inside the same function as handle creation.**
   There is no way to create a handle, compose children, compute
   bounds, and THEN show. The LCL forces all of these to happen
   in one `DoAllAutoSize` call.

3. **The loop can't converge on a half-constructed form.** If
   components are still being added (like during `TMainIDE.Create`),
   each addition triggers `AdjustSize`, which calls `DoAllAutoSize`,
   which runs the full loop including showing — on a form that
   isn't done being built.

### What Should Happen

The phases should actually be phases:

```
Phase 1: CreateHandles
  - Allocate GTK widgets for form and all children
  - NO GTK signals processed (DisableAutoSizing)
  - NO showing

Phase 2: ComputeBounds
  - Calculate all sizes and positions
  - Pure computation, no widget calls

Phase 3: RealizeBounds
  - Send computed bounds to GTK in ONE batch
  - Process resulting signals ONCE
  - NO showing

Phase 4: Show
  - gtk_widget_show on children, then form
  - Focus, OnShow, Activate
```

Each phase completes fully before the next begins. No loops. No
re-entry. No "if autosize needed, go back to step 2."

### Files Involved

| File | Role |
|------|------|
| `lcl/controls.pp:987-994` | `TControlAutoSizePhase` — the unused enum |
| `lcl/include/wincontrol.inc:3645-3727` | `DoAllAutoSize` — the everything loop |
| `lcl/include/wincontrol.inc:4505-4566` | `UpdateShowing` — gated by a phase that's always active |
| `lcl/include/wincontrol.inc:8720-8737` | `RealizeBoundsRecursive` — triggers GTK signals mid-loop |

---

## 6. WM Constraints That Fight the User

**Status:** Fixed (constraints removed from WM), needs LCL-level solution
**Unit:** `ide/mainbar.pas`
**Severity:** Medium — toolbar can't be dragged on GNOME/Mutter

### Symptoms

The IDE toolbar (TMainIDEBar) snaps to the bottom of the screen and
fights the user during drag operations. Moving it causes it to jump
around unpredictably.

### Root Cause

`DoSetMainIDEHeight` sets `Constraints.MinHeight` and `Constraints.MaxHeight`
to the same value (e.g., 85). The LCL propagates these to X11 via
`gtk_window_set_geometry_hints` → `WM_NORMAL_HINTS` with
`min_size.height = max_size.height = 85`.

Mutter (GNOME Shell's window manager) enforces these rigidly. A window
with locked height is treated as a panel-like object. Mutter restricts
how it can be moved and snaps it to screen edges.

### Discovered Via

```bash
xprop -id 0x2a00be9 WM_NORMAL_HINTS
```

Output:
```
program specified minimum size: 0 by 85
program specified maximum size: 32767 by 85
```

### The Antipattern

**Don't use WM-level constraints for internal layout purposes.**

The toolbar height is an internal LCL layout concern. The window manager
doesn't need to know about it. Telling Mutter "this window must be exactly
85px tall" makes Mutter enforce that constraint in ways the LCL doesn't
expect, including restricting window movement.

### Current Fix

Removed `Constraints.MinHeight/MaxHeight` from `DoSetMainIDEHeight`.
Height is set via `ClientHeight` only, which the LCL auto-size system
respects without telling the WM.

### Better Fix (Not Yet Implemented)

Add LCL-only constraints that are enforced internally by the auto-size
system but never propagated to `gtk_window_set_geometry_hints`. This
would let the toolbar maintain its fixed height while Mutter treats it
as a normal freely-movable window. See `lcl-evolution.md` item #2.

### Files Involved

| File | Role |
|------|------|
| `ide/mainbar.pas` | `DoSetMainIDEHeight` — was setting WM constraints |
| `lcl/interfaces/gtk2/gtk2wsforms.pp` | `SetConstraints` — sends hints to WM |
