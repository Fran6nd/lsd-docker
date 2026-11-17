# lsd-docker

An [LSD](https://66.135.15.57/lsd/) Ace of Spades server in one Docker
image: the server, a catalog of scripts to install (gamemodes, protocol
extensions, weapon effects, bots, tools), and `lsdctl`, which administers
all of it from a docker command. One container is one server.

You do not need this repository to run it.

## Install

One line, which pulls the image, runs the setup wizard and starts the
server:

```sh
curl -fsSL https://raw.githubusercontent.com/Fran6nd/lsd-docker/master/install.sh | sh
```

Or the same thing, by hand:

```sh
docker run --rm -it -v lsd-data:/data ghcr.io/fran6nd/lsd-docker setup
docker run -d --name lsd --restart unless-stopped \
    -p 32887:32887/udp -v lsd-data:/data ghcr.io/fran6nd/lsd-docker
```

Skipping `setup` is fine: a server started on an empty volume writes
default settings, generates a flat map so it can boot, and runs ctf.

Everything the server keeps lives on the `/data` volume:

| path | what |
|---|---|
| `/data/settings` | the whole configuration: installed scripts, gamemode, every value |
| `/data/maps/` | the maps (`.vxl`, and their `.txt` metadata) |
| `/data/rw/` | bans, accounts, the admin console socket |
| `/data/catalog/` | your own catalog entries (optional, see below) |
| `/data/scripts/` | loose Lua modules that override any other (optional) |

## Administer

Everything is `lsdctl`, inside the container:

```sh
docker exec -it lsd lsdctl help
```

(The installer also puts an `lsd` shorthand on your PATH: `lsd status`
is `docker exec -it lsd lsdctl status`.)

```sh
lsdctl status                        # version, state, gamemode, scripts, maps
lsdctl setup                         # the wizard again: name, port, listing, gamemode, scripts

lsdctl available                     # every script this image can install
lsdctl info flashlight               # what it does, needs, asks, and every setting it reads
lsdctl install flashlight            # install, run its setup, restart to load it
lsdctl install flashlight --preset night_vision --policy required --yes
lsdctl configure flashlight          # run its setup again
lsdctl remove flashlight
lsdctl list                          # what is installed

lsdctl gamemode                      # list gamemodes (* is the current one)
lsdctl gamemode hostage              # switch

lsdctl set masterlist_name "'My server'"   # any setting
lsdctl get guard_count
lsdctl edit                          # the settings file in vi

lsdctl map list
lsdctl map add https://example.com/mesa.vxl
lsdctl map load mesa                 # switch the live map now
lsdctl masterlist off                # unlist, live, nobody disconnected

lsdctl restart                       # warns players; the container stays up
lsdctl say "back in five"
lsdctl console                       # the in-game admin console
```

The settings are read when the server starts, so every change restarts
the server process after a five-second in-game warning; `--now` skips
the wait and `--no-restart` leaves it for later. The container itself
stays up, and the map, bans and accounts survive.

On a terminal every setup asks its questions; otherwise, or with
`--yes`, the defaults (or the `--preset` given) are taken, so all of it
scripts.

## Update

```sh
docker run --rm --volumes-from lsd \
    -v /var/run/docker.sock:/var/run/docker.sock \
    ghcr.io/fran6nd/lsd-docker update
```

Pulls the newest image and recreates the `lsd` container on it, keeping
its volume, name, restart policy, networks and anything else it was run
with, and publishing the port the settings name -- so this is also how a
port change is applied. The old container is kept until the new one is
up, and restored if it is not. New images bring new and updated scripts:
`lsdctl available` afterwards.

The update runs in a throwaway container. The server's own container is
never given the docker socket.

## The catalog

| category | class | what | examples |
|---|---|---|---|
| gamemodes | `Gamemode` | exactly one runs | ctf, onectf, arena, babel, ffa, hostage |
| extensions | `Extension` | protocol extensions; the setup also asks what a client lacking one costs | flashlight, daytime, teamplay, damage_markers, player_limit, message_types, silent_player |
| effects | `Effect` | change how the game plays | railgun, grenade_shotgun, pinning_smg, the_fall, grenade_pit |
| bots | `Bot` | server-side players | guards, battle_bots |
| tools | `Tool` | everything else | world_editor, votekick, esp_demo, headless, time_limit, ... |
| libs | `Library` | what the others need; installed with them, not listed | ext, ext_policy, bot, shot_detect |

The flashlight's presets:

| preset | |
|---|---|
| `default` | OpenSpades' warm white beam, seen by everybody |
| `night_vision` | a green beam only its carrier sees: nobody spots your light |
| `disco` | every player's beam a random colour, changing as they play |

### Writing a catalog entry

An entry is a directory, `catalog/<category>/<id>/`:

```
catalog/extensions/flashlight/
├── script.lua           the manifest
└── lib_flashlight.lua   the LSd module(s) it ships
```

The manifest is one call to its category's class, which extends the
abstract `Script` (`catalog/core/catalog.lua`):

```lua
return Extension {
	title = "Flashlight",
	summary = "Server-controlled flashlights.",
	module = "lib_flashlight",       -- or modules = {...}
	ext_id = 0x32,
	requires = {},                   -- other catalog ids (load before it)
	presets = {
		{name = "default", summary = "...", values = {flashlight_red = 255}},
	},
	questions = {                    -- asked by its setup
		{key = "flashlight_blast", type = "boolean", default = false,
			ask = "Grenade blasts shake beams?"},
	},
}
```

The category decides where the modules load (`phase`), what every entry
of the kind depends on, and what installing means. An entry for an
upstream LSd module sets `upstream = true` and ships no files.

Entries in `/data/catalog/<category>/<id>/` work the same way and win
over the image's own of the same id, which is how a server runs its own
or a modified script without building an image.

## Developing

```sh
git clone --recurse-submodules git@github.com:Fran6nd/lsd-docker.git
git config core.hooksPath githooks
dev/test.sh                 # Lua tests
dev/test.sh --image         # and build + smoke-test the image (docker)
dev/bump-lsd.sh             # move the lsd submodule to upstream master
dev/release.sh              # version, tag and push; CI publishes the image
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

The image is linux/amd64: upstream's seccomp filter knows x86, x86_64
and 32-bit arm, but not arm64. On an arm64 machine Docker runs it under
emulation.

### Moving from the multi-instance layout

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

Then start the server as in [Install](#install).

## License

AGPL-3.0-or-later; see [LICENSE](LICENSE).
