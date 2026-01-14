# In-Place Command Editing: Design Document

Full design context for the PR series: prompt bounds → click-to-move → edit selection.

## Scope & Assumptions

- Applies only when `inplace-command-editing` is enabled, prompt boundaries are known (semantic prompt/input), primary screen, not readonly, no IME preedit
- Cursor movement and selection are clamped to prompt input bounds only
- No input is mutated unless the user types while a selection is active
- Blank lines within multiline input (e.g., Option+Return) are treated as part of input bounds

## Behavioral Specs

### A) Shift+Arrow (multi-line input)
- Shift+Left/Right extends selection by one input character; wide spacer tails are skipped
- Shift+Up/Down extends selection by one visual row at same column; clamp if target row is shorter
- Selection clamped to input bounds; must never include deleted rows or go past input end
- Selection bounds are half-open (end exclusive): active cursor position is the insertion point
- Anchor stays fixed; active end moves. Reversing direction shrinks then expands other way
- Each shift step updates shell cursor to active end. No history navigation, no text replacement

### B) Exiting selection with arrows
- If selection active and user presses unmodified arrow:
  - Left → collapse to start of selection
  - Right → collapse to end of selection
  - Up → collapse to start of entire input
  - Down → collapse to end of entire input
- Collapse is one step only (no off-by-one move)
- Collapsing must not invoke history or modify input

### C) Shift+Click (prompt input selection)
- When Shift held and user clicks within prompt input:
  - Anchor is current cursor position
  - Click location sets active end
  - Create/extend selection between anchor and click
- Selection clamped to input bounds; cursor moves to active end
- Shift+Click outside prompt input does nothing special

### D) Mouse click/drag for cursor placement
- Single click in prompt input clears selection and moves cursor to nearest valid input cell
- Clicking past end-of-line snaps to that row's input end
- Drag creates/extends selection anchored at mouse-down; active end follows mouse
- Clicking/dragging outside prompt input behaves like normal terminal selection
- Double-click selects word inside input bounds

### E) History behavior
- When there is any current input, Up/Down move only within input buffer
- History navigation only when input buffer is empty

### F) Blank lines in multiline input
- Blank lines within input (Option+Return) are part of input bounds
- `selectPrompt()` spans through `.unknown` rows when scanning forward if more `.input` follows
- Blank lines followed by `.command` output stop bounds at last known `.input` row

### G) Click-to-move in multi-line input
- Click-to-move must work on all rows including last row of multi-line input
- Use direct row coordinate comparisons, not `Pin.before()` for loop termination
- Click-to-move handling occurs BEFORE mouse reporting

## Activation Conditions

All must be true:
1. `inplace-command-editing` config enabled
2. `Terminal.flags.semantic_prompt_seen == true`
3. `Terminal.cursorIsAtPrompt()` returns true
4. `Terminal.flags.password_input == false`
5. `Terminal.flags.mouse_event == .none`
6. Surface is not read-only
7. Not in IME preedit state

## Shell Compatibility

| Shell | Delete Sequence | Notes |
|-------|-----------------|-------|
| bash (readline) | `\x1b[3~` | Standard; can be remapped |
| zsh | `\x1b[3~` | Standard; bindkey customizable |
| fish | `\x1b[3~` | Standard |

## Implementation Notes

### Key Sequence Generation
```
Arrow keys: cursor_keys mode → \x1bO[ABCD] else \x1b[[ABCD]
Delete key: \x1b[3~ (standard VT)
```

### Edit Selection vs Copy Selection
- Edit selections within input bounds skip copy-on-select
- Manual copy (Cmd+C) still works
- Selection cleared after replacement

### Pin.before() Caveat
`Pin.before()` compares page nodes in addition to coordinates. For same-row comparisons, use direct coordinate checks:
```zig
if (row_pin.node == end.node and row_pin.y == end.y) ...
```

## PR Series

1. **Prompt Bounds Infrastructure**: `Row.input_start_col`, `semantic_prompt_seen`, `inputBounds()`, `inputPath()`
2. **Click-to-Move**: `clickMoveCursorInput()`, arrow sequence helpers
3. **Edit Selection**: selection gating, replace-on-type, shift-select, multiline fixes
