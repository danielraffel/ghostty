# How to Debug Ghostty

## Building

```bash
zig build
```

## Running from Terminal (to see logs)

```bash
./zig-out/Ghostty.app/Contents/MacOS/ghostty
```

This runs Ghostty and shows debug log output in the terminal where you launched it.

## Using the Inspector

Open the Inspector via **View > Inspector** or **Cmd+Shift+I**.

### Inspector Tabs

- **Screen**: Shows cursor position, active screen, keyboard mode, memory usage
- **Modes**: Terminal mode flags
- **Keyboard**: Keyboard input handling info
- **Terminal IO**: Terminal I/O statistics
- **Cell**: Inspect individual cell properties (use "Picker" button then click a cell)
- **Dear ImGui Demo**: ImGui demo window

### Cell Inspector

1. Click the **Cell** tab
2. Click the **Picker** button
3. Click on any cell in the terminal
4. View properties: codepoint, width, colors, etc.

### Surface Info Panel

Shows:
- Screen/grid dimensions
- Cell size
- Mouse hover and click positions (useful for debugging click handling)

## Adding Debug Logging

### Zig scoped logging
```zig
const log = std.log.scoped(.your_scope);
log.debug("message with value: {}", .{value});
```

**Note:** `log.debug` may be filtered out. Use `log.warn` or `log.err` to ensure logs appear.

### Direct print (always visible)
```zig
std.debug.print("message with value: {}\n", .{value});
```

### Swift logging
```swift
print("SWIFT: message")
```

Logs appear in the terminal where you launched Ghostty.

## Quick Debug Workflow

1. Build: `zig build`
2. Run from terminal: `./zig-out/Ghostty.app/Contents/MacOS/ghostty`
3. Test in the Ghostty window that opens
4. View logs in the original terminal

**Combined command:**
```bash
zig build && ./zig-out/Ghostty.app/Contents/MacOS/ghostty
```

## Common Debug Scenarios

### Click-to-move not working
- Check if `cursor_click_to_move_input` config is enabled
- Check if cursor is at a prompt (`cursorIsAtPrompt()`)
- Check if `shell_redraws_prompt` flag is set

### Selection issues
- Use Inspector to check cursor position before/after
- Check `semantic_prompt` markers on rows
