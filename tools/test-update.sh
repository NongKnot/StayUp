#!/bin/sh
# Sparkle/update readiness check.
#
# Usage:
#   sh tools/test-update.sh        # local preflight before signing/release
#   sh tools/test-update.sh live   # after deploying appcast.xml to production

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE="${1:-local}"
INFO="$ROOT/Info.plist"
CHANGELOG="$ROOT/CHANGELOG.md"
RELEASE="$ROOT/tools/release.sh"
SIGN_UPDATE="$ROOT/Vendor/Sparkle-bin/sign_update"
# Default to the version the app actually declares — Info.plist is the single
# definition point, so a standalone run checks the *current* release's
# consistency (build number, CHANGELOG entry, live appcast) instead of rotting
# on a hardcoded number. Set STAYUP_EXPECTED_VERSION to assert a specific
# release (e.g. pre-bump intent checks in a release flow).
EXPECTED_VERSION="${STAYUP_EXPECTED_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")}"
FEED_URL="${STAYUP_FEED_URL:-https://getstayup.app/appcast.xml}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

plist() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO"
}

version="$(plist CFBundleShortVersionString)"
build="$(plist CFBundleVersion)"
feed="$(plist SUFeedURL)"
pubkey="$(plist SUPublicEDKey)"

[ "$version" = "$EXPECTED_VERSION" ] || fail "CFBundleShortVersionString is $version, expected $EXPECTED_VERSION"
[ "$build" = "$EXPECTED_VERSION" ] || fail "CFBundleVersion is $build, expected $EXPECTED_VERSION"
[ "$feed" = "$FEED_URL" ] || fail "SUFeedURL is $feed, expected $FEED_URL"
[ -n "$pubkey" ] || fail "SUPublicEDKey is empty"

grep -q "^## \[$EXPECTED_VERSION\]" "$CHANGELOG" ||
    fail "CHANGELOG.md is missing ## [$EXPECTED_VERSION]"

grep -q 'SIGN_UPDATE=' "$RELEASE" || fail "release.sh does not configure SIGN_UPDATE"
grep -q 'CHANGELOG.md' "$RELEASE" || fail "release.sh does not read CHANGELOG.md"
grep -q 'appcast.xml' "$RELEASE" || fail "release.sh does not write appcast.xml"

if [ -f "$SIGN_UPDATE" ] && [ ! -x "$SIGN_UPDATE" ]; then
    chmod +x "$SIGN_UPDATE" 2>/dev/null || true
fi
[ -x "$SIGN_UPDATE" ] || fail "Sparkle sign_update is missing or not executable: $SIGN_UPDATE"

case "$MODE" in
    local)
        echo "update preflight: ok (local $EXPECTED_VERSION)"
        ;;
    live)
        tmp="${TMPDIR:-/tmp}/stayup-appcast-live.$$"
        trap 'rm -f "$tmp"' EXIT HUP INT TERM
        curl -fsSL --max-time 20 "$FEED_URL" > "$tmp" ||
            fail "could not fetch live appcast: $FEED_URL"
        grep -q "<sparkle:shortVersionString>$EXPECTED_VERSION</sparkle:shortVersionString>" "$tmp" ||
            fail "live appcast does not advertise shortVersionString $EXPECTED_VERSION"
        grep -q "<sparkle:version>$EXPECTED_VERSION</sparkle:version>" "$tmp" ||
            fail "live appcast does not advertise sparkle:version $EXPECTED_VERSION"
        grep -q "https://getstayup.app/StayUp-$EXPECTED_VERSION.dmg" "$tmp" ||
            fail "live appcast enclosure does not point at site-owned StayUp-$EXPECTED_VERSION.dmg"
        grep -q 'sparkle:edSignature="' "$tmp" ||
            fail "live appcast has no Sparkle EdDSA signature"
        grep -q 'length="[0-9][0-9]*"' "$tmp" ||
            fail "live appcast has no enclosure length"
        echo "update preflight: ok (live $EXPECTED_VERSION)"
        ;;
    *)
        fail "unknown mode: $MODE"
        ;;
esac
