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
		# catalog/<category>/<id>/, and effects/<kind>/<id>/
		for entry in "$root"/*/*/ "$root"/effects/*/*/; do
			[ -f "${entry}script.lua" ] || continue
			id=$(basename "$entry")
			for f in "$entry"*; do
				case "${f##*/}" in
				script.lua) ;;
				# translations: locales/<lang>.po is installed as
				# scripts/locales/<lang>/<id>.po, one file per script
				locales)
					for po in "$f"/*.po; do
						[ -f "$po" ] || continue
						lang=$(basename "$po" .po)
						mkdir -p "scripts/locales/$lang"
						cp "$po" "scripts/locales/$lang/$id.po"
					done ;;
				*) cp -R "$f" scripts/ ;;
				esac
			done
		done
	done
	cp catalog/core/*.lua scripts/
	cp catalog/overrides/*.lua scripts/ 2>/dev/null || true
	# translations of upstream LSd's own messages
	for po in catalog/overrides/locales/*.po; do
		[ -f "$po" ] || continue
		lang=$(basename "$po" .po)
		mkdir -p "scripts/locales/$lang"
		cp "$po" "scripts/locales/$lang/lsd.po"
	done
	cp -R "$DATA/scripts/." scripts/
}

serve() {
	cd "$HOME_DIR"
	prepare_data
	su-exec lsd lsdctl init

	child=
	stopping=
	trap 'stopping=1; [ -z "$child" ] || kill -TERM "$child" 2>/dev/null' TERM INT

	# Is a newer lsd-docker image published? Asked a minute after start,
	# then every six hours, unless update_check = False; the answer is a
	# file that lib_update_notice tells admins about as they log in. Only
	# the image is checked: LSd is built into it.
	( sleep 60; while :; do
		su-exec lsd lsdctl update-check --quiet >/dev/null 2>&1 || true
		sleep 21600
	done ) &

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
