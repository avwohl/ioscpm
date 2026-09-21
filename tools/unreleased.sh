#!/bin/sh
# unreleased.sh - what is finished here but not yet in anybody's hands?
#
# WHY THIS EXISTS.  "Done" means four different things and the gap between them
# is where the mistakes come from: written, compiled, submitted, released.
# `CLAUDE.md` has the rule this enforces by reporting rather than by gating -
# archiving is not uploading, and submitted is not released.  How tight the
# answer is depends on the version: see "the commit that version was cut from".  On 2026-09-03 the
# tree was at build 58 while the App Store served 1.4.9, builds 36/37, six
# months old.  Twenty-one builds of true statements about this repository were
# false statements about the product.
#
# THIS IS ONE OF SIX AND THEY ARE DELIBERATELY DIFFERENT.  Every port ships on
# its own channel, so each repository's unreleased.sh is written for its own
# channel rather than copied.  check-shipped-disks.sh was "one file in five
# repos", diverged into four that no two of which agreed, and "the check
# passed" came to mean four different things.  Do not try to unify these.
#
#   sh tools/unreleased.sh
#
# HOW THIS RUNS: BY HAND, AND IT MUST STAY THAT WAY.  Not wired to any
# workflow, and the exit codes are shaped so it cannot usefully become one.
#
# Exit 0 = it measured, INCLUDING when the answer is "nine builds unreleased".
#          That is the normal state of a working repository.  Four jobs in this
#          family went red daily for the normal state and all four were deleted
#          on 2026-09-13; do not rebuild one out of this.
# Exit 2 = could not measure.  Nothing is asserted when nothing was read.
#
# There is no exit 1.

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here" && git rev-parse --show-toplevel 2>/dev/null) || {
    echo "CANNOT MEASURE: $here is not inside a git checkout."; exit 2; }

echo "ioscpm - the App Store, iOS and Mac Catalyst"
echo

store_out=$(sh "$here/check-store-version.sh" 2>&1)
store_rc=$?
echo "$store_out" | sed 's/^/  /'
echo
if [ "$store_rc" = 2 ]; then
    echo "  The App Store could not be measured, so nothing below would mean anything."
    exit 2
fi

live=$(echo "$store_out" | sed -n 's/^  serves  *\([0-9][0-9.]*\).*/\1/p' | head -1)
if [ -z "${live:-}" ]; then
    echo "  CANNOT MEASURE: no 'serves' line in the store output."
    exit 2
fi

# --- the commit that version was cut from ------------------------------------
# The App Store channel leaves no git tag behind - this repository's tags are
# disk-image pins (v1.4.x), not app releases - so the anchor has to be found in
# the pbxproj's history.  There are two ways to find it and they are not equally
# good, so this asks check-store-version.sh which one it has earned.
#
# EXACT, when the served version heads exactly one CHANGELOG entry.  That script
# prints "which is  build NN" with no hedge in that case, and NN is then the
# build users actually have: the anchor is the commit that set
# CURRENT_PROJECT_VERSION to NN, and what follows is neither an over- nor an
# under-count.
#
# FLOOR, otherwise.  Every version before 1.6.2 spanned several builds - 1.6.1
# heads builds 67 to 72 - and the lookup does not say which of them Apple
# served, so the script hedges with "at most build NN".  The anchor is then the
# commit that first set MARKETING_VERSION to the served value, which is the
# FLOOR of that range, and the list below becomes an UPPER BOUND: if a later
# build of the same version shipped, some of what is reported has in fact
# reached users.  That is the safe direction for "what might I still owe a
# user" - better over-answered than under-answered - but it is an over-count,
# not a truth, and saying which way the error runs is the point.
exact=$(echo "$store_out" | sed -n 's/^  which is  *build \([0-9][0-9]*\).*/\1/p' | head -1)
anchor=
if [ -n "${exact:-}" ]; then
    anchor=$(git -C "$root" log --format=%H --reverse -S"CURRENT_PROJECT_VERSION = $exact;" \
                 -- iOSCPM.xcodeproj/project.pbxproj 2>/dev/null | head -1)
fi
if [ -n "${anchor:-}" ]; then
    kind=exact
else
    kind=floor
    anchor=$(git -C "$root" log --format=%H --reverse -S"MARKETING_VERSION = $live" \
                 -- iOSCPM.xcodeproj/project.pbxproj 2>/dev/null | head -1)
fi
if [ -z "${anchor:-}" ]; then
    echo "  CANNOT MEASURE: no commit sets MARKETING_VERSION to $live."
    echo "  The App Store serves $live and this tree has no record of building it."
    exit 2
fi

short=$(git -C "$root" rev-parse --short "$anchor")
build=$(git -C "$root" show "$anchor:iOSCPM.xcodeproj/project.pbxproj" 2>/dev/null |
        sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\);.*/\1/p' | head -1)
if [ "$kind" = exact ]; then
    echo "  $live is build $exact, cut at $short - $(git -C "$root" log -1 --format=%s "$anchor")"
    echo "  That is the build itself and not a floor: $live heads exactly one"
    echo "  CHANGELOG entry, so what follows is what users do NOT have, neither"
    echo "  over- nor under-counted."
else
    echo "  $live first appears at $short (build ${build:-unknown}) - $(git -C "$root" log -1 --format=%s "$anchor")"
    echo "  That is the FLOOR of the builds $live covers.  Nothing here records"
    echo "  which build Apple actually served, so the list below is an UPPER BOUND:"
    echo "  if a later build of $live shipped, some of it has already reached users."
    echo "  Over-counting is the safe direction here, but it is over-counting."
fi
echo

n=$(git -C "$root" rev-list --count "$anchor..HEAD" 2>/dev/null)
if [ "${n:-0}" = "0" ]; then
    echo "  Nothing since.  The tree is what the App Store serves."
else
    echo "  $n commit(s) since that build:"
    echo
    git -C "$root" log --format='    %h  %ad  %s' --date=short "$anchor..HEAD"
    echo
    app_n=$(git -C "$root" rev-list --count "$anchor..HEAD" -- iOSCPM/ 2>/dev/null)
    echo "  Of those, $app_n touch iOSCPM/ - the application itself."
    if [ "${app_n:-0}" != "0" ]; then
        git -C "$root" log --format='      %h  %s' "$anchor..HEAD" -- iOSCPM/
        echo
        if [ "$kind" = exact ]; then
            echo "  Those are features and fixes an App Store user does not have."
        else
            echo "  Those are features and fixes an App Store user on the FLOOR"
            echo "  build does not have; some may be in a later build of $live."
        fi
        echo "  They reach a user only through a submission Apple then"
        echo "  releases - and the upload is a person with credentials, not"
        echo "  a session."
    fi
    asset_n=$(git -C "$root" rev-list --count "$anchor..HEAD" -- release_assets/ 2>/dev/null)
    if [ "${asset_n:-0}" != "0" ]; then
        echo
        echo "  $asset_n touch release_assets/ - the help topics.  Those do NOT"
        echo "  need an app release: they are published to the romwbw_disks"
        echo "  catalog and reach installed clients on their next fetch."
        git -C "$root" log --format='      %h  %s' "$anchor..HEAD" -- release_assets/
    fi
fi
echo

exit 0
