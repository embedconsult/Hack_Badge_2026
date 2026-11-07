#!/bin/sh
# Host tests for the SNAKES arena's network side (main/snakes.c) against the
# example bot (crystal/net/snakes/example_bot.py) run locally:
#   1. test_snakes: shell command, URLs, JSON, HTTP batch with one
#      deadline (a fast bot, a bot slower than the 500 ms timeout, a port
#      with nothing listening);
#   2. arena_host.cr: whole games of the Crystal rules engine + house
#      snake against example bots over HTTP, the badge's turn loop.
# The rules engine itself: crystal spec test/snakes_spec.cr.
set -eu
cd "$(dirname "$0")"
IDF=${IDF_PATH:-/opt/debian/opt/esp/esp-idf}
CJ=$IDF/components/json/cJSON
M=../../main
BOT=../../../net/snakes/example_bot.py
P1=${P1:-18701} P2=${P2:-18702} P3=${P3:-18703} P4=${P4:-18704}
mkdir -p bin
CF="-O1 -g -Wall -Wno-unused-function -I$M -I$CJ"
gcc -o bin/test_snakes test_snakes.c $M/snakes.c $CJ/cJSON.c $CF -lm
gcc -c -o bin/snakes.o $M/snakes.c $CF
gcc -c -o bin/cJSON.o $CJ/cJSON.c $CF

python3 -I $BOT --port $P1 --name fast --quiet --host 127.0.0.1 & B1=$!
python3 -I $BOT --port $P2 --name slow --quiet --host 127.0.0.1 --delay 800 & B2=$!
python3 -I $BOT --port $P4 --name rival --quiet --host 127.0.0.1 & B4=$!
trap 'kill $B1 $B2 $B4 2>/dev/null || true' EXIT INT TERM
for i in 1 2 3 4 5 6 7 8 9 10; do # wait for the bots to listen
  python3 -I -c "import socket,sys; [socket.create_connection(('127.0.0.1', p), 1).close() for p in ($P1, $P2, $P4)]" 2>/dev/null && break
  sleep 0.3
done
ok=0
./bin/test_snakes $P1 $P2 $P3 || ok=1
crystal run arena_host.cr -- $P1 $P4 || ok=1
exit $ok
