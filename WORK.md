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
| 7 | Bots stuck on a roof bridge or dig their way down (engine_bots_edit=all) | REVIEW (brain agent): planner can bridge, stair down and dig down from a roof at scale; `stranded` for the trees |
| 8 | A babel tree, sent by babel_plus only when bots are added; no bots, no engine | TODO (brain agent) |
| 9 | Remove battle_bots and the gamemodes bots, bots_rewards (setup, scripts, docs, migration of servers that run them) | TODO (after 0) |
| 10 | Shooting range gamemode on a generated map: a static range (bots as targets from 5 to 50 m, standing or crouched, never dying, never moving, damage shown to the shooter; a target on a rail or one that blinks from place to place) and an IPSC course, one player at a time; all targets as fast as possible | TODO (after 9) |
| 11 | Graphical node editor in tools/tree-editor (replaces its text-first phase 2) | REVIEW (editor agent): diagram A/B, edits through the engine, upload to chosen bots/team/kind, who-chooses-what; real run green. No live view (owner) |
| 12 | Docs pass left unfinished by the tooling agent (bot/trees/README.md, TREES.md trimmed, docs/*, skills) | TODO |
| 13 | A scenario test for the sniper role (tdm, ctf) | TODO |
| 14 | Proposal to the owner: a behaviour's HOW written in Lua (a script skill a tree can `do`) | REPORTED, waiting for a yes |
| 15 | Editor backend gaps: a game list as data, a quiet roster poll, an outline for text that does not compile | PARTLY DONE: `lsdctl bots games`, `bttree --split --json` committed; open for botd/bt.c: a quiet roster request, a parse of a wrong text (see the 2026-11-25 log) |
| 16 | A release (the published image predates `lsdctl bots`; the editor refuses it) | when the owner asks |
| 17 | Hostage gamemode: the hostages as engine bots with a tree of their own (botlink_add with a tree), falling back to today's lib_bot hostages with no engine; guards kept | TODO (brain agent, after 8) |
| 18 | 230 bots without lag: botd sized for every seat, the planner's budget grown with the fleet, nothing built or walked for a bot on the server's send paths | REVIEW (scale agent): branch commits; numbers in BRAIN-STATUS.md (c2) |
| 19 | Structural review of the fast fixes (the owner's rule: no quick hacks, one rule in one place) | REVIEW (review agent): see the 2026-11-25 log |

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
- 2026-11-25 (editor agent, items 11 and 15): the graphical editor in
  tools/tree-editor. The owner chose A (top-down) as the main view, B
  (left to right) second, the text always beside it; then "no live mode
  for now. You can upload to a bot. this is enough": no watching, the
  upload to chosen bots, a team or a kind stays. Done: model.py (edits
  on the engine's JSON), layout.py (automatic; in A a parent of many
  leaves stacks them in a column, so ctf_duty is 300 px wide, not
  3,800), diagram.py (cards in the proof of concept's palette, light and
  dark, sub-trees read-only in place and opened by a click, priority
  lists as numbered rows, drag to move, palette from the schema),
  panel.py (properties from the schema), tuning.py (bttree --split
  --json). Every edit: --from-json, check, read back, in one docker
  call; refused whole. Backend: `bttree --split --json`, `lsdctl bots
  games --json` (the app reads which games have one team from it).
  Tests: 82 green (34 of phase 1, one changed: the Watch button is gone).
- 2026-11-25 (editor agent, items 11 and 15, final): A's first view of
  every shipped tree fits a 1440 x 900 laptop at 85-100 % (a parent of
  more than three leaves stacks them in a column; tdm 724 px wide, ctf
  724, ctf_duty and tdm_duty a column). Window size and panes, A/B and
  the colours (system, light, dark) remembered between runs; Cmd+I /
  Cmd+Shift+I insert, Backspace deletes on macOS. "Revert all" also
  gives back the trees given to single bots (`revert --each`; `--all`
  alone leaves them). Real run on Docker (tdm, 6 bots, three edits in
  0.1 s each, apply to team 1, revert, quit): nothing left, lsd-demo
  untouched. The published image 2026.11.25.2 passes the app's probe:
  the default image works as it comes. Still needed from the backend:
  (1) botd logs two lines for every roster request ("1 request ...",
  "nobody watches any more"): one a poll; the app asks every 2 s in
  front, 10 s behind -- quiet it in botd, or let `bttree --bots` reuse a
  bots.json under a second old; (2) a structure for a text that does
  not compile (bt.c stops at the first error: the diagram shows the
  last good tree); (3) `lsdctl bots` for what the app still asks bttree
  directly (--json, --from-json, --split and the one-call remake);
  (4) `revert --all --each` as one command.
- 2026-11-25 (brain agent, item 7): off the roof. Reproduced on real maps
  (Pyeongyang 19 roofs, BigPineTree 21: with edits, at the engine's cap,
  no way found from any; the search flooded the roof). nav: a heuristic
  term for a goal far below (`descent_secs`, set by the engine when edits
  are allowed): found at the cap 19/19 and 16/21 (rest within the long
  search), 1 550 / 5 000 expansions on average; bridges and stairs past
  their first block in the open; a stair DOWN hung from the step above;
  a step down digs its arrival. Brain: `stranded` (cond, score) and a
  `<mode>_stranded` branch in the three trees (fight what it sees, face a
  shot, hold and watch); a goal where it stands needs no search; perches
  need a way down. Fixed on the way: the net's jump threw strafing bots off
  roofs; walk_safe missed an edge under half the body; a flinch jump needs
  floor; no walking on toward a goal far below while planning. Edit soak:
  lost 9 -> 0. Bench: ctf:10 4 -> 11 captures (4 of 4 games); the rest as
  before or within noise of the trees' new branch.
- 2026-11-25 (brain agent): ONLY WHAT A PLAYER COULD DO (the owner's
  rule). lib_botlink refuses a bot's build unless against a face that
  faces its eye and is in clear sight, a dig unless of a voxel with a face
  open to the air it sees (LSd checks a client for neither: no reach, no
  sight); nav plans only such edits, from the middle of the floor or its
  edge (a bridge's next block); the hung stair down is gone (a stair down
  a wall stays). The simulations play the rule; none refused over every
  scenario and the soak. keidoro's sky slab: no way a player could build
  (the nearest top 20 under it) -- stranded, holds. Spawn on the slab and
  the net's step-back off edges next.
- 2026-11-25 (brain agent): the spawn on a sky slab: catalog/overrides/
  tentspawns.lua (upstream's, patched) takes the floor under a thin layer
  (3 voxels or fewer) floating more than 9 over the tent with more than 9
  of air under it -- for anybody, person or bot; tests/tentspawns_test.lua.
  The net's step back and sidestep never walk off an edge; no jumping in
  the map's top band (a run and jump across a gap of keidoro's slab fell
  short). A stranded bot's capped search is taken as no way (no bridge
  built toward nowhere, no long search) and it is shut in 30 s at a time:
  keidoro, 3 bots stranded 5 minutes with edit=all, about 27 000
  expansions a minute each (450 a second); with edits off 8 000.
- 2026-11-25 (scale agent, item 18): what the owner saw at "230 bots"
  was 64 bots and 166 standing (botd --bots 64) on a server whose Lua
  walked every player for every packet. Measured on a container of its
  own with one headless Player Limit client (a probe module on
  mod.xearly before/after tick via `lsdctl exec`: tick p50/p99/max, UPS
  min/p1/median a second, bots holding keys and moving; CPU from
  /proc/<pid>/stat; a Python pyenet client counting World Updates):
  ctf prisonbreakv1 edit=all at 230, before -> after: server 22 -> 13%
  of a core, tick p99 30 -> 4.6 ms, ticks over 25 ms 58 -> 1 a minute,
  UPS 60 throughout, botd 13.5 -> 15.6% (the bigger planner budget),
  client 60 updates a second either way (5.5 KB each, 324 kB/s). Done:
  botd at 255 (the coordinator's entrypoint commit; botd's default too;
  leaders 8 -> 52 a team; a bot with no room said so), the planner's
  budget per 40 bots (bench map230: waiting for routes 33 -> 2%),
  lib_bot's people_in with command_ups and afkick overrides,
  player_properties idle with nobody to tell. Tried and dropped: World
  Updates as unreliable fragments (worse under loss than reliable). Not
  done, next: a route board shared by a team's bots (aosbot's; the
  planner is ~90% of botd on a real map), sight shared by pairs or
  staggered for far enemies (98% of a think on a flat field), the
  world write's 12 API calls a player.
- 2026-11-25 (brain agent): a stranded bot makes its height a vantage
  (the owner: "bots stuck here should at least try to bridge to camp
  other enemies' spawn"): `build_perch [place]` (a level walkway toward the
  place, a block a step through build_at's route, until it sees the place
  within its gun's reach, its blocks run out -- 50 at spawn, nothing
  restocked up there -- or something is in the way), then `camp`; in the
  `<mode>_stranded` branch of the four trees, weighted by marksman and
  aggression. A goal one step away is asked for even while shut in. On
  keidoro, three bots on the slab with edit=all built 130 blocks of
  walkway west in 5 minutes (out of reach of a base 330 away: they stop
  when the blocks run out); with a base 100 off, the walkway stops at
  sight and reach (38 blocks) and the bot shoots a man there. Babel: each
  stair laid on the row beside the platform with nothing in its way (a
  team may not break its own area's blocks), live: team 2's stair whole
  in 4 minutes, 2 captures in 9.
- 2026-11-25 (review agent, item 19): the fast fixes of the day against
  the owner's rule. ONE RULE FOR A FLEET: lib_bot's THE PEOPLE -- the
  people kept from connects and disconnects (xearly hooks; no walk, no
  per-tick list), `people_in(set)` over them with the one pid_matches
  mirror (no binding asks it of one id; piditer per packet is the walk to
  avoid) -- used by every loop for a client's sake: lib_bot's send guard,
  lib_player_limit (its `human` cache and the 0.25 s `calm` sweep replaced
  by an event-kept set of the clients still owed a cut, empty = a
  broadcast goes whole), lib_edit_mode (its per-tick `idle` cache gone: a
  look at each person), lib_player_properties, lib_night (fog, sky, beams,
  lights), lib_ext_policy's sweep, lib_headless's split. The command_ups
  copy is gone: lib_bot's late send_player_update drops a bot's World
  Update under upstream's command_ups. afkick's copy kept (a local
  function), cut to the exemption; lib_bot's 45 s sneak fidget, a second
  mechanism for "a bot is never away", removed. Every override names the
  upstream file it was made from by checksum; tests/overrides_test.lua
  fails when upstream changes under it. `bot_seats_free()` is the one
  count of "one seat kept for the server's hand" (engine_bots used its own
  copy); get_anon_pid finds the highest free seat without a walk.
  tentspawns: BODY (3) and SAFE_DROP (9) named from the game's rules.
  Engine: a team's leaders sized by its players (no clamp, no overflow);
  live grenades three a player, walked to the high-water mark, the oldest
  no longer silently overwritten; the planner's budget is max(--budget,
  --plan-rate x bots / hz) (same numbers: bench unchanged). The top-band
  jump rule in try_move removed: jumps at z 0 are the measured ones
  (nav_test top_of_map_jumps); keidoro's ceiling_slab results unchanged.
  Left open: try_edit's top-band rule for edits up into z < 3 (no test
  moves without it either; its reason, routes onto slabs, wants a look by
  the brain agent).
- 2026-11-25 (brain agent): the shut-in rule stated as what it is: a
  search over the map is what the throttle limits, a local search is
  always allowed. The nav policy has a `scope` (columns from the start a
  search may enter, 0 = the map, enforced in relax()); while shut in,
  fill_policy bounds the search to BC_NAV_JUMP_DMAX (the reach of one
  move) and move_to refuses only a goal beyond that scope -- the old "one
  step away (2 voxels)" distance is gone. Babel live with the row fix
  (Babelpocalypse, 6 bots a team, edit=all): both teams' stairs whole on
  row 255 (42/42 each) and the score 2-1 at 6 minutes, unchanged at 10
  (3 of 12 bots read "idle" in bots list then: to look at); babel's
  GAMES row in lsdctl now says bots = true.
