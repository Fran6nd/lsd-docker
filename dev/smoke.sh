#!/bin/sh
# dev/smoke.sh -- build the image, boot a server, administer it
#
# What a user does on day one, end to end: start with an empty volume,
# wait for the server, install a script with a preset, restart, and
# check the server actually loaded it.
set -eu
cd "$(dirname "$0")/.."

IMAGE=${IMAGE:-lsd-docker:smoke}
NAME=lsd-smoke-$$
VOL=lsd-smoke-$$

if [ -z "${SKIP_BUILD:-}" ]; then
	# for this machine's own arch, so nothing runs under emulation
	docker build \
		--build-arg VERSION="$(cat VERSION)" \
		--build-arg LSD_COMMIT="$(git -C lsd rev-parse --short=10 HEAD 2>/dev/null || echo unknown)" \
		-t "$IMAGE" .
fi

cleanup() {
	docker logs "$NAME" >smoke.log 2>&1 || true
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "SMOKE FAIL: $*" >&2; docker logs "$NAME" 2>&1 | tail -60 >&2; exit 1; }

wait_up() {
	i=0
	until docker exec "$NAME" lsdctl status 2>/dev/null | grep -q 'server: *running'; do
		i=$((i + 1)); [ $i -lt 90 ] || fail "server did not come up ($1)"
		sleep 2
	done
}

# Settings first, unlisted: a test server must never show up on the
# public server lists.
docker run --rm -v "$VOL:/data" "$IMAGE" setup --defaults >/dev/null \
	|| fail "setup --defaults"
docker run --rm -v "$VOL:/data" "$IMAGE" set masterlist_enabled False >/dev/null \
	|| fail "set before start"
docker run -d --name "$NAME" -v "$VOL:/data" "$IMAGE" >/dev/null
wait_up "first boot"
echo "ok: first boot on default settings"

docker exec "$NAME" lsdctl status
docker exec "$NAME" lsdctl available >/dev/null
docker exec "$NAME" lsdctl install flashlight --preset disco --policy required --yes --now \
	|| fail "install"
sleep 3
wait_up "after install"
docker logs "$NAME" 2>&1 | grep -q 'lib_flashlight' || fail "lib_flashlight not loaded"
docker exec "$NAME" lsdctl get flashlight_colors | grep -q random || fail "preset not written"
echo "ok: install with a preset, server restarted and loaded it"

docker exec "$NAME" lsdctl gamemode hostage --yes --now || fail "gamemode"
sleep 3
wait_up "after gamemode"
docker logs "$NAME" 2>&1 | grep -q 'gamemode hostage' || fail "hostage not running"
echo "ok: gamemode switch"

docker exec "$NAME" lsdctl set masterlist_name "'smoke test'" || fail "set"
docker exec "$NAME" lsdctl remove flashlight --yes --now || fail "remove"
sleep 3
wait_up "after remove"
echo "ok: set, remove"

if docker logs "$NAME" 2>&1 | grep -E 'failed to load|is installed but not in the catalog|stack traceback'; then
	fail "errors in the server log"
fi
if docker logs "$NAME" 2>&1 | grep -q 'Connected to masterlist'; then
	fail "the test server announced itself to a public server list"
fi
echo "SMOKE OK"
