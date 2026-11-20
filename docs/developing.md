# Developing

```sh
git clone --recurse-submodules git@github.com:Fran6nd/lsd-docker.git
git config core.hooksPath githooks
dev/test.sh                 # Lua tests
dev/test.sh --image         # and build + smoke-test the image (docker)
dev/bump-lsd.sh             # move the lsd submodule to upstream master
dev/release.sh              # version, tag and push; CI publishes the image
dev/demo-new.sh             # a demo server of the working tree to play on (bots_rewards, random maps)
dev/demo-refresh.sh         # the demo rebuilt from the working tree, its volume kept
dev/demo-clean.sh           # the demo gone: container, volume, image
```

| path | |
|---|---|
| `lsd/` | upstream LSd, a pristine submodule |
| `catalog/core/` | `catalog.lua` (the classes, load order), `settings_format.lua` (the one parser), `lib_server` |
| `catalog/<category>/` | the scripts |
| `catalog/overrides/` | patched upstream modules (`sel.lua`, pending upstream) |
| `image/` | `config.lua`, the entrypoint/supervisor, `lsdctl`, `update` |
| `tests/` | run on the host with luajit, no server needed |
| `dev/` | test, smoke, bump and release scripts |

Versions are the release date plus a counter (`2026.11.17.1`), in
`VERSION`. `dev/release.sh` sets it, tags `v<version>` and pushes;
the tag makes CI build, smoke-test and publish
`ghcr.io/fran6nd/lsd-docker:<version>` and `:latest`. Every push and
pull request runs the tests, shellcheck and the smoke test.

Images are published for linux/amd64 and linux/arm64, each built and
smoke-tested on its own architecture. Upstream's seccomp filter knows
x86_64, i386 and 32-bit arm but not arm64, so the arm64 image runs
without seccomp (no_new_privs and the container's isolation remain);
`lsdctl status` shows which sandbox a server has.

## Moving from the multi-instance layout

Pick the instance to keep, then on the host that ran it, from the old
checkout (its `instances/<name>.map/` holds the maps; the `.vxl` files
were never in git):

```sh
docker volume create lsd-data
# its bans and accounts
docker run --rm -v lsd-rw:/from -v lsd-data:/to alpine cp -a /from/. /to/rw/
# its maps
docker run --rm -v "$PWD/instances/hostage.map:/from" -v lsd-data:/to alpine \
    sh -c 'mkdir -p /to/maps && cp -a /from/. /to/maps/'
# its settings (gone from the tree, still in history): load_order
# becomes the scripts list
git show 35f9bfb:instances/hostage.settings > /tmp/hostage.settings
docker run --rm -v /tmp/hostage.settings:/old.settings:ro -v lsd-data:/data \
    ghcr.io/fran6nd/lsd-docker import /old.settings
```

Then start the server as in [Install](../README.md#install).
