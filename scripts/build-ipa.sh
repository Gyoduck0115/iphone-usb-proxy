#!/usr/bin/env bash
# Builds an unsigned IPA for sideloading (SideStore, AltStore, Feather, or your own developer cert).
# Modeled after viktor-svirsky/tether/scripts/build-ipa.sh.
#
# Usage:
#   scripts/build-ipa.sh <version> <output-dir> [--scheme USBProxy|USBProxyFree]
#
# - USBProxyFree (default for free Apple ID / SideStore): includes in-app SOCKS5/UoT + silent audio KeepAlive.
# - USBProxy (paid Apple Developer account): includes Stage 2 dummy NEPacketTunnelProvider extension.
set -euo pipefail

if (( $# < 2 )); then
    echo "usage: $0 <version X.Y.Z> <output-dir> [--scheme USBProxy|USBProxyFree]" >&2
    exit 2
fi

version=$1
out_arg=$2
shift 2

scheme="USBProxyFree"
while (( $# > 0 )); do
    case "$1" in
        --scheme)
            scheme=$2
            shift 2
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z, got '$version'" >&2; exit 2; }
[[ $scheme == "USBProxy" || $scheme == "USBProxyFree" ]] || { echo "scheme must be USBProxy or USBProxyFree" >&2; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out_arg"
out=$(cd "$out_arg" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$root"
xcodegen generate --quiet

build_num=$(git rev-list --count HEAD 2>/dev/null || echo "1")
log="$out/xcodebuild-${scheme}.log"

if ! xcodebuild archive \
    -project USBProxy.xcodeproj \
    -scheme "$scheme" \
    -configuration Release \
    -destination generic/platform=iOS \
    -archivePath "$work/${scheme}.xcarchive" \
    -derivedDataPath "$work/dd" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_num" \
    > "$log" 2>&1; then
    awk '/(^| )error: / && n++ < 25' "$log" >&2
    tail -25 "$log" >&2
    echo "xcodebuild failed; full log: $log" >&2
    exit 1
fi

app="$work/${scheme}.xcarchive/Products/Applications/${scheme}.app"
if [[ ! -d "$app" ]]; then
    echo "expected app bundle not found at $app" >&2
    exit 1
fi

mkdir -p "$work/Payload"
cp -R "$app" "$work/Payload/"
ipa="$out/${scheme}.ipa"
rm -f "$ipa"
(cd "$work" && zip -qry "$ipa" Payload)
echo "Built unsigned IPA: $ipa"
