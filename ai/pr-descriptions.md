# PR Descriptions for In-Place Command Editing Stack

**Series**: `pr/1-prompt-bounds-v2` → `pr/2-click-to-move-input-v2` → `pr/3-inplace-replacement-v2`

---

## PR 1: Prompt Bounds Infrastructure

**Branch**: `pr/1-prompt-bounds-v2`
**Base**: `main`

### Title
```
feat(terminal): add input boundary tracking for prompt-aware editing
```

### Description

```markdown
## Summary

Adds infrastructure to track where user input begins within shell prompt rows. This enables future features that need to distinguish prompt text from user-typed input.

**Part 1 of 3** in the in-place command editing series:
- **→ PR 1**: Prompt bounds infrastructure (this PR)
- PR 2: [Click-to-move in prompt input](#link-to-pr2)
- PR 3: [In-place edit selection](#link-to-pr3)

## Changes

- Add `Row.input_start_col` field to track where input begins on each row
- Add `Terminal.flags.semantic_prompt_seen` to gate features on OSC 133 support
- Add `Screen.inputBounds()` helper to query input-only regions
- Add `Screen.inputPath()` for cursor movement within input bounds
- Mark prompt end in zsh integration to set input boundary column

## Behavioral Specs

This PR adds no user-visible behavior changes. It provides the data model for PRs 2 and 3.

## Test Plan

- `zig build test` - unit tests for boundary tracking
- Verify `input_start_col` is set correctly via OSC 133 promptEnd
- Verify bounds propagate on soft wrap and linefeed during input

## Compatibility

- No impact on terminals without OSC 133 shell integration
- No impact on alternate screen or password input modes
```

---

## PR 2: Click-to-Move in Prompt Input

**Branch**: `pr/2-click-to-move-input-v2`
**Base**: `pr/1-prompt-bounds-v2`

### Title
```
feat(surface): click-to-move cursor within prompt input area
```

### Description

```markdown
## Summary

Enables clicking within the prompt input area to move the shell cursor to that position. Uses arrow key sequences so the shell maintains its own state.

**Part 2 of 3** in the in-place command editing series:
- PR 1: [Prompt bounds infrastructure](#link-to-pr1)
- **→ PR 2**: Click-to-move in prompt input (this PR)
- PR 3: [In-place edit selection](#link-to-pr3)

## Changes

- Add `clickMoveCursorInput()` for prompt-aware cursor positioning
- Enable click-to-move by default when `inplace-command-editing` is on
- Preserve double-click word selection behavior after click-to-move
- Add arrow sequence helpers shared with future shift-select

## Behavioral Specs

**D) Mouse click for cursor placement** (from design spec):
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
```

---

## PR 3: In-Place Edit Selection

**Branch**: `pr/3-inplace-replacement-v2`
**Base**: `pr/2-click-to-move-input-v2`

### Title
```
feat(surface): in-place selection replacement and shift-select in prompt input
```

### Description

```markdown
## Summary

Adds GUI-style text editing within the shell prompt: select text with shift+arrows or shift+click, then type to replace. Selections within the input area behave like a text editor rather than terminal copy-selection.

**Part 3 of 3** in the in-place command editing series:
- PR 1: [Prompt bounds infrastructure](#link-to-pr1)
- PR 2: [Click-to-move in prompt input](#link-to-pr2)
- **→ PR 3**: In-place edit selection (this PR)

## Changes

This PR contains three logical sections:

### Section A: Edit Selection Core
- Add `edit_selection_active` flag to distinguish edit vs copy selections
- Replace selected text when typing (via arrow + delete sequences)
- Skip copy-on-select for edit selections

### Section B: Shift-Select
- Shift+Left/Right extends selection by character
- Shift+Up/Down extends selection by row (preserving column)
- Shift+Click extends selection from cursor to click position
- Selection uses half-open bounds (end exclusive)

### Section C: Multiline Input Handling
- Span unknown rows in `selectPrompt()` for blank lines in multiline input
- Propagate `semantic_prompt` on linefeed for multiline commands
- Fix click-to-move on last row of multiline input
- Clamp selection to rows with actual text

## Behavioral Specs

**A) Shift+Arrow** (multi-line input):
- Extends selection by one character/row, clamped to input bounds
- Anchor stays fixed; active end moves
- Cursor tracks the active end

**B) Exiting selection with arrows**:
- Left → collapse to start; Right → collapse to end
- Up → collapse to input start; Down → collapse to input end
- Collapse only, no extra movement

**C) Shift+Click**:
- Anchor at cursor, click sets active end
- Selection clamped to input bounds

**F) Blank lines in multiline input**:
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
```

---

## Gist Content (Full Design Docs)

Create a gist with the following for reviewers who want full context:

**Filename**: `inplace-command-editing-design.md`

Contents: Combine the key sections from `bizlogic.md` and `inplace-command-editing-plan.md`:
- Scope/assumptions
- Full behavioral specs (A-G)
- Architectural decisions
- Implementation tracking table
- Test plan details
