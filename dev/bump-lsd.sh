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
# upstream's messages may have changed: bring the templates and .po
# files in line (a reworded message keeps its translation, as fuzzy)
luajit dev/l10n.lua
fuzzy=$(grep -l '^#, fuzzy' $(find catalog -path '*/locales/*.po') 2>/dev/null || true)
[ -z "$fuzzy" ] || printf 'translations to check (fuzzy):\n%s\n' "$fuzzy"
dev/test.sh
git add lsd $(find catalog -path "*/locales/*")
git commit -q -m "lsd: update to $new"
echo "committed; next: dev/test.sh --image, then dev/release.sh"
echo "overridden upstream files to re-apply: catalog/overrides/README"
