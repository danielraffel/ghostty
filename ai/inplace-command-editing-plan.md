# In-Place Command Editing Design Plan (v5)

## Summary
Implementation + tracking plan for GUI-style replacement of selected text on the active shell input line, using Ghostty prompt semantics and input pipeline. This document now reflects completed work in the stacked PR series and includes the newer prompt-input cursor UX (click-to-move input, shift-select by character).

**Key implementation additions (v5)**:
- Input boundary tracking (`Row.input_start_col`, `semantic_prompt_seen`) with tests
- Input-only helpers (`inputBounds`, `inputPath`, `countInputCharacters`)
- In-place selection replacement for typing/paste via arrow + delete sequences
- Click-to-move within prompt input (default on) and preserved double-click selection
- Shift+arrow prompt selection (left/right/up/down) that moves cursor and clamps to input bounds
- Shift-click selection extension in prompt input (anchor at cursor, click sets active end)
- Edit selection uses half-open bounds (end exclusive) to avoid off-by-one highlights or trailing spaces on the last character
- Vertical shift selection preserves the insertion column and only skips wide spacer tails
- `@"inplace-command-editing"` default enabled for local builds

---

## Codebase Review (What Exists Today)

### Cursor, Screen State, and Prompt Semantics

| Component | Location | Notes |
|-----------|----------|-------|
| `Row.SemanticPrompt` | [page.zig:1750-1798](src/terminal/page.zig#L1750-L1798) | u3 enum: `unknown`, `prompt`, `prompt_continuation`, `input`, `command` |
| `Terminal.markSemanticPrompt()` | [Terminal.zig:1065-1075](src/terminal/Terminal.zig#L1065-L1075) | Sets row semantic prompt at cursor position |
| `Terminal.cursorIsAtPrompt()` | [Terminal.zig:1082-1109](src/terminal/Terminal.zig#L1082-L1109) | Searches backward from cursor; returns true if prompt/input found before command |
| OSC 133 handlers | [stream_handler.zig:1068-1086](src/termio/stream_handler.zig#L1068-L1086) | `promptStart()`, `promptContinuation()`, `promptEnd()`, `endOfInput()` |

**Key implementation details**:
- `cursorIsAtPrompt()` returns `false` on alternate screen (security boundary)
- Searches backward through rows; treats `.unknown` as continuation (can traverse entire scrollback)
- Row semantic state is the *only* boundary signal; no column-level data exists
- `markSemanticPrompt()` simply assigns to current cursor row without capturing column

### Selection

| Component | Location | Notes |
|-----------|----------|-------|
| `Screen.selection` | [Screen.zig](src/terminal/Screen.zig) | Optional selection, tracked or untracked |
| `Selection` struct | [Selection.zig](src/terminal/Selection.zig) | Bounds union (tracked/untracked), rectangle mode, `init()`/`track()`/`deinit()` |
| `Screen.selectPrompt()` | [Screen.zig:2812-2853](src/terminal/Screen.zig#L2812-L2853) | Returns full-row bounds; sets x=0 to x=cols-1; spans through .unknown rows if more .input follows |
| `Screen.promptPath()` | [Screen.zig:2853-2877](src/terminal/Screen.zig#L2853-L2877) | Computes cursor movement delta within prompt bounds |
| Copy-on-select | [Surface.zig:2333-2366](src/Surface.zig#L2333-L2366) | `setSelection()` respects config, copies to clipboard |

**Key implementation details**:
- `selectPrompt()` always returns x=0 to x=cols-1 (full row width) — **no column differentiation**
- `selectPrompt()` continues through .unknown rows when scanning forward for prompt end, only stopping at .command or end of screen; this handles blank lines in multiline input (e.g., Option+Return)
- Selection can be "tracked" (survives screen changes via pin tracking) or "untracked" (fast, invalidated by changes)
- Copy-on-select is configurable: `.false`, `.true` (selection clipboard), `.clipboard` (both)
- Related helpers: `selectLine()`, `selectWord()`, `selectOutput()` for different selection modes
- Edit selections are rendered with end-exclusive bounds on the ordered end row to avoid highlighting an extra trailing cell at the input end

### Input Path (Keyboard + PTY)

| Component | Location | Notes |
|-----------|----------|-------|
| `Surface.keyCallback()` | [Surface.zig:2614-2775](src/Surface.zig#L2614-L2775) | Main key event handler; remapping → bindings → encoding → queueIo |
| `Surface.encodeKey()` | [Surface.zig:3142-3237](src/Surface.zig#L3142-L3237) | Transforms keystroke to PTY bytes; returns `WriteReq` |
| `Surface.encodeKeyOpts()` | [Surface.zig:3217-3237](src/Surface.zig#L3217-L3237) | Builds encoding options from terminal state |
| `Surface.queueIo()` | [Surface.zig](src/Surface.zig) | Sends message to termio thread |
| `arrowSequence()` / `sendArrowSequences()` | [Surface.zig](src/Surface.zig) | Shared arrow-key helpers for cursor motion |
| `sendDeleteSequences()` | [Surface.zig](src/Surface.zig) | Sends delete key sequences for selection replacement |
| `clickMoveCursor()` | [Surface.zig:4312-4361](src/Surface.zig#L4312-L4361) | Reference pattern for sending synthetic keystrokes |
| `clickMoveCursorInput()` | [Surface.zig](src/Surface.zig) | Uses `inputClickMovePath` + `sendArrowSequences` for prompt input |
| Message types | [message.zig](src/termio/message.zig) | `WriteReq.Small` (≤38 bytes), `WriteReq.Stable`, `WriteReq.Alloc` |

**Key implementation details**:
- `clickMoveCursor()` uses `queueIo(.{ .write_stable = arrow }, .locked)` pattern
- `sendArrowSequences()` centralizes cursor motion for click-to-move input and shift selection
- Respects `cursor_keys` mode: `\x1bOA` (application) vs `\x1b[A` (normal)
- Gates on `shell_redraws_prompt` flag (conflates semantic prompt detection with redraw behavior)
- `encodeKey()` tries fixed buffer first, falls back to allocation

### Mouse Selection Flow

| Event | Location | Behavior |
|-------|----------|----------|
| Left press | [Surface.zig:3873-4240](src/Surface.zig#L3873-L4240) | Records `left_click_pin`, handles multi-click (word/line select) |
| Shift + left press (prompt input) | [Surface.zig](src/Surface.zig) | Extends edit-selection from cursor to clicked pin (anchor stays fixed, active end moves) |
| Left drag | [Surface.zig:4725-4800](src/Surface.zig#L4725-L4800) | Updates selection endpoint via `setSelection()` |
| Left release | [Surface.zig:3985-3996](src/Surface.zig#L3985-L3996) | Copy-on-select if configured |

**Key implementation details**:
- `mouse.left_click_count` tracks single/double/triple click
- `mouse.left_click_pin` stores initial click position for drag validation
- Selection drag validates screen hasn't changed since click began
- Shift-click inside prompt input extends selection from cursor; shift-click outside input behaves normally

### Terminal Flags

**Location**: [Terminal.zig:80-126](src/terminal/Terminal.zig#L80-L126)

```zig
flags: packed struct {
    shell_redraws_prompt: bool = false,  // Set by promptStart(); conflates two meanings
    mouse_event: MouseEvents = .none,    // .x10, .normal, .button, .any
    password_input: bool = false,
    focused: bool = true,
    // ... other flags
}
```

**Issue identified**: `shell_redraws_prompt` is used in `clickMoveCursor()` (line 4326) as a proxy for "semantic prompts seen" but semantically means "shell will redraw prompt on resize". This conflation should be avoided for feature gating.

---

## Architectural Blockers / Assumptions

| Blocker | Impact | Mitigation |
|---------|--------|------------|
| **No input boundary column** | Cannot distinguish prompt text from user input on same row | Add `Row.input_start_col` |
| **No input buffer** | Edits must be expressed as PTY keystrokes | Use arrow + delete + insert sequences |
| **Prompt integration required** | Without OSC 133, no safe way to detect input area | Feature disabled when `semantic_prompt_seen == false` |
| **Mouse capture** | Applications can grab mouse events | Feature disabled when `mouse_event != .none` |
| **Alternate screen** | Different application context | `cursorIsAtPrompt()` already returns false |

---

## Design Proposal

### Opt-In and Scope

Add a config flag in [Config.zig](src/config/Config.zig):
```zig
@"inplace-command-editing": bool = true,
```

**Activation conditions** (all must be true):
1. Config flag enabled
2. `Terminal.cursorIsAtPrompt()` returns true
3. `Terminal.flags.semantic_prompt_seen == true` (new flag)
4. `Terminal.flags.password_input == false`
5. `Terminal.flags.mouse_event == .none`
6. Surface is not read-only
7. Not in IME preedit state

### Prompt Boundary Detection (Needed for Input-Only Editing)

**Goal**: Determine where user input begins within a prompt row.

#### Row-Level Input Boundary Column

Add to `Row` struct in [page.zig](src/terminal/page.zig):
```zig
/// Column where user input begins on this row. Set on promptEnd().
/// null = unknown/not applicable, 0 = entire row is input (continuation)
input_start_col: ?u16 = null,
```

**Lifecycle management**:

| Event | Action | Location |
|-------|--------|----------|
| `promptEnd()` | Set `input_start_col = cursor.x` | [stream_handler.zig:1079](src/termio/stream_handler.zig#L1079) |
| Soft wrap during input | Set `input_start_col = 0` on new row | `Terminal.printWrap()` |
| Newline during input | Set `input_start_col = 0` on new row | `Terminal.linefeed()` |
| Carriage return | Consider cursor position changes | `Terminal.carriageReturn()` |
| Row clear/erase | Reset `input_start_col = null` | Row lifecycle functions |
| Row reuse (page recycling) | Reset `input_start_col = null` | Page recycling code |

**Detection of "during input"**: Check if current row's semantic prompt is `.input` before propagating to new rows.

#### Semantic Prompt Seen Flag

Add to `Terminal.flags` in [Terminal.zig](src/terminal/Terminal.zig):
```zig
semantic_prompt_seen: bool = false,
```

Set to `true` in any of:
- `StreamHandler.promptStart()`
- `StreamHandler.promptContinuation()`
- `StreamHandler.promptEnd()`
- `StreamHandler.endOfInput()`

**Rationale**: Avoid reusing `shell_redraws_prompt` which has different semantics (prompt redraw behavior vs. feature availability).

### New Screen Helpers

Add to [Screen.zig](src/terminal/Screen.zig):

#### `inputBounds(pin: Pin) ?Selection`

Returns selection covering only the input area (excludes prompt text):
```zig
pub fn inputBounds(self: *Screen, pin: Pin) ?Selection {
    // 1. Get prompt bounds (full rows)
    const prompt_sel = self.selectPrompt(pin) orelse return null;

    // 2. Find start row's input_start_col
    const start_row = prompt_sel.start().rowAndCell().row;
    const input_start = start_row.input_start_col orelse return null;

    // 3. Adjust selection start to input column
    var input_sel = prompt_sel;
    // Clamp start.x to input_start_col
    // ... implementation details

    return input_sel;
}
```

#### `inputPath(from: Pin, to: Pin) struct { x: isize, y: isize }`

Like `promptPath()` but clamped to input bounds:
```zig
pub fn inputPath(self: *Screen, from: Pin, to: Pin) struct { x: isize, y: isize } {
    const bounds = self.inputBounds(from) orelse return .{ .x = 0, .y = 0 };
    // Clamp 'to' within bounds
    // Compute delta
    return .{ .x = delta_x, .y = delta_y };
}
```

#### `countInputCharacters(sel: Selection) usize`

Count logical characters in selection (for delete count):
```zig
pub fn countInputCharacters(self: *Screen, sel: Selection) usize {
    var count: usize = 0;
    const ordered = sel.ordered(self, .forward);
    var iter = ordered.start().cellIterator(.right_down, ordered.end());
    while (iter.next()) |pin| {
        const cell = pin.rowAndCell().cell;
        // Skip spacer tails (wide char continuations)
        if (cell.wide == .spacer_tail) continue;
        count += 1;
    }
    return count;
}
```

**Alternative**: Use `selectionString()` and count UTF-8 codepoints. Less accurate for complex graphemes but simpler.

### Selection Classification: Copy vs Edit

Add to `Surface` struct in [Surface.zig](src/Surface.zig):
```zig
/// True when selection is within input bounds and eligible for replacement
edit_selection_active: bool = false,
```

**Classification logic** (called in mouse selection flow):

```zig
fn classifySelection(self: *Surface) void {
    if (!self.config.inplace_command_editing) {
        self.edit_selection_active = false;
        return;
    }

    const sel = self.renderer_state.terminal.screen.selection orelse {
        self.edit_selection_active = false;
        return;
    };

    // Check all activation conditions
    const t = self.renderer_state.terminal;
    if (!t.flags.semantic_prompt_seen or
        t.flags.password_input or
        t.flags.mouse_event != .none or
        !t.cursorIsAtPrompt()) {
        self.edit_selection_active = false;
        return;
    }

    // Check if selection is fully within input bounds
    const screen = t.screens.active;
    const sel_start = sel.topLeft(screen);
    const sel_end = sel.bottomRight(screen);
    const input_bounds = screen.inputBounds(sel_start) orelse {
        self.edit_selection_active = false;
        return;
    };

    self.edit_selection_active =
        input_bounds.contains(screen, sel_start) and
        input_bounds.contains(screen, sel_end);
}
```

**Behavior when `edit_selection_active == true`**:
- Skip copy-on-select on mouse release (avoid clipboard pollution)
- Manual copy shortcuts (Cmd+C / Ctrl+Shift+C) still work
- Selection not cleared on first typed character (replacement handles it)

### Replacement Flow (Keyboard + Paste)

**Trigger**: Key/paste event when `edit_selection_active == true` and event would insert text.

**Algorithm**:

```
1. VALIDATE STATE
   - Re-check cursorIsAtPrompt()
   - Verify selection still within input bounds
   - If invalid: clear edit_selection_active, fall through to normal handling

2. MOVE CURSOR TO SELECTION START
   - Compute delta via Screen.inputPath(cursor_pin, selection_start)
   - For each row: send Up/Down arrow sequence
   - For each column: send Left/Right arrow sequence
   - Use cursor_keys mode for correct escape sequences

3. DELETE SELECTION
   - Count characters via Screen.countInputCharacters(selection)
   - Send Delete key sequence N times
   - Alternative: send Ctrl+K (kill to EOL) if selection extends to end

4. INSERT NEW TEXT
   - Normal typing: use existing encodeKey() pipeline
   - Paste: use existing paste encoding after deletion

5. CLEANUP
   - Clear selection
   - Set edit_selection_active = false
   - Queue render
```

**Key sequence generation** (reference: `clickMoveCursor()` at [Surface.zig:4340-4355](src/Surface.zig#L4340-L4355)):

```zig
const arrow_up = if (t.modes.get(.cursor_keys)) "\x1bOA" else "\x1b[A";
const arrow_down = if (t.modes.get(.cursor_keys)) "\x1bOB" else "\x1b[B";
const arrow_right = if (t.modes.get(.cursor_keys)) "\x1bOC" else "\x1b[C";
const arrow_left = if (t.modes.get(.cursor_keys)) "\x1bOD" else "\x1b[D";
const delete_key = "\x1b[3~";  // Standard VT Delete
```

**Delete key considerations**:
- Standard VT Delete sequence: `\x1b[3~`
- Arrow keys respect `cursor_keys` mode; Delete typically does not have variants
- Forward delete preferred (cursor at selection start after movement)
- If Delete proves unreliable, consider Backspace (`\x7f` or `\x08`) as fallback

**Reference implementation sketch**:
```zig
fn performEditReplacement(self: *Surface, event: input.KeyEvent) bool {
    if (!self.edit_selection_active) return false;

    // 1. Validate state
    const t = self.renderer_state.terminal;
    if (!t.cursorIsAtPrompt()) {
        self.edit_selection_active = false;
        return false;
    }

    const screen = t.screens.active;
    const sel = screen.selection orelse {
        self.edit_selection_active = false;
        return false;
    };

    // 2. Compute movement to selection start
    const path = screen.inputPath(screen.cursor.page_pin.*, sel.start());

    // 3. Send arrow sequences for movement
    self.sendArrowSequences(path);

    // 4. Compute and send delete sequences
    const delete_count = screen.countInputCharacters(sel);
    self.sendDeleteSequences(delete_count);

    // 5. Cleanup (insertion handled by normal flow after return)
    screen.clearSelection();
    self.edit_selection_active = false;

    return true;  // Indicates replacement was initiated
}
```

### IME/Preedit Handling

In [Surface.zig](src/Surface.zig) `preeditCallback()`:
```zig
pub fn preeditCallback(self: *Surface, ...) ... {
    // Cancel edit selection when preedit begins
    if (self.edit_selection_active) {
        self.edit_selection_active = false;
        // Optionally clear selection too
    }
    // ... existing preedit handling
}
```

**Rationale**: IME composition creates intermediate states; edit-selection replacement during composition would produce incorrect results.

### Cursor vs Edit Selection Interactions

**Unchanged behavior**:
- Standard selection and copy continue to work outside the input area
- Mouse capture in applications continues to bypass selection/editing
- Alt-click cursor movement (`cursor-click-to-move`) remains unchanged
- Escape clears selection as it already does

### Undo / Cancellation

- `Escape` clears selection (existing behavior in `Surface.keyCallback`)
- Undo relies on shell line editor (zsh/bindkey undo, readline undo)
- Edit is sent as actual keypresses so shells can undo normally

---

## Tradeoffs & Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Prompt boundary accuracy** | Editing could target prompt text without `input_start_col` | `input_start_col` precisely marks boundary |
| **Shell compatibility** | Delete behavior varies across shells | Use standard VT Delete; document limitations |
| **Multiline input** | Wrapped lines need correct boundary propagation | Propagate `input_start_col = 0` on wrap/newline |
| **Blank lines in input** | Blank lines may have .unknown semantic_prompt, truncating selection bounds | `selectPrompt()` spans through .unknown rows if more .input follows |
| **Pin.before() node comparison** | `Pin.before()` compares page nodes in addition to coordinates; same-row pins with different node refs give incorrect results | Use direct row coordinate comparisons (`node == end.node and y == end.y`) instead of `Pin.before()` for same-row checks |
| **Mouse reporting intercepts clicks** | Mouse reporting block consumes left-click release before click-to-move-input can handle it | Move click-to-move handling before mouse reporting block; fall through if click is outside input bounds |
| **tmux/ssh** | Semantic prompts may be absent | Feature auto-disables (`semantic_prompt_seen == false`) |
| **Wide/combining characters** | Character count may differ from cell count | Count logical characters, not cells |
| **Performance** | Selection iteration adds overhead | Keep helpers allocation-free; use cell iteration |
| **Philosophical departure** | Terminals separate selection from editing | Opt-in only; limited to prompt input |

### Shell Compatibility Matrix

| Shell | Default Delete | Notes |
|-------|---------------|-------|
| bash (readline) | `\x1b[3~` (delete-char) | Standard; can be remapped |
| zsh | `\x1b[3~` (delete-char) | Standard; bindkey customizable |
| fish | `\x1b[3~` | Standard |
| Custom readline configs | May vary | User may rebind; document limitation |

---

## Test Plan

### Unit Tests (Zig)

#### Phase 1: Boundary Tracking Tests

Location: [Terminal.zig](src/terminal/Terminal.zig) or new test file

```zig
test "input_start_col set on promptEnd" {
    // Setup: cursor at column 5
    // Call: markSemanticPrompt(.input) via promptEnd path
    // Assert: row.input_start_col == 5
}

test "input_start_col propagates on soft wrap" {
    // Setup: row with input_start_col = 5, semantic_prompt = .input
    // Call: printWrap() to create continuation row
    // Assert: new row.input_start_col == 0
}

test "input_start_col propagates on linefeed" {
    // Setup: row with semantic_prompt = .input
    // Call: linefeed() during input
    // Assert: new row.input_start_col == 0
}

test "input_start_col reset on row clear" {
    // Setup: row with input_start_col = 5
    // Call: clearRow() or equivalent
    // Assert: row.input_start_col == null
}

test "semantic_prompt_seen flag set on any OSC 133" {
    // Call: any OSC 133 handler (promptStart, promptEnd, etc.)
    // Assert: terminal.flags.semantic_prompt_seen == true
}
```

#### Phase 2: Input Bounds Tests

Location: [Screen.zig](src/terminal/Screen.zig)

```zig
test "inputBounds single line" {
    // Setup: prompt "$ " at col 0-1, input at col 2+
    // Assert: inputBounds returns selection starting at col 2
}

test "inputBounds multiline prompt" {
    // Setup: prompt on row 0, input starts row 0 col 5, continues row 1
    // Assert: bounds span both rows correctly
}

test "inputBounds wrapped input" {
    // Setup: input that wraps to second row
    // Assert: continuation row has input_start_col = 0
}

test "inputBounds outside prompt returns null" {
    // Setup: cursor on command output row
    // Assert: inputBounds returns null
}

test "inputPath computes correct delta" {
    // Setup: cursor at row 2 col 10, target at row 1 col 5
    // Assert: path.x == -5, path.y == -1 (clamped to input bounds)
}

test "countInputCharacters with wide chars" {
    // Setup: selection containing wide characters (e.g., CJK)
    // Assert: count reflects logical characters, not cells
}

test "countInputCharacters skips spacer tails" {
    // Setup: selection with wide char spanning 2 cells
    // Assert: count is 1, not 2
}

test "selectPrompt spans unknown rows between input" {
    // Setup: row 0 = .input, row 1 = .unknown (blank line), row 2 = .input
    // Assert: selectPrompt returns bounds spanning rows 0-2
}

test "selectPrompt stops at command after unknown" {
    // Setup: row 0 = .input, row 1 = .unknown (blank line), row 2 = .command
    // Assert: selectPrompt returns bounds ending at row 0 (last known .input)
}
```

#### Phase 3: Edit Selection Tests

Location: [Surface.zig](src/Surface.zig) or new test file

```zig
test "edit_selection_active within input bounds" {
    // Setup: selection fully within input area, all conditions met
    // Assert: edit_selection_active == true
}

test "edit_selection_active false outside input bounds" {
    // Setup: selection includes prompt text
    // Assert: edit_selection_active == false
}

test "edit_selection_active false without semantic prompts" {
    // Setup: semantic_prompt_seen == false
    // Assert: edit_selection_active == false regardless of selection
}

test "edit_selection_active false during password input" {
    // Setup: password_input == true
    // Assert: edit_selection_active == false
}

test "edit_selection_active false with mouse capture" {
    // Setup: mouse_event != .none
    // Assert: edit_selection_active == false
}

test "copy-on-select skipped for edit selection" {
    // Setup: edit_selection_active == true, mouse release
    // Assert: clipboard not updated
}

test "manual copy works with edit selection" {
    // Setup: edit_selection_active == true, Cmd+C pressed
    // Assert: clipboard updated normally
}
```

#### Phase 4: Replacement Logic Tests

```zig
test "replacement generates correct PTY sequence" {
    // Setup: selection "foo" at col 5-7, cursor at col 10, replacement char 'x'
    // Assert: generated sequence is: Left×3, Delete×3, then normal key encoding
}

test "replacement respects cursor_keys mode" {
    // Setup: cursor_keys mode enabled (DECCKM)
    // Assert: arrow sequences use \x1bO format instead of \x1b[
}

test "replacement handles multiline selection" {
    // Setup: selection spans two rows
    // Assert: movement includes row changes, delete count correct
}

test "replacement clears edit_selection_active" {
    // Setup: perform replacement
    // Assert: edit_selection_active == false after completion
}
```

### Integration / Regression Tests

1. **Selection still copies outside input area**
   - Select output text → verify clipboard contains selection
   - `edit_selection_active` should remain false

2. **Non-prompt areas behave normally**
   - When `cursorIsAtPrompt() == false`, typing clears selection (no replacement)

3. **Password mode disables feature**
   - During password input, edit-selection never activates

4. **Alternate screen disables feature**
   - In vim/tmux (alternate screen), edit-selection never activates

5. **IME preedit cancels edit selection**
   - Begin preedit → verify `edit_selection_active` cleared

### Manual Acceptance Testing

| Scenario | Expected Behavior |
|----------|-------------------|
| bash + single-line command | Select text → type → replaces selection |
| zsh + multiline prompt | Select input (not prompt) → type → replaces |
| fish + wrapped command | Select across wrap → type → replaces |
| tmux session | Feature disabled; normal selection behavior |
| ssh without integration | Feature disabled; normal selection behavior |
| Wide characters (日本語) | Delete count matches logical characters |
| Combining characters (é) | Delete count handles correctly |
| Escape during selection | Selection clears, no replacement |
| Cmd+C with edit selection | Copies to clipboard (override skip) |
| Shift-click in input | Anchor at cursor → click extends selection; repeated shift-click expands/contracts |

---

## Pull Request Strategy

**Structure**: Stacked PR series, one per phase.

```
main
  └── phase-1/scaffolding-data-model
        └── phase-2/input-bounds-helpers
              └── phase-3/edit-selection-mode
                    └── phase-4/replacement-logic
                          └── phase-5/shell-compat-polish
```

**Rules**:
- Each branch based on previous phase's branch
- Each PR contains only incremental changes for that phase
- PRs are reviewable and mergeable independently
- PRs should not be squashed across phases; each phase should remain independently reviewable in Git history
- If earlier phase needs changes: update, then rebase subsequent branches
- Force-push updated branches as needed

**Commit message format**:
```
feat(terminal): add Row.input_start_col for input boundary tracking

Part of in-place command editing feature (Phase 1).

- Add input_start_col field to Row struct
- Set column in promptEnd() handler
- Propagate on soft wrap and newline during input mode
- Reset on row clear/reuse
- Add semantic_prompt_seen flag to Terminal.flags

Tests: src/terminal/Terminal.zig boundary tracking tests
```

---

## Implementation Tracking

**Recommended approach**: track progress directly in this document with a small, living table aligned to the stacked PRs. This keeps scope, status, and test coverage visible in one place.

Current stack:

| Phase/Scope | Branch | PR | Status | Tests Run | Notes |
|-------------|--------|----|--------|-----------|-------|
| 1-2 (prompt bounds + input helpers) | `pr/1-prompt-bounds-v2` |  | Ready for review | `zig build test` | `semantic_prompt_seen`, `input_start_col`, `inputBounds`, `inputPath`, `countInputCharacters` |
| UX add-on (prompt input click-to-move) | `pr/2-click-to-move-input-v2` |  | Ready for review | `zig build test` | `clickMoveCursorInput`, input gating, double-click preserved |
| 3-4 (edit selection + replacement) | `pr/3-inplace-replacement-v2` | c1d2aa105 | Ready for review | `zig build test` | selection gating, replace-on-type/paste, tests; **blank line fix**: `selectPrompt` spans .unknown rows |
| 4b (shift-select by character + default) | `pr/3-inplace-replacement-v2` |  | Ready for review | `zig build test` | shift+arrow selection, default `inplace-command-editing` |
| 4c (shift-click select extension) | `pr/4-shift-click-input-selection` |  | Not started | `zig build test` | shift-click extends selection from cursor within input bounds |
| Fix: multi-line click last row | `pr/3-inplace-replacement-v2` | df3484502 | Merged | manual | **Pin.before() fix**: `inputCursorIndex` loop termination was using `Pin.before()` which compares page nodes; replaced with direct row coordinate comparisons. Also moved click-to-move before mouse reporting. |
| Fix: shift selection + click-to-deselect + ESC | `pr/3-inplace-replacement-v2` | d23daf736 | Ready for review | manual | **Shift boundary fix**: shift+up on first line extends to start, shift+down on last line extends to end. **Click-to-deselect**: plain click clears any selection. **ESC clears selection**. **Delete with selection**: backspace/delete deletes selection without extra char. **U+2028/U+2029 normalization**: paste converts Unicode line separators to newlines. |
| Fix: ESC returns to anchor | `pr/3-inplace-replacement-v2` | 56e5840a7 | Ready for review | manual | **ESC returns cursor to anchor**: When pressing ESC to cancel a selection, cursor moves back to where selection started (anchor) before clearing, providing intuitive cancel behavior. |

Status values suggestion: `Not started`, `In progress`, `Ready for review`, `Merged`.

---

## Agent Checklist

Use this checklist per phase to keep diffs tight and reviewable.

- Confirm the phase branch is based on the previous phase branch.
- Scope work strictly to the phase’s “Changes” table.
- Add or update tests listed in the phase’s test coverage section.
- Ensure no user-visible behavior changes in Phase 1 and Phase 2.
- Update or add documentation only in Phase 5 (unless a phase explicitly requires it).
- Run `zig fmt .` before opening the PR.
- Run `zig build test` or the smallest targeted test command that covers the phase changes.
- Verify selection behavior outside prompts is unchanged.
- Populate the Implementation Tracking table (branch, PR link, tests run).

---

## Phased Implementation Plan

### Phase 1: Scaffolding and Data Model

**Goal**: Track input start column and prompt integration availability.

**Changes**:

| File | Change |
|------|--------|
| [page.zig](src/terminal/page.zig) | Add `Row.input_start_col: ?u16 = null` |
| [Terminal.zig](src/terminal/Terminal.zig) | Add `flags.semantic_prompt_seen: bool = false` |
| [stream_handler.zig](src/termio/stream_handler.zig) | Set `input_start_col = cursor.x` in `promptEnd()` |
| [stream_handler.zig](src/termio/stream_handler.zig) | Set `semantic_prompt_seen = true` in all OSC 133 handlers |
| [Terminal.zig](src/terminal/Terminal.zig) | Propagate `input_start_col = 0` in `printWrap()` when semantic prompt is `.input` |
| [Terminal.zig](src/terminal/Terminal.zig) | Propagate `input_start_col = 0` in `linefeed()` when semantic prompt is `.input` |
| [page.zig](src/terminal/page.zig) | Reset `input_start_col = null` in row clear/init functions |

**Success criteria**: Unit tests for boundary tracking pass. No user-visible behavior changes are expected in this phase.

**Test coverage**: Prompt/input boundary unit tests (see Test Plan Phase 1).

---

### Phase 2: Input Bounds Helpers

**Goal**: Query input-only ranges and paths.

**Changes**:

| File | Change |
|------|--------|
| [Screen.zig](src/terminal/Screen.zig) | Add `inputBounds(pin: Pin) ?Selection` |
| [Screen.zig](src/terminal/Screen.zig) | Add `inputPath(from: Pin, to: Pin) struct { x: isize, y: isize }` |
| [Screen.zig](src/terminal/Screen.zig) | Add `countInputCharacters(sel: Selection) usize` |

**Success criteria**: Correct bounds/path in unit tests. No user-visible behavior changes are expected in this phase.

**Test coverage**: Input bounds helper tests (see Test Plan Phase 2).

---

### Phase 3: Edit Selection Mode

**Goal**: Distinguish edit selection from copy selection.

**Changes**:

| File | Change |
|------|--------|
| [Config.zig](src/config/Config.zig) | Add `@"inplace-command-editing": bool = true` |
| [Surface.zig](src/Surface.zig) | Add `edit_selection_active: bool = false` field |
| [Surface.zig](src/Surface.zig) | Add `classifySelection()` helper function |
| [Surface.zig](src/Surface.zig) | Call `classifySelection()` in `mouseButtonCallback()` and `cursorPosCallback()` |
| [Surface.zig](src/Surface.zig) | Skip copy-on-select in `setSelection()` when `edit_selection_active` |
| [Surface.zig](src/Surface.zig) | Clear `edit_selection_active` in `preeditCallback()` |

**Success criteria**: Selection behaves normally outside prompt; edit mode engages within prompt.

**Test coverage**: Surface gating tests + regression for copy selection (see Test Plan Phase 3).

---

### Phase 4: Replacement Logic

**Goal**: Replace selection on typed text/paste.

**Changes**:

| File | Change |
|------|--------|
| [Surface.zig](src/Surface.zig) | Add `performEditReplacement(event: KeyEvent) bool` |
| [Surface.zig](src/Surface.zig) | Add `sendArrowSequences(path)` helper |
| [Surface.zig](src/Surface.zig) | Add `sendDeleteSequences(count)` helper |
| [Surface.zig](src/Surface.zig) | Intercept in `keyCallback()` when `edit_selection_active` and text key |
| [Surface.zig](src/Surface.zig) | Handle paste events similarly |

**Success criteria**: Typing replaces selection on input line; no changes outside prompt.

**Test coverage**: Replacement planning tests + PTY sequence tests (see Test Plan Phase 4).

---

### Phase 5: Shell Compatibility + UX Polish

**Goal**: Improve robustness and prompt-input UX polish.

**Changes**:

| File | Change |
|------|--------|
| [Surface.zig](src/Surface.zig) | Add prompt input click-to-move (`inputClickMovePath` + `sendArrowSequences`) |
| [Surface.zig](src/Surface.zig) | Preserve double-click word selection after click-to-move |
| [Surface.zig](src/Surface.zig) | Add prompt input shift-select by character (left/right/up/down, cursor moves + bounds clamp) |
| [Surface.zig](src/Surface.zig) | Add prompt input shift-click selection (anchor at cursor, click sets active end, clamp to input bounds) |
| [Surface.zig](src/Surface.zig) | Add guards for edge cases discovered in testing |
| Documentation | Add user-facing documentation for feature |
| Documentation | Document shell compatibility matrix and limitations |

**Success criteria**: Works across bash/zsh/fish; no regressions in selection behavior.

**Test coverage**: Manual acceptance testing across shells.

---

## Validation Checklist

### Before Each Phase PR

- [ ] All new code has corresponding tests
- [ ] `zig build test` passes
- [ ] `zig fmt .` applied
- [ ] No regressions in existing selection behavior
- [ ] Manual testing on macOS (primary platform)

### Before Phase 5 Merge (Feature Complete)

- [ ] Manual testing on bash, zsh, fish
- [ ] Manual testing with multiline prompts
- [ ] Manual testing with wrapped commands
- [ ] Verified feature disabled in tmux/ssh without integration
- [ ] Verified feature disabled during password input
- [ ] Verified feature disabled on alternate screen
- [ ] Performance acceptable (no visible lag on selection/typing)
- [ ] Wide character handling verified
- [ ] IME behavior verified

---

## What Remains Unchanged

- Terminal rendering stays output-driven; no local command buffer
- Selection behavior in non-prompt areas stays copy-focused
- Mouse reporting and alternate screen behavior untouched
- `clickMoveCursor()` continues to work independently
- No platform-specific code required for this design

---

## Appendix: Reference Implementation Snippets

### Arrow Key Sequence Generation

From [Surface.zig](src/Surface.zig) `arrowSequence()`:

```zig
const arrow = switch (direction) {
    .up => if (t.modes.get(.cursor_keys)) "\x1bOA" else "\x1b[A",
    .down => if (t.modes.get(.cursor_keys)) "\x1bOB" else "\x1b[B",
    .right => if (t.modes.get(.cursor_keys)) "\x1bOC" else "\x1b[C",
    .left => if (t.modes.get(.cursor_keys)) "\x1bOD" else "\x1b[D",
};

self.queueIo(.{ .write_stable = arrow }, .locked);
```

### Delete Key Sequence

Standard VT Delete:
```zig
const delete_key: []const u8 = "\x1b[3~";
self.queueIo(.{ .write_stable = delete_key }, .locked);
```

### Selection Cell Iteration Pattern

From [Screen.zig](src/terminal/Screen.zig):

```zig
const ordered = sel.ordered(screen, .forward);
var iter = ordered.start().cellIterator(.right_down, ordered.end());
while (iter.next()) |pin| {
    const cell = pin.rowAndCell().cell;
    // Process cell
    if (cell.wide == .spacer_tail) continue;  // Skip wide char continuations
    count += 1;
}
```

### Locking Strategy for queueIo

- `.locked` = renderer mutex already held (don't acquire/release)
- `.unlocked` = renderer mutex not held (will acquire inside queueIo)

Use `.locked` when called from within `keyCallback()` or `mouseButtonCallback()` where lock is already held.
