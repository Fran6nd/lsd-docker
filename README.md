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
master.buildandshoot.com (drop entries from `masterlist_remotes` in
`config.lua`, or remove `load "masterlist"`, to stay private).

Day-to-day management goes through `lsdctl`. Per-instance commands take
the instance name first (`lsdctl <name> <command>`):

```sh
./lsdctl hostage status                      # state + published ports
./lsdctl hostage gamemode babel              # switch gamemode (ctf, arena, babel, ...)
./lsdctl hostage map add https://example.com/mesa.vxl ~/Downloads/pinpoint.vxl
./lsdctl hostage map load BusanPort          # switch the live map now, no restart
./lsdctl hostage set LSD_NAME "my server"    # any .env setting, restarts to apply
./lsdctl hostage load rifle_is_a_rail_gun    # hot-reload a script, no restart
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

Maps (`maps/`) and custom scripts (`scripts.local/`) are a shared pool
by default; an instance can point at its own via `LSD_MAPS_DIR` /
`LSD_SCRIPTS_DIR` in its `.env`.

Everything an operator touches lives outside the image, so no rebuild
is ever needed for content changes:

| what | where | applied |
|---|---|---|
| settings (port, name, gamemode, map queue) | `instances/<name>.env` | on restart |
| full config | `instances/<name>.config.lua` | on restart |
| maps (`.vxl`) | `maps/` (shared) | next rotation |
| custom/override scripts & gamemodes | `scripts.local/` (shared) | `./lsdctl <name> load [module...]` (hot, no restart) or on restart |

The top-level `config.lua` is the template `./lsdctl new` copies for a
new instance; it is not itself loaded by any instance.

- **Port**: `LSD_PORT` changes the container *and* published port
  together — they must match because the masterlist advertises the
  bound port. Each instance needs a distinct port; `lsdctl new` and
  `lsdctl <name> set LSD_PORT` refuse a port another instance already uses.
- **Scripts**: at startup the container overlays `scripts.local/` on
  the upstream scripts; a file with the same name as an upstream script
  replaces it, new files (e.g. a custom gamemode you then select with
  `./lsdctl <name> gamemode mymode`) are added. The `lsd/` submodule is
  never modified.
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

## Network checklist

- Router: forward the **UDP port of each instance** (external) → the
  docker host, same port (e.g. 32887 for `hostage`). That is the only
  port each server needs.
- DNS: `lsd-dev.fran6nd.online` A record → the box's public IPv4.
- Host firewall: Docker-published ports bypass ufw; no rule needed.
- Nothing else on the host may be bound to the same UDP port.
