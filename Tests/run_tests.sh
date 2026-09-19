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

# The 20 entries under iOSCPM/Core/ are symlinks into ../romwbw_emu/src and
# ../cpmemu/src. They have been flattened into stale copies once already (see
# docs/notes_to_windos.md), and a flattened copy still compiles and still
# passes every test below - it just stops tracking upstream. Check the shape
# before checking the behaviour.
printf '%s\n' "=== CoreSymlinks ==="
# The index is the thing that records the flattening, so this half needs a
# checkout. An exported tree has no index to consult and is not a failure.
if (cd "$ROOT" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    links=$( (cd "$ROOT" && git ls-files -s iOSCPM/Core/ | grep -c '^120000') || true)
    # 20 and not 21 since romwbw_emu v1.44 deleted src/romwbw_pin.h: the
    # symlink to it here dangled the moment that landed, with no commit in this
    # repository, and it went with the release gate it was the header for.
    if [ "${links:-0}" -eq 20 ]; then
        echo "PASS: all 20 iOSCPM/Core entries are still symlinks"
    else
        echo "FAIL: expected 20 symlinks under iOSCPM/Core, found ${links:-0}"
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

# The sizes the "New Disk" picker offers, against the rule emu_validate_disk_image()
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
# DiskLedger.swift and CatalogMigration.swift are mutually dependent and have to
# be compiled together: DiskLedger.action() calls
# CatalogMigration.isEquivalentPriorImage() to recognise the one migrated image
# whose hash disagrees with the catalog naming it, and CatalogMigration in turn
# rewrites a DiskLedger. So this list is the same eight files
# CatalogMigrationTests uses below, and the duplication is not something to
# tidy away - dropping either half stops the other compiling.
run_suite DiskLedgerTests \
    "$ROOT/iOSCPM/Views/CGAColor.swift" \
    "$ROOT/iOSCPM/Views/TerminalRendition.swift" \
    "$ROOT/iOSCPM/Views/TerminalDialect.swift" \
    "$ROOT/iOSCPM/Views/TerminalScreen.swift" \
    "$ROOT/iOSCPM/Views/DiskSize.swift" \
    "$ROOT/iOSCPM/Views/EmulatorProfile.swift" \
    "$ROOT/iOSCPM/Views/DiskLedger.swift" \
    "$ROOT/iOSCPM/Views/CatalogMigration.swift" \
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

# The two interface-v0 catalog documents: what a field is called, what may be
# missing, and when a fetched catalog is the wrong one. Nothing here touches the
# network - the fetch is in the view model and the decisions are in this file,
# which is why the suite is one source file and a handful of JSON literals cut
# from the real published documents.
run_suite CatalogDocumentTests \
    "$ROOT/iOSCPM/Views/CatalogDocument.swift" \
    "$ROOT/Tests/CatalogDocumentTests.swift"

# Renaming what the app remembers about a catalog disk when the catalog started
# naming its images <id>-v0-<romwbw version>.img. Four stores have to move
# together - the disk slots, the saved profiles, the ledger and the files - so
# this suite drags in DiskLedger and EmulatorProfile (and everything
# EmulatorProfile needs) to check the real types rather than stand-ins. The
# FileManager half is driven through renames(in:), which takes a directory
# listing and returns moves, for the same reason ExportPath takes a string.
run_suite CatalogMigrationTests \
    "$ROOT/iOSCPM/Views/CGAColor.swift" \
    "$ROOT/iOSCPM/Views/TerminalRendition.swift" \
    "$ROOT/iOSCPM/Views/TerminalDialect.swift" \
    "$ROOT/iOSCPM/Views/TerminalScreen.swift" \
    "$ROOT/iOSCPM/Views/DiskSize.swift" \
    "$ROOT/iOSCPM/Views/EmulatorProfile.swift" \
    "$ROOT/iOSCPM/Views/DiskLedger.swift" \
    "$ROOT/iOSCPM/Views/CatalogMigration.swift" \
    "$ROOT/Tests/CatalogMigrationTests.swift"

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
# What ContentView.swift asks of the view model, checked by name.
#
# The type-check below covers EmulatorViewModel itself; it cannot cover the file
# that drives it, because ContentView imports UIKit and there is no iOS SDK here.
# So a deleted or renamed member is invisible to every check in this repo until
# somebody opens Xcode. This closes that, for the one question it can answer.
sh "$ROOT/Tests/check_view_bindings.sh" || status=1
echo

# Every exit from start() puts the re-entrancy flag back.
#
# WHY THIS IS A SOURCE CHECK AND NOT A SUITE
#
# The decision being checked lives in EmulatorViewModel, which imports SwiftUI
# and the Objective-C bridge: the stage below type-checks it and nothing in this
# repository RUNS it. Splitting the flag into a Foundation-only type would make
# it a suite, and that is the pattern TerminalDialect and DiskSize follow - but
# it is two states and one bit, and a new file costs four project.pbxproj
# entries that nothing here can check. So the invariant is checked where it is
# written, by shape.
#
# It is a shape check, with a shape check's limits: it cannot tell whether a
# terminus is reachable, and a return whose clearing call is more than six
# statements above it reads as uncleared. What it does answer is the one
# question that shipped the bug - "does every way out of start() clear the
# flag?" - and it answers it for a new early return added months from now, which
# is when this stops being obvious.
printf '%s\n' "=== StartReentrancyGuard ==="
VM_FILE="$ROOT/iOSCPM/Views/EmulatorViewModel.swift"
CV_FILE="$ROOT/iOSCPM/Views/ContentView.swift"

# The lines of one method, from the declaration given verbatim to the closing
# brace at four spaces.
body_of() { # $1 = the whole declaration line, $2 = file
    awk -v head="$1" '
        $0 == head { on = 1; next }
        on && /^    \}/ { exit }
        on { print }' "$2"
}

# Statement lines only: blank lines and whole-line comments carry no control
# flow and would otherwise fill the window below with prose.
statements() { grep -vE '^[[:space:]]*(//|$)' | sed -E 's/^[[:space:]]+//'; }

# A `return` is cleared if the flag is put back on the same line or within the
# six statements above it - which is what a two-line failStart() call followed
# by a closing brace needs.
uncleared_returns() { # reads a body on stdin
    statements | awk '
        BEGIN { clears = "endStart\\(\\)|failStart\\(|guard !isStarting" }
        {
            if ($0 ~ /(^|[^A-Za-z_])return([^A-Za-z_]|$)/) {
                ok = ($0 ~ clears || $0 ~ /guard let self = self else/)
                for (i = 1; i <= n && !ok; i++) if (prev[i] ~ clears) ok = 1
                if (!ok) print "        " $0
            }
            for (i = n; i >= 1; i--) prev[i + 1] = prev[i]
            prev[1] = $0
            if (n < 6) n = n + 1
        }'
}

start_body=$(body_of "    func start() {" "$VM_FILE")
emu_body=$(body_of "    private func startEmulator() {" "$VM_FILE")

if [ -z "$start_body" ] || [ -z "$emu_body" ]; then
    echo "FAIL: cannot find start() and startEmulator() in EmulatorViewModel.swift"
    status=1
else
    # The guard itself, and that it is the FIRST thing start() does: a guard
    # below the first statement that can return is not a guard.
    first=$(printf '%s\n' "$start_body" | statements | head -1)
    case "$first" in
        guard\ !isStarting*)
            echo "PASS: start() refuses a second entry before it does anything else" ;;
        *)
            echo "FAIL: start() does not open with a guard on isStarting; it opens with:"
            echo "        $first"
            status=1 ;;
    esac

    printf '%s\n' "$start_body" | grep -q 'isStarting = true' &&
        echo "PASS: start() claims the flag" || {
            echo "FAIL: start() never sets isStarting = true, so the guard guards nothing"
            status=1
        }

    bad=$( { printf '%s\n' "$start_body"; printf '%s\n' "$emu_body"; } | uncleared_returns)
    if [ -z "$bad" ]; then
        echo "PASS: every return in start() and startEmulator() clears the flag first"
    else
        echo "FAIL: these returns leave isStarting set, so Play stops working:"
        printf '%s\n' "$bad"
        status=1
    fi

    # The success terminus has no `return` to hang off: startEmulator() simply
    # runs off the end, so the check for it is that its LAST statement is the
    # one that ends the start.
    last=$(printf '%s\n' "$emu_body" | statements | tail -1)
    case "$last" in
        endStart\(\)*)
            echo "PASS: startEmulator() ends the start when the machine comes up" ;;
        *)
            echo "FAIL: startEmulator() does not clear isStarting on the way out; it ends with:"
            echo "        $last"
            status=1 ;;
    esac
fi

# One writer. Every other path says endStart(), so a future terminus that pokes
# the flag directly - and skips whatever endStart() grows into - fails here.
writers=$(grep -c 'isStarting = false' "$VM_FILE" || true)
if [ "${writers:-0}" -eq 1 ] &&
   body_of "    private func endStart() {" "$VM_FILE" | grep -q 'isStarting = false'; then
    echo "PASS: endStart() is the only thing that clears the flag"
else
    echo "FAIL: isStarting is cleared in ${writers:-0} place(s) and endStart() is not the only one"
    status=1
fi

for f in stop reset; do
    if body_of "    func $f() {" "$VM_FILE" | grep -q 'endStart()'; then
        echo "PASS: $f() ends any start in flight"
    else
        echo "FAIL: $f() does not clear isStarting, so it cannot recover a stuck Play"
        status=1
    fi
done

# The UI half. Play and Stop are ONE button, so disabling it on isStarting alone
# would take the Stop away from a running machine as well - see the comment at
# the control. The check is written the way the bug would come back: as the
# simpler expression.
if grep -q '\.disabled(!viewModel\.isRunning && viewModel\.isStarting)' "$CV_FILE"; then
    echo "PASS: the Play/Stop button is disabled only while a start is in flight"
else
    echo "FAIL: ContentView's Play/Stop button does not carry"
    echo "      .disabled(!viewModel.isRunning && viewModel.isStarting)"
    status=1
fi
if grep -vE '^[[:space:]]*//' "$CV_FILE" | grep -q '\.disabled(viewModel\.isStarting)'; then
    echo "FAIL: .disabled(viewModel.isStarting) takes Stop away from a running machine too"
    status=1
fi
echo

# A second start does not land on a machine that is already running, and a start
# that does land says what it is starting.
#
# WHY THIS IS A SOURCE CHECK AND NOT A SUITE
#
# The same reason as the isStarting block above: both decisions are written into
# startEmulator(), which nothing in this repository constructs or runs. The
# banner's WORDING is tested by behaviour - the "What Start says it is starting"
# section of CatalogDocumentTests drives RomWBWRelease.startBanner through every
# arm - and every one of those passes whether or not anything ever calls it.
# This is the half a suite cannot reach: that startEmulator asks, and that it
# refuses a live machine before it wipes one.
#
# WHAT THE GUARD IS AGAINST. Everything in startEmulator() is destructive -
# clearTerminal(), resetScrollback(), closeAllDisks() inside
# loadSelectedResources(), and then HBIOSEmulator::start(), which re-initialises
# HBIOS and zeroes the registers. On a live machine that is a cold restart
# nobody asked for, with the session's output gone and the scrollback emptied
# behind it. isStarting does not cover it: that refuses a second PRESS while a
# start is in flight, and this refuses a flight that arrives after another has
# already brought the machine up - which Reset during a download makes
# reachable, since Reset calls endStart() and hands Play back. z80cpmw filed the
# same guard as df7accf.
#
# It is checked as the FIRST statement, because a guard below the first
# destructive call is not a guard.
printf '%s\n' "=== StartRefusesALiveMachineAndSaysWhatItStarts ==="
banner_body=$(body_of "    private func startEmulator() {" "$VM_FILE" | statements)
if [ -z "$banner_body" ]; then
    echo "FAIL: cannot find startEmulator() in EmulatorViewModel.swift"
    status=1
else
    case $(printf '%s\n' "$banner_body" | head -1) in
        guard\ !isRunning*)
            echo "PASS: startEmulator() refuses a machine that is already running" ;;
        *)
            echo "FAIL: startEmulator() does not open with a guard on isRunning; it opens with:"
            echo "        $(printf '%s\n' "$banner_body" | head -1)"
            echo "      Anything above that guard runs on the live machine it is meant to spare."
            status=1 ;;
    esac

    if printf '%s\n' "$banner_body" | grep -q 'RomWBWRelease\.startBanner('; then
        echo "PASS: startEmulator() asks RomWBWRelease.startBanner what to print"
    else
        echo "FAIL: startEmulator() does not call RomWBWRelease.startBanner, so what Start"
        echo "      says about the release, the ROM and the drives is decided somewhere"
        echo "      CatalogDocumentTests cannot see it."
        status=1
    fi

    # The wording lives in CatalogDocument.swift or it lives nowhere, for the
    # same reason romWBWReleaseSummary's does: a string built here is built where
    # nothing runs it. Read through statements(), so the comment above the call
    # - which quotes the line - cannot fail the check.
    inlined=$(printf '%s\n' "$banner_body" | grep '"Starting RomWBW' || true)
    if [ -z "$inlined" ]; then
        echo "PASS: and writes no second copy of the wording"
    else
        echo "FAIL: startEmulator() spells the banner out itself:"
        printf '%s\n' "$inlined" | sed 's/^/        /'
        status=1
    fi

    # AFTER the disks are loaded, so the drives it names are the ones that
    # actually took an image. Before that call, mountedDiskNames() answers for
    # the PREVIOUS machine - closeAllDisks() is the first thing
    # loadSelectedResources() does.
    order=$(printf '%s\n' "$banner_body" |
            grep -nE 'guard loadSelectedResources\(\)|RomWBWRelease\.startBanner\(|^emulator\?\.start\(\)')
    load_at=$(printf '%s\n' "$order" | grep 'loadSelectedResources' | head -1 | cut -d: -f1)
    banner_at=$(printf '%s\n' "$order" | grep 'startBanner' | head -1 | cut -d: -f1)
    start_at=$(printf '%s\n' "$order" | grep 'emulator?.start()' | head -1 | cut -d: -f1)
    if [ -z "$load_at" ] || [ -z "$banner_at" ] || [ -z "$start_at" ]; then
        echo "FAIL: cannot place the banner against the disk load and the core start:"
        printf '%s\n' "$order" | sed 's/^/        /'
        status=1
    elif [ "$load_at" -lt "$banner_at" ] && [ "$banner_at" -lt "$start_at" ]; then
        echo "PASS: and prints it after the disks are mounted and before the guest gets the screen"
    else
        echo "FAIL: the banner is not between loadSelectedResources() and emulator?.start():"
        printf '%s\n' "$order" | sed 's/^/        /'
        echo "      Above the load it names the previous machine's drives; below the start"
        echo "      it is racing the guest for the screen."
        status=1
    fi
fi
echo

# Downloaded disks land in the SCOPED library, and the scope is chosen before
# the transfer starts.
#
# WHY THIS IS A SOURCE CHECK AND NOT A SUITE
#
# The same reason as the isStarting block above: the decision is written into
# EmulatorViewModel, which nothing in this repository constructs or runs, and
# what would prove it by behaviour is a 49 MB download against a second
# catalog. So it is checked by shape, where it is written.
#
# TWO QUESTIONS, and the version that shipped answered both wrong.
#
# WHERE. `disksDirectoryURL` appends `CatalogMigration.indexScope` so a custom
# index gets a library of its own, because two catalogs publish DIFFERENT BYTES
# under the same filename - hd1k_combo-v0-3.6.0.img means one thing in
# romwbw_disks and another in a fork. `downloadDiskFromSettings` built
# `Documents/Disks` by hand, so under a custom index every download landed in
# the built-in index's library while `isDiskDownloaded`, `refreshAvailableDisks`
# and `fileFacts(for:)` all read the scoped one and saw nothing.
#
# WHEN. Reading the scope inside the completion handler answers the first
# question and still gets it wrong: `applyCatalogIndexURL` cancels no transfer
# in flight - its only guard is `!isRunning` - so an index switched mid-download
# would install catalog A's bytes into catalog B's library, which is precisely
# what the scope exists to prevent. The capture has to be synchronous.
printf '%s\n' "=== DiskDownloadScope ==="

# One spelling of the path, in one place. `grep -h | wc -l` and not `grep -c`,
# which prints a count PER FILE and so can never be compared with 1.
spellings=$(grep -h 'appendingPathComponent("Disks' "$ROOT"/iOSCPM/Views/*.swift | wc -l | tr -d ' ')
if [ "${spellings:-0}" -ne 1 ]; then
    echo "FAIL: $spellings places build the disk library path by hand; there must be exactly one"
    grep -n 'appendingPathComponent("Disks' "$ROOT"/iOSCPM/Views/*.swift | sed 's/^/        /'
    echo "      Everything else goes through disksDirectoryURL or downloadsDirectory."
    status=1
elif grep -h 'appendingPathComponent("Disks' "$ROOT"/iOSCPM/Views/*.swift |
        grep -q 'CatalogMigration.indexScope'; then
    echo "PASS: the disk library path is built in one place, and carries the index scope"
else
    echo "FAIL: the one disk library path does not carry CatalogMigration.indexScope:"
    grep -n 'appendingPathComponent("Disks' "$ROOT"/iOSCPM/Views/*.swift | sed 's/^/        /'
    echo "      A custom index would then share the built-in index's library."
    status=1
fi

# The function in two halves, split at the line that creates the transfer: the
# capture belongs in the first half and the second must not ask again. Read
# through statements() so that this comment block's own prose - which names
# both accessors - cannot satisfy or fail the check.
dl_body=$(awk '
    /^    private func downloadDiskFromSettings/ { on = 1 }
    on && /^    \}/ { exit }
    on { print }' "$VM_FILE")
before=$(printf '%s\n' "$dl_body" | sed -n '1,/session.downloadTask(with:/p' | statements)
after=$(printf '%s\n' "$dl_body" | sed -n '/session.downloadTask(with:/,$p' | statements)

if [ -z "$dl_body" ]; then
    echo "FAIL: cannot find downloadDiskFromSettings() in EmulatorViewModel.swift"
    status=1
else
    if printf '%s\n' "$before" |
            grep -qE 'disksDir *= *(Self\.)?(disksDirectoryURL|downloadsDirectory)'; then
        echo "PASS: the download captures its directory before the transfer starts"
    else
        echo "FAIL: downloadDiskFromSettings does not capture the disk directory before"
        echo "      session.downloadTask(with:). Whatever the completion handler uses"
        echo "      instead was decided 49 MB later, under whichever index is current then."
        status=1
    fi
    late=$(printf '%s\n' "$after" | grep -E 'disksDirectoryURL|downloadsDirectory' || true)
    if [ -z "$late" ]; then
        echo "PASS: the completion handler does not ask for the directory again"
    else
        echo "FAIL: the completion handler re-reads the disk directory:"
        printf '%s\n' "$late" | sed 's/^/        /'
        echo "      applyCatalogIndexURL cancels nothing in flight, so that answer can be"
        echo "      a DIFFERENT catalog's library from the one this transfer started in."
        status=1
    fi
fi
echo

# Emptying the four slots for a switch also raises slotsAwaitingCatalog.
#
# WHY THIS IS A SOURCE CHECK AND NOT A SUITE
#
# The same reason as the blocks above. What the flag GOVERNS is tested by
# behaviour - runSlotPersistTests in CatalogMigrationTests drives
# CatalogMigration.slotNamesToPersist through every arm - and all of it passes
# whether or not anything ever sets the flag. This is the half a suite cannot
# reach: that the two teardowns raise it.
#
# WHAT IT IS AGAINST. A release or index switch blanks selectedDisks inside the
# isRestoringSelections bracket, which stops the blanking persisting ITSELF and
# nothing more. The blanks stay in memory until the new catalog lands, and on a
# fetch that fails nothing refills them - so the next slot the user touched
# persisted three blanks plus their one edit over the new release's key, one
# edit late. On a release the device had never visited that wrote
# ["","","",""] where there had been no key at all, which makes
# restoreDiskSelections' hasSavedSelections true for good and keeps the
# first-launch disks out of slots 1-3 on that release for ever.
#
# A third teardown site added without the flag brings all of that back, so the
# sites are counted rather than named.
printf '%s\n' "=== SlotTeardownFlagsAwaitingCatalog ==="

# Statements only, so this comment block's own prose cannot satisfy the check,
# and anchored at the start of the statement so the @Published DECLARATION -
# which is the initial value at launch and must not raise the flag - does not
# count as a teardown.
teardown=$(statements < "$VM_FILE" | awk '
    /^selectedDisks = Array\(repeating: nil/ { sites++; window = 3; next }
    window > 0 {
        if ($0 ~ /^slotsAwaitingCatalog = true/) { flagged++; window = 0 }
        else window--
    }
    END { print sites + 0, flagged + 0 }')
sites=${teardown% *}
flagged=${teardown#* }
if [ "$sites" -lt 2 ]; then
    echo "FAIL: found $sites places that blank the four slots, expected the release"
    echo "      switch and the index switch at least"
    status=1
elif [ "$sites" -ne "$flagged" ]; then
    echo "FAIL: $sites teardowns blank the four slots, only $flagged raise slotsAwaitingCatalog"
    grep -n 'selectedDisks = Array(repeating: nil' "$VM_FILE" | sed 's/^/        /'
    echo "      The one that does not will persist its blanks on the user's next slot edit."
    status=1
else
    echo "PASS: all $sites slot teardowns raise slotsAwaitingCatalog"
fi

# And the restore lowers it BEFORE it persists. Clearing it afterwards reads
# just as well and is wrong: a release the device has never visited has no
# selectedDisks key, so savedSelections is nil, the first-launch branch fills
# the slots from RomWBWCatalogDocument.defaultDiskIDs, and a flag still raised
# would decline to write them - on precisely the switch that needs them.
restore_body=$(body_of "    private func restoreDiskSelections() {" "$VM_FILE" | statements)
if [ -z "$restore_body" ]; then
    echo "FAIL: cannot find restoreDiskSelections() - has it been renamed?"
    status=1
else
    order=$(printf '%s\n' "$restore_body" | grep -nE '^(slotsAwaitingCatalog = false|persistSelectedDisks\(remembering:)')
    clear_at=$(printf '%s\n' "$order" | grep 'slotsAwaitingCatalog = false' | head -1 | cut -d: -f1)
    persist_at=$(printf '%s\n' "$order" | grep 'persistSelectedDisks(remembering:' | head -1 | cut -d: -f1)
    if [ -z "$clear_at" ] || [ -z "$persist_at" ]; then
        echo "FAIL: restoreDiskSelections no longer both clears the flag and persists:"
        printf '%s\n' "$order" | sed 's/^/        /'
        status=1
    elif [ "$clear_at" -lt "$persist_at" ]; then
        echo "PASS: restoreDiskSelections lowers slotsAwaitingCatalog before it persists"
    else
        echo "FAIL: restoreDiskSelections persists before it lowers slotsAwaitingCatalog:"
        printf '%s\n' "$order" | sed 's/^/        /'
        echo "      A switch to a release with no saved slots would then write nothing,"
        echo "      and the catalog's own defaults would never reach slots 1-3."
        status=1
    fi
fi
echo

# The first-launch drives come from the catalog's ids, not from defaultSlot.
#
# WHY THIS IS A SOURCE CHECK AND NOT A SUITE
#
# The same reason as the blocks above. The RULE is tested by behaviour - the
# "First-launch drives" section of CatalogDocumentTests drives
# RomWBWCatalogDocument.defaultDiskFilenames through a release that publishes
# defaultSlot 3, one that publishes neither id, and the real 3.5.1 shape - and
# every one of those passes whether or not anything calls it. This is the half
# a suite cannot reach: that restoreDiskSelections asks.
#
# WHAT IT IS AGAINST. The loop that used to be here read each catalog entry's
# `defaultSlot` as the DRIVE to mount it in. That field is the slice to boot
# INSIDE the image (CATALOG_SCHEMA.md 3.3), and the mistake was invisible
# because the one entry publishing it is hd1k_combo with value 0. A release
# that published 3 would have filled drive 3 and left a first launch with
# nothing to boot in drive 0. Re-reading `defaultSlot` anywhere in this
# function is exactly what undoing the fix looks like, so that is what is
# checked - through statements(), so the comment explaining the change does not
# count as the change being undone.
printf '%s\n' "=== FirstLaunchDrivesByCatalogID ==="
first_launch=$(body_of "    private func restoreDiskSelections() {" "$VM_FILE" | statements)
if [ -z "$first_launch" ]; then
    echo "FAIL: cannot find restoreDiskSelections() - has it been renamed?"
    status=1
else
    if printf '%s\n' "$first_launch" | grep -q 'RomWBWCatalogDocument\.defaultDiskFilenames('; then
        echo "PASS: restoreDiskSelections asks RomWBWCatalogDocument for the first-launch drives"
    else
        echo "FAIL: restoreDiskSelections does not call"
        echo "      RomWBWCatalogDocument.defaultDiskFilenames, so which disk a fresh"
        echo "      install mounts in which drive is decided somewhere"
        echo "      CatalogDocumentTests cannot see it."
        status=1
    fi
    slotreads=$(printf '%s\n' "$first_launch" | grep -n 'defaultSlot' || true)
    if [ -z "$slotreads" ]; then
        echo "PASS: and it reads no defaultSlot, which is a slice and not a drive"
    else
        echo "FAIL: restoreDiskSelections reads defaultSlot:"
        printf '%s\n' "$slotreads" | sed 's/^/        /'
        echo "      That is the slice to boot inside an image, not one of the four"
        echo "      drives. It reads as correct only while hd1k_combo is the one entry"
        echo "      that publishes it and its value is 0."
        status=1
    fi
fi
echo

# The About line is RomWBWRelease.summary's wording, asked for with the bytes
# the core measured.
#
# WHY THIS IS A SOURCE CHECK AND NOT A SUITE
#
# The same reason as the two blocks above: `romWBWReleaseSummary` reads
# `emulator`, so it lives in EmulatorViewModel, which nothing in this
# repository constructs. The RULE it applies is tested by behaviour -
# runReleaseSummaryTests in CatalogDocumentTests covers every arm of
# RomWBWRelease.summary - and every one of those tests passes whether or not
# anything calls it. This is the half a suite cannot reach: that the view model
# asks.
#
# WHAT IT IS AGAINST. The property used to build "RomWBW <version> ROM loaded"
# itself, out of loadedRomWBWRelease() alone. Those two HCB bytes cannot spell
# a pre-release suffix, so a machine running the 3.7.0-dev.14 ROM said "RomWBW
# 3.7.0" - the release that snapshot PRECEDES - in the first line of every bug
# report. Re-inlining the string is exactly what undoing the fix looks like, so
# that is what is checked: the wording is in CatalogDocument.swift, where
# romServes can qualify it, or it is nowhere.
printf '%s\n' "=== ReleaseSummaryDelegation ==="
summary_body=$(body_of "    var romWBWReleaseSummary: String {" "$VM_FILE" | statements)
if [ -z "$summary_body" ]; then
    echo "FAIL: cannot find romWBWReleaseSummary in EmulatorViewModel.swift"
    status=1
else
    if printf '%s\n' "$summary_body" | grep -q 'RomWBWRelease\.summary('; then
        echo "PASS: romWBWReleaseSummary asks RomWBWRelease.summary for the wording"
    else
        echo "FAIL: romWBWReleaseSummary does not call RomWBWRelease.summary, so whatever"
        echo "      it says about a development snapshot is decided somewhere romServes"
        echo "      and CatalogDocumentTests cannot see it."
        status=1
    fi

    # The measured bytes have to still be what is handed over: a summary built
    # from the picker alone would name the snapshot and never notice a ROM from
    # another release, which is the opposite bug and the reason bank 0 is read.
    if printf '%s\n' "$summary_body" | grep -q 'loadedRomWBWRelease()'; then
        echo "PASS: and hands it what the core measured out of bank 0"
    else
        echo "FAIL: romWBWReleaseSummary no longer reads loadedRomWBWRelease(); nothing"
        echo "      else in this app asks a loaded ROM what release it is."
        status=1
    fi

    inlined=$(printf '%s\n' "$summary_body" | grep '"RomWBW' || true)
    if [ -z "$inlined" ]; then
        echo "PASS: and writes no second copy of the wording"
    else
        echo "FAIL: romWBWReleaseSummary spells the answer out itself:"
        printf '%s\n' "$inlined" | sed 's/^/        /'
        echo "      A string built here is built from the HCB bytes alone, which cannot"
        echo "      carry a -dev suffix. The wording belongs to RomWBWRelease.summary."
        status=1
    fi
fi
echo

# Every slot that gains or loses a local file settles its release warning.
#
# WHY THIS IS A SOURCE CHECK AND NOT A SUITE
#
# The same reason as the three blocks above. The DECISION is
# CatalogMigration.releaseNamedByLocalFile, which CatalogMigrationTests drives
# through every arm - and all of it passes whether or not anything ever calls
# it. This is the half a suite cannot reach, because nothing in this repository
# constructs an EmulatorViewModel, and the file that draws the warning is one of
# the five no compiler here can read.
#
# WHAT IT IS AGAINST. `localDiskReleaseNotices[i]` is what a slot says about the
# file bound to it and `localDiskURLs[i]` is that file, so a write to one
# without the other leaves a Settings row warning about an image that is no
# longer in the drive - or, worse, silent about one that is. The writes are not
# in one place and were not all reached from the same direction: loadLocalDisk
# binds a picked file, createNewDisk binds a blank image it wrote itself and
# never goes through loadLocalDisk, restoreLocalDiskBindings drops all four and
# then rebinds them from bookmarks under whatever release is now in play,
# clearLocalDisk unbinds one, and applyProfile unbinds every slot the profile
# names a catalog disk for. So the sites are counted rather than named, and a
# seventh added later has to answer this too.
printf '%s\n' "=== LocalDiskReleaseNotice ==="

# Assignments only, anchored, so `localDiskURLs[i]?.stopAccessing...` and the
# `if let url = localDiskURLs[unit]` reads are not counted as bindings, and the
# @Published DECLARATION - which is the empty state at launch and has nothing to
# warn about - is not either.
bindings=$(statements < "$VM_FILE" | awk '
    /^localDiskURLs\[[A-Za-z_][A-Za-z0-9_]*\] = / { sites++; window = 3; next }
    window > 0 {
        if ($0 ~ /^localDiskReleaseNotices\[/) { settled++; window = 0 }
        else window--
    }
    END { print sites + 0, settled + 0 }')
sites=${bindings% *}
settled=${bindings#* }
if [ "$sites" -lt 4 ]; then
    echo "FAIL: found $sites places that bind or unbind a local file, expected at least"
    echo "      loadLocalDisk, createNewDisk, restoreLocalDiskBindings and clearLocalDisk"
    status=1
elif [ "$sites" -ne "$settled" ]; then
    echo "FAIL: $sites writes to localDiskURLs, only $settled settle localDiskReleaseNotices"
    grep -n 'localDiskURLs\[.*\] = ' "$VM_FILE" | sed 's/^/        /'
    echo "      The one that does not leaves the slot's row warning about a file that is"
    echo "      not in that drive, or saying nothing about one that names another release."
    status=1
else
    echo "PASS: all $sites local-file bindings settle the slot's release warning"
fi
echo

# The saved catalog and the saved release list are checked before they are used.
#
# WHY THIS IS A SOURCE CHECK AND NOT A SUITE
#
# The same reason as the blocks above. The RULE is tested by behaviour - the
# "Reading back what this app saved" sections of CatalogDocumentTests drive
# CachedCatalog through a matching stamp, a disagreeing one and an absent one -
# and every one of those passes whether or not anything ever calls it. This is
# the half a suite cannot reach, because nothing in this repository constructs
# an EmulatorViewModel: that the OFFLINE path asks, and that the fetch path
# leaves it something to ask against.
#
# WHAT IT IS AGAINST. loadCachedCatalog decoded the file and adopted it. Both
# cache files sit in the disk library under Documents, which the app publishes
# over UIFileSharingEnabled, and a catalog names both the base_url each image
# is fetched from and the sha256 it is checked against - so an edited one is
# verified against its own hash and reported as good. The index cache is worse:
# it is where catalog_url and catalog_sha256 come from.
#
# AND AGAINST THE OTHER DIRECTION. The delete has to stay tied to
# `discardsFile`. Deleting an unstamped cache - which every install that
# predates the stamp has - would leave a device with no connection nothing to
# boot and no way back, since start() returns early on an empty diskCatalog.
# Declining costs one launch; deleting cannot be undone.
printf '%s\n' "=== CachedCatalogVerified ==="
for pair in "loadCachedCatalog:CachedCatalog.catalogVerdict(" \
            "continueFromCachedIndex:CachedCatalog.stampVerdict(" \
            "saveCatalogToCache:stampCache(" \
            "saveIndexToCache:stampCache("; do
    fn=${pair%%:*}
    wanted=${pair#*:}
    case $fn in
        continueFromCachedIndex) head="    private func $fn(indexProblem: String) {" ;;
        saveCatalogToCache)      head="    private func $fn(_ data: Data, for version: String) {" ;;
        saveIndexToCache)        head="    private func $fn(_ data: Data) {" ;;
        *)                       head="    private func $fn() {" ;;
    esac
    fn_body=$(body_of "$head" "$VM_FILE" | statements)
    if [ -z "$fn_body" ]; then
        echo "FAIL: cannot find $fn in EmulatorViewModel.swift - has it been renamed?"
        status=1
    elif printf '%s\n' "$fn_body" | grep -qF "$wanted"; then
        echo "PASS: $fn goes through ${wanted%(}"
    else
        echo "FAIL: $fn does not call ${wanted%(}, so a cache file edited in the Files"
        echo "      app is adopted - or written with nothing to check it against later."
        status=1
    fi
done

# Every deletion of a cache file is inside the discardsFile arm.
cache_deletes=$( { body_of "    private func loadCachedCatalog() {" "$VM_FILE"
                   body_of "    private func continueFromCachedIndex(indexProblem: String) {" "$VM_FILE"
                 } | statements | awk '
    /discardsFile/ { window = 4; next }
    /removeItem\(/ { if (window > 0) ok++; else bad++ }
    { if (window > 0) window-- }
    END { print ok + 0, bad + 0 }')
guarded=${cache_deletes% *}
unguarded=${cache_deletes#* }
if [ "$unguarded" -ne 0 ]; then
    echo "FAIL: $unguarded cache deletion(s) are not inside the discardsFile arm."
    echo "      An unstamped cache must be DECLINED and left alone: every install that"
    echo "      predates the stamp has one, and start() refuses an empty catalog, so a"
    echo "      device with no connection would be left with nothing to boot."
    status=1
elif [ "$guarded" -lt 2 ]; then
    echo "FAIL: only $guarded of the two cache files is deleted when its stamp disagrees;"
    echo "      bytes this app can prove are not its own should not be left on the device."
    status=1
else
    echo "PASS: both cache files are deleted only when a stamp is present and disagrees"
fi
echo

# EmulatorViewModel.swift and everything it needs, named once. The stage below
# this one compiles exactly the same files at a different target, and two copies
# of the list would let a file be checked at one target and not the other -
# which is the failure the second stage exists to catch. Unquoted where it is
# used, like $CORE_SRCS above: this is /bin/sh and the split into words is the
# point.
VM_SRCS="
    $ROOT/iOSCPM/Views/CGAColor.swift
    $ROOT/iOSCPM/Views/TerminalRendition.swift
    $ROOT/iOSCPM/Views/TerminalDialect.swift
    $ROOT/iOSCPM/Views/TerminalScreen.swift
    $ROOT/iOSCPM/Views/TerminalSelection.swift
    $ROOT/iOSCPM/Views/DiskSize.swift
    $ROOT/iOSCPM/Views/EmulatorProfile.swift
    $ROOT/iOSCPM/Views/DiskLedger.swift
    $ROOT/iOSCPM/Views/CatalogMigration.swift
    $ROOT/iOSCPM/Views/CatalogDocument.swift
    $ROOT/iOSCPM/Views/ControlKey.swift
    $ROOT/iOSCPM/Views/KeyMap.swift
    $ROOT/iOSCPM/Views/ExportPath.swift
    $ROOT/iOSCPM/Views/WindowFrame.swift
    $ROOT/iOSCPM/Views/EmulatorViewModel.swift
    $ROOT/Tests/ViewModelHostStubs.swift
"

# EmulatorViewModel.swift, type-checked.
#
# The 4,500-line file the catalog migration was written into, and the only one
# in the repo whose bridge calls cross into Objective-C. Every suite above
# compiles the small types that were SPLIT OUT of it; none of them compiles it.
#
# That gap shipped a hard compile error. Build 65 moved the ROM load onto
# `emulator?.loadROM(fromData: romImage)`, but `- (BOOL)loadROMFromData:(NSData*)`
# imports into Swift as `loadROM(from:)` - the importer drops "Data" from the
# label because it names the parameter's type - so the app target could not
# build. Nothing caught it: the pbxproj was correct, every other file compiled,
# and the only tool that compiles this one is Xcode, which the machine the
# migration was written on did not have.
#
# It type-checks against the macosx SDK because it imports SwiftUI, Combine,
# AVFoundation, CryptoKit and Network and no UIKit; Tests/ViewModelHostStubs.swift
# supplies the two symbols that do come from a UIKit-importing file. The
# bridging header is passed so every Objective-C call is checked against the real
# RomWBWEmulator.h rather than assumed.
#
# A type-check and not a run: nothing here observes what the code does. The five
# files that DO import UIKit - ContentView, TerminalView, CatalystWindow,
# HelpView, iOSCPMApp - still need an iOS SDK and are checked only by Xcode.

printf '%s\n' "=== EmulatorViewModelTypechecks ==="
if command -v xcrun >/dev/null 2>&1; then
    if xcrun --sdk macosx swiftc -typecheck -parse-as-library \
            -import-objc-header "$ROOT/iOSCPM/iOSCPM-Bridging-Header.h" \
            -I "$ROOT/iOSCPM/Bridge" -I "$ROOT/iOSCPM/Core" \
            $VM_SRCS 2>&1; then
        echo "PASS: EmulatorViewModel.swift type-checks, bridge calls included"
    else
        echo "FAIL: EmulatorViewModel.swift does not type-check"
        status=1
    fi
else
    echo "SKIP: no Swift toolchain (needs a Mac)"
    skipped=$((skipped + 1))
fi
echo

# The same files, at the deployment target the app actually ships.
#
# The stage above compiles them for the host macOS, where the whole SDK is
# available and nothing is too new. So an API added under an iOS version above
# IPHONEOS_DEPLOYMENT_TARGET type-checks clean there and trips on a user's
# device instead - which is the one failure mode that a type-check can be made
# to catch and the stage above structurally cannot. The network surface is where
# this bites first: NWPathMonitor, path.isConstrained,
# allowsExpensiveNetworkAccess, allowsConstrainedNetworkAccess and
# URLError.networkUnavailableReason are all used in EmulatorViewModel with no
# availability guard. WIP.md recorded that somebody once ran this by hand; this
# is it as a check.
#
# -macabi and not a plain ios target because there is no iOS SDK on a machine
# with only Command Line Tools. Mac Catalyst is a slice this app ships
# (SUPPORTS_MACCATALYST = YES), the macosx SDK compiles it, availability is
# still enforced against the iOS floor, and it reaches one arm the stage above
# never sees: openFolderInFilesApp is behind #if targetEnvironment(macCatalyst).
#
# The floor is read out of the pbxproj rather than written here, so raising
# IPHONEOS_DEPLOYMENT_TARGET moves the check with it instead of leaving it
# certifying a floor nobody ships any more.
printf '%s\n' "=== DeploymentFloorTypechecks ==="
FLOOR=$(sed -n 's/^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET = \([0-9.]*\);.*/\1/p' \
        "$ROOT/iOSCPM.xcodeproj/project.pbxproj" 2>/dev/null | sort -u)
if [ -z "$FLOOR" ]; then
    # A tree with no pbxproj has no floor to check against, the same way an
    # exported tree has no index for CoreSymlinks to consult. Under `set -e` the
    # sed above cannot abort the run - the pipeline's status is sort's - so this
    # is the arm that catches it, and not knowing is not a failure.
    echo "SKIP: no IPHONEOS_DEPLOYMENT_TARGET in project.pbxproj to check against"
    skipped=$((skipped + 1))
elif [ "$(printf '%s\n' "$FLOOR" | wc -l)" -ne 1 ]; then
    echo "FAIL: project.pbxproj sets more than one IPHONEOS_DEPLOYMENT_TARGET:" $FLOOR
    echo "      Debug and Release ship one app; this stage needs one floor to check"
    status=1
elif ! command -v xcrun >/dev/null 2>&1; then
    echo "SKIP: no Swift toolchain (needs a Mac)"
    skipped=$((skipped + 1))
elif floor_out=$(xcrun --sdk macosx swiftc -typecheck -parse-as-library \
        -target "arm64-apple-ios${FLOOR}-macabi" \
        -import-objc-header "$ROOT/iOSCPM/iOSCPM-Bridging-Header.h" \
        -I "$ROOT/iOSCPM/Bridge" -I "$ROOT/iOSCPM/Core" \
        $VM_SRCS 2>&1); then
    echo "PASS: type-checks at the shipped floor, iOS $FLOOR (Catalyst)"
elif printf '%s\n' "$floor_out" | grep -q 'invalid version number'; then
    # Mac Catalyst carries a floor of its own and it rises: this toolchain
    # already refuses ios13.0-macabi and accepts 14.0 as its lowest. The day
    # that overtakes IPHONEOS_DEPLOYMENT_TARGET, swiftc rejects the target
    # string before it compiles a line, and calling that "uses an API newer than
    # the floor" would send the reader looking for a bug in Swift that is not
    # there. Nothing was checked, so say so.
    echo "SKIP: this toolchain will not target iOS $FLOOR as Mac Catalyst"
    skipped=$((skipped + 1))
else
    echo "$floor_out"
    echo "FAIL: uses an API newer than IPHONEOS_DEPLOYMENT_TARGET = $FLOOR"
    status=1
fi
echo

# The Swift/Objective-C bridge, compiled.
#
# `EmulatorViewModelTypechecks` above checks the Swift SIDE of every bridge call
# against RomWBWEmulator.h, which is what catches a wrong argument label. It
# does not compile the implementation, so a header and a .mm that disagree - a
# method declared and not defined, or defined and not declared - passed
# everything in this repository. Build 66 removed `loadROMFromBundle:` and
# `romWBWReleaseOfBundledROM:` from both files with nothing checking that both
# halves moved together.
#
# -std=c++17 and not the c++11 the core suites use: this file calls
# std::make_unique, which is C++14.
printf '%s\n' "=== BridgeCompiles ==="
if command -v xcrun >/dev/null 2>&1; then
    if xcrun --sdk macosx clang++ -fsyntax-only -Wall \
            -Wundeclared-selector -Werror=undeclared-selector \
            -x objective-c++ -std=c++17 -fobjc-arc \
            -I "$ROOT/iOSCPM/Core" -I "$ROOT/iOSCPM/Bridge" \
            "$ROOT/iOSCPM/Bridge/RomWBWEmulator.mm" 2>&1; then
        echo "PASS: RomWBWEmulator.mm compiles clean against its own header"
    else
        echo "FAIL: RomWBWEmulator.mm does not compile"
        status=1
    fi
else
    echo "SKIP: no Objective-C toolchain (needs a Mac)"
    skipped=$((skipped + 1))
fi
echo

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
