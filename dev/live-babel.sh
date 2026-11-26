#!/bin/sh
# dev/live-babel.sh -- bots on a real server, measured, with a person's
# build pings: the live end-to-end check of what the bots do
#
#   dev/live-babel.sh <map.vxl>
#
# Starts a server of its own (container and volume lsd-live-<pid>, a free
# UDP port; never the demo), babel on the given map, BOTS engine bots a
# team at LEVEL; loads dev/live/probe.lua into it (counts and reads only)
# and for MINUTES samples, every few seconds, what each bot is doing (its
# tree's running leaf, `lsdctl bots list`) and where it is. A scripted
# PERSON (dev/person: a real client over the network) joins team 1 and,
# one case after another, stands where a case says and pings its spot
# "Build stairs here" through /pingmark, as the pie menu does. Then it
# says what it measured and checks it:
#
#   idle         share of the living bots' samples spent holding (`hold`,
#                `idle`) or not moved a voxel over two samples running
#                (some 15 s) doing anything but fighting  <= IDLE_MAX
#   blocks       voxels each team placed a minute      >= BLOCKS_MIN
#   order        each case's stair: the engine took the order and a body
#                can walk from the ground up to its top step, beside the
#                spot, within STAIR_SECS of the ping (the probe's own
#                search, not the engine's)
#   errors       no Lua error, no script crash in the server's log
#
# Exits 0 when every check passes, 1 otherwise; the samples, the server's
# log and the person's are kept in OUT. The container and volume go
# whatever happens.
#
# Settings (environment):
#   IMAGE        an image to run; unset, the working tree is built
#                (lsd-docker:live)
#   BOTS (20) LEVEL (10) MINUTES (10) INTERVAL (5: seconds between samples)
#   PING_AT (60)     seconds from the bots' arrival to the first case
#   STAIR_SECS (150) a case's time: its ping, then its stair reached
#   CASES        the pings, ';' between cases, each
#                  "<name> <stand x> <stand y> <spot x> <spot y> <spot z>"
#                (the person stands on the ground of column stand x, y and
#                aims at the spot: a point on a face, as a client's ping
#                is); unset, the BABEL_CASES below, for the map
#                tests/fixtures' demobabel (the owner's two pings of
#                2026-11-26 and a stair to a hill elsewhere)
#   IDLE_MAX (0.30) BLOCKS_MIN (20)
#   OUT          where to keep what was measured (a new temporary folder)
#   PORT         the UDP port (unset: 32890 and up, the first free)
set -eu
cd "$(dirname "$0")/.."

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
	sed -n '3,4p' "$0" >&2
	exit 2
fi
MAP=$1

BOTS=${BOTS:-20}
LEVEL=${LEVEL:-10}
MINUTES=${MINUTES:-10}
INTERVAL=${INTERVAL:-5}
PING_AT=${PING_AT:-60}
STAIR_SECS=${STAIR_SECS:-150}
IDLE_MAX=${IDLE_MAX:-0.30}
BLOCKS_MIN=${BLOCKS_MIN:-20}
# On the map of the demo of 2026-11-26 (the owner's babel, as it was
# when he reported it): his first ping, at the platform's underside by its
# west edge, from the ground close under it; his second, its west face,
# from further off; and away from the platform (from the asker to the
# spot, the rule everywhere else) the side of the mound by team 1's stair,
# from off its axis. Each stand sees its spot (a client's ping is refused
# otherwise).
BABEL_CASES="underside 203 236 207.78 242.63 2.00;face 188 241 206.00 250.50 1.50;mound 170 245 182.00 263.50 6.50"
CASES=${CASES:-$BABEL_CASES}
OUT=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/live-babel.XXXXXX")}
NAME=lsd-live-$$
mkdir -p "$OUT"

if [ -z "${IMAGE:-}" ]; then
	IMAGE=lsd-docker:live
	echo "building $IMAGE from the working tree..."
	docker build -q -t "$IMAGE" . >/dev/null
fi

if [ -z "${PORT:-}" ]; then
	PORT=32890
	while docker ps --format '{{.Ports}}' | grep -q ":$PORT->"; do PORT=$((PORT + 1)); done
fi

cleanup() {
	docker logs "$NAME" >"$OUT/server.log" 2>&1 || true
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	docker volume rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail_setup() { echo "live-babel: $*" >&2; exit 1; }
ctl() { docker exec "$NAME" lsdctl "$@"; }
lua() { ctl exec "exec $1"; }        # what it log()s comes back, among the console's own lines
now() { date +%s; }

echo "setting up $NAME (port $PORT): babel, $BOTS bots a team at level $LEVEL, map $(basename "$MAP")"
docker run --rm -v "$NAME:/data" "$IMAGE" setup --defaults >/dev/null || fail_setup "setup"
MAPDIR=$(cd "$(dirname "$MAP")" && pwd)
docker run --rm -v "$NAME:/data" -v "$MAPDIR:/m:ro" -e MAPFILE="$(basename "$MAP")" \
	-e BOTS="$BOTS" -e LEVEL="$LEVEL" --entrypoint sh "$IMAGE" -c '
	set -e
	cp "/m/$MAPFILE" /tmp/live.vxl
	lsdctl gamemode babel --yes --no-restart
	lsdctl set masterlist_enabled false --no-restart
	lsdctl bots "$BOTS" --no-restart
	lsdctl set engine_bots_level "$LEVEL" --no-restart
	lsdctl map add /tmp/live.vxl
	lsdctl set map_rotation live --no-restart' >"$OUT/setup.log" 2>&1 \
	|| fail_setup "configure: $(tail -3 "$OUT/setup.log")"
docker run -d --name "$NAME" -p "$PORT:32887/udp" -v "$NAME:/data" "$IMAGE" >/dev/null

i=0
until docker logs "$NAME" 2>&1 | grep -q "botd: bots: 0 -> $((BOTS * 2))"; do
	i=$((i + 1)); [ $i -lt 120 ] || fail_setup "the bots did not come (botd: bots: 0 -> $((BOTS * 2)))"
	sleep 1
done
# the map played is the one given (the engine's copy of it, byte for byte)
docker logs "$NAME" 2>&1 | grep -q "botd: map loaded: .*, $(wc -c <"$MAP" | tr -d ' ') bytes" \
	|| fail_setup "the server plays another map than $(basename "$MAP")"
docker exec -i "$NAME" sh -c 'cat > /tmp/live_probe.lua' <dev/live/probe.lua
lua 'dofile("/tmp/live_probe.lua")' >/dev/null
lua 'log("PROBE " .. tostring(LIVE_PROBE ~= nil))' | grep -q '^PROBE true' || fail_setup "the probe did not load"
START=$(now)
echo "bots in at $(date '+%H:%M:%S'); measuring for $MINUTES minutes in $OUT"

# --- the person's cases, one after another, in the background ---------------
# Each: the person stands on the ground at the case's column and pings its
# spot; it stays STAIR_SECS. Then the order the engine said it took for him
# ("order of #<his id>: stairs ... top X Y Z") is looked at: can a body
# walk from the ground up to that top step (the probe's own search)?
: >"$OUT/cases.txt"
: >"$OUT/climb.txt"
orders() { docker logs "$NAME" 2>&1 | grep -E 'engine: order of #[0-9]+: stairs' || true; }
run_cases() {
	sleep "$PING_AT"
	echo "$CASES" | tr ';' '\n' | while read -r cname sx sy tx ty tz; do
		[ -n "$cname" ] || continue
		g=$(lua "live_ground($sx, $sy)" </dev/null | awk '/^GROUND/{print $4}')
		lx=$(printf '%.2f' "$tx"); ly=$(printf '%.2f' "$ty"); lz=$(printf '%.2f' "$tz")
		pin="$lx $ly $lz"
		before=$(orders | wc -l)
		echo "CASE $cname at $(($(now) - START)) s: stand $sx $sy $g, spot $pin" >>"$OUT/cases.txt"
		# team 1 is the wire's team 0
		dev/person/run.sh "$NAME" --name "Tester" --team 0 --at "$sx" "$sy" "$g" \
			--look "$lx" "$ly" "$lz" --say "/pingmark $pin Build stairs here" --stay "$STAIR_SECS" \
			</dev/null >"$OUT/person-$cname.log" 2>&1 || true
		me=$(sed -n 's/.*player id \([0-9]*\).*/\1/p' "$OUT/person-$cname.log" | head -1)
		said=$(orders | sed -n "$((before + 1)),\$p" | grep "order of #$me:" | tail -1)
		echo "  engine: ${said:-nothing}" >>"$OUT/cases.txt"
		top=$(echo "$said" | sed -n 's/.* top \([0-9]* [0-9]* [0-9]*\).*/\1/p')
		if [ -z "$top" ]; then
			# what the person was told after it spoke, or why it never did
			why=$(sed -n '/^SAID/,$p' "$OUT/person-$cname.log" | grep -m1 -E '^CHAT  type=2' | grep -v '> /pingmark' || true)
			grep -q '^SAID' "$OUT/person-$cname.log" || why="it never got there: $(grep -m1 '^WARN' "$OUT/person-$cname.log" || echo 'no WARN')"
			echo "ORDER $cname: no stair ordered${why:+ (person: $why)}" >>"$OUT/climb.txt"
			continue
		fi
		read -r top_x top_y top_z <<EOF
$top
EOF
		c=$(lua "live_climb($top_x, $top_y, $top_z, 64)" </dev/null | grep '^CLIMB' || echo "CLIMB no (probe)")
		echo "ORDER $cname: top $top, $c, $(($(now) - START)) s" >>"$OUT/climb.txt"
	done
}
run_cases &
CASES_PID=$!

# --- samples --------------------------------------------------------------------
: >"$OUT/samples.txt"
END=$((START + MINUTES * 60))
while [ "$(now)" -lt "$END" ]; do
	t=$(($(now) - START))
	ctl bots list >"$OUT/list.tmp" 2>/dev/null &
	LIST_PID=$!
	lua 'live_positions()' >"$OUT/pos.tmp" 2>/dev/null || true
	wait "$LIST_PID" 2>/dev/null || true
	# "S <t> <pid> <team> <leaf> <x> <y> <z>"; a bot not alive has no place
	awk -v t="$t" '
		FNR == NR { if ($1 == "POS") for (i = 2; i <= NF; i++) { split($i, p, ":"); pos[p[1]] = p[3] " " p[4] " " p[5] } next }
		$1 ~ /^[0-9]+$/ { print "S", t, $1, $3, $NF, ($1 in pos) ? pos[$1] : "- - -" }
	' "$OUT/pos.tmp" "$OUT/list.tmp" >>"$OUT/samples.txt"
	lua 'live_report()' | grep '^LIVE' >>"$OUT/report.txt" || true
	sleep "$INTERVAL"
done
wait "$CASES_PID" 2>/dev/null || true
docker logs "$NAME" >"$OUT/server.log" 2>&1 || true

lua 'live_report()' | grep '^LIVE' >>"$OUT/report.txt" || true

# --- what was measured ---------------------------------------------------------
echo
echo "== what the bots did ($OUT/samples.txt) =="
awk '
	$1 != "S" || $5 == "dead" || $6 == "-" { next }
	{
		id = $3; n++; leaf[$5]++;
		moved = 1;
		if (id in lx) { dx = $6 - lx[id]; dy = $7 - ly[id]; dz = $8 - lz[id]; moved = dx*dx + dy*dy + dz*dz > 1 }
		still[id] = moved ? 0 : still[id] + 1;
		lx[id] = $6; ly[id] = $7; lz[id] = $8;
		idle = ($5 == "hold" || $5 == "idle") || (still[id] >= 2 && $5 != "fight");
		if (idle) { nidle++; idleleaf[$5]++ }
	}
	END {
		printf "samples of living bots %d, idle %d (%.2f)\n", n, nidle, n ? nidle / n : 0;
		for (l in leaf) printf "  %-16s %5d  %5.1f%%   idle %5d\n", l, leaf[l], 100 * leaf[l] / n, idleleaf[l];
		printf "IDLE %.3f\n", n ? nidle / n : 1;
	}' "$OUT/samples.txt" | tee "$OUT/idle.txt"
first=$(head -1 "$OUT/report.txt"); last=$(tail -1 "$OUT/report.txt")
echo "$first"; echo "$last"
mins=$(echo "$last" | awk '{sub("t=", "", $2); print ($2 > 0 ? $2 / 60 : 1)}')
echo "$last" | awk -v m="$mins" '{printf "BLOCKS a minute: team 1 %.1f, team 2 %.1f; captures %d %d\n", $4 / m, $5 / m, $7, $8}' | tee "$OUT/blocks.txt"
echo
echo "== the person's orders =="
cat "$OUT/cases.txt" "$OUT/climb.txt"
CLIMB_N=$(grep -c '^ORDER' "$OUT/climb.txt" || true)
CLIMB_OK=$(grep -c 'CLIMB yes' "$OUT/climb.txt" || true)
ERRORS=$(grep -cE 'attempt to|stack traceback|crashed on|on_load failed|engine: trouble' "$OUT/server.log" || true)
echo
echo "== errors in the server's log: $ERRORS =="
grep -E 'attempt to|stack traceback|crashed on|on_load failed|engine: trouble' "$OUT/server.log" | sort | uniq -c | sort -rn | head -10

# --- the checks -------------------------------------------------------------------
ok=1
check() { if [ "$1" = 1 ]; then echo "PASS $2"; else echo "FAIL $2"; ok=0; fi; }
idle=$(awk '/^IDLE/{print $2}' "$OUT/idle.txt")
b1=$(awk '{print $6}' "$OUT/blocks.txt" | tr -d ,); b2=$(awk '{print $9}' "$OUT/blocks.txt" | tr -d ';')
echo
check "$(awk -v a="$idle" -v b="$IDLE_MAX" 'BEGIN{print (a <= b) ? 1 : 0}')" "idle share $idle <= $IDLE_MAX"
check "$(awk -v a="$b1" -v c="$b2" -v b="$BLOCKS_MIN" 'BEGIN{print (a >= b && c >= b) ? 1 : 0}')" "blocks a minute $b1 / $b2 >= $BLOCKS_MIN"
check "$([ "$CLIMB_N" -gt 0 ] && [ "$CLIMB_OK" = "$CLIMB_N" ] && echo 1 || echo 0)" "ordered stairs a body climbs from the ground to the top: $CLIMB_OK of $CLIMB_N cases"
check "$([ "$ERRORS" = 0 ] && echo 1 || echo 0)" "no errors in the server's log"
[ "$ok" = 1 ]
