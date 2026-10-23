#!/bin/zsh
# Builds Minimalia.app and Minimalia Folio.app next to this script.
#
#   ./build.sh            the release edition: writing, reading and the web
#   ./build.sh full       also Letters (mail), Film and Games
#   ./build.sh install    also copies both apps to /Applications (combine: ./build.sh full install)
#   ./build.sh release    signs with Developer ID, notarizes, and makes build/Minimalia-<version>.dmg
#
# Before the first release, store notarization credentials in the keychain once:
#   xcrun notarytool store-credentials minimalia --apple-id <your Apple ID> --team-id <team ID>
# It asks for an app-specific password from account.apple.com. Set NOTARY_PROFILE to use another name.
set -euo pipefail
cd "$(dirname "$0")"

FULL=0; INSTALL=0; RELEASE=0
for arg in "$@"; do
  case "$arg" in
    full) FULL=1 ;;
    install) INSTALL=1 ;;
    release) RELEASE=1 ;;
    *) echo "Unknown option: $arg (use full, install or release)"; exit 1 ;;
  esac
done

APP="Minimalia.app"
WORD="Minimalia Folio.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
mkdir -p build

# Sign with a stable certificate when there is one, so macOS remembers folder permissions
# between builds. Without it every build looks like a new app and asks again.
IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
SIGN="-"
for want in "Developer ID Application" "Apple Development" "Minimalia Developer"; do
  match=$(echo "$IDS" | grep "$want" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
  if [ -n "$match" ]; then SIGN="$match"; break; fi
done
if [ $RELEASE = 1 ] && [[ "$SIGN" != "Developer ID Application"* ]]; then
  echo "A release needs a Developer ID Application certificate in your keychain."
  echo "Create one in Xcode under Settings, Accounts, Manage Certificates, once you are in the Apple Developer Program."
  exit 1
fi
if [ "$SIGN" = "-" ]; then
  echo "Note: no signing certificate found; signing ad hoc (macOS will ask for folder access again)."
fi

# The hardened runtime is always on, so problems show up in everyday builds before a release.
# A release also gets a secure timestamp, which notarization requires.
SIGN_OPTS=(--force --options runtime --sign "$SIGN")
[ $RELEASE = 1 ] && SIGN_OPTS+=(--timestamp)

for pair in "AppIcon os" "WordIcon word"; do
  name=${pair% *}; variant=${pair#* }
  if [ ! -f Resources/$name.icns ]; then
    rm -rf build/$name.iconset
    swift Tools/make_icon.swift build/$name.iconset $variant
    iconutil -c icns build/$name.iconset -o Resources/$name.icns
  fi
done

# Mail, films and games live in these files. The release edition leaves them out.
EXTRAS=(Sources/LettersProgram.swift Sources/MailCore.swift Sources/GoogleSignIn.swift
        Sources/FilmProgram.swift Sources/GamesProgram.swift Sources/Blocks.swift)
SOURCES=(Sources/*.swift)
FLAGS=()
if [ $FULL = 1 ]; then
  FLAGS=(-D MINIMALIA_EXTRAS)
  echo "Building the full edition, with Letters, Film and Games."
else
  SOURCES=(${SOURCES:|EXTRAS})
fi

swiftc -O -swift-version 5 -target arm64-apple-macos26.0 "${FLAGS[@]}" \
  -o build/Minimalia "${SOURCES[@]}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Minimalia "$APP/Contents/MacOS/Minimalia"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f Resources/Chime.mp3 ] && cp Resources/Chime.mp3 "$APP/Contents/Resources/Chime.mp3"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
# Sacred texts (the Pali Canon, the Qur'an), kept compressed in the repository and unpacked into the app.
for dir in Resources/Canon Resources/Quran; do
  name=$(basename "$dir")
  mkdir -p "$APP/Contents/Resources/$name"
  cp "$dir/index.json" "$APP/Contents/Resources/$name/index.json"
  for gz in "$dir"/*.txt.gz; do
    gzip -dc "$gz" > "$APP/Contents/Resources/$name/$(basename "$gz" .gz)"
  done
done
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --output-partial-info-plist build/assets-info.plist >/dev/null
codesign "${SIGN_OPTS[@]}" "$APP" >/dev/null
echo "Built $APP"

swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  -o "build/Minimalia Folio" WordApp/*.swift
rm -rf "$WORD"
mkdir -p "$WORD/Contents/MacOS" "$WORD/Contents/Resources"
cp "build/Minimalia Folio" "$WORD/Contents/MacOS/Minimalia Folio"
cp Resources/Word-Info.plist "$WORD/Contents/Info.plist"
cp Resources/WordIcon.icns "$WORD/Contents/Resources/WordIcon.icns"
codesign "${SIGN_OPTS[@]}" "$WORD" >/dev/null
echo "Built $WORD"

# A disk image with both apps and a shortcut to Applications, signed, notarized and stapled.
if [ $RELEASE = 1 ]; then
  DMG="build/Minimalia-$VERSION.dmg"
  STAGE="build/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/$APP"
  ditto "$WORD" "$STAGE/$WORD"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Minimalia $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  codesign --force --timestamp --sign "$SIGN" "$DMG"
  echo "Sending $DMG to Apple for notarization. This usually takes a few minutes."
  xcrun notarytool submit "$DMG" --keychain-profile "${NOTARY_PROFILE:-minimalia}" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  echo "Ready to publish: $DMG"
fi

# Install also copies both apps to /Applications and keeps a Desktop alias to Minimalia.
if [ $INSTALL = 1 ]; then
  for app in "$APP" "$WORD"; do
    rm -rf "/Applications/$app"
    ditto "$app" "/Applications/$app"
  done
  if [ ! -e "$HOME/Desktop/Minimalia" ]; then
    osascript -e 'tell application "Finder" to make alias file to POSIX file "/Applications/Minimalia.app" at POSIX file "'"$HOME"'/Desktop"' \
      -e 'tell application "Finder" to set name of result to "Minimalia"' >/dev/null
  fi
  echo "Installed in /Applications"
fi
