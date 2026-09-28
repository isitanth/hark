#!/bin/zsh
# Builds dist/Hark.app from the SwiftPM release build, signs it inside out, verifies it,
# then runs the in-app self-test.
#
#   --clean        wipe .build entirely (SwiftPM re-fetches dependencies), so everything is recompiled
#   --check        run scripts/check.sh first (format, lint, builds, tests)
#   --install      replace /Applications/Hark.app with the new build (quits a running Hark first)
#   --debug-audio  compile the debug-only audio dump (-DHARK_DEBUG_AUDIO)
#   --identity     codesign identity (default: $HARK_SIGN_IDENTITY, else the keychain's first Apple Development
#                  certificate, else ad hoc)
#
# Full rebuild, tested, installed:  scripts/bundle.sh --clean --check --install
set -euo pipefail
trap 'print -u2 "bundle.sh: failed at line $LINENO"' ERR

usage() {
    print "usage: scripts/bundle.sh [--clean] [--check] [--install] [--debug-audio] [--identity <codesign identity>]"
}

# An ad hoc signature changes with every build, so macOS asks for the microphone and Accessibility again each time.
certificates=(${(f)"$(security find-identity -v -p codesigning | sed -n 's/^[^"]*"\(Apple Development: .*\)"$/\1/p')"})
identity="${HARK_SIGN_IDENTITY:-${certificates[1]:--}}"
debug_audio=0
clean=0
check=0
install=0
while (( $# )); do
    case "$1" in
        --clean) clean=1 ;;
        --check) check=1 ;;
        --install) install=1 ;;
        --debug-audio) debug_audio=1 ;;
        --identity) identity="${2:?--identity needs a value}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 64 ;;
    esac
    shift
done

root="$(cd "${0:A:h:h}" && pwd -P)"
cd "$root"

if (( clean )); then
    print "==> wiping .build"
    rm -rf .build
fi

if (( check )); then
    print "==> scripts/check.sh"
    scripts/check.sh
fi

build=(-c release --arch arm64)
(( debug_audio )) && build+=(-Xswiftc -DHARK_DEBUG_AUDIO)

print "==> swift build ${build[*]}"
swift build "${build[@]}"
bin="$(swift build "${build[@]}" --show-bin-path)"

app="$root/dist/Hark.app"
contents="$app/Contents"
exe="$contents/MacOS/Hark"
framework="$contents/Frameworks/whisper.framework"

print "==> assembling ${app#$root/}"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Frameworks"

ditto "$bin/Hark" "$exe"

for bundle in "$bin"/*.bundle(N); do
    [[ "${bundle:t}" == *Tests.bundle ]] && continue
    ditto "$bundle" "$contents/Resources/${bundle:t}"
done

# Apple Silicon only: thin the universal framework and drop its build-time headers.
ditto "$bin/whisper.framework" "$framework"
lipo "$framework/Versions/A/whisper" -thin arm64 -output "$framework/Versions/A/whisper.arm64"
mv "$framework/Versions/A/whisper.arm64" "$framework/Versions/A/whisper"
rm -rf "$framework/Headers" "$framework/Modules" "$framework/Versions/A/Headers" "$framework/Versions/A/Modules"

# whisper is the only @rpath dependency. Keep /usr/lib/swift, drop the toolchain and @loader_path
# entries, so dyld can only find whisper in Contents/Frameworks.
for rpath in ${(f)"$(otool -l "$exe" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')"}; do
    [[ "$rpath" == /usr/lib/swift ]] && continue
    install_name_tool -delete_rpath "$rpath" "$exe" 2>/dev/null
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe" 2>/dev/null

print "==> icon"
tmpdir="$(mktemp -d)"
: "${tmpdir:?mktemp failed}"
trap 'rm -rf "$tmpdir"' EXIT
iconset="$tmpdir/Hark.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -Z $size Support/Icon/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -Z $((size * 2)) Support/Icon/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset" --output "$contents/Resources/Hark.icns"

ditto Support/Info.plist "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$contents/Info.plist"
print -n "APPL????" > "$contents/PkgInfo"
xcrun xcstringstool compile Support/InfoPlist.xcstrings --output-directory "$contents/Resources"
# The Services menu's "Ask Hark": its title per language (ServicesMenu.strings) and its template icon (NSIconName).
xcrun xcstringstool compile Support/ServicesMenu.xcstrings --output-directory "$contents/Resources"
# pbs reads a Services title from an old-style .strings file, as UTF-16; xcstringstool writes an XML plist.
for strings in "$contents"/Resources/*.lproj/ServicesMenu.strings; do
    plutil -convert json -o - "$strings" | perl -MJSON::PP -0777 -ne '
        binmode STDOUT, ":encoding(UTF-8)";
        my $table = JSON::PP->new->utf8->decode($_);
        for my $key (sort keys %$table) {
            my ($k, $v) = map { (my $s = $_) =~ s/(["\\])/\\$1/g; $s } ($key, $table->{$key});
            print "\"$k\" = \"$v\";\n";
        }' | iconv -f UTF-8 -t UTF-16 > "$strings.tmp"
    mv "$strings.tmp" "$strings"
done
ditto Support/Icon/AskHarkServiceTemplate.png Support/Icon/AskHarkServiceTemplate@2x.png "$contents/Resources"
# The binary includes whisper.cpp, KeyboardShortcuts and Yams, so their MIT notices travel with it.
ditto LICENSE THIRD_PARTY_NOTICES.md "$contents/Resources"

print "==> signing with \"$identity\""
timestamp=(--timestamp=none)
[[ "$identity" == "Developer ID Application:"* ]] && timestamp=(--timestamp)
codesign --force "${timestamp[@]}" --options runtime --sign "$identity" "$framework"
codesign --force "${timestamp[@]}" --options runtime --entitlements Support/Hark.entitlements \
    --sign "$identity" "$app"

print "==> verifying"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => /designated requirement: /p'

print "==> self-test"
"$exe" --self-test

print "==> ${app#$root/} ready"

if (( install )); then
    # HARK_INSTALL_DIR exists only to test this step without touching /Applications.
    target="${HARK_INSTALL_DIR:-/Applications}/Hark.app"
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Support/Info.plist)"
    print "==> installing to $target"

    # `pgrep -x Hark` matches any process called Hark, so compare executable paths: never signal someone else's
    # binary. Only the copy being replaced, or the one just built, is ours to quit.
    running=()
    for pid in ${(f)"$(pgrep -x Hark || true)"}; do
        [[ -n "$pid" ]] || continue
        case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
            "$target/Contents/MacOS/Hark"|"$exe") running+=("$pid") ;;
        esac
    done
    alive() {
        local pid
        for pid in $running; do
            kill -0 "$pid" 2>/dev/null && return 0
        done
        return 1
    }
    if alive; then
        print "==> quitting Hark ($running)"
        osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
        for _ in {1..40}; do alive || break; sleep 0.25; done
        alive && kill $running 2>/dev/null
        for _ in {1..20}; do alive || break; sleep 0.25; done
        alive && { print -u2 "bundle.sh: Hark is still running; quit it and retry"; exit 1; }
    fi
    rm -rf "$target"
    ditto "$app" "$target"
    codesign --verify --deep --strict "$target"
    # Launch Services learns the new NSServices entry, and pbs rebuilds the Services menu from it. pbs caches the
    # titles only for the languages it is given (measured 2026-09-28: a bare -update kept English alone).
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target"
    /System/Library/CoreServices/pbs -update ${(f)"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleLocalizations' Support/Info.plist | sed -n 's/^ *\([a-z][a-z]\)$/\1/p')"}
    print "==> installed; start it with: open ${(q)target}"
fi
