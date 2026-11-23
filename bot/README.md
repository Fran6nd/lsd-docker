# The bot engine

Bots that live in the instance. A bot is a player slot of the server's
with no connection behind it; what it does is decided by `botd`, a
second process in the container, through one memory-mapped file
(`link/botlink.h`). No ENet, no socket, no client.

```
LSd (sandboxed, one thread, 60 ticks a second)        botd (its own process and cores)
  lib_botlink.lua --- libbotlink.so                     host: clock, workers, the file
        |  world, events  ->                                 |
        |  <- intents, actions                          core: the brain, a library
  bots are peerless players (lib_bot)
```

## The layers of a bot (`core/`)

Each layer only knows the one below it.

| layer | files | what it is | where it comes from |
|---|---|---|---|
| decision | `bt.*`, `persona.*`, `trees/` | a behaviour tree per gamemode; its choices are weighted, and the weights are each bot's own | new |
| senses | `senses.*` | what this bot knows: seen, heard, remembered. Night and noise live here | new, on aosbot's ranges |
| skills | `skill_*.c` | the things a tree's leaves do: go there, fight him, dig, build, climb, throw, use an item | aosbot's executor, ported |
| mechanics | `map.*`, `nav.*`, `aim.*`, `cull.*`, `body.*` | the map as bit columns, the route planner (walk, jump, dig, bridge, stairs), human aim, physics | aosbot, ported; physics is LSd's own `demoncore.c` |

**Not a blind port.** aosbot's mechanics were tuned against real servers
and are kept, behaviour for behaviour, with its harness cases as their
tests. Its decisions -- utility-scored roles chosen in C++ -- are not
ported: decisions are trees here, written as text, so a gamemode's Lua
can bring its own.

## Rules for every file in `core/`

- C11, `-Wall -Wextra -Werror -pedantic`. No compiler extensions.
- **No I/O, no clock, no threads, no globals.** Time comes in as an
  argument, randomness from a `bc_rng` the caller owns (`rng.h`): the
  same seed and the same inputs are the same bot, which is what makes a
  behaviour testable. Logging goes through a callback the host gives.
- The caller owns memory: a module is given its state, or told how much
  to allocate once. Nothing allocates per tick.
- Names: `bc_` for the core, `bt_` for the tree runtime, `bl_` for the
  link. One header per module, and the header is the documentation:
  what, why, and what was learned (aosbot's `docs/internals` are the
  source for the why -- carry the reasons over with the code).
- A search that can be long is resumable: it is given a budget and
  returns "not done yet", never blocks a tick (aosbot used threads as
  coroutines for this; here the search keeps its own state).
- Every module has a test in `tests/` that runs with no server. A ported
  module's test replays cases recorded from aosbot (same inputs, same
  outputs); a new module's test is written with it.

## The host (`botd/`)

Maps the file, loads the map the server names, keeps one brain per bot,
ticks them at the server's rate, writes their intents. It is the only
place with a clock, threads, files or logs.
