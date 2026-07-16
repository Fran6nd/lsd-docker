#!/bin/sh
# Nightly update for the dockerized LSD server: bump the lsd submodule
# to upstream master, rebuild the image, restart the container (compose
# only recreates it when the image actually changed). The submodule
# stays pristine -- config.lua lives in this project and is mounted
# into the container, so there is nothing to stash, ever.
#
# Run from root's crontab:
#   0 3 * * * /path/to/lsd-docker/update.sh >> /var/log/lsd-update.log 2>&1
# (also works run directly as a user in the docker group)
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OWNER=$(stat -c %U "$DIR")

# run git as the repo owner when invoked as root
as_owner() {
	if [ "$(id -u)" -eq 0 ]; then runuser -u "$OWNER" -- "$@"; else "$@"; fi
}

exec 9>"${TMPDIR:-/tmp}/lsd-docker-update.lock"
flock -n 9 || { echo "another update is already running, aborting"; exit 1; }

cd "$DIR"
echo "=== update started $(date -Is) ==="

OLD=$(as_owner git -C lsd rev-parse HEAD)
as_owner git submodule update --remote --init --recursive lsd
NEW=$(as_owner git -C lsd rev-parse HEAD)

if [ "$OLD" != "$NEW" ]; then
	echo "lsd updated: $OLD -> $NEW"
	as_owner git add lsd
	as_owner git commit -q -m "lsd: update to $(as_owner git -C lsd rev-parse --short HEAD)" || true
else
	echo "lsd already up to date"
fi

docker compose build --pull
docker compose up -d
docker image prune -f >/dev/null

echo "=== update finished $(date -Is) ==="
