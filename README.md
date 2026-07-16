# lsd-docker

Dockerized deployment of the [LSD](https://66.135.15.57/lsd/) Ace of
Spades server for **lsd-dev.fran6nd.online**. The server source is the
pristine `lsd/` git submodule; this project adds packaging only.

The image compiles everything itself (Alpine/musl, matching the seccomp
sandbox in `src/sandbox.c`), including the native Lua modules the stock
scripts need: lsqlite3, luasodium, linenoise, stb_image, lfs.

## Run

```sh
cp .env.example .env        # optional, set LSD_PORT here
docker compose up -d --build
docker compose logs -f
```

- **Port**: set `LSD_PORT` in `.env` (default 32887/udp). Container and
  published port follow together — they must match because the
  masterlist advertises the bound port.
- **Config**: edit `config.lua` here, then `docker compose restart`.
  It is mounted into the container; the submodule is never touched.
- **Scripts**: uncomment the scripts volume in `docker-compose.yml` to
  serve modified scripts from `lsd/scripts` without rebuilding.
- **Persistent data** (bans/auth databases): named volume `lsd-rw`.
- **Admin console**: `sock_console` listens on `rw/console.sock` inside
  the volume (stdio_console is disabled in containers — it wedges the
  event loop without a real terminal).

## Update (nightly)

`update.sh` bumps the `lsd` submodule to upstream master, rebuilds the
image and restarts the container only if something changed. Cron:

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
