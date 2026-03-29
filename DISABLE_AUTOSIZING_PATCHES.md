# Patches for DisableAutoSizing Bugs

## Bug Fix #1: TCustomButtonPanel.DoShowButtons

**File:** `buttonpanel.pas:188-220`

**Before (BUGGY):**
```
188: procedure TCustomButtonPanel.DoShowButtons;
189: var
190:   btn: TPanelButton;
191:   aButton: TPanelBitBtn;
192: begin
193:   DisableAutoSizing('TCustomButtonPanel.DoShowButtons');
194: 
195:   for btn := Low(btn) to High(btn) do
196:   begin
197:     if FButtons[btn] = nil
198:     then CreateButton(btn);      ← CAN THROW EXCEPTION
199:     aButton:=FButtons[btn];
200: 
201:     if btn in FShowButtons
202:     then begin
203:       if csDesigning in ComponentState then
204:         aButton.ControlStyle:=aButton.ControlStyle-[csNoDesignVisible];
205:       aButton.Visible := True;
206:     end
207:     else begin
208:       if csDesigning in ComponentState then
209:         aButton.ControlStyle:=aButton.ControlStyle+[csNoDesignVisible];
210:       aButton.Visible := False;
211:     end;
212:   end;
213: 
214:   UpdateButtonOrder;
215:   UpdateButtonLayout;
216:   EnableAutoSizing('TCustomButtonPanel.DoShowButtons');
217: end;
```

**After (FIXED):**
```pascal
procedure TCustomButtonPanel.DoShowButtons;
var
  btn: TPanelButton;
  aButton: TPanelBitBtn;
begin
  DisableAutoSizing('TCustomButtonPanel.DoShowButtons');
  try
    for btn := Low(btn) to High(btn) do
    begin
      if FButtons[btn] = nil
      then CreateButton(btn);
      aButton:=FButtons[btn];

      if btn in FShowButtons
      then begin
        if csDesigning in ComponentState then
          aButton.ControlStyle:=aButton.ControlStyle-[csNoDesignVisible];
        aButton.Visible := True;
      end
      else begin
        if csDesigning in ComponentState then
          aButton.ControlStyle:=aButton.ControlStyle+[csNoDesignVisible];
        aButton.Visible := False;
      end;
    end;

    UpdateButtonOrder;
    UpdateButtonLayout;
  finally
    EnableAutoSizing('TCustomButtonPanel.DoShowButtons');
  end;
end;
```

---

## Bug Fix #2: TCustomButtonPanel.DoShowGlyphs

**File:** `buttonpanel.pas:228-244`

**Before (BUGGY):**
```pascal
228: procedure TCustomButtonPanel.DoShowGlyphs;
229: var
230:   btn: TPanelButton;
231: begin
232:   DisableAutoSizing('TCustomButtonPanel.DoShowGlyphs');
233:   for btn := Low(btn) to High(btn) do
234:   begin
235:     if FButtons[btn] = nil then Continue;
236: 
237:     if btn in FShowGlyphs then 
238:       FButtons[btn].GlyphShowMode := gsmApplication    ← CAN THROW
239:     else
240:       FButtons[btn].GlyphShowMode := gsmNever;
241:   end;
242:   EnableAutoSizing('TCustomButtonPanel.DoShowGlyphs');
243: end;
```

**After (FIXED):**
```pascal
procedure TCustomButtonPanel.DoShowGlyphs;
var
  btn: TPanelButton;
begin
  DisableAutoSizing('TCustomButtonPanel.DoShowGlyphs');
  try
    for btn := Low(btn) to High(btn) do
    begin
      if FButtons[btn] = nil then Continue;

      if btn in FShowGlyphs then 
        FButtons[btn].GlyphShowMode := gsmApplication
      else
        FButtons[btn].GlyphShowMode := gsmNever;
    end;
  finally
    EnableAutoSizing('TCustomButtonPanel.DoShowGlyphs');
  end;
end;
```

---

## Summary of Changes

Both bugs follow the same pattern:
1. Add `try` keyword after `DisableAutoSizing` call
2. Add `finally` block before `EnableAutoSizing` call
3. This ensures `EnableAutoSizing` is called even if exceptions occur

**Pattern template:**
```pascal
DisableAutoSizing('Reason');
try
  // ... potentially throwing operations ...
finally
  EnableAutoSizing('Reason');
end;
```

This is already correctly implemented in:
- `UpdateButtonSize()` 
- `SetAlign()` 
- `SetShowBevel()`
- `SetBiDiMode()` (and many others in include files)

The two buggy procedures just missed the try..finally wrapper.

