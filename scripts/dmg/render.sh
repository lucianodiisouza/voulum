#!/usr/bin/env bash
#
# render.sh — turn background.svg into the 1x and 2x PNGs the DMG uses.
# Only needed after editing the SVG; the PNGs are committed so release
# builds don't depend on a browser. Uses headless Google Chrome.
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[[ -x "$CHROME" ]] || { echo "Google Chrome not found (set CHROME)" >&2; exit 1; }

for scale in 1 2; do
  out="${DIR}/background.png"
  [[ $scale == 2 ]] && out="${DIR}/background@2x.png"
  "$CHROME" --headless --disable-gpu --hide-scrollbars \
    --default-background-color=00000000 \
    --force-device-scale-factor="$scale" --window-size=660,400 \
    --screenshot="$out" "file://${DIR}/background.svg" 2>/dev/null
  echo "$out"
done
