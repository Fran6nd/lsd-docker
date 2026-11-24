# Developing

```sh
git clone --recurse-submodules git@github.com:Fran6nd/lsd-docker.git
git config core.hooksPath githooks
dev/test.sh                 # Lua tests
dev/test.sh --image         # and build + smoke-test the image (docker)
dev/bump-lsd.sh             # move the lsd submodule to upstream master
dev/release.sh              # version, tag and push; CI publishes the image
dev/demo-new.sh             # a demo server of the working tree to play on (parkour with the engine's bots; LSD_DEMO_GAME=tdm for tdm on random maps)
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

## Bots

The bots are made of three pieces, described in `bot/README.md`:

- **The server's side**, `catalog/libs/botlink` (`lib_botlink`): makes the
  link file when a script asks for the first bot, writes the world into
  it, takes the engine's intents and actions out. It loads
  `libbotlink.so` and reads `botlink.h` through LuaJIT's ffi. A server
  with no bots makes no file.
- **The link**, `bot/link/`: the file's layout (`botlink.h`) and the
  library both ends use.
- **`botd`**, `bot/botd/`: the host process. It waits for the file, maps
  it, runs the core (`bot/core/`) at 60 rounds a second and writes the
  bots' intents back. The server cannot start a process (its sandbox), so
  the entrypoint starts botd beside it (`bot_helper`), as `lsd`, restarts
  it if it exits while the server is up, and, when the server stops, stops
  botd and removes the file and the map dumps.

In the image: `/usr/local/bin/botd`, `/lsd/exec/libbotlink.so` and
`/lsd/exec/botlink.h` (where `lib_botlink` looks first), and the behaviour
trees (`bot/trees/*.bt`) in `/opt/botd/trees`, with `bttree` to look at
and check them (how a tree is written, compiled and run, and how to give
bots your own: [bot/trees/README.md](../bot/trees/README.md) step by
step, [bot/TREES.md](../bot/TREES.md) for reference; the other bot
documents are indexed in [bot/README.md](../bot/README.md)). The link file is
`/dev/shm/lsd-botlink` (setting `botlink_file`, read when botd starts), the
map dumps `$LSD_DATA/rw/botlink-map-N.vxl`. botd is built only once
`bot/core/engine.c` exists.

To run botd by hand against a server (a local one, or in the container
with `docker exec -u lsd`): `botd --file /dev/shm/lsd-botlink --trees
bot/trees`; `--once` exits at once if there is no file, `--hz` and
`--budget` set the rate and the planner's work per round.

```sh
make -C bot          # libbotcore.a, libbotlink.so, build/bin/botd
make -C bot test     # every bot/tests/*_test.c; botd_test runs botd
                     # against a fake engine and a fake server
```

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
