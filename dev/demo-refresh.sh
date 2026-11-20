#!/bin/sh
# dev/demo-refresh.sh -- the demo server on the working tree as it is now
#
# Rebuilds lsd-docker:demo from what is checked out and starts the demo
# again on it. Its volume is kept: the settings, the maps, the scripts
# installed. Players are disconnected; they reconnect to the same
# address.
#
# LSD_DEMO_NAME (lsd-demo) and LSD_DEMO_PORT (32887) as dev/demo-new.sh.
set -eu
cd "$(dirname "$0")/.."

NAME=${LSD_DEMO_NAME:-lsd-demo}
PORT=${LSD_DEMO_PORT:-32887}
IMAGE=lsd-docker:demo

if ! docker volume inspect "$NAME" >/dev/null 2>&1; then
	echo "no demo called $NAME: dev/demo-new.sh" >&2
	exit 1
fi

echo "building $IMAGE from the working tree..."
docker build -q -t "$IMAGE" . >/dev/null

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --restart unless-stopped \
	-p "$PORT:32887/udp" -v "$NAME:/data" "$IMAGE" >/dev/null

i=0
until docker exec "$NAME" lsdctl status 2>/dev/null | grep -q 'server: *running'; do
	i=$((i + 1)); [ $i -lt 60 ] || { docker logs "$NAME" | tail -20 >&2; echo "the demo did not come up" >&2; exit 1; }
	sleep 1
done
docker exec "$NAME" lsdctl status | grep -E 'gamemode|maps'
echo "demo refreshed: $NAME on $PORT/udp"
