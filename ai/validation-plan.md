# Validation Plan for In-Place Command Editing

## Summary

This document provides a systematic plan to validate the shift+arrow selection and arrow key collapse behaviors against the spec in `bizlogic.md`.

---

## Current Implementation Analysis

### Shift+Arrow Up/Down (`adjustPromptInputSelection`)

**Location**: `src/Surface.zig:2575`

**How it works**:
1. `stepInputPin` moves the selection end by one row (up/down) while maintaining the x column
2. `clampInputPinRow` adjusts the x position to be within the target row's valid input range
3. `sendInputCursorMove` sends left/right arrow sequences to move the shell cursor to match

**Key functions**:
- `stepInputPin` (line 2554): Uses `from.up(1)` or `from.down(1)` for vertical movement
- `clampInputPinRow` (line 2536): Clamps x to `[row_start, row_end]` on the target row
- `inputRowEndCol` (line 2503): Finds the last cell with text (or cursor position) on a row

**Spec requirement** (Section A):
> Shift+Up/Down extends selection by one input row (visual row) at the same column; if the target row is shorter, clamp to that row's input end (last text/insertion point).

### Exiting Selection with Arrows (`collapsePromptInputSelection`)

**Location**: `src/Surface.zig:2638`

**How it works**:
1. Determines target position based on direction:
   - Left → `ordered_sel.start()` (topLeft of selection)
   - Right → `ordered_sel.end()` (bottomRight of selection)
   - Up → `bounds.ordered().start()` (start of input)
   - Down → `inputEndPin(screen, bounds)` (end of input/insertion point)
2. Clears selection
3. Sends cursor movement via `sendInputCursorMove`

**Spec requirement** (Section B):
> - Left → collapse to start of selection
> - Right → collapse to end of selection
> - Up → collapse to start of entire input
> - Down → collapse to end of entire input (insertion point)

---

## Potential Issues Identified

### Issue 1: `inputSelectionBounds` vs `inputBounds` discrepancy

**Location**: `adjustPromptInputSelection` uses `inputSelectionBounds` (line 2591), while `collapsePromptInputSelection` uses `inputBounds` (line 2665).

**Difference**:
- `inputSelectionBounds`: Returns bounds clamped to the last text position (or cursor)
- `inputBounds`: Returns full prompt bounds including empty cells

**Potential problem**: The shift-selection bounds may be more restrictive than the collapse bounds, leading to inconsistent behavior.

### Issue 2: Up/Down collapse uses `inputBounds` not `inputSelectionBounds`

In `collapsePromptInputSelection`:
```zig
const bounds = screen.inputBounds(cursor) orelse return false;
// ...
.up => bounds.ordered(screen, .forward).start(),
.down => inputEndPin(screen, bounds),
```

This uses `inputBounds` (full bounds) but `adjustPromptInputSelection` uses `inputSelectionBounds` (text-clamped bounds). The two functions may have different notions of "start" and "end" of input.

### Issue 3: Vertical movement cursor tracking

When pressing Shift+Up/Down, `sendInputCursorMove` sends left/right arrows (not up/down). This relies on the shell treating the input as a linear buffer where left/right wrap at line boundaries.

**Potential problem**: If the shell doesn't wrap correctly (e.g., tmux passthrough, certain readline configurations), the cursor position may desync.

### Issue 4: Empty row handling in `inputRowEndCol`

When a target row has no text, `inputRowEndCol` returns `row_start`. This means:
- Moving to an empty row clamps to position 0 (or input_start_col)
- Selection across empty rows may behave unexpectedly

---

## Test Scenarios

### A. Shift+Arrow Selection Tests

#### A1. Shift+Up from middle of multi-line input
```
Setup:
  Row 0: "$ hello" (prompt="$ ", input starts at col 2)
  Row 1: "world"   (continuation, input starts at col 0)
  Cursor at row 1, col 3 ('l' in world)

Action: Shift+Up

Expected:
  Selection from (1,3) anchor to (0,3) end (or (0,6) if col 3 is outside input)
  Shell cursor moves to row 0
```

#### A2. Shift+Down when target row is shorter
```
Setup:
  Row 0: "$ hello" (5 chars input: h,e,l,l,o at cols 2-6)
  Row 1: "ab"      (2 chars: a,b at cols 0-1)
  Cursor at row 0, col 5

Action: Shift+Down

Expected:
  Selection end clamps to row 1, col 1 (last text position)
  Not col 5 (would be past end of text)
```

#### A3. Shift+Up/Down with empty rows
```
Setup:
  Row 0: "$ hello"
  Row 1: ""        (empty continuation)
  Row 2: "world"
  Cursor at row 2, col 3

Action: Shift+Up twice

Expected:
  First Shift+Up: selection to row 1, col 0 (empty row clamps to start)
  Second Shift+Up: selection to row 0, col 3 (or input end if shorter)
```

#### A4. Shift+Up at input start (boundary)
```
Setup:
  Row 0: "$ hello"
  Cursor at row 0, col 2 (start of input)

Action: Shift+Up

Expected:
  No change (already at top of input)
  handled_no_change returned
```

### B. Exit Selection with Arrows Tests

#### B1. Left collapse
```
Setup:
  Selection from col 5 to col 2 (made via Shift+Left)
  Shell cursor at col 2

Action: Left arrow (unmodified)

Expected:
  Selection cleared
  Cursor at col 2 (start of selection - already there)
```

#### B2. Right collapse
```
Setup:
  Selection from col 2 to col 5 (made via Shift+Right)
  Shell cursor at col 5

Action: Right arrow (unmodified)

Expected:
  Selection cleared
  Cursor at col 5 (end of selection - already there)
```

#### B3. Up collapse multi-line
```
Setup:
  Multi-line input on rows 0-2
  Selection spanning rows 1-2
  Shell cursor at row 2, col 3

Action: Up arrow (unmodified)

Expected:
  Selection cleared
  Cursor moves to row 0, col 2 (start of input)
```

#### B4. Down collapse multi-line
```
Setup:
  Multi-line input "hello\nworld" (last text at row 1, col 4)
  Selection spanning rows 0-1
  Shell cursor at row 0

Action: Down arrow (unmodified)

Expected:
  Selection cleared
  Cursor moves to insertion point (after "world")
```

#### B5. Collapse should not trigger history
```
Setup:
  Any selection within input

Action: Up or Down arrow (unmodified)

Expected:
  Selection cleared
  Cursor moves to input start/end
  Shell history NOT invoked
```

---

## Manual Testing Checklist

### Shell Compatibility
- [ ] bash: Single-line selection + collapse
- [ ] bash: Multi-line selection + collapse
- [ ] zsh: Single-line selection + collapse
- [ ] zsh: Multi-line selection + collapse
- [ ] fish: Single-line selection + collapse

### Edge Cases
- [ ] Empty input (no text after prompt)
- [ ] Wide characters (CJK)
- [ ] Very long lines (wrapped input)
- [ ] Cursor at input boundaries

### Behavior Verification
- [ ] Shift+Left/Right moves by character
- [ ] Shift+Up/Down moves by row (same column or clamped)
- [ ] Left/Right collapse goes to selection start/end
- [ ] Up/Down collapse goes to input start/end
- [ ] No history navigation during collapse
- [ ] Selection replaces on typing after collapse

---

## Recommended Actions

1. **Add unit tests** for the specific scenarios above
2. **Verify `inputBounds` vs `inputSelectionBounds`** usage is intentional
3. **Test with actual shell** to verify cursor sync
4. **Test history behavior** with multi-line input

---

## Code Locations Reference

| Function | Line | Purpose |
|----------|------|---------|
| `adjustPromptInputSelection` | 2575 | Shift+arrow selection |
| `collapsePromptInputSelection` | 2638 | Unmodified arrow collapse |
| `stepInputPin` | 2554 | Move pin by one step in direction |
| `clampInputPinRow` | 2536 | Clamp x to row's valid input range |
| `inputRowEndCol` | 2503 | Find last text cell in row |
| `inputSelectionBounds` | 2433 | Get bounds clamped to text |
| `inputEndPin` | 2416 | Get insertion point (after last text) |
| `sendInputCursorMove` | 2461 | Send left/right arrows to move cursor |
