#!/bin/zsh
# Packs dist/Hark.app into dist/Hark-<version>.dmg: the app beside a link to /Applications, to drag across.
# Run scripts/bundle.sh first.
set -euo pipefail
cd "${0:A:h:h}"

app=dist/Hark.app
[[ -d "$app" ]] || { print -u2 "dmg.sh: no $app, run scripts/bundle.sh first"; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="dist/Hark-$version.dmg"

stage="$(mktemp -d)"
: "${stage:?mktemp failed}"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Hark.app"
ln -s /Applications "$stage/Applications"

rm -f "$dmg"
hdiutil create -quiet -volname Hark -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
print "==> $dmg"
