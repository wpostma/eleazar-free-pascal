# AutoSizing Storm Bug

**Status:** Under investigation
**Severity:** Critical — IDE hangs 2–30 seconds on layout switch, access violations on undock
**Reproducible:** Always, on any docking layout change
**Date:** 2026-03-29

## Summary

Two related bugs in the LCL's autosizing/docking interaction:

1. **Storm:** Switching docking layouts triggers ~90,000 redundant
   `DisableAutoSizing`/`EnableAutoSizing` cycles in under 2 seconds,
   hanging the IDE.

2. **Crash:** Programmatic undock (`ManualFloat`) triggers an access
   violation in the GTK2 `size-allocate` callback because GTK
   re-enters the LCL while the control tree is mid-modification.

Both are caused by the same fundamental issue: the LCL's autosizing
propagation protocol interacts badly with GTK's synchronous layout
model.

## How to Reproduce

### Storm (layout switch)

1. Build with `DIAG=1 bash build.sh`
2. Launch the IDE
3. Enable debug logging:
   ```
   python3 tools/lcl-inspector.py find AnchorDock --class AnchorDock --set-debug on
   python3 tools/lcl-inspector.py set-debug MainIDE on
   python3 tools/lcl-inspector.py set-debug ObjectInspectorDlg on
   ```
4. Switch docking layout (View → Desktop → any other layout)
5. Check stats: `python3 tools/lcl-inspector.py stats`

Result: `total_pushed` jumps by 60,000–90,000 in ~2 seconds.

### Crash (programmatic undock)

1. Build and launch as above
2. Run stress test: `bash test-dock-stress.sh 5`
3. Or manually: send undock command during layout switch:
   ```json
   {"cmd":"undock","path":"ObjectInspectorDlg"}
   ```

Result: `EAccessViolation` in `gtksize_allocateCB` → `WndProc`.

## The Crash: GTK Re-Entrancy During Tree Surgery

### What happens

1. Socket command sends `undock` → calls `ManualFloat` on ObjectInspectorDlg
2. `ManualFloat` calls `DisableAutoSizing`, then **reparents the control** —
   removes OI from `AnchorDockSite9`'s children, creates float host
3. That reparenting changes the control tree — OI is removed from the
   dock site's child list
4. GTK sees the reparent and **immediately, synchronously** fires
   `size-allocate` on the dock site that just lost a child
5. `gtksize_allocateCB` → `SendSizeNotificationToLCL` → `WndProc`
   tries to process the size change
6. The dock site's control tree is mid-modification — OI was removed
   but the dock site hasn't finished cleaning up its internal state
7. Something walks a stale pointer → **access violation**

### Captured stack trace (from ring buffer)

```
857  20:11:40.436 TControl.ManualFloat ObjectInspectorDlg:TObjectInspectorDlg
858  20:11:40.446 [HandleException][FIRST] class=EAccessViolation msg="Access violation"
860  $00000000005BE3C3  WndProc,  line 5552 of include/wincontrol.inc
861  $000000000049D96D  WndProc,  line 1518 of include/customform.inc
862  $00000000007DBC0E  DeliverMessage,  line 114 of lclmessageglue.pas
863  $000000000068082D  DeliverMessage,  line 3755 of gtk2proc.inc
864  $000000000068648D  SendSizeNotificationToLCL,  line 6826 of gtk2proc.inc
865  $0000000000690509  gtksize_allocateCB,  line 2535 of gtk2callback.inc
```

### Context: what was happening just before

```
846  [DockMaster.FullRestoreLayout] START Root= Children=1 Scale=True
847  [DockMaster.FullRestoreLayout] Controls(11): Assembler,BreakPoints,...
848  [AnchorDesktop.RestoreDesktop] WorkArea=3840x2033 Tree nodes=1
...  (multiple RestoreLayout cycles as desktops switch)
857  TControl.ManualFloat ObjectInspectorDlg:TObjectInspectorDlg
858  ACCESS VIOLATION
```

The crash happens during `ManualFloat` while the dock master is
restoring a layout — the tree is already in flux from the desktop
switch, and the undock operation adds more tree surgery on top.

### Why GTK is different from Win32

In **Win32/VCL**, `SetWindowPos`/`MoveWindow` completes synchronously
and `WM_SIZE` arrives later through the message queue. It's a
notification after the fact. You can't re-enter the layout engine
because layout changes go through the message queue.

In **GTK**, layout is a two-phase protocol:

1. **size-request** (bottom-up): each widget tells its parent how much
   space it wants
2. **size-allocate** (top-down): each parent tells its children how much
   space they get

When our code calls `gtk_widget_reparent` or `gtk_container_remove`/
`gtk_container_add`, GTK **immediately fires `size-allocate`** on
affected widgets — right there on the call stack, synchronously, before
the Pascal code that triggered the reparent has returned. The LCL's
GTK2 widgetset hooks this signal (`gtksize_allocateCB` in
`gtk2callback.inc`) and translates it into `LM_SIZE` messages sent to
the control.

If the `size-allocate` handler changes the widget tree (like calling
`DisableAutoSizing`/`EnableAutoSizing` → `DoAllAutoSize` →
`RealizeBoundsRecursive` → `gtk_widget_size_allocate` on children),
we **re-enter the GTK layout engine while it's still running**.

There is also a genuinely **asynchronous** path: on GNOME, when a
top-level window changes size, Mutter (the compositor) can decide to
resize it differently (constraints, tiling, HiDPI scaling) and send
an X11 `ConfigureNotify` back. GTK translates this into another
`size-allocate` that arrives through the GLib event loop at an
unpredictable time. This is why the bug is worse on GNOME/Mutter
than on KDE/KWin.

Both paths hit the same `gtksize_allocateCB` → `WndProc` code.

## The Storm Pattern

Three distinct phases observed in a single layout switch, all within
the same 2-second window (18:15:42.982 to 18:15:44.943):

### Phase 1: OI PnlClient ↔ MainIDE ping-pong

The Object Inspector's `PnlClient` panel repeatedly triggers
Disable/Enable cycles that propagate up through the dock site chain
to `MainIDE`:

```
[DisableAutoSizing] OI count=1 reason="child:PnlClient:TPanel"
  → propagate to AnchorDockSite9
    → propagate to AnchorDockSite10
      → propagate to MainIDE
[EnableAutoSizing] OI count=0 reason="child:PnlClient:TPanel"
  → propagate to AnchorDockSite9
    → propagate to AnchorDockSite10
      → MainIDE → DoAllAutoSize
```

`DoAllAutoSize` on `MainIDE` triggers the entire layout to recalculate,
which causes `PnlClient` to Disable/Enable again. This cycle repeats
thousands of times within a single millisecond timestamp.

### Phase 2: ComponentPageControl ↔ MainIDE ping-pong

The component palette (`ComponentPageControl`) does the same thing:

```
[DisableAutoSizing] MainIDE count=1 reason="child:ComponentPageControl"
[EnableAutoSizing]  MainIDE count=0 reason="child:ComponentPageControl"
  → DoAllAutoSize
```

This is a tighter cycle — the PageControl is a direct child of
`MainIDE`, so the propagation is shorter, but it repeats just as many
times.

### Phase 3: AnchorDockSite1 ↔ MainIDE

The Source Editor's dock site joins the storm:

```
[DisableAutoSizing] MainIDE count=1 reason="child:AnchorDockSite1"
[EnableAutoSizing]  MainIDE count=0 reason="child:AnchorDockSite1"
  → DoAllAutoSize
```

### Event frequency analysis

From 65,536 events in the ring buffer:

| Count | Pattern | % |
|-------|---------|---|
| 34,878 | MainIDE ↔ AnchorDockSite2 (Messages) | 53% |
| 14,536 | MainIDE ↔ ComponentPageControl | 22% |
| 11,082 | SourceNotebook ↔ SrcEditNotebook | 17% |
| 5,040 | Everything else | 8% |

92% of events are three identical Disable/Enable ping-pong patterns.

## Key Observations

1. **Lock count never exceeds 1.** Every Disable immediately goes to
   count=1, and every Enable drops back to 0 and triggers `DoAllAutoSize`.
   This means no batching is happening — each child change triggers a
   full layout pass.

2. **All within the same millisecond.** Hundreds of cycles share the
   same timestamp (e.g., all at 18:15:42.982). This is not interleaved
   with the event loop — it's a synchronous cascade within a single
   call frame.

3. **`DoAllAutoSize` is the amplifier.** Every `EnableAutoSizing` that
   drops the count to 0 calls `DoAllAutoSize`, which walks the entire
   control tree and re-layouts everything. This re-layout triggers child
   controls to Disable/Enable, which propagates back up to the parent.

4. **The propagation protocol is the root cause.** When a child calls
   `DisableAutoSizing`, it propagates to its parent. When it calls
   `EnableAutoSizing`, it propagates to the parent, which calls
   `DoAllAutoSize`. The parent's `DoAllAutoSize` touches other children,
   which Disable/Enable, which propagate back to the parent, ad
   infinitum until the layout stabilizes.

5. **No convergence detection.** The LCL has no mechanism to detect
   "nothing changed since last layout" and skip the redundant passes.
   Every `DoAllAutoSize` does full work even if the sizes didn't change.

6. **Unbounded recursion.** The cascade is synchronous and recursive.
   With a deep dock site hierarchy (4–5 levels of nested
   `TAnchorDockHostSite`), the stack depth grows with every cycle.
   A layout switch with many panels can hang for 30 seconds, and on
   pathological layouts the recursion can exhaust the stack and
   segfault.

7. **GTK re-entrancy turns the storm into a crash.** The Disable/Enable
   storm is a performance bug on its own. But combined with GTK's
   synchronous `size-allocate`, it becomes a crash: the storm triggers
   tree modifications, GTK re-enters during those modifications, and
   the LCL walks stale pointers.

## The Participants

| Control | Role in storm |
|---------|---------------|
| `MainIDE:TMainIDEBar` | Top-level parent, calls `DoAllAutoSize` on every Enable |
| `ObjectInspectorDlg` → `PnlClient:TPanel` | Repeatedly Disable/Enable, propagates through 3 dock sites to MainIDE |
| `ComponentPageControl:TPageControl` | Direct child of MainIDE, tight Disable/Enable cycle |
| `AnchorDockSite1` (Source Editor) | Propagates to MainIDE |
| `AnchorDockSite9` (Object Inspector) | Intermediate propagation node |
| `AnchorDockSite10` (root dock site) | Intermediate propagation node |
| `AnchorDockSite11` (Messages panel) | Intermediate propagation node |
| GTK2 `gtksize_allocateCB` | Re-enters LCL during tree surgery, causes AV |
| Mutter compositor | Sends async `ConfigureNotify`, adds more re-entrancy |

## Proposed Fix: Deferred Size-Allocate During Dock Operations

### The idea

During tree surgery (dock/undock/layout restore), defer all GTK
`size-allocate` processing instead of handling it synchronously.
Process the deferred notifications after the surgery is complete.

### Why global, not per-form or per-dock-site

A single undock of ObjectInspectorDlg affects:
- `ObjectInspectorDlg` (being removed)
- `AnchorDockSite9` (losing a child)
- `AnchorDockSite10` (parent, relayouts)
- `MainIDE` (grandparent, relayouts)
- The new float host (being created)

Any of these can receive a `size-allocate` during the surgery. A
per-form flag would need to be set on all of them, but you don't
know the full list in advance because the propagation walks up the
tree dynamically.

The flag must be **global** — one counter (for nesting) that says
"the LCL is currently doing tree surgery, defer all `size-allocate`
processing."

### Design

```pascal
var
  LCLDockOperationCount: Integer = 0;
  DeferredSizeAllocates: <list of (Widget, Allocation) pairs>;

procedure BeginDockOperation;
begin
  Inc(LCLDockOperationCount);
end;

procedure EndDockOperation;
begin
  Dec(LCLDockOperationCount);
  if LCLDockOperationCount = 0 then
    ProcessDeferredSizeAllocates;
end;
```

In `gtksize_allocateCB` (our code, in `gtk2callback.inc`):

```pascal
if LCLDockOperationCount > 0 then begin
  QueueDeferredSizeAllocate(Widget, Allocation);
  Exit;
end;
// ... normal processing ...
```

### Where to call BeginDockOperation / EndDockOperation

| Call site | Scope |
|-----------|-------|
| `TControl.ManualFloat` | Wraps the undock + reparent |
| `TControl.ManualDock` | Wraps the dock + reparent |
| `TAnchorDockMaster.FullRestoreLayout` | Wraps the entire desktop switch |

The counter handles nesting: `FullRestoreLayout` calls `Begin`, then
internally calls `ManualFloat`/`ManualDock` which call `Begin`/`End`
for their own operations, but the outer `End` is what actually
processes the deferred queue.

### What the deferred queue contains

Each entry is a `(GtkWidget, GtkAllocation)` pair — the widget and
the size GTK allocated to it. When `EndDockOperation` calls
`ProcessDeferredSizeAllocates`, it iterates the queue and calls
`SendSizeNotificationToLCL` for each entry, in order.

### Will GTK tolerate ignored size-allocate?

GTK expects `size-allocate` to position the widget's children. If we
swallow it and do nothing, the widget may paint at the wrong size
temporarily. But:

1. The defer period is very short — from `BeginDockOperation` to
   `EndDockOperation`, typically a single synchronous call.
2. The deferred processing happens immediately after, not on the next
   idle cycle.
3. A brief visual glitch during a dock operation is vastly better than
   an access violation or a 30-second hang.
4. The final `ProcessDeferredSizeAllocates` delivers all the size
   notifications, so the final state is correct.

### What this fixes

- **Crash (AV):** Eliminated. GTK can't re-enter the LCL during tree
  surgery because `size-allocate` is deferred.
- **Storm (partially):** The deferred queue collapses redundant
  notifications — if the same widget receives 50 `size-allocate`
  calls during the defer period, only the last one matters.
- **Stack overflow:** The synchronous cascade is broken because
  `size-allocate` no longer triggers `DoAllAutoSize` mid-surgery.

### What this does NOT fix

- **The 0→1→0 ping-pong in DisableAutoSizing/EnableAutoSizing.** The
  internal LCL storm still happens — `DoAllAutoSize` still triggers
  child Disable/Enable cascades. But without GTK re-entrancy
  amplifying it, the storm is bounded and much faster.
- **Convergence.** `DoAllAutoSize` still does full work even when
  nothing changed. A dirty-flag would help but is a separate fix.

### Implementation plan

1. Add `LCLDockOperationCount` and the deferred queue to the GTK2
   widgetset (not the LCL core — this is GTK-specific).
2. Add `BeginDockOperation`/`EndDockOperation` as widgetset methods
   or as globals in a shared unit.
3. Wrap `ManualFloat` and `ManualDock` in `control.inc`.
4. Wrap `FullRestoreLayout` in `anchordocking.pas`.
5. Modify `gtksize_allocateCB` to check the counter and defer.
6. Test with `test-dock-stress.sh` — expect zero AVs and reduced
   event counts.

## Other Fix Ideas (lower priority)

### Batch the layout switch

The dock manager should `DisableAutoSizing` on `MainIDE` (or the root
dock site) once at the start of the layout switch, do all the
reconfiguration, then `EnableAutoSizing` once at the end. Currently each
individual dock/undock/move operation does its own Disable/Enable pair,
and each one triggers a full layout cascade.

### Dirty-flag in `DoAllAutoSize`

`DoAllAutoSize` could check whether the control tree actually changed
since the last pass and skip if nothing is dirty. Currently it does
full work unconditionally.

### Coalesce at the parent

When `EnableAutoSizing` drops the count to 0 and would call
`DoAllAutoSize`, instead post a deferred layout request (like
`InvalidatePreferredSize` does) and let the event loop coalesce
multiple requests into a single pass.

### Make tree walks tolerant of modification

The code that walks the control tree during `DoAllAutoSize` could
snapshot the child list before iterating, so that concurrent
modifications (from GTK re-entrancy) don't cause stale pointer
access. This is a defense-in-depth measure, not a fix for the storm.

### Rate-limit `DoAllAutoSize`

If `DoAllAutoSize` has been called within the last N milliseconds,
skip or defer. This is a hack but would cap the storm to a bounded
number of passes.

## Measurement

Captured via the LCL socket inspector ring buffer.

### Layout switch storm

- **90,441 events total** (from baseline of 731)
- **Ring buffer filled** to capacity (65,536) — oldest 25K events lost
- **Duration:** ~2 seconds (18:15:42.982 to 18:15:44.943)
- **Rate:** ~45,000 Disable/Enable cycles per second
- **Lock count range:** 0 to 1 (never batched)

With more complex layouts or on GNOME/Mutter, the same storm can
take 30 seconds.

### Stress test crash

- **test-dock-stress.sh** — automated undock/dock/resize/layout-switch
- 3 rounds of undock→resize→dock→switch produced 2 access violations
- Both AVs in `gtksize_allocateCB` → `WndProc` during `ManualFloat`
- Crash occurs when GTK fires `size-allocate` synchronously during
  a control reparent operation

## Diagnostic Tools

All data was captured using the LCL socket inspector:

```bash
# Enable debug on all dock components
python3 tools/lcl-inspector.py find AnchorDock --class AnchorDock --set-debug on

# Check for exceptions
python3 tools/lcl-inspector.py events --max 1000 | grep -i exception

# Run stress test
bash test-dock-stress.sh 5

# Check event rate
python3 tools/lcl-inspector.py stats

# Inspect dock hierarchy
python3 -c "... {'cmd':'dock_state'} ..."

# Switch desktop programmatically
python3 -c "... {'cmd':'switch_desktop','name':'default'} ..."
```

## Related

- [DISABLE_AUTOSIZING_BUGS.md](DISABLE_AUTOSIZING_BUGS.md) — missing try..finally in Disable/Enable pairs
- [RESIZE_LOOP_SEGFAULT.md](RESIZE_LOOP_SEGFAULT.md) — the resize loop variant on GNOME
- [LCL_SOCKET_INSPECTOR.md](LCL_SOCKET_INSPECTOR.md) — diagnostic infrastructure design
