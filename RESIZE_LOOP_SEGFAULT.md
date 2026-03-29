# The DisableAutoSizing Resize Loop Segfault

**Date:** 2026-03-28
**Status:** Fixed (workaround: commented out the offending calls)
**Severity:** Critical — segfault during normal IDE use, preceded by visual seizure
**Related:** [lazarus-antipatterns.md](lazarus-antipatterns.md) §1 (Endless Recursion in Event Callbacks)

---

## Symptoms

After re-enabling `DisableAutoSizing`/`EnableAutoSizing` in
`TMainIDEBar.DoSetMainIDEHeight` (which had been intentionally commented
out to stop the recursion described in `lazarus-antipatterns.md` §1), the
IDE exhibits:

1. **Visual seizure.** The main window shakes, resizes rapidly, and
   redraws in tight loops. The user described it as "went nuts."

2. **Segmentation fault.** The process crashes with SIGSEGV in
   `TControl.GetText` at `control.inc:3632`, accessing a freed object.

These two symptoms are not two bugs. They are one bug with two phases.

---

## The Full Call Chain

Read bottom-up. Frame numbers match the GDB backtrace.

### Phase 1: The Resize Loop (frames #204 → #120)

```
#204  lazarus.pp:169                    Application.Run — normal event loop
#186  gtk2wsforms.pp:250                Gtk2FormEvent calls Application.ProcessMessages
#170  gtk2callback.inc:2594             gtkconfigureevent — GTK configure event on main window
#169  gtk2callback.inc:2535             gtksize_allocateCB
#168  gtk2proc.inc:6726                 SendSizeNotificationToLCL
#167  gtk2proc.inc:7159                 SetWindowSizeAndPosition
#166  gtk_widget_size_allocate          (GTK internal)
  ... 20+ frames of nested GTK size-allocate signals bouncing through
  ... child widgets, each one firing g_signal_emit → g_closure_invoke →
  ... gtk_widget_size_allocate cascades ...
#141  control.inc:5898                  EnableAutoSizing → DoAllAutoSize
#140  wincontrol.inc:3685               DoAllAutoSize
#139  wincontrol.inc:8759               RealizeBoundsRecursive (on main form)
#138  wincontrol.inc:8759               RealizeBoundsRecursive (on child)
#137  wincontrol.inc:8759               RealizeBoundsRecursive (on grandchild)
#136  wincontrol.inc:8762               RealizeBoundsRecursive (on great-grandchild)
#135  wincontrol.inc:8724               RealizeBounds
#134  wincontrol.inc:8673               DoSendBoundsToInterface
#133  gtk2wscontrols.pp:637             SetBounds → AWidth=2895, AHeight=32005 ← INSANE
  ... GTK processes the 32005-pixel-tall allocation, fires more
  ... size-allocate signals back into the LCL ...
#120  application.inc:1298              HandleException — an exception was raised
```

**The height value `32005` is the smoking gun.** The window is being
sized to thirty-two thousand pixels tall. This is not a valid height.
It's the result of unbounded recursive growth: each iteration of the
resize loop adds to the height because `DoAllAutoSize` →
`RealizeBoundsRecursive` sends the accumulated bounds to GTK, GTK fires
`size-allocate` back, and the LCL processes it as a new resize, adding
more height. Frame #141 shows `AHeight=32163`. Frame #133 shows
`AHeight=32005`. The numbers are different because different controls
in the tree are being realized with different accumulated insanity.

### Phase 2: The Exception Dialog (frames #120 → #30)

```
#120  application.inc:1298              HandleException
#119  lclexceptionstacktrace.pas:28     HandleApplicationException
#118  application.inc:1639              ShowException — shows modal error dialog
#117  lclintf.inc:525                   PromptUser
#116  lclintf.inc:361                   PromptUser
#115  gtk2lclintf.inc:1314              PromptUser — calls gtk_dialog_run
#114  gtk_dialog_run                    GTK modal dialog event loop
  ... GTK processes events inside the modal dialog ...
  ... ANOTHER size-allocate fires on the main window ...
  ... this re-enters the LCL ...
#30   application.inc:1275              HandleException — SECOND exception handler
#29   fpc_do_exit                       Halt() called
#28   SYSTEM_$$_INTERNALEXIT
#27   SYSTEM_$$_DOEXITPROC
```

The key catastrophe: **`gtk_dialog_run` processes pending GTK events.**
One of those pending events is another `size-allocate` on the main
window (because the first resize loop left dozens of queued allocations).
This triggers a second exception. The second `HandleException` calls
`Halt`, which begins program termination while we're still inside
`gtk_dialog_run`, which is still inside the first `HandleException`.

### Phase 3: The Use-After-Free (frames #27 → #0)

```
#27   SYSTEM_$$_DOEXITPROC              Finalization begins
#26   forms.pp:2100                     BeforeFinalization
#25   application.inc:1135              DoBeforeFinalization
#24   SYSTEM_$$_HALT$LONGINT            TObject.Free chain begins
#23   main.pp:1879                      TMainIDE.Destroy
#22   formeditor.pp:89                  FreeFormEditor
#21   SYSTEM_$$_TOBJECT_$__$$_FREE
#20   customformeditor.pp:542           TCustomFormEditor.Destroy
#19   SYSTEM_$$_TOBJECT_$__$$_FREE      FreeAndNil
#18   SYSUTILS_$$_FREEANDNIL$TOBJECT
#17   SYSTEM_$$_TOBJECT_$__$$_FREE
#16   ../designer/jitforms.pp:747       TJITForms.Destroy
#15   ../designer/jitforms.pp:796       DestroyJITComponent(Index=0)
#14   SYSTEM_$$_TOBJECT_$__$$_FREE
#13   customform.inc:138                TCustomForm.Destroy
#12   scrollingwincontrol.inc:360       TScrollingWinControl.Destroy
#11   customcontrol.inc:40              TCustomControl.Destroy
#10   wincontrol.inc:6795               TWinControl.Destroy
#9    control.inc:5246                  TControl.Destroy
#8    lclclasses.pp:154                 TLCLComponent.Destroy
#7    CLASSES$_$TCOMPONENT_$__$$_DESTROY
#6    CLASSES$_$TCOMPONENT_$__$$_REMOVEFREENOTIFICATIONS
#5    propedits.pp:8190                 TPropertyEditorHook.Notification(opRemove)
#4    propedits.pp:8146                 SetLookupRoot(nil) — iterates handlers
#3    objectinspector.pp:4674           HookLookupRootChange
#2    editbtn.pas:1380                  ResetFilter → Filter := ''
#1    editbtn.pas:1224                  SetFilter → Text := AValue → calls GetText
#0    control.inc:3632                  GetText → SIGSEGV
```

Here's what happened:

1. `TMainIDE.Destroy` destroys the form editor.
2. The form editor destroys JIT forms.
3. Destroying a JIT component triggers `RemoveFreeNotifications` on
   `TComponent.Destroy`.
4. `TPropertyEditorHook.Notification` receives `opRemove` and calls
   `SetLookupRoot(nil)`.
5. `SetLookupRoot(nil)` iterates the `htChangeLookupRoot` handler list
   and calls each one.
6. `TObjectInspectorDlg.HookLookupRootChange` is called. It calls
   `CompFilterEdit.ResetFilter`.
7. `ResetFilter` sets `Filter := ''`.
8. The `SetFilter` setter reads `Text` (to check `if Text=AValue`).
9. `Text` calls `GetText`.
10. `GetText` at line 3632 does:
    ```pascal
    GetTextMethod := TMethod(@Self.GetTextBuf);
    ```
    This dereferences the VMT of `Self`. But `Self` (`CompFilterEdit`,
    a `TCustomControlFilterEdit` at address `0x7fffd31cbd10`) has
    **already been destroyed**. Its VMT pointer is garbage. Accessing
    it triggers the segfault.

### Why Was CompFilterEdit Already Destroyed?

Because we're in `DoExitProc` — program finalization. The order of
destruction is:

1. `TMainIDE.Destroy` runs first (frame #23)
2. This destroys the form editor and its JIT forms
3. JIT form destruction fires `RemoveFreeNotifications`
4. One notification reaches the `TPropertyEditorHook`
5. The hook tries to notify the Object Inspector
6. The Object Inspector tries to access its `CompFilterEdit`
7. But `CompFilterEdit` was already freed earlier in the destruction
   sequence (either by the Object Inspector's own partial destruction,
   or by the form hierarchy teardown that already ran)

This is a classic **destructor ordering problem**: component A's
destructor notifies component B, but B (or B's children) have already
been freed. The notification system doesn't know the recipient is dead
because `RemoveFreeNotifications` iterates the notification list of the
*dying* component, not the *notified* component.

---

## Root Cause

**`DisableAutoSizing`/`EnableAutoSizing` in `DoSetMainIDEHeight`
creates a re-entrant GTK size-allocate loop.**

The mechanism:

```
DoSetMainIDEHeight is called
  DisableAutoSizing('TMainIDEBar.DoSetMainIDEHeight')
    increments FAutoSizingLockCount, defers sizing
  ... modifies ClientHeight ...
  EnableAutoSizing('TMainIDEBar.DoSetMainIDEHeight')
    decrements FAutoSizingLockCount to 0
    calls DoAllAutoSize                          ← HERE
      calls RealizeBoundsRecursive
        sends bounds to GTK via SetBounds/SetWidgetSizeAndPosition
          GTK fires size-allocate signal
            LCL receives WMMove / WMSize
              SetBounds fires again
                EnableAutoSizing fires again
                  DoAllAutoSize fires again
                    ... ad infinitum
```

The `EnableAutoSizing` call at the end of `DoSetMainIDEHeight` is the
detonator. It releases all the deferred sizing at once, which sends
bounds to GTK, which fires signals back, which re-enters the LCL sizing
code. Without a re-entrancy guard, the height grows unboundedly.

This is the exact same bug documented in `lazarus-antipatterns.md` §1,
but now observed through a complete crash rather than just a hang. The
previous documentation described the infinite recursion. This document
describes what happens AFTER the recursion is detected (by the runtime
or by the user) and the app tries to shut down: a cascade of
exception-inside-exception-inside-finalization that ends in a
use-after-free segfault.

---

## The Code — And The Misdiagnosis

**Initial (wrong) fix:** Comment out the `DisableAutoSizing`/
`EnableAutoSizing` pair in `DoSetMainIDEHeight`.

**Corrected understanding:** The pair is fine. It was written by Juha
(lazarus-ide.org core maintainer) and is the standard LCL batching
pattern. It works correctly when `DoSetMainIDEHeight` is called from
safe contexts: `SetMainIDEHeight`, `InitPaletteAndCoolBar`,
`MainSplitterMoved`, etc.

**The actual bug** was that the *original upstream code* called
`DoSetMainIDEHeight` from inside `TMainIDEBar.Resizing` — which sits
on the GTK `size-allocate` callback chain. In THAT context,
`EnableAutoSizing` → `DoAllAutoSize` → `RealizeBoundsRecursive` sends
bounds to GTK, GTK fires `size-allocate` back, and the loop begins.

**The real fix** (commit `c7de5ca758`) was to remove the call from
`Resizing` entirely:

```pascal
procedure TMainIDEBar.Resizing(State: TWindowState);
begin
  // Never adjust height synchronously during a resize/move signal.
  inherited Resizing(State);
end;
```

With `Resizing` neutered, the `DisableAutoSizing`/`EnableAutoSizing`
pair in `DoSetMainIDEHeight` is safe and has been **restored**. The
crash documented here occurred during a transitional state where the
refactor in commit `cdb7d19b47` (changing the `DisableAutoSizing`
signature) accidentally re-enabled the pair while also being called
from inside the signal handler chain.

---

## The Real Problem: Calling Context, Not The Function

The `DisableAutoSizing`/`EnableAutoSizing` pair in `DoSetMainIDEHeight`
was written by Juha and is the correct LCL batching pattern. The pair
itself is not the bug.

The bug is **who calls `DoSetMainIDEHeight`**. The upstream code had
`Resizing` calling it:

```
GTK size-allocate
  → gtksize_allocateCB
    → SendSizeNotificationToLCL
      → DeliverMessage
        → TMainIDEBar.WndProc
          → TCustomForm.WMSize
            → TMainIDEBar.Resizing
              → DoSetMainIDEHeight     ← called from signal handler!
                → EnableAutoSizing     ← fires DoAllAutoSize
                  → RealizeBoundsRecursive
                    → GTK size-allocate  ← re-entrant!
```

You cannot call `EnableAutoSizing` (and thus `DoAllAutoSize`) from
inside a GTK signal handler that is itself triggered by sizing. The
`DoAllAutoSize` will send bounds back to GTK, GTK will fire
`size-allocate` again, and you have unbounded recursion.

**The fix is not to remove the pair — it's to ensure `DoSetMainIDEHeight`
is never called from `Resizing` (or any other GTK signal handler path).**

This is a classic instance of the "Protocols Between Objects Without
Contracts" problem from `lazarus-antipatterns.md` §0: a function that
is safe in one calling context and deadly in another, with nothing in
the API to distinguish them. Juha solved the batching problem. Someone
called it from the wrong place. Everyone spent days debugging the
resulting explosion instead of the one-line root cause.

---

## The Three-Layer Catastrophe

This crash demonstrates why the LCL's auto-sizing architecture is
so fragile. Three independent design problems combined into one
segfault:

**Layer 1: Re-entrant sizing with no guard.**
`EnableAutoSizing` → `DoAllAutoSize` → `RealizeBoundsRecursive` sends
bounds to GTK. GTK fires `size-allocate` back. The LCL processes it as
a new event and re-enters. Height spirals to 32,000px. This is
`lazarus-antipatterns.md` §1.

**Layer 2: Exception inside a modal dialog event loop.**
The absurd height causes an exception. `HandleException` shows a dialog
via `gtk_dialog_run`. `gtk_dialog_run` processes pending events. A
pending `size-allocate` triggers a SECOND exception. The second
`HandleException` calls `Halt`. Now we're tearing down the program from
inside a dialog that's inside an exception handler that's inside a
size-allocate callback. The call stack is 200+ frames deep.

**Layer 3: Notification to a dead object during finalization.**
`Halt` → finalization → `TMainIDE.Destroy` → `FreeFormEditor` →
JIT form destruction → `RemoveFreeNotifications` →
`TPropertyEditorHook.Notification(opRemove)` → `SetLookupRoot(nil)` →
`HookLookupRootChange` → `CompFilterEdit.ResetFilter` →
`CompFilterEdit.GetText` → SIGSEGV. The `CompFilterEdit` was already
freed. Nobody checked.

Each layer is a well-known class of bug. Together they form an
impenetrable crash that cannot be understood from the segfault alone —
you have to read the entire 200-frame backtrace to understand that a
resize loop caused an exception that caused a shutdown that caused a
use-after-free.

---

## Lessons

1. **`DisableAutoSizing`/`EnableAutoSizing` is not safe inside
   size-allocate handlers.** The `EnableAutoSizing` path calls
   `DoAllAutoSize` which re-enters GTK. In a notification handler,
   this creates unbounded recursion. The pair should only be used in
   code that is NOT on the `gtksize_allocateCB` → `DeliverMessage` →
   `WndProc` call path.

2. **`gtk_dialog_run` processes events.** Showing an error dialog from
   inside an event handler means all pending events — including the ones
   that caused the error — will be processed. If those events cause more
   errors, you get cascading exceptions and forced shutdown.

3. **`RemoveFreeNotifications` during finalization is dangerous.** The
   notification recipient may have been destroyed before the notifier.
   The LCL's `TPropertyEditorHook.Notification` calls
   `SetLookupRoot(nil)` which iterates handlers without checking if the
   handler's owner is still alive.

4. **32,000-pixel heights are never valid.** A sanity check in
   `DoSetMainIDEHeight` (or in `SetBounds`) clamping to screen
   dimensions would have caught this before the exception. The height
   spiral would have been visible as a clamped-but-wrong layout instead
   of a crash.

---

## Files Involved

| File | Role |
|------|------|
| `ide/mainbar.pas:438,474` | `DoSetMainIDEHeight` — the `DisableAutoSizing`/`EnableAutoSizing` pair that triggers the loop |
| `lcl/include/control.inc:5898` | `EnableAutoSizing` → `DoAllAutoSize` — the detonator |
| `lcl/include/control.inc:3632` | `GetText` — the crash site (VMT dereference on freed object) |
| `lcl/include/wincontrol.inc:3685` | `DoAllAutoSize` — runs `RealizeBoundsRecursive` |
| `lcl/include/wincontrol.inc:8759` | `RealizeBoundsRecursive` — sends bounds to GTK |
| `lcl/interfaces/gtk2/gtk2callback.inc:2535` | `gtksize_allocateCB` — GTK re-entry point |
| `lcl/interfaces/gtk2/gtk2proc.inc:6826` | `SendSizeNotificationToLCL` |
| `lcl/interfaces/gtk2/gtk2proc.inc:7159` | `SetWindowSizeAndPosition` |
| `lcl/interfaces/gtk2/gtk2wsforms.pp:190,250` | `Gtk2FormEvent` — calls `ProcessMessages` inside event handler |
| `components/ideintf/objectinspector.pp:4674` | `HookLookupRootChange` — calls `ResetFilter` on dead control |
| `components/ideintf/propedits.pp:8190` | `TPropertyEditorHook.Notification` — calls `SetLookupRoot(nil)` during destruction |
| `lcl/editbtn.pas:1224` | `SetFilter` — calls `GetText` on dead `CompFilterEdit` |

---

## GDB Backtrace (Full)

```
Thread 1 "lazarus" received signal SIGSEGV, Segmentation fault.
0x00000000005cd4fb in GetText (this=0x7fffd31cbd10) at include/control.inc:3632
3632      GetTextMethod := TMethod(@Self.GetTextBuf);

#0  GetText (this=0x7fffd31cbd10)                           at control.inc:3632
#1  SetFilter (this=0x7fffd31cbd10, AValue=...)             at editbtn.pas:1224
#2  ResetFilter (this=0x7fffd31cbd10)                       at editbtn.pas:1380
#3  HookLookupRootChange (this=0x7fffd31c85b0)              at objectinspector.pp:4674
#4  SetLookupRoot (this=0x7ffff42ecf80, APersistent=0x0)    at propedits.pp:8146
#5  Notification (this=0x7ffff42ecf80, AComponent=0x7fffd1e3ae30, Operation=opRemove)
                                                             at propedits.pp:8190
#6  CLASSES$_$TCOMPONENT_$__$$_REMOVEFREENOTIFICATIONS ()
#7  CLASSES$_$TCOMPONENT_$__$$_DESTROY ()
#8  Destroy (this=0x7fffd1e3ae30)                           at lclclasses.pp:154
#9  Destroy (this=0x7fffd1e3ae30)                           at control.inc:5246
#10 Destroy (this=0x7fffd1e3ae30)                           at wincontrol.inc:6795
#11 Destroy (this=0x7fffd1e3ae30)                           at customcontrol.inc:40
#12 Destroy (this=0x7fffd1e3ae30)                           at scrollingwincontrol.inc:360
#13 Destroy (this=0x7fffd1e3ae30)                           at customform.inc:138
#14 SYSTEM$_$TOBJECT_$__$$_FREE ()
#15 DestroyJITComponent (this=0x7fffefa4cd10, Index=0)      at jitforms.pp:796
#16 Destroy (this=0x7fffefa4cd10)                           at jitforms.pp:747
#17 SYSTEM$_$TOBJECT_$__$$_FREE ()
#18 SYSUTILS_$$_FREEANDNIL$TOBJECT ()
#19 Destroy (this=0x7fffefa33de0)                           at customformeditor.pp:542
#20 SYSTEM$_$TOBJECT_$__$$_FREE ()
#21 FreeFormEditor ()                                       at formeditor.pp:89
#22 Destroy (this=0x7ffff4a53bb0)                           at main.pp:1879
#23 SYSTEM$_$TOBJECT_$__$$_FREE ()
#24 DoBeforeFinalization (this=0x7ffff699f890)               at application.inc:1135
#25 BeforeFinalization ()                                    at forms.pp:2100
#26 SYSTEM_$$_DOEXITPROC ()
#27 SYSTEM_$$_INTERNALEXIT ()
#28 fpc_do_exit ()
#29 SYSTEM_$$_HALT$LONGINT ()
#30 HandleException (this=0x7ffff699f890, Sender=0x0)       at application.inc:1275
    ... (the second exception handler — called Halt)
#31-#96: Cascading GTK size-allocate signals through child widgets
    (20+ nested g_closure_invoke → gtk_widget_size_allocate cycles)
#97  SetWindowSizeAndPosition (AWinControl=0x7fffef6d9970)  at gtk2proc.inc:7159
#98  SendSizeNotificationToLCL (aWidget=0x3279080)          at gtk2proc.inc:6726
#99  gtksize_allocateCB                                     at gtk2callback.inc:2535
#100 gtkconfigureevent                                      at gtk2callback.inc:2594
#101 Gtk2FormEvent                                          at gtk2wsforms.pp:190
    ... more GTK signal dispatch ...
#114 gtk_dialog_run ()                — INSIDE THE ERROR DIALOG
#115 PromptUser                                             at gtk2lclintf.inc:1314
    ... (the first exception handler — ShowException → PromptUser)
#120 HandleException                                        at application.inc:1298
#121-#132: GTK size-allocate cascade
#133 SetBounds (AHeight=32005)                              at gtk2wscontrols.pp:637
#134-#140: RealizeBoundsRecursive chain
#141 EnableAutoSizing                                       at control.inc:5898
    ... (this is the EnableAutoSizing that triggered DoAllAutoSize)
#142 SetBounds (AHeight=32163)                              at wincontrol.inc:8294
    ... WMMove → SetBounds → EnableAutoSizing → DoAllAutoSize
#147 TMainIDEBar.WndProc                                    at mainbar.pas:624
    ... GTK size-allocate entry chain
#186 Gtk2FormEvent → ProcessMessages                        at gtk2wsforms.pp:250
    ... main event loop GTK signal dispatch
#204 $main ()                                               at lazarus.pp:169
```
