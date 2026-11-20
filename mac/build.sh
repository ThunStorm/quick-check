#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

sdk=$(xcrun --sdk macosx --show-sdk-path)
target="$(uname -m)-apple-macosx15.0"
mkdir -p dist
staging=$(mktemp -d dist/.quick-check.XXXXXX)
trap 'rm -rf "$staging"' EXIT

app="$staging/Quick Check.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
gzip -dc Resources/dictionary.sqlite3.gz > "$app/Contents/Resources/dictionary.sqlite3"
cp Resources/DICTIONARY_LICENSE.md "$app/Contents/Resources/"
xcrun swiftc -O -target "$target" -sdk "$sdk" Sources/*.swift -o "$app/Contents/MacOS/QuickCheck"
/usr/bin/codesign --force --sign "${QUICK_CHECK_SIGN_IDENTITY:--}" "$app"
/usr/bin/codesign --verify --strict "$app"
rm -rf "dist/Quick Check.app"
mv "$app" "dist/Quick Check.app"
echo "$PWD/dist/Quick Check.app"
