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

BUILD_UNIVERSAL_DMG="${BUILD_UNIVERSAL_DMG:-1}"
BUILD_ARM_DMG="${BUILD_ARM_DMG:-1}"
BUILD_ZIP="${BUILD_ZIP:-0}"
BUILD_PKG="${BUILD_PKG:-0}"
ARM_TARGET="${ARM_TARGET:-aarch64-macos}"

require_cmd awk
require_cmd codesign
require_cmd ditto
require_cmd file
require_cmd gh
require_cmd git
require_cmd xcrun
require_cmd zig

if [[ "$BUILD_UNIVERSAL_DMG" -eq 1 || "$BUILD_ARM_DMG" -eq 1 ]]; then
  if ! command -v create-dmg >/dev/null 2>&1; then
    echo "Missing required command: create-dmg (install via: npm install --global create-dmg) or set BUILD_UNIVERSAL_DMG=0 BUILD_ARM_DMG=0" >&2
    exit 1
  fi
fi

if [[ "$BUILD_UNIVERSAL_DMG" -eq 0 && "$BUILD_ARM_DMG" -eq 0 && "$BUILD_ZIP" -eq 0 && "$BUILD_PKG" -eq 0 ]]; then
  echo "Nothing to build. Enable BUILD_UNIVERSAL_DMG, BUILD_ARM_DMG, BUILD_ZIP, or BUILD_PKG." >&2
  exit 1
fi

require_env APPLE_ID
require_env TEAM_ID
require_env APP_CERT
require_env APP_SPECIFIC_PASSWORD
require_env GITHUB_USER

if [[ "$BUILD_PKG" -eq 1 ]]; then
  require_env INSTALLER_CERT
  require_cmd productbuild
fi

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

VERSION="$(awk -F '"' '/^[[:space:]]*\.version[[:space:]]*=/ {print $2; exit}' "$ROOT/build.zig.zon")"
if [[ -z "$VERSION" ]]; then
  echo "Failed to read version from build.zig.zon" >&2
  exit 1
fi

TAG="v${VERSION}"
ARTIFACT_DIR="${ROOT}/ai/output"
APP_PATH="${ROOT}/zig-out/Ghostty.app"
ENTITLEMENTS="${ROOT}/macos/GhosttyReleaseLocal.entitlements"

SUBMIT_ZIP_UNIVERSAL="${ARTIFACT_DIR}/Ghostty-${VERSION}-macos-universal.notarize.zip"
FINAL_ZIP_UNIVERSAL="${ARTIFACT_DIR}/Ghostty-${VERSION}-macos-universal.zip"
DMG_UNIVERSAL="${ARTIFACT_DIR}/Ghostty-${VERSION}-macos-universal.dmg"

SUBMIT_ZIP_ARM="${ARTIFACT_DIR}/Ghostty-${VERSION}-macos-arm64.notarize.zip"
FINAL_ZIP_ARM="${ARTIFACT_DIR}/Ghostty-${VERSION}-macos-arm64.zip"
DMG_ARM="${ARTIFACT_DIR}/Ghostty-${VERSION}-macos-arm64.dmg"

PKG_PATH="${ARTIFACT_DIR}/Ghostty-${VERSION}.pkg"

mkdir -p "$ARTIFACT_DIR"

sign_item() {
  /usr/bin/codesign --force --options runtime --timestamp --sign "$APP_CERT" "$1"
}

sign_app() {
  local app_path="$1"
  local framework_dir="${app_path}/Contents/Frameworks"

  while IFS= read -r -d '' dylib; do
    sign_item "$dylib"
  done < <(find "$app_path/Contents" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 || true)

  while IFS= read -r -d '' exe; do
    if file -b "$exe" | grep -q "Mach-O"; then
      sign_item "$exe"
    fi
  done < <(find "$app_path/Contents" -type f -perm -111 -print0 || true)

  while IFS= read -r -d '' helper; do
    sign_item "$helper"
  done < <(find "$app_path/Contents" -type d \( -name "*.app" -o -name "*.xpc" \) -print0 || true)

  if [[ -d "$framework_dir" ]]; then
    while IFS= read -r -d '' framework; do
      sign_item "$framework"
    done < <(find "$framework_dir" -type d -name "*.framework" -print0)
  fi

  /usr/bin/codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$APP_CERT" \
    "$app_path"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
}

notarize_app() {
  local app_path="$1"
  local submit_zip="$2"

  rm -f "$submit_zip"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submit_zip"

  xcrun notarytool submit "$submit_zip" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait

  xcrun stapler staple "$app_path"
}

create_zip() {
  local app_path="$1"
  local zip_path="$2"

  rm -f "$zip_path"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
}

create_dmg() {
  local app_path="$1"
  local dmg_path="$2"
  local stage_dir

  stage_dir="$(mktemp -d "${ARTIFACT_DIR}/dmg.XXXXXX")"
  create-dmg --identity="$APP_CERT" "$app_path" "$stage_dir"

  local dmg_source
  dmg_source="$(ls -1t "$stage_dir"/Ghostty*.dmg | head -n 1)"
  if [[ -z "$dmg_source" ]]; then
    echo "Failed to find DMG output in $stage_dir" >&2
    rm -rf "$stage_dir"
    exit 1
  fi

  mv "$dmg_source" "$dmg_path"
  rm -rf "$stage_dir"

  xcrun notarytool submit "$dmg_path" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait

  xcrun stapler staple "$dmg_path"
}

build_pkg() {
  local app_path="$1"
  local pkg_path="$2"

  rm -f "$pkg_path"
  productbuild --component "$app_path" /Applications --sign "$INSTALLER_CERT" "$pkg_path"

  xcrun notarytool submit "$pkg_path" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait

  xcrun stapler staple "$pkg_path"
}

release_assets=()

if [[ "$BUILD_UNIVERSAL_DMG" -eq 1 || "$BUILD_ZIP" -eq 1 || "$BUILD_PKG" -eq 1 ]]; then
  zig build -Doptimize=ReleaseFast -Dxcframework-target=universal

  if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found at $APP_PATH" >&2
    exit 1
  fi

  sign_app "$APP_PATH"
  notarize_app "$APP_PATH" "$SUBMIT_ZIP_UNIVERSAL"

  if [[ "$BUILD_ZIP" -eq 1 ]]; then
    create_zip "$APP_PATH" "$FINAL_ZIP_UNIVERSAL"
    release_assets+=("$FINAL_ZIP_UNIVERSAL")
  fi

  if [[ "$BUILD_UNIVERSAL_DMG" -eq 1 ]]; then
    create_dmg "$APP_PATH" "$DMG_UNIVERSAL"
    release_assets+=("$DMG_UNIVERSAL")
  fi

  if [[ "$BUILD_PKG" -eq 1 ]]; then
    build_pkg "$APP_PATH" "$PKG_PATH"
    release_assets+=("$PKG_PATH")
  fi
fi

if [[ "$BUILD_ARM_DMG" -eq 1 ]]; then
  zig build -Doptimize=ReleaseFast -Dxcframework-target=native -Dtarget="$ARM_TARGET"

  if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found at $APP_PATH" >&2
    exit 1
  fi

  sign_app "$APP_PATH"
  notarize_app "$APP_PATH" "$SUBMIT_ZIP_ARM"

  create_dmg "$APP_PATH" "$DMG_ARM"
  release_assets+=("$DMG_ARM")

  if [[ "$BUILD_ZIP" -eq 1 ]]; then
    create_zip "$APP_PATH" "$FINAL_ZIP_ARM"
    release_assets+=("$FINAL_ZIP_ARM")
  fi
fi

if [[ ${#release_assets[@]} -eq 0 ]]; then
  echo "No release assets were created." >&2
  exit 1
fi

if gh release view "$TAG" --repo "$GITHUB_USER/$GITHUB_REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "${release_assets[@]}" --repo "$GITHUB_USER/$GITHUB_REPO" --clobber
else
  gh release create "$TAG" "${release_assets[@]}" \
    --repo "$GITHUB_USER/$GITHUB_REPO" \
    --title "$TAG" \
    --generate-notes
fi

echo "Release assets ready:"
if [[ -f "$DMG_UNIVERSAL" ]]; then
  echo "  DMG (universal): $DMG_UNIVERSAL"
fi
if [[ -f "$DMG_ARM" ]]; then
  echo "  DMG (arm64): $DMG_ARM"
fi
if [[ -f "$FINAL_ZIP_UNIVERSAL" ]]; then
  echo "  Zip (universal): $FINAL_ZIP_UNIVERSAL"
fi
if [[ -f "$FINAL_ZIP_ARM" ]]; then
  echo "  Zip (arm64): $FINAL_ZIP_ARM"
fi
if [[ -f "$PKG_PATH" ]]; then
  echo "  PKG: $PKG_PATH"
fi

echo "Open app:"
echo "  open \"$APP_PATH\""
