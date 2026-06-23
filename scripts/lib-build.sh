#!/usr/bin/env bash
# Shared helpers for the build/install scripts. Source it after setting ROOT:
#   . "$ROOT/scripts/lib-build.sh"
#
# Their job is to recover from a build previously done as root — e.g. running the
# *whole* script with `sudo ./scripts/install-app.sh`. That leaves files in
# .build and the Powerspaces.app bundle owned by root, and a later **non-sudo**
# build then can't overwrite them, so the linker fails with:
#   ld: can't write output file: …/.build/…/release/PowerspacesApp
# These helpers delete the stale root-owned leftovers first so the unprivileged
# build can recreate them.

# Delete a path, preferring no sudo. You can delete files inside a directory you
# own even when the files themselves are root-owned, so a plain `rm` clears a
# root-polluted .build with no password. Only when the path *itself* is a
# root-owned directory (e.g. a Powerspaces.app built under sudo) does removal
# genuinely need root — then we fall back to a single sudo and say why.
reclaim() {
    local path="$1"
    [ -e "$path" ] || return 0
    if rm -rf "$path" 2>/dev/null; then
        return 0
    fi
    echo "  • $path is owned by another user (left by an earlier 'sudo' build)."
    echo "    Removing it once so future builds need no sudo — you may be asked for your password."
    sudo rm -rf "$path"
}

# Clear the SwiftPM build dir, but only when BOTH are true:
#   1. we're running non-sudo (as root you can overwrite root-owned files
#      directly, so there's nothing to clean up — and running this as root would
#      wrongly flag the regular user's files as "foreign" and wipe a good cache); and
#   2. it actually contains files owned by someone else (left by an earlier
#      `sudo` build), so a healthy user-owned cache is never touched.
# Otherwise there's nothing to delete.
reclaim_build_dir() {
    local build="$1"
    [ -d "$build" ] || return 0
    [ "$(id -u)" -eq 0 ] && return 0   # running as root → nothing to reclaim
    local foreign
    foreign="$(find "$build" ! -user "$(id -un)" -print -quit 2>/dev/null || true)"
    if [ -n "$foreign" ]; then
        echo "› Clearing build files left root-owned by an earlier 'sudo' build so this no-sudo build can proceed…"
        reclaim "$build"
    fi
}
