#!/bin/sh
#
# Every `viewModel.<member>` ContentView.swift asks for, checked against what
# EmulatorViewModel.swift actually declares.
#
# WHY THIS EXISTS
#
# Five files import UIKit or use a SwiftUI macro and therefore cannot be
# type-checked on a machine that has only Command Line Tools: ContentView,
# TerminalView, CatalystWindow, HelpView and iOSCPMApp. Of those, exactly one
# reaches into the view model - ContentView - and it does so 90-odd times. So
# renaming or deleting a member of EmulatorViewModel is invisible to every check
# in this repo until somebody opens Xcode.
#
# That is not hypothetical. Build 65's ROM work shipped `loadROM(fromData:)`,
# which does not compile, and nothing noticed for two days. Removing the bundled
# ROM deleted `bundledROMFallbackRelease`, which ContentView called twice. Both
# are the same class of bug: a cross-file symbol that only Xcode resolves.
#
# WHAT IT IS AND IS NOT
#
# It is a spelling check, not a type check. It cannot see a changed argument
# label, a changed return type or a wrong `$binding`. It answers one question -
# "does this member still exist?" - and that is the question that keeps being
# answered wrong here.
#
# TerminalView.swift, CatalystWindow.swift and iOSCPMApp.swift do not mention the
# view model at all (verified: grep for EmulatorViewModel and viewModel in them
# returns nothing), so ContentView is the whole exposure. HelpView.swift's
# `viewModel` is a HelpViewModel declared in HelpView.swift itself, so it is
# checked against that file instead.
#
# Usage:  Tests/check_view_bindings.sh   (called by Tests/run_tests.sh)

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
status=0

# Declarations a Swift member reference can resolve to.
#
# Members of ONE named type, and only those. The first version of this took every
# `var`/`let`/`func`/`case` anywhere in the file, which let a local variable
# inside an unrelated function stand in for a member that does not exist - a
# dictionary big enough to pass almost anything, which is the failure mode a
# spelling check can least afford.
#
# The type's members are what sits at exactly four spaces of indentation between
# its opening line and the closing brace in column 0; a local is indented deeper,
# and a neighbouring type's members are outside the range. Extensions of the same
# type are included, which is why the awk matches every block whose header names
# it rather than only the first.
#
# Deliberately loose about access control and `static`/`class`: this is a
# spelling check, and a member that exists but is private is the compiler's to
# complain about on a real build.
decls_of() { # $1 = type name, then the files declaring it
    type=$1; shift
    awk -v want="$type" '
        # A top-level block header naming the type we want.
        /^(final )?(public |internal |fileprivate |private |open )?(class|struct|enum|extension) / {
            inside = ($0 ~ ("(class|struct|enum|extension)[[:space:]]+" want "[[:space:]:{]"))
            next
        }
        /^}/ { inside = 0; next }
        inside && /^    [^ ]/ {
            line = $0
            # strip attributes, access control and modifiers, then take the name
            if (match(line, /(var|let|func|case)[[:space:]]+`?[A-Za-z_][A-Za-z0-9_]*`?/)) {
                d = substr(line, RSTART, RLENGTH)
                sub(/^(var|let|func|case)[[:space:]]+/, "", d)
                gsub(/`/, "", d)
                print d
            }
        }' "$@" | sort -u
}

# Every `viewModel.member` / `$viewModel.member`, first component only.
uses_in() {
    grep -ohE '[$]?viewModel[?!]?\.[A-Za-z_][A-Za-z0-9_]*' "$1" |
        sed -E 's/.*\.([A-Za-z_][A-Za-z0-9_]*)/\1/' |
        sort -u
}

check_pair() { # $1 = user file, $2 = type name, then the files declaring it
    user=$1; label=$2; shift 2
    used=$(uses_in "$user")
    have=$(decls_of "$label" "$@")
    missing=""
    for m in $used; do
        printf '%s\n' "$have" | grep -qx "$m" || missing="$missing $m"
    done
    n=$(printf '%s\n' "$used" | grep -c . || true)
    if [ -z "$missing" ]; then
        echo "PASS: all $n $label members $(basename "$user") asks for are declared"
        return 0
    fi
    echo "FAIL: $(basename "$user") uses $label members that do not exist:"
    for m in $missing; do echo "        viewModel.$m"; done
    echo "      Xcode is the only other thing that would catch this."
    status=1
}

printf '%s\n' "=== ViewBindings ==="
check_pair "$ROOT/iOSCPM/Views/ContentView.swift" "EmulatorViewModel" \
    "$ROOT/iOSCPM/Views/EmulatorViewModel.swift"
check_pair "$ROOT/iOSCPM/Views/HelpView.swift" "HelpViewModel" \
    "$ROOT/iOSCPM/Views/HelpView.swift"

# Objective-C bridge calls made from ContentView.swift, a file no compiler here
# can reach. The view-model type-check covers every other bridge call; anything
# in this file would otherwise be checked by nothing.
#
# The list is DERIVED by grep and not written out. It used to be a one-element
# `for` loop naming RomWBWEmulator.romWBWReleases(), and when that method was
# deleted with romwbw_emu's release gate the loop went empty while the line
# below still printed PASS - a check that passes because it has nothing left to
# check is worse than no check. Today ContentView makes no direct bridge call
# at all (the About screen asks the view model, which asks the bridge), so the
# honest output is "none to check", and the day somebody adds one back this
# picks it up without being edited.
calls=$(grep -oE 'RomWBWEmulator\.[A-Za-z_][A-Za-z0-9_]*' \
            "$ROOT/iOSCPM/Views/ContentView.swift" | sort -u || true)
if [ -z "$calls" ]; then
    echo "PASS: ContentView makes no direct bridge call"
else
    bad=0
    for sym in $(printf '%s\n' "$calls" | sed -E 's/^RomWBWEmulator\.//'); do
        grep -qE "NS_SWIFT_NAME\($sym|[+-][[:space:]]*\([^)]*\)[[:space:]]*$sym" \
            "$ROOT/iOSCPM/Bridge/RomWBWEmulator.h" && continue
        echo "FAIL: ContentView calls RomWBWEmulator.$sym, which RomWBWEmulator.h does not declare"
        bad=1
        status=1
    done
    [ "$bad" -eq 0 ] &&
        echo "PASS: all $(printf '%s\n' "$calls" | grep -c .) bridge calls ContentView makes are declared"
fi

# The three Pickers the catalog fetch rewrites underneath, and the flag that
# says it is in flight.
#
# WHY THIS IS HERE AND NOT A SUITE
#
# Nothing in this repository constructs an EmulatorViewModel - every suite above
# compiles the small types that were split OUT of it - and the file that draws
# these controls is one of the five no compiler here can reach. So this is a
# shape check over the source, for the same reason the isStarting one in
# run_tests.sh is, and it lives beside the bridge-call block above rather than
# in a new file: this script is already "the checks on ContentView.swift that
# only Xcode would otherwise make", and its first block is only the largest of
# them.
#
# WHAT IT IS ANSWERING
#
# adoptCatalog() ends in refreshAvailableDisks(), restoreROMSelection() and
# restoreDiskSelections(), and adoptIndex() assigns `romwbwVersions` outright.
# Those four writes are exactly what these three Pickers show, so until a fetch
# lands each of them is offering the PREVIOUS catalog's rows. It cannot see
# whether the expression is otherwise right - `.disabled(true)` would pass - and
# it deliberately does not require `isRunning`, which the ROM Picker has never
# carried and does not need.
printf '%s\n' "=== CatalogPickerGating ==="

# The `.disabled(...)` modifier attached to a given Picker: the first one within
# 20 statement lines of the selection, taken from `.disabled(` until its
# parentheses balance so that a wrapped expression is read whole.
gating_of() { # $1 = the selection expression, $2 = file
    awk -v want="$1" '
        function balanced(s,   t, opens, closes) {
            t = s; opens  = gsub(/\(/, "", t)
            t = s; closes = gsub(/\)/, "", t)
            return (opens > 0 && opens == closes)
        }
        !found && index($0, want) { found = 1; next }
        # Prose carries no modifier, and this file discusses `.disabled(` at
        # length in comments that sit between controls.
        found && text == "" && /^[[:space:]]*\/\// { next }
        found && text == "" {
            i = index($0, ".disabled(")
            if (i == 0) { if (++n > 20) exit; next }
            text = substr($0, i)
            if (balanced(text)) { print text; exit }
            next
        }
        found {
            sub(/^[[:space:]]+/, "")
            text = text " " $0
            if (balanced(text)) { print text; exit }
        }' "$2"
}

CV="$ROOT/iOSCPM/Views/ContentView.swift"
for sel in '$viewModel.romwbwVersion' '$viewModel.selectedDisks[unit]' \
           '$viewModel.selectedROM'; do
    got=$(gating_of "selection: $sel" "$CV")
    if [ -z "$got" ]; then
        echo "FAIL: the Picker on $sel carries no .disabled(...) at all"
        echo "      A catalog fetch rewrites its rows while it is open."
        status=1
    elif printf '%s\n' "$got" | grep -q 'catalogLoading'; then
        echo "PASS: the Picker on $sel is off while the catalog is being read"
    else
        echo "FAIL: the Picker on $sel is not disabled on catalogLoading:"
        echo "        $got"
        echo "      Its rows are the previous fetch's until this one lands."
        status=1
    fi
done

exit $status
