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

**Knowing when there is one.** The server asks ghcr.io, a minute after
it starts and then every six hours, which lsd-docker versions are
published -- an anonymous request for the image's tags, nothing about
the server is sent. When a newer one exists, every admin is told as they
log in (`/login`), once per connection, in their language; nobody else
is. `lsd status` shows it too, and `lsd update-check` asks right away.
To turn it off: `lsd set update_check False`. (The notice goes to whoever
holds the `update_notice` cap, which admins have.)

**LSd itself is part of the image.** An instance updates only by moving
to a newer lsd-docker image; nothing in it fetches or rebuilds LSd. LSd
moves in development (`dev/bump-lsd.sh`), and reaches servers with the
next release.

## The catalog

| category | class | what | examples |
|---|---|---|---|
| gamemodes | `Gamemode` | exactly one runs; every one runs the map's layout (map_layout) | ctf, onectf, arena, babel, ffa, hostage, editor |
| extensions | `Extension` | protocol extensions; the setup also asks what a client lacking one costs | every extension in the [AoS protocol registry](https://github.com/zerospades/aosprotocol): player_properties, damage_markers, teamplay, pie_menu, flashlight, daytime, edit_mode, player_limit, message_types, kick_reason (UTF-8 chat is built into LSd); plus silent_player |
| effects/player | `PlayerEffect` | change what a player's own actions do, or what happens around them when triggered; meant to be required by gamemodes, or forced on in setup | railgun, grenade_shotgun, pinning_smg, area_heal, area_hurt, medkit |
| effects/world | `WorldEffect` | change the map or the match for everybody; same | the_fall |
| bots | `Bot` | server-side players | guards, battle_bots |
| tools | `Tool` | everything else | votekick, esp_demo, headless, time_limit, ... |
| libs | `Library` | what the others need; installed with them, not listed | ext, ext_policy, bot, shot_detect, player_effect, map_layout |

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

Some effects are set off rather than worn: `area_heal` heals the
teammates around a player, `area_hurt` damages the enemies around them
(the kill is theirs), `medkit` gives a player health back. A gamemode
triggers them when it decides, with its own radius and amount or the
settings':

```lua
PlayerEffect.get("area_heal"):trigger(pid, {radius = 10, amount = 30})
PlayerEffect.get("area_hurt"):trigger(pid, {radius = 6, amount = 40})
PlayerEffect.get("medkit"):trigger(pid, {free = true})
```

Heals are dealt as negative damage from the healer, so a player with the
Damage Markers extension sees them float over each one healed, as damage
floats over each one hit. On its own -- forced on, no gamemode -- such
an effect fires by itself every `<id>_every` seconds for each player who
has it: `area_heal_every = 2` and `area_hurt_every = 2` by default;
`medkit` stays on `/m` (`medkit_every = 0`). A gamemode driving them
itself sets `<id>_every = 0`.

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

The Edit Mode extension puts a player in edit mode with
`/editmode [player] [on|off]` (the `editmode` cap). The editor gamemode
does not use it: building there works the same for every client.

### Building maps

Building is a gamemode of its own: `lsd gamemode editor`. While it runs,
the server is off the public lists (the address still works, to invite
builders), `time_limit` is paused, and every player builds: terrain
tools (`/sel`, `/selfill`, `/selrm`, `/selcpy`, ...), flight (`/noclip`),
any block anywhere, unlimited blocks, no fall damage, and a gun that does
not chew the map.

The tools are in the pie menu, ahead of the usual pies (the editor
installs `pie_menu`):

| pie | when aiming at | wedges |
|---|---|---|
| Select | a block | Corner 1, Corner 2 (where you aim), Fill, Remove, Paint, Deselect |
| Place | a block | Door (up / aside), Lift (up / down), Mark here, Delete |
| Map | anything | Undo, Save, Fly, Components, Chunks, Help |

Select two corners, then Fill or Remove the box -- or Door or Lift, which
take it as theirs; a lift then wants the height it travels to: aim there,
Mark here. Every wedge is a command too, for clients without the pie
menu.

A map's **layout** -- what it holds besides terrain -- is placed here
and runs in every gamemode, kept in `<map>.editor.json` beside the map:

- **doors** that open as a player nears them, **elevators** that carry
  riders: build the shape, then `/place door left` (or `/place elevator
  up`) and select its box; `/place` lists them, `/undo` and `/delete`
  take one back, its blocks left as they are;
- **permission chunks**: `/chunk box rw:1 base` -- who may edit inside;
  `/defaultperm` for the rest of the map, `/mapreadonly on` to lock it.

`/save` writes the map and its layout to `maps/`; then
`lsd gamemode ctf` (or any other) plays it, doors and all. Marks can
also come by coordinate (`/marks x y z ...`), which with `/place` drives
a placement from the console.

Under the hood: `catalog/libs/map_layout/` runs layouts (doors,
elevators, permissions, the layout file), and
`catalog/gamemodes/editor/` is the editing session and its commands.

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

### Your own scripts

A server runs scripts of your own -- new ones, or your version of one
of the image's -- without building an image, from its data volume:

| Where | What | Updates |
|---|---|---|
| `/data/catalog/<category>/<id>/` | a catalog entry of your own: `script.lua` and its module(s), installed with `lsdctl install` like any other | kept |
| `/data/scripts/` | loose Lua modules, copied over everything else at start: a patched copy of any module, by file name | kept |

`lsd update` replaces the image and leaves `/data` alone, so both
survive every update. An entry of yours with the id of one of the
image's replaces it -- updates included -- until you remove yours.

**Seeing them**: `lsd local` lists your entries and loose modules, and
for each whether it is installed, whether the running server has it
loaded, and which of the image's scripts it replaces:

```
Your entries (/data/catalog), kept across updates:
  * hello              Tools            running
  * votekick           Tools            running; replaces the image's votekick
    draft              Tools            not installed

Loose modules (/data/scripts), kept across updates:
    motd.lua                           running; replaces the image's motd.lua
```

**Adding one.** Write the entry on your machine, as described above:

```
hello/
├── script.lua        return Tool {title = "Hello", summary = "Says hello.", module = "hello"}
├── hello.lua         the module
└── locales/fr.po     optional: its translations (see TRANSLATIONS.md)
```

```lua
-- hello.lua
local mod = init_mod();
local cmd = {name = "hello", desc = "Say hello."};
function cmd.func(pid)
	l10n_send_chat(pid, {en = "Hello, %(name)!"}, {name = get_name(pid)});
end
register_command(cmd, mod);
return mod;
```

Copy it into the server's volume, and install it:

```sh
docker exec lsd mkdir -p /data/catalog/tools
docker cp hello lsd:/data/catalog/tools/hello
lsd available tools        # hello  Says hello.  (yours)
lsd install hello          # restarts the server with it
lsd info hello             # source: /data/catalog/tools/hello (yours: updates keep it)
```

Player and world effects go one level deeper, in
`/data/catalog/effects/player/<id>/` and `/data/catalog/effects/world/<id>/`.

**Changing it**: `docker cp` the new version over the old one, then
`lsd restart`. **Removing it**: `lsd remove hello`, then delete the
directory (`docker exec lsd rm -r /data/catalog/tools/hello`).

**Working on scripts often?** Mount a directory of your machine as the
catalog instead of copying, when creating the container:

```sh
docker run -d --name lsd --restart unless-stopped -p 32887:32887/udp \
    -v lsd-data:/data -v "$PWD/my-scripts:/data/catalog" ghcr.io/fran6nd/lsd-docker
```

`my-scripts/` then holds `tools/hello/` and the like, edited in place;
`lsd update` recreates the container with the same mounts.

**Loose modules** in `/data/scripts/` need no manifest: `hello.lua`
there replaces any `hello.lua` the image ships, for every script that
loads it. They load only when something loads them, so they are for
patching, not adding; a new script belongs in `/data/catalog`.

### Translations

English, French, Spanish, Chinese and Russian, each complete: the tests
fail unless every language translates every message.
**[TRANSLATIONS.md](TRANSLATIONS.md)** covers the whole pipeline: the
files, machine translation with LibreTranslate, reviewing, adding a
language, parity, and what happens when LSd changes.

Every player reads the server in their own language: the one they chose
with `/lang fr` (`/lang auto` to undo), else the locale their client
reports, else `l10n_default_lang`. `fr_ca` falls back to `fr`, then the
default, then English.

Translations are for ZeroSpades 0.0.9 and above only: the client that
sends its locale, speaks UTF-8 and draws the scripts translated into
(accents, Cyrillic, Chinese). Every other client -- an older ZeroSpades, stock
OpenSpades, BetterSpades, Voxlap -- reads `l10n_default_lang`, and `/lang`
tells them what translations need. The gate is a setting, the client
names and the oldest version of each (that version and above), matched
in the version string a client reports:

```
l10n_clients = {ZeroSpades: '0.0.9'}
```

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

The pre-commit hook keeps the templates and `.po` files in step with the
code; `dev/l10n_mt.sh <lang>` drafts a new language by machine. See
[TRANSLATIONS.md](TRANSLATIONS.md).

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
