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
#
# Off a Mac there is no xcrun, and the two halves fare differently. The Swift
# suites need Foundation and are skipped. The C++ suite does not: it compiles
# the same symlinked core with any C++11 compiler, and it is the only check in
# the repo that notices when an upstream core sync adds a backend function this
# port has not defined yet - which has happened (see the CHANGELOG entry for
# emu_host_file_get_read_name). Losing that check on every non-Mac machine is
# worse than running it under a different compiler.
if command -v xcrun >/dev/null 2>&1; then
    SWIFTC="xcrun --sdk macosx swiftc -parse-as-library"
    CXX="xcrun --sdk macosx c++ -std=c++11 -Wall"
else
    SWIFTC=""
    CXX="${CXX:-c++} -std=c++11 -Wall"
fi

status=0
skipped=0

run_suite() {
    name=$1
    shift
    printf '%s\n' "=== $name ==="
    if [ -z "$SWIFTC" ]; then
        echo "SKIP: no Swift toolchain (needs a Mac with Xcode)"
        skipped=$((skipped + 1))
        echo
        return
    fi
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

run_suite CGAColorTests \
    "$ROOT/iOSCPM/Views/CGAColor.swift" \
    "$ROOT/Tests/CGAColorTests.swift"

run_suite TerminalRenditionTests \
    "$ROOT/iOSCPM/Views/CGAColor.swift" \
    "$ROOT/iOSCPM/Views/TerminalRendition.swift" \
    "$ROOT/Tests/TerminalRenditionTests.swift"

# The whole terminal: the grid, the cursor, the scrolling region, the scrollback
# and the escape parser. This is the suite that "the CSI parser has no unit
# tests" asked for; it can exist because TerminalScreen was pulled out of
# EmulatorViewModel and imports nothing but Foundation.
run_suite TerminalScreenTests \
    "$ROOT/iOSCPM/Views/CGAColor.swift" \
    "$ROOT/iOSCPM/Views/TerminalRendition.swift" \
    "$ROOT/iOSCPM/Views/TerminalDialect.swift" \
    "$ROOT/iOSCPM/Views/TerminalScreen.swift" \
    "$ROOT/Tests/TerminalScreenTests.swift"

# Where a selection is, what it covers, what text that is, and where on a
# letterboxed screen a given cell actually sits. All of it was private state and
# private methods on TerminalUIView until build 61 - which is why the half-open
# span that dropped the last selected cell, and the text extractor that trapped
# on a row shorter than the selection, both shipped. The gesture that drives
# this needs a finger and is in MANUAL_CHECKS.md; every decision it makes is
# here.
run_suite TerminalSelectionTests \
    "$ROOT/iOSCPM/Views/CGAColor.swift" \
    "$ROOT/iOSCPM/Views/TerminalRendition.swift" \
    "$ROOT/iOSCPM/Views/TerminalDialect.swift" \
    "$ROOT/iOSCPM/Views/TerminalScreen.swift" \
    "$ROOT/iOSCPM/Views/TerminalSelection.swift" \
    "$ROOT/Tests/TerminalSelectionTests.swift"

# The sizes the "New Disk" picker offers, against the rule emu_check_disk_size()
# applies. This suite reads the three geometry constants back out of
# iOSCPM/Core/emu_init.h, so an upstream change to them fails here rather than
# at a user's file picker.
run_suite DiskSizeTests \
    "$ROOT/iOSCPM/Views/DiskSize.swift" \
    "$ROOT/Tests/DiskSizeTests.swift"

# What a remembered Mac Catalyst window frame is allowed to be restored to. The
# UIKit calls that read and move the window are in CatalystWindow.swift and need
# a Catalyst build; every decision they make is here and does not.
run_suite WindowFrameTests \
    "$ROOT/iOSCPM/Views/WindowFrame.swift" \
    "$ROOT/Tests/WindowFrameTests.swift"

# Which published image each installed disk came from, and what may be done
# about one the catalog has moved on from. The reason this is a suite and not a
# hash comparison in the view model is in DiskLedger.swift: a downloaded disk is
# a writable CP/M volume, so "its bytes differ from the catalog" is not evidence
# that it is stale, and acting on it as though it were destroys user data.
run_suite DiskLedgerTests \
    "$ROOT/iOSCPM/Views/DiskLedger.swift" \
    "$ROOT/Tests/DiskLedgerTests.swift"

# Named machine configurations: what a profile carries, and what it does when
# one comes back from an older version or a hand-edited defaults plist.
run_suite EmulatorProfileTests \
    "$ROOT/iOSCPM/Views/CGAColor.swift" \
    "$ROOT/iOSCPM/Views/TerminalRendition.swift" \
    "$ROOT/iOSCPM/Views/TerminalDialect.swift" \
    "$ROOT/iOSCPM/Views/TerminalScreen.swift" \
    "$ROOT/iOSCPM/Views/DiskSize.swift" \
    "$ROOT/iOSCPM/Views/EmulatorProfile.swift" \
    "$ROOT/Tests/EmulatorProfileTests.swift"

run_core_suite CoreKeyboardTests \
    "$ROOT/Tests/CoreKeyboardTests.cc"

# Whether R8 can find out which file it is reading. The suite supplies two
# backend shapes - synchronous and parking - and drives R8's real sequence
# (0xE1 -> 0xEA -> 0xE3) through both, because the thing that was broken was a
# property of the backend's open and not of the getter. Also covers
# storeHostName's clamping and the PC-rewind arm.
run_core_suite CoreHostFileTests \
    "$ROOT/Tests/CoreHostFileTests.cc"

# The port's own Objective-C++ backend, compiled.
#
# WIP.md recorded this file as untestable here. That was too strong: it is
# Foundation-only Objective-C++, so the macosx SDK compiles it. It is a compile
# and not a run - nothing here observes what the code does.
#
# -Wundeclared-selector is the flag that earns it. Every delegate hop in that
# file is respondsToSelector:-guarded, so a selector that no longer exists fails
# SILENTLY at runtime: the message is simply never sent, and a failed R8 shows
# no alert. Plain -Wall says nothing about that, because @selector() accepts any
# literal. With this flag a @selector() naming a method no declared protocol
# has is an error here instead. -Werror on the two selector warnings only, so an
# unrelated future warning does not fail the suite.
#
# It cannot join run_core_suite, which falls back to plain `c++` off a Mac and
# would then try to compile Objective-C++ with no Foundation.
printf '%s\n' "=== EmuIOBackendCompiles ==="
if command -v xcrun >/dev/null 2>&1; then
    if xcrun --sdk macosx clang++ -fsyntax-only -Wall \
            -Wundeclared-selector -Werror=undeclared-selector \
            -x objective-c++ -std=c++11 \
            -fobjc-arc -I "$ROOT/iOSCPM/Core" "$ROOT/iOSCPM/Core/emu_io_ios.mm" 2>&1; then
        echo "PASS: emu_io_ios.mm compiles clean against the macOS SDK"
    else
        echo "FAIL: emu_io_ios.mm does not compile"
        status=1
    fi
else
    echo "SKIP: no Objective-C toolchain (needs a Mac)"
    skipped=$((skipped + 1))
fi
echo

if [ "$status" -ne 0 ]; then
    echo "TESTS FAILED"
    exit 1
fi
if [ "$skipped" -ne 0 ]; then
    echo "PASSED, $skipped suite(s) SKIPPED - this was not a full run"
    exit 0
fi
echo "ALL TESTS PASSED"
