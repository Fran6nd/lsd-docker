# lsd-docker

Dockerized deployment of the [LSD](https://66.135.15.57/lsd/) Ace of
Spades server for **lsd-dev.fran6nd.online**. The server source is the
pristine `lsd/` git submodule; this project adds packaging only.

The image compiles everything itself (Alpine/musl, matching the seccomp
sandbox in `src/sandbox.c`), including the native Lua modules the stock
scripts need: lsqlite3, luasodium, linenoise, stb_image, lfs.

## Setup

Requires Docker with the compose plugin. The server source is a git
submodule, so clone with `--recurse-submodules` (or init it after the
fact — an empty `lsd/` is the usual cause of a failing build):

```sh
git clone --recurse-submodules git@github.com:Fran6nd/lsd-docker.git
cd lsd-docker
# if already cloned without submodules:
git submodule update --init --recursive

./lsdctl hostage up            # builds the image and starts the instance
./lsdctl hostage logs -f       # watch it come up (Ctrl-C to stop watching)
```

The server runs as one or more named **instances**. Each instance is the
pair `instances/<name>.env` + `instances/<name>.config.lua`, run as its
own compose project (`lsd-<name>`) off the shared image and
`docker-compose.yml`. Instances have their own port, config, and data
volume, so they start and stop independently. This repo ships one
instance, `hostage`. Add more with `./lsdctl new <name>`:

```sh
./lsdctl ls                    # list instances (port, gamemode, state)
./lsdctl new arena -p 32888    # scaffold instances/arena.{env,config.lua}
# edit instances/arena.config.lua to taste, then:
./lsdctl arena up
./lsdctl rm arena              # stop and delete an instance
```

The server is up when the logs show maps loading and masterlist
connections; it announces itself to the LSD author's masterlist and to
master.buildandshoot.com. `./lsdctl <name> masterlist off` takes it off
those lists — live, without disconnecting anyone — and remembers the
choice. Being unlisted is not access control: anyone who knows the
`ip:port` can still join.

Day-to-day management goes through `lsdctl`. Per-instance commands take
the instance name first (`lsdctl <name> <command>`):

```sh
./lsdctl hostage status                      # state + published ports
./lsdctl hostage gamemode babel              # switch gamemode (ctf, arena, babel, ...)
./lsdctl hostage map add https://example.com/mesa.vxl ~/Downloads/pinpoint.vxl
./lsdctl hostage map load BusanPort          # switch the live map now, no restart
./lsdctl hostage set LSD_NAME "my server"    # any .env setting, restarts to apply
./lsdctl hostage load rifle_is_a_rail_gun    # hot-reload a script, no restart
./lsdctl hostage masterlist off              # unlist the server, live
./lsdctl hostage dev off                     # run released scripts only
./lsdctl promote world_editor                # scripts.dev/ -> scripts.local/
./lsdctl hostage console                     # in-game admin console (Ctrl-C leaves)
./lsdctl update                              # rebuild + restart every instance
```

Every per-instance command has an `All` twin that fans it out over all
instances (`<command>All`, or `all <command>`):

```sh
./lsdctl restartAll                          # restart every instance
./lsdctl reloadAll                           # warn + reload scripts everywhere
./lsdctl loadAll rifle_is_a_rail_gun         # hot-reload a script on all
./lsdctl statusAll                           # state of every instance
./lsdctl all set LSD_MAPS "hallway pinpoint" # any command works: upAll, logsAll, ...
```

Each instance owns its maps in `instances/<name>.map/`, created and
seeded when you `lsdctl new` it — editing a map on one server never
touches what another is playing.

**The folder is the rotation.** Drop a `.vxl` in and it plays; delete it
and it stops. Nothing to keep in step by hand:

```sh
./lsdctl spicyctf map add ~/maps/mesa.vxl   # in rotation from the next restart
./lsdctl spicyctf map list                  # what is installed, and what rotates
```

Set `LSD_MAPS` in the instance's `.env` only when the *order* matters or
you want a subset — it then wins over the folder, and `map list` marks
which installed maps are actually played and warns about queue entries
with no `.vxl` behind them. Custom scripts are still a shared pool.
Both are overridable per instance via `LSD_MAPS_DIR` / `LSD_SCRIPTS_DIR` /
`LSD_DEV_SCRIPTS_DIR` in its `.env`. Whatever the host path, the
container always sees its maps at `/lsd/maps`.

## Released vs in-development scripts

Custom scripts live in two committed trees:

| tree | holds | who runs it |
|---|---|---|
| `scripts.local/` | released, known-good scripts | every instance |
| `scripts.dev/` | work in progress | instances with `LSD_SCRIPTS_DEV=1` (the default) |

They are overlay layers, stacked upstream → `scripts.local/` →
`scripts.dev/`, and the last copy of a filename wins. So a
`scripts.dev/world_editor.lua` shadows the released
`scripts.local/world_editor.lua` on dev instances while the instances
with `./lsdctl <name> dev off` keep running the released one — same
image, same maps, different scripts.

```sh
./lsdctl hostage dev            # which layer this instance runs
./lsdctl hostage dev off        # released scripts only (reassembles + reloads)
./lsdctl hostage load hostage   # says when a module comes from scripts.dev/
./lsdctl promote hostage        # graduate it: scripts.dev/ -> scripts.local/
```

`promote` moves the module's `.lua` and its companion directory (e.g.
`world_editor/`) together, with `git mv` when they are tracked.
Toggling `dev` is a scripts-only change: modules reload, nobody is
disconnected.

Everything an operator touches lives outside the image, so no rebuild
is ever needed for content changes:

| what | where | applied |
|---|---|---|
| settings (port, name, gamemode, map queue) | `instances/<name>.env` | on restart |
| full config | `instances/<name>.config.lua` | on restart |
| maps (`.vxl`) | `instances/<name>.map/` (per instance) | next rotation |
| map rotation | the folder itself — or `LSD_MAPS` to pin it | next rotation |
| released custom/override scripts & gamemodes | `scripts.local/` (shared) | `./lsdctl <name> load [module...]` (hot, no restart) or on restart |
| in-development scripts | `scripts.dev/` (shared) | same, on instances with the dev layer on |
| public listing | `LSD_MASTERLIST` in `instances/<name>.env` | `./lsdctl <name> masterlist on\|off` (hot) |

`./lsdctl new` stamps a new instance out of `templates/`:

| template | becomes |
|---|---|
| `templates/config.lua` | `instances/<name>.config.lua` |
| `templates/instance.env` | `instances/<name>.env` (`@PLACEHOLDERS@` filled in, `#T#` lines dropped) |
| — | `instances/<name>.map/`, seeded from an existing instance |

Neither template is loaded by any instance: they are copied once, and the
copy is then that server's own to edit. Keep them neutral — anything
specific to one server belongs in that server's copy, or every server
created afterwards inherits it.

- **Port**: `LSD_PORT` changes the container *and* published port
  together — they must match because the masterlist advertises the
  bound port. Each instance needs a distinct port; `lsdctl new` and
  `lsdctl <name> set LSD_PORT` refuse a port another instance already uses.
- **Scripts**: at startup the container overlays `scripts.local/` and
  then `scripts.dev/` on the upstream scripts; a file with the same name
  as an upstream script replaces it, new files (e.g. a custom gamemode
  you then select with `./lsdctl <name> gamemode mymode`) are added. The
  `lsd/` submodule is never modified.
- **Settings drift**: an instance's `.env` is the source of truth, but a
  running container keeps the values it was created with. `masterlist`
  and `dev` apply their change live *and* record it; `reload` notices
  when the two disagree and recreates the container instead of
  restarting it in place, so a hot change is never silently reverted.
- **Persistent data** (bans/auth databases): a per-instance named volume,
  `lsd-<name>-rw` (the migrated `hostage` instance keeps the legacy
  `lsd-rw`).
- **Admin console**: `sock_console` on `rw/console.sock` inside each
  instance's container (stdio_console is disabled in containers — it
  wedges the event loop without a real terminal).

## Update (nightly)

`./lsdctl update` (or `update.sh` directly) bumps the `lsd` submodule
to upstream master, rebuilds the shared image and recreates every
instance (each picks up the rebuilt image on recreate). Cron:

```
0 3 * * * /path/to/lsd-docker/update.sh >> /var/log/lsd-update.log 2>&1
```

## AI policy

This repository is deployment packaging, not the server itself (the
`lsd/` submodule is upstream's work and stays pristine). AI-assisted
contributions are acceptable here, but only if they are small and a
human can fully review and maintain them: a Dockerfile tweak, a script
fix, a doc update. Anything a maintainer couldn't rewrite from scratch
after reading it doesn't belong in this repo.

## License

Copyright (C) 2026 Fran6nd.

The files original to this repository — the packaging, `lsdctl`, the
Docker setup, and the custom scripts under `scripts.local/` — are free
software licensed under the **GNU Affero General Public License, version
3 or (at your option) any later version** (AGPL-3.0-or-later). The full
text is in [LICENSE](LICENSE).

Because the AGPL covers use over a network, **anyone who runs a modified
version of this software — including operating a modified server that
players connect to — must make the complete corresponding source of
their modifications available to those users under the same license.**
Distributing modified copies carries the same obligation.

The bundled `lsd/` git submodule is upstream's work, kept pristine and
distributed under its own license; it is not covered by this notice.

## Network checklist

- Router: forward the **UDP port of each instance** (external) → the
  docker host, same port (e.g. 32887 for `hostage`). That is the only
  port each server needs.
- DNS: `lsd-dev.fran6nd.online` A record → the box's public IPv4.
- Host firewall: Docker-published ports bypass ufw; no rule needed.
- Nothing else on the host may be bound to the same UDP port.
