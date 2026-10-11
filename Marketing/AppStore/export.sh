#!/bin/zsh
# Renders every slide to PNG at App Store resolution with headless Chrome:
#   export/en-US/*.png and export/de-DE/*.png (folder names match fastlane deliver locales).
# iPhone 6.9": 1320 × 2868, iPad 13" (landscape): 2752 × 2064.
set -euo pipefail
cd "$(dirname "$0")"

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
ids=(${(f)"$(grep -oE '^    id: "[a-z0-9-]+"' slides.js | sed -E 's/.*id: "(.*)"/\1/')"})

for lang locale in en en-US de de-DE; do
  out="export/$locale"
  mkdir -p "$out"
  for id in $ids; do
    if [[ $id == ipad-* ]]; then size="2752,2064"; else size="1320,2868"; fi
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
      --allow-file-access-from-files --virtual-time-budget=4000 \
      --window-size="$size" --screenshot="$PWD/$out/$id.png" \
      "file://$PWD/index.html?lang=$lang&slide=$id" >/dev/null 2>&1
    echo "$out/$id.png"
  done
done
