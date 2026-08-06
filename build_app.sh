#!/bin/bash
set -euo pipefail

APP_NAME="HIDTouch Studio"
BUNDLE_NAME="${APP_NAME}.app"
OUTPUT_DIR="./dist"
BUNDLE="${OUTPUT_DIR}/${BUNDLE_NAME}"

# Signing identity, in order of preference:
#   1. SIGN_IDENTITY from the environment (a Developer ID, say)
#   2. the local self-signed certificate, if it is in the keychain
#   3. ad-hoc
#
# Anything other than ad-hoc makes the designated requirement reference the
# certificate instead of the CDHash, so Input Monitoring / Accessibility grants
# survive a rebuild. See README for how to create the local certificate.
LOCAL_IDENTITY="HIDTouch Local Signing"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-certificate -c "${LOCAL_IDENTITY}" >/dev/null 2>&1; then
        SIGN_IDENTITY="${LOCAL_IDENTITY}"
    else
        SIGN_IDENTITY="-"
    fi
fi

echo "=== Building HIDTouch Studio App Bundle ==="
echo "Signing identity: ${SIGN_IDENTITY}"

# 1. Verify the core logic still holds before shipping a bundle
swift run core-selftest

# 2. Swift Release Build
swift build --product hidtouch-studio -c release
BUILD_DIR=$(swift build --show-bin-path -c release)

# 3. Create App Bundle Structure
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

# 4. Copy Executable Binary
cp "${BUILD_DIR}/hidtouch-studio" "${BUNDLE}/Contents/MacOS/TouchStudio"

# 5. Generate Info.plist
cat << 'EOF' > "${BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>TouchStudio</string>
    <key>CFBundleIdentifier</key>
    <string>com.reo.hidtouch.Studio</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>HIDTouch Studio</string>
    <key>CFBundleDisplayName</key>
    <string>HIDTouch Studio</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- Menu bar agent: no Dock icon, and no window at launch. The driver runs
         with no window open, so a Dock tile is only in the way — and an app
         registered to start at login must not deal out a window every time. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSInputMonitoringUsageDescription</key>
    <string>HIDTouch Studio requires Input Monitoring permissions to capture raw USB HID touch screen packets.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>HIDTouch Studio requires Accessibility permissions to post touch and cursor events.</string>
</dict>
</plist>
EOF

# 6. Sign the bundle.
#
# macOS keys Input Monitoring and Accessibility grants to the binary's code
# signature, not its path. With no certificate (ad-hoc, identity "-") the
# designated requirement is the CDHash, which changes on every rebuild — so a
# previously granted permission silently stops applying. Pass SIGN_IDENTITY with
# a real or self-signed certificate to get a requirement that survives rebuilds.
PREVIOUS_CDHASH="$(cat "${OUTPUT_DIR}/.last-cdhash" 2>/dev/null || true)"

codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${BUNDLE}"
codesign --verify --verbose=1 "${BUNDLE}"

CDHASH="$(codesign -dvvv "${BUNDLE}" 2>&1 | sed -n 's/^CDHash=//p')"
# Ad-hoc signatures print "# designated => …"; certificate-backed ones omit the "# ".
REQUIREMENT="$(codesign -d -r- "${BUNDLE}" 2>&1 | sed -n 's/^#* *designated => //p')"
mkdir -p "${OUTPUT_DIR}"
printf '%s' "${CDHASH}" > "${OUTPUT_DIR}/.last-cdhash"

echo ""
echo "=== App bundle: ${BUNDLE} ==="
echo "Designated requirement: ${REQUIREMENT}"
echo ""

case "${REQUIREMENT}" in
  cdhash*)
    if [ -n "${PREVIOUS_CDHASH}" ] && [ "${PREVIOUS_CDHASH}" != "${CDHASH}" ]; then
      echo "!! The code signature CHANGED (${PREVIOUS_CDHASH:0:20}… -> ${CDHASH:0:20}…)."
      echo "!! Input Monitoring / Accessibility grants no longer apply to this build."
      echo "!! In System Settings > Privacy & Security, REMOVE '${APP_NAME}' from both"
      echo "!! lists and add it again — leaving the stale entry enabled will not work."
    else
      echo "Note: ad-hoc signed, so the requirement is the CDHash and every rebuild"
      echo "      invalidates previously granted permissions. Set SIGN_IDENTITY to a"
      echo "      certificate to make grants survive rebuilds (see README)."
    fi
    ;;
  *)
    echo "Signed with a certificate — permission grants survive rebuilds."
    ;;
esac

echo ""
echo "Run it:  open '${BUNDLE}'"
echo "The Dashboard's Permissions section shows the live grant state and this signature."
