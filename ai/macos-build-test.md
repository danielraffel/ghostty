# macOS Build & Test (Ghostty)

This is a quick, local guide for building and testing Ghostty on macOS using the repo’s supported workflow. It follows `AGENTS.md` and `HACKING.md`.

The helper script writes a log to `ai/output/macos-build-test-<timestamp>.log`, the app bundle is created at `.zig-cache/xcodebuild/Build/Products/<config>/Ghostty.app`, and Xcode output is stored under `.zig-cache/xcodebuild` (sandbox-friendly).

## Prerequisites

- Zig installed and available in `PATH`.
- Xcode 26 + macOS 26 SDK (per `HACKING.md`).
  - If builds fail due to SDK mismatch, check your active Xcode path with `xcode-select -p`.
  - If needed, update the active Xcode selection (see `HACKING.md` for details).

macOS users do not require additional dependencies beyond Xcode + SDK (`HACKING.md`).

## Build (macOS app + core)

From repo root:

```sh
zig build
```

### Scripted build/test

You can also use the convenience script:

```sh
ai/scripts/macos-build-test.sh
```

Options:

```sh
ai/scripts/macos-build-test.sh --run
ai/scripts/macos-build-test.sh --no-test
ai/scripts/macos-build-test.sh --test-filter "<test name>"
ai/scripts/macos-build-test.sh --lib-vt
```

## Run the macOS app

```sh
zig build run
```

> Per `AGENTS.md`, do **not** use `xcodebuild` to build or run the macOS app.

## Tests (Zig)

```sh
zig build test
```

Filter a test by name:

```sh
zig build test -Dtest-filter="<test name>"
```

## Optional: libghostty-vt only

If you’re only working on `libghostty-vt`, avoid building the full app:

```sh
zig build lib-vt
zig build test-lib-vt
```

## Formatting

```sh
zig fmt .
```

## References

- `AGENTS.md` for command policy and macOS app constraints.
- `HACKING.md` for Xcode/SDK requirements and troubleshooting.
