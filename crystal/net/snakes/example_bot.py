#!/usr/bin/env python3
"""A tiny SNAKES bot: Python standard library only.

Speaks the open snake-bot move API, so the badge arena (and any other
referee for that API) can play it by URL:

    GET  /        -> bot info
    POST /start   -> a game begins (reply ignored)
    POST /move    -> {"move": "up|down|left|right", "shout": "..."}
    POST /end     -> the game is over (reply ignored)

Strategy: never step off the board or into a body (tails that will move
away are fine), stay away from cells next to bigger heads, then head for
the nearest food. Good enough to beat a careless bot, easy to improve.

    python3 example_bot.py [--port 8000] [--name NAME] [--delay MS]

--delay sleeps before every /move answer (to try the referee's timeout).
Register it on a badge (same Wi-Fi):  snakes add mybot http://<your-ip>:8000
"""
import argparse
import json
import random
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MOVES = {"up": (0, 1), "down": (0, -1), "left": (-1, 0), "right": (1, 0)}
ARGS = None


def choose(state):
    board, you = state["board"], state["you"]
    w, h = board["width"], board["height"]
    head = you["head"]
    blocked = set()
    for s in board["snakes"]:
        body = s["body"]
        # the tail moves away unless the snake just ate (tail is doubled)
        keep = body if len(body) > 1 and body[-1] == body[-2] else body[:-1]
        blocked.update((p["x"], p["y"]) for p in keep)
    danger = set()
    for s in board["snakes"]:
        if s["id"] != you["id"] and s["length"] >= you["length"]:
            hx, hy = s["head"]["x"], s["head"]["y"]
            danger.update((hx + dx, hy + dy) for dx, dy in MOVES.values())
    food = [(f["x"], f["y"]) for f in board["food"]]

    def score(move):
        dx, dy = MOVES[move]
        x, y = head["x"] + dx, head["y"] + dy
        if not (0 <= x < w and 0 <= y < h) or (x, y) in blocked:
            return None
        s = 0.0
        if (x, y) in danger:
            s -= 100
        if food:
            s -= min(abs(x - fx) + abs(y - fy) for fx, fy in food)
        return s + random.random() * 0.1

    scored = [(score(m), m) for m in MOVES]
    scored = [(s, m) for s, m in scored if s is not None]
    return max(scored)[1] if scored else "up"


class Bot(BaseHTTPRequestHandler):
    def reply(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the referee gave up on us (too slow): the move is lost

    def do_GET(self):
        self.reply({"apiversion": "1", "author": ARGS.name, "color": "#000000",
                    "head": "default", "tail": "default", "version": "0.1"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        state = json.loads(self.rfile.read(n) or b"{}")
        path = self.path.rstrip("/").rsplit("/", 1)[-1]
        if path == "move":
            if ARGS.delay:
                time.sleep(ARGS.delay / 1000)
            move = choose(state)
            self.reply({"move": move, "shout": f"turn {state.get('turn')}: {move}"})
        elif path in ("start", "end"):
            if path == "end" and not ARGS.quiet:
                you = state.get("you", {})
                print(f"game {state['game']['id']} over at turn {state['turn']}, length {you.get('length')}",
                      flush=True)
            self.reply({})
        else:
            self.send_error(404)

    def log_message(self, fmt, *a):
        if not ARGS.quiet:
            super().log_message(fmt, *a)


def main():
    global ARGS
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--name", default="example")
    p.add_argument("--delay", type=int, default=0, help="ms to wait before each /move reply")
    p.add_argument("--quiet", action="store_true")
    ARGS = p.parse_args()
    srv = ThreadingHTTPServer((ARGS.host, ARGS.port), Bot)
    print(f"snake bot '{ARGS.name}' on http://{ARGS.host}:{ARGS.port}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
