---
name: bot-behaviour
description: Add or change what the engine's bots do - a new skill, condition or score, a gamemode's behaviour tree, an inventory item or server script that brings its own bot behaviour, a setting the server sends. Use when asked for a new bot behaviour, to "make bots work for <gamemode>", or to make bots use something.
---

# Giving bots a behaviour

Read `bot/README.md` first (the layers, and "A gamemode's part, and
nothing more"), then `bot/BRAIN-STATUS.md` (what exists, the settings
keys, the open list). The rule that shapes everything: **nothing in
`bot/core/` or `bot/botd/` may know a gamemode, an item or a server
script by name.** What differs is data sent over the link.

## Where a change goes

| You want | It goes in |
|---|---|
| A gamemode's bots to play its rules | a tree, `bot/trees/<gamemode>.bt` (text; `bot/trees/README.md` teaches it step by step, `bot/TREES.md` is the reference). The server names the tree after the gamemode; an unknown name runs `default.bt`. A gamemode's Lua can send its own: `botlink_set("tree", text)`. |
| Something ONE gamemode or script needs the bots to know, go to, or trigger | FIRST see whether the bridge does it, with no C at all (TREES.md section 13, items 8 to 10): a **fact** the script sets and a tree reads (`botlink_set("fact.alarm", 1)`, `if fact alarm`, `option none fact alarm`), a **place** of the script's naming (`botlink_set("place.church", "x y z")` or `"pid <n>"`, written `@church` in a tree), a **word** a tree says back to a Lua function (`do tell ring_bell`, `botlink_on("ring_bell", fn)`). Worked example: engine_test.c "a village". |
| A new thing bots can do, or can ask about the world (for every mode: a way of moving, sensing, fighting) | a NEUTRAL word in the vocabulary: implement in `bot/core/skill_*.c` / `senses.c`, add it to the table in `vocab.c` WITH ITS ARGUMENTS AS DATA (the macros above the table: name, type, required, default -- the compiler checks trees against them and the docs are written from them). Named for what it does (`enemy_near`), never for who uses it. A NUMBER the bot senses (a distance, a count, an age) is a VALUE, in vocab.c's `VALUES` table (its unit and range as data, unknown when there is none): trees compare it (`if enemy_distance < 5`), so no threshold condition is needed; a condition or a 0/1 score that only compares one is written as SHORT FOR the comparison (the table's last column, `"health < $1"`), never as a second function reading the same thing. Then `make -C bot doc` (VOCAB.md) and use it in trees. |
| Bots to use an inventory item | the ITEM says when: `inventory_define(key, {..., bot = {tree = "<fragment>", guide = <secs>}})` (catalog/tools/inventory). Rewards do it per menu entry (`bot = "seq\n\tif health_below 50\n\tdo use medkit self"`). The engine gathers the fragments into the generated tree `items`; a gamemode tree includes it with `tree items`. |
| A server script (night, weather...) to change how bots behave | it sends a fragment as `botlink_set("extra.<name>.tree", text)` (ticked beside the main tree at every decision: `tree extras`) and settings for mechanics that are off by default (`night.sight=1`, `night.cone=...`). Example: catalog/extensions/night/lib_night.lua, the BOTS section. |
| The server to tell bots a fact | a setting through `botlink_set(key, value [, pid])` in catalog/libs/botlink/lib_botlink.lua (re-sent to an engine that attaches late). Existing: `tree`, `water`, `water.damage`, `night_vision`, `item.<name>`. New keys must be handled in `bot/core/engine.c` (an unknown key is logged once and kept for `if setting`). |
| Something new to cross the link (not a setting) | `bot/link/botlink.h` (the one contract: layout checks in botlink.c and both link tests must follow). Prefer a setting. |
| How many bots, on which team | catalog/bots/engine_bots (`engine_bots_count`, `_team1`, `_team2`, level and spread). |
| The setup to offer bots for a game | `GAMES` in image/ctl/lsdctl.lua: `bots = true` on the game (only once it has a tree). |

Character: a tree's `pick` options name a trait (bot/core/persona.h:
aggression, caution, objective, teamwork, builder, marksman, flank,
stealth, curiosity, greed); each bot's weights are rolled around an
archetype (the table in persona.c is the place to tune). A pick's chosen
option that fails at once fails the pick: every option's score must be 0
when its action cannot be done.

## The rules of `bot/core/`

C11, `-Wall -Wextra -Werror -pedantic`; no I/O, no clock, no threads, no
globals, nothing allocated per think; time and randomness come in as
arguments (same seed, same inputs = same bot); a long search is given a
budget and resumed; the header is the documentation and carries the why.

## Always

1. A test in simulation that fails without the change:
   `bot/tests/senses_test.c`, `skills_test.c`, `engine_test.c` (the
   simulated server is `brain_sim.h`); for a tree, a scenario where the
   team visibly does it, plus the 6 v 6 / 20 v 20 "stuck 0, nobody idle"
   and the replay-determinism checks still passing.
2. `make -C bot test` green, and once on Linux:
   `docker run --rm -v "$PWD":/w:ro -w /w/bot alpine:3 sh -c 'apk add --no-cache build-base >/dev/null && make B=/tmp/b test'`
3. Server side changed too? `luajit tests/botlink_test.lua`, `dev/test.sh`.
4. Update `bot/BRAIN-STATUS.md` (vocabulary added, keys, open list).
5. Try it live: the `demo-server` skill, then `bot-live-debug` to see
   that the bots really do it. Simulation passing is not the same thing:
   say which of the two you actually checked.

## Looking at a tree

`make -C bot tools`, then `bot/build/bin/bttree bot/trees/tdm.bt` draws the
tree with every `tree <name>` opened in place (`--as camper`
shows that kind of bot's weight beside each weighed choice, `--tree NAME` one tree,
`--plain` for a pipe). `bttree --check bot/trees/*.bt` compiles them with
the real vocabulary and names the faulty line; `make -C bot test` runs it.
`bttree --words` lists every condition, score, action and trait
(`bot/VOCAB.md` is the same as a page, with each word's arguments). On a
running server: `lsdctl bots list`, `lsdctl bots watch <bot>`, `lsdctl
bots apply` (the `bot-live-debug` skill).


After any change to the words (bot/core/vocab.c) or to persona centres, run `make -C bot doc`: it regenerates bot/VOCAB.md, and `make -C bot test` fails while that file is stale.
