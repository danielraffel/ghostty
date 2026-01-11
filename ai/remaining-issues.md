# Inplace Command Editing - Remaining Issues

## Feature Overview

Inplace command editing allows users to edit shell commands directly in the terminal using familiar text editing shortcuts (arrow keys, shift+arrow for selection, etc.) instead of relying on shell-specific keybindings. This is controlled by `config.inplace_command_editing`.

### Key Components

- **Selection System**: Uses `edit_selection_active` flag and `selection_end_exclusive` to track prompt input selections
- **Prompt Detection**: Uses semantic prompt markers (`.input`, `.prompt`, `.command`) to identify editable regions
- **Bounds Calculation**: `inputSelectionBounds()` determines the valid selection region within prompt input
- **Click-to-Move**: Clicking within prompt input moves cursor to that position

## Working Features

1. **Double-click word selection** - Fixed by checking if click is on word character before trying URL/link detection. Prevents path regex from matching text like "/triple click" when clicking on "click".
   - File: `src/Surface.zig` lines 4783-4816
   - Fix: Only try `linkAtPin()` when clicking on boundary characters

2. **Triple-click line selection** - Works correctly

3. **Word boundaries** - Added `/` and `\` to boundary list in `selectWord()`
   - File: `src/terminal/Screen.zig` lines 2586-2587

4. **Render state cleanup** - Clear `row_sels` when selection is null to prevent stale highlighting
   - File: `src/terminal/render.zig` lines 647-653

## Outstanding Issues

### 1. Click-to-Deselect Not Working

**Symptom**: After making a selection (shift+arrows or paste highlighting), clicking outside the selection does NOT clear the highlight.

**Attempted Fixes**:
- Added `queueRender()` after `performEditReplacement()` in `completeClipboardPaste()` - did not resolve
- The `row_sels` clearing in render.zig should handle this, but something else may be preventing selection from being set to null

**Investigation Needed**:
- Check if `setSelection(null)` is being called on click
- Check if selection is actually being cleared but render not triggered
- May need to trace click handling flow in `leftClickPress()` and `primaryClick()`

### 2. Paste-Replace Bug ("only" → "onlyy")

**Symptom**: When selecting text and pasting to replace, an extra character appears at the end.

**Investigation Needed**:
- Review `performEditReplacement()` logic
- Check `generateEditSequence()` for off-by-one errors
- May be related to selection bounds calculation

### 3. Triple-Click Selecting Prompt Instead of Input

**Symptom**: Triple-clicking sometimes selects the prompt text instead of just the input area.

**Investigation Needed**:
- Review `selectPrompt()` function
- Check semantic prompt boundary handling
- May need to restrict selection to `.input` semantic type only

### 4. Shift+Down Selection Limit

**Symptom**: Cannot select all the way to the end of multi-line input using shift+down.

**Attempted Fixes**:
- Modified `handlePromptSelectionShift()` to use `sel.bottomRight(screen)` for bounds calculation
- This may need further testing/refinement

**Code Location**: `src/Surface.zig` lines 2747-2758

## Key Files

| File | Purpose |
|------|---------|
| `src/Surface.zig` | Main input handling, selection, click-to-move, paste |
| `src/terminal/Screen.zig` | `selectWord()`, `selectPrompt()`, `selectLine()` |
| `src/terminal/render.zig` | Selection rendering, `row_sels` management |
| `src/terminal/Selection.zig` | Selection struct, `contains()`, `topLeft()`, `bottomRight()` |

## Key Functions

| Function | Location | Purpose |
|----------|----------|---------|
| `handlePromptSelectionShift()` | Surface.zig:2680 | Shift+arrow selection handling |
| `inputSelectionBounds()` | Surface.zig:2947 | Calculate valid selection region |
| `performEditReplacement()` | Surface.zig:5085 | Replace selection with clipboard content |
| `selectWord()` | Screen.zig:2561 | Word selection on double-click |
| `selectPrompt()` | Screen.zig:2770 | Select prompt input region |
| `linkAtPin()` | Surface.zig:5261 | URL/link detection at cursor |

## Debug Tips

1. Add logging with: `std.log.scoped(.surface).debug("message: {}", .{value});`
2. Check selection state: `if (screen.selection) |sel| { ... }`
3. Check semantic types: `row.semantic_prompt` returns `.input`, `.prompt`, `.command`, or `.unknown`
