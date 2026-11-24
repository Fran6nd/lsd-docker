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
| 0 | 255 players by default; joining a server with 32+ bots works; outdated clients take the spectator path | REVIEW (Lua only, no C; tests green, live run on lsd-limit) |
| 1 | This file | DONE |
| 2 | Study of tree diagrams + a visual proof of concept for the owner to choose from | DOING (agent) |
| 3 | Report: how botd is built, CPU with 30 bots, where the bottlenecks are | DOING (agent) |
| 4 | Audit: every decision about WHAT that still lives in C; plan to move each | REVIEW (brain agent): bot/DECISIONS.md; 8 numbers made word arguments |
| 5 | Archetypes as a data file beside the trees | TODO (after 4) |
| 6 | Bots look where they are heading; shot at: cover within the field of view, else face the threat, never turn the back to search | REVIEW (brain agent): heading-first head, cover in view; bench re-baselined in BRAIN-STATUS.md |
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
| 17 | Hostage gamemode: the hostages as engine bots with a tree of their own (botlink_add with a tree), falling back to today's lib_bot hostages with no engine; guards kept | TODO (brain agent, after 8) |

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
- 2026-11-25 (limit agent, item 0): cause -- player_limit_max defaulted
  to 32 and bots take ids like people, so 32 bots held ids 0-31 and the
  core's assign_new_pid answered 255: "server full" (disconnect reason
  4) for every client, ZeroSpades or not. Now: player_limit_max 255 by
  default (ids 0-254, bots included; an operator may lower it); a person
  who finds every seat taken gets a bot's (lib_bot, engine bots first);
  engine_bots says once in the log when it is short of seats. Above 32
  seats a client without Player Limit takes the one outdated path
  (lib_ext_policy, required -- a `floor` lib_player_limit registers, so
  no policy can let it play): spectator, told every 15 s it is outdated
  and to install ZeroSpades, and sent nothing that names another player
  (the old "low" class is gone; only itself, as 1 above 31, the map and
  system chat). One clock for both: from the end of the map, 10 s.
  lsdctl init moves a 32 or 254 written under an old setup question to
  255 (and policy applied -> required); a chosen number is kept.
  demo-new.sh and the tree editor no longer set player_limit_max.
- 2026-11-25 (brain agent, item 6, checkpoint): the travelling head is ON
  THE HEADING (the follower's facing, turned to as a head turns, no
  reaction delay at each corner; glances every 4.5-9 s, short; investigate
  and a lost man looked at only while the place is in sight). Bench, share
  of travelling time (nobody in sight, not shot at for 3 s) with the head
  within 30 degrees of the way the body goes, before -> after: arena12 35
  -> 71, arena32 22 -> 55, arena40 33 -> 48, fight6 44 -> 78, fight20 43
  -> 70, sea40 72 -> 90, ctf10 47 -> 77 %; spells over 1 s with the head
  over 60 degrees off, ctf10: 388 -> 45. Shot at: `cover_in_view` (cond,
  score) and `take_cover [any|in_view] [steps] [degrees]`; take_cover moves
  with the head on the threat and turns to it before setting off; the
  under-fire branches of tdm/ctf/default say "cover in view: take it;
  else crouch facing him". Scenarios in behaviour_test. Item 17 added
  (hostages as engine bots, owner's request).
- 2026-11-25 (brain agent, item 6 done): the in-view cover flood skips
  cells 30 degrees beyond the cone (cover cells looked at: +40% over the
  old any-direction search in arena12; most of the think rise is the
  planner's, routes to where bots now stand and fight, not the cover
  search). Walked up on from behind (10 voxels, 20 s): a sneaker is found
  by 8 of 12 bots in 9 s on average (glances only); a sprinter by 12 of 12
  at once -- a sprinter's footsteps are now heard at 12 (a walker's 8).
  BRAIN-STATUS.md's bench table re-run in full (every scene and four real
  maps). DECISIONS.md row 7 (retreat's second cover finder) left open.
- 2026-11-25 (limit agent, item 0 fix after the CI smoke failure of
  2026.11.25.1): with 255 seats the core's get_anon_pid answered 255
  (the slot just past the seats), which every Lua call taking a player
  id refuses -- map_layout's set_block_color(get_anon_pid()) made the
  editor's first door fail ("plid is invalid (255)"), so no layout was
  saved. lib_player_limit now hooks get_anon_pid: above the core's
  answer, the highest free seat. lib_bot keeps one seat free while it
  has bots (a bot never takes the last; a person who takes it makes a
  bot give way). lib_player_limit's send hooks pass a fake pid (the
  console's 255, new_fakepid handles) down the chain untouched instead
  of iterating it to nobody. Tests for both; smoke green twice.
