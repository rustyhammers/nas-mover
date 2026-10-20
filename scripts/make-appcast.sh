#!/bin/sh
# Signs dist/NAS-Mover-<version>.zip with the Sparkle EdDSA key and writes dist/appcast.xml + dist/notes.md.
# Usage: SPARKLE_PRIVATE_KEY=... scripts/make-appcast.sh <version>
# (or SPARKLE_KEY_FILE=path for a local run)
set -e
cd "$(dirname "$0")/.."

VERSION="$1"
[ -n "$VERSION" ] || { echo "usage: $0 <version>"; exit 1; }
REPO="rustyhammers/nas-mover"
SPARKLE_VERSION="2.10.0"
ZIP="dist/NAS-Mover-$VERSION.zip"
[ -f "$ZIP" ] || { echo "missing $ZIP (run PACKAGE=1 ./build.sh first)"; exit 1; }

TOOLS=$(mktemp -d)
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" | tar -xJf - -C "$TOOLS"

KEY_FILE="$SPARKLE_KEY_FILE"
if [ -z "$KEY_FILE" ]; then
	[ -n "$SPARKLE_PRIVATE_KEY" ] || { echo "SPARKLE_PRIVATE_KEY is not set"; exit 1; }
	KEY_FILE="$TOOLS/key"
	printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
fi
SIG=$("$TOOLS/bin/sign_update" -f "$KEY_FILE" -p "$ZIP")
rm -f "$TOOLS/key"
LENGTH=$(stat -f %z "$ZIP")
BUILD=$(echo "$VERSION" | awk -F. '{ printf "%d", ($1 * 1000000) + ($2 * 1000) + $3 }')
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

# Release notes come from the annotated tag message.
git tag -l --format='%(contents)' "v$VERSION" | sed '/^-----BEGIN PGP/,$d' > dist/notes.md
[ -s dist/notes.md ] || echo "NAS Mover $VERSION" > dist/notes.md
NOTES_HTML=$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/^[-*] \(.*\)/<li>\1<\/li>/' -e 's/$/<br>/' dist/notes.md)

cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NAS Mover</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$DATE</pubDate>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/NAS-Mover-$VERSION.zip"
                 length="$LENGTH" type="application/octet-stream"
                 sparkle:edSignature="$SIG"/>
    </item>
  </channel>
</rss>
EOF
rm -rf "$TOOLS"
echo "Wrote dist/appcast.xml for $VERSION (build $BUILD)"
