#!/bin/sh
# Badge-to-badge robot battles on the host: main/robonet.c (the badge's
# code, in host_badge) against crystal/net/sim_badge.py + robonet.py over UDP
# on localhost, both simulating with the badge's engine (bin/rb, the robot
# engine built with --prelude=empty). Needs crystal, gcc, python3 and the
# upstream robots (test/robots/upstream.sh).
#
#   crystal/firmware/test/robonet/run.sh
#
# bin/rb is also the engine to copy to a BeagleBadge for sim_badge.py
# --engine (build there, or RB_STATIC=1 here for a static binary).
set -eu
cd "$(dirname "$0")"
HERE=$(pwd)
NET=$HERE/../../../net
UP=$HERE/../robots/upstream
[ -d "$UP" ] || ../robots/upstream.sh
mkdir -p bin
STATIC=""
[ "${RB_STATIC:-0}" = 1 ] && STATIC="--static"
crystal build --prelude=empty $STATIC ../robots/empty_prelude.cr -o bin/rb
gcc -O1 -g -Wall -I../../main -o bin/host_badge host_badge.c ../../main/robonet.c ../../main/tourney_net.c

fail=0
E=$UP/examples
R1=$E/sniper.cr; R2=$E/rook.cr; R3=$E/counter.cr; R4=$E/rabbit.cr

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: exit $3, expected $2"; fail=1; fi
}

# 1. the badge code challenges the simulator (which has no robots yet)
python3 "$NET/sim_badge.py" 25 --port 4632 --bcast 127.0.0.1:4631 --name SimBeagle --engine bin/rb \
  > bin/sim1.log 2>&1 &
SIM=$!
set +e
bin/host_badge --port 4631 --bcast 127.0.0.1:4632 --secs 20 --challenge SimBeagle --seed 7 \
  "$R1" "$R2" "$R3" "$R4" > bin/host1.log 2>&1
H=$?
set -e
kill $SIM 2>/dev/null || true
wait $SIM 2>/dev/null || true
check "badge challenges sim, 4 robots sent, same result" 0 $H
grep -q "VERDICT: SAME" bin/sim1.log || { echo "FAIL sim did not agree"; cat bin/sim1.log; fail=1; }

# 2. the simulator challenges the badge code (which has no robots yet)
bin/host_badge --port 4633 --bcast 127.0.0.1:4634 --secs 25 > bin/host2.log 2>&1 &
HOST=$!
set +e
python3 "$NET/sim_badge.py" 20 --port 4634 --bcast 127.0.0.1:4633 --name SimBeagle --engine bin/rb \
  --challenge HostBadge "$R2" "$R1" --seed 99 > bin/sim2.log 2>&1
S=$?
wait $HOST
H=$?
set -e
check "sim challenges badge, same result (sim)" 0 $S
check "sim challenges badge, same result (badge)" 0 $H

# 3. a peer whose engine disagrees is caught
printf '#!/bin/sh\n"%s/bin/rb" "$@" | sed "s/hash [0-9]*/hash 1/"\n' "$HERE" > bin/rb_wrong
chmod +x bin/rb_wrong
python3 "$NET/sim_badge.py" 25 --port 4636 --bcast 127.0.0.1:4635 --name Liar --engine bin/rb_wrong \
  > bin/sim3.log 2>&1 &
SIM=$!
set +e
bin/host_badge --port 4635 --bcast 127.0.0.1:4636 --secs 20 --challenge Liar --seed 3 "$R3" "$R4" \
  > bin/host3.log 2>&1
H=$?
set -e
kill $SIM 2>/dev/null || true
wait $SIM 2>/dev/null || true
check "different result is detected" 3 $H

# 4. 30 % of the badge code's packets lost: retries still get there
python3 "$NET/sim_badge.py" 40 --port 4638 --bcast 127.0.0.1:4637 --name SimBeagle --engine bin/rb \
  > bin/sim4.log 2>&1 &
SIM=$!
set +e
bin/host_badge --port 4637 --bcast 127.0.0.1:4638 --secs 35 --loss 30 --challenge SimBeagle --seed 5 \
  "$R1" "$R3" "$R2" > bin/host4.log 2>&1
H=$?
set -e
kill $SIM 2>/dev/null || true
wait $SIM 2>/dev/null || true
check "30 % packet loss, same result" 0 $H

# 5. ports as on the real network: the badge code binds its link port and
#    broadcasts its announces to it (as a badge on 4626); the simulator binds
#    its own port (as 4627) and shares the link port with listen-only
#    SO_REUSEADDR. The badge code also holds its result back 10 s (a badge
#    redrawing its e-paper). Both directions. On one PC the badge code binds
#    the PC's network address (--ip) so its port's unicast is its own, as on
#    a separate badge.
IP=$(hostname -i 2>/dev/null | cut -d' ' -f1)
case "$IP" in 127.*|"") IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p') ;; esac
bin/host_badge --port 4651 --ip "$IP" --secs 45 --slow 10 > bin/host5a.log 2>&1 &
HOST=$!
set +e
python3 "$NET/sim_badge.py" 40 --port 4652 --link-port 4651 --name SimBeagle --engine bin/rb \
  --challenge HostBadge "$R1" "$R2" --seed 42 > bin/sim5a.log 2>&1
S=$?
wait $HOST
H=$?
set -e
check "badge ports, slow badge, sim challenges (sim)" 0 $S
check "badge ports, slow badge, sim challenges (badge)" 0 $H
python3 "$NET/sim_badge.py" 45 --port 4654 --link-port 4653 --name SimBeagle --engine bin/rb \
  > bin/sim5b.log 2>&1 &
SIM=$!
set +e
bin/host_badge --port 4653 --ip "$IP" --secs 40 --slow 10 --challenge SimBeagle --seed 8 "$R3" "$R1" "$R4" \
  > bin/host5b.log 2>&1
H=$?
set -e
kill $SIM 2>/dev/null || true
wait $SIM 2>/dev/null || true
check "badge ports, slow badge, badge challenges" 0 $H
grep -q "VERDICT: SAME" bin/sim5b.log || { echo "FAIL sim did not agree (5b)"; fail=1; }

[ $fail = 0 ] && echo "robonet: all passed" || { tail -n 20 bin/*.log; exit 1; }
