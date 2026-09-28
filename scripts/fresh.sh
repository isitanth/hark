#!/bin/zsh
# Cleans build product this project owns, then build, test and install the app. The installed
# copy is quit and replaced by scripts/bundle.sh --install, at the end, so a build that fails leaves the app you
# already have in place.
#
#   --purge-downloads  also wipe SwiftPM's shared cache, so dependencies (57 MB of whisper) download again
#   --debug-audio      passed through to scripts/bundle.sh, like any other flag
#
# Left alone on purpose: your preferences (the shortcuts you recorded), the microphone and Accessibility grants,
# and the utterance logs in ~/Library/Application Support/Hark.
set -euo pipefail

root="${0:A:h:h}" # make absolute and come back to the root folder for work
cd "$root"

purge=0
passthrough=()
while (( $# )); do
    case "$1" in
        --purge-downloads) purge=1 ;;
        -h|--help) print "usage: scripts/fresh.sh [--purge-downloads] [flags for bundle.sh]"; exit 0 ;;
        *) passthrough+=("$1") ;;
    esac
    shift
done

print "==> wiping build products"
rm -rf .build dist .swiftpm

if (( purge )); then
    print "==> wiping SwiftPM caches"
    rm -rf "${HOME}/Library/Caches/org.swift.swiftpm" "${HOME}/Library/org.swift.swiftpm/cache"
fi

print "==> building from scratch"
exec scripts/bundle.sh --check --install "${passthrough[@]}"
