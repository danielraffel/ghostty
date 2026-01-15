# Inplace Command Editing - Status

## 01/14/26 — Input Selection Demo in Ghostty

### Working Features

1. **Double-click word selection**
2. **Triple-click line selection**
3. **Mouse drag selection** (in-place editing)
4. **Shift + Arrow selection**
5. **Shift + Up / Down multi-line selection**
6. **Click-to-move cursor**
7. **ESC clears selection**
8. **Delete / Backspace with selection**

### Known Issues

1. **Paste leaves selection highlighted**
   - After pasting, the selection highlight remains
   - Highlighted content cannot be deleted
   - Clicking before the highlighted text deselects it and places the cursor correctly
   - Clicking outside the text or at the bottom does not move the cursor to the end of the input

---

## Feature Overview

Inplace command editing allows users to edit shell commands directly in the terminal using familiar text editing shortcuts (arrow keys, shift+arrow for selection, etc.) instead of relying on shell-specific keybindings. This is controlled by `config.inplace_command_editing`.

### Key Components

- **Selection System**: Uses `edit_selection_active` flag and `selection_end_exclusive` to track prompt input selections
- **Prompt Detection**: Uses semantic prompt markers (`.input`, `.prompt`, `.command`) to identify editable regions
- **Bounds Calculation**: `inputSelectionBounds()` determines the valid selection region within prompt input
- **Click-to-Move**: Clicking within prompt input moves cursor to that position

## Implementation History

1. **Double-click word selection** - Fixed by checking if click is on word character before trying URL/link detection. Prevents path regex from matching text like "/triple click" when clicking on "click".
   - File: `src/Surface.zig` lines 4783-4816
   - Fix: Only try `linkAtPin()` when clicking on boundary characters

2. **Triple-click line selection** - Works correctly

3. **Word boundaries** - Added `/` and `\` to boundary list in `selectWord()`
   - File: `src/terminal/Screen.zig` lines 2586-2587

4. **Render state cleanup** - Clear `row_sels` when selection is null to prevent stale highlighting
   - File: `src/terminal/render.zig` lines 647-653

5. **Click-to-Deselect** - RESOLVED
   - Fix: Plain click now clears any selection (not just edit selections)
   - Changed `mouseButtonCallback()` to call `screen.clearSelection()` directly with `queueRender()`
   - File: `src/Surface.zig` in `mouseButtonCallback()`

6. **Paste-Replace Bug** - RESOLVED
   - Fix: Backspace/delete with selection now deletes selection without sending extra key to shell
   - Added check for delete keys in `keyCallback()` after `performEditReplacement()`
   - File: `src/Surface.zig` lines ~3348-3358

7. **Triple-Click Selecting Prompt** - RESOLVED
   - `selectPrompt()` properly handles input-only selection within bounds

8. **Shift+Down/Up Selection Limit** - RESOLVED
   - Fix: Shift+up on first line extends to beginning, shift+down on last line extends to end
   - Modified `stepInputPin()` to handle boundary cases when target row is outside input bounds
   - Vertical navigation through multi-line input (with newlines from paste) now works correctly
   - File: `src/Surface.zig` in `stepInputPin()`

9. **ESC clears selection** - NEW FEATURE
   - ESC key now clears selections in inplace command editing mode
   - File: `src/Surface.zig` in `keyCallback()`

10. **Unicode Line Separator (U+2028/U+2029)** - RESOLVED
    - Paste now normalizes Unicode LINE SEPARATOR (U+2028) and PARAGRAPH SEPARATOR (U+2029) to newlines
    - These characters display as `<2028>` in terminals; converting to `\n` provides expected line break behavior
    - File: `src/Surface.zig` in `completeClipboardPaste()`

11. **Mouse drag selection** - NEW FEATURE (01/14/26)
    - Added mouse drag selection for inplace command editing
    - Selection preserved on mouse release (not cleared by click-to-move)
    - File: `src/Surface.zig` in `mouseButtonCallback()` click_move block

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
| `stepInputPin()` | Surface.zig:~2693 | Step cursor within input bounds |
| `inputSelectionBounds()` | Surface.zig:2947 | Calculate valid selection region |
| `performEditReplacement()` | Surface.zig:5085 | Replace selection with clipboard content |
| `selectWord()` | Screen.zig:2561 | Word selection on double-click |
| `selectPrompt()` | Screen.zig:2770 | Select prompt input region |
| `linkAtPin()` | Surface.zig:5261 | URL/link detection at cursor |

## Debug Tips

1. Add logging with: `std.log.scoped(.surface).debug("message: {}", .{value});`
2. Check selection state: `if (screen.selection) |sel| { ... }`
3. Check semantic types: `row.semantic_prompt` returns `.input`, `.prompt`, `.command`, or `.unknown`
