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

cp .env.example .env        # then edit to taste (port, name, maps, ...)
./lsdctl up                 # builds the image and starts the server
./lsdctl logs -f            # watch it come up (Ctrl-C to stop watching)
```

The server is up when the logs show maps loading and masterlist
connections; it announces itself to the LSD author's masterlist and to
master.buildandshoot.com (drop entries from `masterlist_remotes` in
`config.lua`, or remove `load "masterlist"`, to stay private).

Day-to-day management goes through `lsdctl`:

```sh
./lsdctl status                      # state + published ports
./lsdctl gamemode babel              # switch gamemode (ctf, arena, babel, ...)
./lsdctl map add https://example.com/mesa.vxl ~/Downloads/pinpoint.vxl
./lsdctl map load BusanPort           # switch the live map now, no restart
./lsdctl set LSD_NAME "my server"    # any .env setting, restarts to apply
./lsdctl load rifle_is_a_rail_gun    # hot-reload a script, no restart
./lsdctl console                     # in-game admin console (Ctrl-C leaves)
./lsdctl update                      # pull upstream source + rebuild
```

Everything an operator touches lives outside the image, so no rebuild
is ever needed for content changes:

| what | where | applied |
|---|---|---|
| settings (port, name, gamemode, map queue) | `.env` | on restart |
| full config | `config.lua` | on restart |
| maps (`.vxl`) | `maps/` | next rotation |
| custom/override scripts & gamemodes | `scripts.local/` | `./lsdctl load [module...]` (hot, no restart) or on restart |

- **Port**: `LSD_PORT` changes the container *and* published port
  together — they must match because the masterlist advertises the
  bound port.
- **Scripts**: at startup the container overlays `scripts.local/` on
  the upstream scripts; a file with the same name as an upstream script
  replaces it, new files (e.g. a custom gamemode you then select with
  `./lsdctl gamemode mymode`) are added. The `lsd/` submodule is never
  modified.
- **Persistent data** (bans/auth databases): named volume `lsd-rw`.
- **Admin console**: `sock_console` on `rw/console.sock`
  (stdio_console is disabled in containers — it wedges the event loop
  without a real terminal).

## Update (nightly)

`./lsdctl update` (or `update.sh` directly) bumps the `lsd` submodule
to upstream master, rebuilds the image and restarts the container only
if something changed. Cron:

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

- Router: forward **UDP 32887** (external) → the docker host, same
  port. That is the only port the server needs.
- DNS: `lsd-dev.fran6nd.online` A record → the box's public IPv4.
- Host firewall: Docker-published ports bypass ufw; no rule needed.
- Nothing else on the host may be bound to the same UDP port.
