#!/bin/bash
# Package an already built, locally signed bundle. Does not upload or install.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT_DIR/dist/AIYOUClean-0.6.2.app"
OUTPUT="$PROJECT_DIR/dist/release"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app|--output)
            [ "$#" -ge 2 ] || { printf 'Missing value for %s\n' "$1" >&2; exit 1; }
            case "$1" in --app) APP="$2" ;; --output) OUTPUT="$2" ;; esac
            shift 2 ;;
        -h|--help) printf 'Usage: bash scripts/package-release.sh [--app APP] [--output DIRECTORY]\n'; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
[ -d "$APP" ] && [ ! -L "$APP" ] || { printf 'Expected an existing app directory.\n' >&2; exit 1; }
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid app version.\n' >&2; exit 1; }
[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" = 'local.aiyou.AIYOUClean' ] || exit 1
/usr/bin/lipo -archs "$APP/Contents/MacOS/AIYOUClean" | /usr/bin/grep -qw arm64
/usr/bin/codesign --verify --deep --strict "$APP"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd -P)"
ASSET="AIYOUClean-$VERSION-macOS-arm64.zip"
[ ! -e "$OUTPUT/$ASSET" ] && [ ! -e "$OUTPUT/SHA256SUMS" ] || { printf 'Refusing to overwrite release artifacts. Use a new output directory.\n' >&2; exit 1; }
SCRATCH="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/aiyouclean-package.XXXXXX")"
trap '/bin/rm -rf "$SCRATCH"' EXIT
/usr/bin/ditto "$APP" "$SCRATCH/AIYOUClean.app"
# --norsrc omits machine-specific Finder resource metadata; the bundle is unchanged.
/usr/bin/ditto -c -k --norsrc --keepParent "$SCRATCH/AIYOUClean.app" "$SCRATCH/$ASSET"
/usr/bin/unzip -tq "$SCRATCH/$ASSET"
(cd "$SCRATCH" && /usr/bin/shasum -a 256 "$ASSET" > SHA256SUMS)
/bin/mv "$SCRATCH/$ASSET" "$OUTPUT/$ASSET"
/bin/mv "$SCRATCH/SHA256SUMS" "$OUTPUT/SHA256SUMS"
printf 'Release artifacts: %s\n' "$OUTPUT"
