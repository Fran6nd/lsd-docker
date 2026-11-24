# The catalog

| category | class | what | examples |
|---|---|---|---|
| gamemodes | `Gamemode` | exactly one runs; every one runs the map's layout (map_layout) | tdm, parkour, ctf, bots, bots_rewards, onectf, arena, babel, ffa, hostage, editor |
| extensions | `Extension` | protocol extensions; the setup also asks what a client lacking one costs | every extension in the [AoS protocol registry](https://github.com/zerospades/aosprotocol): player_properties, damage_markers, teamplay, pie_menu, night (daytime and flashlight), edit_mode, player_limit, message_types, kick_reason (UTF-8 chat is built into LSd); plus silent_player |
| effects/player | `PlayerEffect` | change what a player's own actions do, or what happens around them when triggered; meant to be required by gamemodes, or forced on in setup | railgun, grenade_shotgun, pinning_smg, area_heal, area_hurt, medkit, nightvision, rocket, missile, grenade_launcher, airstrike, ammo_box |
| effects/world | `WorldEffect` | change the map or the match for everybody; same | the_fall |
| bots | `Bot` | server-side players | guards, battle_bots |
| tools | `Tool` | everything else | votekick, vote_map, rewards, inventory, esp_demo, headless, time_limit, ... |
| demos | `Demo` | set a server up to show something off, not to run for good | demo_reward (every reward free and unlimited) |
| libs | `Library` | what the others need; installed with them, not listed | ext, ext_policy, bot, shot_detect, player_effect, map_layout, callouts, blast, babel_protect, ask_player |

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

`nightvision` lets a player who has it light a wide green beam with the F
key that only their own client draws: every other client is told the
beam is dark, so neither the light nor its glare gives them away. The
flashlight (part of `night`) draws it, so install that too. Players without
night vision keep the ordinary flashlight, unless `nightvision_only`. A
gamemode can switch it for them with
`PlayerEffect.get("nightvision"):trigger(pid, {on = true})`.

## Extensions: what a client without one costs

Each extension has a policy (`ext_policy` in the settings, asked by its
setup): **applied** -- used by clients that have it, nobody else is
told; **recommended** -- a client without it is told what it misses;
**required** -- a client without it watches from spectator. A new server
turns nobody away:

| extension | without it | default |
|---|---|---|
| player_properties, damage_markers, pie_menu, night's Flashlight, kick_reason, message_types, silent_player, edit_mode, teamplay | something cosmetic, or a plain fallback | applied |
| night's Daytime and Weather | at night, a black fog instead of real darkness | applied by day, recommended at night |
| player_limit | see below | applied up to 32 seats, required above |

**More than 32 players** (`player_limit_max`, 32 by default): clients
with Player Limit can play; a client without it watches from spectator
and is never sent a player id it cannot hold (32 or more) -- and one that
arrives when 32 ids are already taken is told it is player 1 and sent
nothing about anybody. Older settings move to these defaults by
themselves; a policy you chose is kept.

## Babel

Upstream's tower game, made fair. You cannot build in the enemy's
tower area or remove blocks from your own (upstream's `babel_protect`),
and dashed lines in each team's colour are painted on the ground
around each area. Every player spawns holding their team's colour. For
Teamplay clients, an enemy who stands in your tower area or your spawn
and hardly moves (less than `babel_camp_move` blocks) for
`babel_camp_secs` (20 s) or `babel_spawn_secs` (15 s) is outlined for
your team -- "Camping by your tower", "In your spawn" -- until they
move, leave, die or disconnect. `babel_camp_marks = False` turns the
marks off.

## Parkour

One team, nobody to shoot: a course of gaps, steps, beams and stepping
stones over water that kills, from a start platform to the tent at the
end. The clock starts when a runner leaves the start platform and stops
at the tent; the time is told, each runner's best is kept, the record
is announced, and the runner is put back at the start. `/best` lists the
best times (kept by name while the server runs, through every map
restart; not through a restart of the server). There is no score and no
end. Whoever dies is back at once at the last checkpoint reached (the
yellow platforms), the clock still running; nobody builds or digs.

The course is generated (`catalog/core/parkour_map.lua`, from a seed)
when the mode is chosen, and is the only map in rotation: `lsdctl
gamemode parkour`, or `lsdctl play parkour random 10` for a casual game
with ten bots. `lsdctl map course [seed]` generates another, and
`lsdctl bots <n>` sets how many bots run it. Every obstacle is within
what the bot engine's bots can do (`bot/trees/parkour.bt`: "go to our
base"), so they run it too. A map of your own can be a course: its
`.txt` names the places, as the generated one does (`'parkour_start'`,
`'parkour_tent'`, `'parkour_checkpoints'`, and `'water_damage'` for the
water to kill).

## Bots: day and night

`bots` is team deathmatch against and alongside guard bots (6 a side
by default), through a day that turns to night and back:
`bots_day_secs` (240) of day, `bots_night_secs` (180) of night. At
nightfall everyone is told to light their flashlight, and the guards
light theirs; at dawn they put them out. Scoring is tdm's
(`tdm_kills`). `lsdctl play bots` plays it in one line.

`bots_rewards` is the same game with every reward free and unlimited
(`demo_reward`): rockets, missiles, airstrikes, as often as you like.
`lsdctl play bots_rewards`, or `bots_rewards` in the quick setup.

## Rewards

On by default, in every gamemode. Every `rewards_kills` kills (10) and
every intel capture earn a reward: one of the list below at random, the
costlier the rarer, put in the player's [inventory](#inventory) -- at
most `rewards_max` (3) held. It is used from there: `/inv`, the
Inventory pie, or `/reward <name>`. One that cannot be used right now (a
medkit at full health, night vision by day) is kept.

| reward | cost (rarity) | |
|---|---|---|
| Railgun | 1 | 30 s, or until death |
| Rocket | 1 | fired at once where you aim: a streak of blocks that blows a crater; one-shots a direct hit and anyone within 2 blocks |
| Missile | 2 | a top-attack missile, like a Javelin: it pops up, cruises above, and dives onto what your crosshair is on, following your aim live |
| Grenade launcher | 1 | a real grenade fired hard along your aim, exploding where you aim (up to 40 blocks), or on whatever it hits first |
| Airstrike | 2 | where you aim: everyone is warned (across the screen near the target), then five bombs fall in a line, each one-shotting within 5 blocks |
| Medkit | 1 | |
| Ammo box | 1 | a full resupply on the spot |
| Area heal | 1 | 20 s |
| Night vision | 1 | at night only |

The list is the `rewards_menu` setting, and only installed effects are
offered (rewards installs the nine with it). With `rewards_exclusive`
(the default) an effect on the menu is held only by whoever earned it,
even if it is otherwise on for everybody.

Three ways to run it, which `play` and the quick setup ask: **on**
(earned), **off** (`rewards_enabled = False`: nothing is earned and the
effects stay nobody's) and **infinite** (`rewards_free = True`: every
reward, unlimited, for everybody).

Bots earn and hold rewards like anybody, and each reward says when a bot
should use it: its `bot` entry in `rewards_menu` is a fragment of
behaviour tree in the bot engine's words (a medkit when hurt, an ammo
box when low, a missile at an enemy in sight under open sky...). Any
inventory item can carry one (`inventory_define`'s `bot`), and a
gamemode's tree uses them all with `tree items` (the language of those
trees, and how to write your own for a mode or for one bot:
[bot/TREES.md](../bot/TREES.md), section 13: everything a script can
give the bots -- a tree, a fragment, an item's rule, settings, orders,
and facts, places and words of its own naming). Every impact -- rocket, missile, bomb -- also plays a grenade explosion,
the sound and the flash, for every client. Rocket and airstrike are
ordinary effects too, built on the `blast` library: installed alone,
they are everybody's.

## Inventory

What a player holds. An item is a command: a script defines a kind
(`inventory_define(key, {label, command, aim})`) and hands items out
(`inventory_give(pid, key, n)`); using one runs its command as the
player and uses it up, unless the command kept it (`inventory_keep()`).
Players use theirs with `/inv` -- "1) Rocket x3  2) Medkit x1", then
`/inv <number|name>` -- or from the Inventory pie, each wedge labelled
with how many (`x∞` for an unlimited one), an aimed item sent the point
under the crosshair. The rewards are its first items.

## Voting the map on (/va)

On by default. `/va` starts a vote to move on to the next map, and
`/va` again agrees; a majority of the people playing carries it
(`vote_map_ratio`), one player alone at once. On a server whose maps
were picked at random (`play ... random`, the quick setup's random
rotation: `map_web_random`) the next map is a new random one from the
web, from what the map sources list for the game; elsewhere, the
rotation's next. In random mode every map change is one from the web,
the end of a round and the time limit too; the map being played goes
on until the new one is here (only the first map, at start, comes from
the rotation). The server may not run programs (its sandbox), so it
asks the container's entrypoint with a file and loads what comes back,
playing on meanwhile; with nothing in `vote_map_fetch_secs` (60), the
rotation's next.

## Asking a player (ask_player)

A library for scripts, not used by any yet:
`ask_player(pid, question, choices, callback, opts)` with 2 to 6
`{key, label}` choices. The player reads the question and numbered
choices in chat, in their language, and answers with
`/answer <number|key>`; while it is open their pie menu shows only the
question's pie (`pie_menu_override`). One question at a time per
player, later ones queue; the callback gets nil on timeout
(`ask_player_secs`, 30), `ask_player_cancel` or disconnect.

## Callouts

Every gamemode has its own pie of team callouts, ahead of the usual
pies: in babel "Digger!", "Help build", "Rush intel"; in ctf "Intel
stolen", "I have intel"; and so on. Each says its line to the team as
the player's chat, in each teammate's language -- words only, never a
ping. They live in
`catalog/libs/callouts/callouts/<gamemode>.lua`, one small file each.

The same files hold each gamemode's **pings**: the pie menu's Mark pie
(aiming at a block or an enemy) -- in ctf "Intel here", "Build here",
"Sniper"; in babel "Digger here", "Defend the tower". Each wedge sends
Teamplay's own command, `/pingmark %h <reason>`, the reason in the
language of whoever pings, so it is offered only to players whose
client speaks Teamplay and follows its rules (alive, in sight, not too
often). A gamemode with
no pings of its own gets Enemy, Attack, Defend, Need help, Danger and
Go here; ffa has none, having no team.

`night` is both the Daytime and Weather and the Flashlight extensions
(one file, `lib_night`), and tells the bot engine how bots see and use a
lamp at night. An entry takes one preset, so night's say both whether it
is day or night and how the beam looks:

| preset | |
|---|---|
| `day` | ordinary daylight, OpenSpades' warm white beam seen by everybody |
| `night` | full darkness, only flashlights light the world, the same beam |
| `night_vision` | night, a green beam only its carrier sees: nobody spots your light |
| `disco` | night, every player's beam a random colour, changing as they play |

Each of the two extensions has its own policy (the setup asks about
both; `--policy` sets both). By night the bots are told how far their
lamp lights (`flashlight_cone`, `flashlight_reach`) and how far night
vision sees a lit lamp (`night_far`, 192 blocks).

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

## Protected blocks

An effect or a bot that breaks blocks -- a rocket's crater, a railgun,
the Fall's shaft, a guard digging through a wall -- is the server
breaking them, which nothing guarding blocks against players sees. So
they all go through one door, `PlayerEffect.break_blocks(owner, list,
type)` (bots: `bot_dig_block(x, y, z, pid)`), which asks one gate,
`may_break_block(owner, pos, type)`, for every block. A script that
protects blocks joins the gate once and holds for every effect and
bot there is:

```lua
function mod.may_break_block(owner, pos, type)
	if (<pos is mine to guard>) then return false; end
	local below = mod.next.may_break_block;
	return below == nil or below(owner, pos, type);
end
```

Babel does: its platform, and each team's tower area against that
team (and against ownerless world effects). `tests/catalog_test.lua`
refuses an effect or a bot, or a library one needs, that breaks a
block without asking the gate.

## Writing a catalog entry

An entry is a directory, `catalog/<category>/<id>/`:

```
catalog/extensions/night/
├── script.lua           the manifest
└── lib_night.lua        the LSd module(s) it ships
```

The manifest is one call to its category's class, which extends the
abstract `Script` (`catalog/core/catalog.lua`):

```lua
return Extension {
	title = "Flashlight",
	summary = "Server-controlled flashlights.",
	module = "lib_flashlight",       -- or modules = {...}
	ext_id = 0x32,                   -- policy = "applied" or a function of its settings
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

An entry that speaks several protocol extensions lists them instead of
`ext_id`/`policy`, each with its own policy and its own question in the
setup (`night` does):

```lua
	exts = {
		{id = 0x33, title = "Daytime and Weather", policy = function(v) ... end},
		{id = 0x32, title = "Flashlight", policy = "applied"},
	},
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
