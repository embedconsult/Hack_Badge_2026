# Badge link protocol (BLNK v1)

How three kinds of badges find and talk to each other:

| Badge | Radio | Speaks |
|---|---|---|
| **BeagleBadge** (TI AM62L, Linux, badge-launcher) | TI CC33xx Wi-Fi (`cc33xx` mac80211 driver) | UDP (this protocol) |
| **Supercon 2026 badge, our Crystal firmware** | ESP32-S3 | UDP (this protocol) **and** ESP-NOW (yigitabi formats); bridges the two |
| **Supercon 2026 badge, yigitabi5444's badge os** | ESP32-S3 | ESP-NOW on channel 1: `BOSR` ranging beacons, `PONG` packets |

## 1. Can the BeagleBadge speak ESP-NOW itself?

ESP-NOW is an 802.11 *action* frame (category 127 vendor specific, OUI `18:fe:34`) sent to the
broadcast or a peer MAC, outside any BSS. Findings on the BeagleBadge (kernel 6.12, `iw list`, `lsmod`):

- Chip/driver: TI **CC33xx** over SDIO, `cc33xx` + `mac80211` (`/sys/class/net/wlan0/device/driver` ->
  `cc33xx_driver`).
- Interface modes include **monitor**, and `iw phy phy0 interface add mon0 type monitor` works *next to*
  the associated `wlan0`. **Transmit works**: ESP-NOW frames written to `mon0` (AF_PACKET + radiotap) go
  out on wlan0's channel; a Crystal badge received 24 of 25 injected `BOSR` beacons and listed the
  BeagleBadge as a badge os badge (`crystal/net/espnow_nl80211.py inject`).
- **Receive does not**: the CC33xx firmware filters what reaches the host. `mon0` sees only a few beacons
  and data frames, and an nl80211 `REGISTER_FRAME` for `7f 18 fe 34` action frames on `wlan0` registers
  fine but never gets one, while a Crystal badge beacons ESP-NOW at 1 Hz a few cm away.
- `NL80211_CMD_FRAME` on `wlan0` fails with ENOTCONN (station mode refuses frames outside its BSS).
- Channel: the BeagleBadge's Wi-Fi follows its access point (tonight a phone hotspot on channel 6);
  badge os uses a fixed channel 1. Injection goes out on the current channel only.

So the **working path is UDP on the shared Wi-Fi**, with our Supercon badge as an **ESP-NOW bridge**
(needed for receiving). The BeagleBadge can additionally send ESP-NOW itself through `mon0`.

## 2. Transport

- UDP, port **4626**, IPv4, on the Wi-Fi network both badges joined.
- Discovery: broadcast to `255.255.255.255:4626` every ~1 s (+0..250 ms jitter).
- Everything else: unicast to the address the peer's announce came from.
- No reliability layer: every message is idempotent or repeated (announces, game state at 10 Hz).
  Commands are answered with `R`; the sender may retry once after 500 ms.

## 3. Packet header (12 bytes, all packets)

| Offset | Size | Field |
|---|---|---|
| 0 | 3 | magic `"BLK"` |
| 3 | 1 | version, `1` (receivers drop other versions) |
| 4 | 1 | type, ASCII letter (below) |
| 5 | 1 | sequence number (wraps; for logs and duplicate commands) |
| 6 | 6 | sender identity: its Wi-Fi station MAC |

Multi-byte numbers are little endian (as on both CPUs). Strings are UTF-8/ASCII, zero padded, not
necessarily zero terminated.

## 4. Messages

### `H` hello / announce (broadcast, ~1 Hz)

| Offset | Size | Field |
|---|---|---|
| 12 | 1 | kind: 1 = BeagleBadge, 2 = Supercon/Crystal, 3 = Supercon/badge os (sent *by a bridge* for it) |
| 13 | 1 | caps bits: 1 remote control, 2 pong, 4 ESP-NOW bridge, 8 sketch, 16 robot battles (G J B K Z, tournaments T) |
| 14 | 1 | screen id (Crystal: 0 nametag 1 portrait 2 sketch 3 life 4 snake 5 diag 6 link 7 pong; else 255) |
| 15 | 1 | flags: 1 = in a pong game |
| 16 | 6 | `via`: the bridge's MAC for kind 3, else zero. The badge itself has the MAC in the header |
| 22 | 12 | name |
| 34 | 1 | n, number of heard entries (<= 8) |
| 35 | 9 n | heard: `mac[6]`, `rssi` int8 dBm (127 = unknown), `cm` int16 (FTM distance, -1 unknown) |

The heard list is what the sender measured itself: the RSSI of frames it captured *from* that MAC. The
Supercon badge runs the ESP32's promiscuous mode on its station channel and records the RSSI of every frame
transmitted by a MAC it knows (from announces); that is how the BeagleBadge learns its distance to a
Supercon badge (its own driver cannot report per-sender RSSI for frames relayed by the AP). For
bridged badge os badges the entry is the ESP-NOW RSSI at the bridge, and `cm` is copied from their `BOSR`
shared FTM ranges when one of them is about the bridge.

Distance estimate (receiver side): `d = 10 ^ ((RSSI_1m - rssi) / (10 n))`, `RSSI_1m = -45 dBm`, `n = 2.5`,
smoothed as the max RSSI over the last 4 s, shown in buckets (here < 1 m, near 1-3 m, room 3-8 m, far).
FTM (`cm >= 0`) wins over RSSI when present. See yigitabi's RADAR_RESEARCH.md for why RSSI is rough.

### `C` command (unicast) and `R` reply

`C` body: one ASCII command line, at most 120 bytes, no newline. `R` body: one status byte (0 ok,
1 refused, 2 busy, 3 bad syntax), the request's sequence number, then optional ASCII text.

Commands accepted by the Crystal badge (the same words as its USB shell, which executes them on the
shell task so only the main task ever drives the e-paper):

| Command | Effect |
|---|---|
| `mode <nametag\|portrait\|sketch\|life\|snake\|diag\|link\|pong>` | switch screen |
| `press <a\|b\|plus\|minus>` | a button tap (plus/minus = menu next/previous) |
| `hold a` / `colour` | the long-press colour refresh |
| `knob <l\|r> <mV>` / `knob off` | override a knob (drives Sketch, Life, Snake) |
| `stroke x0 y0 x1 y1` | a line on the Sketch canvas, x 134..824, y 123..522 |
| `sketch quickdraw` | Sketch draws its six-shooter |
| `text <line1>[\|<line2>]` | set the nametag name (saved), shows the nametag |
| `pong` | go to the PONG screen and pair with the sender at once (no button dance) |
| `pong seek` | go to the PONG screen and start badge os pairing, as if User A was pressed there |
| `status` | logs status on the badge console (reply is just ok) |
| `robot` / `robot list` | lists the robot slots and built-in robots on the badge console |
| `robot run <r1> <r2> [r3] [r4] [@seed]` | a robot battle on the ROBOTS screen (slot numbers or built-in names) |

Everything else (`wifi`, `ota`, `reboot`, `net`, `dump`, `flag`, `upd`, and `robot put/del/challenge`) is
refused from the network.
Remote control is only active while the badge has network mode on (`net on`, or the LINK screen).

### `P` pong (unicast; `P_PAIR` broadcast)

Body: badge os's `pkt_t` from `main/link.h`, byte for byte (25 bytes):

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `"PONG"` |
| 4 | 1 | 1 = `P_PAIR` (seeking), 2 = `P_GAME` |
| 5 | 2 | `age`: ms since the sender pressed pair (P_PAIR) |
| 7 | 6 | `peer`: the sender's choice (zero while undecided) or its peer |
| 13 | 12 | `game_t`: `bx, by` int16, `dx, dy` int8, `py[2]` int16, `score[2]` uint8 |

Game rules are badge os's, unchanged: court 960 x 624 (y = 0 is 48 px below the panel top), ball 24,
paddle 16 x 120 at 24 px from its edge, step 15 ms, first to 4. The badge with the **lower MAC is host**:
it owns the ball and sends the whole state; the guest sends only `py[1]`. Each side draws its own
paddle on the left (the guest mirrors x). A peer silent for 1 s ends the game. Pairing is badge os's: both
press within 500 ms; or, between BeagleBadge and a Crystal badge, the `pong` command pairs at once. The
BeagleBadge scales the court to its 400 x 300 panel; the game state stays in badge os units.

### `E` ESP-NOW tunnel (bridge)

Body: `mac[6]`, `rssi` int8, then an ESP-NOW payload (<= 200 bytes).

- Bridge -> UDP broadcast: an ESP-NOW frame the bridge received with magic `BOSR` or `PONG`; `mac` is
  its sender, `rssi` its RSSI. (PONG frames are consumed instead when the bridge itself is in a game.)
- UDP -> bridge (unicast): the bridge sends the payload over ESP-NOW to `mac` (`ff:ff:ff:ff:ff:ff` =
  broadcast). The frame leaves with the **bridge's** MAC, so a BeagleBadge playing Pong with a badge os
  badge through a bridge uses the bridge's MAC as its identity inside `pkt_t` (`peer` fields, host
  election). Only one tunnelled game per bridge.

### Robot battles: `G` challenge, `J` answer, `B` source chunk, `K` chunk ack, `Z` result (unicast)

Badge-to-badge battles of the ROBOTS app (crystal-robots robots; badge code: `main/robonet.c`,
Python: `crystal/net/robonet.py`). Nothing of the battle itself goes over the air: **both badges
simulate it** with the same engine (it is deterministic: same robot sources in the same order, same
seed and cycle limit give the same battle), then exchange results to cross-check. Robots are named by
CRC-32 (zlib/IEEE) and length of their source, so a badge that already has a robot (a built-in, or
from an earlier battle; the badge keeps 8 sources) is not sent it again. All numbers little endian;
seeds are below 2^31.

| Type | Body |
|---|---|
| `G` challenge | `id` u32 (random), `seed` u32, `limit` u32 (CROBOTS cycles, normally 500000), `n` u8 (2..4), then `n` x {`crc` u32, `len` u16}: the robots in battle order |
| `J` answer to `G` | `id` u32, `status` u8 (0 accepted, 1 missing robots, 2 busy), `missing` u8 (bit k = robot k, for status 1) |
| `B` source chunk | `crc` u32, `len` u16 (whole source, <= 8160), `off` u16 (multiple of 512), then `min(512, len - off)` source bytes |
| `K` chunk ack | `crc` u32, `off` u16, `status` u8 (0 stored, 1 refused) |
| `Z` result | `id` u32, `cycles` u32, `winner` i8 (robot index, -1 none), `n` u8, `damage` n x u8, `hash` u32, `have` u8 (1 = I have your `Z`) |

Flow (the challenger is A):

0. Only peers announcing caps bit 16 (robot battles) are challenged. They are reached at the source
   address and **port** of their announces: a badge's is 4626, a simulator's its own (4627 by
   default). The badges broadcast their announces to 4626, so a simulator binds its own port and also
   listens on 4626 (receive only, `SO_REUSEADDR`, shared with the BeagleBadge's launcher apps).
1. A sends `G` (every 400 ms until answered, for 20 s: a badge may be busy redrawing its e-paper).
   B answers `J`: 0 if it has every robot and is free, 1 with the bit mask of the robots it lacks,
   2 if a battle is going on.
2. On `J` 1, A sends the missing sources as `B` chunks, one at a time, each repeated every 400 ms
   until B's matching `K` (again 20 s at most per chunk); then `G` again. B assembles the chunks and
   keeps a source when its CRC-32 checks out.
3. On `J` 0 both badges switch to ROBOTS and play the battle (the Crystal badge: the same as
   `robot run`, with the given seed and limit). The Crystal badge simulates the whole battle at once
   (well under a second), sends its `Z`, and only then shows it, replaying the same battle frame by
   frame; so its result does not wait for the 5-9 s of e-paper refreshes.
4. Each badge sends `Z` as soon as it has its result and repeats it every second until it has the
   peer's `Z` (the Crystal badge gives up after 120 s; a simulator waits as long as it runs).
   A badge answers a `Z` whose `have` is 0 with its own `Z`. With both, each compares cycles, winner,
   damages and `hash` (FNV-1a 32 of cycles, robot count, and per robot x, y, damage, restarts,
   cycles run, active, failed: `RB.result_hash` in `src/robots/battle.cr`) and shows
   "<peer> got the same result" or "a DIFFERENT result!".

On the Crystal badge: `robot challenge <badge> <r1> <r2> [r3] [r4] [@seed]` in the USB shell (network
mode on; `<badge>` = the start of its announced name, or the last hex digits of its MAC). Host test:
`crystal/firmware/test/robonet/run.sh` runs the badge's `robonet.c` against `sim_badge.py` over UDP
on localhost: both directions, a peer with a different result, 30 % packet loss, and the real port
layout (badge code on its link port, broadcasting to it; simulator on its own port listening on the
link port too) with a badge that holds its result back 10 s.

### Robot tournaments: `T` (unicast), sources as `B` chunks

A tournament of every robot badge's saved robots (badge code: `main/tourney_net.c`, Python:
`crystal/net/tourney.py`; schedule and scoring: `src/robots/tourney.cr`). Nothing of the battles goes
over the air: every badge plays the **whole** tournament itself (round robin of 2-4 robot line-ups,
`seeds` battles per line-up, then a final of the top four; the same robots in the same order with the
same seed give the same tournament) and the organizer compares the tournament hashes.

The **organizer** is the badge with the lowest MAC among those announcing caps bit 16. A badge asked to
start one (`robot tourney net`, B: LINK TOURNEY on ROBOTS) organizes if it is the lowest, else sends `O`
to the lowest, which waits 2.5 s (to hear every announce), then organizes with every live robot badge,
the asker included.

Joining is opt-in on the Crystal badge (`robot autojoin on|off`, NVS net/autojoin, also on the Settings
page; default on): it answers a `Q` only while it shows Home or ROBOTS, or after 60 s without a button
press or knob turn, and always when it asked for the tournament itself. Otherwise it stays silent (the
organizer leaves it out after 20 s), logs it and shows TOURNEY NEARBY in its top bar for 30 s.

Every `T` body starts with `sub` (one ASCII letter) and `tid` u32 (the tournament; 0 in `O`):

| sub | From -> to | Rest of the body |
|---|---|---|
| `O` organize | asker -> lowest MAC | `seed` u32 (0: pick one), `seeds` u8 (1..4) |
| `Q` query | organizer -> each badge | (none); repeated every 400 ms, 20 s, then the badge is left out |
| `E` entries | badge -> organizer | `n` u8 (<= 8), then `n` x {`crc` u32, `len` u16}: its slot robots |
| `S` send me | anyone -> a badge that has it | `crc` u32, `len` u16, `got` u32 (bit k: chunk k already here). The receiver sends up to 4 of the missing chunks as ordinary `B` messages; the asker repeats every 400 ms |
| `P` plan | organizer -> each badge | `seed` u32, `seeds` u8, `nb` u8 badges, `n` u8 robots (2..48); `nb` x {`mac`[6], `name`[12]} (badge 0 = organizer); `n` x {`crc` u32, `len` u16, `owner` u8 (badge index, 255 = built-in)}: the robots in tournament order. Every second until acknowledged |
| `A` ack | badge -> organizer | `missing` u8: robots it still lacks (it fetches them with `S` from the organizer; 0 = playing) |
| `R` result | badge -> organizer | `hash` u32 of its whole tournament (`Tour.hash`); every second until `W` |
| `W` standings | organizer -> each badge | `hash` u32 (the organizer's), `nb` u8, `nb` x `agree` u8 (1 same hash, 0 different, 2 no result), `tlen` u16, then the standings: per rank {`robot` u8, `wins` u8, `draws` u8, `played` u8, `damage` u16 (sum)}, then `champion` u8 and `final winner` u8 (robot, 255 none) |

Order of the robots: the organizer's slots, then each badge's in MAC order, then the organizer's
built-ins; a robot already in the list (same CRC and length) is not added again. Robots whose source
cannot be fetched within 60 s are left out; badges that never take the plan (60 s) or send no result
(15 min) are reported as "sent none". Every badge shows the organizer's standings, with the owner
badge of each robot, and the verdict ("all 3 badges got the same result" / "<badge> got a DIFFERENT
result!"); the Crystal badge saves them in NVS (`robot standings net`) and replays the final.

Host test: `crystal/firmware/test/robonet/tourney.sh` runs `main/tourney_net.c` (host_badge) with two
`sim_badge.py --mine ... [--tourney N]` simulators on localhost: the badge code organizing, a simulator
organizing (the badge code asks it), a simulator with a lying engine caught, 20 % packet loss.

On a BeagleBadge, against a real Supercon badge:

```sh
# the badge engine for the BeagleBadge (aarch64): RB_STATIC=1 crystal/firmware/test/robonet/run.sh
# builds crystal/firmware/test/robonet/bin/rb statically; copy it and the robot files over, then
# with sim_badge.py: robonet.py and the repo's _badgenet.py (the launcher's installed copy in
# /opt/badge_launcher may be too old; sim_badge.py says so and stops)
python3 sim_badge.py 120 --name Beagle --engine ./rb                      # answer: badge runs `robot challenge Beagle sniper rook`
python3 sim_badge.py 120 --name Beagle --engine ./rb --challenge <badge> sniper.cr rook.cr --seed 42
```

The simulator binds 4627 and listens on 4626 next to the launcher apps. Caveat: while it runs, a
unicast to the BeagleBadge's port 4626 (a badge's `R` reply to a launcher app) may reach the
simulator's listener instead of the app (Linux gives a shared port's unicast to one socket);
broadcasts reach both.

`sim_badge.py` prints each step and the verdict (exit 0 same, 3 different, 4 failed). Without
`--engine` it still transfers robots and answers, but cannot compare.

## 5. ESP-NOW side (Crystal badge, compatible with badge os)

- Every ~1 s the Crystal badge broadcasts a badge os ranging beacon, so badge os's Radar lists it:
  `"BOSR"`, `ap[6]` (its SoftAP MAC; it does not answer FTM yet), `n = 0`, then the name (12 bytes).
- It parses `BOSR` beacons (name, shared FTM ranges) and lists those badges as kind 3 in its own
  announces (via = itself).
- ESP-NOW runs on the station's channel. **Bridging badge os needs channel 1**: either the access point is
  on channel 1, or `net ap on`, where the Crystal badge hosts a soft AP on channel 1 that the
  BeagleBadge joins. With tonight's hotspot on channel 6 the bridge only reaches badges on channel 6.

## 6. Network mode on the Crystal badge

- `net on` / `net off` in the USB shell, or User A on the LINK screen; saved in NVS (namespace `net`,
  key `on`). Wi-Fi credentials are the OTA ones (`wifi <ssid> <password>`).
- While on: Wi-Fi stays connected (reconnects forever), power save off (ESP-NOW would drop frames),
  promiscuous RX on, announces every second.
- LINK screen: network state, IP, channel, and the peers it knows with kind, RSSI and age.

### Access point mode (`net ap on`): one channel for everyone

The ESP32-S3 has one radio on one channel. In station mode it follows the access point (a phone hotspot
picks 1, 6 or 11 by itself), and badge os badges are fixed on channel 1, so they only meet when the
hotspot happens to be on 1. `net ap on` makes the Crystal badge the network instead:

- The badge runs a soft AP **`BADGE-LINK-xxxx`** (xxxx = last two bytes of its station MAC) on
  **channel 1**, WPA2 with password `supercon` (NVS `net/ap_pass` overrides; 8+ chars, else open),
  DHCP server, badge at **192.168.4.1/24**, up to 4 clients. No station meanwhile, so no internet and
  no OTA (`ota` says so; `net ap off` goes back to station mode). Saved as NVS `net/ap`.
- The BeagleBadge joins it (`crystal/net/beagle_wifi.sh badge`; `beagle_wifi.sh home` to go back).
  The protocol is unchanged: UDP 4626 broadcasts on 192.168.4.255/255.255.255.255.
- ESP-NOW runs on the AP interface, channel 1: badge os badges hear our `BOSR` beacons and Pong
  packets, and the bridge forwards theirs to the BeagleBadge. Our ESP-NOW identity becomes the
  **soft-AP MAC** (station MAC + 1), which is also our badge link identity in this mode, so badge os
  pairing and host election see one consistent address.
- RSSI of the BeagleBadge: the AP's station list (`esp_wifi_ap_get_sta_list`) plus promiscuous RX.
- The BeagleBadge's own ESP-NOW injection (`espnow_nl80211.py inject`) then also goes out on
  channel 1, because its wlan0 follows the badge's AP.
- Later: `ftm_responder = true` on this AP (needs `CONFIG_ESP_WIFI_FTM_ENABLE`) would let badge os
  badges FTM-range the Crystal badge, as they do each other.
- Coordination: the Settings app (apps-home branch) also starts a soft AP. Both use the one radio, so
  they cannot run at once; this mode's keys live in the `net` namespace (`ap`, `ap_pass`) and the
  Settings AP should stop network mode (`cr_net_set(false)`) before it starts and restart it after.

## Radar (Crystal app, src/apps/radar.cr + main/radar.c)

No new messages: the Radar uses what the `H` announce already carries.

- **Me to a badge**: the RSSI I measure from it (max over 4 s, net.c) and the RSSI it reports for me in
  its heard list, averaged in dB; FTM `cm` wins when present (badge os `BOSR` ranges).
- **Badge to badge**: each badge's heard list (`mac`, `rssi`, `cm`) gives the links between the others,
  so a badge that hears only some of the group still gets the whole set of pairwise distances.
- Each link keeps an EMA of its RSSI (weight 0.35 per ~1 s update, forgotten after 30 s), converted with
  `d = 10 ^ ((-45 - rssi) / 25)` metres.
- **Map** (3+ badges incl. me): stress majorization of the distance matrix with me pinned at the origin
  (a fresh trilateration start and a few shuffled starts against folds; the previous layout is kept
  unless a new one is 30 % better), then rotated/mirrored onto the previous frame (2-D Procrustes) so
  dots do not jump; first frame: lowest-MAC badge straight up, the next one to its right. Rotation and
  mirror are not observable (one antenna, no compass), and RSSI distances are rough (RADAR_RESEARCH.md
  in yigitabi5444's badge os, whose Radar inspired this).

## 7. Open experiments

1. Direct ESP-NOW on the BeagleBadge: TX done (injection), RX blocked by the CC33xx firmware. Worth
   checking for a firmware/driver knob (debugfs `cc33xx/beacon_filtering`, a "promiscuous" or sniffer mode
   in TI's firmware) before giving up on RX.
2. FTM between the Crystal badge (SoftAP responder) and badge os (`CONFIG_ESP_WIFI_FTM_ENABLE`).
