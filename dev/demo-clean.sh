#!/bin/sh
# dev/demo-clean.sh -- the demo server gone: container, volume, image
#
# LSD_DEMO_NAME (lsd-demo) as dev/demo-new.sh.
set -eu

NAME=${LSD_DEMO_NAME:-lsd-demo}
IMAGE=lsd-docker:demo

docker rm -f "$NAME" >/dev/null 2>&1 && echo "removed the container $NAME" || true
docker volume rm "$NAME" >/dev/null 2>&1 && echo "removed the volume $NAME" || true
# the image only if no other container still uses it
if [ -z "$(docker ps -aq --filter "ancestor=$IMAGE")" ]; then
	docker image rm "$IMAGE" >/dev/null 2>&1 && echo "removed the image $IMAGE" || true
fi
