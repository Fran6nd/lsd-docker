#!/bin/sh
# dev/test.sh -- the host-side tests, as CI runs them
#
#   dev/test.sh            Lua tests (needs luajit)
#   dev/test.sh --image    also build the image and smoke-test it (docker)
set -eu
cd "$(dirname "$0")/.."

# the bot link's library, for tests/botlink_test.lua (which skips cleanly
# without it): only that one target, a second's work; a failure to build
# it is not a failure of the Lua tests
if [ -f bot/Makefile ] && command -v cc >/dev/null 2>&1; then
	make -s -C bot build/libbotlink.so >/dev/null 2>&1 || echo "== (bot/build/libbotlink.so not built; botlink_test will skip)"
fi

# each test's last line is its summary; a failing test prints its
# failures and fails the run
failed=
for t in tests/*_test.lua; do
	echo "== $t"
	if out=$(luajit "$t" 2>&1); then
		printf '%s\n' "$out" | tail -1
	else
		printf '%s\n' "$out" | grep -E 'FAIL|rror|traceback' || printf '%s\n' "$out" | tail -20
		failed="$failed $t"
	fi
done
if [ -n "$failed" ]; then
	echo "FAILED:$failed" >&2
	exit 1
fi

# every Lua file in the catalog and the image at least compiles
find catalog image -name '*.lua' -exec luajit -bl {} \; >/dev/null
echo "== catalog and image Lua compiles"

[ "${1:-}" = --image ] || exit 0
exec dev/smoke.sh
