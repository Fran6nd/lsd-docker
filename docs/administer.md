# Administering a server

Everything the server keeps lives on the `/data` volume:

| path | what |
|---|---|
| `/data/settings` | the whole configuration: installed scripts, gamemode, every value |
| `/data/maps/` | the maps (`.vxl`, and their `.txt` metadata) |
| `/data/rw/` | bans, accounts, the admin console socket |
| `/data/catalog/` | your own catalog entries (optional, see below) |
| `/data/trees/` | your own bot behaviour trees, `<name>.bt` (optional; read at each map load: [writing one, step by step](../bot/trees/README.md)) |
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
lsdctl setup                         # the wizard again: quick (name, listing, game, map) or full

lsdctl available                     # every script this image can install
lsdctl info night                    # what it does, needs, asks, and every setting it reads
lsdctl install night                 # install, run its setup, restart to load it
lsdctl install night --preset night_vision --policy required --yes
lsdctl configure night             # run its setup again
lsdctl remove night
lsdctl list                          # what is installed

lsdctl gamemode                      # list gamemodes (* is the current one)
lsdctl gamemode hostage              # switch

lsdctl set masterlist_name "'My server'"   # any setting
lsdctl get guard_count
lsdctl edit                          # the settings file in vi

lsdctl map list
lsdctl map add https://aos.party/view/864    # a map from aos.party, with its .txt
lsdctl map add https://example.com/mesa.vxl  # any .vxl link, or a local file
lsdctl map load Remus                # switch the live map now
lsdctl map load random               # ...to a random one
lsdctl set map_random True           # play the rotation in a random order
lsdctl masterlist off                # unlist, live, nobody disconnected

lsdctl account add alice admin       # an account, its password asked for (or read from stdin)
lsdctl account list                  # every account and its caps
lsdctl account caps alice mod        # replace its caps (admin: everything; mod, guard: see cap_groups)
lsdctl account passwd alice          # reset its password
lsdctl account rm alice

lsdctl restart                       # warns players; the container stays up
lsdctl say "back in five"
lsdctl console                       # the in-game admin console
```

An account's player logs in with `/login alice <password>`. A password
never goes on the command line and never reaches the server's log; a
script gives it on stdin: `echo "$pw" | docker exec -i lsd lsdctl account add alice admin`.
The server has to be running.

The settings are read when the server starts, so every change restarts
the server process after a five-second in-game warning; `--now` skips
the wait and `--no-restart` leaves it for later. The container itself
stays up, and the map, bans and accounts survive.

**Finding maps:** [aos.party](https://aos.party) is a good place -- browse
it, and paste a map's page into `lsdctl map add` (or into the setup
wizard, which asks for maps after the gamemode). Its download links work
too (`lsdctl map add https://aos.party/download/864/vxl`), and so does
`aos.party:864`; each brings the map's `.txt` (name, author) along.
[hosting.dgd.cx](https://hosting.dgd.cx/map-search) is built in too: paste
its map page (`https://hosting.dgd.cx/map-search?map=Normandie`), or write
`hosting.dgd.cx:Normandie` -- the map's file name, spaces and all
(`hosting.dgd.cx:Rocket Island`). A random map, in `play` and the quick
setup, is picked from what the sites have: a source at random, its maps
for the game (babel maps for babel, capture-the-flag maps for the rest),
one of those at random -- and another, or the other source, when one
fails. Parkour and range take none of them: choosing one generates its
map (`parkour.vxl`, `range.vxl`) and makes that the whole rotation;
`lsdctl map course [seed]` generates another. A source says how to list its maps in its own entry
(`catalog/core/map_sources.lua`, `list`), so one of yours can too.
Other sites that publish maps by id can be added beside them:

```
map_sources = [{name: 'example', view: 'https://example.org/map/%(id)',
                vxl: 'https://example.org/get/%(id).vxl',
                txt: 'https://example.org/get/%(id).txt'}]
```

On a terminal every setup asks its questions; otherwise, or with
`--yes`, the defaults (or the `--preset` given) are taken, so all of it
scripts.

## The bots

Bots that play as players do (`lsdctl bots <n>`: n a team) decide with a
behaviour tree, a text you can read and replace. They take player ids
like people do, out of the 255 seats a server has by default
(`player_limit_max`); a person who finds every seat taken gets a bot's,
so no number of bots keeps anybody out. A player id above 31 needs a
client with Player Limit (ZeroSpades); any other client watches from
spectator, told to update ([catalog](catalog.md#extensions-what-a-client-without-one-costs)). Four settings say how
they play, each applied within a second, empty by default:

```sh
lsdctl set engine_bots_tree "'mine'"                # the tree they run, by name: yours is /data/trees/mine.bt
lsdctl set engine_bots_archetypes "'camper:2,pusher:1'"   # the mix of characters
lsdctl set engine_bots_traits "'aggression:1.5'"    # every bot's weights, scaled
lsdctl set engine_bots_edit "'dig'"                 # what a bot's route may do to the map: dig, build, all
lsdctl set engine_bots_level 8                      # how good they are, 1 to 10 (10 by default)
lsdctl set engine_bots_level_spread 0               # how far each may fall from it, either way (0 by default)
```

A level is how WELL a bot aims, reacts, hears and moves, never what it
chooses to do: [the table](../bot/TREES.md#11-characters-traits-archetypes-weights).

The bots think in a process of their own beside the server (`botd`),
whose heaviest work is finding routes on a big map; a team's bots going
the same way share one search, and no round gives routes more than about
half its time (what does not fit waits for the next). It can search up
to four routes at once, and look for many bots at once, on as many
threads. How many it uses is read when it starts and changes nothing of
what the bots do, only how much route finding fits in a round; measured
at 200 bots one thread keeps botd's rounds inside their period and four
made none shorter, so it is off unless you turn it on:

```sh
lsdctl set botlink_threads 4    # 1 (the default): botd's own thread alone; 0: half the cores the container sees, at most 4
```

(`set` restarts the server, and botd with it.)

And on the bots that are playing, with no restart:

```sh
lsdctl bots list                      # every bot: its kind, its tree, what it is doing
lsdctl bots watch [name|id]           # one bot's tree, live: where it is, and why (Ctrl-C leaves)
lsdctl bots trees                     # the trees there are; lsdctl bots tree <name> prints one
lsdctl bots check mine.bt             # every mistake of a text, with its line
lsdctl bots apply - --bot Bot12 < mine.bt    # a tree for one bot, now (--team 2, --archetype camper, --each, --all)
lsdctl bots revert --each             # every bot back to the world's tree
lsdctl bots save mine < mine.bt       # keep a text as /data/trees/mine.bt
```

(From the host: `docker exec -i lsd lsdctl bots save mine < mine.bt`.)
Writing a tree, from an empty file to one running here:
[bot/trees/README.md](../bot/trees/README.md); everything else about
them: [bot/TREES.md](../bot/TREES.md).

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
