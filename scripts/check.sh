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
forbid "URLSession is only allowed in URLSessionDownloader.swift and Ask/LLMClient.swift" \
    "$(grep -rn 'URLSession' Sources | grep -vE '^Sources/HarkCore/(Models/URLSessionDownloader|Ask/LLMClient)\.swift:' || true)"
# An API key lives in the Keychain only. Sources/ holds the default commands.yaml too. A Bearer token or an sk- key
# written out, or an api_key with a value, fails; "Bearer \(key)" and prose about Bearer do not. In YAML, a profile's
# key: is keychain or none, nothing else.
forbid "no API key literals in Sources: keys live in the Keychain" \
    "$(grep -rnE 'api_key:[[:space:]]*[^[:space:]`]|Bearer [A-Za-z0-9._~+/=-]*[0-9][A-Za-z0-9._~+/=-]*|Bearer [A-Za-z0-9._~+/=-]{16,}|(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}' Sources || true)"
forbid "a profile's key: in YAML is keychain or none: keys live in the Keychain" \
    "$(grep -rnE --include='*.yaml' '^[[:space:]]*key:[[:space:]]*[^[:space:]#]' Sources | grep -vE 'key:[[:space:]]*"?(keychain|none)"?([[:space:]]|#|$)' || true)"
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
