---
name: bot-engine-work
description: Plan and run larger work on the bot engine (bot/) with subagents - navigation fixes, a brain pass, a new subsystem. Use when a bot change is too big for one edit, or when resuming engine work in a new session.
---

# Working on the bot engine

## Start here

- `bot/README.md` -- the design and the binding rules.
- `bot/BRAIN-STATUS.md`, `bot/NAV-STATUS.md` -- the handover documents:
  what exists, measured numbers, the open list in order with the command
  that reproduces each item, traps. They are kept true by whoever works
  on that part; read them before believing a bug is new, update them
  before stopping.
- `docs/developing.md`, "Bots" -- who starts what, where files live in
  the image.

## The pieces and who owns which files

| Part | Files |
|---|---|
| The link (contract) | `bot/link/botlink.{h,c}`, `bot/tests/link_*` |
| Server side | `catalog/libs/botlink/`, `catalog/bots/engine_bots/`, `tests/botlink_test.lua` |
| Host | `bot/botd/`, `bot/tests/botd_test.c`, Dockerfile, `image/entrypoint.sh` (bot_helper) |
| Navigation | `bot/core/{map,body,cull,lsd_core,nav*}.*`, `bot/tests/{map,body,nav,cull_parity}_test.c`, `nav_sim.h` |
| Decision runtime | `bot/core/{bt,persona,rng}.*` and their tests |
| Aim | `bot/core/aim.*` |
| Brain | `bot/core/{engine.c,brain.h,senses.*,skill_*.c,skills.h,vocab.*}`, `bot/trees/`, `bot/tests/{brain_sim.h,senses,skills,engine}_test.c` |

One agent per part at a time, told exactly which files are its own and
that everything else is read-only; headers others build on (`nav.h`,
`map.h`, `body.h`, `engine.h`, `bt.h`, `botlink.h`) get additions only.
Agents do not run git: the main session reviews, runs the tests in
place, and commits each part's files by name.

## How to brief an agent

Give it: the files to read first (above), its files, the owner's request
in the owner's words, what "done" is as tests that fail before and pass
after, the numbers to report (soak arrival/stuck/lost, think cost), and
"do not weaken or delete a check: skip it with a printed KNOWN LIMIT".
Ask for a CHECKPOINT (green build, status file updated, short report) at
the first coherent state, so it can be committed and tried live while
the agent goes on. If an agent is cut off, its work is on disk: check the
build (it may be mid-edit), then resume the same agent with SendMessage
rather than starting a new one.

## Verify before committing

```sh
make -C bot test                       # every suite, no warnings
luajit bot/tests/link_ffi_test.lua     # the link from LuaJIT (needs `make -C bot` first)
dev/test.sh                            # the catalog side
dev/smoke.sh                           # the image, when Dockerfile/entrypoint/lsdctl changed
```

Then live (the `demo-server` skill), building from a clean worktree of
the commit if other agents still have the tree half-changed.

## Facts that cost time to learn

- The server's sandbox (x86) forbids starting a process or a thread:
  anything outside the tick is the entrypoint's or botd's, and the two
  sides talk through the mapped file, never a socket.
- Physics is the server's own `lsd/src/demoncore.c`, compiled into the
  engine; collapse is `libpvx2`'s cull, and the parity test compares
  against the real code. Do not rewrite either.
- A jump pressed while the server's `airborne` flag flickers after a
  landing is dropped; changing crouch in the air lifts the body; walking
  does not climb out of water (it needs a jump).
- The engine thinks at the host's rate but the world arrives 30 times a
  second, and block collapses are computed by the engine itself (the
  server tells nobody).
- LSd is a submodule kept pristine: C changes go in `patches/lsd/`.
