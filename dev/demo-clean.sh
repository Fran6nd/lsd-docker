#!/bin/sh
# dev/demo-clean.sh -- the demo server gone: container, volume, image
#
# LSD_DEMO_NAME (lsd-demo) as dev/demo-new.sh.
set -eu

NAME=${LSD_DEMO_NAME:-lsd-demo}
IMAGE=lsd-docker:demo

if docker rm -f "$NAME" >/dev/null 2>&1; then echo "removed the container $NAME"; fi
if docker volume rm "$NAME" >/dev/null 2>&1; then echo "removed the volume $NAME"; fi
# the image only if no other container still uses it
if [ -z "$(docker ps -aq --filter "ancestor=$IMAGE")" ]; then
	if docker image rm "$IMAGE" >/dev/null 2>&1; then echo "removed the image $IMAGE"; fi
fi
