# LCL Lifecycle Fix: Phased Form Creation

## The Problem

The LCL collapses three distinct phases into one thunk (`EndFormUpdate`):
1. Handle allocation (CreateHandle/CreateWnd)
2. Child handle creation
3. Showing (gtk_widget_show, focus, events)

When a child control is inserted into a form that isn't fully constructed
yet, `InsertControl` → `UpdateControlState` → `AdjustSize` may trigger
handle creation and showing on a half-built form. GTK fires size-allocate
signals on every mutation, creating feedback loops.

## The Fix: Three-Phase Lifecycle

### Phase 1: Object Construction (already works)
- `TCustomForm.Create` / `CreateNew`
- `BeginFormUpdate` disables autosizing
- Children are created and parented
- NO handles allocated, NO showing

### Phase 2: Handle Allocation (NEW — explicit, batch)
- `TCustomForm.AllocateHandles` — new method
- Creates the GTK window for the form
- Creates handles for ALL children in one pass (top-down)
- Auto-sizing runs once at the end
- GTK widgets exist but are NOT shown (`gtk_widget_show` not called)

### Phase 3: Show (NEW — explicit, after composition is complete)
- `TCustomForm.ShowForm` or the existing `Show`
- Calls `UpdateShowing` which triggers `gtk_widget_show`
- Focus is set, OnShow fires
- Everything is fully composed before anything is visible

## Key Changes

### 1. New flag: `wcfDeferShowing` in `TWinControlFlag`

Added to the existing flag set. When set on a control, `UpdateShowing`
skips the `ChangeShowing` call (the part that calls `gtk_widget_show`).
Handles can still be allocated.

### 2. `UpdateControlState` respects parent form state

When a child's `UpdateControlState` is called, it checks if its parent
form is still in `BeginFormUpdate` (i.e., `FFormUpdateCount > 0`). If so,
it does nothing — handle creation and showing are deferred until the
form says it's ready.

### 3. `EndFormUpdate` orchestrates the phases

Instead of the current behavior (set Visible → triggers everything),
`EndFormUpdate` does:
1. Create handles for the form and all children (batch)
2. Run auto-sizing once
3. THEN trigger showing

### 4. `DoAllAutoSize` respects `wcfDeferShowing`

The auto-size pass that creates handles and calls `UpdateShowing` checks
the flag and skips showing while deferred.

## Files Modified

- `lcl/controls.pp` — add `wcfDeferShowing` flag
- `lcl/include/wincontrol.inc` — `UpdateControlState`, `UpdateShowing`
- `lcl/include/customform.inc` — `EndFormUpdate`, new `AllocateHandles`
- `lcl/forms.pp` — new method declarations
