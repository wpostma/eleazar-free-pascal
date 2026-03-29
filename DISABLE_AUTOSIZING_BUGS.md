# DisableAutoSizing/EnableAutoSizing Bug Report

## Summary
Found **critical bugs** in LCL components where `DisableAutoSizing` is called without proper exception safety using `try..finally` blocks.

---

## FORM UPDATE PAIR: BeginFormUpdate / EndFormUpdate

Related pair with similar exception safety issues.

**Purpose:** Similar to DisableAutoSizing/EnableAutoSizing but for entire form construction. Prevents child controls from being shown and sized before the form construction is complete.

**Classes:** `TCustomForm` and descendants

**Implementation:** `FFormUpdateCount` counter-based locking (customform.inc:2879-2889)

---

### 3. **TCustomDockForm.Create** (customdockform.inc:56-66) - FORM UPDATE PAIR

**Location:** [customdockform.inc](customdockform.inc#L56)

**Bug:**
```pascal
constructor TCustomDockForm.Create(TheOwner: TComponent);
begin
  BeginFormUpdate;  // LINE 58

  CreateNew(TheOwner,0);    // ⚠️ CAN THROW EXCEPTION
  AutoScroll := False;
  BorderStyle := bsSizeToolWin;
  DockSite := True;
  FormStyle := fsStayOnTop;
  EndFormUpdate;  // LINE 64 - MAY NOT REACH
end;
```

**Problem:**
- If `CreateNew()` or any property assignment throws exception, `EndFormUpdate` is never called
- `FFormUpdateCount` remains > 0 permanently
- Form stays in "under construction" state
- Child controls never get sized/shown properly
- Higher severity than DisableAutoSizing because it affects entire form initialization

**Impact:** CRITICAL - Form becomes unusable

**Fix:** Add try..finally
```pascal
constructor TCustomDockForm.Create(TheOwner: TComponent);
begin
  BeginFormUpdate;
  try
    CreateNew(TheOwner,0);
    AutoScroll := False;
    BorderStyle := bsSizeToolWin;
    DockSite := True;
    FormStyle := fsStayOnTop;
  finally
    EndFormUpdate;
  end;
end;
```

---

### 4. **TCalculatorForm.Create** (calcform.pas:676-682) - FORM UPDATE PAIR

**Location:** [calcform.pas](calcform.pas#L676)

**Bug:**
```pascal
constructor TCalculatorForm.Create(AOwner: TComponent; ALayout: TCalculatorLayout);
begin
  BeginFormUpdate;

  inherited CreateNew(AOwner, 0);  // ⚠️ CAN THROW EXCEPTION
  InitForm(ALayout);                 // ⚠️ CAN THROW EXCEPTION
  EndFormUpdate;  // MAY NOT REACH
end;
```

**Problem:**
- If `CreateNew()` or `InitForm()` throws exception, `EndFormUpdate` is never called
- `FFormUpdateCount` remains > 0 permanently
- Form initialization state is broken
- Same critical impact as TCustomDockForm

**Impact:** CRITICAL - Form becomes unusable

**Fix:** Add try..finally
```pascal
constructor TCalculatorForm.Create(AOwner: TComponent; ALayout: TCalculatorLayout);
begin
  BeginFormUpdate;
  try
    inherited CreateNew(AOwner, 0);
    InitForm(ALayout);
  finally
    EndFormUpdate;
  end;
end;
```

---

## CRITICAL BUGS (Missing try..finally guards) - ORIGINAL LIST

### 1. **TCustomButtonPanel.DoShowButtons** (buttonpanel.pas:193-216)

**Location:** [buttonpanel.pas](buttonpanel.pas#L188)

**Bug:**
```pascal
procedure TCustomButtonPanel.DoShowButtons;
var
  btn: TPanelButton;
  aButton: TPanelBitBtn;
begin
  DisableAutoSizing('TCustomButtonPanel.DoShowButtons');  // LINE 193

  for btn := Low(btn) to High(btn) do
  begin
    if FButtons[btn] = nil
    then CreateButton(btn);  // ⚠️ CAN THROW EXCEPTION
    // ...
  end;

  UpdateButtonOrder;
  UpdateButtonLayout;
  EnableAutoSizing('TCustomButtonPanel.DoShowButtons');  // LINE 216 - MAY NOT REACH
end;
```

**Problem:**
- If `CreateButton(btn)` throws an exception, `EnableAutoSizing` is never called
- `FAutoSizingLockCount` remains > 0 permanently
- Component stops auto-sizing for the rest of its lifetime
- Parent component also remains locked

**Impact:** HIGH - Component layout breaks

**Fix:** Add try..finally
```pascal
procedure TCustomButtonPanel.DoShowButtons;
begin
  DisableAutoSizing('TCustomButtonPanel.DoShowButtons');
  try
    for btn := Low(btn) to High(btn) do
    begin
      if FButtons[btn] = nil
      then CreateButton(btn);
      // ...
    end;
    UpdateButtonOrder;
    UpdateButtonLayout;
  finally
    EnableAutoSizing('TCustomButtonPanel.DoShowButtons');
  end;
end;
```

---

### 2. **TCustomButtonPanel.DoShowGlyphs** (buttonpanel.pas:233-243)

**Location:** [buttonpanel.pas](buttonpanel.pas#L228)

**Bug:**
```pascal
procedure TCustomButtonPanel.DoShowGlyphs;
var
  btn: TPanelButton;
begin
  DisableAutoSizing('TCustomButtonPanel.DoShowGlyphs');  // LINE 233

  for btn := Low(btn) to High(btn) do
  begin
    if FButtons[btn] = nil then Continue;
    if btn in FShowGlyphs then 
      FButtons[btn].GlyphShowMode := gsmApplication  // ⚠️ CAN THROW
    else
      FButtons[btn].GlyphShowMode := gsmNever;
  end;
  EnableAutoSizing('TCustomButtonPanel.DoShowGlyphs');  // LINE 243 - MAY NOT REACH
end;
```

**Problem:**
- Assignment to `GlyphShowMode` could throw exceptions (memory, invalid state)
- `EnableAutoSizing` may never be called
- Same deadlock effect as DoShowButtons

**Impact:** HIGH - Component layout breaks

**Fix:** Add try..finally guard

---

## CORRECT IMPLEMENTATIONS (Reference)

These implementations show the proper pattern:

### ✓ TCustomButtonPanel.UpdateButtonSize (buttonpanel.pas:389-405)

```pascal
DisableAutoSizing('TCustomButtonPanel.UpdateButtonSize');
try
  for btn in FButtons do
  begin
    if btn = nil then Continue;
    // ... risky operations ...
  end;
finally
  EnableAutoSizing('TCustomButtonPanel.UpdateButtonSize');
end;
```

### ✓ TCustomButtonPanel.SetAlign (buttonpanel.pas:411-418)

```pascal
DisableAutoSizing('TCustomButtonPanel.SetAlign');
try
  inherited SetAlign(Value);
  UpdateButtonLayout;
  UpdateBevel;
  UpdateSizes;
finally
  EnableAutoSizing('TCustomButtonPanel.SetAlign');
end;
```

### ✓ TCustomButtonPanel.SetShowBevel (buttonpanel.pas:473-481)

```pascal
DisableAutoSizing('TCustomButtonPanel.SetShowBevel');
try
  FBevel := TBevel.Create(Self);  // ⚠️ Risky
  FBevel.Parent := Self;
  FBevel.Name   := 'Bevel';
  UpdateBevel;
finally
  EnableAutoSizing('TCustomButtonPanel.SetShowBevel');
end;
```

---

## ADDITIONAL CONCERNS

### Conditional DisableAutoSizing/EnableAutoSizing

**Pattern found in coolbar.inc (lines 685-691):**

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

**Status:** ✓ SAFE - Conditions match on both sides

---

### Nested Control Disable/Enable (wincontrol.inc:6314-6369)

**Pattern in InsertControl and Remove:**

```pascal
// InsertControl
if AControl.FAutoSizingLockCount>0 then
begin
  DisableAutoSizing('TControl.DisableAutoSizing');
end;

// Remove  
if AControl.FAutoSizingLockCount>0 then
begin
  EnableAutoSizing('TControl.DisableAutoSizing');
end;
```

**Status:** ⚠️ FRAGILE
- Relies on symmetry between Insert/Remove calls
- If control is inserted but never removed (memory leak scenario), parent remains locked
- If Remove is somehow called twice, would cause underflow exception

**Risk:** MEDIUM - Works in normal flow but fragile to lifecycle bugs

---

## DEBUG SUPPORT

The LCL has built-in debug checks when `{$DEFINE DebugDisableAutoSizing}` is enabled:

From control.inc (5845-5856):
```pascal
{ Underflow check — always fatal }
if FAutoSizingLockCount <= 0 then
  raise ELayoutException.CreateFmt(
    'TControl.EnableAutoSizing %s count=%d: missing DisableAutoSizing',
    [DbgSName(Self), FAutoSizingLockCount]);
```

This means:
- **If you call `EnableAutoSizing` without matching `DisableAutoSizing`:** Raises exception immediately
- **If you call `DisableAutoSizing` without `EnableAutoSizing`:** The component silently deadlocks (no exception, just broken layout)

---

## CONSEQUENCES OF NOT FIXING

When `FAutoSizingLockCount` remains > 0:

1. `DoAllAutoSize()` never executes
2. Child controls don't resize properly
3. Layout becomes broken and frozen
4. Parent is also affected (cascades up)
5. **No error message** - silent deadlock
6. Difficult to debug (appears to be a layout algorithm failure)

---

## RECOMMENDATION

### Priority 1: Fix buttonpanel.pas
- Wrap DoShowButtons (line 193) with try..finally
- Wrap DoShowGlyphs (line 233) with try..finally

### Priority 2: Audit entire codebase
Search for all `DisableAutoSizing` calls without matching `finally`:

```bash
grep -rn "DisableAutoSizing" /var/otherdev/lazarus/lcl \
  --include="*.pp" --include="*.pas" --include="*.inc" | wc -l
```

Then check each one for proper exception handling.

---

## Files Involved

- `/var/otherdev/lazarus/lcl/buttonpanel.pas` - 2 bugs
- `/var/otherdev/lazarus/lcl/include/control.inc` - Implementation
- `/var/otherdev/lazarus/lcl/include/wincontrol.inc` - Fragile pattern
- `/var/otherdev/lazarus/lcl/include/coolbar.inc` - Conditional but safe

---

## Test Case to Reproduce

```pascal
procedure TestDisableAutoSizingBug;
var
  Panel: TCustomButtonPanel;
begin
  Panel := TCustomButtonPanel.Create(nil);
  try
    Panel.Parent := Form1;
    Panel.ShowButtons := [pbOK];
    
    // Simulate exception in button creation
    // (would happen if theme engine fails, memory low, etc)
    Panel.DoShowButtons;  // If CreateButton throws, AutoSizing stuck
    
    // Now try to resize - layout will be broken
    Panel.Width := 400;  // Won't trigger AutoSize!
  finally
    Panel.Free;
  end;
end;
```

---

## FIXES APPLIED

**✓ FIXED - March 28, 2026**

Four bugs in LCL components have been corrected:

### Fixed Bug #1: TCustomButtonPanel.DoShowButtons
- **File:** `/var/otherdev/lazarus/lcl/buttonpanel.pas` (lines 188-220)
- **Change:** Wrapped entire loop and update operations in `try..finally` block
- **Status:** ✓ FIXED

### Fixed Bug #2: TCustomButtonPanel.DoShowGlyphs  
- **File:** `/var/otherdev/lazarus/lcl/buttonpanel.pas` (lines 228-244)
- **Change:** Wrapped glyph mode assignments in `try..finally` block
- **Status:** ✓ FIXED

### Fixed Bug #3: TCustomDockForm.Create
- **File:** `/var/otherdev/lazarus/lcl/include/customdockform.inc` (lines 56-66)
- **Change:** Wrapped form configuration operations in `try..finally` block
- **Status:** ✓ FIXED

### Fixed Bug #4: TCalculatorForm.Create
- **File:** `/var/otherdev/lazarus/lcl/forms/calcform.pas` (lines 676-682)
- **Change:** Wrapped form construction and initialization in `try..finally` block
- **Status:** ✓ FIXED

All procedures now properly guarantee exception safety:
1. Component/Form state cannot become deadlocked
2. Update lock counts are always restored
3. Parent components are not affected by child exceptions
4. Matches the correct pattern already used in other LCL methods

