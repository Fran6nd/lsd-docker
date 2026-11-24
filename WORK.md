# Work in hand

The list of what the owner asked for and where each item stands, kept
here so it survives a change of AI session. Whoever works on an item
updates its line and adds a dated entry to the log at the end. Details
live where they belong (bot/BRAIN-STATUS.md, bot/NAV-STATUS.md,
bot/TREES.md, tools/tree-editor/README.md); this file only says what is
open, who has it, and what was decided.

States: TODO, DOING (who), REVIEW (waiting to be checked and committed),
DONE (commit), BLOCKED (on what).

## Decisions that bind every item

- The tree decides WHAT a bot does; the engine only decides HOW. A
  decision about what to do that lives in C moves into the tree or
  becomes a setting of a word. The kinds of bot (archetypes: their trait
  weights) become data beside the trees.
- Nothing in bot/core knows a gamemode, item or script by name.
- 255 players is the default (ids 0 to 254). A client that cannot go
  past 32 goes through the one "outdated client" path: spectator, sent
  nothing a 32-player client cannot take, told to update.
- Kept: lib_bot, the hostage gamemode, guards (bot_standard.lua),
  engine_bots. Removed: battle_bots, the gamemodes bots and bots_rewards.
- Commits: one per step, no co-author trailer, only from a state the
  agent announced GREEN and frozen. Agents never run git.
- Agents run on Opus (design, engine, review) or Sonnet (narrow, well
  specified work).

## Items

| # | Item | State |
|---|---|---|
| 0 | 255 players by default; joining a server with 32+ bots works; outdated clients take the spectator path | DOING (agent) |
| 1 | This file | DONE |
| 2 | Study of tree diagrams + a visual proof of concept for the owner to choose from | DOING (agent) |
| 3 | Report: how botd is built, CPU with 30 bots, where the bottlenecks are | DOING (agent) |
| 4 | Audit: every decision about WHAT that still lives in C; plan to move each | REVIEW (brain agent): bot/DECISIONS.md; 8 numbers made word arguments |
| 5 | Archetypes as a data file beside the trees | TODO (after 4) |
| 6 | Bots look where they are heading; shot at: cover within the field of view, else face the threat, never turn the back to search | TODO (brain agent, after 4) |
| 7 | Bots stuck on a roof bridge or dig their way down (engine_bots_edit=all) | TODO (brain agent) |
| 8 | A babel tree, sent by babel_plus only when bots are added; no bots, no engine | TODO (brain agent) |
| 9 | Remove battle_bots and the gamemodes bots, bots_rewards (setup, scripts, docs, migration of servers that run them) | TODO (after 0) |
| 10 | Shooting range gamemode on a generated map: a static range (bots as targets from 5 to 50 m, standing or crouched, never dying, never moving, damage shown to the shooter; a target on a rail or one that blinks from place to place) and an IPSC course, one player at a time; all targets as fast as possible | TODO (after 9) |
| 11 | Graphical node editor in tools/tree-editor (replaces its text-first phase 2) | BLOCKED (on the owner's choice after 2) |
| 12 | Docs pass left unfinished by the tooling agent (bot/trees/README.md, TREES.md trimmed, docs/*, skills) | TODO |
| 13 | A scenario test for the sniper role (tdm, ctf) | TODO |
| 14 | Proposal to the owner: a behaviour's HOW written in Lua (a script skill a tree can `do`) | REPORTED, waiting for a yes |
| 15 | Editor backend gaps: a game list as data, a quiet roster poll, an outline for text that does not compile | TODO (with 11) |
| 16 | A release (the published image predates `lsdctl bots`; the editor refuses it) | when the owner asks |

## Log

- 2026-11-24: file created. HEAD 6a9f0c3 ("wip", the owner's commit of
  the tooling agent's unfinished docs pass). Demo: ctf, 10 bots a team,
  engine_bots_edit=all, image built from c41c01f.
- 2026-11-25 (brain agent, step A, item 4): bot/DECISIONS.md written --
  50 places in bot/core where C decides WHAT or carries a tree author's
  number, each with file:function, its kind (HOW / WHAT / NUMBER), the
  move and its risk, and the moves in priority order (1: cover in view,
  step B; 2: stranded bots, step C; 3: rest times as arguments; 4: seek
  as tree structure; ...). Done now, same defaults so no tree and no
  bench number moves: `camp [secs] [kills]`, `retreat [secs]`, `sniped
  [voxels] [secs]`, `outnumbered [radius]` (cond and score),
  `target_in_cover [secs]`, `spotted_new [secs]`, `allies_hurt_near
  <radius> [hp]`, `carry_home [voxels]`; test in skills_test. VOCAB.md
  regenerated. make -C bot test and dev/test.sh green.
