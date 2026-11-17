#!/bin/sh
# dev/release.sh -- cut a release: version, commit, tag, push
#
# Versions are the date plus a counter: 2026.11.17.1, then 2026.11.17.2
# for a second release the same day. Pushing the tag is what makes CI
# build, smoke-test and publish ghcr.io/<owner>/lsd-docker:<version>
# and :latest (.github/workflows/release.yml).
#
#   dev/release.sh             release master as it stands
#   dev/release.sh --dry-run   say what would happen
set -eu
cd "$(dirname "$0")/.."

dry=
[ "${1:-}" = --dry-run ] && dry=1

[ "$(git rev-parse --abbrev-ref HEAD)" = master ] || { echo "release from master" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first" >&2; exit 1; }

git fetch --tags --quiet origin
today=$(date +%Y.%m.%d)
n=1
while git rev-parse -q --verify "refs/tags/v$today.$n" >/dev/null; do
	n=$((n + 1))
done
version=$today.$n

dev/test.sh

if [ -n "$dry" ]; then
	echo "would release $version (lsd $(git -C lsd rev-parse --short HEAD))"
	exit 0
fi

if [ "$(cat VERSION)" != "$version" ]; then
	printf '%s\n' "$version" > VERSION
	git add VERSION
	git commit -q -m "release $version"
fi
git tag -a "v$version" -m "lsd-docker $version"
git push origin master "v$version"
echo "released $version: CI publishes the image (watch: gh run watch)"
