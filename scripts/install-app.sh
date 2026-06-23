#!/usr/bin/env bash
# Build Powerspaces.app and install it into your Applications folder.
#
# Builds the bundle with make-app.sh, then `ditto`s it into place (ditto is the
# Apple-recommended copy for app bundles — it preserves bundle metadata, where
# `cp -R` can leave an app flagged "damaged"). Defaults to the system
# /Applications (writable by admins; falls back to sudo). Override with APP_DEST.
#
#   ./scripts/install-app.sh                                # → /Applications
#   APP_DEST="$HOME/Applications" ./scripts/install-app.sh  # → per-user, no sudo
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
APP_NAME="Powerspaces.app"
SRC="$ROOT/$APP_NAME"
APP_DEST="${APP_DEST:-/Applications}"
DEST="$APP_DEST/$APP_NAME"

# shellcheck source=scripts/lib-build.sh
. "$ROOT/scripts/lib-build.sh"

echo "=== Building $APP_NAME ==="
"$DIR/make-app.sh"

echo
echo "› Installing $APP_NAME → $DEST"
# Remove any existing install first. reclaim does this with no sudo when it can
# (a user-owned bundle in a writable folder); it falls back to a single sudo only
# when a previous `sudo` install left the bundle owned by root. After that the
# fresh copy below is user-owned, so future installs need no sudo at all.
reclaim "$DEST"
if [ -w "$APP_DEST" ] || { [ ! -e "$APP_DEST" ] && [ -w "$(dirname "$APP_DEST")" ]; }; then
    mkdir -p "$APP_DEST"
    ditto "$SRC" "$DEST"
else
    echo "  ($APP_DEST isn't writable — using sudo for the copy; you may be prompted for your password)"
    echo "  Tip: for a fully no-sudo install, target your personal folder instead:"
    echo "       APP_DEST=\"\$HOME/Applications\" ./scripts/install-app.sh"
    echo "  (Avoid running this whole script with sudo — that builds as root and leaves"
    echo "   root-owned files behind that break later no-sudo runs.)"
    sudo mkdir -p "$APP_DEST"
    sudo ditto "$SRC" "$DEST"
fi

# Nudge LaunchServices so the icon/name appear in Spotlight / Raycast / Launchpad.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST" 2>/dev/null || true

echo
echo "✓ Powerspaces.app installed at:"
echo "    $DEST"
case "$DEST" in
    "$HOME"/*) echo "  (a per-user install in your home folder — no admin needed)." ;;
    *)         echo "  (the system Applications folder — shared by all users)." ;;
esac
echo "  Launch it with:  open \"$DEST\""
