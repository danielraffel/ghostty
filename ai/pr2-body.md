## Summary

Enables clicking within the prompt input area to move the shell cursor to that position. Uses arrow key sequences so the shell maintains its own state.

**Part 2 of 3** in the in-place command editing series:
- PR 1: Prompt bounds infrastructure
- **→ PR 2**: Click-to-move in prompt input (this PR)
- PR 3: In-place edit selection

## Changes

- Add `clickMoveCursorInput()` for prompt-aware cursor positioning
- Enable click-to-move by default when `inplace-command-editing` is on
- Preserve double-click word selection behavior after click-to-move
- Add arrow sequence helpers shared with future shift-select

## Behavioral Specs

**Mouse click for cursor placement**:
- Single click in prompt input moves cursor to nearest valid input cell
- Clicking past end-of-line snaps to that row's input end
- Double-click still selects word as before
- Clicks outside prompt input behave normally (no cursor move)

**Activation conditions** (all must be true):
- `inplace-command-editing` config enabled
- `semantic_prompt_seen` is true
- Cursor is at prompt (not in command output)
- Not in password input, mouse capture, or alternate screen

## Test Plan

- `zig build test`
- Manual: Click within prompt input → cursor moves
- Manual: Click past line end → cursor moves to line end
- Manual: Double-click → selects word
- Manual: Click on command output → no cursor movement

## Compatibility

- Feature auto-disables without OSC 133 shell integration
- Feature auto-disables when applications capture mouse
