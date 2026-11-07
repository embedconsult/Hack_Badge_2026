#!/bin/sh
# Install (or update) the Link apps on a BeagleBadge's badge-launcher and
# restart it. Run on the BeagleBadge as root:
#   curl -sL https://raw.githubusercontent.com/embedconsult/Hack_Badge_2026/interop/crystal/net/install_beagle.sh | sh
# BRANCH=... picks another branch. Only adds applications/link/ (a new menu
# category); the first previous copy is kept in /root/link.orig.
set -eu
BRANCH=${BRANCH:-interop}
BASE=https://raw.githubusercontent.com/embedconsult/Hack_Badge_2026/$BRANCH/crystal/net
DST=/opt/badge_launcher/applications/link
TMP=$(mktemp -d)
for f in _badgenet.py _linkui.py README.md finder/finder_app.py finder/README.md \
         remote/remote_app.py remote/README.md netpong/netpong_app.py netpong/README.md; do
  mkdir -p "$TMP/link/$(dirname "$f")"
  curl -fsSL "$BASE/beaglebadge/applications/link/$f?$(date +%s)" -o "$TMP/link/$f"
done
for t in sim_badge.py espnow_nl80211.py fake_badgeos.py; do
  curl -fsSL "$BASE/$t?$(date +%s)" -o /opt/badge_launcher/tools/$t 2>/dev/null || true
done
if [ -d "$DST" ] && [ ! -d "$DST.orig" ]; then cp -a "$DST" /root/link.orig; fi
rm -rf "$DST"
mv "$TMP/link" "$DST"
rmdir "$TMP" 2>/dev/null || true
echo "installed into $DST:"; find "$DST" -type f | sort
systemctl restart badge-launcher.service
echo "badge-launcher restarted"
