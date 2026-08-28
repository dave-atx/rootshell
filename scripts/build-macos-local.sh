#!/bin/bash
#
# Build, ad-hoc sign and install rootshell for local macOS development.
#
# Why this exists rather than a plain `xcodebuild`: this project is wired to
# upstream team D97ZME3ET2 and to entitlements (iCloud container, app group,
# keychain group, push, associated domains) that a free Apple ID cannot
# provision. Signing with them ad-hoc gets the process SIGKILLed by the
# kernel; signing without them is fine, because the code probes for what it
# actually has at runtime. See docs/macos-local-dev.md for the full account.
#
# Usage:  scripts/build-macos-local.sh [--run] [--clean]
#
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"

SCHEME="rootshell-Standalone"
CONFIG="DebugStandalone"
DERIVED="$REPO/.derivedData/mac"
ENTITLEMENTS="$REPO/Configuration/LocalDev.entitlements"
PRODUCT="$DERIVED/Build/Products/$CONFIG-maccatalyst/rootshell.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED="$INSTALL_DIR/rootshell.app"

RUN=0
for arg in "$@"; do
  case "$arg" in
    --run)   RUN=1 ;;
    --clean) echo "==> removing $DERIVED"; rm -rf "$DERIVED" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[ -f "$ENTITLEMENTS" ] || { echo "missing $ENTITLEMENTS" >&2; exit 1; }

echo "==> building $SCHEME / $CONFIG (Mac Catalyst)"
# CODE_SIGNING_ALLOWED=NO: let xcodebuild skip signing entirely, so its
#   provisioning check never runs. All signing happens below, which also
#   avoids having to override CODE_SIGN_ENTITLEMENTS per target.
# ENABLE_DEBUG_DYLIB=NO: without this Xcode emits a launcher stub plus a
#   separate .debug.dylib and the resulting bundle is linker-signed with no
#   sealed resources -- it looks built but is not a runnable app.
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_DEBUG_DYLIB=NO \
  build

[ -d "$PRODUCT" ] || { echo "build produced no app at $PRODUCT" >&2; exit 1; }

echo "==> ad-hoc signing (inside out)"
# Order matters: nested code must be sealed before whatever contains it.
find "$PRODUCT/Contents/Frameworks" -name '*.dylib' -print0 2>/dev/null \
  | xargs -0 -r -I{} codesign --force --sign - --timestamp=none {}
for f in "$PRODUCT"/Contents/Frameworks/*.framework; do
  [ -e "$f" ] || continue
  codesign --force --sign - --timestamp=none --deep "$f"
done
for p in "$PRODUCT"/Contents/PlugIns/*; do
  [ -e "$p" ] || continue
  codesign --force --sign - --timestamp=none "$p"
done
for h in "$PRODUCT"/Contents/Helpers/*.app; do
  [ -e "$h" ] || continue
  codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$h"
done
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$PRODUCT"

echo "==> verifying signature"
codesign --verify --deep --strict "$PRODUCT"

echo "==> installing to $INSTALLED"
# LaunchServices will not open a bundle from inside the dot-directory
# .derivedData, so the app is copied out before it can be launched normally.
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED"
ditto "$PRODUCT" "$INSTALLED"

echo "==> done: $INSTALLED"
if [ "$RUN" -eq 1 ]; then
  echo "==> launching"
  open -n "$INSTALLED"
fi
