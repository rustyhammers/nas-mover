#!/bin/sh
# Installs (or reinstalls) the latest NAS Mover into /Applications.
#   curl -fsSL https://raw.githubusercontent.com/rustyhammers/nas-mover/main/install.sh | sh
# After this, the app updates itself (NAS Mover › Check for Updates…).
set -e
REPO="rustyhammers/nas-mover"
DEST="/Applications/NAS Mover.app"

echo "Finding the latest release…"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
	| grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"$/\1/')
[ -n "$URL" ] || { echo "Couldn't find a release to download."; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading $URL"
curl -fL --progress-bar -o "$TMP/NAS-Mover.zip" "$URL"
ditto -x -k "$TMP/NAS-Mover.zip" "$TMP"

if pgrep -xq "NAS Mover"; then
	echo "Quitting the running copy…"
	osascript -e 'quit app "NAS Mover"' >/dev/null 2>&1 || pkill -x "NAS Mover" || true
	sleep 2
fi
rm -rf "$DEST"
ditto "$TMP/NAS Mover.app" "$DEST"
# The app isn't notarized by Apple; clear the download flag so it opens without a Gatekeeper prompt.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
echo "Installed $DEST"
open "$DEST"
