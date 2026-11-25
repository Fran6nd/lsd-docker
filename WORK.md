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
| 0 | 255 players by default; joining a server with 32+ bots works; outdated clients take the spectator path | DONE (v2026.11.25.2, CI fix .3) |
| 1 | This file | DONE |
| 2 | Study of tree diagrams + a visual proof of concept for the owner to choose from | DONE (owner chose A main, B secondary) |
| 3 | Report: how botd is built, CPU with 30 bots, where the bottlenecks are | DONE (report; acted on in 18, 19, 20) |
| 4 | Audit: every decision about WHAT that still lives in C; plan to move each | DONE (bot/DECISIONS.md; moves continue as items) |
| 5 | Archetypes as a data file beside the trees | DONE (archetypes.txt, v2026.11.25.7) |
| 6 | Bots look where they are heading; shot at: cover within the field of view, else face the threat, never turn the back to search | DONE (v2026.11.25.3) |
| 7 | Bots stuck on a roof bridge or dig their way down (engine_bots_edit=all) | DONE (player-realistic edits; v2026.11.25.4) |
| 8 | A babel tree, sent by babel_plus only when bots are added; no bots, no engine | DONE (babel.bt, masons/raiders, GAMES bots=true; v2026.11.25.5) |
| 9 | Remove battle_bots and the gamemodes bots, bots_rewards (setup, scripts, docs, migration of servers that run them) | TODO (after 0) |
| 10 | Shooting range gamemode on a generated map: a static range (bots as targets from 5 to 50 m, standing or crouched, never dying, never moving, damage shown to the shooter; a target on a rail or one that blinks from place to place) and an IPSC course, one player at a time; all targets as fast as possible; IPSC after the owner played it: targets drop, a start wall, no-shoots with a time penalty | DONE (range + IPSC + colour flip; v2026.11.25.6) |
| 11 | Graphical node editor in tools/tree-editor (replaces its text-first phase 2) | DONE (diagram editor; never seen on a real screen yet) |
| 12 | Docs pass left unfinished by the tooling agent (bot/trees/README.md, TREES.md trimmed, docs/*, skills) | TODO |
| 13 | A scenario test for the sniper role (tdm, ctf) | DONE (sniper_test, 07ad876) |
| 14 | Proposal to the owner: a behaviour's HOW written in Lua (a script skill a tree can `do`) | ON HOLD (owner stopped it; branch kept) |
| 15 | Editor backend gaps: a game list as data, a quiet roster poll, an outline for text that does not compile | PARTLY DONE: `lsdctl bots games`, `bttree --split --json` committed; open for botd/bt.c: a quiet roster request, a parse of a wrong text (see the 2026-11-25 log) |
| 16 | A release (the published image predates `lsdctl bots`; the editor refuses it) | DONE (releases .2 to .7) |
| 17 | Hostage gamemode: the hostages as engine bots with a tree of their own (botlink_add with a tree), falling back to today's lib_bot hostages with no engine; guards kept | DONE (v2026.11.25.7) |
| 18 | 230 bots without lag: botd sized for every seat, the planner's budget grown with the fleet, nothing built or walked for a bot on the server's send paths | DONE (v2026.11.25.4/.5) |
| 19 | Structural review of the fast fixes (the owner's rule: no quick hacks, one rule in one place) | DONE (d99cc30) |
| 20 | Server optimisation, "4 parallel threads?": the route board (a team's bots going the same way share one search) and the route planner on botd's threads, deterministic at any thread count | DONE (route board in .5; threads off by default in .7) |
| 21 | Never send a packet to a bot, nor the same packet to each: lib_bot is the one broadcaster (`broadcast`, `broadcast_each`, `people_in`), the guard counts what a script still sends at a bot, a test fails on any | DONE (broadcaster ac59a52; C patch 0002 d3a06f8) |
| 22 | `/votepeace`: a vote toggles a peace where no player damage is done; bots stand down; on by default in every mode | DONE on master (28e28bb), not released yet |

| 23 | Clients' UPS: large World Updates travel as reliable ENet fragments (flow control collapses on jitter); fix and measure under netem | PAUSED (UPS agent; findings in its report, scratchpad/ups/) |
| 24 | botd's slow rounds at 200 bots (p99 27-31 ms): every bot deciding in one think, and sight; two-phase sight so it could thread | TODO |
| 25 | Babel: carriers falling 26-30 voxels off their own stair's top under fire | TODO |
| 26 | CI: bttree does not build on Ubuntu (upstream demoncore.c -Werror=address-of-packed-member), so bots_ctl_test skips there | TODO |
| 27 | try_edit's top-band rule (no edits up into z < 3): same reasoning as the removed jump rule | TODO |
| 28 | lib_bot's send_spawn_player split, redundant since patch 0002 | TODO |
| 29 | One filter for every edit of the map (the owner: "all destruction effects must go through the gamemode's filter"): `may_edit_block`, asked at the engine's block_action_rm / block_action / block_line, answered once by each gamemode | DONE on the branch (lib_block_filter), not released |

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
- 2026-11-25 (range agent, item 10): the `range` gamemode on a generated
  map (catalog/core/range_map.lua, seeded; 1 block = 1 m). Static range:
  5 lanes 9 wide between walls 3 high, a line every 5 m (orange every
  10), lane numbers on a backstop 10 high; each lane the same 8 targets
  (5, 10, 15, 25, 35, 50 m standing or crouched, some on plinths; a rail
  at 20 m, 2.5 m/s across the lane; a blink between 30, 40 and 45 m
  every 1.5 s). A run: step into a bay, the clock 3 s later, stops at
  8/8; leaving the bay voids it. IPSC: a hall and three rooms walled 5
  high, doors and ports, 10 targets (one on a rail); /ipsc or the orange
  waiting area queues; one inside; clock from leaving the start box to
  the end box with every target hit; death, walking out, leaving the
  server or 120 s abandons; an intruder is sent to the waiting area and
  queued. Best times on two boards (/best). Targets: 50 lib_bot bots on
  team 2, silent, no think, no engine (no botlink file, botlink_add
  never called; GAMES bots unset), one controller from the map's data
  (static | rail | blink); immortal in the damage hook, the shooter shown
  the hit through damage_markers_show. Counted: bullets only. Live
  (lsd-range, two pyenet clients): targets where the metadata says (39
  static exact, 14 crouched), a lane run 8/8 with a double hit counted
  once, a marker per hit (49 body, 100 head) with the target at 100 hp,
  the IPSC queue end to end. Not done: a bot tree to run the course.
- 2026-11-25 (bcast agent, item 21): "make sure the server never sends the
  same packet to each bot; lib_bot provides a custom broadcaster".
  Measured first (tests/bot_sends_test.lua --table: one simulated minute,
  100 bots and one person, the core's own hook chain from core.lua with a
  stub of the C core that sends the way funcs_send.c and main.c do), on
  d99cc30: 33 650 sends made at a bot pid, 27 350 of them to the end of
  the chain, 445 000 visits of a bot by a piditer loop, 3.3 M Lua calls.
  The cause was not a script that sends in a loop but the upstream hooks
  that SPLIT a send to a group into one send for each id of it: purgatory
  (every packet of the server, 255 sends for each broadcast), command_ignore
  (chat), command_secspec (spawn, kill), command_ups (a World Update, 100
  bot visits a tick), and what C does itself for a bot (see below). Done:
  lib_bot's THE BROADCASTER: `broadcast(set, data[, unreliable])` (one
  call into the core for a group, none if no person is in it),
  `broadcast_each(set, fn)` and `people_in`; every typed send (30 of them)
  is guarded at the top of the chain (a send at a bot is dropped before any
  hook or packet, counted by name: `bot_guard_drops()`, one log line a
  minute with the file:line of the first of each when there were any), the
  core's own sends to the player an event is about kept apart (ENGINE:
  map, state, restock, reload, position...); a send to a group is made to
  the people of it a person at a time only for send_spawn_player, which the
  core takes apart itself (a has_quirk and a send for each slot).
  Overrides (checksummed): purgatory, command_ignore, command_secspec,
  command_ups send a group WHOLE unless someone in it needs a different
  packet, and then walk the people; map_meta tells the people the next
  map. Catalog loops that sent to each player now walk people_in
  (l10n's split, silent_player, message_types, teamplay, pie_menu, night,
  hostage, the_fall, callouts (now one send to the group), babel_plus,
  edit_mode, botlink, airstrike). After: 0 sends at a bot, the guard 0, 0
  to the end of the chain, 31 600 bot visits (lib_bot's seat count and its
  1 Hz people check, night's catch-up of a viewer), 2.0 M Lua calls (1.5 M
  of them the test's own stub core). Not loaded by the image, not
  patched: ffa, if_websocket (both split per id: use people_in if you load
  them), tip_spam, command_admin (rare). NEEDS C (not done, patches/lsd is
  another agent's): (1) send_map(PID_BROADCAST) on a map change and
  on_successful_connect of a bot call send_state for each slot that
  matches, bots too (answered by lib_bot at the top of the chain, but one
  Lua call each, 100 a map change); (2) main.c set_block / cull_* walk
  every slot with `pid_matches(PID_BROADCAST, i) && has_quirk(i, ...)`:
  one Lua has_quirk call per bot per block edit, and the OpenSpades
  noneighbor branch sends a block action to each slot WITHOUT the quirk,
  bots included; (3) send_spawn_player, demand_fingerprint and any C loop
  over pid_matches(set, i) reach Lua per bot. One C change would remove
  all of them: a recipient test `pid_matches(set, i) && st->p[i].peer !=
  NULL` in those loops (funcs_send.c send_map, send_spawn_player; main.c
  cull and set_block loops), as send_packet_flags already does for the
  send itself.
  DONE (peer agent): patches/lsd/0002-recipients.patch adds
  `pid_recipient()` (pid_matches && peer != NULL; pid_matches itself is
  unchanged, Lua's piditer and the damage/position loops still see bots)
  and uses it in send_packet_flags, send_map, send_spawn_player,
  demand_fingerprint, send_chat (textcodec), finish_map_load and the four
  main.c block-action loops. Measured on 200 bots in one container, Lua
  calls into the chain heads, before -> after: a map change send_state
  200 -> 0, send_map 1 -> 0 (nobody to send a map to), send_packet 21 -> 7;
  per 10 spade-3x edits has_quirk 26 000 -> 0 (Voxlap), 4 000 -> 0
  (OpenSpades) and send_block_action 2 000 -> 0 (OpenSpades, no person);
  per 10 grenade edits has_quirk 314 000 -> 0 (Voxlap), 4 000 -> 0.
  Smoke OK, dev/test.sh passes. lib_bot's send_spawn_player split could
  now go (the core skips bots itself): not done, harmless.
- 2026-11-25 (range agent, item 10, the owner's IPSC asks): what a hit
  does is the target's KIND, in the map's data (range_targets gained a
  field; range_version 2, an older range refused with a log line): plate
  (the lanes: never falls), popper (the course: the hit that counts kills
  it -- kill(pid, fall, itself): no kill, no score; out of the kill feed
  by lib_bot's silent options -- it stays down, get_spawn_time 0 for every
  target, and is stood up again when the run ends), noshoot (four on the
  course, on the people's team, each by a target: behind a crouched one,
  beside one by a door; a hit is +range_noshoot_penalty s, default 10,
  told at once and in the final "15.50 s + 10 s penalty = 25.50 s"; the
  boards rank by the total; never down). A same-team hit is dropped by the
  core's on_hit team test: the range's late on_hit (the_fall's place)
  sends it on to the damage hook, so every hit is decided there. The
  START WALL ('range_ipsc_wall': voxels and colour, painted that colour in
  the vxl) closes the start box from the hall; the server takes its
  supports (both ends, then the bottom row) by single block_actions and
  the rest is culled as floating -- every client drops it -- when the
  course is ready (every course target up, nobody else in, 3 s given); the
  clock starts then. A run's end, however it ends, stands the set's
  poppers up and builds the wall again before the next is let in. No
  rewards: lib_rewards reads gamemode_rewards (false while the range is
  loaded), rewards_enabled untouched. No building is now in the late
  chain and reverts the client's edit (map_layout.revert_action). Live
  (lsd-range, two pyenet clients, 22 checks): 10 poppers team 2, 4
  no-shoots team 1; a hit behind the wall counts for nothing; the wall
  down with 32 destroys sent and 0/120 voxels left; each popper hit a
  KillAction (itself, type 4) seen by both clients; a no-shoot hit "+10 s"
  with a marker and no fall; "16.42 s + 10 s penalty = 26.42 s"; 120
  builds and the ten stood up before the next shooter's wall fell; the
  next shooter's course all up; a walk-out rebuilt it; scores 0, no
  reward. Not seen: a real ZeroSpades client's hit on a teammate (the
  scripted client sends what it is told; ffa.lua relies on clients
  sending them) and the debris on a real screen.
- 2026-11-25 (brain agent): babel, the idle bots and the owner's two asks.
  IDLE: a bot reads "idle" when its whole tree ends at once every tick.
  The 3 seen were team 2's waiting round their carrier, who stood 3.1
  from his tent with the intel for minutes: `go_to own_base 2` arrived at
  the CORNER of a square of radius 2 round the goal (2.9 from the column,
  3.1 from the tent; ctf captures at 3, round). The planner's goal is now
  a distance (is_goal: a disc), and an exact goal (build_at's floor) is
  that floor, not one a voxel off it (move_to's "at hand"). ctf_test's
  dropped-intel check is read at 25 s, not 12 (a team-mate who took
  theirs is escorted past first; then two guard, as before).
  CARRIER DEATHS, measured (blueresortbabel, 10 a team, 20 min, a probe
  on kill and capture): 4 captures, 5 carrier deaths -- 4 shot, 1
  grenaded; 3 in the middle of the platform, 2 near a base (one parked
  out of capture range: the radius above); NONE by a fall: no fall
  pricing added (nothing measured asks for it). The engine now reads
  babel's one intel (bc_obj_theirs/ours: one object in the world is the
  one both teams go for and keep; one put out of the map is none), so
  the carrier uses `carry_home` (a route wide of the enemies it knows,
  shooting only who is in its way), mates `escort`, the other side
  `intercept`. After-numbers: being measured (same map, same probe).
  TOWER WORK: words `dig_weakest <place> [voxels]` (the block a player
  could dig whose removal drops the most: bc_cull_would_drop, the
  server's collapse run on the bot's map and undone; two wide -> a cut
  a block wide) and `put_at <place>` (a block where a player could put
  it: the nearest floor in reach that sees a solid neighbour's face);
  dig_at shares their edit path (stand chosen by bc_nav_sees_edit, the
  edit sent when the bot's own eye sees it). A pillar jumps only with
  the body's box clear of what is beside it. Team scope on the bridge:
  a world fact or place "<name>@1|2" is read by that team under the bare
  name (TREES.md 13). babel_plus: per team stair, widen (the second band,
  put_at), prop (a pillar beside the middle of the longest stretch held
  by nothing, build_at from the ground up), breach (theirs, at its
  weakest stretch); places written exactly ("%.2f": one decimal rounded
  a half by the build's own rule -- CI on Ubuntu's LuaJIT failed).
  babel.bt: masons (mend, widen, prop), raiders dig_weakest, carriers
  carry_home. Scenarios (build_test): propped stair broken where most
  falls (36 of 36), a widened stair stands a dig that dropped 73, a
  pillar to the step props it (72 -> 0), a cut stair rebuilt; 0 refused
  for sight in all. Not done: step G (hostages) is in progress in
  catalog/gamemodes/hostage/hostage.lua and bot/core/skill_fight.c (a
  bot with no rounds does not aim to fire at will).
- 2026-11-25 (brain agent): CARRIER AFTER-NUMBERS (blueresortbabel, 10 a
  team, the same probe; before: 4 captures, 5 carrier deaths in 20 min,
  2-2). First after-run: team 2's carrier dug for an hour in its own tower
  area, where babel_protect refuses it -- the engine knew only the
  platform's zone. Now `zone` is the whole list ("; " between), each
  rectangle for everybody or `team N`; babel_plus sends babel_protect's
  rules (own area nodig, the other's nobuild, per team); routes and the
  edit words honour them (build_test: a zone for one team). Second
  after-run, 25 min: 8 captures (team 1 all), 8 carrier deaths (team 2
  all: 7 shot, 1 grenaded), 6 of them on team 1's stair or in its area --
  team 2's carriers go home the wrong way, down the enemy's stair. A
  third run with the enemy's base as one more danger circle for
  carry_home: the same (4-0, team 2's carriers still dying west, one of
  a 26-voxel fall): backed out, not shipped. Open: why team 2's way
  down on this map is not taken.
  STEP G (item 17, REVIEW): the hostages are engine bots while an
  engine beats (botlink_add with the script's own tree), lib_bot's
  otherwise; the mind changes only while a hostage waits at a tent with
  nobody leading it. decide() keeps all the game's rules; the tree is
  told an order to follow, fact rescue / home / lost, and says `tell
  hostage_home`. The server disarms it (no rounds); a bot with no rounds
  does not aim to fire at will (skill_fight.c). Tests: bot/tests/
  hostage_test.c (held, led 180 across the field within 8.8 of its man,
  in when he is home and says so; rescuer dead: down and still, cowering
  under fire, never aiming), tests/hostage_test.lua (no engine: lib_bot's
  and nothing asked of an engine; engine: its tree, told once a change;
  freed, home, rescuer dead; the swap only at a tent).
  STEP E (item 5): the kinds of player as data -- trees/archetypes.txt,
  the built-in table number for number (kinds_test); the operator's
  /data/trees/archetypes.txt read after it by botd (a kind replaced, a
  kind added, nameable in engine_bots_archetypes); a script's
  `archetype_table` setting over the files'; a fault or a table missing a
  kind the mix names changes nothing. bttree --schema/--as/--split --mix
  read the file beside the trees or --archetypes FILE. The image ships
  the file (Dockerfile). Not done: `lsdctl bots schema` passing the
  files to bttree (lsdctl is not mine to edit; one line for its owner).
  STEP F (item 13), part: the tdm and ctf snipers stood idle once within
  45 of the enemy's base with nothing heard (`advance_by_cover ... 45`
  is a radius: it succeeded at once, and nothing followed); now they
  watch from there. The scenario test is parked: "a shot heard, up a
  hill" holds for 1 sniper in 7 -- to look at next.
- 2026-11-25 (parallel agent, item 20): "multi threading bots? 4
  parallel threads?" -- both the owner's options built, measured in
  BRAIN-STATUS.md (c3). The server process: nothing to move off its
  thread (World Updates are a loop and a memcpy a person, ENet is not
  thread-safe and every send comes from Lua, the map's compression is
  OpenMP already). THE ROUTE BOARD (core/routes.h, in master since the
  checkpoint): a team's bots going the same way share one search (a
  fresh route joined by a local search onto it, checked against the map
  as it is now; a search under way waited on; plan.share=0 is the old
  engine metric for metric); bench map230: expansions -16% (-37% after
  babel's planner changes), waiting for a route halved or better, think
  -18 to -24%. THE PLANNER ON THREADS: the core cuts its planner's work
  into units (engine.h) and applies what they found in its own order;
  botd runs them on a pool (botd/pool.h, --threads, setting
  botlink_threads); the same intents at any thread count
  (parallel_test, ThreadSanitizer clean); bench think -35% at 4. Live at
  100 and 200 bots (lsd-par, ctf prisonbreakv1 edit=all, a client on the
  Mac): botd 20-25% of a core at 200 whatever the setting, its p99 round
  27-31 ms untouched by either (not the planner), client 59-60 updates a
  second in every quiet run; the only drops came with the host loaded
  and hit server and botd together -- not botd's planning. So threads
  default to 1. Fixed on the way: a botd restarted at once by the
  entrypoint was never told the bots (lib_botlink resynced only after a
  silence; now a new engine_pid is a new engine). Next: what makes botd's
  p99 round at 200 (decide bursts, sight), and sight in two phases.
- 2026-11-25 (brain agent): WHY TEAM 2'S CARRIERS CAME HOME THE WRONG WAY
  (blueresortbabel), found on the real map in the simulator (platform,
  both stairs as babel_plus lays them, babel_protect's zones): a carrier
  run-jumps off its stair onto the roofs below (the planner's cheapest
  way), lands a voxel off the node planned, and plans from a ledge; that
  long search finds no way, and (1) `nocap` -- "the long search found
  none" -- stayed set for the goal, so every later search, from the
  floor it then stood on, took its first cap for "no way": stuck for
  good; (2) the team's no-way memory read "from about here" as within 24
  columns at ANY height, and was noted from a body in the air: from the
  platform 40 up the team was told there was no way home that side.
  Fixed: nocap is a fact about the floor it set out from (a search from
  another starts ordinary); the memory matches in height as for the goal
  (2), and is noted only from a floor. behaviour_test "no way from a
  cage; then the way through a maze": never there before, 44 s now; the
  height rule checked directly. Sim: team 2 carriers 24 of 24 home (12
  seeds, levels 3 and 8), from 8 places on the platform 24 of 24. Live
  (10 a team, the first 15 min until the map changed): 5 captures (4-1),
  2 carrier deaths, both team 2's -- falls of 26 and 30 off the top of
  its own stair (x 306-307, y 254: beside its two rows), with enemies
  about; not reproduced without them (every run home is clean), no dig
  near either, `evade` checks edges, routes plan no harmful drop: open.
  STEP F (item 13 -> REVIEW): the sniper scenario landed (bot/tests/
  sniper_test.c): rifles only (7 of 40 rifle marksmen, 0 smg, 0
  shotgun); nothing heard, to within 45 of their base and watching it,
  never idle (7 of 7); a shot heard beyond a wall, up a hill and camping
  (7 of 7); the role in its next life (7 of 7); ctf, keen on the game:
  their intel home, on toward their base and then for it (8 of 8 within
  45 s), dropped in the field (8 of 8). Two tree faults found and fixed:
  in tdm the top pick's `investigate` (curiosity) came before every role,
  so a curious sniper went to look instead of going up -- it is now the
  searchers' (tdm_searcher, looked at every second); and tdm_contact's
  `advance_by_cover enemy` and `flank enemy` succeeded at once when the
  man was already in range (or failed, too near to go round) with
  nothing after -- the bot stood "idle" seeing him; both now end in a
  fight.
- 2026-11-25 (peace agent, item 22): "votepeace to vote peace mode:
  damages are then disabled; undone on a new votepeace; warn joining
  players; bots aware". lib_vote (the tally, majority, timeout) now serves
  /va and /votepeace; vote_peace toggles the peace on a passed vote, with
  one hook at the last of the damage chain (`late`), after the range's and
  the editor's own answers to a hit: damage does nothing at peace except
  the fall type (falls, water, boundary), the map's own rule (decision: so
  a parkour course keeps its water; one line to change). Healing passes.
  Ends with the map. Bots: `fact.peace` for the trees (tdm, ctf, default,
  babel stand the war down on it: no fights, grenades or items) and the
  engine setting `fire=hold` (the server's rule: the movement skills fire
  at will, so trees alone could not keep a bot from shooting). On by
  default in every mode: lsdctl's default scripts, and `defaults_offered`
  gives an older settings file the script once, at `lsdctl init`.
- 2026-11-25 (brain agent): SHOT AT, NEVER ITS BACK (the owner: "when
  getting shot at you should almost never turn around and go back").
  Measured in the sim (6 a side, walls, 5 min each; for every hit, the
  next 3 s): before, back turned and walked away 2 of 211 hits (tdm),
  4 of 139 (ctf), 2 of 183 (default) -- fall_back_by_cover, fetch,
  fight; facing the shooter most of the 3 s 68% / 83% / 76%. The cause
  in the movement layer: a skill with nothing to aim at leaves the head
  to the travel gaze, which faced the route. ONE RULE there
  (skill_look.c): shot at (the trees' `threat`, 8 s) the head stays on
  the man and the body goes where the route goes, backwards or aside
  (act's remap_keys) -- every skill, falling back and a duty behind it
  alike; not on a move that needs the facing, and not for a man
  carrying the objective home (he runs: carry_home). `pressed` is now
  truly pressed: no round left, or hurt AND outnumbered (it was hurt OR
  outnumbered); the trees' fall-back options lowered (x0.6 under fire,
  x0.8 in contact, caution only). After: back turned 1 / 4 / 3, facing
  71% / 83% / 89%, fall_back_by_cover after a hit 5 -> 0; 5 ctf games:
  back turned 28 -> 9, captures 7 -> 5 (noise of 5 games), kills the
  same. Scenario (behaviour_test): shot from the front on its way to its
  base behind it -- on a bare duty its back to him 16 ticks after the
  first second before, 0 now (it backs away); on tdm it faces him all 5 s
  and goes no farther. Tests changed: skills_test's spade check runs the
  fight skill, not the tdm tree (a man with no round left is pressed
  now, and the careful back off).
- 2026-11-25 (brain agent): BABEL DITHERING, and TOWERS BROKEN FROM AFAR.
  Measured in the sim on blueresortbabel (10 a side, babel.bt, the
  bridge as babel_plus says it, 10 min): per bot per minute 16 leaf
  changes, 21 goal changes, 2.3 reversals of travel; the reversals came
  with a flip between the duty and the fight (enemy_visible dropping to
  0 the moment a man went behind something) far more than with the stair
  step moving (2 of 453: babel_plus's places left as they are), and with
  fight's own strafing (its dodge, kept). Fixed in the word: the score
  `enemy_visible [secs]` stays up that long after the last man left its
  sight, fading (the same 3 s as under_fire); babel's top pick reads it,
  and babel_contact has "just gone behind something: here, watching".
  After: 13 leaf changes, 15 goal changes, 1.2-1.4 reversals; stairs
  whole at 66-70 s as before; captures 3-0 / 1-0 / 0-0 over the three
  10-minute games (one game each: not read as a trend).
  TOWERS: dig_weakest keeps the one decision of WHERE (the server's cull)
  and now cuts by the cheapest it has, block by block: a weapon the tree
  names (`dig_weakest @breach 6 rocket`: the server's "inv rocket x y
  z", at a block in its sight), a grenade that lands with the block in
  the server's 3x3x3 crater, thrower clear (bc_grenade_lands, the arc
  solver's burst flown through the map; aimed at an open face, top
  first), else the spade; of the blocks that drop the most it takes one
  it can cut from where it stands. A hand grenade reaches nothing 17 or
  more over the thrower: a propped stair's weak point (high) is a
  rocket's, a plain one's (low, where it leaves the ground) a grenade's.
  babel.bt: babel_cut, the greedy using a rocket, missile, grenade
  launcher or airstrike they hold. build_test: a plain stair dropped by
  grenades from 22 off (74 blocks in 3.1 s), a propped one by a rocket
  from 40 off (40 at once), neither climbed; with nothing in hand the
  spade, as before. Not done: gunfire at blocks -- LSd takes a gun's
  "destroy" on the client's word (it counts the round); a bot has no
  client, and lib_botlink has no honest path for it yet (the rounds
  really fired at a block in sight, the hits a block takes counted).
- 2026-11-25 (brain agent): BUILDING COVER (the owner: "they should
  sometimes create cover"). A word, `build_cover`: shot at, a wall two
  high put up where it stands in the column beside it toward the man (the
  trees' threat), on the axis nearest the way to him, the middle then a
  column either side while it has the blocks (1 to 3 wide) -- each block
  from where it stands, against a face its eye sees (the floor's top,
  then the first block's), not where a zone forbids building, never with
  building off. In the under-fire picks of tdm, ctf, default and babel,
  weighted by the builder trait (x0.6 under fire, x0.8 in default's top
  pick), only with no cover in view (else to the cover in view): walls
  up, down behind it, and at its next choice the wall is cover in view
  to fight from. behaviour_test: 6 builders on the tdm tree shot at from
  40 in the open -- 5 walled up, 4 hidden from him crouched behind it;
  6 of other character: none; building off: none; refused for sight 0.
- 2026-11-25 (protect agent, item 29): THE ONE FILTER. The owner, on babel:
  "with a rocket I destroyed the platform". Measured on a live babel
  (container, Lua through `lsdctl exec`): a blast on the platform, a
  grenade, a spade, a bulk destroy all leave it whole -- upstream's own
  block_action_rm hook (babel.lua) keeps the platform from everything --
  but the platform did go once a tower holding it up was cut (a crater
  on a column built to it): the cull dropped it, babel rebuilt it
  (platform_destroyed ">:("). See "what remains". What was wrong
  structurally: each protection lived in its own hooks (upstream babel's
  block_action_rm for the platform, babel_protect's on_block_action for
  the towers, map_layout's two for "foreign" writes, parkour's and the
  range's block_action for a grenade only), and the effects' `may_break_block`
  was a second, parallel gate asked by the effect's own door and by bots'
  digs, with babel the only one answering. So: a rocket at the range's
  start wall, at a parkour course, a grenade beside a map_layout door
  (map_layout looked only at the grenade's centre) all took blocks.
  After: lib_block_filter (catalog/libs/block_filter), required by
  map_layout (so by every gamemode), player_effect and bot. A gamemode
  answers `may_edit_block(who, pos, type)` once (babel_plus: platform and
  towers, now also builds; map_layout: its cells; range and parkour:
  everything) and it holds for every edit, because the filter hooks the
  three engine calls every edit ends in, in the early chain, and asks per
  block (a spade's 3, a grenade's 27; when some are refused the rest are
  taken one by one, each with its cull; air is never asked). Who: a
  player's `from`; under the anonymous pid, `edit_as(who, fn)` (effects'
  break_blocks, lib_bot's bot_dig_block) or else "a script" (nil);
  `server_edit(fn)` for the server rebuilding its own (map_layout's
  fill/paint/dig_box, the range's wall) -- not asked. `may_break_block`
  is gone. Table of paths (before -> after):
    player spade/gun/build/line ........ upstream hooks only (babel, babel_protect, map_layout, parkour, range each their own) -> the filter too
    server grenade (detonate_grenade) .. babel.lua hook for the platform only; map_layout: centre cell only; range/parkour: refused whole -> the filter, per block
    effects (rocket, missile, airstrike, grenade_launcher, the_fall, railgun) .. may_break_block, asked by break_blocks, only babel answered -> the filter, as the owner
    bots' digs (lib_bot, botlink) ...... may_break_block precheck -> edit_as + the filter (the botlink precheck stays, advisory)
    lib_bulk_destroy users (sel.lua, scripts) .. block_action_rm: upstream babel + map_layout's anon check -> the filter, as a script
    map_layout drawing, the range's wall ... unchecked / `we.drawing` -> server_edit
    edit_mode (spade_with_62, batches) .. block_action_rm / block_action with the player's pid -> the filter (nothing to change)
    the cull ........................... not an edit, not asked (see below)
  Tests: tests/block_filter_test.lua (the real filter between a copy of
  main.c's block paths and the real babel_plus, range, parkour and
  lib_map_layout: rocket, missile, airstrike bomb, grenade, spade, bulk
  destroy, a bot's dig, lines; 18 of its checks fail with the hooks
  off), the old may_break_block tests moved to the new question.
  WHAT REMAINS: the cull. A protected structure that unprotected blocks
  hold up falls with them (clients flood-fill themselves, so the server
  cannot keep it), and babel's platform hangs on whichever tower reaches
  it: cut that tower and the platform vanishes for a moment and is
  rebuilt (upstream's after.finish_cull). Refusing a cut that would drop
  it would make the first stair to reach the platform uncuttable, which
  the raiders' tactics (item 8) rely on; the owner may want it anyway.
  sel.lua's admin edits run as "a script" (the protections hold against
  them); a decision for the owner whether an admin may edit protected
  blocks.
- 2026-11-25 (brain agent): THE DEMO'S STUCK GREEN TEAM (babel, 15 a
  side): its carrier "arrived" on a pile of blocks on its own tent, five
  over it, out of what the server counts (lib_ctf's tent cylinder: the
  eye from 4 over the tent's point to 1 under), with 11 team-mates
  escorting it, packed on the base. (1) carry_home now goes to a floor at
  the base inside that band -- one to stand on, else the highest solid
  voxel in it, the route digging down to it -- strictly inside, not on
  its edge. Three faults in reaching an exact floor, found on the way:
  an exact goal arrived when the body was held a voxel over it by a
  corner of the next column (the follower's "at rest a voxel above" is
  for ordinary goals only), an empty plan for an exact goal was taken as
  there (it is followed, off the corner and down), and an exact goal
  once reached stayed "arrived" after the body left that floor (planned
  again). (2) escorts: the score/condition `escort_open` -- a mate
  carries their intel, is going somewhere (not still for 4 s, follow's
  patience), and fewer than two escort him (a station each side), the
  first two keeping it; the trees' escort options read it; near home
  they stand beside him, not on him. ctf_test: a carrier digs into a
  7x7 pile 5 high on its base and captures (5.5 s); 8 of a carrier's
  team, at most 2 escort him, none once he has stood 7 s. build_cover's
  side cells are judged from the bot's own eye (it waited on one it
  could not see, to the word's 8 s): 5 of 6 builders hidden, was 4.
