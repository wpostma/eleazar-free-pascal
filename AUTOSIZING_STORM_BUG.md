# AutoSizing Storm Bug

**Status:** Under investigation
**Severity:** Critical — IDE hangs 2–30 seconds on layout switch, can stack overflow
**Reproducible:** Always, on any docking layout change

## Summary

Switching docking layouts in the IDE triggers ~90,000 redundant
`DisableAutoSizing`/`EnableAutoSizing` cycles in under 2 seconds.
The ring buffer captures the full storm; this document describes the
mechanism and identifies the participants.

## How to Reproduce

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

6. **Unbounded recursion.** The cascade is synchronous and recursive:
   `EnableAutoSizing` → `DoAllAutoSize` → child layout → child
   `DisableAutoSizing` → parent `DisableAutoSizing` → ... → child
   `EnableAutoSizing` → parent `EnableAutoSizing` → `DoAllAutoSize`.
   With a deep enough dock site hierarchy (which the IDE has — 4–5
   levels of nested `TAnchorDockHostSite`), the stack depth grows
   with every cycle. A layout switch with many panels can hang for
   30 seconds, and on pathological layouts the recursion can exhaust
   the stack and segfault. This is not theoretical — it happens on
   GNOME/Mutter (see [RESIZE_LOOP_SEGFAULT.md](RESIZE_LOOP_SEGFAULT.md)).

## The Participants

| Control | Role in storm |
|---------|---------------|
| `MainIDE:TMainIDEBar` | Top-level parent, calls `DoAllAutoSize` on every Enable |
| `ObjectInspectorDlg:TObjectInspectorDlg` → `PnlClient:TPanel` | Repeatedly Disable/Enable, propagates through 3 dock sites to MainIDE |
| `ComponentPageControl:TPageControl` | Direct child of MainIDE, tight Disable/Enable cycle |
| `AnchorDockSite1` (Source Editor) | Propagates to MainIDE |
| `AnchorDockSite9` (Object Inspector) | Intermediate propagation node |
| `AnchorDockSite10` (root dock site) | Intermediate propagation node |
| `AnchorDockSite11` (Messages panel) | Intermediate propagation node |

## Possible Fixes

### 1. Batch the layout switch

The dock manager should `DisableAutoSizing` on `MainIDE` (or the root
dock site) once at the start of the layout switch, do all the
reconfiguration, then `EnableAutoSizing` once at the end. Currently each
individual dock/undock/move operation does its own Disable/Enable pair,
and each one triggers a full layout cascade.

### 2. Dirty-flag in `DoAllAutoSize`

`DoAllAutoSize` could check whether the control tree actually changed
since the last pass and skip if nothing is dirty. Currently it does
full work unconditionally.

### 3. Coalesce at the parent

When `EnableAutoSizing` drops the count to 0 and would call
`DoAllAutoSize`, instead post a deferred layout request (like
`InvalidatePreferredSize` does) and let the event loop coalesce
multiple requests into a single pass.

### 4. Rate-limit `DoAllAutoSize`

If `DoAllAutoSize` has been called within the last N milliseconds,
skip or defer. This is a hack but would cap the storm to a bounded
number of passes.

## Measurement

Captured via the LCL socket inspector ring buffer. One layout switch:

- **90,441 events total** (from baseline of 731)
- **Ring buffer filled** to capacity (65,536) — oldest 25K events lost
- **Duration:** ~2 seconds (18:15:42.982 to 18:15:44.943)
- **Rate:** ~45,000 Disable/Enable cycles per second
- **Lock count range:** 0 to 1 (never batched)

This was a fast case (2 seconds). With more complex layouts, more
docked panels, or on GNOME/Mutter (which fires additional
`size-allocate` signals back into the LCL during layout), the same
storm can take 30 seconds. The stack depth grows with the number of
nested dock sites × the number of cycles, and can overflow.

## Related

- [DISABLE_AUTOSIZING_BUGS.md](DISABLE_AUTOSIZING_BUGS.md)
- [RESIZE_LOOP_SEGFAULT.md](RESIZE_LOOP_SEGFAULT.md)
- [LCL_SOCKET_INSPECTOR.md](LCL_SOCKET_INSPECTOR.md)
