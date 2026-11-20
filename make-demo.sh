#!/bin/zsh
# Renders the README demo from the real engine: docs/demo.mp4 (with the cat's sounds)
# and docs/demo.gif (silent loop). Needs ffmpeg (brew install ffmpeg).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
WORK=$(mktemp -d)
"$(swift build -c release --show-bin-path)/Oneko" --render-demo "$WORK"
mkdir -p docs
ffmpeg -v error -y -framerate 30 -i "$WORK/frames/%04d.png" -i "$WORK/audio.wav" \
    -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 128k -shortest docs/demo.mp4
ffmpeg -v error -y -framerate 30 -i "$WORK/frames/%04d.png" \
    -vf "fps=15,scale=720:-1:flags=neighbor,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
    -loop 0 docs/demo.gif
rm -rf "$WORK"
ls -lh docs/demo.mp4 docs/demo.gif
