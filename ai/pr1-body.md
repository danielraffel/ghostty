## Summary

Adds infrastructure to track where user input begins within shell prompt rows. This enables future features that need to distinguish prompt text from user-typed input.

**Part 1 of 3** in the in-place command editing series:
- **→ PR 1**: Prompt bounds infrastructure (this PR)
- PR 2: Click-to-move in prompt input
- PR 3: In-place edit selection

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
