#!/bin/bash
# AIYOUClean user-space installer. No sudo, privilege changes, or Gatekeeper bypass.
set -euo pipefail
REPOSITORY='yubowen123/AIYOUClean'
DESTINATION="$HOME/Applications"
LOCAL_ZIP=''
CHECKSUMS=''
usage() {
    cat <<'HELP'
Usage: bash install.sh [--destination EXISTING_DIRECTORY]
       bash install.sh --local-zip FILE --checksums SHA256SUMS [--destination EXISTING_DIRECTORY]
Installs a verified release to ~/Applications/AIYOUClean.app without opening it.
A custom destination must already exist. No sudo or security-policy changes.
HELP
}
fail() { printf 'AIYOUClean: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --destination|--local-zip|--checksums)
            [ "$#" -ge 2 ] || fail "Missing value for $1"
            case "$1" in
                --destination) DESTINATION="$2" ;;
                --local-zip) LOCAL_ZIP="$2" ;;
                --checksums) CHECKSUMS="$2" ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail 'macOS is required.'
[ "$(uname -m)" = arm64 ] || fail 'This release supports Apple Silicon (arm64) only. Run from a native terminal, without Rosetta.'
MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{print $1}')"
[ "$MAJOR" -ge 13 ] || fail 'macOS 13 or later is required.'
case "$DESTINATION" in /*) ;; *) fail 'Destination must be an absolute path.' ;; esac
case "$DESTINATION" in *'/../'*|*'/..'|*'/./'*|*'/.'|*$'\n'*) fail 'Destination contains an unsafe path component.' ;; esac
if [ "$DESTINATION" = "$HOME/Applications" ] && [ ! -e "$DESTINATION" ]; then
    /bin/mkdir -p "$DESTINATION"
fi
[ -d "$DESTINATION" ] && [ ! -L "$DESTINATION" ] || fail 'Destination must be an existing directory, not a symlink.'
DESTINATION="$(cd "$DESTINATION" && pwd -P)"
case "$DESTINATION" in
    /|/System|/System/*|/Library|/Library/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/dev|/dev/*|/private|/private/etc|/private/etc/*|/Users|"$HOME") fail 'Refusing an unsafe destination.' ;;
esac
[ -w "$DESTINATION" ] || fail 'Destination is not writable. Choose a user-owned directory.'
TARGET="$DESTINATION/AIYOUClean.app"
[ ! -L "$TARGET" ] || fail 'Refusing to replace a symlink.'
if [ -e "$TARGET" ]; then
    [ -d "$TARGET" ] || fail 'The target exists and is not an app directory.'
    EXISTING_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$TARGET/Contents/Info.plist" 2>/dev/null || true)"
    [ "$EXISTING_ID" = 'local.aiyou.AIYOUClean' ] || fail 'The existing target is not AIYOUClean.'
fi
# Check this destination, not unrelated older versions in other directories.
is_target_running() {
    [ -f "$TARGET/Contents/MacOS/AIYOUClean" ] || return 1
    /usr/sbin/lsof -t "$TARGET/Contents/MacOS/AIYOUClean" >/dev/null 2>&1
}
if is_target_running; then
    fail 'AIYOUClean is running. Finish its task, quit the app yourself, then retry.'
fi
SCRATCH="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/aiyouclean-install.XXXXXX")"
STAGE=''
BACKUP=''
INSTALLED=0
COMMITTED=0
cleanup() {
    STATUS=$?
    trap - EXIT
    if [ "$STATUS" -ne 0 ] && [ "$COMMITTED" -eq 0 ] && [ -n "$BACKUP" ] && [ -d "$BACKUP/AIYOUClean.app" ]; then
        # A failed commit restores the old app; no user files outside our target are removed.
        if [ "$INSTALLED" -eq 1 ] && [ -d "$TARGET" ] && [ ! -L "$TARGET" ]; then /bin/rm -rf "$TARGET"; fi
        if [ ! -e "$TARGET" ]; then /bin/mv "$BACKUP/AIYOUClean.app" "$TARGET" || printf 'Previous app preserved at %s\n' "$BACKUP/AIYOUClean.app" >&2; fi
    fi
    [ -z "$STAGE" ] || /bin/rm -rf "$STAGE"
    if [ -n "$BACKUP" ] && [ ! -e "$BACKUP/AIYOUClean.app" ]; then /bin/rmdir "$BACKUP" 2>/dev/null || true; fi
    /bin/rm -rf "$SCRATCH"
    exit "$STATUS"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "$LOCAL_ZIP" ]; then
    [ -f "$LOCAL_ZIP" ] && [ -n "$CHECKSUMS" ] && [ -f "$CHECKSUMS" ] || fail 'Local mode requires an existing ZIP and SHA256SUMS.'
    ARCHIVE="$LOCAL_ZIP"
else
    [ -z "$CHECKSUMS" ] || fail '--checksums is only valid with --local-zip.'
    API="https://api.github.com/repos/$REPOSITORY/releases/latest"
    /usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$API" -o "$SCRATCH/release.json"
    TAG="$(/usr/bin/plutil -extract tag_name raw -o - "$SCRATCH/release.json")"
    [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Unexpected release tag.'
    VERSION="${TAG#v}"
    ASSET="AIYOUClean-$VERSION-macOS-arm64.zip"
    BASE="https://github.com/$REPOSITORY/releases/download/$TAG"
    ARCHIVE="$SCRATCH/$ASSET"
    CHECKSUMS="$SCRATCH/SHA256SUMS"
    /usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$BASE/$ASSET" -o "$ARCHIVE"
    /usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$BASE/SHA256SUMS" -o "$CHECKSUMS"
fi
NAME="$(basename "$ARCHIVE")"
EXPECTED="$(/usr/bin/awk -v name="$NAME" '($2 == name || $2 == "*" name) { count++; value=$1 } END { if (count == 1) print value }' "$CHECKSUMS")"
[[ "$EXPECTED" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'No unique SHA-256 entry for this ZIP.'
ACTUAL="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
[ "$(printf '%s' "$EXPECTED" | /usr/bin/tr 'A-F' 'a-f')" = "$ACTUAL" ] || fail 'SHA-256 mismatch; nothing installed.'
/usr/bin/unzip -tq "$ARCHIVE" >/dev/null || fail 'ZIP integrity check failed.'
/usr/bin/zipinfo -1 "$ARCHIVE" > "$SCRATCH/entries"
/usr/bin/awk '
    BEGIN { valid=1; count=0 }
    { if ($0 ~ /^\// || $0 ~ /\\/ || $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /[[:cntrl:]]/) valid=0;
      split($0, parts, "/"); if (root == "") root=parts[1]; if (parts[1] != root) valid=0; count++ }
    END { if (!valid || count == 0 || root !~ /^AIYOUClean(-[0-9]+\.[0-9]+\.[0-9]+)?\.app$/) exit 1; print root }
' "$SCRATCH/entries" > "$SCRATCH/root" || fail 'ZIP must contain one AIYOUClean app and safe relative paths.'
# Reject archive symlinks before extraction to prevent traversal through a link.
/usr/bin/zipinfo -l "$ARCHIVE" > "$SCRATCH/attributes"
if /usr/bin/awk '$1 ~ /^l/ { found=1 } END { exit !found }' "$SCRATCH/attributes"; then fail 'Unexpected symlink in release ZIP.'; fi
/bin/mkdir "$SCRATCH/unpacked"
/usr/bin/ditto -x -k "$ARCHIVE" "$SCRATCH/unpacked"
APP="$SCRATCH/unpacked/$(cat "$SCRATCH/root")"
[ -d "$APP" ] && [ ! -L "$APP" ] || fail 'No app found after extraction.'
[ -z "$(/usr/bin/find "$APP" -type l -print -quit)" ] || fail 'Unexpected app symlink.'
PLIST="$APP/Contents/Info.plist"
[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = 'local.aiyou.AIYOUClean' ] || fail 'Unexpected bundle identifier.'
[ "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$PLIST")" = AIYOUClean ] || fail 'Unexpected executable name.'
APP_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Unexpected bundle version.'
if [ -z "$LOCAL_ZIP" ]; then [ "$APP_VERSION" = "$VERSION" ] || fail 'Bundle and release versions differ.'; fi
[ -x "$APP/Contents/MacOS/AIYOUClean" ] || fail 'Missing app executable.'
/usr/bin/lipo -archs "$APP/Contents/MacOS/AIYOUClean" | /usr/bin/grep -qw arm64 || fail 'The app does not contain arm64 code.'
/usr/bin/codesign --verify --deep --strict "$APP" || fail 'App signature verification failed.'
STAGE="$(/usr/bin/mktemp -d "$DESTINATION/.aiyouclean-stage.XXXXXX")"
/usr/bin/ditto "$APP" "$STAGE/AIYOUClean.app"
/usr/bin/codesign --verify --deep --strict "$STAGE/AIYOUClean.app"
# Repeat the running-process guard immediately before replacement.
if is_target_running; then fail 'AIYOUClean started during installation. Quit it yourself and retry.'; fi
if [ -e "$TARGET" ]; then
    BACKUP="$(/usr/bin/mktemp -d "$DESTINATION/.aiyouclean-backup.XXXXXX")"
    /bin/mv "$TARGET" "$BACKUP/AIYOUClean.app"
fi
/bin/mv "$STAGE/AIYOUClean.app" "$TARGET"
INSTALLED=1
/usr/bin/codesign --verify --deep --strict "$TARGET"
COMMITTED=1
if [ -n "$BACKUP" ]; then
    if /bin/rm -rf "$BACKUP/AIYOUClean.app"; then
        /bin/rmdir "$BACKUP" 2>/dev/null || true
        BACKUP=''
    else
        printf 'Installed successfully; previous backup could not be fully removed: %s\n' "$BACKUP" >&2
    fi
fi
printf 'Installed AIYOUClean %s to %s\n' "$APP_VERSION" "$TARGET"
printf 'Open the app from Finder. macOS may require Privacy & Security → Open Anyway.\n'
printf 'This installer does not grant Full Disk Access or start a scan.\n'
