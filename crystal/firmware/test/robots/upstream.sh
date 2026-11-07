#!/bin/sh
# Fetch the pinned crystal-robots source (the oracle for test/robots_spec.cr)
# into test/robots/upstream/ (git-ignored). The GitHub mirror is used because
# openbeagle.org sits behind a bot check.
#
#   crystal/firmware/test/robots/upstream.sh && crystal spec crystal/firmware/test/robots_spec.cr
set -eu
REV=${CRYSTAL_ROBOTS_REV:-c0ecb30a9df73a969bbe4d3c0df2b8973e0d6e8a}
HERE=$(cd "$(dirname "$0")" && pwd)
DEST="$HERE/upstream"
if [ -f "$DEST/.rev" ] && [ "$(cat "$DEST/.rev")" = "$REV" ]; then
  echo "upstream crystal-robots $REV already present"
  exit 0
fi
rm -rf "$DEST" "$DEST.tmp"
mkdir -p "$DEST.tmp"
curl -sSfL "https://github.com/jadonk/crystal-robots/archive/$REV.tar.gz" | tar xz -C "$DEST.tmp" --strip-components=1
echo "$REV" > "$DEST.tmp/.rev"
mv "$DEST.tmp" "$DEST"
echo "fetched crystal-robots $REV into $DEST"
