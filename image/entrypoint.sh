#!/bin/sh
# entrypoint.sh -- serve, or run an lsdctl command
# Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
#
#   docker run ... IMAGE                 serve (the default)
#   docker run ... IMAGE <command>       lsdctl <command>, e.g. setup
#
# Serving keeps the container up across server restarts: the server is
# a child of this script, and when it exits -- `lsdctl restart`, or an
# install that changes the load order -- the scripts are reassembled
# and it is started again. Only `docker stop` ends the loop.
set -eu

HOME_DIR=/lsd
DATA=${LSD_DATA:-/data}

# The data volume is the lsd user's, whoever created it.
prepare_data() {
	mkdir -p "$DATA/maps" "$DATA/rw" "$DATA/scripts" "$DATA/catalog"
	if [ "$(id -u)" = 0 ]; then
		chown -R lsd:lsd "$DATA"
	fi
}

# The server resolves `load "x"` against ./scripts only, so every layer
# is copied there, later winning: upstream, every catalog entry's
# modules (a script loads only when installed, so shipping all of them
# costs nothing), the catalog core, patched upstream modules, and last
# the operator's own scripts from the volume.
assemble_scripts() {
	find scripts -mindepth 1 -delete
	cp -R scripts.dist/. scripts/
	for root in catalog "$DATA/catalog"; do
		for entry in "$root"/*/*/; do
			[ -f "${entry}script.lua" ] || continue
			for f in "$entry"*; do
				[ "${f##*/}" = script.lua ] || cp -R "$f" scripts/
			done
		done
	done
	cp catalog/core/*.lua scripts/
	cp catalog/overrides/*.lua scripts/ 2>/dev/null || true
	cp -R "$DATA/scripts/." scripts/
}

serve() {
	cd "$HOME_DIR"
	prepare_data
	su-exec lsd lsdctl init

	child=
	stopping=
	trap 'stopping=1; [ -z "$child" ] || kill -TERM "$child" 2>/dev/null' TERM INT

	fails=0
	while :; do
		assemble_scripts
		chown -R lsd:lsd scripts
		port=$(su-exec lsd lsdctl get port 2>/dev/null || echo 32887)
		echo "lsd-docker $(cat VERSION): starting the server on $port/udp"

		started=$(date +%s)
		su-exec lsd ./server -c config.lua -p "$port" &
		child=$!
		rc=0
		# wait returns early when a signal arrives; keep waiting until
		# the server itself is gone
		while kill -0 "$child" 2>/dev/null; do
			wait "$child" || rc=$?
		done
		child=

		[ -z "$stopping" ] || exit 0

		# a server that dies at once is failing to start: back off so
		# the log stays readable while it is fixed
		if [ $(( $(date +%s) - started )) -lt 10 ]; then
			fails=$((fails + 1))
		else
			fails=0
		fi
		delay=$(( fails > 5 ? 30 : fails * fails ))
		echo "server exited ($rc), starting again in ${delay}s"
		sleep "$delay"
	done
}

cmd=${1:-serve}
case "$cmd" in
serve)
	serve
	;;
update|selfupdate)
	shift
	exec /usr/local/lib/lsdctl/selfupdate.sh "$@"
	;;
*)
	prepare_data
	exec lsdctl "$@"
	;;
esac
