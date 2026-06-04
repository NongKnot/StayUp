#!/bin/bash
# StayUp release pipeline.
#
# One command: build → codesign → notarize → staple → DMG.
# Output: dist/StayUp-<version>.dmg, ready to upload to getstayup.app.
#
# Prerequisites (one-time):
#   1. Developer ID Application certificate imported into login.keychain.
#      Verify with: security find-identity -v -p codesigning
#   2. Apple notary credentials stored in a local keychain profile whose name
#      matches $KEYCHAIN_PROFILE below.
#
#      Find your Team ID in Apple Developer portal → Membership, or via
#      `security find-identity -v -p codesigning` (the 10-char string in
#      the parentheses of your "Developer ID Application" identity).
#
# Usage:
#   bash tools/release.sh

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────
APP_NAME="StayUp"
BUNDLE_ID="app.getstayup"
KEYCHAIN_PROFILE="${STAYUP_NOTARY_PROFILE:-stayup-notarytool}"
DOWNLOAD_BASE="https://getstayup.app"

# Identity resolution: STAYUP_DEV_ID env var wins if set, otherwise
# auto-detect the first "Developer ID Application" cert from the keychain.
# Forkers: install your own Developer ID Application cert (Apple Developer
# portal); the script discovers it automatically. To pin a specific cert
# in environments with several, `export STAYUP_DEV_ID="Developer ID
# Application: Your Name (TEAMID)"` before running.
DEV_ID="${STAYUP_DEV_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"Developer ID Application:[^"]+"' \
    | head -1 | tr -d '"')}"
if [ -z "$DEV_ID" ]; then
    echo "✗ No 'Developer ID Application' certificate in keychain."
    echo "  Install one via Apple Developer portal, or set STAYUP_DEV_ID."
    exit 1
fi
# Extract Team ID from the cert string (the 10-char ID in parentheses).
TEAM_ID="$(echo "$DEV_ID" | sed -E 's/.*\(([A-Z0-9]+)\).*/\1/')"

# The appcast enclosure points at the GitHub Release asset. Override this when
# publishing to a new repo:
#   STAYUP_GH_REPO=owner/repo bash tools/release.sh
GH_REPO="${STAYUP_GH_REPO:-NongKnot/StayUp}"
DMG_DOWNLOAD_BASE="https://github.com/$GH_REPO/releases/download"

# ─── Paths ──────────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT_ROOT/$APP_NAME.app"
HELPER="$APP/Contents/MacOS/app.getstayup.helper"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
DIST="$PROJECT_ROOT/dist"
SITE="$PROJECT_ROOT/site"
APPCAST="$SITE/appcast.xml"
SIGN_UPDATE="$PROJECT_ROOT/Vendor/Sparkle-bin/sign_update"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_ROOT/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PROJECT_ROOT/Info.plist")
DMG="$DIST/$APP_NAME-$VERSION.dmg"

# ─── Sanity checks ──────────────────────────────────────────────────────
echo "==> Pre-flight checks"
if ! security find-identity -v -p codesigning | grep -q "$DEV_ID"; then
    echo "✗ Developer ID Application certificate not found in keychain."
    echo "  Expected: $DEV_ID"
    echo "  Run: security find-identity -v -p codesigning"
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    echo "✗ notarytool keychain profile '$KEYCHAIN_PROFILE' not configured."
    echo "  Store Apple notary credentials in that local keychain profile first."
    exit 1
fi
if [ ! -x "$SIGN_UPDATE" ]; then
    echo "✗ Sparkle's sign_update tool not found at $SIGN_UPDATE"
    echo "  Run: download Sparkle from https://github.com/sparkle-project/Sparkle/releases"
    echo "  and place Sparkle.framework + bin/ into Vendor/"
    exit 1
fi
if ! "$SIGN_UPDATE" --version >/dev/null 2>&1; then
    # sign_update fails to read the EdDSA private key from keychain if the
    # key was generated on a different macOS user account or was deleted.
    # The tool itself runs even without a key (--version works), so we
    # don't fail pre-flight here — sign_update <dmg> below will raise.
    :
fi
echo "✓ Developer ID found"
echo "✓ notarytool credentials cached"
echo "✓ Sparkle sign_update available"

# ─── Build ──────────────────────────────────────────────────────────────
echo ""
echo "==> Building $APP_NAME $VERSION"
cd "$PROJECT_ROOT"
bash build.sh >/dev/null

# ─── Replace Sparkle.framework with a fresh copy ────────────────────────
# build.sh signs Sparkle with --deep (no timestamp) for the offline dev
# loop. Apple's notary rejects layered signatures, so blow away the
# bundled Sparkle.framework and copy a fresh adhoc-signed copy from
# Vendor/ before re-signing.
echo ""
echo "==> Replacing Sparkle.framework with fresh copy from Vendor/"
rm -rf "$SPARKLE"
cp -R "$PROJECT_ROOT/Vendor/Sparkle.framework" "$SPARKLE"

# ─── Sign Sparkle per the official Sparkle 2.x docs ─────────────────────
# Exact sequence from https://sparkle-project.org/documentation/sandboxing/.
# Two specifics worth knowing:
#  1) ONLY Downloader.xpc gets --preserve-metadata=entitlements. The
#     XPC service may optionally be signed with a sandbox entitlement;
#     Installer.xpc never has one. Applying --preserve-metadata to
#     Installer.xpc copies-over empty entitlements and breaks the
#     signature in a way local codesign --verify can't catch but
#     Apple's notary will reject.
#  2) Do NOT explicitly sign Versions/B/Sparkle (the framework binary).
#     Signing the framework wrapper at the end handles it correctly.
#     An explicit binary-sign step here causes hash mismatches that
#     the notary rejects.
echo ""
echo "==> Signing Sparkle.framework (per official Sparkle docs)"
SPARKLE_VB="$SPARKLE/Versions/B"
echo "    Installer.xpc"
codesign -f -s "$DEV_ID" -o runtime --timestamp \
    "$SPARKLE_VB/XPCServices/Installer.xpc"
echo "    Downloader.xpc (--preserve-metadata=entitlements)"
codesign -f -s "$DEV_ID" -o runtime --timestamp \
    --preserve-metadata=entitlements \
    "$SPARKLE_VB/XPCServices/Downloader.xpc"
echo "    Autoupdate"
codesign -f -s "$DEV_ID" -o runtime --timestamp \
    "$SPARKLE_VB/Autoupdate"
echo "    Updater.app"
codesign -f -s "$DEV_ID" -o runtime --timestamp \
    "$SPARKLE_VB/Updater.app"
echo "    Sparkle.framework"
codesign -f -s "$DEV_ID" -o runtime --timestamp \
    "$SPARKLE"

# ─── Sign helper with its own identifier ────────────────────────────────
echo ""
echo "==> Signing helper binary"
codesign -f -s "$DEV_ID" -o runtime --timestamp \
    --identifier app.getstayup.helper \
    "$HELPER"

# ─── Sign main app binary explicitly, then seal the bundle ──────────────
# Bottom-up signing: main executable first, then the bundle wrapper.
# This is what the general macOS guidance recommends; signing the
# bundle alone has been observed to leave the main binary's signature
# in a state Apple's notary rejects as invalid.
echo ""
echo "==> Signing main app binary"
codesign -f -s "$DEV_ID" -o runtime --timestamp \
    "$APP/Contents/MacOS/$APP_NAME"

echo ""
echo "==> Signing executable resource scripts"
codesign -f -s "$DEV_ID" --timestamp \
    "$APP/Contents/Resources/stayup-source-hook.sh"
codesign -f -s "$DEV_ID" --timestamp \
    "$APP/Contents/Resources/stayup.sh"

echo ""
echo "==> Sealing app bundle"
codesign -f -s "$DEV_ID" -o runtime --timestamp \
    "$APP"

# ─── Verify signatures ──────────────────────────────────────────────────
echo ""
echo "==> Verifying signatures"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | head -8

# Gatekeeper assessment is informational only here — apps can fail this
# pre-notarization and still pass post-notarization. The real test is
# `xcrun stapler validate` after stapling.
echo ""
echo "==> Pre-notarization Gatekeeper check (will fail until notarized)"
spctl --assess --type execute --verbose "$APP" 2>&1 | head -3 || true

# ─── Build DMG ──────────────────────────────────────────────────────────
# Two-pass DMG creation:
#   1. Create a read-write DMG (UDRW) so we can mount it, drop a custom
#      background image into .background/, and run AppleScript to set
#      window size + icon positions + hide the toolbar/sidebar.
#   2. Convert it to a compressed read-only DMG (UDZO) for shipping.
#
# Use `ditto` (NOT `cp -r`) for staging the .app. cp -r silently
# corrupts Sparkle.framework's nested symlinks in a way local
# codesign --verify cannot detect but Apple's notary rejects with
# "The signature of the binary is invalid." (5 attempts to find this.)
echo ""
echo "==> Staging DMG contents"
rm -rf "$DIST"
mkdir -p "$DIST"
DMG_STAGE="$DIST/dmg-stage"
mkdir -p "$DMG_STAGE/.background"
ditto "$APP" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
if [ -f "$PROJECT_ROOT/assets/dmg-bg.png" ]; then
    cp "$PROJECT_ROOT/assets/dmg-bg.png" "$DMG_STAGE/.background/dmg-bg.png"
else
    echo "⚠  assets/dmg-bg.png missing — run: bash tools/make-dmg-bg.sh"
    echo "   Continuing with an unstyled DMG."
fi

echo "==> Creating read-write DMG for styling"
VOLUME_NAME="Stay Up Duck"
DMG_RW="$DIST/$APP_NAME-rw.dmg"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_STAGE" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size 50m \
    -ov "$DMG_RW" >/dev/null

MOUNT_POINT="/Volumes/$VOLUME_NAME"
hdiutil attach "$DMG_RW" \
    -readwrite -noverify -noautoopen \
    -mountpoint "$MOUNT_POINT" >/dev/null

echo "==> Styling DMG window (AppleScript)"
# Window 540×380; icons at (150, 200) and (390, 200); background image
# from the hidden .background folder. The `update without registering`
# flush is critical — without it the changes don't write to .DS_Store.
osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 100, 740, 480}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 12
        try
            set background picture of viewOptions to file ".background:dmg-bg.png"
        end try
        set position of item "$APP_NAME.app" of container window to {150, 200}
        set position of item "Applications" of container window to {390, 200}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Flush the .DS_Store to disk before detach. Without this, the DMG
# unmounts before Finder's view options write back, and the styling
# is lost in the final compressed DMG.
sync
sleep 1
hdiutil detach "$MOUNT_POINT" >/dev/null

echo "==> Compressing DMG (UDZO)"
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$DMG_RW"
rm -rf "$DMG_STAGE"

# Sign the DMG itself so Safari's "Open Safely" trusts it.
echo "==> Signing DMG"
codesign --force --sign "$DEV_ID" --timestamp "$DMG"

# ─── Notarize ───────────────────────────────────────────────────────────
echo ""
echo "==> Submitting to Apple notarization (1–15 minutes)"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

# ─── Staple ─────────────────────────────────────────────────────────────
echo ""
echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ─── Sparkle: sign DMG + generate appcast.xml ───────────────────────────
# Sign the notarized + stapled DMG with the EdDSA private key (stored in
# the macOS keychain, paired with the SUPublicEDKey in Info.plist).
# sign_update prints `sparkle:edSignature="…" length="…"` — exactly the
# two attributes the <enclosure> tag in appcast.xml needs.
echo ""
echo "==> Signing DMG for Sparkle appcast"
SIGN_OUTPUT=$("$SIGN_UPDATE" "$DMG")
echo "    $SIGN_OUTPUT"

# Pull the CHANGELOG section for this version (between `## [VERSION]` and
# the next `## [` heading). Used as the human-readable release notes
# embedded in the appcast item.
CHANGELOG_NOTES=$(awk -v v="$VERSION" '
    $0 ~ "^## \\[" v "\\]" { flag = 1; next }
    flag && /^## \[/ { exit }
    flag
' "$PROJECT_ROOT/CHANGELOG.md")

PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
DMG_FILENAME=$(basename "$DMG")
DMG_LENGTH=$(stat -f%z "$DMG")

# Write the full appcast.xml. For a single-version release feed this
# overwrites whatever's there; when 1.0.1 ships we either prepend a new
# <item> manually or switch to Sparkle's generate_appcast tool.
mkdir -p "$SITE"
echo "==> Writing $APPCAST"
cat > "$APPCAST" <<APPCAST_EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>$APP_NAME</title>
        <link>$DOWNLOAD_BASE/appcast.xml</link>
        <description>$APP_NAME release feed. Updates verified via EdDSA against the SUPublicEDKey embedded in the app.</description>
        <language>en</language>
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <description><![CDATA[
$CHANGELOG_NOTES
            ]]></description>
            <enclosure
                url="$DMG_DOWNLOAD_BASE/v$VERSION/$DMG_FILENAME"
                $SIGN_OUTPUT
                type="application/octet-stream"/>
        </item>
    </channel>
</rss>
APPCAST_EOF

# ─── Done ───────────────────────────────────────────────────────────────
echo ""
echo "==> ✓ Release built"
echo "    File:    $DMG"
echo "    Size:    $(du -sh "$DMG" | cut -f1)"
echo "    SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "    Appcast: $APPCAST"
echo ""
echo "Ship via wrangler (uploads BOTH the DMG and the appcast):"
echo "  cp \"$DMG\" \"$SITE/$DMG_FILENAME\""
echo "  cd \"$SITE\" && wrangler pages deploy . --project-name=getstayup --branch=main"
echo ""
echo "Then create/replace the GitHub Release:"
echo "  gh release upload v$VERSION \"$DMG\" --repo $GH_REPO --clobber"
