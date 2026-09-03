#!/bin/sh
# check-store-version.sh - what does the App Store actually serve, and does
# anything in this tree claim otherwise?
#
# WHY THIS EXISTS.  A tick in a feature table, a "shipped" column, a release
# note and a changelog heading all describe the TREE.  None of them knows what a
# user can install.  On 2026-09-03 the tree was at build 58 and the Store was
# serving 1.4.9 - builds 36/37, released 2026-03-19 - so twenty-one builds and
# six months of true statements about this repository were false statements
# about the product.  The gap is normal; asserting it away is not.  This
# measures the gap instead of inferring it.
#
# It is the companion to check-disk-pins.sh, which asks the same question one
# layer down: that one checks the image users download, this one checks the app
# users run.  Neither is answerable from inside the tree, which is why both go
# out to the network and why both exit 2 rather than 0 when they cannot.
#
#   sh tools/check-store-version.sh
#
# Exit 0 = measured, and nothing recorded in this tree or its siblings claims a
#          shipped build the Store does not serve.  The tree being AHEAD of the
#          Store is normal and is never a failure - you always build before you
#          ship.
# Exit 1 = something records a shipped state that contradicts the measurement,
#          or the pbxproj disagrees with itself.
# Exit 2 = could not verify (no network, no parser, no such app).  A gate that
#          cannot verify must not say yes.

set -u

BUNDLE_ID="com.awohl.cpm"
LOOKUP="https://itunes.apple.com/lookup?bundleId=$BUNDLE_ID&country=us"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here" && git rev-parse --show-toplevel 2>/dev/null) || root=$(dirname "$here")
SRC=$(dirname "$root")

PBX="$root/iOSCPM.xcodeproj/project.pbxproj"
CHANGELOG="$root/CHANGELOG.md"

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t store)
trap 'rm -rf "$tmp"' EXIT INT TERM

status=0

get() { # $1 url, $2 dest
    if command -v curl >/dev/null 2>&1; then
        curl -sSfL -o "$2" "$1" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1" 2>/dev/null
    else
        return 127
    fi
}

# Flat JSON, one object, no nesting we care about.  Anchor on the opening quote
# so "version" does not also match "minimumOsVersion".
jfield() { # $1 = key, reads $tmp/lookup.json
    tr -d '\n' < "$tmp/lookup.json" |
        grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" |
        head -1 |
        sed 's/.*"\([^"]*\)"$/\1/'
}

vnum() { # $1 = 1.4.9 -> sortable integer
    echo "$1" | awk '{
        sub(/^v/, "", $0); n = split($0, a, "."); r = 0
        for (i = 1; i <= 4; i++) r = r * 1000 + (i <= n ? a[i] + 0 : 0)
        print r
    }'
}

days_since() { # $1 = 2026-03-19T10:15:33Z -> days, or nothing
    d=$(echo "$1" | cut -c1-10)
    now=$(date -u +%Y-%m-%d 2>/dev/null) || return 1
    # BSD date, then GNU date, then give up rather than print a wrong number.
    a=$(date -j -u -f %Y-%m-%d "$d" +%s 2>/dev/null) ||
    a=$(date -u -d "$d" +%s 2>/dev/null) || return 1
    b=$(date -j -u -f %Y-%m-%d "$now" +%s 2>/dev/null) ||
    b=$(date -u -d "$now" +%s 2>/dev/null) || return 1
    echo $(( (b - a) / 86400 ))
}

# --- what the Store serves -----------------------------------------------------
if ! get "$LOOKUP" "$tmp/lookup.json"; then
    echo "CANNOT VERIFY: no network, or neither curl nor wget is installed."
    echo "This gate does not pass when it cannot check."
    exit 2
fi

case "$(tr -d ' \n' < "$tmp/lookup.json")" in
    *'"resultCount":0'*)
        echo "CANNOT VERIFY: the lookup returned no result for $BUNDLE_ID."
        echo "Either the app is not on the US store, or the bundle id changed."
        exit 2 ;;
esac

live=$(jfield version)
when=$(jfield currentVersionReleaseDate)
name=$(jfield trackName)

if [ -z "$live" ]; then
    echo "CANNOT VERIFY: could not read a version out of the iTunes lookup."
    echo "Rate-limited, or the response shape changed."
    exit 2
fi

echo "App Store, $BUNDLE_ID (${name:-unknown})"
echo "  serves           $live"
age=$(days_since "$when") || age=
if [ -n "$age" ]; then
    echo "  released         $(echo "$when" | cut -c1-10)  ($age days ago)"
else
    echo "  released         $(echo "$when" | cut -c1-10)"
fi

# --- what the tree claims to be ------------------------------------------------
mkv=$(grep -o 'MARKETING_VERSION = [^;]*;' "$PBX" 2>/dev/null |
      sed 's/.*= *//; s/;//' | sort -u)
cpv=$(grep -o 'CURRENT_PROJECT_VERSION = [^;]*;' "$PBX" 2>/dev/null |
      sed 's/.*= *//; s/;//' | sort -u)

if [ -z "$mkv" ] || [ -z "$cpv" ]; then
    echo "CANNOT VERIFY: no MARKETING_VERSION/CURRENT_PROJECT_VERSION in $PBX."
    exit 2
fi

# CLAUDE.md: both appear twice, Debug and Release, and must move together.
if [ "$(echo "$mkv" | wc -l | tr -d ' ')" != 1 ]; then
    echo
    echo "PBXPROJ DISAGREES WITH ITSELF: MARKETING_VERSION is [$(echo "$mkv" | tr '\n' ' ')]"
    echo "  Debug and Release must carry the same version.  See CLAUDE.md."
    status=1
    mkv=$(echo "$mkv" | tail -1)
fi
if [ "$(echo "$cpv" | wc -l | tr -d ' ')" != 1 ]; then
    echo
    echo "PBXPROJ DISAGREES WITH ITSELF: CURRENT_PROJECT_VERSION is [$(echo "$cpv" | tr '\n' ' ')]"
    echo "  Debug and Release must carry the same build number.  See CLAUDE.md."
    status=1
    cpv=$(echo "$cpv" | tail -1)
fi

echo "  this tree        $mkv (build $cpv)"

# --- which build is the shipped version? ---------------------------------------
# The lookup returns a marketing version and no build number, so the mapping
# comes from CHANGELOG.md's headings.  Exact when one names the shipped version;
# otherwise the two headings it falls between, which is an honest bracket rather
# than a guess.  1.4.9 has no heading at all - it is bracketed by 1.4.8 (35) and
# 1.4.10 (39), i.e. builds 36-38.
exact=$(awk -v v="$live" '
    $0 ~ "^## Version " v " \\(Build [0-9]+\\)" {
        match($0, /Build [0-9]+/); print substr($0, RSTART + 6, RLENGTH - 6); exit }' "$CHANGELOG" 2>/dev/null)

lo=; hi=
if [ -z "$exact" ]; then
    lv=$(vnum "$live")
    while read -r hv hb; do
        [ -n "$hb" ] || continue
        n=$(vnum "$hv")
        if [ "$n" -lt "$lv" ] 2>/dev/null; then
            [ -z "$lo" ] && lo=$hb
        elif [ "$n" -gt "$lv" ] 2>/dev/null; then
            hi=$hb
        fi
    done <<EOF
$(awk '/^## Version [0-9]/ {
        v = $3; b = ""
        if (match($0, /Build [0-9]+/)) b = substr($0, RSTART + 6, RLENGTH - 6)
        print v, b }' "$CHANGELOG" 2>/dev/null)
EOF
fi

if [ -n "$exact" ]; then
    shipped_build=$exact
    echo "  which is         build $exact  (CHANGELOG.md names it)"
    ceiling=$exact
elif [ -n "$lo" ] && [ -n "$hi" ]; then
    shipped_build=
    echo "  which is         after build $lo, before build $hi  (no CHANGELOG heading for $live)"
    ceiling=$((hi - 1))
else
    shipped_build=
    ceiling=
    echo "  which is         unknown - no CHANGELOG heading brackets $live"
fi

# --- the gap -------------------------------------------------------------------
echo
if [ "$(vnum "$mkv")" -lt "$(vnum "$live")" ] 2>/dev/null; then
    echo "TREE IS BEHIND THE STORE: MARKETING_VERSION $mkv < shipped $live."
    echo "  That is not a normal state.  Somebody edited it downward, or a"
    echo "  release went out from another checkout.  See CLAUDE.md."
    status=1
elif [ -n "$ceiling" ] && [ "$cpv" -gt "$ceiling" ] 2>/dev/null; then
    echo "The tree is ahead of the Store by roughly $((cpv - ceiling)) build(s). That is normal."
    echo "What is NOT normal is writing build $cpv into anything that records what"
    echo "USERS have.  Queued is not released: a submission can sit in review, be"
    echo "rejected, or be held.  Nothing that records what ships may move until this"
    echo "script says otherwise."
else
    echo "The tree and the Store agree on what users have."
fi

# --- what the siblings claim ships ---------------------------------------------
# z80cpmw/FEATURE_PARITY.md carries an ioscpm 'shipped:<build>' in its
# sibling-readings block, and check-sibling-drift.sh scores every tick in the
# ioscpm column against it.  That field is hand-maintained because no tree knows
# what a store is serving - this is the measurement it is supposed to be set
# from.  It failing because the tree is ahead is CORRECT and must not be
# "fixed" by editing the number.
fp="$SRC/z80cpmw/FEATURE_PARITY.md"
if [ -f "$fp" ]; then
    claim=$(awk '/^ioscpm[[:space:]]/ { for (i = 1; i <= NF; i++)
                    if ($i ~ /^shipped:/) { print substr($i, 9); exit } }' "$fp")
    echo
    if [ -z "$claim" ]; then
        echo "z80cpmw/FEATURE_PARITY.md  no shipped: field on the ioscpm line"
    elif [ "$claim" = unknown ]; then
        echo "z80cpmw/FEATURE_PARITY.md  shipped:unknown - set it from the reading above"
        status=1
    elif [ -n "$ceiling" ] && [ "$claim" -gt "$ceiling" ] 2>/dev/null; then
        echo "z80cpmw/FEATURE_PARITY.md  CLAIMS shipped:$claim, BUT $live cannot be past build $ceiling"
        echo "  Every tick in the ioscpm column is being scored against software"
        echo "  no user has.  Set it back to what this script measured."
        status=1
    else
        echo "z80cpmw/FEATURE_PARITY.md  shipped:$claim agrees with what the Store serves"
    fi
fi

echo
if [ "$status" != 0 ]; then
    echo "Something records a shipped state the Store does not support."
    exit 1
fi
exit 0
