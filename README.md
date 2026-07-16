# lsd-docker

Dockerized deployment of the [LSD](https://66.135.15.57/lsd/) Ace of
Spades server for **lsd-dev.fran6nd.online**. The server source is the
pristine `lsd/` git submodule; this project adds packaging only.

The image compiles everything itself (Alpine/musl, matching the seccomp
sandbox in `src/sandbox.c`), including the native Lua modules the stock
scripts need: lsqlite3, luasodium, linenoise, stb_image, lfs.

## Run

```sh
cp .env.example .env        # then edit to taste
./lsdctl up
./lsdctl logs -f
```

Day-to-day management goes through `lsdctl`:

```sh
./lsdctl status                      # state + published ports
./lsdctl gamemode babel              # switch gamemode (ctf, arena, babel, ...)
./lsdctl map add https://example.com/mesa.vxl ~/Downloads/pinpoint.vxl
./lsdctl set LSD_NAME "my server"    # any .env setting, restarts to apply
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
| custom/override scripts & gamemodes | `scripts.local/` | on restart |

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

## Network checklist

- Router: forward **UDP 32887** (external) → the docker host, same
  port. That is the only port the server needs.
- DNS: `lsd-dev.fran6nd.online` A record → the box's public IPv4.
- Host firewall: Docker-published ports bypass ufw; no rule needed.
- The old native systemd unit must stay off or it fights for the port:
  `sudo systemctl disable --now lsd`.
