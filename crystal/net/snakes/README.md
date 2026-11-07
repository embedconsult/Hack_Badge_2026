# SNAKES: write a bot, bring it to the arena

SNAKES is a bot arena app on the Crystal firmware for the Supercon 2026 badge. Up to four snakes play on
an 11x11 board, the badge is the referee, and every snake except the built-in house snake is **a bot you
write**: a small web server, in any language, that the badge asks for a move each turn.

The bot API is the open snake-bot move API (`GET /`, `POST /start`, `/move`, `/end`), so a bot you already
have for that API works here as it is. Give the badge its URL.

## Quick start

1. Run the example bot on a laptop on the same Wi-Fi as the badge (Python 3, standard library only):

   ```sh
   python3 example_bot.py --port 8000 --name mybot
   ```

2. On the badge's USB shell (`idf.py monitor`, or any serial terminal at the badge's USB port), with the
   badge's Wi-Fi set (`wifi <ssid> <password>`):

   ```text
   snakes add mybot http://192.168.1.20:8000
   snakes list
   snakes play
   ```

   `snakes play` opens SNAKES and starts a game right away. You can also open SNAKES from the home screen
   and press **A**.

3. Make your bot better: edit `choose()` in `example_bot.py`, restart it, press **A** for another game.

### Shell commands

| Command | |
|---|---|
| `snakes list` | the saved bots (up to 6) |
| `snakes add <name> <url>` | save a bot; the same name again replaces its URL. Names: up to 15 of `A-Z a-z 0-9 - _ .` |
| `snakes rm <name\|#>` | forget a bot (by name or list number) |
| `snakes play` | go to SNAKES and start a game |

Bots are saved in the badge's NVS and survive reboots and firmware updates.

### On the badge

- **Lobby**: the saved bots, each checked with `GET /` (online + reply time + author, or no answer).
  **A** plays, **B** sets how many house snakes join (0 to 4). The players are the house snakes first,
  then the saved bots in list order, four at most. No bots saved: house snakes play each other.
- **Game**: the board, and per snake its length, health, how long its last answer took, missed moves and
  its last shout. **A** pauses, **B** stops. The board updates once per turn (about 0.7 s a turn).
- **Result**: winner, then everyone in the order they lasted. **A** plays again, **B** back to the lobby.

## The API

The badge sends JSON over HTTP/1.1 with `Connection: close`. All coordinates are cells, `x` from 0 at
the left, **`y` from 0 at the bottom** (`"up"` is `y + 1`).

| Request | When | Your answer |
|---|---|---|
| `GET /` | lobby check | bot info: `{"apiversion": "1", "author": "you", "color": "#000000", "head": "default", "tail": "default", "version": "0.1"}` (the badge shows `author`) |
| `POST /start` | a game begins | anything (ignored) |
| `POST /move` | every turn, while your snake is alive | `{"move": "up"}` (`up`, `down`, `left`, `right`), optional `"shout"` (shown on the badge, 48 characters) |
| `POST /end` | the game is over (or was stopped) | anything (ignored) |

If your URL has a path (`http://host:8000/bots/v2`), the endpoints go below it (`/bots/v2/move`).

Every POST body:

```json
{
  "game": {"id": "badge-1a2b3c4d", "ruleset": {"name": "standard", "version": "badge-1",
           "settings": {"foodSpawnChance": 15, "minimumFood": 1, "hazardDamagePerTurn": 0}},
           "map": "standard", "timeout": 500, "source": "custom"},
  "turn": 12,
  "board": {
    "height": 11, "width": 11,
    "food": [{"x": 5, "y": 5}],
    "hazards": [],
    "snakes": [
      {"id": "snake-1", "name": "house-1", "health": 88, "body": [{"x": 2, "y": 3}, {"x": 2, "y": 2}, {"x": 2, "y": 1}],
       "latency": "0", "head": {"x": 2, "y": 3}, "length": 3, "shout": "", "squad": "",
       "customizations": {"color": "#000000", "head": "default", "tail": "default"}}
    ]
  },
  "you": {"id": "snake-2", "name": "mybot", "...": "your own snake, same fields"}
}
```

`board.snakes` holds the living snakes; `body[0]` is the head. `latency` is how many ms that snake's
previous answer took.

## Rules (standard)

- 11x11 board, up to 4 snakes. Each starts in a corner as 3 segments stacked on one cell, with health
  100, a food diagonally next to it and one in the centre.
- Every turn, in this order: all snakes move at once; health drops by 1; a snake whose head lands on
  food eats it (health back to 100, length + 1: its tail stays put for a turn); new food appears (always at
  least 1 on the board, else a 15 % chance of one more per turn); then snakes are eliminated:
  - head off the board, or health 0;
  - head on any body segment (its own or another snake's; a tail that moved away this turn is free);
  - head-to-head on the same cell: the shorter snake is out, equal length both are out.
- The last snake standing wins; if the last ones go out together it is a draw. A one-snake game ends when
  the snake dies.

## Timing: the badge is the referee

- Each turn the badge asks **all living bots at once** and waits **500 ms** in total, network included.
  A bot that does not answer a usable move in time gets an **automatic safe move**: its last direction
  (`up` on the first turn) if that does not hit a wall or a body, else the house snake's pick. The badge
  counts those as missed moves and shows `MISSED (AUTO)` for that turn.
- While your bot thinks, the badge is busy updating the e-paper with the previous turn, so a turn takes
  about 0.7 s whatever you do. Use your 500 ms.
- Plain `http://` on the local network is the fast, reliable choice. `https://` URLs work (the badge
  keeps one TLS connection per bot for the game), but a TLS handshake on the badge takes a while; far
  away cloud hosts may miss the deadline.
- `/start` and `GET /` get 3 s, `/end` 1 s.

## Writing a bot

Anything that serves HTTP works: Python, Go, Rust, Node, Crystal, a Raspberry Pi, another badge. Start
from `example_bot.py` (one file, no dependencies). It does what most first bots should do:

1. never move off the board or into a body (tails that will move away are fine);
2. avoid the cells next to the head of a snake that is as long or longer (head-to-head);
3. go for the nearest food.

Ideas from there: flood fill (do not walk into a space smaller than you), chase shorter snakes'
heads, cut others off, look a few turns ahead. The house snake on the badge
(`crystal/firmware/src/games/snakes_house.cr`) does 1-3 plus flood fill.

Try your bot without a badge: `crystal/firmware/test/snakes/run.sh` runs the badge's referee code (the
same C HTTP client and Crystal rules) against bots on the local machine, and `example_bot.py --delay 800`
shows what a too-slow bot looks like. A quick manual check:

```sh
curl -s localhost:8000/
curl -s -X POST localhost:8000/move -H 'Content-Type: application/json' \
  -d '{"game":{"id":"t"},"turn":0,"board":{"width":11,"height":11,"food":[],"hazards":[],"snakes":[{"id":"a","body":[{"x":1,"y":1}],"head":{"x":1,"y":1},"length":1}]},"you":{"id":"a","body":[{"x":1,"y":1}],"head":{"x":1,"y":1},"length":1}}'
```

## Files

| | |
|---|---|
| `crystal/net/snakes/example_bot.py` | the example bot |
| `crystal/firmware/src/apps/snakes.cr` | the app: lobby, game loop, screen |
| `crystal/firmware/src/games/snakes_rules.cr` | the rules engine (host specs: `crystal spec test/snakes_spec.cr`) |
| `crystal/firmware/src/games/snakes_house.cr` | the house snake |
| `crystal/firmware/main/snakes.c` | bot API JSON, the parallel HTTP client, the shell command (host tests: `test/snakes/run.sh`) |
| `crystal/firmware/main/snakes_net.c` | the badge side: Wi-Fi, worker task, https, NVS |
