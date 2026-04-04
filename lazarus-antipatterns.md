# Lazarus Antipatterns

Bugs and architectural problems found while working on the Lazarus IDE codebase.

## A Note on Environment

**Critical discovery:** Most of the severe bugs documented here — the resize
loops, the X11 deadlock, the WM constraint fighting — were observed on
**Ubuntu with GNOME/Mutter**. When tested on **OpenSUSE Tumbleweed with KDE
Plasma**, many of these problems do not reproduce at all, or manifest only as
minor visual glitches rather than hangs and crashes.

This strongly suggests that the issues are not fundamental LCL architectural
flaws but rather **GNOME/Mutter-specific interaction problems** with the GTK2
backend. Mutter's handling of `size-allocate` signal re-entrancy,
`_NET_FRAME_EXTENTS` timing during window mapping, and rigid enforcement of
`WM_NORMAL_HINTS` constraints are all more aggressive than KWin's behavior.
The LCL code that "doesn't work" on GNOME has been working for years on KDE,
XFCE, and other desktop environments.

This doesn't mean the code is perfect — the missing `try..finally` guards,
the silent early exits, and the lack of re-entrancy protection are real
code quality issues worth fixing. But the apocalyptic tone of the original
writeups was driven by a GNOME-specific experience that we mistakenly
generalized to the entire LCL.

## A Note on Humility

This document was written while debugging a fresh-install hang on a dual-monitor
Ubuntu + GNOME desktop. The tone was initially harsh. Some of that harshness was
earned — a fresh install that hangs forever is a real bug. But much of it came
from the arrogance of outsiders who barged into a 25-year-old codebase, declared
everything broken, and started "fixing" things without fully understanding why
they were the way they were.

The `Resizing` → `DoSetMainIDEHeight` loop that we called "insanely shitty code"
had been working for years on KDE, XFCE, and single-monitor setups. The
`DoAllAutoSize` loop we called a "Rube Goldberg machine" handles edge cases
in dozens of widget sets across five operating systems. The `gdk_window_get_root_origin`
call we replaced works fine on every X11 setup except during initial window mapping
on GNOME/Mutter compositors.

When we added our own fixes — re-entrancy guards, deferred showing, height
change tracking — we introduced our own bugs. The `FLastResizeHeight` check
broke window moves. The `wcfDeferShowing` flag changed timing assumptions that
other code depended on. We knocked shelves over while rearranging the store.

**The lesson:** In a system this old, every line of code survived years of bug
reports. Before adding a guard, understand what the unguarded path was doing
and who relied on it. Before calling something garbage, check whether it works
on the platforms and configurations you haven't tested — especially non-GNOME
desktops. Before rewriting a phase system, understand that the "wrong" design
might be the only one that converges across GTK2, Qt5, Win32, and Cocoa.

Write tests first. Change one thing at a time. Verify on the actual application
before declaring victory. And when your fix makes things worse, write that down
too.

---

## The Worst Generic Flaw: Protocols Between Objects Without Contracts

The single most damaging pattern in the LCL is objects that coordinate
through implicit protocols with no enforceable contract.

A child tells its parent to do something. Maybe. If the parent exists.
If it's the right parent. If the lock count happens to be at the right
value. The parent doesn't know which child told it. The child doesn't
record which parent it told. Nobody verifies that the Disable and Enable
were sent to the same object. Nobody checks that the object graph didn't
change between the two calls.

This isn't one bug. It's the *architecture*. It shows up everywhere:

- **DisableAutoSizing / EnableAutoSizing** (section 8): Child propagates
  a lock to Parent on Disable, but Parent might be nil, or a different
  Parent, or gone entirely by Enable time. The Disable side silently does
  nothing when Parent is nil. The Enable side has completely different
  fallback logic (`DoAllAutoSize`). The two sides of the "protocol" don't
  even agree on what to do when the contract can't be fulfilled.

- **DoAllAutoSize loop** (section 5): Auto-size runs phases on a control
  tree, but any phase can trigger GTK signals that re-enter auto-sizing
  on other controls. There's no contract about which controls are allowed
  to auto-size during which phase. Everything just runs and hopes it
  converges within 100 iterations.

- **Resizing → DoSetMainIDEHeight** (section 1): GTK tells the LCL
  the size changed. The LCL responds by changing the size. GTK tells the
  LCL the size changed again. There's no contract between the notification
  producer (GTK) and the notification consumer (LCL) about who is allowed
  to mutate during a notification.

- **WM constraints** (section 6): The LCL tells the window manager to
  enforce a height constraint. The WM enforces it by restricting window
  movement. Neither side agreed on what "enforce" means. The LCL wanted
  internal layout enforcement. The WM provided global movement restriction.
  Same words, different contracts.

The pattern is always the same: Object A tells Object B to do something.
The protocol assumes B exists, B is the right B, B hasn't changed state
since A last talked to it, and B interprets the message the same way A
intended. None of these assumptions are checked. None are documented.
When they're violated — during reparenting, during construction, during
docking, during first launch with no saved config — the system silently
corrupts its own state and nobody knows until a form doesn't lay out, a
window doesn't show, or the IDE hangs forever.

**The fix is contracts.** If Disable propagates to a parent, record which
parent. If Enable needs to undo that, verify it's the same parent. If it
isn't, raise an error instead of silently corrupting the lock count. If
an auto-size phase requires that no GTK signals fire, enforce that with a
flag that blocks signal delivery, don't just hope. If a protocol has two
sides, both sides must agree on what happens in every case — including
the cases where the preconditions aren't met.

Protocols without contracts are just hopes. Hopes are not architecture.

---

## Table of Contents

0. [The Worst Generic Flaw: Protocols Between Objects Without Contracts](#the-worst-generic-flaw-protocols-between-objects-without-contracts)
1. [Endless Recursion in Event Callbacks](#1-endless-recursion-in-event-callbacks)
2. [Default Window Positions Span All Monitors](#2-default-window-positions-span-all-monitors)
3. [Synchronous X11 Round-Trip Inside GTK Signal Handler](#3-synchronous-x11-round-trip-inside-gtk-signal-handler)
4. [Editorial: The Fresh Install Is Completely Broken](#4-editorial-the-fresh-install-is-completely-broken)
5. [AutoSize Phase System: Phases That Aren't Phases](#5-autosize-phase-system-phases-that-arent-phases)
6. [WM Constraints That Fight the User](#6-wm-constraints-that-fight-the-user)
7. [Silent Early Exit: `if Condition then Exit`](#7-silent-early-exit-if-condition-then-exit)
8. [TControl.DisableAutoSizing: A Lock That Isn't a Lock](#8-tcontroldisableautosizing-a-lock-that-isnt-a-lock)
9. [Selftest-on-Startup That Poisons Its Own Config](#9-selftest-on-startup-that-poisons-its-own-config)

---

## 1. Endless Recursion in Event Callbacks

**Status:** Fixed (removed call from `Resizing`); hang was GNOME/Mutter-specific
**Unit:** `ide/mainbar.pas` — `TMainIDEBar`
**Severity:** Critical on GNOME — does not reproduce on KDE Plasma

> **See also:** [RESIZE_LOOP_SEGFAULT.md](RESIZE_LOOP_SEGFAULT.md) — full
> autopsy of the three-layer crash that occurs when
> `DisableAutoSizing`/`EnableAutoSizing` is re-enabled in
> `DoSetMainIDEHeight`. Documents the resize loop → exception inside
> `gtk_dialog_run` → use-after-free segfault in `CompFilterEdit.GetText`
> during finalization. Includes the complete 200-frame GDB backtrace.

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

### Why It Only Hits GNOME Fresh Installs

On a fresh install, there is no saved window geometry in
`environmentoptions.xml`. The IDE creates the main bar with default
dimensions. When GTK first maps and allocates the window, the calculated
height may differ from what `DoSetMainIDEHeight` wants, so
`DoSetMainIDEHeight` adjusts it, triggering the loop. On subsequent
launches with saved geometry, the initial allocation matches the desired
height, so `DoSetMainIDEHeight` is a no-op and the loop never starts.

**Environment note:** This loop was only observed on Ubuntu + GNOME/Mutter.
On OpenSUSE Tumbleweed with KDE Plasma, the same code path does not produce
infinite recursion — KWin appears to coalesce `size-allocate` signals or
handle the re-entrant sizing more gracefully. This suggests Mutter's
`size-allocate` dispatch is more aggressive about firing signals synchronously
during allocation, while KWin batches or defers them.

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

**Status:** GNOME/Mutter-specific; does not reproduce on KDE Plasma
**Unit:** `lcl/interfaces/gtk2/gtk2proc.inc`
**Severity:** Critical on GNOME — KWin handles `_NET_FRAME_EXTENTS` timing differently

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

**Environment note:** This deadlock was observed exclusively on GNOME/Mutter.
KWin (KDE Plasma) appears to set `_NET_FRAME_EXTENTS` earlier in the window
mapping sequence, or responds to the `XGetWindowProperty` query even before
decoration is complete. The underlying code is still technically unsafe — a
synchronous X11 round-trip inside a signal handler is never a good idea —
but in practice it only deadlocks under Mutter's specific timing.

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

## 4. Editorial: The Fresh Install Is Broken — On Ubuntu 24.04 LTS

**Update:** The bugs described in this section were observed on **Ubuntu
24.04 LTS** with its default GNOME/Mutter desktop. Testing on OpenSUSE
Tumbleweed with KDE Plasma revealed that the fresh install works without
these issues. The problems are real, but they are **window-manager-specific**,
not universal LCL failures.

### The Debian/Ubuntu Situation

Debian dropped both Lazarus and Free Pascal from its repositories. The
reasons were a combination of having no active Debian package maintainer,
and no concrete plan to address the deprecation of GTK1 (the LCL's oldest
backend, which Lazarus historically shipped with). After being dropped
from Debian, the Lazarus/FPC community appears to be taking the steps
needed to eventually produce compliant packages for re-inclusion. In the
meantime, building from source on Debian and Ubuntu remains possible but
is fraught with difficulty — dependency resolution, FPC bootstrapping,
and the GTK2 backend's GNOME-specific quirks all compound the problem.

This matters because Ubuntu 24.04 LTS is one of the most widely deployed
Linux distributions, and its users have no `apt install lazarus` path.
They must build from source, which means they hit these GNOME/Mutter
bugs on their very first attempt to run the IDE. The combination of
"no package" and "broken on first launch" is a serious barrier to entry
on what is arguably the most common Linux desktop.

Three bugs. Three separate programming issues. All triggered by starting the
IDE for the first time on **Ubuntu 24.04 LTS with two monitors.**

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

All three bugs share the same root cause: **the code was primarily tested
on KDE and other non-GNOME desktops.** The Lazarus developers likely never
saw these problems because KWin handles the edge cases more gracefully.
The first-launch path is different from the subsequent-launch path, and
Mutter's aggressive signal dispatching exposes re-entrancy bugs that KWin
masks.

This is still worth fixing — GNOME is the default desktop on Ubuntu, the
most popular Linux distribution, and with Lazarus dropped from Debian's
repos, the only path for Ubuntu users is building from source. If the IDE
hangs on first launch after a user spent an hour bootstrapping FPC and
compiling the IDE, they don't file a bug — they close the terminal and
pick a different IDE. The Lazarus project cannot afford to lose these
users, especially while working to regain a place in Debian's package
archive.

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

On GNOME, this is the LCL. The API looks beautiful — `TForm`, `TButton`,
`Position := poDefault`, `Constraints.MinHeight`. But to get a window
on screen without it hanging, fighting Mutter, spanning all monitors, or
looping 600,000 times, you have to bend your elbows (don't create handles
during construction), hunch your back (don't set constraints because Mutter
will fight you), and bend your knees (don't resize during resize, don't
show during show, don't call `gdk_window_get_root_origin` during
`size-allocate`).

On KDE, the same code works. KWin is a more forgiving tailor. The suit
fits without contortions. This doesn't mean the suit is well-made — it
means KWin compensates for the LCL's assumptions. Mutter does not.

**The fix for the LCL is still to make the suit fit properly — code that
only works when the window manager is forgiving is fragile code. But the
urgency is lower than we initially thought, and the blame is shared
between the LCL and Mutter.**

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
**Severity:** Medium — GNOME/Mutter-specific; KDE Plasma handles constraints without fighting the user

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

**Environment note:** KWin (KDE Plasma) accepts the same `WM_NORMAL_HINTS`
without restricting window movement. The "fighting" behavior is specific to
Mutter's interpretation of min_size == max_size as a panel-like window.

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

---

## 7. Silent Early Exit: `if Condition then Exit`

**Status:** Coding standard for Eleazar fork

### The Antipattern

```pascal
if not Showing then Exit;
```

This is everywhere in the LCL and IDE. A function silently does nothing
based on a condition the caller can't see. When debugging, you have no
idea the function was called and bailed out. Hours are wasted wondering
"why didn't the height get set?" when the answer is a silent `Exit` on
line 432.

### The Rule

**Never write `if Condition then Exit;` without logging.**

Always:

```pascal
if not Showing then begin
  DebugLn('[DoSetMainIDEHeight] not Showing — skipping');
  Exit;
end;
```

This way, when things don't work, there's a clue. The cost of a
`DebugLn` call that nobody reads is zero. The cost of a silent `Exit`
that hides a bug is hours.

### Why This Matters

`DoSetMainIDEHeight` had `if not Showing then Exit` at the top. On
first launch, `Showing` is `False` because the form hasn't been shown
yet. The function silently did nothing. The toolbar height was never
set. The dock site started at the wrong position. The IDE looked broken.

The fix was to remove the early exit entirely — the height MUST be set
before showing. But finding the bug required reading the function,
noticing the silent exit, and understanding that `Showing` is `False`
during construction. A logged exit would have made it obvious in the
debug log.

### Acceptable Form

```pascal
if not Showing then begin
  DebugLn('[DoSetMainIDEHeight] not Showing — deferring');
  // Queue for later: Application.QueueAsyncCall(@DeferredSetHeight, 0);
  Exit;
end;
```

The key elements: explain WHY you're exiting, and ideally, schedule the
work for later instead of silently dropping it.

---

## 7b. Coding Standard: One Log Per Call in Enable/Disable Functions

**Status:** Coding standard for Eleazar fork

### The Rule

Any function that increments or decrements a lock count — `DisableAutoSizing`,
`EnableAutoSizing`, `BeginFormUpdate`, `EndFormUpdate`, or anything like
them — MUST emit exactly **one** log message per call. Not zero. Not two.
One.

### Why

These functions are the most debugged code in the LCL. When auto-sizing
is stuck, the ONLY way to find the orphaned call is to read the log and
match up every Disable with its Enable. If any call is silent, you have
a gap. If any call logs twice (once for itself, once for the parent
propagation), you have noise that looks like a real call. Both make the
log useless.

One call, one line. Always. Every path through the function hits the
same `DebugLn`. No path skips it.

### Requirements

**1. One `DebugLn`, unconditional, every path.**

No `{$IFDEF}` around the log call. No `if FAutoSizingLockCount=1 then`
gating. The log is not optional. It fires whether you're debugging or
not. The cost of a `DebugLn` is nothing compared to the hours lost
finding a silent mismatch.

**2. The reason is always in the log.**

Even when `{$IFDEF DebugDisableAutoSizing}` is off, the log message
must include enough to identify the caller. Use the caller's name as
a string literal if you must. The point is: when you read the log, you
can see WHO called Disable and WHO called Enable without recompiling.

**3. No nested `if`.**

Flat control flow. Decide what to do, log it, do it. Don't nest
`if Parent<>nil then if FAutoSizingLockCount=1 then`. Each condition
gets its own block or the function is restructured so nesting isn't
needed.

**4. The log line contains: who, what, count, and context.**

```
[DisableAutoSizing] Button1:TButton count=1 parent=Panel1:TPanel reason='loading'
[EnableAutoSizing]  Button1:TButton count=0 parent=Panel1:TPanel reason='loading' → DoAllAutoSize
[DisableAutoSizing] Button1:TButton count=1 parent=nil reason='reparenting'
```

- **Who:** `DbgSName(Self)`
- **What:** function name
- **Count:** the lock count AFTER the inc/dec
- **Context:** parent (or `nil`), reason, and what action was taken
  (propagated to parent, called DoAllAutoSize, did nothing, error)

### Template

```pascal
procedure TControl.DisableAutoSizing(const AReason: string);
var
  Action: string;
begin
  Inc(FAutoSizingLockCount);
  if (FAutoSizingLockCount = 1) and (Parent <> nil) then
    Action := 'propagate to ' + DbgSName(Parent)
  else
    Action := 'no propagation';
  DebugLn(['[DisableAutoSizing] ', DbgSName(Self),
    ' count=', FAutoSizingLockCount,
    ' parent=', DbgSName(Parent),
    ' reason="', AReason, '"',
    ' → ', Action]);
  if (FAutoSizingLockCount = 1) and (Parent <> nil) then
    Parent.DisableAutoSizing('child:' + DbgSName(Self));
end;
```

One call. One log. One line. Always. If you can't see what happened by
reading the log, the log is wrong.

---

## 8. TControl.DisableAutoSizing: A Lock That Isn't a Lock

**Status:** Architectural problem
**Unit:** `lcl/include/control.inc`
**Severity:** Root cause contributor — makes autosize bugs nearly impossible to diagnose

### The Code

```pascal
procedure TControl.DisableAutoSizing
  {$IFDEF DebugDisableAutoSizing}(const Reason: string){$ENDIF};
begin
  inc(FAutoSizingLockCount);
  {$IFDEF DebugDisableAutoSizing}
  if FAutoSizingLockReasons=nil then FAutoSizingLockReasons:=TStringList.Create;
  FAutoSizingLockReasons.Add(Reason);
  {$ENDIF}
  DebugLn([Space(FAutoSizingLockCount*2),'TControl.DisableAutoSizing ',DbgSName(Self),' ',FAutoSizingLockCount]);
  if FAutoSizingLockCount=1 then
  begin
    if Parent<>nil then
    begin
      Parent.DisableAutoSizing{$IFDEF DebugDisableAutoSizing}('TControl.DisableAutoSizing'){$ENDIF};
    end;
  end;
end;
```

### What's Wrong

**1. The debug infrastructure is compiled out by default.**

The `Reason` parameter — the one thing that would tell you WHY
auto-sizing was disabled — only exists when `DebugDisableAutoSizing` is
defined. In a normal build, calls are `DisableAutoSizing` with no
argument. When you're debugging a hang caused by a stuck lock count, you
have no idea which caller incremented it and never decremented it.

The `FAutoSizingLockReasons` string list that tracks the stack of reasons?
Also compiled out. The diagnostic tool exists but is behind a define that
nobody enables in their normal development build.

**2. It's a reference-counted lock that propagates to parents — asymmetrically.**

When `FAutoSizingLockCount` goes from 0 to 1, it calls
`Parent.DisableAutoSizing` — which increments the parent's lock count,
which (if the parent goes from 0 to 1) propagates to the grandparent,
and so on up the tree. `EnableAutoSizing` reverses this.

This means a single mismatched `DisableAutoSizing` on a deeply-nested
control silently locks the entire parent chain. No auto-sizing happens
anywhere in that branch of the control tree. No error. No warning. The
form just never lays out correctly, and you get to guess which of the
hundreds of `DisableAutoSizing` calls forgot its `EnableAutoSizing`.

**3. Parent=nil race: silent corruption.**

Look at what happens when `FAutoSizingLockCount` hits 1 and `Parent`
is `nil`:

```pascal
  if FAutoSizingLockCount=1 then
  begin
    if Parent<>nil then              // Parent is nil → nothing happens
      Parent.DisableAutoSizing(...);
  end;
```

It just... does nothing. No propagation, no logging, no record that
this top-level control is now locked. Is that intentional? Is the
control a top-level form? Was it just reparented? Is it mid-construction
and Parent hasn't been assigned yet? Nobody knows. It's silent.

Now look at `EnableAutoSizing`:

```pascal
  if (FAutoSizingLockCount=0) then
  begin
    if (Parent<>nil) then
      Parent.EnableAutoSizing(...)   // propagate up
    else
      DoAllAutoSize;                 // no parent → auto-size self
  end;
```

The Enable side has DIFFERENT logic from the Disable side. This creates
three race conditions when Parent changes between Disable and Enable:

| Disable time | Enable time | Result |
|---|---|---|
| Parent = nil | Parent = nil | OK — `DoAllAutoSize` runs on self |
| Parent = A | Parent = A | OK — symmetric propagation |
| **Parent = nil** | **Parent = B** | **BUG — `B.EnableAutoSizing` called but `B.DisableAutoSizing` was never called → underflow exception or negative lock count on B** |
| **Parent = A** | **Parent = nil** | **BUG — `A.DisableAutoSizing` was called but `A.EnableAutoSizing` never is → A stays locked forever, auto-sizing never runs on that branch again** |

This isn't hypothetical. Controls get reparented during docking, during
form construction, during `TMainIDE.Create` when dock panels are built
and populated. Every reparenting between a Disable/Enable pair silently
corrupts the lock counts somewhere in the control tree.

**4. The unconditional DebugLn is noise.**

The bare `DebugLn` call (outside the `{$IFDEF}`) fires on EVERY
disable/enable cycle in debug builds. Auto-sizing is disabled and
enabled hundreds of times during form construction. This produces
thousands of log lines that obscure the one line you care about — the
unpaired call. It's the logging equivalent of a car alarm that goes
off every time the wind blows: you learn to ignore it.

**5. The debug mode is a two-API fork that leaks RAM.**

The `{$IFDEF DebugDisableAutoSizing}` doesn't just toggle logging — it
changes the function *signature*. Without the define, it's
`DisableAutoSizing` (no parameters). With it, it's
`DisableAutoSizing(const Reason: string)`. Every callsite in the LCL
has both forms: `{$IFDEF DebugDisableAutoSizing}('reason'){$ENDIF}`.
You're maintaining two different APIs in the same source file, toggled
by a compile flag.

When the define IS on, `FAutoSizingLockReasons` is created on first
Disable and entries are added on every call. Enable deletes matching
entries. But if there's ever a mismatch — and there will be, because
reparenting corrupts the lock counts (see #3 above) — entries
accumulate forever. The TStringList is never freed outside the
`{$IFDEF}` destructor path. So you enable the debug flag to diagnose
why auto-sizing is stuck, and the diagnostic tool itself leaks memory
for every orphaned reason string. You're debugging a leak with a leak.

**6. There's no overflow or underflow protection.**

`FAutoSizingLockCount` is a plain integer. Nothing prevents it from
going negative (double-enable) or overflowing (leaked disables
accumulating forever). A negative count would silently cause auto-sizing
to run when it shouldn't. An ever-growing count would silently prevent
auto-sizing forever. Both failures are silent.

### The Pattern

This is Yossi's suit again. The API looks reasonable — disable
auto-sizing, do your work, re-enable it. But the implementation:
- Hides the only useful diagnostic behind a compile-time flag
- Silently propagates up the control tree
- Has no protection against misuse
- Floods the log with noise that drowns out real problems

To debug an auto-sizing hang, you have to: recompile the LCL with
`-dDebugDisableAutoSizing`, reproduce the bug, wade through thousands
of log lines, and manually match up every Disable/Enable pair to find
the orphan. This is a multi-hour process for what should be a simple
"who forgot to call EnableAutoSizing?" question.

### What It Should Be

```pascal
procedure TControl.DisableAutoSizing(const Reason: string);
begin
  inc(FAutoSizingLockCount);
  FAutoSizingLockReasons.Add(Reason);  // ALWAYS, not just in debug builds
  if FAutoSizingLockCount=1 then
    if Parent<>nil then
      Parent.DisableAutoSizing('child:' + DbgSName(Self));
end;

procedure TControl.EnableAutoSizing(const Reason: string);
begin
  if FAutoSizingLockCount <= 0 then begin
    DebugLn(['ERROR: EnableAutoSizing underflow on ', DbgSName(Self),
      ' reason="', Reason, '"']);
    Exit;
  end;
  // ... remove matching reason, decrement, propagate to parent
end;
```

The `Reason` parameter should always be there. The reason list should
always be tracked. Underflow should be caught and logged. The parent
propagation reason should identify which child caused it. None of this
needs a compile-time flag — a string list add is not a performance
bottleneck compared to the hundreds of GTK round-trips that auto-sizing
already does.

### Files Involved

| File | Role |
|------|------|
| `lcl/include/control.inc` | `DisableAutoSizing` / `EnableAutoSizing` |
| `lcl/controls.pp` | `FAutoSizingLockCount`, `FAutoSizingLockReasons` declarations |
| `lcl/include/wincontrol.inc` | `DoAllAutoSize` — checks `AutoSizingLockCount` |

---

## 9. Selftest-on-Startup That Poisons Its Own Config

**Status:** Design problem
**Unit:** `components/macroscript/registerems.pas`
**Severity:** Medium — package permanently disabled after any startup crash

### The Pattern

The EditorMacroScript package runs a selftest on every IDE startup:

```pascal
conf.SelfTestActive := True;   // flag: "test in progress"
conf.Save;                     // persist to ~/.lazarus/editormacroscript.xml

ok := DoSelfTest;              // run the test

conf.SelfTestActive := False;  // clear the flag
conf.SelfTestFailed := 0;
conf.Save;
```

If the IDE crashes or hangs for ANY reason during startup — not just a
macroscript problem — the `SelfTestActive` flag stays set in the XML.
On next launch, the package sees the stale flag:

```pascal
if conf.SelfTestActive then begin
  conf.SelfTestFailed := EMSVersion;
  conf.SelfTestError := 'failed last time';
  conf.Save;
  MessageDlg('The package selftest was not completed...');
end;
```

The package disables itself permanently. The user sees "EditorMacroScript
has detected a problem and was deactivated" with no way to re-enable it
from the UI. The fix is to manually edit the XML file.

### Why This Is Bad

1. **It punishes the innocent.** Our fresh-install hang had nothing to do
   with PascalScript. But because the IDE hung during startup, the
   selftest flag was left set, and macroscript was disabled on the next
   (fixed) launch.

2. **The error message is misleading.** "The package selftest was not
   completed" implies the package is broken. The real cause is that
   the IDE crashed during startup for an unrelated reason.

3. **There's no recovery path.** No UI to re-enable the package. No
   "try again" button. No timeout. The user has to know to find and
   edit `~/.lazarus/editormacroscript.xml`.

### The Fix

```
~/.lazarus/editormacroscript.xml:
  Set SelfTestFailed="0" and SelfTestError=""
```

### The Better Fix

Don't persist a "test in progress" flag to disk. Instead:
- Run the selftest
- If it fails, record the failure
- If the IDE crashes, that's not a selftest failure — don't treat it as one
- Or at minimum: on next launch, offer "The IDE crashed last time.
  Re-run macroscript selftest? [Yes] [Disable]" instead of silently
  disabling the package

### Files Involved

| File | Role |
|------|------|
| `components/macroscript/registerems.pas` | Selftest runner and config persistence |
| `components/macroscript/emsselftest.pas` | Actual selftest implementation |
| `~/.lazarus/editormacroscript.xml` | Persisted selftest state |

---

## WM_SIZE Feedback Loop: Mutating Geometry Inside a WMSize Handler

**Found:** 2026-04-03  
**Files:** `ide/mainbar.pas`, `lcl/interfaces/gtk2/gtk2callback.inc`, `lcl/interfaces/gtk2/gtk2proc.pp`

### The Bug

`TMainIDEBar.Resizing()` — called from `TScrollingWinControl.WMSize` whenever
GTK delivers a `size-allocate` signal with `FromIntf=True` — was calling
`DoSetMainIDEHeight`, which synchronously wrote `ClientHeight`.

Writing `ClientHeight` inside a WMSize handler re-enters GTK's resize path:

```
GTK size-allocate
  → gtksize_allocateCB
    → SendSizeNotificationToLCL → LM_SIZE (FromIntf=True)
      → TScrollingWinControl.WMSize
        → TMainIDEBar.Resizing
          → DoSetMainIDEHeight
            → ClientHeight := N          ← geometry mutation
              → gtk_widget_set_size_request / size-allocate again
                → all dock sites get WMSize (FromIntf=False)
                  → each resizes its anchored neighbors
                    → neighbors resize back
                      → oscillation: 1396 ↔ 2880 ↔ 1440 ↔ ...
```

The oscillation was visible in the ring buffer: ~7700 WMSize events/second,
sustained, all `FromIntf=False`, widths bouncing between two or three values.
`AutoSizeLock=0` on all recipients — the lock on the *sender* doesn't protect
the *recipients* from being re-entered.

`CoolBarOnChange` and `MainSplitterMoved` also called `SetMainIDEHeight`
directly, and both fired during layout cascades triggered by the resize, adding
more geometry mutations mid-storm.

### The Rule

**Never mutate geometry (ClientHeight, SetBounds, Constraints) synchronously
inside a WMSize handler, a Resizing override, or any callback that fires
during a GTK size-allocate signal.**

GTK fires `size-allocate` synchronously and re-entrantly. Any geometry write
inside the handler causes another `size-allocate` before the first one returns.
The LCL's auto-sizing lock (`DisableAutoSizing`) protects *that control* but
not its unlocked siblings and neighbors, which will process the cascade freely.

### The Fix

`DoSetMainIDEHeight` now only queues a deferred call:

```pascal
procedure TMainIDEBar.DoSetMainIDEHeight(...);
begin
  if FPendingHeightAdjust then Exit;  // coalesce: one async call per storm
  FPendingHeightAdjust := True;
  Application.QueueAsyncCall(@AsyncSetMainIDEHeight, 0);
end;

procedure TMainIDEBar.AsyncSetMainIDEHeight(Data: PtrInt);
begin
  FPendingHeightAdjust := False;
  // recalculate from current state, now safe to write geometry
  ...
  ClientHeight := ANewHeight;
end;
```

No matter how many times `DoSetMainIDEHeight` is called during a storm (7000+
calls/second observed), only one `QueueAsyncCall` is posted. The actual height
adjustment runs once, during the next idle cycle, outside any size-allocate
context.

### Related Fix: GTK size-allocate guard

`gtksize_allocateCB` now skips the LM_SIZE delivery entirely when the target
control has `AutoSizingLockCount > 0` — the LCL is mid-layout for that control,
and delivering a size message now causes the EnableAutoSizing → DoAllAutoSize →
RealizeBounds → size-allocate recursion.

The check uses a class cracker (defined in `gtk2proc.pp`) to access the
protected `TControl.AutoSizingLockCount` field without making it public:

```pascal
type
  TControlCracker = class(TControl);  // local to gtk2proc.pp, never exported

function GTK2ControlIsAutoSizeLocked(AData: gPointer): Boolean; inline;
begin
  Result := (AData <> nil)
        and (TObject(AData) is TControl)
        and (TControlCracker(AData).AutoSizingLockCount > 0);
end;
```

### Why `QueueAsyncCall` and not `PostMessage`

`Application.QueueAsyncCall` runs during the next `Application.Idle` cycle,
after all pending GTK events are processed. The callback fires on the main
thread with no GTK resize signals in flight — safe to call `ClientHeight :=`.
`PostMessage` would deliver during the current event loop iteration, potentially
still inside a resize cascade.

### Files Changed

| File | Change |
|------|--------|
| `ide/mainbar.pas` | `DoSetMainIDEHeight` deferred via `QueueAsyncCall`; `FPendingHeightAdjust` coalescing flag; `AsyncSetMainIDEHeight` callback |
| `lcl/interfaces/gtk2/gtk2callback.inc` | Skip LM_SIZE when `AutoSizingLockCount > 0`; use `GTK2ControlIsAutoSizeLocked` helper |
| `lcl/interfaces/gtk2/gtk2proc.pp` | `TControlCracker` class cracker; `GTK2ControlIsAutoSizeLocked` helper function |
