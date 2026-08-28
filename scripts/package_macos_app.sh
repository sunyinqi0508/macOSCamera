#!/usr/bin/env bash
# Packages the app.
#   ./scripts/package_macos_app.sh              → dist/Camera for macOS.app (+zip), developer-signed
#   ./scripts/package_macos_app.sh --appstore   → sandboxed, distribution-signed app + installer pkg
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY_NAME="mbCamera"
APP_DISPLAY_NAME="Camera for macOS"
BUNDLE_ID="com.yurika.mbCamera"
APP_DIR="$ROOT_DIR/dist/${APP_DISPLAY_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ENTITLEMENTS="$ROOT_DIR/scripts/appstore.entitlements"

APPSTORE=0
if [[ "${1:-}" == "--appstore" ]]; then
    APPSTORE=1
fi

cd "$ROOT_DIR"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/$BINARY_NAME" "$MACOS_DIR/$BINARY_NAME"
chmod +x "$MACOS_DIR/$BINARY_NAME"

if [[ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    swift "$ROOT_DIR/scripts/generate_app_icon.swift" "$ROOT_DIR/Resources/AppIcon.icns"
fi
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${BINARY_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Camera</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Yinqi Sun. All rights reserved.</string>
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <key>NSCameraUsageDescription</key>
    <string>Camera access is required to show the preview and capture photos and videos.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Microphone access is required to record audio with your videos.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Screen capture access is required to record or photograph your screen.</string>
    <key>NSPhotoLibraryAddUsageDescription</key>
    <string>Photo library access is required to save captures into your Photos library.</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Photo library access is required to save captures into your Photos library.</string>
    <key>NSCameraUseContinuityCameraDeviceType</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "APPL????" > "$CONTENTS_DIR/PkgInfo"

find_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' -v pattern="$1" '$2 ~ pattern { print $2; exit }'
}

if [[ "$APPSTORE" == "1" ]]; then
    # Mac App Store: sandboxed, distribution-signed, delivered as an installer pkg.
    APP_IDENTITY="${MBCAMERA_DIST_IDENTITY:-$(find_identity '^(Apple Distribution|3rd Party Mac Developer Application)')}"
    PKG_IDENTITY="${MBCAMERA_INSTALLER_IDENTITY:-$(security find-identity -v 2>/dev/null \
        | awk -F'"' '$2 ~ /^(Mac Installer Distribution|3rd Party Mac Developer Installer)/ { print $2; exit }')}"

    if [[ -z "$APP_IDENTITY" || -z "$PKG_IDENTITY" ]]; then
        cat >&2 <<'MSG'
error: App Store signing identities not found.

You need, from developer.apple.com (paid Apple Developer account):
  1. An "Apple Distribution" (or "3rd Party Mac Developer Application") certificate
  2. A "Mac Installer Distribution" (or "3rd Party Mac Developer Installer") certificate
  3. A Mac App Store provisioning profile for this bundle id
     (export it and set MBCAMERA_PROVISIONING_PROFILE=/path/to/profile.provisionprofile)

Install the certificates into your keychain, then re-run with --appstore.
MSG
        exit 1
    fi

    if [[ -n "${MBCAMERA_PROVISIONING_PROFILE:-}" ]]; then
        cp "$MBCAMERA_PROVISIONING_PROFILE" "$CONTENTS_DIR/embedded.provisionprofile"
    else
        echo "warning: MBCAMERA_PROVISIONING_PROFILE not set — App Store Connect will reject the upload without an embedded provisioning profile." >&2
    fi

    echo "Signing (App Store) with: $APP_IDENTITY"
    codesign --force --sign "$APP_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DIR"

    PKG_PATH="$ROOT_DIR/dist/CameraForMacOS.pkg"
    rm -f "$PKG_PATH"
    productbuild --component "$APP_DIR" /Applications --sign "$PKG_IDENTITY" "$PKG_PATH"
    printf "Built App Store package: %s\n" "$PKG_PATH"
    printf "Upload with: xcrun altool/notarytool or Transporter.app\n"
else
    if command -v codesign >/dev/null 2>&1; then
        # Sign with a stable identity when one exists. Ad-hoc signatures change on
        # every build, which makes macOS forget TCC grants (screen recording in
        # particular re-prompts after each rebuild).
        SIGN_IDENTITY="${MBCAMERA_SIGN_IDENTITY:-$(find_identity '.')}"

        if [[ -n "$SIGN_IDENTITY" ]]; then
            echo "Signing with identity: $SIGN_IDENTITY"
            codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR" || {
                echo "warning: signing with '$SIGN_IDENTITY' failed; falling back to ad-hoc." >&2
                codesign --force --sign - "$APP_DIR"
            }
        else
            echo "warning: no codesigning identity found; using an ad-hoc signature." >&2
            echo "         Screen-recording permission will re-prompt after every rebuild." >&2
            codesign --force --sign - "$APP_DIR"
        fi
    fi

    ZIP_PATH="$ROOT_DIR/dist/Camera-for-macOS.zip"
    rm -f "$ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
    printf "Built zip package: %s\n" "$ZIP_PATH"
fi

printf "Built app bundle: %s\n" "$APP_DIR"
