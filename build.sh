#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="AutoBrightness.app"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/autobrightness-build.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
if [ ! -f artwork/AutoBrightness.icns ] || [ artwork/draw-icon.m -nt artwork/AutoBrightness.icns ] || [ build.sh -nt artwork/AutoBrightness.icns ]; then
  xcrun clang -fobjc-arc -Os -Wall -Wextra -Werror -framework AppKit artwork/draw-icon.m -o "$temporary/icon"
  "$temporary/icon" "$temporary/png"
  mkdir "$temporary/AutoBrightness.iconset"
  for size in 16 32; do
    cp "$temporary/png/autobrightness-$size.png" "$temporary/AutoBrightness.iconset/icon_${size}x${size}.png"
    double=$((size * 2))
    cp "$temporary/png/autobrightness-$double.png" "$temporary/AutoBrightness.iconset/icon_${size}x${size}@2x.png"
  done
  cp "$temporary/png/autobrightness-128.png" "$temporary/AutoBrightness.iconset/icon_128x128.png"
  cp "$temporary/png/autobrightness-128.png" artwork/autobrightness-128.png
  iconutil -c icns "$temporary/AutoBrightness.iconset" -o artwork/AutoBrightness.icns
fi
xcrun clang -arch arm64 -fobjc-arc -Os -DNDEBUG -Wall -Wextra -Werror \
  -mmacosx-version-min=26.4 -framework AppKit -framework QuartzCore -framework IOSurface \
  src/main.m -Wl,-dead_strip -o "$temporary/AutoBrightness"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
mv "$temporary/AutoBrightness" "$app/Contents/MacOS/AutoBrightness"
cp Info.plist "$app/Contents/Info.plist"
cp artwork/AutoBrightness.icns "$app/Contents/Resources/AutoBrightness.icns"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf 'Built %s/%s\n' "$PWD" "$app"
