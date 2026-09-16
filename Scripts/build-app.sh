#!/bin/bash
# Builds Bud.app from the SwiftPM executable.
#
# There is no .xcodeproj: this machine has only the Command Line Tools, so the
# bundle is assembled by hand. That is also why the bundle is ad-hoc signed —
# it is a locally-built app, not a distributed one.
#
# This script is the only thing that writes Info.plist, so --version/--build
# stamp CFBundleShortVersionString and CFBundleVersion right here. The updater
# decides whether to offer an update by comparing those values against the
# signed appcast, so they are release-critical and must not be patched into the
# bundle afterwards — a second writer would leave the plist and the ad-hoc
# signature describing different builds. Defaults keep the historical
# no-argument behaviour intact.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="release"
APP_NAME="Bud"
BUNDLE_ID="com.bud.assistant"
VERSION="0.0.1"
# An integer, because the build number is what orders two releases and an
# updater that cannot order them cannot refuse a downgrade. It used to mirror
# VERSION, which meant the default bundle declared "1.0.0" where every consumer
# of a build number expects a monotonic integer — including this app's own
# updater, which would have refused every update as unreadable.
BUILD_NUMBER="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ $# -lt 2 ]]; then
        echo "error: --version needs a value" >&2
        exit 1
      fi
      VERSION="$2"
      shift 2
      ;;
    --build)
      if [[ $# -lt 2 ]]; then
        echo "error: --build needs a value" >&2
        exit 1
      fi
      BUILD_NUMBER="$2"
      shift 2
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      exit 1
      ;;
    *)
      CONFIG="$1"
      shift
      ;;
  esac
done

# A malformed stamp ships a bundle that can never be updated, so reject it
# before paying for a build.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be X.Y.Z (got: $VERSION)" >&2
  exit 1
fi
# Integers only. A dotted build number sorts lexically, so "1.10" would be read
# as older than "1.9" and the updater would offer a downgrade.
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "error: build must be an integer (got: $BUILD_NUMBER)" >&2
  exit 1
fi

cd "$ROOT"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "error: executable not found at $BIN" >&2
  exit 1
fi

APP="$ROOT/build/$APP_NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# The Services entry is declared here rather than registered in code: a Services
# menu is built from this list, and the message name is the selector the app has
# to answer. `NSPortName` has to be the app's own name, because that is the port
# Services uses to reach a running copy of Bud.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.bud.assistant.url</string>
            <key>CFBundleURLSchemes</key><array><string>bud</string></array>
            <key>CFBundleTypeRole</key><string>Viewer</string>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key><string>Ask Bud about this</string>
            </dict>
            <key>NSMessage</key><string>askBud</string>
            <key>NSPortName</key><string>$APP_NAME</string>
            <key>NSSendTypes</key>
            <array>
                <string>public.utf8-plain-text</string>
                <string>NSStringPboardType</string>
            </array>
        </dict>
    </array>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>Bud — a native macOS assistant.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Required for the app to run at all on Apple Silicon, and it
# keeps the hotkey and network entitlements consistent across rebuilds.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "==> Done: $APP"
