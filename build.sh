#!/bin/sh
# Builds "NAS Mover.app" (and optionally a release zip) next to this script.
#
#   ./build.sh                      local build for this Mac
#   VERSION=1.2.0 ./build.sh        set the version (defaults to the latest git tag)
#   UNIVERSAL=1 ./build.sh          Apple silicon + Intel (needs full Xcode; used by CI)
#   PACKAGE=1 ./build.sh            also write dist/NAS-Mover-<version>.zip
set -e
cd "$(dirname "$0")"

REPO="rustyhammers/nas-mover"
BUNDLE_ID="com.diamondlakeproductions.nasmover"
APP="NAS Mover.app"

if [ -z "$VERSION" ]; then
	VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
	[ -n "$VERSION" ] || VERSION="0.0.0"
fi
# Sparkle compares CFBundleVersion, so derive a monotonically increasing number from the semver.
BUILD=$(echo "$VERSION" | awk -F. '{ printf "%d", ($1 * 1000000) + ($2 * 1000) + $3 }')
PUBKEY=$(cat Resources/sparkle_public_key.txt)

if [ -n "$UNIVERSAL" ]; then
	swift build -c release --arch arm64 --arch x86_64
	BIN=.build/apple/Products/Release/NASMover
else
	swift build -c release
	BIN=.build/release/NASMover
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/NAS Mover"
cp Resources/runner.sh Resources/excludes.txt Resources/AppIcon.icns "$APP/Contents/Resources/"
SPARKLE=$(find .build/artifacts -type d -path "*Sparkle.xcframework/macos-*/Sparkle.framework" | head -1)
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>NAS Mover</string>
	<key>CFBundleDisplayName</key><string>NAS Mover</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key><string>NAS Mover</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSLocalNetworkUsageDescription</key><string>NAS Mover connects to your QNAP and UNAS over SSH to browse folders and run transfers.</string>
	<key>SUFeedURL</key><string>https://github.com/$REPO/releases/latest/download/appcast.xml</string>
	<key>SUPublicEDKey</key><string>$PUBKEY</string>
	<key>SUEnableAutomaticChecks</key><true/>
	<key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
EOF

# Ad-hoc signature with a fixed designated requirement, so macOS permissions (Local Network)
# and Sparkle see every version as the same app. Update integrity comes from Sparkle's EdDSA signature.
REQ="designated => identifier \"$BUNDLE_ID\""
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$FW/XPCServices/Installer.xpc" "$FW/XPCServices/Downloader.xpc" "$FW/Autoupdate" "$FW/Updater.app"; do
	[ -e "$item" ] && codesign --force --sign - "$item"
done
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - -r="$REQ" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $(pwd)/$APP (version $VERSION, build $BUILD)"

if [ -n "$PACKAGE" ]; then
	mkdir -p dist
	ZIP="dist/NAS-Mover-$VERSION.zip"
	rm -f "$ZIP"
	ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
	echo "Packaged $ZIP"
fi
