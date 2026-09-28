#!/bin/zsh
# Local quality gate: swift-format lint, grep lint, build, test. Stops at the first failure.
set -euo pipefail
cd "${0:A:h:h}"

step() { print "==> $1"; }
fail() { print -u2 "check.sh: $1"; exit 1; }
forbid() {
    local message="$1" hits="$2"
    [[ -z "$hits" ]] || fail "$message"$'\n'"$hits"
}

step "swift-format lint"
xcrun swift-format lint --strict --recursive --parallel Package.swift Sources Tests

step "grep lint"
forbid "HarkCore must not import UI frameworks" \
    "$(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(SwiftUI|AppKit|Cocoa|KeyboardShortcuts)([[:space:]]|$)' Sources/HarkCore || true)"
forbid "only Sources/HarkCore/Transcription may import whisper" \
    "$(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+whisper([[:space:]]|$)' Sources Tests | grep -v '^Sources/HarkCore/Transcription/' || true)"
forbid "URLSession is only allowed in URLSessionDownloader.swift" \
    "$(grep -rn 'URLSession' Sources | grep -v '/URLSessionDownloader.swift:' || true)"
forbid "empty catch blocks are not allowed" \
    "$(find Sources Tests -name '*.swift' -print0 | xargs -0 perl -0777 -ne 'print "$ARGV\n" if /\bcatch\b[^{}]*\{\s*\}/' || true)"
forbid "no print( or debugPrint( (use os.Logger)" \
    "$(grep -rnE '(^|[^A-Za-z0-9_.])(print|debugPrint)\(' Sources Tests || true)"

step "swift build"
swift build

# Separate scratch path, so the debug-only audio dump keeps compiling without invalidating the normal build.
step "swift build -DHARK_DEBUG_AUDIO"
swift build --scratch-path .build/debug-audio -Xswiftc -DHARK_DEBUG_AUDIO

step "swift test"
swift test

print "==> check passed"
