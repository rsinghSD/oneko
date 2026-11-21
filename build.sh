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

# Compiles with swiftc directly: it's one target with no dependencies, and this way a
# SwiftPM hiccup (like the manifest hang after the Swift 6.4 update) can't block a build.
# No whole-module optimization: Swift 6.4.2 hangs on it for this project.
compile() {   # compile <arch> <output>
    xcrun swiftc -O -j8 -target "$1-apple-macos13.0" -module-name Oneko \
        Sources/Oneko/*.swift -o "$2"
}

mkdir -p build/bin
if [[ "${1:-}" == "--dmg" ]]; then
    compile arm64 build/bin/Oneko-arm64
    compile x86_64 build/bin/Oneko-x86_64
    lipo -create build/bin/Oneko-arm64 build/bin/Oneko-x86_64 -output build/bin/Oneko
else
    compile "$(uname -m)" build/bin/Oneko
fi
BIN=build/bin/Oneko

APP=build/Oneko.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Oneko"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/oneko.gif Resources/oneko.js-LICENSE.txt Resources/AppIcon.icns Resources/meow.m4a "$APP/Contents/Resources/"
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
