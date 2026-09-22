#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_MODE="${HELIARC_BUILD_MODE:-debug}"
APP_DIR="$ROOT_DIR/dist/Heliarc.app"
INSTALL_DIR="/Applications/Heliarc.app"
IDENTITY="${HELIARC_SIGNING_IDENTITY:-Developer ID Application: Robin Obermaier (5S5288W3R7)}"
VERSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT_DIR/release.json")"
BUILD="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"])' "$ROOT_DIR/release.json")"

case "${1:-run}" in
  --logs)
    /usr/bin/log stream --style compact --predicate 'process == "Heliarc"'
    exit 0
    ;;
  --telemetry)
    /usr/bin/log stream --style compact --level debug --predicate 'subsystem == "build.robin.heliarc"'
    exit 0
    ;;
  --verify)
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALL_DIR"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$INSTALL_DIR" || true
    /usr/bin/codesign -d --entitlements :- "$INSTALL_DIR" 2>/dev/null
    exit 0
    ;;
esac

swift build --package-path "$ROOT_DIR" --configuration "$BUILD_MODE"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --configuration "$BUILD_MODE" --show-bin-path)"

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
/bin/cp "$BIN_DIR/Heliarc" "$APP_DIR/Contents/MacOS/Heliarc"
ICON_PARTIAL_PLIST="$APP_DIR/Contents/icon-partial.plist"
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" /usr/bin/xcrun actool "$ROOT_DIR/Resources/HeliarcIcon.icon" \
  --compile "$APP_DIR/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon HeliarcIcon \
  --output-partial-info-plist "$ICON_PARTIAL_PLIST" \
  --warnings \
  --notices >/dev/null
/bin/rm "$ICON_PARTIAL_PLIST"
/bin/cp "$ROOT_DIR/Resources/HeliarcIcon.png" "$APP_DIR/Contents/Resources/HeliarcIcon.png"
/bin/cp "$ROOT_DIR/Resources/HeliarcLogo.png" "$APP_DIR/Contents/Resources/HeliarcLogo.png"
/bin/cp "$ROOT_DIR/Resources/MenuBarIcon@2x.png" "$APP_DIR/Contents/Resources/MenuBarIcon@2x.png"
/usr/bin/plutil -create xml1 "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string Heliarc "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string build.robin.heliarc "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleName -string Heliarc "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleDisplayName -string Heliarc "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIconFile -string HeliarcIcon "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIconName -string HeliarcIcon "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$VERSION" "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "$BUILD" "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 14.0 "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -insert LSUIElement -bool true "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -insert NSAppleEventsUsageDescription -string 'Heliarc tracks the active Helium tab for recent-tab ordering and activates tabs when you use Ctrl-Tab.' "$APP_DIR/Contents/Info.plist"
/usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" --entitlements "$ROOT_DIR/entitlements.plist" "$APP_DIR"

if [[ "${1:-run}" == "--build" ]]; then
  echo "$APP_DIR"
  exit 0
fi

/usr/bin/pkill -x Heliarc 2>/dev/null || true
/bin/rm -rf "$INSTALL_DIR"
/bin/cp -R "$APP_DIR" "$INSTALL_DIR"
/usr/bin/open "$INSTALL_DIR"
echo "Installed and launched $INSTALL_DIR"
