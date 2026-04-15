# Docking System Design Rules

## Core Principle

**The docking manager owns all sizing decisions. Client windows declare constraints, not enforcement.**

This document outlines the architectural rules for Yossi's docked-only IDE to keep the docking system stable and prevent feedback loops.

## Rule 1: Docking Manager Owns Layout

The docking manager (`TIDEAnchorDockMaster` and its dock sites) is responsible for:
- Calculating and applying all window sizes and positions
- Restoring saved layouts from user preferences
- Querying client windows for size constraints
- Respecting those constraints during layout calculations

**Client windows must NOT reach into the docking hierarchy and force-resize dock sites or sibling controls.**

## Rule 2: Clients Declare Constraints, Not Enforcement

Every dockable window should declare its minimum usable size:

```pascal
// In client window initialization:
Constraints.MinHeight := 300;  // "I'm unusable below this"
Constraints.MinWidth := 400;
```

The docking manager will query these constraints and incorporate them into layout decisions.

**Clients never call docking manager methods to adjust heights or widths.** If a layout violates your constraints, that's a docking system bug.

## Rule 3: No Bidirectional Dependencies

The old code violated this:
- MainIDEBar would calculate coolbar height
- Pass it to `AdjustMainIDEWindowHeight`
- Which would reach into dock site children and force their heights
- Which would trigger wmSize messages
- Which would restart the adjustment timer
- Creating a bidirectional fight

**Unidirectional only:** Client → declare constraints → DockMaster → read constraints → apply layout.

## Rule 4: Don't Decouple Layout With Timers

When layout code feels like it needs to "settle" or "wait for GTK", that is a signal the caller is running in the wrong phase, not a signal to add a timer.

A timer is the weakest form of decoupling available: it reruns arbitrary code at an arbitrary wall-clock moment with no knowledge of what state the program is in. It can fire during modal dialogs, before subsystems are assigned, or after the owning form has begun tearing down. Every timer handler that touches layout becomes a second entry point into code that assumed a specific call order, and the bugs that result are non-deterministic and hard to reproduce.

Prefer, in order:

1. **Do the work in the correct phase.** One-shot init (after constructors, after `IDEDockMaster` is assigned, after desktop restore completes) is almost always the right place for min-constraint enforcement, splitter locking, and similar configuration.
2. **`Application.QueueAsyncCall`** when you genuinely need to defer until the current message is drained — it runs once, in the message loop, not on a wall-clock interval.
3. **An explicit state flag** (`LayoutOperationInProgress`) that makes re-entrant handlers exit early, rather than a timer that papers over the re-entry.

If after all of the above a timer is still the answer, it is an admission that the underlying layout API is wrong. Document that, don't hide it.

## Rule 5: Enforce Window-Level Constraints Only

The main IDE window (MainIDEBar) can enforce constraints on itself:

```pascal
// In MainIDEBar:
Constraints.MinHeight := 800;
Constraints.MinWidth := 1000;
```

But **never enforce constraints on dock sites, splitters, or child windows.** That's the docking manager's job.

## When to Violate These Rules

If you find yourself needing to push back against the docking manager (e.g., "this layout violates my panel's usability"), that's a sign:

1. **Is your constraint declared?** Make sure you're setting `Constraints.MinHeight/MinWidth` on your window
2. **Does the docking manager query it?** Check that the DockMaster is reading your constraints during layout
3. **Is there a docking system bug?** If constraints are set and queried but still violated, file a bug in the docking manager, don't work around it in your client

Never add validation logic in client windows to second-guess the docking manager's sizing. That creates the feedback loop we're trying to avoid.

## Example: Correct Pattern

```pascal
// 1. Client declares constraint
MyPanel.Constraints.MinHeight := 200;

// 2. DockMaster reads it during layout
function TIDEAnchorDockMaster.CalcLayout(...): TRect;
  for each child in layout do
    MinH := child.Constraints.MinHeight;
    // Ensure site height respects MinH
  
// 3. DockMaster applies result
  Child.Height := SafeHeight;

// 4. Client's wmSize fires, but MainIDEBar doesn't fight it
procedure TMainIDEBar.Resizing(State);
  inherited; // no geometry mutation in response to resize signals
```

## Open Issue: Anchor-Docked WMSize Loop (2026-04-14)

With the TMainIDEBar timer removed, the main bar no longer loops. A separate `ELayoutException: WMSize loop detected` burst still fires in the anchor-docking / editor pane subtree during first layout realization. Observed via LCL diag socket:

- 174 loop-exceptions in a 175ms burst at one layout phase
- Affected controls: `TAnchorDockHeader`, `TAnchorDockHostSite`, `TAnchorDockSplitter`, `TTabSheet`, `TSrcEditTabSheet`, `TSrcEditExtendedNotebook`, `TSourcePageControl`, `TSourceNotebook`, `TSynChildWinControl`, `TIDESynEditor`, `TObjectInspectorDlg`, `TProjectInspectorForm`, `TTreeView`, `TPanel`, `TGroupBox`
- Pattern: `BoundsRealized.b` consistently ~973px larger than `NewBoundsRealized.b` (e.g. 4429 vs 3456, 4443 vs 3470). 3456 matches `MaxWidget` screen height from GTK init — so the dock manager is asking for a height that exceeds the physical display, GTK clamps, loop detector fires.

Next diagnostic step: trace who is setting the initial `BoundsRealized` height to 4429 on the anchor-dock tree — likely stale saved-layout values being applied without clamping against `Screen.WorkAreaHeight` before the first `WMSize` round-trip. Candidate files:
- `components/anchordocking/anchordocking.pas` — `TAnchorDockHostSite.BoundsChanged`, layout restore
- `components/anchordocking/anchordockstorage.pas` — saved-layout application
- `components/anchordocking/design/registeranchordocking.pas` — IDE-specific dock master

## Understanding WMSize Messages

WMSize is fundamentally a **notification**, not a command. When you see in the logs:
```
[WMSize] MainIDE:TMainIDEBar W=6144 H=3456 FromIntf=True AutoSizeLock=0
[WMSize] MainIDE:TMainIDEBar W=6144 H=3402 FromIntf=False AutoSizeLock=1
```

This means:
- **FromIntf=True**: GTK resized you (this is what GTK wants)
- **FromIntf=False**: LCL code triggered the resize (you asked for it)
- **AutoSizeLock**: Counter tracking how many DisableAutoSizing/EnableAutoSizing pairs are active

A loop forms when:
1. GTK sends WMSize saying "you're 3456"
2. LCL handler responds by adjusting child geometry
3. That causes LCL to request a different size (FromIntf=False)
4. GTK rejects it and resends "no, you're 3456" (FromIntf=True)
5. Repeat → infinite loop

**Solution:** During layout restore/initialization, set `LayoutOperationInProgress=True` so WMSize handlers exit early instead of responding with geometry changes. Let GTK finish its cascade without interference.

## See Also

- `ide/mainbar.pas:OnHeightSettleTimer` — example of debounce without re-layout
- `ide/mainbar.pas:Resizing` — checks LayoutOperationInProgress flag before starting settle timer
- `ide/envguioptions.pas:TDesktopOpt.RestoreDesktop` — wraps layout restore with flag guards
- `components/ideintf/idewindowintf.pas:SetLayoutOperationInProgress` — global flag control
- `components/anchordocking/design/registeranchordocking.pas:TIDEAnchorDockMaster` — the docking manager implementation
- `AUTOSIZING_STORM_BUG.md` — related history of layout chaos in LCL
