#!/bin/sh
# Builds, copies the app to /Applications and opens it. On its first launch from there the app
# registers itself as a login item (once); remove it in System Settings → General → Login Items.
set -eu
cd "$(dirname "$0")"
./build.sh
pkill -x AutoBrightness 2>/dev/null || true
sleep 1
rm -rf /Applications/AutoBrightness.app
ditto AutoBrightness.app /Applications/AutoBrightness.app
codesign --verify --strict /Applications/AutoBrightness.app
open /Applications/AutoBrightness.app
printf 'Installed and started /Applications/AutoBrightness.app\n'
