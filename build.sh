#!/bin/zsh
# Builds Minimalia.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="Minimalia.app"
mkdir -p build

# Sign with a stable certificate when there is one, so macOS remembers folder permissions
# between builds. Without it every build looks like a new app and asks again.
IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
SIGN="-"
for want in "Developer ID Application" "Apple Development" "Minimalia Developer"; do
  match=$(echo "$IDS" | grep "$want" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
  if [ -n "$match" ]; then SIGN="$match"; break; fi
done
if [ "$SIGN" = "-" ]; then
  echo "Note: no signing certificate found; signing ad hoc (macOS will ask for folder access again)."
fi

for pair in "AppIcon os" "WordIcon word"; do
  name=${pair% *}; variant=${pair#* }
  if [ ! -f Resources/$name.icns ]; then
    rm -rf build/$name.iconset
    swift Tools/make_icon.swift build/$name.iconset $variant
    iconutil -c icns build/$name.iconset -o Resources/$name.icns
  fi
done

swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  -o build/Minimalia Sources/*.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Minimalia "$APP/Contents/MacOS/Minimalia"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f Resources/Chime.mp3 ] && cp Resources/Chime.mp3 "$APP/Contents/Resources/Chime.mp3"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --output-partial-info-plist build/assets-info.plist >/dev/null
codesign --force --sign "$SIGN" "$APP" >/dev/null
echo "Built $APP"

WORD="Minimalia Folio.app"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  -o "build/Minimalia Folio" WordApp/*.swift
rm -rf "$WORD"
mkdir -p "$WORD/Contents/MacOS" "$WORD/Contents/Resources"
cp "build/Minimalia Folio" "$WORD/Contents/MacOS/Minimalia Folio"
cp Resources/Word-Info.plist "$WORD/Contents/Info.plist"
cp Resources/WordIcon.icns "$WORD/Contents/Resources/WordIcon.icns"
codesign --force --sign "$SIGN" "$WORD" >/dev/null
echo "Built $WORD"

# ./build.sh install also copies both apps to /Applications and keeps a Desktop alias to Minimalia.
if [ "${1:-}" = "install" ]; then
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
