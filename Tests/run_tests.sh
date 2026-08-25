#!/bin/sh
#
# Run the host-side unit tests.
#
# These compile production sources directly and run them as command-line
# programs: no Xcode test target, no simulator, no display.
#
# Two kinds of suite:
#
#   Swift  - types with no UIKit or emulator dependency, split out of the views
#            for exactly this reason: TerminalDialect out of EmulatorViewModel,
#            ControlKey out of TerminalUIView.
#   C++    - the shared emulator core, compiled through the symlinks in
#            iOSCPM/Core/. Those resolve into ../romwbw_emu and ../cpmemu, so
#            this is the only check in the repo that what this port actually
#            builds is what it is supposed to build.
#
# Usage:  Tests/run_tests.sh
#
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# xcrun so we get the Xcode toolchain rather than whatever xcode-select points
# at; SDKROOT so Foundation resolves on a machine with only Command Line Tools
# selected.
SWIFTC="xcrun --sdk macosx swiftc -parse-as-library"
CXX="xcrun --sdk macosx c++ -std=c++11 -Wall"

status=0

run_suite() {
    name=$1
    shift
    printf '%s\n' "=== $name ==="
    if $SWIFTC -O -o "$OUT/$name" "$@" 2>&1; then
        "$OUT/$name" || status=1
    else
        echo "FAILED TO COMPILE: $name"
        status=1
    fi
    echo
}

# The core sources this port compiles, named through iOSCPM/Core/ rather than
# through the sibling repos: a flattened symlink or a sibling left on a feature
# branch has to show up here, which it cannot if we reach past them.
CORE_SRCS="
    $ROOT/iOSCPM/Core/hbios_dispatch.cc
    $ROOT/iOSCPM/Core/hbios_cpu.cc
    $ROOT/iOSCPM/Core/emu_init.cc
    $ROOT/iOSCPM/Core/emu_io_common.cc
    $ROOT/iOSCPM/Core/qkz80.cc
    $ROOT/iOSCPM/Core/qkz80_mem.cc
    $ROOT/iOSCPM/Core/qkz80_reg_set.cc
    $ROOT/iOSCPM/Core/qkz80_errors.cc
"

run_core_suite() {
    name=$1
    shift
    printf '%s\n' "=== $name ==="
    if $CXX -O1 -I "$ROOT/iOSCPM/Core" -o "$OUT/$name" "$@" $CORE_SRCS 2>&1; then
        "$OUT/$name" || status=1
    else
        echo "FAILED TO COMPILE: $name"
        status=1
    fi
    echo
}

# The 21 entries under iOSCPM/Core/ are symlinks into ../romwbw_emu/src and
# ../cpmemu/src. They have been flattened into stale copies once already (see
# docs/notes_to_windos.md), and a flattened copy still compiles and still
# passes every test below - it just stops tracking upstream. Check the shape
# before checking the behaviour.
printf '%s\n' "=== CoreSymlinks ==="
# The index is the thing that records the flattening, so this half needs a
# checkout. An exported tree has no index to consult and is not a failure.
if (cd "$ROOT" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    links=$( (cd "$ROOT" && git ls-files -s iOSCPM/Core/ | grep -c '^120000') || true)
    if [ "${links:-0}" -eq 21 ]; then
        echo "PASS: all 21 iOSCPM/Core entries are still symlinks"
    else
        echo "FAIL: expected 21 symlinks under iOSCPM/Core, found ${links:-0}"
        echo "      a flattened copy compiles and passes - and stops tracking upstream"
        status=1
    fi
else
    echo "SKIP: not a git checkout, cannot tell a symlink from a flattened copy"
fi
broken=$(find "$ROOT/iOSCPM/Core" -type l ! -exec test -e {} \; -print 2>/dev/null || true)
if [ -z "$broken" ]; then
    echo "PASS: every symlink resolves to a file that exists"
else
    echo "FAIL: dangling symlinks under iOSCPM/Core:"
    echo "$broken" | sed 's/^/      /'
    status=1
fi
echo

run_suite TerminalDialectTests \
    "$ROOT/iOSCPM/Views/TerminalDialect.swift" \
    "$ROOT/Tests/TerminalDialectTests.swift"

run_suite ControlKeyTests \
    "$ROOT/iOSCPM/Views/ControlKey.swift" \
    "$ROOT/Tests/ControlKeyTests.swift"

run_suite KeyMapTests \
    "$ROOT/iOSCPM/Views/KeyMap.swift" \
    "$ROOT/Tests/KeyMapTests.swift"

run_suite ExportPathTests \
    "$ROOT/iOSCPM/Views/ExportPath.swift" \
    "$ROOT/Tests/ExportPathTests.swift"

run_core_suite CoreKeyboardTests \
    "$ROOT/Tests/CoreKeyboardTests.cc"

if [ "$status" -ne 0 ]; then
    echo "TESTS FAILED"
    exit 1
fi
echo "ALL TESTS PASSED"
