---
name: bot-live-debug
description: Diagnose bots misbehaving on a running server (standing still, not fighting, vanished after a map change, server lag). Use when the owner reports something seen in the demo, before changing any code.
---

# Looking at live bots

Measure first; the cause is rarely where it looks. Everything below is
read-only except where said.

## 1. Is the chain up?

```sh
docker logs <c> 2>&1 | grep -E 'botd:|lib_botlink|vote_map|attempt to|traceback' | tail -30
docker exec <c> sh -c 'ls -la /dev/shm/lsd-botlink /data/rw/botlink-map-*.vxl; ps | grep -c "[b]otd"'
```

Expect `lib_botlink: link up`, `botd: attached`, `botd: map loaded` after
every map, `botd: bots: 0 -> N`, and a `botd: health:` line a minute
(rounds/s should be 60; `drops` 0). `inert` in a lib_botlink line means
the library or header was not found. No `botd: waiting/attached` at all:
the image has no botd (built without `bot/core/engine.c`).

## 2. What are the bots THINKING? (the engine's view)

```sh
docker exec <c> lsdctl bots list                 # every bot: kind, level, health, its tree, what it is doing
docker exec <c> lsdctl bots watch <name|id> --once --plain    # one frame of its tree (no --once: live, in a terminal)
docker exec <c> lsdctl bots watch <id> --once --json          # the snapshot itself (bot/TREES.md section 16): also its facts and script places
```

The frame shows the RUNNING path through the tree the engine really
holds (items and extras included), each pick's timer, and for every
option `score x weight x factor x luck x sticky = worth` with the one
held -- so "why is it doing that" is read, not guessed. `--full` draws
every node. Watching costs the bot nothing it would notice and changes
nothing it decides; it stops by itself when the viewer goes. `bots
list` showing every bot `dead` or `idle` for long is section 1's
business (no map, no link).

To try a different tree on the bots that are playing, without a restart
(a text that does not compile is refused, nothing changes):

```sh
docker exec -i <c> lsdctl bots apply - --bot <name|id> < my.bt     # --team N, --archetype K, --each, --all (the world's)
docker exec <c> lsdctl bots revert --each
```

## 2b. What are the bots doing? (server's view)

`lsdctl exec 'exec <lua>'` runs Lua in the server; `log(...)` comes back.
Useful globals: `bot_is_bot(pid)`, `is_joined`, `is_alive`, `get_position`,
`get_orientation`, `get_velocity`, `get_inputs` (keys held: 1 forward,
2 back, 4 left, 8 right, 16 jump, 32 crouch), `is_wading`, `is_airborne`,
`get_team`, `get_tentloc()`, `botlink_stats()` (actions, ac_refused,
ac_dropped, ev_dropped, errors), `botlink_alive()`, `inventory_count`.

Sample twice, some seconds apart, and compare positions: "alive, keys
down, velocity 0, same place" is a stuck bot (it happened to a whole team
spawned in water on a map with tents in the sea). Record the map
(`docker cp <c>:/data/maps/<name>.vxl <scratchpad>/maps/`) so the case
can be replayed in the simulation.

## 3. Is it the map?

`lsdctl exec 'exec advance_map()'` and sample again. A fault that goes
with the map is navigation (water, banks, a spawn that cannot reach the
enemy); one that stays is the brain or the link.

## 4. Is it the server's clock?

Unsteady updates-per-second is the tick, not the bots: probe tick gaps
with a module on `mod.xearly.before/after.tick` and LuaJIT's
`jit.profile` (see `patches/lsd/0001-steady-tick.patch` for what was
found: sleeps wake late on Docker Desktop).

## 4b. Measure it live, repeatably (and as a person)

`dev/live-babel.sh <map.vxl>` is the live end-to-end check: a server of
its own (container and volume `lsd-live-<pid>`, the first free port from
32890; built from the working tree, or `IMAGE=lsd-docker:demo` for what
the demo runs), babel on that map, `BOTS` (20) a team at `LEVEL` (10),
for `MINUTES` (10). It loads `dev/live/probe.lua` into the server (it
counts blocks placed and captures per team, and walks the map: a
column's ground, whether a body can climb from the ground to a voxel)
and samples every bot's running leaf (`lsdctl bots list`) and place. A
SCRIPTED PERSON (`dev/person/`: a real 0.75 client over ENet, claiming
Teamplay and Player Limit) joins team 1 and, case after case (`CASES`),
stands where a case says and sends `/pingmark <spot> Build stairs here`,
as the pie menu does. It prints the share of each leaf, idle
bot-samples (holding, or not moved over two samples while not
fighting), blocks a minute per team, each case's order as the engine
logged it, and checks: idle <= `IDLE_MAX`, blocks >= `BLOCKS_MIN`, each
ordered stair climbable from the ground to its top within `STAIR_SECS`,
no Lua error or engine trouble in the log. Everything it saw stays in
`OUT` (samples.txt, server.log, person-<case>.log, climb.txt). Run it
before and after a change to bots, and give both numbers.

The person alone, on any running server (its options in
`dev/person/person.c`'s header):

```sh
dev/person/run.sh <container> --name Tester --team 0 --at 200 243 29 \
    --look 207.78 242.63 2.00 --say "/pingmark 207.78 242.63 2.00 Build stairs here" --stay 60
```

`--team` is the wire's (0 is Lua's team 1); `--at` names the voxel the
feet stand on. A ping lands ON A FACE (x, y or z a whole number): a sim
test that pings a voxel's middle does not test what a client sends.
`map_rotation` is a string (`lsdctl set map_rotation <name>`): a list
there is ignored and the map folder's name order plays instead.

## 5. Reproduce before fixing

Every live bug becomes a scenario that fails first: navigation in
`bot/tests/nav_test.c` (and the soak, `BC_SOAK_MAP=...`), behaviour in
`bot/tests/engine_test.c` / `skills_test.c` on the simulated server
(`bot/tests/brain_sim.h`). The open items and the reproduction commands
live in `bot/NAV-STATUS.md` and `bot/BRAIN-STATUS.md`: read them before
assuming a bug is new.

Things that surprised us, so check them early:
- LSd's `raycast(a, b, last)`: `last = true` is the AIR voxel before the
  hit, `false` the solid one (the apidoc says the opposite); a ray that
  starts inside a solid or above the map (z < 0) finds nothing useful.
- One script erroring in its tick ends the tick for every script after
  it (a map's odd metadata once froze all bots and projectiles).
- A test stub more forgiving than the real function hides the bug: use
  the real `lib_l10n` (`tests/support/l10n_env.lua`), the server's real
  values (PID_BROADCAST, SPECTATOR = 256).
