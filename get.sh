#!/bin/bash
# Heimdall Entrepreneur Edition: download, verify and install on macOS.
#
# One line, pasted into Terminal:
#   curl -fsSL https://raw.githubusercontent.com/bradykrowe/Heimdall-Entrepreneur_Edition/v0.1.0-beta/get.sh | bash
#
# Pass installer flags after "bash -s --", for example:
#   ... | bash -s -- --skip-software
#   ... | bash -s -- --vault ~/Lab_Brain
#
# What it does, in order:
#   1. Reads the GitHub Release for the pinned tag below.
#   2. Downloads the install zip and its .sha256 with curl, so macOS adds no
#      quarantine flag and Gatekeeper does not block the installer.
#   3. Refuses to continue if the hash does not match.
#   4. Unpacks the zip into ~/Downloads and runs install_heimdall.sh.
#
# It never runs as root and never touches anything outside ~/Downloads and
# the vault folder the installer asks you about.

set -eu

REPO="bradykrowe/Heimdall-Entrepreneur_Edition"
TAG="${SECOND_BRAIN_TAG:-v0.1.0-beta}"
DEST="${HEIMDALL_GET_DIR:-$HOME/Downloads}"

# Private beta only: a GitHub token in HEIMDALL_GITHUB_TOKEN (or GH_TOKEN)
# lets this script read a release that is not public yet. Leave it unset
# otherwise; a public release needs no token and the script never sends one.
TOKEN="${HEIMDALL_GITHUB_TOKEN:-${GH_TOKEN:-}}"

say()  { printf '%s\n' "$*"; }
die()  { printf 'get.sh: %s\n' "$*" >&2; exit 1; }

gh_get() {
  # gh_get <url> <output path, or - for stdout> <Accept header value>
  if [ -n "$TOKEN" ]; then
    curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: $3" -o "$2" "$1"
  else
    curl -fsSL -H "Accept: $3" -o "$2" "$1"
  fi
}

case "$(uname -s)" in
  Darwin) ;;
  *) die "this script is for macOS. On Windows use get.ps1; on Linux run install_heimdall.sh from the zip." ;;
esac

command -v curl >/dev/null 2>&1 || die "curl not found."
command -v shasum >/dev/null 2>&1 || die "shasum not found."
command -v ditto >/dev/null 2>&1 || die "ditto not found."

# Chip and admin checks before anything downloads (installer decisions R1, R2).
SKIP_SOFTWARE=0
for a in "$@"; do [ "$a" = "--skip-software" ] && SKIP_SOFTWARE=1; done

if [ "$SKIP_SOFTWARE" -eq 0 ]; then
  if [ "$(uname -m)" = "x86_64" ] && ! command -v brew >/dev/null 2>&1; then
    say "This is an Intel Mac without Homebrew. Homebrew's installer no longer"
    say "supports Intel Macs, so the software step cannot run here."
    say "Install Obsidian, Node.js 20 or later, Python 3.12 and Claude Code by"
    say "hand, then run this line again with:  bash -s -- --skip-software"
    exit 1
  fi
  if ! command -v brew >/dev/null 2>&1 && ! groups 2>/dev/null | tr ' ' '\n' | grep -qx admin; then
    say "This account is not an administrator on this Mac, and Homebrew is not"
    say "installed, so the software step cannot run. Ask IT (or Self Service)"
    say "to install Obsidian, Node.js, Python 3.12 and Claude Code, then run"
    say "this line again with:  bash -s -- --skip-software"
    exit 1
  fi
fi

API="https://api.github.com/repos/$REPO/releases/tags/$TAG"
say "Reading release $TAG ..."
JSON="$(gh_get "$API" - application/vnd.github+json)" || die "could not read the release $TAG. Check the tag and your network."

if [ -n "$TOKEN" ]; then
  # A release that is not public: assets come through the API by asset URL.
  PAIRS="$(printf '%s' "$JSON" | tr ',' '\n' | awk -F'"' '
    /"url": *"https:\/\/api\.github\.com\/repos\/.*\/releases\/assets\/[0-9]+"/ { u = $4 }
    /^ *"name": *"/ && u != "" { print u "\t" $4; u = "" }')"
  ZIP_URL="$(printf '%s\n' "$PAIRS" | awk -F'\t' '$2 ~ /\.zip$/ { print $1; exit }')"
  ZIP_NAME="$(printf '%s\n' "$PAIRS" | awk -F'\t' '$2 ~ /\.zip$/ { print $2; exit }')"
  SHA_URL="$(printf '%s\n' "$PAIRS" | awk -F'\t' '$2 ~ /\.sha256$/ { print $1; exit }')"
  ACCEPT="application/octet-stream"
else
  ZIP_URL="$(printf '%s' "$JSON" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -n1 | sed 's/.*"\(https[^"]*\)"/\1/')"
  SHA_URL="$(printf '%s' "$JSON" | grep -o '"browser_download_url": *"[^"]*\.sha256"' | head -n1 | sed 's/.*"\(https[^"]*\)"/\1/')"
  ZIP_NAME="$(basename "$ZIP_URL")"
  ACCEPT="*/*"
fi
[ -n "$ZIP_URL" ] || die "release $TAG has no .zip asset."
[ -n "$SHA_URL" ] || die "release $TAG has no .sha256 asset."

mkdir -p "$DEST"
say "Downloading $ZIP_NAME ..."
gh_get "$ZIP_URL" "$DEST/$ZIP_NAME" "$ACCEPT" || die "download of $ZIP_NAME failed."
gh_get "$SHA_URL" "$DEST/$ZIP_NAME.sha256" "$ACCEPT" || die "download of $ZIP_NAME.sha256 failed."

EXPECTED="$(awk '{print $1}' "$DEST/$ZIP_NAME.sha256" | head -n1 | tr 'A-F' 'a-f')"
ACTUAL="$(shasum -a 256 "$DEST/$ZIP_NAME" | awk '{print $1}')"
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
  rm -f "$DEST/$ZIP_NAME"
  die "sha256 mismatch. Expected $EXPECTED, got $ACTUAL. The download was removed; nothing was installed."
fi
say "sha256 verified."

UNPACK="$DEST/${ZIP_NAME%.zip}"
rm -rf "$UNPACK"
mkdir -p "$UNPACK"
ditto -x -k "$DEST/$ZIP_NAME" "$UNPACK"

# The zip holds one top-level folder.
INNER="$(find "$UNPACK" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[ -n "$INNER" ] || die "unexpected zip layout."
[ -f "$INNER/install_heimdall.sh" ] || die "install_heimdall.sh not found in the zip."

say "Starting the installer from $INNER"
say ""
cd "$INNER"
# Through "curl | bash" this script arrives on stdin, so the installer's
# questions would read end of file and take their defaults without a pause.
# Hand it the keyboard when there is one; CI and other pipes keep stdin.
if [ ! -t 0 ] && { : < /dev/tty; } 2>/dev/null; then
  exec bash ./install_heimdall.sh "$@" < /dev/tty
fi
exec bash ./install_heimdall.sh "$@"
