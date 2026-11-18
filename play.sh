#!/bin/sh
# play.sh -- a casual LAN game of Ace of Spades, gone when it is over
# Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
#
#   curl -fsSL https://raw.githubusercontent.com/Fran6nd/lsd-docker/master/play.sh | sh
#   curl -fsSL .../play.sh | sh -s -- babel random
#   curl -fsSL .../play.sh | sh -s -- ctf https://aos.party/view/864
#
# Starts a throwaway server (docker run --rm, no volume kept): it asks
# which game (ctf, babel) and which map (random, or an aos.party link or
# id) unless told, prints the address friends on your network join
# with, and stops by itself a minute after the last player leaves --
# Ctrl-C stops it at once. Then the container is gone, and so is the
# image, if this script is what downloaded it and nothing else uses it.
#
# Environment: LSD_IMAGE, LSD_PORT (the first port to try, 32887).
set -eu

IMAGE=${LSD_IMAGE:-ghcr.io/fran6nd/lsd-docker:latest}

say() { printf '%s\n' "$*"; }

if ! command -v docker >/dev/null 2>&1; then
	say "Docker is needed: https://www.docker.com/products/docker-desktop/ (Windows, macOS),"
	say "https://docs.docker.com/engine/install/ (Linux)."
	exit 1
fi
if ! docker info >/dev/null 2>&1; then
	say "Docker is installed but not running: start Docker Desktop (or the docker service)."
	exit 1
fi

# Was the image here already? Then it is somebody's -- a server of yours,
# say -- and stays (updated, see below). Only an image this game
# downloaded goes with it.
had_image=
docker image inspect "$IMAGE" >/dev/null 2>&1 && had_image=1

cleanup() {
	if [ -z "$had_image" ] && [ -z "$(docker ps -aq --filter "ancestor=$IMAGE")" ]; then
		docker image rm "$IMAGE" >/dev/null 2>&1 && say "removed the game's image ($IMAGE)"
	fi
}
trap cleanup EXIT

# The first free UDP port from 32887: a server already running (yours,
# or another game) keeps its own.
port_taken() {
	docker ps --format '{{.Ports}}' | grep -q ":$1->" && return 0
	if command -v lsof >/dev/null 2>&1; then
		lsof -nP -iUDP:"$1" >/dev/null 2>&1 && return 0
	elif command -v ss >/dev/null 2>&1; then
		ss -uln | grep -q ":$1 " && return 0
	fi
	return 1
}
port=${LSD_PORT:-32887}
while port_taken "$port"; do
	port=$((port + 1))
	[ "$port" -lt 32987 ] || { say "no free UDP port from ${LSD_PORT:-32887}"; exit 1; }
done

# This computer's LAN addresses, which a container cannot see: the ones
# to give friends. As install.sh finds them, WSL included.
host_addresses() {
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

# Always the newest image: one line has to be enough, and an old copy
# left here by an earlier game or a server may predate `play`. Pulling
# only moves the tag -- a server running on the old image keeps it.
# Offline, a copy already here will do.
if [ -z "$had_image" ]; then
	say "downloading the game (removed again when it is over)..."
	docker pull -q "$IMAGE" >/dev/null
else
	say "checking for a newer version of the game..."
	docker pull -q "$IMAGE" >/dev/null 2>&1 || say "offline? playing the copy already here"
fi

# Questions need a terminal; under `curl | sh` stdin is the script.
set -- docker run --rm -p "$port:32887/udp" \
	-e LSD_HOST_ADDRESSES="$(host_addresses)" -e LSD_HOST_PORT="$port" \
	"$IMAGE" play "$@"
if (exec </dev/tty) 2>/dev/null; then
	# -it after `run`, for the questions and for Ctrl-C
	first=$1; shift; second=$1; shift
	"$first" "$second" -it "$@" </dev/tty || true
else
	"$@" || true
fi
