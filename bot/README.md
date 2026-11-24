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

## A gamemode's part, and nothing more

Nothing in `core/` or `botd/` may know a gamemode by name. What differs
from one mode to the next is data, and comes over the link:

- **A tree** (`bt.h`), as text. The built-in ones are files in
  `trees/` (`tdm.bt` first), one per mode; an operator adds or replaces
  one with a file in the data volume's `trees/`; a gamemode's Lua can
  send its own (`botlink_set("tree", text)`), for every bot or for one
  (a boss, a villager); a mode that sends none gets `default.bt`. A tree
  is made only of the neutral vocabulary below.
  **[TREES.md](TREES.md) is the reference**: every keyword with its exact
  meaning and defaults, how a text is compiled and run, how to write and
  tune one, and the JSON an editor or a debugger reads. [VOCAB.md](VOCAB.md)
  lists the words (`make doc` writes it; `make test` fails when it is
  stale).
  To look at a tree, `make tools` then `build/bin/bttree trees/tdm.bt`:
  drawn with its sub-trees opened in place, compiled first by the
  engine's own compiler. `--as camper` shows beside each weighed choice
  what that kind of bot's weight is, `--tree NAME` draws one, `--check`
  only says what is wrong, `--words` lists the vocabulary, `--split
  word=value...` rolls 700 bots and counts what each would do in the
  situation given (`--why`: what each option was worth), `--trace` shows
  one bot's tree as the engine holds it, with what is RUNNING and why
  each pick chose; `--json`, `--from-json` and `--schema` are for an
  editor. On a running server, `lsdctl bots list`, `lsdctl bots watch
  <bot>` (what one is thinking, live) and `lsdctl bots apply` (a tree
  for one bot, many or all, without a restart) -- TREES.md, sections 14
  and 16. It is in the image too: `docker exec <server> bttree
  /opt/botd/trees/tdm.bt`.
- **Settings**, `key=value` (`BL_EV_SET`): what the mode's objects mean
  (`intel=fetch`, `tents=defend`...), zones where editing is refused,
  the archetype mix, how many blocks a bot may spend.
- **Orders**, for one bot (`BL_EV_ORDER`), when a mode wants to direct it.

**The vocabulary** -- the conditions, scores and actions a tree may name
-- is the engine's whole interface to behaviour, so it is kept small,
named for what it does and not for who uses it (`enemy_near`, never
`tdm_enemy_near`), and documented in one place (`core/vocab.h`). A new
mode that needs a new word adds it there, neutral, with a test; it does
not add an `if (mode == ...)` anywhere.

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
