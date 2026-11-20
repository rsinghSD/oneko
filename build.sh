#!/bin/zsh
# Builds build/Oneko.app from the Swift package.
# Usage: ./build.sh            build only
#        ./build.sh --run      build and launch from build/
#        ./build.sh --install  build, copy to /Applications and launch (use this for Launch at Login)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Oneko"

APP=build/Oneko.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Oneko"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/oneko.gif Resources/oneko.js-LICENSE.txt "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1   # ad-hoc sign so it launches cleanly

echo "Built $APP"

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
esac
