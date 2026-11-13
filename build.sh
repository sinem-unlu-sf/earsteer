#!/bin/zsh
# Builds Earsteer.app from the Swift sources using only Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Earsteer.app
BUNDLE_ID=io.github.sinem-unlu-sf.earsteer
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -target arm64-apple-macosx14.0 \
  -framework AppKit -framework CoreMotion -framework CoreGraphics \
  -framework ApplicationServices \
  Sources/Earsteer/*.swift \
  -o "$APP/Contents/MacOS/Earsteer"

cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc sign, but with a designated requirement based on the bundle ID instead of
# the binary hash. That way macOS privacy grants (Accessibility, Motion) keep
# matching the app after every rebuild.
codesign --force --sign - --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$APP"

echo "Built $APP"
