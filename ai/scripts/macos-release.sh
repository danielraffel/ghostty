#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT}/ai/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

cd "$ROOT"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: $name" >&2
    exit 1
  fi
}

require_cmd awk
require_cmd codesign
require_cmd ditto
require_cmd gh
require_cmd git
require_cmd xcrun
require_cmd zig

require_env APPLE_ID
require_env TEAM_ID
require_env APP_CERT
require_env APP_SPECIFIC_PASSWORD
require_env GITHUB_USER

GITHUB_REPO="${GITHUB_REPO:-ghostty}"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Working tree has uncommitted changes in tracked files." >&2
  exit 1
fi

if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  ahead="$(git rev-list --left-right --count @{u}...HEAD | awk '{print $2}')"
  if [[ "${ahead:-0}" -gt 0 ]]; then
    if [[ "${PUSH_RELEASE:-0}" -eq 1 ]]; then
      git push
    else
      echo "Local branch is ahead of remote. Set PUSH_RELEASE=1 to push." >&2
      exit 1
    fi
  fi
fi

VERSION="$(awk -F '\"' '/^[[:space:]]*\.version[[:space:]]*=/ {print $2; exit}' "$ROOT/build.zig.zon")"
if [[ -z "$VERSION" ]]; then
  echo "Failed to read version from build.zig.zon" >&2
  exit 1
fi

TAG="v${VERSION}"
ARTIFACT_DIR="${ROOT}/ai/output"
APP_PATH="${ROOT}/zig-out/Ghostty.app"
ENTITLEMENTS="${ROOT}/macos/GhosttyReleaseLocal.entitlements"
SUBMIT_ZIP="${ARTIFACT_DIR}/Ghostty-${VERSION}-macos-universal.notarize.zip"
FINAL_ZIP="${ARTIFACT_DIR}/Ghostty-${VERSION}-macos-universal.zip"

mkdir -p "$ARTIFACT_DIR"

zig build -Doptimize=ReleaseFast

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH" >&2
  exit 1
fi

sign_item() {
  /usr/bin/codesign --force --options runtime --timestamp --sign "$APP_CERT" "$1"
}

FRAMEWORK_DIR="${APP_PATH}/Contents/Frameworks"

while IFS= read -r -d '' dylib; do
  sign_item "$dylib"
done < <(find "$APP_PATH/Contents" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 || true)

while IFS= read -r -d '' helper; do
  sign_item "$helper"
done < <(find "$APP_PATH/Contents" -type d \( -name "*.app" -o -name "*.xpc" \) -print0 || true)

if [[ -d "$FRAMEWORK_DIR" ]]; then
  while IFS= read -r -d '' framework; do
    sign_item "$framework"
  done < <(find "$FRAMEWORK_DIR" -type d -name "*.framework" -print0)
fi

/usr/bin/codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$APP_CERT" \
  "$APP_PATH"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

rm -f "$SUBMIT_ZIP" "$FINAL_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$SUBMIT_ZIP"

xcrun notarytool submit "$SUBMIT_ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --wait

xcrun stapler staple "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$FINAL_ZIP"

PKG_PATH=""
if [[ -n "${INSTALLER_CERT:-}" ]]; then
  require_cmd productbuild
  PKG_PATH="${ARTIFACT_DIR}/Ghostty-${VERSION}.pkg"
  rm -f "$PKG_PATH"
  productbuild --component "$APP_PATH" /Applications --sign "$INSTALLER_CERT" "$PKG_PATH"

  xcrun notarytool submit "$PKG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait

  xcrun stapler staple "$PKG_PATH"
fi

if gh release view "$TAG" --repo "$GITHUB_USER/$GITHUB_REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$FINAL_ZIP" --repo "$GITHUB_USER/$GITHUB_REPO" --clobber
  if [[ -n "$PKG_PATH" ]]; then
    gh release upload "$TAG" "$PKG_PATH" --repo "$GITHUB_USER/$GITHUB_REPO" --clobber
  fi
else
  if [[ -n "$PKG_PATH" ]]; then
    gh release create "$TAG" "$FINAL_ZIP" "$PKG_PATH" \
      --repo "$GITHUB_USER/$GITHUB_REPO" \
      --title "$TAG" \
      --generate-notes
  else
    gh release create "$TAG" "$FINAL_ZIP" \
      --repo "$GITHUB_USER/$GITHUB_REPO" \
      --title "$TAG" \
      --generate-notes
  fi
fi

echo "Release asset ready: $FINAL_ZIP"
