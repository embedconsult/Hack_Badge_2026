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
| 13 | 1 | caps bits: 1 remote control, 2 pong, 4 ESP-NOW bridge, 8 sketch |
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
| `status` | logs status on the badge console (reply is just ok) |

Everything else (`wifi`, `ota`, `reboot`, `net`, `dump`, `flag`, `upd`) is refused from the network.
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

## 5. ESP-NOW side (Crystal badge, compatible with badge os)

- Every ~1 s the Crystal badge broadcasts a badge os ranging beacon, so badge os's Radar lists it:
  `"BOSR"`, `ap[6]` (its SoftAP MAC; it does not answer FTM yet), `n = 0`, then the name (12 bytes).
- It parses `BOSR` beacons (name, shared FTM ranges) and lists those badges as kind 3 in its own
  announces (via = itself).
- ESP-NOW runs on the station's channel. **Bridging badge os needs channel 1**: either the access point is
  on channel 1, or (planned) `net ap`, where the Crystal badge hosts a SoftAP on channel 1 that the
  BeagleBadge joins. With tonight's hotspot on channel 6 the bridge only reaches badges on channel 6.

## 6. Network mode on the Crystal badge

- `net on` / `net off` in the USB shell, or User A on the LINK screen; saved in NVS (namespace `net`,
  key `on`). Wi-Fi credentials are the OTA ones (`wifi <ssid> <password>`).
- While on: Wi-Fi stays connected (reconnects forever), power save off (ESP-NOW would drop frames),
  promiscuous RX on, announces every second.
- LINK screen: network state, IP, channel, and the peers it knows with kind, RSSI and age.

## 7. Open experiments

1. Direct ESP-NOW on the BeagleBadge: TX done (injection), RX blocked by the CC33xx firmware. Worth
   checking for a firmware/driver knob (debugfs `cc33xx/beacon_filtering`, a "promiscuous" or sniffer mode
   in TI's firmware) before giving up on RX.
2. FTM between the Crystal badge (SoftAP responder) and badge os (`CONFIG_ESP_WIFI_FTM_ENABLE`).
