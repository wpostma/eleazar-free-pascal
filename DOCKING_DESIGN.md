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

## Rule 4: Timer Debouncing, Not Height Adjustment

If your window receives many rapid wmSize messages (especially during GTK initialization), use a debounce timer to let things settle:

```pascal
FSettleTimer.Interval := 50;  // Wait 50ms for GTK to go quiet
// Fire once in the timer handler, but DON'T re-layout in response
// Just mark that we've settled and let the docking manager decide what to do next
```

Never use the settle timer to force geometry changes. It's purely for observing when GTK has stopped reshuffling.

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
procedure TMainIDEBar.OnHeightSettleTimer(...);
  // Just observe that GTK has settled
  // Don't call AdjustMainIDEWindowHeight or force any heights
```

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
