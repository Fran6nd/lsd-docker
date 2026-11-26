#!/bin/sh
# entrypoint.sh -- serve, or run an lsdctl command
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
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
	mkdir -p "$DATA/maps" "$DATA/rw" "$DATA/scripts" "$DATA/catalog" "$DATA/trees" "$DATA/structures"
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

# /va's new map from the web. The server may not run programs (its
# sandbox forbids fork and exec), so it asks with a file: rw/map_request,
# holding the gamemode. This fetches a random map for that game with
# lsdctl and answers in rw/map_result -- what lsdctl said, "added
# <name>.vxl ..." -- which the server (vote_map) reads and loads. Polled
# once a second; a game without vote_map never writes the request.
map_helper() {
	# the script is the inner shell's: its $1 is not ours to expand
	# shellcheck disable=SC2016
	su-exec lsd sh -c '
		req="$1/rw/map_request"; res="$1/rw/map_result"
		while :; do
			if [ -f "$req" ]; then
				mode=$(head -c 64 "$req"); rm -f "$req"
				case "$mode" in *[!A-Za-z0-9_]*|"") mode= ;; esac
				lsdctl map web-random $mode > "$res.part" 2>&1 || true
				mv -f "$res.part" "$res"
			fi
			sleep 1
		done' map_helper "$DATA" &
}

# The bot engine's host. The server cannot start a process either, so
# botd (bot/botd) runs beside it, as lsd, and waits for the link file the
# server makes when its settings ask for bots (a server without bots
# never makes it: botd then sleeps and costs nothing). botd exits when
# the server closes the link or goes silent, and is started again here
# with a small back-off; the file and the map dumps the server wrote for
# it are removed whenever the server is down, so nothing stale is left
# for the next start. An image built without an engine has no botd, and
# this does nothing.
bot_helper_pid=
bot_link() {
	su-exec lsd lsdctl get botlink_file 2>/dev/null || echo /dev/shm/lsd-botlink
}

# the threads botd's sight and route planner run on (botd --threads; 1 unless the
# setting says otherwise; 0: botd's choice, half the cores at most 4)
bot_threads() {
	t=$(su-exec lsd lsdctl get botlink_threads 2>/dev/null) || t=1
	case "$t" in ''|*[!0-9]*) t=1 ;; esac
	echo "$t"
}

bot_clean() {
	command -v botd >/dev/null 2>&1 || return 0
	rm -f "$(bot_link)" "$DATA"/rw/botlink-map-*.vxl "$DATA"/rw/botlink-map-*.vxl.new
}

bot_helper() {
	command -v botd >/dev/null 2>&1 || return 0
	(
		pid=
		stopping=
		trap 'stopping=1; [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null' TERM INT
		fails=0
		while [ -z "$stopping" ]; do
			started=$(date +%s)
			su-exec lsd botd --threads "$(bot_threads)" --file "$(bot_link)" &
			pid=$!
			while kill -0 "$pid" 2>/dev/null; do
				wait "$pid" || true
			done
			pid=
			[ -z "$stopping" ] || break
			# one that stays up a while, or stops cleanly, restarts at
			# once; one that keeps failing is let alone for longer
			if [ $(( $(date +%s) - started )) -lt 5 ]; then
				fails=$((fails + 1))
			else
				fails=0
			fi
			delay=$(( fails > 5 ? 5 : fails ))
			[ "$delay" -eq 0 ] || { sleep "$delay" & wait $! || true; }
		done
	) &
	bot_helper_pid=$!
}

# botd is asked to stop and given a few seconds; then the link is cleaned
bot_helper_stop() {
	if [ -n "$bot_helper_pid" ]; then
		kill -TERM "$bot_helper_pid" 2>/dev/null || true
		i=0
		while kill -0 "$bot_helper_pid" 2>/dev/null && [ "$i" -lt 5 ]; do
			sleep 1
			i=$((i + 1))
		done
		if kill -0 "$bot_helper_pid" 2>/dev/null; then
			kill -KILL "$bot_helper_pid" 2>/dev/null || true
			killall -KILL botd 2>/dev/null || true
		fi
		wait "$bot_helper_pid" 2>/dev/null || true
		bot_helper_pid=
	fi
	bot_clean
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
	map_helper
	bot_helper

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
		bot_clean

		[ -z "$stopping" ] || { bot_helper_stop; exit 0; }

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

# A casual game on a throwaway container (docker run --rm, see play.sh):
# lsdctl play sets it up -- the game, the map, unlisted -- then the
# server runs once, without the restart loop, so when it ends the
# container ends and Docker removes it with its volume. lib_play ends it
# when the last player leaves. The terminal shows who comes and goes;
# the whole log stays in the container, and goes with it.
play() {
	cd "$HOME_DIR"
	prepare_data
	su-exec lsd lsdctl init >/dev/null
	su-exec lsd lsdctl play "$@" || exit $?
	assemble_scripts
	chown -R lsd:lsd scripts

	log=/tmp/server.log
	: > "$log"
	tail -n 0 -f "$log" | grep -E 'joined as|disconnected|lib_play:|vote_map:' &
	watcher=$!
	map_helper
	bot_helper
	su-exec lsd ./server -c config.lua -p "$(su-exec lsd lsdctl get port)" >"$log" 2>&1 &
	child=$!
	trap 'kill -TERM "$child" 2>/dev/null' TERM INT
	rc=0
	while kill -0 "$child" 2>/dev/null; do
		wait "$child" || rc=$?
	done
	bot_helper_stop
	sleep 1
	kill "$watcher" 2>/dev/null || true
	echo "game over"
	exit "$rc"
}

cmd=${1:-serve}
case "$cmd" in
serve)
	serve
	;;
play)
	shift
	play "$@"
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
