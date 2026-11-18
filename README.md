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
architecture; see [Developing](docs/developing.md).

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

## Quick LAN game

A game for friends on your network, gone when it is over: no server to
install, nothing left behind.

```sh
curl -fsSL https://raw.githubusercontent.com/Fran6nd/lsd-docker/master/play.sh | sh
```

```powershell
irm https://raw.githubusercontent.com/Fran6nd/lsd-docker/master/play.ps1 | iex
```

It asks for the game (ctf or babel) and the map (random, or a link or id
from [aos.party](https://aos.party)), then prints the `aos://` address to
join. A minute after the last player leaves it stops, and the container,
its data and -- if the game downloaded it -- the image are removed.
Ctrl-C stops it at once. Answers can be given ahead:
`curl ... | sh -s -- babel random`. Without the scripts, the same game is
`docker run --rm -it -p 32887:32887/udp ghcr.io/fran6nd/lsd-docker play`.

## Documentation

- [Administering a server](docs/administer.md) -- `lsdctl`, settings,
  maps (find them on [aos.party](https://aos.party)), updates
- [The catalog](docs/catalog.md) -- gamemodes, extensions, effects,
  bots, tools; writing your own scripts, and keeping them across updates
- [Building maps](docs/building-maps.md) -- the editor gamemode
- [Translations](docs/translations.md) -- every player in their language
- [Developing](docs/developing.md) -- building, testing, releasing

## License

AGPL-3.0-or-later; see [LICENSE](LICENSE).
