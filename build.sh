#!/bin/zsh
# Builds build/Oneko.app from the Swift package.
# Usage: ./build.sh            build only (this Mac's architecture)
#        ./build.sh --run      build and launch from build/
#        ./build.sh --install  build, copy to /Applications and launch (use this for Launch at Login)
#        ./build.sh --dmg      universal build (Apple silicon + Intel), build/Oneko-<version>.dmg,
#                              and the Homebrew cask in Casks/oneko.rb
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

if [[ "${1:-}" == "--dmg" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Oneko"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/Oneko"
fi

APP=build/Oneko.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Oneko"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/oneko.gif Resources/oneko.js-LICENSE.txt Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1   # ad-hoc sign so it launches cleanly

echo "Built $APP ($VERSION)"

stop_running() {
    pkill -x Oneko 2>/dev/null || return 0
    while pgrep -x Oneko >/dev/null; do sleep 0.1; done
    sleep 0.5   # let LaunchServices notice it's gone, or `open` fails with -600
}

case "${1:-}" in
    --run)
        stop_running
        open "$APP"
        ;;
    --install)
        stop_running
        rm -rf /Applications/Oneko.app
        cp -R "$APP" /Applications/Oneko.app
        echo "Installed /Applications/Oneko.app"
        open /Applications/Oneko.app
        ;;
    --dmg)
        DMG="build/Oneko-$VERSION.dmg"
        STAGE=$(mktemp -d)
        cp -R "$APP" "$STAGE/"
        ln -s /Applications "$STAGE/Applications"      # drag-to-install
        rm -f "$DMG"
        hdiutil create -volname "Oneko $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
        rm -rf "$STAGE"
        SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
        mkdir -p Casks
        sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$SHA/g" Resources/oneko.rb.template > Casks/oneko.rb
        echo "Built $DMG"
        echo "sha256 $SHA"
        echo "Wrote Casks/oneko.rb"
        ;;
esac
