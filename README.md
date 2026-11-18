# lsd-docker

An [LSD](https://66.135.15.57/lsd/) Ace of Spades server in one Docker
image: the server, a catalog of scripts to install (gamemodes, protocol
extensions, weapon effects, bots, tools), and `lsdctl`, which administers
all of it from a docker command. One container is one server.

You do not need this repository to run it.

## Install

You need Docker: [Docker Desktop](https://www.docker.com/products/docker-desktop/)
on Windows and macOS, [Docker Engine](https://docs.docker.com/engine/install/)
on Linux. Then one line pulls the image, runs the setup wizard, starts
the server and prints the `aos://` addresses players connect with.

**Linux and macOS**, in a terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/Fran6nd/lsd-docker/master/install.sh | sh
```

**Windows**, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/Fran6nd/lsd-docker/master/install.ps1 | iex
```

(Inside WSL, the Linux line works too, and finds the Windows LAN
address.) If Windows Firewall asks about Docker, allow it, or players on
your network cannot connect.

| | Linux | macOS | Windows |
|---|---|---|---|
| installer | `install.sh` | `install.sh` | `install.ps1` (or `install.sh` in WSL) |
| image | amd64, arm64 | arm64 (Apple silicon), amd64 (Intel) | amd64, arm64 |
| afterwards | `lsd <command>` shorthand, if `/usr/local/bin` or `~/.local/bin` is writable | same | `docker exec -it lsd lsdctl <command>` |

Docker picks the image for your machine. On arm64 the server runs
without upstream's seccomp filter, which does not support that
architecture; see [Developing](#developing).

### By hand

The installers only run these, which work the same in every shell (in
PowerShell, end continued lines with `` ` `` instead of `\`):

```sh
docker volume create lsd-data
docker run --rm -it -v lsd-data:/data ghcr.io/fran6nd/lsd-docker setup
docker run -d --name lsd --restart unless-stopped \
    -p 32887:32887/udp -e LSD_HOST_ADDRESSES=192.168.1.20 \
    -v lsd-data:/data ghcr.io/fran6nd/lsd-docker
```

Use the port you chose in setup on both sides of `-p`.
`LSD_HOST_ADDRESSES` is optional: it is the host's LAN address(es),
which a container cannot see, so that `lsdctl address` can print the
`aos://` URL players on your network connect with (the installers fill
it in). Setup ends by printing those addresses, and the public one for
a listed server.

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

(On Linux and macOS the installer also puts an `lsd` shorthand on your
PATH: `lsd status` is `docker exec -it lsd lsdctl status`.)

```sh
lsdctl status                        # version, state, gamemode, scripts, maps, addresses
lsdctl address                       # the aos:// URLs players connect with
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
| extensions | `Extension` | protocol extensions; the setup also asks what a client lacking one costs | every extension in the [AoS protocol registry](https://github.com/zerospades/aosprotocol): player_properties, damage_markers, teamplay, pie_menu, flashlight, daytime, edit_mode, player_limit, message_types, kick_reason (UTF-8 chat is built into LSd); plus silent_player |
| effects/player | `PlayerEffect` | change what a player's own actions do; meant to be required by gamemodes, or forced on in setup | railgun, grenade_shotgun, pinning_smg |
| effects/world | `WorldEffect` | change the map or the match for everybody; same | the_fall |
| bots | `Bot` | server-side players | guards, battle_bots |
| tools | `Tool` | everything else | world_editor, votekick, esp_demo, headless, time_limit, ... |
| libs | `Library` | what the others need; installed with them, not listed | ext, ext_policy, bot, shot_detect, player_effect |

A player effect forced on in setup is everybody's (`<id>_everyone = true`).
A gamemode can hand one out instead, per player, for a time, until death
or until the map changes, replacing or stacking:

```lua
local rail = PlayerEffect.get("railgun")
rail.everyone = false
rail:give(pid, {secs = 30})                    -- replaces what they had
rail:give(pid, {minutes = 2, stack = true})    -- on top of it
rail:give(pid, {death = true})                 -- until they die
rail:give(pid, {map = true})                   -- until the map changes
rail:take(pid)
```

The flashlight's presets:

| preset | |
|---|---|
| `default` | OpenSpades' warm white beam, seen by everybody |
| `night_vision` | a green beam only its carrier sees: nobody spots your light |
| `disco` | every player's beam a random colour, changing as they play |

The pie menu's slices come from the settings file, or a built-in menu
of pings, quick chat and player commands when it names none:

```
pie_menu = [
	{theme: 'Orders', when: 'block enemy', slices: [
		{text: '/pingmark %h Attack', label: 'Attack'},
		{text: '/pingmark %h Defend', label: {en: 'Defend', fr: 'Défendre'}},
	]},
]
```

Edit mode follows the world editor's `worldedit on|off`, or
`/editmode [player] [on|off]` for holders of the `editmode` cap.

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

### Translations

Every player reads the server in their own language: the one they chose
with `/lang fr` (`/lang auto` to undo), else the locale their client
reports (OpenSpades and its forks send it on connect), else
`l10n_default_lang`. `fr_ca` falls back to `fr`, then the default, then
English.

A script writes its messages in English, with LSd's `%(name)`
placeholders, and every message is translated for each player it
reaches, broadcasts included:

```lua
l10n_send_chat(PID_BROADCAST, {en = "%(name) was kicked"}, {name = n})
server_msg(pid, l10n_msg({en = "Edit mode on."}))  -- server_msg, send_chat,
kick_reason_set(pid, l10n_msg({en = "Vote kicked"}))  -- msg_send take one
l10n_msgn({en = "%(n) bot", en_plural = "%(n) bots"}, count)
```

Translations live with the script, as gettext files:

```
catalog/tools/votekick/locales/
├── template.pot   every message of the script, written by dev/l10n.lua
└── fr.po          its French
```

`luajit dev/l10n.lua` rewrites every template and brings each `.po` in
line with it; the pre-commit hook runs it, so they never go stale.
`luajit dev/l10n.lua --new de catalog/tools/votekick` starts a language.
Edit a `.po` with any gettext editor (Poedit, ...); `msgfmt -c` checks
it, and the tests check that each translation keeps its placeholders.
Upstream LSd's own messages are translated in `catalog/overrides/locales/`.

The pie menu speaks the same way. Its default layout has pies with ids
(`mark`, `chat`, `player`, `watching`), and a command puts itself in one
by carrying a `pie` field -- its label goes in that script's template
like any other message:

```lua
local cmd = {name = "votekick", ...,
	pie = {pie = "player", slot = 1, args = "%p",
		label = {en = "Vote kick"}, tooltip = {en = "Start a vote"}}}
register_command(cmd, mod)        -- the wedge sends "/votekick %p"
```

`pie_menu_slice(name, {pie = ..., text = ..., label = ...})` does the
same from any script. A slice takes the slot it asks for if free, else
the first free one; a full pie continues in another just after it; a
pie that is not there is created, from `pie = {id=, theme=, when=}` or
the default layout's.

Text an operator writes in the settings -- `motd` lines, `tips`,
`kick_reason_texts`, `ext_policy_alert_text` -- may be plain text or a
language map, and every player reads their own:

```
motd = [{en: 'Welcome to %(server)!', fr: 'Bienvenue sur %(server) !'}]
tips = [{en: 'Type /lang to change language', fr: 'Tape /lang pour changer de langue'}]
```

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

Images are published for linux/amd64 and linux/arm64, each built and
smoke-tested on its own architecture. Upstream's seccomp filter knows
x86_64, i386 and 32-bit arm but not arm64, so the arm64 image runs
without seccomp (no_new_privs and the container's isolation remain);
`lsdctl status` shows which sandbox a server has.

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
