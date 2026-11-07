#!/bin/sh
# Publish a built badge app as a GitHub release, for the badge's OTA update
# (src/ota.cr: shell `ota`, or hold User B on the DIAG screen).
#
#   crystal/tools/release.sh [APP_BIN]     (default crystal/firmware/build/crystal_blink.bin)
#
# Creates release <tag> on embedconsult/Hack_Badge_2026, tag = `git describe`
# of this checkout (the same string build.sh compiles into CR_VERSION), at
# HEAD, marked latest, with two assets:
#   badge-app.bin       the app image (what esp_https_ota writes to the other slot)
#   badge-version.txt   "<tag> <build number>" (git rev-list --count); a badge installs
#                       only a release whose build number is greater than its own
# The badge fetches .../releases/latest/download/<asset>, so the newest
# release is what every badge installs. HEAD must be pushed first.
set -eu
REPO=embedconsult/Hack_Badge_2026
cd "$(dirname "$0")/../.."
BIN=${1:-crystal/firmware/build/crystal_blink.bin}
[ -f "$BIN" ] || { echo "release: no app image $BIN (run crystal/firmware/build.sh)" >&2; exit 1; }

VER=$(git describe --always --dirty --abbrev=7)
case $VER in
  *-dirty) echo "release: working tree is dirty ($VER); commit and rebuild first" >&2; exit 1 ;;
esac
# The image must be the build of exactly this version (CR_VERSION "<VER> <HH:MM>").
if ! LC_ALL=C grep -q -a -F "$VER " "$BIN"; then
  echo "release: $BIN was not built from $VER; rebuild with crystal/firmware/build.sh" >&2
  exit 1
fi
# ESP-IDF app image magic byte; the badge also checks the project name.
[ "$(head -c1 "$BIN" | od -An -tx1 | tr -d ' ')" = e9 ] || { echo "release: $BIN is not an ESP app image" >&2; exit 1; }
SIZE=$(wc -c <"$BIN")
[ "$SIZE" -le $((0x300000)) ] || { echo "release: image ($SIZE bytes) is larger than an OTA slot" >&2; exit 1; }

HEAD=$(git rev-parse HEAD)
git fetch -q origin
if ! git branch -r --contains "$HEAD" | grep -q .; then
  echo "release: HEAD $HEAD is not pushed to origin; push it first" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp "$BIN" "$TMP/badge-app.bin"
# "<tag> <build number>": badges install only a greater build number (main/ota.c)
BUILDNO=$(git rev-list --count HEAD)
printf '%s %s\n' "$VER" "$BUILDNO" >"$TMP/badge-version.txt"
echo "release: $VER ($SIZE bytes) -> $REPO"
gh release create "$VER" -R "$REPO" --target "$HEAD" --latest \
  --title "Badge firmware $VER" \
  --notes "Crystal badge firmware $VER (OTA image for the 2-slot partition table). Install on a badge: shell \`ota\`, or hold User B on the DIAG screen." \
  "$TMP/badge-app.bin" "$TMP/badge-version.txt"
