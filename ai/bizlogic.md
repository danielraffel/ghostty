Scope / assumptions
- Applies only when inplace_command_editing is enabled, prompt boundaries are known (semantic prompt/input), primary screen, not readonly, no IME preedit.
- Cursor movement and selection are clamped to prompt input bounds only.
- No input is mutated unless the user types while a selection is active.
- Blank lines within multiline input (e.g., created via Option+Return) are treated as part of the input bounds even if they have .unknown semantic_prompt, as long as there is more .input below them.

PRs used for current ARM testing
- Stack: pr/1-prompt-bounds-v2 -> pr/2-click-to-move-input-v2 -> pr/3-inplace-replacement-v2 (tip)

A) Shift + Arrow (multi-line input)
- Shift+Left/Right extends selection by one input character in that direction; wide spacer tails are skipped.
- Shift+Up/Down extends selection by one visual input row at the same column; if the target row is shorter, clamp to that row's input end.
- **Shift+Up on first line**: When already on the first row of input bounds and pressing Shift+Up, extends selection to the **beginning** of that first line (not stuck at current column).
- **Shift+Down on last line**: When already on the last row of input bounds and pressing Shift+Down, extends selection to the **end** of that last line.
- Multi-line input with embedded newlines (e.g., from paste with U+2028 normalized to \n): vertical navigation works through these newline boundaries.
- Selection is clamped to input bounds; it must never include deleted rows or go past the input end.
- Selection bounds are half-open (end exclusive): the active cursor position is the insertion point and must not include an extra trailing cell/space.
- When moving between rows, selection must not include an extra character on the new row; clamp to the nearest valid input cell.
- Anchor stays fixed; active end moves. Reversing direction shrinks selection until it crosses the anchor, then expands the other way.
- Each shift step updates the shell cursor to the active end. No history navigation, no text replacement.

B) Exiting selection with arrows
- If a selection is active and the user presses an unmodified arrow key:
- Left → collapse to start of selection
- Right → collapse to end of selection
- Up → collapse to start of entire input
- Down → collapse to end of entire input (insertion point)
- Collapse is one step only (no off-by-one move).
- Collapsing a selection must not invoke history or modify input.
- After collapse, subsequent arrows behave normally.

C) Shift + Click (prompt input selection)
- When Shift is held and the user clicks within the prompt input:
- Anchor is the current cursor position.
- Click location sets the active end.
- Create or extend a selection between anchor and click.
- Selection is clamped to input bounds.
- Cursor moves to the active end.
- Releasing leaves the selection active for overwrite.
- Shift+Click outside the prompt input does nothing special.

D) Mouse click/drag for cursor placement
- Single click in the prompt input clears selection and moves cursor to the nearest valid input cell, clamped to input start/end.
- **Click-to-deselect**: Any plain click clears any active selection (both edit selections and regular selections).
- Clicking past end-of-line snaps to that row's input end (or global input end if it's the last row).
- Drag in the prompt input creates or extends a selection anchored at mouse-down; active end follows mouse; selection is clamped to input bounds; cursor tracks the active end.
- Clicking or dragging outside the prompt input behaves like normal terminal selection/copy and does not move the shell cursor.
- Double-click selects the word inside input bounds and moves cursor to the selection end.

D2) ESC key behavior
- **ESC clears selection and returns to anchor**: When inplace command editing is enabled and a selection is active, pressing ESC:
  - Moves the cursor back to the selection anchor (where the selection started)
  - Clears the selection
  - Does not send ESC to the shell
- This provides intuitive cancel behavior - you end up back where you were before selecting.
- If no selection is active, ESC is passed through to the shell normally.

E) History behavior
- When there is any current input (multi-line or not), Up/Down move only within the input buffer.
- History navigation is used only when the input buffer is empty.

F) Blank lines in multiline input
- Blank lines created within input (e.g., Option+Return or pasted multiline text with blank lines) are treated as part of the input bounds.
- `selectPrompt()` spans through .unknown rows when scanning forward if there is more .input below them.
- Blank lines followed by .command output stop the prompt bounds at the last known .input row.
- This ensures shift-selection, click-to-move, and editing work correctly across blank lines within the same input.

G) Click-to-move in multi-line input
- Click-to-move must work correctly on all rows of multi-line input, including the last row.
- The `inputCursorIndex` function counts characters from input start to a clicked position.
- When iterating rows, avoid using `Pin.before()` for loop termination on same-row comparisons — it compares internal page nodes in addition to coordinates, which can give incorrect results when pins reference the same row via different nodes.
- Use direct row coordinate comparisons instead: check `row_pin.node == end.node and row_pin.y == end.y` before trying to advance, and `next.y > end.y and next.node == end.node` to detect when past the end row.
- Click-to-move handling must occur BEFORE mouse reporting so it works even when the shell has mouse reporting enabled. If the click is outside input bounds, fall through to mouse reporting.

H) Paste behavior
- **Unicode line separator normalization**: When pasting, Unicode LINE SEPARATOR (U+2028) and PARAGRAPH SEPARATOR (U+2029) are converted to newlines (`\n`). These characters display as `<2028>` in terminals, so conversion provides expected line break behavior.
- After paste completes, selection is cleared and render is triggered.

I) Delete/Backspace with selection
- When a selection is active and Backspace or Delete is pressed:
  - `performEditReplacement()` deletes the selected text
  - The key is NOT sent to the shell (to avoid deleting an extra character)
  - Render is triggered
- For printable characters, the selection is deleted and the character is sent normally (type-to-replace).
