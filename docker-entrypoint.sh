#!/bin/sh
# Port and config file come from the environment (see Dockerfile/compose);
# any extra arguments are passed straight to the server binary.
set -eu
exec ./server -c "${LSD_CONFIG}" -p "${LSD_PORT}" "$@"
