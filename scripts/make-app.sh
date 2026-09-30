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

# Single source of truth for the marketing version: the VERSION file at the repo
# root, overridable with the VERSION env var (the release script / CI export it).
# Replaces a hardcoded string that drifted from the released git tag + Homebrew cask.
VERSION="${VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)}"

# shellcheck source=scripts/lib-build.sh
. "$ROOT/scripts/lib-build.sh"

# Recover from any earlier `sudo` build that left root-owned files behind, so a
# normal (no-sudo) build can overwrite them instead of failing at link time.
reclaim_build_dir "$ROOT/.build"

# Swift Build in Xcode 27 can stamp the deployment target as the SDK version.
# Keep the established backend for packaged apps, with the platform's SwiftUI
# macro plugin available when building against the new SDK. With only the Command
# Line Tools installed xcrun has no platform path: then there is no plugin path.
PSW_BUILD_ARGS=(--build-system native)
PSW_SDK_PLATFORM="$(xcrun --show-sdk-platform-path 2>/dev/null || true)"
if [ -d "$PSW_SDK_PLATFORM/Developer/usr/lib/swift/host/plugins" ]; then
    PSW_BUILD_ARGS+=(-Xswiftc -plugin-path -Xswiftc "$PSW_SDK_PLATFORM/Developer/usr/lib/swift/host/plugins")
fi

echo "› Building release binary…"
swift build "${PSW_BUILD_ARGS[@]}" -c release --product "$EXEC_NAME"
BIN="$ROOT/.build/release/$EXEC_NAME"

echo "› Building powerspaces CLI (bundled for the Raycast setup)…"
swift build "${PSW_BUILD_ARGS[@]}" -c release --product powerspaces
CLI_BIN="$ROOT/.build/release/powerspaces"

echo "› Rendering AppIcon.icns…"
mkdir -p "$ROOT/.build/tmp"
WORK="$(mktemp -d "$ROOT/.build/tmp/iconset.XXXXXX")"
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
# In a git checkout only tracked files are copied, so a local file that happens to
# sit in the folder (an .env, notes) never ships inside the app.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" ls-files -z -- raycast-extension \
        | rsync -a --from0 --files-from=- "$ROOT/" "$APP/Contents/Resources/"
else
    rsync -a --delete \
        --exclude node_modules --exclude dist --exclude .git --exclude '.DS_Store' --exclude '.env*' \
        "$ROOT/raycast-extension/" "$APP/Contents/Resources/raycast-extension/"
fi

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
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
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

# Strip the debug map before signing so the distributed binaries don't embed the
# build machine's absolute object-file paths. The linker records each .o path (e.g.
# /Users/<name>/…/.build/…/AppDelegate.swift.o) in the debug map, which leaks the
# builder's macOS username and local directory layout to anyone who downloads the
# app. `strip -S` removes those debug symbols (verified: clears every embedded path);
# it must run BEFORE code-signing, since stripping a signed binary voids its signature.
echo "› Stripping debug symbols (removes embedded build paths)…"
strip -S "$APP/Contents/MacOS/$APP_NAME"
strip -S "$APP/Contents/Resources/powerspaces"

# The app declares macOS 14 as its minimum. A toolchain that stamps the SDK version
# instead builds a binary that older systems refuse to launch, and the machine that
# built it would not notice.
echo "› Checking the minimum macOS version of both binaries…"
for built in "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/Resources/powerspaces"; do
    minos="$(vtool -show-build "$built" | awk '$1 == "minos" { print $2; exit }')"
    if [ "$minos" != "14.0" ]; then
        echo "✗ $built needs macOS ${minos:-unknown}, expected 14.0" >&2
        exit 1
    fi
done

# Code-sign the finished bundle, inside-out: the nested CLI first, then the
# app itself (which seals Contents/Resources). swift's linker only ad-hoc-signs the
# inner executable; the resources copied in above leave that signature inconsistent,
# so macOS reports "code has no resources but signature indicates they must be
# present" and shows the app as "damaged" — especially after a quarantine round-trip
# (a Homebrew cask download). Ad-hoc ("-") signing is not a Developer ID and is not
# notarized, but it produces a valid, launchable bundle (a downloaded copy still
# needs Gatekeeper cleared once). Developer-ID signing + notarization is the upgrade.
#
# Ad hoc is the default, and it identifies the app by its binary hash: every rebuild
# is a new app to macOS, which asks again for the permissions you granted
# (Accessibility, Automation). Set SIGN_IDENTITY to a certificate identity to keep
# them across rebuilds; list yours with: security find-identity -v -p codesigning
#
# No secure timestamp: with a certificate codesign asks Apple's timestamp server by
# default, and a local build then fails whenever that server does not answer. A
# release build is signed again with a timestamp, which notarization requires.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "› Code-signing the bundle…"
codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/powerspaces"
codesign --force --deep --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"   # on its own line, so a bad signature stops the build
echo "  ✓ code signature valid"

touch "$APP"   # nudge LaunchServices to notice the new bundle/icon

echo "✓ Built $APP"
echo "  Run it with:  open \"$APP\""
if [ "$SIGN_IDENTITY" = - ]; then
    echo "  Ad-hoc signed: macOS asks for the app's permissions again after every rebuild."
    echo "  To keep them, set SIGN_IDENTITY (list: security find-identity -v -p codesigning)."
fi
