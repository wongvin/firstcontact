#!/usr/bin/env bash
#
# Rasterise the generated SVGs into the 1024x1024 PNGs the asset catalog wants,
# and copy them into AppIcon.appiconset.
#
# Chrome is used as the rasteriser because macOS ships no SVG CLI converter and
# this repo has no Node/Python image stack. It resolves Menlo for the binary
# digits, which is why the SVGs can keep them as live text rather than outlines.
#
# Usage: ios/Sophon/icon/render.sh

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/../Sophon/Assets.xcassets/AppIcon.appiconset"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

if [[ ! -x "$CHROME" ]]; then
  echo "error: Google Chrome not found at $CHROME" >&2
  echo "       it is used only as an SVG rasteriser; any replacement that can" >&2
  echo "       render SVG to a 1024x1024 PNG will do." >&2
  exit 1
fi

python3 "$DIR/sophon-icon.py"

for v in light dark tinted; do
  # Chrome screenshots a page, not a file, so the SVG is wrapped to pin it to
  # exactly 1024x1024 with no margin or scrollbar.
  cat > "$DIR/.wrap-$v.html" <<HTML
<html><head><style>html,body{margin:0;padding:0;background:#000}
img{display:block;width:1024px;height:1024px}</style></head>
<body><img src="sophon-$v.svg"></body></html>
HTML
  # Rendered straight into the asset catalog. Writing an intermediate here and
  # copying would leave a second, identical set of PNGs under version control.
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --screenshot="$OUT/icon-$v.png" --window-size=1024,1024 \
    "file://$DIR/.wrap-$v.html" 2>/dev/null
  rm -f "$DIR/.wrap-$v.html"

  echo "  icon-$v.png  $(sips -g pixelWidth -g pixelHeight "$OUT/icon-$v.png" | awk '/pixel/{printf "%s ", $2}')"
done

echo "-> $OUT"
