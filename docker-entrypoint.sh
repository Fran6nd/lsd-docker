#!/bin/sh
# Assemble the runtime scripts/ dir from three layers, later wins on a
# same-name file: upstream defaults (baked into the image as scripts.dist),
# the operator's released scripts.local/ mount, then the in-development
# scripts.dev/ mount (skipped when LSD_SCRIPTS_DEV=0). The server resolves
# `load "x"` against ./scripts only, so layering has to happen by copy.
#
# lsdctl's scripts_sync() repeats this recipe on a running container for
# hot loads -- keep the two in step.
#
# Port and config file come from the environment (see Dockerfile/compose);
# any extra arguments are passed straight to the server binary.
set -eu

find scripts -mindepth 1 -delete
cp -R scripts.dist/. scripts/
if [ -d scripts.local ]; then
	cp -R scripts.local/. scripts/
fi
case "${LSD_SCRIPTS_DEV:-1}" in
0|false|no|off) ;;
*) [ ! -d scripts.dev ] || cp -R scripts.dev/. scripts/ ;;
esac

exec ./server -c "${LSD_CONFIG}" -p "${LSD_PORT}" "$@"
