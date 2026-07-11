#!/bin/sh
# Regression-test the human release/download handoff.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REDIRECTS="$ROOT/site/_redirects"
RELEASE="$ROOT/tools/release.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

download_line=$(awk '$1 == "/download" { print; found=1 } END { if (!found) exit 1 }' "$REDIRECTS") ||
    fail "site/_redirects must define /download"

case "$download_line" in
    "/download  /StayUp.dmg  302") ;;
    *) fail "/download must point at the site-owned stable /StayUp.dmg asset" ;;
esac

grep -q 'LATEST_DMG="\$DIST/\$APP_NAME.dmg"' "$RELEASE" ||
    fail "release.sh must define the stable StayUp.dmg alias path"
grep -q 'cp "\$DMG" "\$LATEST_DMG"' "$RELEASE" ||
    fail "release.sh must create StayUp.dmg from the notarized versioned DMG"
grep -q 'cp "\$DMG" "\$SITE/\$DMG_FILENAME"' "$RELEASE" ||
    fail "release.sh must copy the versioned DMG into site/ for Pages deploy"
grep -q 'cp "\$LATEST_DMG" "\$SITE/\$APP_NAME.dmg"' "$RELEASE" ||
    fail "release.sh must copy the stable StayUp.dmg alias into site/ for /download"
grep -q 'url="\$DMG_DOWNLOAD_BASE/\$DMG_FILENAME"' "$RELEASE" ||
    fail "release.sh must point Sparkle appcast at the site-owned versioned DMG"

copy_line=$(grep -n 'cp "\$LATEST_DMG" "\$SITE/\$APP_NAME.dmg"' "$RELEASE" | head -1 | cut -d: -f1)
deploy_line=$(grep -n 'wrangler pages deploy' "$RELEASE" | head -1 | cut -d: -f1)

[ -n "$copy_line" ] || fail "missing site DMG copy instruction"
[ -n "$deploy_line" ] || fail "missing site deploy instruction"
[ "$copy_line" -lt "$deploy_line" ] ||
    fail "release instructions must copy StayUp.dmg before deploying site /download"

printf 'test-release-download-workflow: ok\n'
