#!/bin/sh
# dev/demo-new.sh -- a demo server of the working tree, to play on
#
# Builds the image from what is checked out (lsd-docker:demo), sets up a
# fresh server on a volume of its own -- parkour with the bot engine's
# bots (LSD_DEMO_BOTS of them, 20) on its generated course, or another
# game (LSD_DEMO_GAME=tdm: that many bots a team, a random map from the
# web, random mode so /va fetches another) -- rewards earned as on any
# server, seats for the bots and for people, never listed publicly --
# and starts it, restarted if it falls over. Then says where to join.
#
#   dev/demo-new.sh          dev/demo-refresh.sh after a change
#                            dev/demo-clean.sh when done
#
# LSD_DEMO_NAME (lsd-demo) names the container and its volume,
# LSD_DEMO_PORT (32887) is the UDP port, LSD_DEMO_GAME (parkour) the
# gamemode, LSD_DEMO_BOTS (20) the bots (a team, where there are two).
set -eu
cd "$(dirname "$0")/.."

NAME=${LSD_DEMO_NAME:-lsd-demo}
PORT=${LSD_DEMO_PORT:-32887}
BOTS=${LSD_DEMO_BOTS:-20}
GAME=${LSD_DEMO_GAME:-parkour}
IMAGE=lsd-docker:demo

if docker container inspect "$NAME" >/dev/null 2>&1 || docker volume inspect "$NAME" >/dev/null 2>&1; then
	echo "a demo called $NAME is already here: dev/demo-refresh.sh, or dev/demo-clean.sh first" >&2
	exit 1
fi

echo "building $IMAGE from the working tree..."
docker build -q -t "$IMAGE" . >/dev/null

echo "setting it up..."
docker run --rm -v "$NAME:/data" "$IMAGE" setup --defaults >/dev/null
docker run --rm -v "$NAME:/data" -e BOTS="$BOTS" -e GAME="$GAME" --entrypoint sh "$IMAGE" -c '
	set -e
	# a game that plays a generated map (parkour) gets it here, and its rotation
	lsdctl gamemode "$GAME" --yes --no-restart >/dev/null
	lsdctl set masterlist_enabled false >/dev/null
	# on the one team, where the game has one
	lsdctl bots "$BOTS" --no-restart >/dev/null
	# seats for both teams of bots and for people: above 32, a client
	# needs the Player Limit extension (ZeroSpades has it)
	lsdctl set player_limit_max $((BOTS * 2 + 24)) >/dev/null
	if out=$(lsdctl map web-random "$GAME"); then
		echo "$out"
		map=$(echo "$out" | sed -n "s/^added \([^ ]*\)\.vxl.*/\1/p" | head -1)
		if [ -n "$map" ]; then
			lsdctl set map_rotation "$map" >/dev/null
			lsdctl set map_web_random true >/dev/null
		fi
	else
		echo "no map from the web: the generated one, until /va"
	fi'

docker run -d --name "$NAME" --restart unless-stopped \
	-p "$PORT:32887/udp" -v "$NAME:/data" "$IMAGE" >/dev/null

# wait for it to answer
i=0
until docker exec "$NAME" lsdctl status 2>/dev/null | grep -q 'server: *running'; do
	i=$((i + 1)); [ $i -lt 60 ] || { docker logs "$NAME" | tail -20 >&2; echo "the demo did not come up" >&2; exit 1; }
	sleep 1
done

lan=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | cut -d' ' -f1 || true)
echo "demo up: $NAME, $GAME with $BOTS bots, unlisted"
echo "  this machine:  127.0.0.1:$PORT"
[ -z "$lan" ] || echo "  your network:  $lan:$PORT"
