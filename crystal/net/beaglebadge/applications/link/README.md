# Link apps for the badge-launcher

A **Link** category with three apps that talk to Hackaday Supercon 2026 badges over Wi-Fi, using the badge
link protocol ([PROTOCOL.md](../../../PROTOCOL.md), UDP port 4626):

| App | What it does |
|---|---|
| Badge Finder (`finder/`) | Nearby Supercon badges (our Crystal firmware, and badge os badges through a Crystal bridge) with an RSSI distance estimate; SELECT for a warmer/colder view of one badge |
| Remote (`remote/`) | Pick a Crystal Supercon badge and switch its screen, tap its buttons, send nametag text, draw on its Sketch with the joystick |
| Link Pong (`netpong/`) | badge os's two-badge Pong, BeagleBadge buttons against the Supercon badge's knob; each badge draws its own view |

`_badgenet.py` (protocol + the Pong engine) and `_linkui.py` (LVGL helpers) are shared; the leading underscore
keeps the app loader from loading them as apps. The Supercon badge needs network mode on: LINK screen, User A,
or `net on` in its USB shell, with Wi-Fi set (`wifi <ssid> <password>`) to the same network as the BeagleBadge.

Install on the BeagleBadge (as root): `crystal/net/install_beagle.sh` (fetches this folder from GitHub into
`/opt/badge_launcher/applications/link/` and restarts `badge-launcher.service`).

Testing without a Supercon badge: `python3 /opt/badge_launcher/tools/sim_badge.py 300` on the BeagleBadge
pretends to be a Crystal badge (and one bridged badge os badge) and plays Pong with an AI paddle.

License: MIT, like badge-launcher. The Pong rules and packets are from yigitabi5444/supercon26-badge-os.
