#!/bin/bash
# SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds the Mac app for people to install: the release build with the
# engine inside, every program and library in it signed with the hardened
# runtime, a DMG, notarized and stapled when a notary key is given, and the
# Sparkle appcast that offers it as an update. Publishing is a separate,
# printed step (a GitHub release). See README.md "Releasing".
#
#   tool/release_mac.sh
#
# Settings (environment):
#   OSB_SIGN_IDENTITY   certificate to sign with; default: the Keychain's
#                       "Developer ID Application" one. Another (an Apple
#                       Development one) makes a build only this Mac's team
#                       can open, for trying the script.
#   OSB_NOTARY_KEY_ID, OSB_NOTARY_ISSUER, OSB_NOTARY_KEY (the .p8 file)
#                       an App Store Connect API key; or OSB_NOTARY_PROFILE,
#                       a `xcrun notarytool store-credentials` profile.
#                       Neither: the DMG isn't notarized.
#   OSB_UPDATE_KEY_ACCOUNT  the Keychain account of Sparkle's signing key
#                       (default opensportsball-mac).
#   OSB_SKIP_BUILD=1    sign what's already in build/ (for retries).
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

REPO=OpenSportsBall/opensportsball
NAME=$(sed -n 's/^version: *\([0-9.]*\)+\([0-9]*\).*/\1/p' pubspec.yaml)
BUILD=$(sed -n 's/^version: *\([0-9.]*\)+\([0-9]*\).*/\2/p' pubspec.yaml)
[ -n "$NAME" ] && [ -n "$BUILD" ] || die "pubspec.yaml has no version x.y.z+N"
TAG="mac-v$NAME"
# The same name in every release: the website links to
# releases/latest/download/OpenSportsBall.dmg (web/src/lib/site.ts).
DMG_NAME="OpenSportsBall.dmg"
KEY_ACCOUNT=${OSB_UPDATE_KEY_ACCOUNT:-opensportsball-mac}

IDENTITY=${OSB_SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
  sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
[ -n "$IDENTITY" ] || die "no Developer ID Application certificate in the Keychain (README.md \"Releasing\"), and OSB_SIGN_IDENTITY isn't set"
case "$IDENTITY" in "Developer ID Application:"*) ;; *)
  echo "note: signing with \"$IDENTITY\": only Macs that trust it can open this build" ;;
esac

APP=build/macos/Build/Products/Release/OpenSportsBall.app
SPARKLE_BIN=build/macos/SourcePackages/artifacts/sparkle/Sparkle/bin
OUT=build/release
if [ "${OSB_SKIP_BUILD:-}" != 1 ]; then
  say "Building $NAME ($BUILD)"
  flutter build macos --release
fi
[ -x "$APP/Contents/Resources/osb-engine/osb-engine" ] ||
  die "the build has no engine: set OSB_ENGINE_DIR in macos/Runner/Configs/Engine.xcconfig"
INFO="$APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" = "$BUILD" ] ||
  die "the build in $APP isn't $NAME+$BUILD; build again without OSB_SKIP_BUILD"
UPDATE_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO" 2>/dev/null || true)
[ -n "$UPDATE_KEY" ] ||
  echo "note: OSB_UPDATE_PUBLIC_KEY is empty (Runner/Configs/AppInfo.xcconfig): this build won't look for updates"

rm -rf "$OUT"
mkdir -p "$OUT/dmg"
STAGED="$OUT/dmg/OpenSportsBall.app"
ditto "$APP" "$STAGED"

# Signs one file or bundle with the hardened runtime and a secure timestamp
# (both required for notarization).
sign() {
  local log
  log=$(codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@" 2>&1) ||
    { echo "$log" >&2; return 1; }
}
export -f sign
export IDENTITY

say "Signing the engine's programs and libraries"
ENGINE="$STAGED/Contents/Resources/osb-engine"
ENGINE_ENT="$PWD/macos/Engine.entitlements"
LIST="$OUT/machos.txt"
# Every Mach-O file, whatever its name (Python extensions, torch's
# libraries, ffmpeg); programs get the engine's entitlements.
find "$ENGINE" -type f -print0 | xargs -0 file -N -F $'\t' |
  awk -F'\t' '$1 !~ / \(for architecture / && $2 ~ /Mach-O/ && $2 !~ /object/ { print $1 "\t" ($2 ~ /executable/ ? "exe" : "lib") }' > "$LIST"
echo "$(wc -l < "$LIST" | tr -d ' ') files"
# One file first, alone: if the Keychain asks whether codesign may use the
# key, that's one question ("Always Allow") instead of eight at once.
FIRST=$(awk -F'\t' '$2=="lib" {print $1; exit}' "$LIST")
sign "$FIRST"
awk -F'\t' -v first="$FIRST" '$2=="lib" && $1!=first {print $1}' "$LIST" | tr '\n' '\0' | xargs -0 -n 20 -P 8 bash -c 'sign "$@"' _
awk -F'\t' '$2=="exe" {print $1}' "$LIST" | while IFS= read -r f; do
  sign --entitlements "$ENGINE_ENT" "$f"
done

say "Signing Sparkle and the frameworks"
SP="$STAGED/Contents/Frameworks/Sparkle.framework"
if [ -d "$SP" ]; then
  # Sparkle's own order (sparkle-project.org/documentation/sandboxing).
  sign "$SP/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SP/Versions/B/XPCServices/Downloader.xpc"
  sign "$SP/Versions/B/Autoupdate"
  sign "$SP/Versions/B/Updater.app"
  sign "$SP"
fi
for f in "$STAGED"/Contents/Frameworks/*.framework; do
  [ "$f" = "$SP" ] || sign "$f"
done

say "Signing the app"
sign --entitlements macos/Runner/Release.entitlements "$STAGED"
codesign --verify --strict --deep "$STAGED"
hardened() { codesign -dv "$1" 2>&1 | grep 'flags=' | grep -q runtime; }
BAD=$(awk -F'\t' '{print $1}' "$LIST" | while IFS= read -r f; do hardened "$f" || echo "$f"; done)
[ -z "$BAD" ] || die "not signed with the hardened runtime: $BAD"

say "Making $DMG_NAME"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname OpenSportsBall -srcfolder "$OUT/dmg" -fs HFS+ -format ULMO "$OUT/$DMG_NAME"
codesign --force --timestamp --sign "$IDENTITY" "$OUT/$DMG_NAME"
rm -rf "$OUT/dmg"

NOTARIZED=no
if [ -n "${OSB_NOTARY_PROFILE:-}" ]; then
  NOTARY=(--keychain-profile "$OSB_NOTARY_PROFILE")
elif [ -n "${OSB_NOTARY_KEY_ID:-}" ]; then
  NOTARY=(--key "${OSB_NOTARY_KEY:?the .p8 file}" --key-id "$OSB_NOTARY_KEY_ID" --issuer "${OSB_NOTARY_ISSUER:?the key issuer}")
else
  NOTARY=()
fi
if [ ${#NOTARY[@]} -gt 0 ]; then
  say "Notarizing (uploads the DMG to Apple; usually 5-30 minutes)"
  xcrun notarytool submit "$OUT/$DMG_NAME" "${NOTARY[@]}" --wait --output-format json > "$OUT/notary.json" || true
  STATUS=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status",""))' "$OUT/notary.json" 2>/dev/null || true)
  if [ "$STATUS" != Accepted ]; then
    ID=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("id",""))' "$OUT/notary.json" 2>/dev/null || true)
    [ -n "$ID" ] && xcrun notarytool log "$ID" "${NOTARY[@]}" "$OUT/notary-log.json" || true
    die "notarization: ${STATUS:-failed} (log: $OUT/notary-log.json)"
  fi
  xcrun stapler staple "$OUT/$DMG_NAME"
  spctl --assess --type open --context context:primary-signature -v "$OUT/$DMG_NAME"
  NOTARIZED=yes
else
  echo "note: not notarized (no OSB_NOTARY_* settings): Gatekeeper will refuse it on other Macs"
fi

if [ -n "$UPDATE_KEY" ]; then
  say "Writing the appcast"
  # Prints: sparkle:edSignature="..." length="..."
  SIG=$("$SPARKLE_BIN/sign_update" --account "$KEY_ACCOUNT" "$OUT/$DMG_NAME")
  MIN=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")
  cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>OpenSportsBall for Mac</title>
    <item>
      <title>$NAME</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$NAME</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
fi

say "Done: $OUT/$DMG_NAME ($(du -h "$OUT/$DMG_NAME" | cut -f1), notarized: $NOTARIZED)"
if [ "$NOTARIZED" = yes ] && [ -n "$UPDATE_KEY" ]; then
  cat <<TXT
To publish it (the appcast's "latest" link must point at this release, so
no other release in $REPO may be marked latest):
  gh release create $TAG -R $REPO --latest --title "OpenSportsBall for Mac $NAME" \\
    --notes-file <notes.md> "$OUT/$DMG_NAME" "$OUT/appcast.xml"
TXT
fi
