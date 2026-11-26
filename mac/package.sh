#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

./build.sh --universal
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
name="Quick-Check-$version-macOS-universal.dmg"
staging=$(mktemp -d "$PWD/dist/.quick-check-package.XXXXXX")
mount=$(mktemp -d "${TMPDIR:-/tmp}/quick-check-mount.XXXXXX")
mounted=false
cleanup() {
    if $mounted; then
        hdiutil detach "$mount" || return
    fi
    rmdir "$mount"
    rm -rf "$staging"
}
trap cleanup EXIT

mkdir "$staging/payload"
ditto "dist/Quick Check.app" "$staging/payload/Quick Check.app"
ln -s /Applications "$staging/payload/Applications"
hdiutil create -fs APFS -format UDZO -volname "Quick Check" -srcfolder "$staging/payload" "$staging/$name"
hdiutil verify "$staging/$name"
hdiutil attach "$staging/$name" -readonly -nobrowse -mountpoint "$mount"
mounted=true

app="$mount/Quick Check.app"
/usr/bin/codesign --verify --strict "$app"
xcrun lipo "$app/Contents/MacOS/QuickCheck" -verify_arch arm64 x86_64
test "$(readlink "$mount/Applications")" = /Applications
for dictionary in dictionary wordnet; do
    test "$(/usr/bin/sqlite3 -readonly "$app/Contents/Resources/$dictionary.sqlite3" 'PRAGMA quick_check;')" = ok
done
hdiutil detach "$mount"
mounted=false

(cd "$staging" && shasum -a 256 "$name" > "$name.sha256")
mv "$staging/$name" "$staging/$name.sha256" dist/
echo "$PWD/dist/$name"
