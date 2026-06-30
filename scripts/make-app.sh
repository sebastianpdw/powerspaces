#!/usr/bin/env bash
# Package PowerspacesApp as a proper macOS .app bundle.
#
# Running unbundled (`swift run PowerspacesApp`) gives no real Dock icon: when the
# Preferences window opens, macOS shows the generic executable icon labelled
# "exec". A bundle carries an Info.plist (name "Powerspaces", LSUIElement) and an
# AppIcon.icns, so the Dock shows the proper icon and name.
#
#   ./scripts/make-app.sh        # build Powerspaces.app
#   open ./Powerspaces.app       # run it (menu-bar agent)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
EXEC_NAME="PowerspacesApp"   # SwiftPM build product in .build/release/
APP_NAME="Powerspaces"       # bundle + inner executable name → Powerspaces.app
APP="$ROOT/$APP_NAME.app"

# shellcheck source=scripts/lib-build.sh
. "$ROOT/scripts/lib-build.sh"

# Recover from any earlier `sudo` build that left root-owned files behind, so a
# normal (no-sudo) build can overwrite them instead of failing at link time.
reclaim_build_dir "$ROOT/.build"

echo "› Building release binary…"
swift build -c release --product "$EXEC_NAME"
BIN="$ROOT/.build/release/$EXEC_NAME"

echo "› Building powerspaces CLI (bundled for the Raycast setup)…"
swift build -c release --product powerspaces
CLI_BIN="$ROOT/.build/release/powerspaces"

echo "› Rendering AppIcon.icns…"
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
"$BIN" --export-iconset "$ICONSET"

echo "› Assembling $APP_NAME.app…"
reclaim "$APP"   # rm; falls back to one sudo if a prior build left it root-owned
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$WORK"

# Bundle the powerspaces CLI and the Raycast extension source so the app's
# (experimental) "Set Up Raycast Extension…" can install the CLI and run
# npm install on a writable copy. Exclude build artefacts from the extension.
echo "› Bundling powerspaces CLI + Raycast extension source…"
cp "$CLI_BIN" "$APP/Contents/Resources/powerspaces"
chmod +x "$APP/Contents/Resources/powerspaces"
rsync -a --delete \
    --exclude node_modules --exclude dist --exclude .git --exclude '.DS_Store' \
    "$ROOT/raycast-extension/" "$APP/Contents/Resources/raycast-extension/"

# Bundle the license + third-party notices so they travel with the distributed
# binary, not just the source repo. A user who only gets the .app (via the
# Homebrew cask / GitHub Release) must still receive the GPL-3.0 text (§5(a)/§6)
# and the MIT copyright/permission notice for the adapted InstantSpaceSwitcher
# code compiled in from Sources/CSpaceSwitch (MIT: "included in all copies").
echo "› Bundling license + third-party notices…"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>Powerspaces</string>
    <key>CFBundleDisplayName</key>        <string>Powerspaces</string>
    <key>CFBundleExecutable</key>         <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>         <string>nl.sebastianpdw.powerspaces</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0.0</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
    <!-- Required to send Apple events (the appleScript new-window strategy:
         "make new Finder window", Safari/Terminal "make new …"). Without this key
         macOS can't show the Automation consent prompt and denies events with
         -1743, so scripted new windows silently no-op. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Powerspaces controls apps like Finder, Safari, and Terminal to open a new window on your current desktop.</string>
</dict>
</plist>
PLIST

# Ad-hoc code-sign the finished bundle, inside-out: the nested CLI first, then the
# app itself (which seals Contents/Resources). swift's linker only ad-hoc-signs the
# inner executable; the resources copied in above leave that signature inconsistent,
# so macOS reports "code has no resources but signature indicates they must be
# present" and shows the app as "damaged" — especially after a quarantine round-trip
# (a Homebrew cask download). Ad-hoc ("-") signing is not a Developer ID and is not
# notarized, but it produces a valid, launchable bundle (a downloaded copy still
# needs Gatekeeper cleared once). Developer-ID signing + notarization is the upgrade.
echo "› Ad-hoc code-signing the bundle…"
codesign --force --sign - "$APP/Contents/Resources/powerspaces"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "  ✓ code signature valid"

touch "$APP"   # nudge LaunchServices to notice the new bundle/icon

echo "✓ Built $APP"
echo "  Run it with:  open \"$APP\""
