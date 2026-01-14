## Summary

Adds GUI-style text editing within the shell prompt: select text with shift+arrows or shift+click, then type to replace. Selections within the input area behave like a text editor rather than terminal copy-selection.

**Part 3 of 3** in the in-place command editing series:
- PR 1: Prompt bounds infrastructure
- PR 2: Click-to-move in prompt input
- **→ PR 3**: In-place edit selection (this PR)

## Changes

### Edit Selection Core
- Add `edit_selection_active` flag to distinguish edit vs copy selections
- Replace selected text when typing (via arrow + delete sequences)
- Skip copy-on-select for edit selections

### Shift-Select
- Shift+Left/Right extends selection by character
- Shift+Up/Down extends selection by row (preserving column)
- Shift+Click extends selection from cursor to click position
- Selection uses half-open bounds (end exclusive)

### Multiline Input Handling
- Span unknown rows in `selectPrompt()` for blank lines in multiline input
- Propagate `semantic_prompt` on linefeed for multiline commands
- Fix click-to-move on last row of multiline input
- Clamp selection to rows with actual text

## Behavioral Specs

**Shift+Arrow** (multi-line input):
- Extends selection by one character/row, clamped to input bounds
- Anchor stays fixed; active end moves
- Cursor tracks the active end

**Exiting selection with arrows**:
- Left → collapse to start; Right → collapse to end
- Up → collapse to input start; Down → collapse to input end

**Shift+Click**:
- Anchor at cursor, click sets active end
- Selection clamped to input bounds

**Blank lines in multiline input**:
- Blank lines (e.g., Option+Return) treated as part of input
- `selectPrompt()` spans through unknown rows if more input follows

## Test Plan

- `zig build test` - includes selection replacement tests
- Manual: Select with shift+arrows → type → replaces selection
- Manual: Shift+click → extends selection from cursor
- Manual: Multiline input with blank lines → selection spans correctly
- Manual: Selection outside prompt → normal copy behavior

## Compatibility

- Works with bash, zsh, fish (standard VT delete sequence)
- Auto-disables in tmux/ssh without shell integration
- Undo via shell's native undo (Ctrl+_ in readline, etc.)

---
[Full design doc](GIST_URL_HERE)
