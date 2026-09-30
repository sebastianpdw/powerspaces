#!/bin/bash
# Compile the real GUI source with a separate entry point: no normal app startup.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir="${1:-$repo_dir/.build}"
build_dir="$scratch_dir/arm64-apple-macosx/debug"
if [ ! -d "$build_dir/Modules" ]; then
    build_dir="$scratch_dir/x86_64-apple-macosx/debug"
fi
if [ -d "$build_dir/Modules" ]; then
    module_args=(-I "$build_dir/Modules" -I "$build_dir/CSpaceSwitch.build")
    # Link the objects of today's sources only: a deleted file leaves its object behind.
    objects=()
    for source in "$repo_dir"/Sources/SpaceKit/*.swift "$repo_dir"/Sources/CSpaceSwitch/*.c; do
        objects+=("$build_dir/$(basename "$(dirname "$source")").build/$(basename "$source").o")
    done
elif [ -d "$scratch_dir/out/Products/Debug/SpaceKit.swiftmodule" ]; then
    # Xcode 27's Swift Build backend uses product-level modules and merged objects.
    build_dir="$scratch_dir/out/Products/Debug"
    module_args=(-I "$build_dir" -Xcc "-fmodule-map-file=$scratch_dir/out/Intermediates.noindex/GeneratedModuleMaps/CSpaceSwitch.modulemap")
    objects=("$build_dir/SpaceKit.o" "$build_dir/CSpaceSwitch.o")
else
    echo "No debug build in $scratch_dir. Run 'swift build' in $repo_dir first," >&2
    echo "or pass the scratch directory of an existing build as the first argument." >&2
    exit 1
fi
plugin_args=()
sdk_platform="$(xcrun --show-sdk-platform-path 2>/dev/null || true)"
if [ -d "$sdk_platform/Developer/usr/lib/swift/host/plugins" ]; then
    plugin_args=(-plugin-path "$sdk_platform/Developer/usr/lib/swift/host/plugins")
fi
mkdir -p "$repo_dir/.build/tmp"
test_dir="$(mktemp -d "$repo_dir/.build/tmp/ui-lifetime.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
export TMPDIR="$test_dir"   # compiler scratch files stay inside the repo too
gui_sources=()
for source in "$repo_dir"/Sources/PowerspacesApp/*.swift; do
    case "$source" in */main.swift) ;; *) gui_sources+=("$source") ;; esac
done
swiftc -whole-module-optimization -Onone -swift-version 5 -enable-upcoming-feature StrictConcurrency \
    -module-name PowerspacesUILifetimeTests -module-cache-path "$test_dir/module-cache" \
    "${module_args[@]}" ${plugin_args[@]+"${plugin_args[@]}"} \
    "${gui_sources[@]}" "$repo_dir"/scripts/ui-lifetime-tests/*.swift \
    "${objects[@]}" \
    -framework AppKit -framework ApplicationServices -o "$test_dir/ui-lifetime-tests"
"$test_dir/ui-lifetime-tests"
