#!/bin/sh
# Badge-link robot tournaments on the host: the badge's main/tourney_net.c
# (+ robonet.c) in host_badge against two crystal/net/sim_badge.py
# simulators (tourney.py), three "badges" on localhost UDP, each playing the
# whole tournament with the badge engine (bin/rb tourney) and cross-checking.
#   1. the badge code has the lowest MAC: it organizes
#   2. a simulator has the lowest MAC: the badge code asks it to organize
#   3. a simulator whose engine disagrees is caught by the organizing badge
#   4. 20 % of the badge code's packets lost
#   5. the badge code is busy in another app (robot autojoin): it does not
#      join, only notes the tournament nearby; the simulators play without it
# (test_join.c: the join rule itself, case by case)
#
#   crystal/firmware/test/robonet/tourney.sh
set -eu
cd "$(dirname "$0")"
HERE=$(pwd)
NET=$HERE/../../../net
mkdir -p bin
crystal build --prelude=empty ../robots/empty_prelude.cr -o bin/rb
crystal run ../robots/dump_roster.cr -- bin/roster
gcc -O1 -g -Wall -I../../main -o bin/host_badge host_badge.c ../../main/robonet.c ../../main/tourney_net.c
gcc -O1 -g -Wall -I../../main -o bin/test_join test_join.c ../../main/tourney_net.c ../../main/robonet.c
R=bin/roster
# players' own robots: built-ins under new names (so new sources)
mk() { sed "s/main(\"[A-Za-z]*\")/main(\"$2\")/" "$R/$1.cr" > "bin/$2.cr"; }
mk sniper Ace; mk hunter Blaze; mk circler Comet; mk dodger Dash; mk turret Echo
printf '#!/bin/sh\n"%s/bin/rb" "$@" | sed "s/^hash .*/hash 1/"\n' "$HERE" > bin/rb_wrong
chmod +x bin/rb_wrong

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: exit $3, expected $2"; fail=1; fi
}
B="--builtin $R/rook.cr --builtin $R/rabbit.cr --builtin $R/target.cr"
SB="--builtins $R/rook.cr $R/rabbit.cr $R/target.cr"

# run <tag> <host mac> <host extra args> <simB engine>
run() {
  P=$1
  python3 "$NET/sim_badge.py" 90 --port $((P + 1)) --link-port $((P + 9)) --bcast 127.0.0.1:$P \
    --bcast 127.0.0.1:$((P + 2)) --name SimA --engine bin/rb --mine bin/Blaze.cr bin/Comet.cr $SB \
    > bin/tA$P.log 2>&1 &
  A=$!
  python3 "$NET/sim_badge.py" 90 --port $((P + 2)) --link-port $((P + 9)) --bcast 127.0.0.1:$P \
    --bcast 127.0.0.1:$((P + 1)) --name SimB --engine "$4" --mine bin/Dash.cr $SB \
    > bin/tB$P.log 2>&1 &
  SB_PID=$!
  set +e
  bin/host_badge --port $P --bcast 127.0.0.1:$((P + 1)) --bcast 127.0.0.1:$((P + 2)) --secs 80 \
    --mac "$2" --name HostBadge --engine bin/rb --mine bin/Ace.cr --mine bin/Echo.cr $B \
    --tourney 2 --seed 7 --seeds 1 $3 > bin/tH$P.log 2>&1
  H=$?
  wait $A; SA=$?
  wait $SB_PID; SBX=$?
  set -e
}

# 1. badge code organizes (lowest MAC)
run 4661 f41200000001 "" bin/rb
check "badge organizes: badge verdict" 0 $H
check "badge organizes: sim A verdict" 0 $SA
check "badge organizes: sim B verdict" 0 $SBX
grep -q "organizing" bin/tH4661.log || { echo "FAIL badge did not organize"; fail=1; }
n=$(sed -n 's/.*tournament [0-9a-f]* seed [0-9]*, \([0-9]*\) robots.*/\1/p' bin/tH4661.log)
check "badge organizes: 5 player robots + 3 built-ins" 8 "$n"
grep -q "standings .*champion" bin/tH4661.log || { echo "FAIL no standings"; fail=1; }

# 2. a simulator organizes (lower MAC); the badge code asks it
run 4671 f4ffffffff01 "" bin/rb
check "sim organizes: badge verdict" 0 $H
check "sim organizes: sim A verdict" 0 $SA
check "sim organizes: sim B verdict" 0 $SBX
grep -q "asking SimA to organize" bin/tH4671.log || { echo "FAIL badge did not ask SimA"; fail=1; }
grep -q "organizing" bin/tA4671.log || { echo "FAIL SimA did not organize"; fail=1; }
# everyone shows the organizer's standings
ranks=$(sed -n 's/.*standings [0-9a-f]* hash [0-9]* (mine [0-9]*): \(ranks.*\)/\1/p' bin/tH4671.log)
[ -n "$ranks" ] || { echo "FAIL badge got no standings from the sim"; fail=1; }

# 3. sim B's engine disagrees: the organizing badge catches it
run 4681 f41200000001 "" bin/rb_wrong
check "a different result is detected (badge)" 3 $H
grep -q "SimB got a DIFFERENT result" bin/tH4681.log || { echo "FAIL badge did not name SimB"; fail=1; }

# 4. packet loss
run 4691 f41200000001 "--loss 20" bin/rb
check "20 % packet loss: badge verdict" 0 $H
check "20 % packet loss: sim A verdict" 0 $SA

# 5. a badge busy elsewhere does not join (sim A organizes, lower MAC)
P=4701
python3 "$NET/sim_badge.py" 60 --port $((P + 1)) --link-port $((P + 9)) --bcast 127.0.0.1:$P \
  --bcast 127.0.0.1:$((P + 2)) --name SimA --engine bin/rb --mine bin/Blaze.cr bin/Comet.cr $SB --tourney 2 --seeds 1 \
  > bin/tA$P.log 2>&1 &
A=$!
python3 "$NET/sim_badge.py" 60 --port $((P + 2)) --link-port $((P + 9)) --bcast 127.0.0.1:$P \
  --bcast 127.0.0.1:$((P + 1)) --name SimB --engine bin/rb --mine bin/Dash.cr \
  > bin/tB$P.log 2>&1 &
SB_PID=$!
set +e
bin/host_badge --port $P --bcast 127.0.0.1:$((P + 1)) --bcast 127.0.0.1:$((P + 2)) --secs 40 \
  --mac f4ffffffff01 --name HostBadge --engine bin/rb --mine bin/Ace.cr --no-join > bin/tH$P.log 2>&1
wait $A; SA=$?
wait $SB_PID; SBX=$?
set -e
check "busy badge left out: sim A verdict" 0 $SA
check "busy badge left out: sim B verdict" 0 $SBX
grep -q "nearby, not joining" bin/tH$P.log || { echo "FAIL busy badge did not note the tournament"; fail=1; }
if grep -q "joined" bin/tH$P.log; then echo "FAIL busy badge joined"; fail=1; fi
if grep -q "HostBadge brings" bin/tA$P.log; then echo "FAIL organizer got robots from the busy badge"; fail=1; fi

bin/test_join || fail=1

[ $fail = 0 ] && echo "tourney net: all passed" || { tail -n 15 bin/t[HAB]46*.log; exit 1; }
