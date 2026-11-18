#!/bin/sh
# install.sh -- set up an LSD server with one command
#
#   curl -fsSL https://raw.githubusercontent.com/Fran6nd/lsd-docker/master/install.sh | sh
#
# Pulls the image, runs the setup wizard into a fresh data volume,
# starts the server, and installs `lsd`, a short alias for the docker
# commands. Everything it does is three docker commands, printed as it
# goes, so nothing here is needed again -- run them by hand instead if
# you prefer.
#
# Environment: LSD_IMAGE, LSD_NAME (container), LSD_VOLUME.
set -eu

IMAGE=${LSD_IMAGE:-ghcr.io/fran6nd/lsd-docker:latest}
NAME=${LSD_NAME:-lsd}
VOLUME=${LSD_VOLUME:-lsd-data}

say() { printf '%s\n' "$*"; }
run() { say "+ $*"; "$@"; }

command -v docker >/dev/null 2>&1 || {
	say "docker is not installed: https://docs.docker.com/engine/install/"
	exit 1
}

if docker container inspect "$NAME" >/dev/null 2>&1; then
	say "a container named $NAME already exists."
	say "  set it up again:  docker exec -it $NAME lsdctl setup"
	say "  update it:        docker run --rm --volumes-from $NAME -v /var/run/docker.sock:/var/run/docker.sock $IMAGE update"
	exit 1
fi

# This host's LAN addresses, for the connect addresses lsdctl prints: a
# container cannot see them itself. Docker's own bridges and VPN
# interfaces are left out.
host_addresses() {
	# Under WSL the Linux side sees only the WSL VM's own network; the
	# LAN address belongs to Windows, so ask Windows.
	if grep -qi microsoft /proc/version 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; then
		powershell.exe -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { \$_.IPAddress -ne '127.0.0.1' -and \$_.IPAddress -notlike '169.254.*' -and \$_.InterfaceAlias -notmatch 'vEthernet|WSL|Docker|Hyper-V|Loopback|VirtualBox|VMware|Tailscale|WireGuard' }).IPAddress" \
			| tr -d '\r'
	elif command -v ip >/dev/null 2>&1; then
		ip -4 -o addr show scope global \
			| awk '$2 !~ /^(docker|br-|veth|virbr|cni|flannel|tailscale|wg|tun)/ {split($4, a, "/"); print a[1]}'
	elif command -v ifconfig >/dev/null 2>&1; then
		ifconfig | awk '/^[a-z]/ {iface = $1} /inet / && $2 != "127.0.0.1" && iface ~ /^(en|eth|wl)/ {print $2}'
	fi | tr '\n' ' ' | sed 's/ *$//'
}
ADDRESSES=$(host_addresses)

run docker pull "$IMAGE"
run docker volume create "$VOLUME" >/dev/null

# The wizard needs a terminal; under `curl | sh` stdin is the script.
if [ -r /dev/tty ]; then
	run docker run --rm -it -e LSD_HOST_ADDRESSES="$ADDRESSES" -v "$VOLUME:/data" "$IMAGE" setup </dev/tty
else
	say "no terminal: writing the default settings (change them later with lsdctl setup)"
	run docker run --rm -v "$VOLUME:/data" "$IMAGE" setup --defaults
fi

port=$(docker run --rm -v "$VOLUME:/data" "$IMAGE" get port)
run docker run -d --name "$NAME" --restart unless-stopped \
	-p "$port:$port/udp" -e LSD_HOST_ADDRESSES="$ADDRESSES" \
	-v "$VOLUME:/data" "$IMAGE" >/dev/null

# The alias, where there is somewhere on PATH to put it. Its $1 and $@
# are its own, hence the single quotes.
# shellcheck disable=SC2016
wrapper='#!/bin/sh
# lsd -- shorthand for the lsd-docker docker commands
case "${1:-}" in
update) shift; exec docker run --rm --volumes-from '"$NAME"' -v /var/run/docker.sock:/var/run/docker.sock '"$IMAGE"' update "$@" ;;
logs) shift; exec docker logs "$@" '"$NAME"' ;;
*) if [ -t 0 ]; then exec docker exec -it '"$NAME"' lsdctl "$@"; else exec docker exec -i '"$NAME"' lsdctl "$@"; fi ;;
esac'
for dir in /usr/local/bin "$HOME/.local/bin"; do
	if [ -d "$dir" ] && [ -w "$dir" ]; then
		printf '%s\n' "$wrapper" > "$dir/lsd" && chmod +x "$dir/lsd"
		say "installed $dir/lsd (lsd status, lsd install flashlight, lsd update, lsd logs -f)"
		break
	fi
done

say ""
say "The server is starting on port $port/udp."
docker exec "$NAME" lsdctl address
say "  status:      docker exec $NAME lsdctl status"
say "  scripts:     docker exec $NAME lsdctl available"
say "  everything:  docker exec $NAME lsdctl help"
say "  logs:        docker logs -f $NAME"
