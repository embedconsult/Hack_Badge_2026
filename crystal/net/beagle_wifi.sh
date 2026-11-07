#!/bin/sh
# Move the BeagleBadge between a Supercon badge's own access point (`net ap on`,
# channel 1, shared with badge os badges) and its usual network.
#   beagle_wifi.sh badge [BADGE-LINK-XXXX] [password]   join the badge (first BADGE-LINK-* found)
#   beagle_wifi.sh home [connection]                    back (default: the last other wifi connection)
set -eu
case "${1:-}" in
badge)
  SSID=${2:-$(nmcli -t -f SSID dev wifi list --rescan yes | grep '^BADGE-LINK-' | head -1)}
  [ -n "$SSID" ] || { echo "no BADGE-LINK-* access point in range"; exit 1; }
  nmcli -t -f NAME con show --active | grep -v '^lo$' | head -1 > /root/.badge_link_home || true
  nmcli dev wifi connect "$SSID" password "${3:-supercon}"
  ;;
home)
  CON=${2:-$(cat /root/.badge_link_home 2>/dev/null || true)}
  [ -n "$CON" ] || { echo "which connection? nmcli con show"; exit 1; }
  nmcli con up "$CON"
  ;;
*) sed -n '2,6p' "$0"; exit 1 ;;
esac
