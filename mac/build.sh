#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

install=false
architectures=("$(uname -m)")
case "${1:-}" in
    "") ;;
    --install) install=true ;;
    --universal) architectures=(arm64 x86_64) ;;
    *) echo "Usage: $0 [--install | --universal]" >&2; exit 2 ;;
esac
if (( $# > 1 )); then
    echo "Usage: $0 [--install | --universal]" >&2
    exit 2
fi

sdk=$(xcrun --sdk macosx --show-sdk-path)
destination="$PWD/dist/Quick Check.app"
if $install; then destination="/Applications/Quick Check.app"; fi
output_dir=$(dirname "$destination")
mkdir -p "$output_dir"
staging=$(mktemp -d "$output_dir/.quick-check.XXXXXX")
previous="$staging/Previous.app"
completed=false
trap 'if $completed || [[ ! -e "$previous" ]]; then rm -rf "$staging"; fi' EXIT

app_state() {
    xcrun swift - "$@" <<'SWIFT'
import AppKit
import Darwin

let stopping = CommandLine.arguments[1] == "stop"
let bundleID = CommandLine.arguments[2]
let destination = CommandLine.arguments[3]

func instances() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
}

if stopping {
    for app in instances() {
        if kill(app.processIdentifier, SIGTERM) != 0, errno != ESRCH {
            perror("Could not stop Quick Check")
            exit(1)
        }
    }
}

for _ in 0..<50 {
    let running = instances()
    if stopping, running.isEmpty { exit(0) }
    if !stopping, running.count == 1, let app = running.first, app.isFinishedLaunching,
       app.bundleURL?.resolvingSymlinksInPath().path == destination {
        print("Running PID \(app.processIdentifier)")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
}

fputs(stopping ? "Quick Check did not quit\n" : "Installed Quick Check did not start\n", stderr)
exit(1)
SWIFT
}

app="$staging/Quick Check.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
iconset="$staging/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" Resources/AppIcon.png \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    /usr/bin/sips -z "$((size * 2))" "$((size * 2))" Resources/AppIcon.png \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "$app/Contents/Resources/"
gzip -dc Resources/dictionary.sqlite3.gz > "$app/Contents/Resources/dictionary.sqlite3"
gzip -dc Resources/wordnet.sqlite3.gz > "$app/Contents/Resources/wordnet.sqlite3"
cp Resources/DICTIONARY_LICENSE.md Resources/WORDNET_PRINCETON_LICENSE.txt "$app/Contents/Resources/"
executables=()
for architecture in "${architectures[@]}"; do
    executable="$staging/QuickCheck-$architecture"
    xcrun swiftc -O -target "$architecture-apple-macosx15.0" -sdk "$sdk" Sources/*.swift -o "$executable"
    executables+=("$executable")
done
if (( ${#executables[@]} == 1 )); then
    mv "${executables[0]}" "$app/Contents/MacOS/QuickCheck"
else
    xcrun lipo -create "${executables[@]}" -output "$app/Contents/MacOS/QuickCheck"
fi
/usr/bin/codesign --force --sign "${QUICK_CHECK_SIGN_IDENTITY:--}" "$app"
/usr/bin/codesign --verify --strict "$app"
if $install; then
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
    app_state stop "$bundle_id" "$destination"
    if [[ -e "$destination" ]]; then mv "$destination" "$previous"; fi
    if ! (mv "$app" "$destination" && /usr/bin/open "$destination" && app_state verify "$bundle_id" "$destination"); then
        # Preserve both bundles if rollback needs intervention.
        trap - EXIT
        app_state stop "$bundle_id" "$destination" || {
            echo "Could not stop the new app. Installation files are in $staging." >&2
            exit 1
        }
        if [[ -e "$destination" ]]; then mv "$destination" "$app"; fi
        if [[ -e "$previous" ]]; then
            mv "$previous" "$destination"
            /usr/bin/open "$destination"
        fi
        echo "Installation failed. Build files are in $staging." >&2
        exit 1
    fi
else
    rm -rf "$destination"
    mv "$app" "$destination"
fi
completed=true
echo "$destination"
