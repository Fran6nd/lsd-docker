# Administering a server

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

lsdctl restart                       # warns players; the container stays up
lsdctl say "back in five"
lsdctl console                       # the in-game admin console
```

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
fails. Parkour takes none of them: choosing it generates its course
(`parkour.vxl`) and makes that the whole rotation; `lsdctl map course
[seed]` generates another. A source says how to list its maps in its own entry
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
