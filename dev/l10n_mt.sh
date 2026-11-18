#!/bin/sh
# dev/l10n_mt.sh -- machine-translate the catalog into new languages
#
#   dev/l10n_mt.sh [--accept] <lang>...      e.g. dev/l10n_mt.sh es zh ru
#
# Runs LibreTranslate (open source, self-hosted; nothing leaves this
# machine but the first download of its models) in Docker, starts a
# locales/<lang>.po in every script that has messages, and fills each
# empty entry with dev/l10n_mt.lua: fuzzy, so unused until reviewed,
# unless --accept. A container already running on the port is used and
# left running; one started here is removed at the end.
#
# LIBRETRANSLATE_IMAGE picks the image (default the official latest);
# LIBRETRANSLATE_PORT the local port (5055).
set -eu
cd "$(dirname "$0")/.."

accept=
if [ "${1:-}" = --accept ]; then accept=--accept; shift; fi
[ $# -gt 0 ] || { echo "usage: dev/l10n_mt.sh [--accept] <lang>..." >&2; exit 2; }

image=${LIBRETRANSLATE_IMAGE:-libretranslate/libretranslate:latest}
port=${LIBRETRANSLATE_PORT:-5055}
url=http://127.0.0.1:$port
name=lsd-l10n-mt

# the engine's codes: our zh is Simplified Chinese
codes=en
for l in "$@"; do
	case "$l" in zh) codes="$codes,zh" ;; *) codes="$codes,$l" ;; esac
done

started=
if ! curl -sf "$url/languages" >/dev/null 2>&1; then
	echo "starting LibreTranslate ($codes) on $url ..."
	docker rm -f "$name" >/dev/null 2>&1 || true
	docker run -d --name "$name" -p "127.0.0.1:$port:5000" "$image" \
		--load-only "$codes" >/dev/null
	started=1
	trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
	# the first run downloads the language models
	i=0
	until curl -sf "$url/languages" >/dev/null 2>&1; do
		i=$((i + 1))
		[ $i -lt 600 ] || { echo "LibreTranslate did not come up" >&2; exit 1; }
		sleep 2
	done
fi

for l in "$@"; do
	luajit dev/l10n.lua --new "$l" >/dev/null
	luajit dev/l10n_mt.lua "$l" --url "$url" $accept
done
luajit dev/l10n.lua >/dev/null

[ -z "$started" ] || echo "stopping LibreTranslate"
