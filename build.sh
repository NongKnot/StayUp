#!/bin/bash
# Local dev build for StayUp.
#
# Usage:
#   bash build.sh             # build + sign (offline-friendly, ~2s)
#   bash build.sh notarize    # build + sign + timestamp + notarize +
#                             # staple — produces a fully shippable
#                             # bundle ready to drag into /Applications.
#                             # Requires internet + a notarytool keychain
#                             # profile. Override with STAYUP_NOTARY_PROFILE.
#                             # Takes 1–15 min depending on Apple's queue.
set -e

NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        notarize|--notarize) NOTARIZE=1 ;;
        *) echo "unknown arg: $arg"; exit 1 ;;
    esac
done

APP="StayUp"
BUNDLE="${APP}.app"
KEYCHAIN_PROFILE="${STAYUP_NOTARY_PROFILE:-stayup-notarytool}"

# Lock the binary's LC_BUILD_VERSION minOS to match Info.plist's
# LSMinimumSystemVersion. SMAppService.daemon needs 13+. Apple Silicon
# only — the battery+lid coverage (CGVirtualDisplay + helper daemon) is
# specific to Apple Silicon firmware behaviour.
TARGET="arm64-apple-macos13.0"
export MACOSX_DEPLOYMENT_TARGET=13.0

echo "Building ${APP}..."

swiftc -target "$TARGET" \
    Sources/main.swift \
    Sources/AppDelegate.swift \
    Sources/MenuController.swift \
    Sources/Caffeinate.swift \
    Sources/SleepPreventer.swift \
    Sources/ClosedLidPreventer.swift \
    Sources/VirtualDisplay.swift \
    Sources/StayUpHelper.swift \
    Sources/SleepStackPlanner.swift \
    Sources/SleepStack.swift \
    Sources/PowerSourceMonitor.swift \
    Sources/ActivitySourceMonitor.swift \
    Sources/BundledSources.swift \
    Sources/ActivitySourceHookInstaller.swift \
    Sources/ExternalSourceWatcher.swift \
    Sources/ActivitySourcesPopover.swift \
    Sources/WalkDetector.swift \
    Sources/StepCounter.swift \
    Sources/IconRenderer.swift \
    Sources/DuckSkin.swift \
    Sources/DuckPack.swift \
    Sources/PackUnlocker.swift \
    Sources/Settings.swift \
    Sources/SettingsWindow.swift \
    Sources/WelcomeWindow.swift \
    Sources/SparkleUpdater.swift \
    -import-objc-header Sources/VirtualDisplay-Bridging.h \
    -F Vendor \
    -framework AppKit \
    -framework Foundation \
    -framework IOKit \
    -framework Sparkle \
    -framework UserNotifications \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "${APP}_bin"

rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"
mkdir -p "${BUNDLE}/Contents/Frameworks"
mv "${APP}_bin" "${BUNDLE}/Contents/MacOS/${APP}"
cp Info.plist "${BUNDLE}/Contents/"

# Sparkle.framework — auto-updater. Vendored so a fresh clone can build.
# Embedded into the bundle at @executable_path/../Frameworks/ so the rpath
# set in swiftc resolves at runtime.
cp -R Vendor/Sparkle.framework "${BUNDLE}/Contents/Frameworks/Sparkle.framework"

# App icon — referenced by Info.plist's CFBundleIconFile=AppIcon.
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/"
else
    echo "⚠  Resources/AppIcon.icns missing."
fi

# Activity Source hook script — ActivitySourceHookInstaller copies this out of the bundle
# to ~/.stayup/bin/ at install time.
cp tools/stayup-source-hook.sh "${BUNDLE}/Contents/Resources/"

# Live tester (the "everything" dashboard) — launched from Settings → About by
# clicking Duck's left eye. Pure renderer of ~/.stayup/status.json.
cp tools/stayup.sh "${BUNDLE}/Contents/Resources/"
chmod +x "${BUNDLE}/Contents/Resources/stayup.sh"

echo "Building helper daemon..."
mkdir -p "${BUNDLE}/Contents/MacOS"
swiftc -target "$TARGET" Helper/main.swift \
    -framework Foundation \
    -o "${BUNDLE}/Contents/MacOS/app.getstayup.helper"

# SMAppService bundle layout: the helper Mach-O lives in Contents/MacOS/
# and its launchd plist lives in Contents/Library/LaunchDaemons/. The app
# registers the daemon at runtime via SMAppService.daemon(plistName:);
# macOS groups it under StayUp in System Settings → Login Items rather
# than showing a separate raw label.
echo "Embedding helper plist..."
mkdir -p "${BUNDLE}/Contents/Library/LaunchDaemons"
cp daemon/app.getstayup.helper.plist "${BUNDLE}/Contents/Library/LaunchDaemons/"

# Codesign the bundle. SMAppService requires the helper Mach-O and the
# parent app to share a Developer ID team — without a signature, helper
# registration fails with errSecCSReqFailed (-67056). For dev we sign
# without --timestamp so this works offline. `build.sh notarize` re-signs
# with --timestamp + notarization.
#
# Identity resolution: local dev builds use STAYUP_DEV_ID when set. Otherwise
# they use ad-hoc signatures so `codesign --verify` stays meaningful even when
# the login keychain has stale or intermittently visible Developer ID entries.
# Without Developer ID, Helper setup (SMAppService.daemon) will fail with
# errSecCSReqFailed.
#
# Forkers: install your own Developer ID Application cert via Xcode or
# Apple Developer portal, then opt into it:
# `export STAYUP_DEV_ID="Developer ID Application: Your Name (TEAMID)"`.
sign_adhoc() {
    # No hardened runtime in the ad-hoc fallback: library validation rejects
    # Sparkle at launch without a real Team ID shared by the app + framework.
    codesign --force --deep \
        --sign - \
        "${BUNDLE}/Contents/Frameworks/Sparkle.framework" >/dev/null
    codesign --force \
        --identifier app.getstayup.helper \
        --sign - \
        "${BUNDLE}/Contents/MacOS/app.getstayup.helper" >/dev/null
    codesign --force \
        --sign - \
        "${BUNDLE}/Contents/Resources/stayup-source-hook.sh" >/dev/null
    codesign --force \
        --sign - \
        "${BUNDLE}/Contents/Resources/stayup.sh" >/dev/null
    codesign --force \
        --sign - \
        "${BUNDLE}" >/dev/null
}

DEV_ID="${STAYUP_DEV_ID:-}"
if [ -n "$DEV_ID" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEV_ID"; then
    echo "Codesigning Sparkle.framework + helper + app..."
    # 1) Sparkle.framework first (its XPC services, Autoupdate, Updater.app,
    #    and framework binary). --deep is appropriate here: Sparkle ships
    #    ad-hoc signed and we're re-signing the entire vendor tree with our
    #    Developer ID in one pass. Skipping --deep leaves the nested
    #    binaries ad-hoc signed and the outer app signature fails to seal.
    codesign --force --deep --options runtime \
        --sign "$DEV_ID" \
        "${BUNDLE}/Contents/Frameworks/Sparkle.framework" >/dev/null
    # 2) Helper with its own identifier. If we relied on the outer app's
    #    --deep, the helper would inherit the app's identifier
    #    (app.getstayup), which conflicts with the daemon's launchd Label.
    codesign --force --options runtime \
        --identifier app.getstayup.helper \
        --sign "$DEV_ID" \
        "${BUNDLE}/Contents/MacOS/app.getstayup.helper" >/dev/null
    # Executable resource scripts are also nested code to `codesign --deep`.
    # Sign them before sealing the app, otherwise deep verification fails.
    codesign --force \
        --sign "$DEV_ID" \
        "${BUNDLE}/Contents/Resources/stayup-source-hook.sh" >/dev/null
    codesign --force \
        --sign "$DEV_ID" \
        "${BUNDLE}/Contents/Resources/stayup.sh" >/dev/null
    # 3) Outer app. No --deep — helper + Sparkle are already signed; this
    #    just seals the bundle and validates everything inside.
    codesign --force --options runtime \
        --sign "$DEV_ID" \
        "${BUNDLE}" >/dev/null

    sleep 1
    if ! codesign --verify --deep --strict "${BUNDLE}" >/dev/null 2>&1; then
        echo "⚠  Developer ID signing did not verify — using ad-hoc signatures."
        sign_adhoc
        echo "   App verifies locally, but Settings → General → Helper → Set up + Sparkle updates"
        echo "   still require Developer ID signing."
    fi
else
    echo "⚠  Developer ID Application cert not found — using ad-hoc signatures."
    sign_adhoc
    echo "   App verifies locally, but Settings → General → Helper → Set up + Sparkle updates"
    echo "   still require Developer ID signing."
fi

# ─── Optional: notarize ─────────────────────────────────────────────────
# `bash build.sh notarize` re-signs with --timestamp (Apple needs that
# on a notarization submission), uploads to Apple, waits for the verdict,
# then staples the ticket to the bundle. After this the app passes
# Gatekeeper and SMAppService registration works on any Mac.
if [ "$NOTARIZE" -eq 1 ]; then
    if [ -z "$DEV_ID" ] || ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEV_ID"; then
        echo "✗ Cannot notarize without Developer ID cert in keychain."
        exit 1
    fi
    # Extract Team ID from the resolved Developer ID Application string
    # (the 10-char ID in the parentheses) for the notarytool setup hint.
    TEAM_ID="$(echo "$DEV_ID" | sed -E 's/.*\(([A-Z0-9]+)\).*/\1/')"
    if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
        echo "✗ notarytool keychain profile '$KEYCHAIN_PROFILE' not configured."
        echo "  Store Apple notary credentials in that local keychain profile first."
        exit 1
    fi

    echo ""
    echo "==> Re-signing with --timestamp"
    codesign --force --deep --options runtime --timestamp \
        --sign "$DEV_ID" \
        "${BUNDLE}/Contents/Frameworks/Sparkle.framework" >/dev/null
    codesign --force --options runtime --timestamp \
        --identifier app.getstayup.helper \
        --sign "$DEV_ID" \
        "${BUNDLE}/Contents/MacOS/app.getstayup.helper" >/dev/null
    codesign --force --options runtime --timestamp \
        --sign "$DEV_ID" \
        "${BUNDLE}" >/dev/null

    echo "==> Zipping for submission"
    ZIP="/tmp/${APP}-build.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "${BUNDLE}" "$ZIP"

    echo "==> Submitting to Apple notarization (1–15 min)"
    xcrun notarytool submit "$ZIP" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket"
    xcrun stapler staple "${BUNDLE}"
    xcrun stapler validate "${BUNDLE}"
    rm -f "$ZIP"
fi

echo "Done — built ${BUNDLE}"
echo ""
echo "Install + launch:"
echo "  pkill -x StayUp 2>/dev/null"
echo "  rm -rf /Applications/StayUp.app"
echo "  cp -r ${BUNDLE} /Applications/StayUp.app"
echo "  open /Applications/StayUp.app"
echo ""
echo "Helper: open StayUp Settings → General → Helper → Set up. macOS will ask"
echo "for approval once in System Settings → Login Items."
