# The catalog

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

## Writing a catalog entry

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

## Your own scripts

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
└── locales/fr.po     optional: its translations (see [translations](translations.md))
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
