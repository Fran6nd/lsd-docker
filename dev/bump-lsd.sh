#!/bin/sh
# dev/bump-lsd.sh -- move the lsd submodule to upstream master
#
# Commits the bump only when the Lua tests still pass; build and
# smoke-test the image with `dev/test.sh --image` before releasing.
set -eu
cd "$(dirname "$0")/.."

old=$(git -C lsd rev-parse --short HEAD)
git submodule update --init --remote lsd
git -C lsd submodule update --init --recursive
new=$(git -C lsd rev-parse --short HEAD)

if [ "$old" = "$new" ]; then
	echo "lsd already at upstream master ($new)"
	exit 0
fi

echo "lsd: $old -> $new"
git -C lsd log --oneline "$old..$new"
dev/test.sh
git add lsd
git commit -q -m "lsd: update to $new"
echo "committed; next: dev/test.sh --image, then dev/release.sh"
