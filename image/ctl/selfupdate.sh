#!/bin/sh
# selfupdate.sh -- pull the newest image and recreate the server on it
# Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
#
#   docker run --rm --volumes-from lsd \
#       -v /var/run/docker.sock:/var/run/docker.sock \
#       ghcr.io/fran6nd/lsd-docker update [options]
#
#   --tag T      move to that version instead (2026.11.17.1), or back
#   --no-pull    use the image as it is locally (a local build)
#   --force      recreate even when nothing changed
#   --name N     the server container, if it is not called lsd
#
# Runs in a throwaway container, never in the server's: the server
# container is the thing being replaced, and it is not given the docker
# socket, which is root on the host. --volumes-from lets this read the
# settings, for the port.
#
# Talks to the Docker Engine API with curl, so the image needs no docker
# CLI. The new container is the old one's configuration -- name,
# volumes, restart policy, networks, anything added to `docker run` --
# on the new image, with the port the settings file names. The old one
# is kept, stopped, until the new one is up, and comes back if it is not.
set -eu

SOCK=/var/run/docker.sock
NAME=lsd
FORCE=
PULL=1
TAG=

while [ $# -gt 0 ]; do
	case "$1" in
	--force) FORCE=1; shift ;;
	--no-pull) PULL=; shift ;;
	--tag) TAG=$2; shift 2 ;;
	--name) NAME=$2; shift 2 ;;
	*) echo "update: unknown option $1" >&2; exit 2 ;;
	esac
done

die() { echo "update: $*" >&2; exit 1; }

[ -S "$SOCK" ] || die "no docker socket. Run this from the host:
  docker run --rm --volumes-from $NAME -v /var/run/docker.sock:/var/run/docker.sock ghcr.io/fran6nd/lsd-docker update"

api() {
	method=$1 path=$2
	shift 2
	curl -fsS --unix-socket "$SOCK" -X "$method" "http://docker/v1.41$path" "$@"
}

json_post() {
	api POST "$1" -H 'Content-Type: application/json' -d "$2"
}

info=$(api GET "/containers/$NAME/json") || die "no container named $NAME"
image=$(printf '%s' "$info" | jq -r .Config.Image)
old_image_id=$(printf '%s' "$info" | jq -r .Image)

# Pull. The tag is the one the container was created from, latest
# when it named none.
repo=${image%@*}
tag=latest
case "${repo##*/}" in
*:*) tag=${repo##*:}; repo=${repo%:*} ;;
esac
[ -z "$TAG" ] || tag=$TAG
if [ -n "$PULL" ]; then
	echo "pulling $repo:$tag"
	out=$(api POST "/images/create?fromImage=$repo&tag=$tag") || die "pull failed"
	err=$(printf '%s\n' "$out" | jq -r 'select(.error != null) | .error' | tail -1)
	[ -z "$err" ] || die "pull failed: $err"
fi
new_image_id=$(api GET "/images/$repo:$tag/json" | jq -r .Id) \
	|| die "no image $repo:$tag"

# The port the settings ask for; the container publishes what it was
# created with.
port=$(lsdctl get port 2>/dev/null || echo 32887)
old_port=$(printf '%s' "$info" | jq -r '.HostConfig.PortBindings // {} | keys[0] // "" | split("/")[0]')

if [ "$new_image_id" = "$old_image_id" ] && [ "$port" = "$old_port" ] && [ -z "$FORCE" ]; then
	echo "already up to date ($(printf '%s' "$info" | jq -r '.Config.Labels["org.opencontainers.image.version"] // "unknown"'))"
	exit 0
fi

old_image=$(api GET "/images/$old_image_id/json")

# The old container's config on the new image: minus what the OLD image
# put there (its env, labels, entrypoint), so the new image's own
# defaults apply; plus every volume, named or anonymous, so nothing on
# them is lost; with the port moved to the one the settings name.
body=$(jq -n \
	--argjson c "$info" --argjson oi "$old_image" \
	--arg image "$repo:$tag" --arg port "$port" --arg old_port "$old_port" '
	($oi.Config.Env // []) as $ienv |
	($oi.Config.Labels // {}) as $ilab |
	($c.HostConfig.Binds // []) as $binds |
	[ $c.Mounts[] | select(.Type == "volume")
	  | select(.Destination as $d | [$binds[] | split(":")[1]] | index($d) | not)
	  | "\(.Name):\(.Destination)" ] as $anon |
	$c.Config
	| del(.Hostname, .Image)
	| .Image = $image
	| .Env = [ (.Env // [])[] | select(. as $e | $ienv | index($e) | not) ]
	| .Labels = ((.Labels // {}) | with_entries(select($ilab[.key] != .value)))
	| (if .Entrypoint == $oi.Config.Entrypoint then del(.Entrypoint) else . end)
	| (if .Cmd == $oi.Config.Cmd then del(.Cmd) else . end)
	| .HostConfig = ($c.HostConfig | .Binds = ($binds + $anon))
	| (if $old_port != "" and $old_port != $port then
		.ExposedPorts = ((.ExposedPorts // {}) | del(.["\($old_port)/udp"]) | .["\($port)/udp"] = {})
		| .HostConfig.PortBindings = (.HostConfig.PortBindings
			| with_entries(if .key == "\($old_port)/udp"
				then {key: "\($port)/udp", value: [.value[] | .HostPort = $port]}
				else . end))
	  else . end)
	| .NetworkingConfig = {EndpointsConfig: ($c.NetworkSettings.Networks
		| map_values({Aliases: .Aliases, IPAMConfig: .IPAMConfig}))}
')

api DELETE "/containers/$NAME-next?force=1" >/dev/null 2>&1 || true
json_post "/containers/create?name=$NAME-next" "$body" >/dev/null \
	|| die "could not create the new container; $NAME is untouched"

echo "stopping $NAME"
api POST "/containers/$NAME/stop?t=15" >/dev/null 2>&1 || true
api DELETE "/containers/$NAME-old?force=1" >/dev/null 2>&1 || true
api POST "/containers/$NAME/rename?name=$NAME-old" >/dev/null
api POST "/containers/$NAME-next/rename?name=$NAME" >/dev/null

rollback() {
	echo "the new container did not stay up; putting the old one back" >&2
	api DELETE "/containers/$NAME?force=1" >/dev/null 2>&1 || true
	api POST "/containers/$NAME-old/rename?name=$NAME" >/dev/null
	api POST "/containers/$NAME/start" >/dev/null
	exit 1
}

api POST "/containers/$NAME/start" >/dev/null || rollback
sleep 5
[ "$(api GET "/containers/$NAME/json" | jq -r .State.Running)" = true ] || rollback

api DELETE "/containers/$NAME-old" >/dev/null
api POST "/images/prune?filters=%7B%22dangling%22%3A%5B%22true%22%5D%7D" >/dev/null 2>&1 || true

version=$(api GET "/images/$new_image_id/json" | jq -r '.Config.Labels["org.opencontainers.image.version"] // "unknown"')
echo "updated: $NAME runs lsd-docker $version on port $port/udp"
