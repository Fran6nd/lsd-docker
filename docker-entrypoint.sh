#!/bin/sh
# Assemble the runtime scripts/ dir: upstream defaults (baked into the
# image) overlaid with the operator's scripts.local/ mount, same-name
# file wins. The server resolves `load "x"` against ./scripts only.
#
# Port and config file come from the environment (see Dockerfile/compose);
# any extra arguments are passed straight to the server binary.
set -eu

find scripts -mindepth 1 -delete
cp -R scripts.dist/. scripts/
if [ -d scripts.local ]; then
	cp -R scripts.local/. scripts/
fi

exec ./server -c "${LSD_CONFIG}" -p "${LSD_PORT}" "$@"
