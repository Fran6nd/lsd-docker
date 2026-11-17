#!/bin/sh
# lsdctl -- the command; the work is in lsdctl.lua
#
# `docker exec` runs as root, and everything lsdctl writes belongs to
# the lsd user that runs the server, so it drops to that user first.
# `update` stays root: it needs the docker socket.
case "${1:-}" in
update|selfupdate)
	shift
	exec /usr/local/lib/lsdctl/selfupdate.sh "$@"
	;;
esac

if [ "$(id -u)" = 0 ] && id lsd >/dev/null 2>&1; then
	exec su-exec lsd luajit /usr/local/lib/lsdctl/lsdctl.lua "$@"
fi
exec luajit /usr/local/lib/lsdctl/lsdctl.lua "$@"
