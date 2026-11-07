#!/bin/sh
# Robot tournaments on the host (src/robots/tourney.cr):
#   - the specs (schedule, scoring, ranking, saved standings) with the std
#     prelude: test/tourney_spec.cr
#   - the badge build (--prelude=empty) of the engine, `rb tourney`, on the
#     ten built-in robots: the same tournament twice gives the same battles,
#     standings and hash; another seed another hash.
#
#   crystal/firmware/test/robots/tourney.sh
set -eu
cd "$(dirname "$0")"
BIN=../robonet/bin
mkdir -p "$BIN"
crystal spec ../tourney_spec.cr
crystal build --prelude=empty empty_prelude.cr -o "$BIN/rb"
crystal run dump_roster.cr -- "$BIN/roster"
cd "$BIN/roster"
set -- sniper.cr rook.cr counter.cr rabbit.cr hunter.cr circler.cr dodger.cr turret.cr wallhugger.cr target.cr
../rb tourney 42 3 "$@" > ../tourney1.txt
../rb tourney 42 3 "$@" > ../tourney2.txt
../rb tourney 43 3 "$@" > ../tourney3.txt
fail=0
cmp -s ../tourney1.txt ../tourney2.txt || { echo "FAIL same seed, different tournament"; fail=1; }
h1=$(sed -n 's/^hash //p' ../tourney1.txt)
h3=$(sed -n 's/^hash //p' ../tourney3.txt)
[ -n "$h1" ] && [ "$h1" != "$h3" ] || { echo "FAIL hash $h1 vs $h3"; fail=1; }
battles=$(sed -n 's/^tourney robots 10 battles \([0-9]*\) .*/\1/p' ../tourney1.txt)
[ "$(grep -c '^battle ' ../tourney1.txt)" = "$battles" ] || { echo "FAIL battle count"; fail=1; }
[ "$(grep -c '^rank ' ../tourney1.txt)" = 10 ] || { echo "FAIL standings"; fail=1; }
grep -q '^final n 4 ' ../tourney1.txt || { echo "FAIL no final"; fail=1; }
grep -v '^battle ' ../tourney1.txt
[ $fail = 0 ] && echo "tourney: all passed" || exit 1
