#!/bin/sh
# dev/test.sh -- the host-side tests, as CI runs them
#
#   dev/test.sh            Lua tests (needs luajit)
#   dev/test.sh --image    also build the image and smoke-test it (docker)
set -eu
cd "$(dirname "$0")/.."

for t in tests/*_test.lua; do
	echo "== $t"
	luajit "$t" | tail -1
done

# every Lua file in the catalog and the image at least compiles
find catalog image -name '*.lua' -exec luajit -bl {} \; >/dev/null
echo "== catalog and image Lua compiles"

[ "${1:-}" = --image ] || exit 0
exec dev/smoke.sh
