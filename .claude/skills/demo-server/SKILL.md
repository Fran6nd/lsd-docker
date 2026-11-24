---
name: demo-server
description: Set up, update, reconfigure or remove the local demo server (container lsd-demo) the owner plays on. Use when asked to "update the local instance", "refresh the demo", "put N bots in the demo", change its gamemode/map/bots, or when a change should be tried live.
---

# The local demo server

One container, `lsd-demo`, on UDP 32887, with a volume of the same name.
Never touch it for a test of your own: use another name
(`LSD_DEMO_NAME=lsd-x LSD_DEMO_PORT=32890`).

## The three scripts

```sh
dev/demo-new.sh       # build from the working tree, fresh volume: parkour on its generated course, engine bots
                      # (LSD_DEMO_GAME=tdm: tdm, random map from the web)
dev/demo-refresh.sh   # rebuild from the working tree, keep the volume (settings, maps)
dev/demo-clean.sh     # container, volume and image gone
```

`LSD_DEMO_BOTS` (20) is the bots for `demo-new.sh` (a team, in a game of
two), `LSD_DEMO_GAME` (parkour) the gamemode. The demo is unlisted,
rewards earned (not infinite). Parkour plays its one generated course;
any other game is in random-map mode (`/va` or a round's end fetches a
new map from the web).

## When the working tree is mid-change

Agents may be editing `bot/` or `catalog/`. Both scripts build from the
working tree, so a half-edited tree gives a broken demo. Build from the
last commit instead:

```sh
W=<scratchpad>/wt; rm -rf $W; git worktree prune
git worktree add -q --detach $W HEAD
rsync -a --exclude .git --exclude '*.o' lsd/ $W/lsd/     # the submodule's files
docker build -q -t lsd-docker:demo $W
git worktree remove --force $W
docker rm -f lsd-demo
docker run -d --name lsd-demo --restart unless-stopped -p 32887:32887/udp -v lsd-demo:/data lsd-docker:demo
```

## Changing it

Settings change with the container stopped or running (a `set` restarts
the server unless `--no-restart`):

```sh
docker exec lsd-demo lsdctl bots 20                      # bots a team (in all, in parkour: one team)
docker exec lsd-demo lsdctl map course                   # parkour: another course; then lsdctl map load parkour
docker exec lsd-demo lsdctl set engine_bots_team1 0      # one team its own count; -1 = the count
docker exec lsd-demo lsdctl set engine_bots_team2 1
docker exec lsd-demo lsdctl gamemode ctf --yes
docker exec lsd-demo lsdctl install <script> --yes
docker exec lsd-demo lsdctl exec 'exec advance_map()'    # next map now (random: from the web)
```

Seats are 255 by default (ids 0 to 254), bots included, and a person who
finds them all taken gets a bot's: nothing to set for more bots. A client
without Player Limit (anything but ZeroSpades, roughly) watches from
spectator, told to update. A demo made before this may still carry
`player_limit_max = 44` or so from the old `demo-new.sh`:
`lsdctl set player_limit_max 255` puts it back to the default.

## Always check after touching it

```sh
docker exec lsd-demo lsdctl status | grep -E 'server|gamemode|maps'
docker logs lsd-demo 2>&1 | grep -E 'botd: (attached|bots:|map loaded|stall)|lib_botlink|attempt to|traceback' | tail
```

Then say what is running (gamemode, bots, map) and the address:
`ipconfig getifaddr en0` gives the LAN address, port 32887. For anything
about bots misbehaving, use the `bot-live-debug` skill.
