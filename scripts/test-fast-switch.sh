#!/bin/bash
# Exercise real event construction and engine failure paths with a fake host.
# Never posts desktop events, changes shortcuts, or writes real preferences.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/.build/tmp"
test_dir="$(mktemp -d "$repo_dir/.build/tmp/fast-switch.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
export TMPDIR="$test_dir"   # compiler scratch files stay inside the repo too
sanitizers=()
if [ "${PSW_TEST_SANITIZERS:-0}" = 1 ]; then
    sanitizers=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
clang -std=gnu17 -Wall -Wextra -Werror -g \
    ${sanitizers[@]+"${sanitizers[@]}"} \
    "$repo_dir/scripts/fast-switch-tests/main.c" \
    "$repo_dir/Sources/CSpaceSwitch/SpaceSwitchPolicy.c" \
    -framework ApplicationServices -framework CoreFoundation -o "$test_dir/tests"
"$test_dir/tests" "$@"
