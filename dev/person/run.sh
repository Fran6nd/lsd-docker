#!/bin/sh
# dev/person/run.sh -- a scripted person playing on a running server
#
#   dev/person/run.sh <server-container> [person options...]
#
# e.g.
#   dev/person/run.sh lsd-pc --name Tester --team 1 \
#       --at 250 255 1 --look 262 255 1 \
#       --say "/pingmark 262.00 255.00 1.00 Build stairs here" --stay 40
#
# Runs dev/person/person.c (see its header for the options and what it
# prints) in a container sharing <server-container>'s network, so it
# connects to the server at 127.0.0.1:32887 the way a player's client
# would. Exits with the person's own status.
#
# The binary is built in a throwaway alpine:3.22 and kept in the docker
# volume PERSON_VOLUME (lsd-person) with the libenet it was linked
# against, so later runs start at once; it is rebuilt whenever person.c
# changes. `docker volume rm lsd-person` forgets it.
set -eu

[ $# -ge 1 ] || { sed -n '3,9p' "$0" >&2; exit 2; }
SERVER=$1
shift

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/person.c
VOLUME=${PERSON_VOLUME:-lsd-person}
BASE=alpine:3.22

docker inspect -f '{{.State.Running}}' "$SERVER" 2>/dev/null | grep -qx true ||
	{ echo "run.sh: container $SERVER is not running" >&2; exit 1; }

SUM=$(cksum <"$SRC" | cut -d' ' -f1)
HAVE=$(docker run --rm -v "$VOLUME":/out "$BASE" cat /out/person.sum 2>/dev/null || true)

if [ "$SUM" != "$HAVE" ]; then
	echo "run.sh: building the person" >&2
	# the source goes in on stdin: nothing of the host is mounted
	docker run --rm -i -v "$VOLUME":/out "$BASE" sh -euc '
		apk add -q build-base enet-dev zlib-dev >/dev/null
		cat >/tmp/person.c
		cc -std=c99 -O2 -Wall -Wextra -o /out/person /tmp/person.c \
			-lenet -lz -lm -Wl,-rpath,/out
		cp -L /usr/lib/libenet.so.7 /usr/lib/libz.so.1 /out/
		echo "$1" >/out/person.sum' sh "$SUM" <"$SRC"
fi

exec docker run --rm -i --network "container:$SERVER" -v "$VOLUME":/out:ro \
	"$BASE" /out/person "$@"
