#!/bin/sh
#
# Run the host-side unit tests.
#
# These compile production sources directly with swiftc and run them as a
# command-line program: no Xcode test target, no simulator, no display. That
# only works for types with no UIKit or emulator dependency - today that is
# TerminalDialect, split out of EmulatorViewModel for exactly this reason.
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

run_suite TerminalDialectTests \
    "$ROOT/iOSCPM/Views/TerminalDialect.swift" \
    "$ROOT/Tests/TerminalDialectTests.swift"

if [ "$status" -ne 0 ]; then
    echo "TESTS FAILED"
    exit 1
fi
echo "ALL TESTS PASSED"
