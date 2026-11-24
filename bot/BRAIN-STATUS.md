# The brain: senses, skills, vocabulary, engine, trees -- where it stands

## CHECKPOINT npc (2026-11-25, later still): a tree for one bot, traits=, the operator's trees

`make -C bot test` is green, no warnings (engine_test 184 checks,
botd_test 72).

- **A TREE FOR ONE BOT** (`tree=` sent for a pid: a gamemode's NPC with a
  role of its own). A name, or TEXT -- which is now that bot's own:
  compiled and kept for it alone (it used to replace the one custom
  forest for everybody), replaced by its next `tree=`, freed with the
  bot. Empty gives it back the world's tree; a name nobody has is said
  and gives it the world's; a text that does not compile is said with its
  line ("bot #1: tree= does not compile, it keeps its tree: line 3: ...")
  and changes nothing. Its own `<name>_also`, `tree items` and `tree
  extras` work, and when an item's fragment changes its text is compiled
  again. Scenario: three bots, the world on tdm, one on `default`, one on
  its own text; then name -> text -> text -> bad text -> name nobody has
  -> text -> empty, 40 changes in a row with an action RUNNING each time,
  the bot removed with a text of its own. `leaks --atExit` on the whole
  engine_test: 0 leaks.
- **`traits=<trait>:<factor>,...`** (for everybody, or one bot; the two
  multiply): each named trait's weight is multiplied, on top of what the
  bot rolled, within 0.2 to 3. Empty clears. A name nobody knows is said
  ("traits=: nonsense: no trait of that name") and left out. Applies to
  bots made before and after. 200 bots hit with a man in sight: 125
  fight on; 189 with `traits=aggression:2,caution:0.5`; 18 with
  `aggression:0.5,caution:2`.
- **botd reads the operator's trees**: after the built-in directory,
  every *.bt of `$LSD_DATA/trees` (LSD_DATA: /data), or `--user-trees
  DIR`. A tree there with a built-in's name replaces it; other names are
  added. A file that does not compile is said ("botd: tree error: file:
  line N: ...", the line being the line in HIS file) and skipped, the
  built-in staying. Read again at every map load, and the log says which
  were loaded ("user trees loaded from DIR: a.bt (a), n.bt (n)").

### THE BENCH (`tests/bench.c`): the numbers a change is judged by

```
make -C bot build/tests/bench
bot/build/tests/bench                          # every built-in scene (about 2 minutes)
bot/build/tests/bench arena40 sea40            # those scenes
bot/build/tests/bench ctf:10                   # ctf, 10 a side, 300 s
bot/build/tests/bench map:/path/prisonbreakv1.vxl 120
bot/build/tests/bench > before.txt ; ...change... ; bot/build/tests/bench > after.txt ; diff before.txt after.txt
```

Not a test (nothing asserted, not in `make test`). One line a metric,
`<scene> <metric> <value> <unit>`; everything but the two `think_*` lines
is the same on every machine and run. Scenes: `arena12/32/40` (flat field
with walls, tdm, respawning, 60 s), `fight6/20` (to the last man),
`sea40` (two islands, both bases in the water), `ctf:<n>` (a town of
walls, 300 s), `map:<file.vxl> [secs]` (40 bots, tdm, bases at the dry
ground nearest 128,256 and 384,256). Metrics: `think_mean_us`,
`think_worst_us`, `no_key_pct` (living bot-time with no movement key and
no trigger), `waiting_pct` (of it, standing waiting for a route),
`longest_idle_s`, `wading_pct`, `plans`, `plans_capped`, `plans_no_way`,
`expansions_per_plan`, `kills`, `stuck`, `goals_dropped`, and `result_s`
(fights), `captures`, `first_capture_s`, `pickups`, `drops` (ctf). bench.c's
header says the same.

## CHECKPOINT scenarios (2026-11-25, later): every behaviour has its scenario

`make -C bot test` is green, no warnings. New: `tests/tactics_test.c` (47
checks). The numbers, all from the simulation:

| behaviour | scenario | result |
|---|---|---|
| flank | 8 bots, 118 voxels to the enemy's base | 8 of 8 arrive; none nearer than 35 voxels to the direct line on the middle of the way; 8 of 8 come onto the base from beyond it; left 4, right 4; the slowest 24 s (direct 12) |
| hunt_noise | a mate sees a man 95 away behind a wall | the bot goes: within 12 of the place after 14.2 s; with nothing told it does not move |
| take_high_ground, camp | two hills and a pillar nobody can climb | 2 perches known (not the pillar); two rifles take one each, 4 and 5 voxels up, on `camp` crouched facing the enemy's side 600 of 600 ticks; a third rifle gets none and does something else; shot at, the perch is left |
| gun and high ground | 30 marksmen on tdm.bt | 30 with a rifle go up, 0 with a shotgun |
| advance_by_cover | 84 voxels across a field a man watches from the side | in his sight 4.9 s, against 11.1 s straight (44%); 23.2 s against 11.1 s |
| fall_back_by_cover | hit by a man 34 away | out of his sight after 3.5 s; after 15 s still out of it, 87 from him, 0 rounds fired |
| the team's memory of no way | a base walled in | the first bot: 3 searches; five more bots joining: 1 search more, 5 goals refused from memory |
| SHUT IN (new) | a bot in a box with no door, 60 s | 11 searches (was: one every few seconds for ever), found shut in 4 times, never over 0.2 s with no key, no round and its head still; with `edit=dig` it digs out |
| the split, nothing in sight | 200 characters, a perch free, a rumour, a leader about | flank 46, hunt_noise 35, take_high_ground 18, follow 53, seek 48; rifles go high 14, smgs 4, shotguns 0; flankers flank 27 of 31, pushers seek 28 of 31, supports follow 27 of 27, scouts hunt 20 of 30, campers go high 9 of 21 (a third of them hold a shotgun and cannot) |
| 20 against 20 | a field of walls | over after 27 s (20-5), stuck 0, longest in one cell with keys down 1.6 s, nobody idle outside cover/camp/hold |

**SHUT IN** (skill_move.c): three searches in a row that find no way, and
for 15 s `bc_move_to` asks for none; the bot paces what room it has and
looks about (engine.c, decide), then one search is let through. This is
the CubeMaze finding (a bot in a closed cube asked for ever and stood).

**tdm.bt's weights were tuned** with `bttree --split` (a perch free, a
rumour, a leader): high ground 25.6% of all (was 56%), flank 23%, seek
20%, follow 19%, hunt_noise 12%. Still true and NOT the tree's to mend:
98% of CAMPERS with a rifle and a free perch take it (marksman 1.8), 95%
of pushers seek, 96% of supports follow -- an archetype's one high trait
decides. See "needed from others": persona.c's spreads.

**Also fixed on the way:** a cover search was begun again every time the
bot had walked two voxels, so a bot advancing never finished one (bounds
by cover did not work at all while moving); a tree entered afresh (a man
comes into sight) no longer throws away the bound or the cover in hand;
the unreachable memory was keyed on the dead end a bot's partial routes
led to, not on where it set out from, so its team-mates never matched.

### Think cost (M-series laptop, -O2, `bc_engine_think`, a call; the host calls twice a world)

| scene | bots | before this work | now | worst call now |
|---|---|---|---|---|
| flat field with walls, 60 s, respawning | 12 | 74 us | 28 us | 1.0 ms |
| the same | 32 | 127 us | 79 us | 1.2 ms |
| the same | 40 | 150 us | 121 us | 1.3 ms |
| 20 v 20 to a result | 40 | -- | 93 us | 1.2 ms |
| prisonbreakv1 (real map, mostly sea), 120 s | 40 | 404 us, bots frozen | 356 us | 3.4 ms |
| spud (real map), 120 s | 40 | not measured | 201 us | 1.5 ms |
| Temple (real map), 120 s | 40 | not measured | 197 us | 2.0 ms |

The mean did not double anywhere; on the flat field it fell, because
routes are no longer searched to the end and are asked for less often.

## CHECKPOINT water (2026-11-25): time in the water, a maze, a dig from the water

`make -C bot test` is green, no warnings (behaviour_test 38 checks).

- **Time in the water** (40 bots, tdm, 120 s, simulation; tents of
  prisonbreakv1 guessed at 72,256 and 440,256, which are an islet and open
  sea): wading 64.8% of living bot-time right after the freeze fix, 45.0%
  now; spud 4.1% before and after. What changed: (a) from land to land
  the sea keeps its full price again (0.5 s a column), so a way round by
  land is taken -- the cheap, greedy water search is only for a body or a
  goal IN the water; (b) falling back in the sea is "to the nearest dry
  ground", not a base a hundred voxels of wading away; (c) `leave_water`
  goes for a column INLAND (a body stopped on the edge rested half in the
  sea and the skill ran for ever: one bot idle 60 s), counts "there and
  still wet" as a failure, and after three banks with no way up gives up
  for 20 s, during which the bot is not "in harmful water" and gets on
  with the game. Not fixed, and probably true to the map: 76% of the
  wading samples had dry ground within 12 -- with both bases out in the
  water the routes run along the shore. "Walk at the goal while waiting"
  was compared on and off (`plan.wait=stand`): 64.8% against 62.2% wading
  on prisonbreakv1, 4.1% against 5.3% on spud: it is not what keeps them
  in the water.
- **The live stuck line** (fall_back_by_cover, "going nowhere", route
  3/206 WALK, sees 19) is the case (b) above: a fall-back in the sea
  toward a far base. Seen again in the simulation only as a one-step
  route pushing at a bank, which the net ends in 4.5 s.
- **A capped search in a maze**: a serpentine of five walls, 330 voxels
  of way; there in 39.9 s with searches run to their end, in 39.4 s with
  a cap of 400 expansions (2 plans, 1 stopped at the cap), stuck 0.
  On the real CubeMaze (my spawns are arbitrary places, some of them
  shut in): 31% of the time with no key down against 38% with the old
  planner, 240 of 1251 plans finding no way; a bot shut in a cube has
  nowhere to go and asks all the same -- NOT solved.
- **A dig asked for from the water**: a pool four deep with digging
  allowed: out after 6.5 s, 5 digs, 3 of them made standing in the water,
  none refused; without `edit=dig` it stays in, digging nothing.

## CHECKPOINT freeze (2026-11-24, later still): bots "frozen" after a map change

`make -C bot test` is green, no warnings (behaviour_test now 29 checks).

**THE CAUSE, MEASURED** (40 bots, tdm, on the real prisonbreakv1.vxl in
brain_sim, tents guessed at 72,256 and 440,256 -- both in the sea):
80.6% of all living bot-time had no key down, 96% of that with the bot
waiting for a route; the longest wait was the whole 60 s; 91 plans were
finished in 60 s, **59 373 expansions each**, against a budget of 3000 a
think. Why so many: wading costs seven times what the planner's heuristic
takes a column for, so a search for any way that crosses water first
looks at all the land (and sea) it could have reached in that time -- the
whole island; and a goal with no way to it floods the pool. The follower
or the watchdog had no part in it: a waiting bot holds no key.

**THE FIX** (the engine's side; nav got one policy field, `h_weight`):
1. A search is stopped at `plan.cap` expansions (8000) and the bot walks
   the route to the nearest place it found, planning on from there; when
   capped routes bring it no nearer it gets one long search (five caps),
   and if that finds nothing the goal is unreachable (team memory).
2. Searches are greedier (`plan.greed`, 1.5), and from or into water much
   greedier (4) with water priced as slow, not also as dangerous.
3. **A bot waiting for a route does not stand**: it walks straight at the
   goal where `bc_walk_safe` allows, and takes the route up where it then
   is (`plan.wait=stand` gives the old behaviour).
4. Fewer routes are asked for: a bound by cover no longer plans to the
   destination and then to the cover; a moving destination is re-planned
   when it has moved 15% of the way to it; the fight's chase likewise.
5. Nobody takes cover, ducks or pauses in the sea: `take_cover` in water
   is "out of the water", `crouch` there ends at once.

**AFTER**, same scene: no key down 8.3% of the time (cover, camping,
holding by a leader), 2.5% waiting for a route, 2131 plans in 120 s at
3305 expansions each. spud and Temple: 16.5% with no key down, 1% of that
waiting. In `make test` (two islands in a sea, both bases in the water):
as it was 6 of 40 hold a key 7 s after the start and 72.7% of the time is
spent standing waiting (longest 28.9 s); as shipped 40 of 40, 0.3%,
longest 1.1 s. Think cost, 40 bots on the flat arena: 116 us a call
(214 at the last checkpoint, 150 before any of this work), worst 1.3 ms;
on prisonbreakv1 315 us a call, worst 2.3 ms -- there the planner uses
its whole budget, as it is meant to.

**NOT VERIFIED:** the real tents and spawns of prisonbreakv1 (mine are
guesses); the demo itself (this is the simulation); how a capped route
behaves on a maze map with real bots -- CubeMaze was not run after the
change; whether the "stop-and-go" seen live (keys swinging between 6 and
37 of 40) is all the same cause, though it is what the old budget sharing
produces. The ctf 6-a-side game is sensitive to all this: its first
capture now comes after 359 s (six seeds: 122 to 359 s), and its "some
go" assertion had to drop to 2% of the time on the enemy's third.

## CHECKPOINT ctf (2026-11-24, later): leaders, and ctf as a team game

`make -C bot test` is green, no warnings (new: `tests/squad_test.c` 13
checks; `tests/ctf_test.c` now 25 checks and no "NOT YET" line).

- **LEADERS** (`core/skill_squad.c`). Per team the engine draws leaders by
  lot among the team's members, bots and people alike, nobody told: one
  for every `leaders.per` members (default 5; 0 turns it off), a person
  weighing `leaders.human` (default 2), a bot by character. A term of 2
  to 6 minutes; lost on leaving, on dying twice in a minute, or (a bot)
  on having had a goal dropped for being stuck. Other bots attach to the
  nearest leader with room (4 a leader; never with teamwork under 0.75),
  and `follow leader` keeps a station beside and behind him, goes where
  he is going, takes his target, stops when he stops, and leaves a leader
  who stays put (10 s + 15 x teamwork). Words: `is_leader`, `has_leader`,
  `leader_near`, `leader_fighting`, `follow leader`, the place `leader`;
  the score `quiet [secs]` came with it (see the lamp fragment below).
  Scenarios: ten a team -> 2 leaders each, 13 followers, no squad over 4,
  0 of the 2 loners follow; a person chosen walks 62 voxels and 4 of 5
  bots are within 10 of him, in front of his gun on 0 of 1795 bot-ticks;
  he fires at a man and 5 of 5 take that man; he is killed and nobody
  stands over 0.9 s; a person who stays put is held round by 3 of 4 at
  8 s and by none at 50 s; `leaders.per=0` -> no leaders, no followers.
- **ctf as a team game** (`trees/ctf.bt`). 6 against 6 on a field of
  walls 150 long reaches a first capture after 117 s, stuck 0; while the
  intel is carried the carrier's mates are on `escort` 85 of 221 samples;
  the carrier fires 0 rounds at a harmless man 20 off its line and is
  home in 11.3 s against 10.6; with our intel taken 5 of 5 go for the
  thief, 3 of them for a place AHEAD of him, and he is dead in 3.9 s; his
  dropped intel is then guarded; 200 characters with nothing in sight:
  fetch 83, guard 72, flank 45, and with ours taken intercept 186, fetch
  10, flank 4.
  HONEST LIMITS: the capture took 117 s and team 1's men were on their
  own third of the field 73% of the time and on the other's 6% -- two
  equal teams of bots mostly hold each other in the middle, and a
  respawn beside the intel favours the defence. On an OPEN field (no
  walls) of the same size there was no capture in 240 s. After the thief
  fell only 1 of 5 stood guard over the dropped intel.
- **The lamp fragment needs one more line** (the server's night script;
  the test's copy has it): `option none quiet 25 x5` / `do lamp on`,
  before the stealth line. Without it two stealthy bots with no night
  vision are blind for good and a night game can fail to end (seen: 240 s,
  1 against 5, none seeing another).
- Think cost with 40 bots is now 214 us a call (150 before any of this,
  164 at checkpoint 1), worst 2.0 ms: followers ask for routes often. To
  be looked at with the numbers table.

## CHECKPOINT 1 (2026-11-24): the head, cover, the net under a stuck body, water

`make -C bot test` is green (new: `tests/behaviour_test.c`, 23 checks). In
this state, and safe to put live:

- **The head while travelling is the bot's own** (`core/skill_look.c`):
  ahead along the route, glances at openings, at where a noise came from,
  over a shoulder. `gaze=0` (a setting) gives the old steering-locked head
  back, for comparing live. 24 bots walking past a still man in a corner
  behind their route: 0 see him with the locked head, 8 with their own,
  24 of 24 once he fires a shot.
- **Being shot at** is known (hurt, a round passing within 2.5, a mate
  killed within 12): `crouch` at once (0.07 s), `take_cover` (behind a
  wall 6 voxels off and at rest 3.2 s after the hit; with none: crouched,
  turned to the shot), `advance_by_cover`, `fall_back_by_cover`. Cover is
  a budgeted flood (`core/skill_cover.c`).
- **THE LIVE BUG (bots wading against a bank for minutes).** The old
  watchdog cleared its timer on any think with no key down, and every new
  plan has one: it never fired. The new one (engine.c, THE NET UNDER
  EVERYTHING) watches the body, whatever the skill or the follower says:
  1.5 s pushing -> a jump; 1.5 more -> a step back, a sidestep and a jump,
  and a new plan with the failed move priced; 1.5 more -> the goal is
  DROPPED, remembered as unreachable for the team (30 s), the tree is
  entered afresh and the bot goes somewhere else for 4 s. Also: 8 s on a
  route without leaving a 4-voxel circle. Counted (`stats.stuck_tries`,
  `stuck_resets`); one level-1 line a bot a minute: "bot #12 stuck at
  x,y,z (pushing) doing <describe>". Scenario (6 bots wading at a bank the
  server made a voxel higher than the engine knows): longest in one cell
  with keys down 1.5 s, 15 goals dropped in 60 s, 5 of 6 out by the other
  banks.
- **Water that hurts** (`water.damage=<n>`, or `water=lethal`): the
  setting is taken, given to nav's policy, and `leave_water` is above
  everything but a grenade in tdm.bt and default.bt. 6 bots spawned in it
  at 10 a second: all make for dry ground first, dry in 3.4 s, none dies.
- tdm.bt and default.bt are rewritten: the last resort is `seek` (the
  ENEMY'S BASE), not roam. flank / hunt_noise / take_high_ground / camp
  exist and are in tdm.bt but have no scenario of their own yet.

### Added since, same day (still green; `tests/ctf_test.c`, 14 checks)

- **ctf, first half.** `trees/ctf.bt` (the tree is named `ctf`),
  `core/skill_objective.c`: fetch, carry_home, escort, intercept, guard;
  the words carrying_intel, their_intel_home/_dropped/_carried,
  our_intel_home/_dropped/_taken, near_own_base, near_their_base,
  mates_near; the places their_intel, our_intel, their_base, thief,
  carrier, intercept. THE SERVER'S RULES WERE READ (ctf.lua, lib_ctf.lua,
  lib_bot.lua, main.c) and a bot needs nothing special: the pickup loop is
  over every connected player and bot_create connects its bot; pickup is
  walking within 3 of the other team's intel, capture is carrying it
  within 3 of one's own tent, death drops it on the spot, 2 s without any
  pickup after a drop, and a team can never touch its own intel (a dropped
  one of ours can only be guarded). brain_sim.h plays those rules.
  WORKS: a lone bot picks up after 11 s and captures after 22 s, and again;
  the carrier is on `carry_home` every tick it carries and gets home in
  11.6 s with a man off its line against 10.7 with nobody; a thief is run
  down by 4 of 5 and his dropped intel is then guarded by 4; replay holds.
  **NOT DONE (printed "NOT YET" by the test, not asserted):** 6 against 6
  does not reach a capture -- the teams meet in the middle and fight there
  as in tdm; with nothing in sight 166 of 200 characters fetch (guard 23,
  flank 11): the weights are untuned; "ours taken" does not shift the
  split to the thief in the 200-character scene; nobody was seen heading
  for a place AHEAD of the thief.
- nav's asks done: roam snaps to dry ground (`bc_nav_snap_dry`) and no
  longer walks "the way it faces" when it finds nowhere; the policy gets
  `water_damage` (scaled up for a hurt bot) and `water_lethal` only at 30
  a second or when the damage is unknown.

Not yet: ctf team play (above), leaders, the scenarios for flank / high
ground / cover-to-cover, the numbers table. The sections below are the previous agent's and
are being brought up to date as the work goes; where they disagree with
the above, the above is right.

A checkpoint for whoever continues. `make -C bot test` builds with no
warning and every test passes on macOS arm64 (Apple clang 17) and on
Linux x86-64 (Alpine, GCC, emulated; see (c)). `make -C bot` links
`build/bin/botd` against this engine (`build/bin/botd --once --file
/nonexistent` exits 1 at once, as it should).

**It has never run against a real LSd server.** Everything below was
measured on `tests/brain_sim.h`, a server I wrote from reading
`lib_botlink.lua` and `lib_bot.lua`. Where that simulation is kinder
than the server, it is said in (f).

## (a) What exists

| file | what it is |
|---|---|
| `core/senses.{h,c}` | What ONE bot knows. Sight (180 degree field, 128 range, three rays for line of sight, close things noticed by their footsteps, 6 s of "noticed"), the three rows of night sight (off unless `night.sight=1`), memory of each enemy with decay, hearing by kind and level, where a hit seemed to come from (bearing error by level), alertness (calm / suspicious / engaged), the team's board (sightings told after a relay delay; standing pings), `bc_ping_kind`. No engine in it: `senses_test` drives it alone. |
| `core/skills.h` | The skills' documentation (wishes not keys, who owns the head, what is aosbot's and why), the level table's non-aim columns, the guns, the grenade maths. |
| `core/brain.h` | PRIVATE: `bc_bot`, `bc_engine`, the wishes, the mover; how a think goes (decide / plan / act, jolts). |
| `core/skill_move.c` | One goal a bot; the shared searches and the budget (longest wait first); the follower's answers obeyed as nav.h prescribes, `bc_nav_follow_again` and `GIVE_UP` included; edits through `BL_AC_BLOCK` / `BL_AC_LINE` at the server's rates; keys from a direction with hysteresis; the walk-safety simulation; cover search; roam goals. |
| `core/skill_fight.c` | Target choice, engage and hold ranges by gun, level and character, strafing, crouch bouts, jump-dodge, bursts, the mate in the line, reload discipline, the spade. |
| `core/skill_grenade.c` | aosbot's arc, flight, damage; throw; evade. |
| `core/skill_misc.c` | Named places; go_to, investigate, roam, follow, hold, retreat, ping, use, lamp, obey, look_around, reload. |
| `core/vocab.{h,c}` | THE vocabulary: 70 words (35 conditions, 20 scores, 15 actions), one table, one line of documentation each, `bc_vocab_dump`. |
| `core/engine.c` | `engine.h`, exactly (its two contracts are now written in engine.h's comments: a failed `bc_engine_trees` changes nothing, a good one replaces all; log levels). Settings, events, the items tree, the extras tree, the think loop, `bc_engine_describe`. |
| `trees/default.bt`, `trees/tdm.bt` | The shipped trees. Each compiles alone (botd tries them so). Nothing in them about night or lamps. |
| `tests/brain_sim.h` | The simulated server. |
| `tests/senses_test.c` | 529 checks. |
| `tests/skills_test.c` | 63 checks, one skill at a time. |
| `tests/engine_test.c` | 154 checks (162 with `BC_TEST_MAPS`). |

## (b) What passes, with its numbers

`senses_test`: field of view, range, line of sight (a four-high wall
hides, a kerb does not), close noticing (walking 8, still or crouched 4),
memory and its decay, the three night rows each (lamp out: nothing even
at arm's length, but a shot is heard; lamp lit: in the cone yes, beside,
behind, beyond its reach no; night vision: a dark man at day range, a lit
one beyond it, neither through a wall, and the field of view still
holds), by day all three alike, night ignored when `night.sight` is
unset, hearing by kind and level (aosbot's ranges), a team-mate's noise
and a visible man's dropped, melee has no sound kind, the hit's bearing
error (level 1 up to 37.8 degrees, level 10 up to 5.4), the board's relay
(1.5 s) and staleness, ping keywords.

`skills_test` (flat field, one or two bots):
- finds and kills a standing man behind a wall: 8 s, 6 rounds, 3 hits.
- SMG: trigger down 198 of 360 ticks, longest burst 0.77 s; reloads out of a fight.
- no ammunition: spade, dead in 5.3 s, no round fired.
- a mate in the line: 0 rounds in 5 s; fires once he steps aside.
- a shot heard 31.5 away (level 9 hears to 31.8) is gone to round a wall; a level 1 hears nothing.
- orders: GOTO reached 4.3 s after the order (1.6 from the place), HOLD for its time, HUNT of an unseen man kills him.
- follow keeps 3.9 from a walking mate; retreat is out of sight in 1.8 s without firing.
- grenade: arc and damage maths; thrown at two men 22 away, both dead, thrower unhurt; one thrown at the bot is run from (18 voxels by the burst).
- edits: off, the wall stops it; `edit=dig` digs through a two-thick wall (6 digs, none refused); `edit=build` bridges a 9-wide trench (4 blocks, then jumps the rest); a wall the server refuses to let it dig: 2 voxels learned, then it stops.
- a bridge shot out under a route: the engine's own collapse removes the deck, the route is planned again, the bot crosses by the other bridge, never in the trench.
- two keen bots seeing one enemy for 12 s: ONE ping, "Enemy"; a loner: none.

`engine_test`:
- every word of the dump compiles in a tree; the two .bt files compile alone; a broken text changes nothing; a good one replaces; an unknown tree name runs "default".
- **6 against 6 to a result**: over in 9 s by day, 12 s at night with the night script's settings; **stuck (one cell, movement keys down, over 3 s): 0**, longest hold 0.57 s / 1.02 s.
- dead bots write no keys; a new life is clean; UNBOT removes.
- a ping: 2 of 6 take it, the nearest keen ones, not the loner nearer than one of them; they get within 6 voxels; "Thanks" is nobody's; `ping_takers=3` makes it three.
- hit down to 45 with the man in sight: **3 of 60 careless bots break off, 60 of 60 careful ones**.
- night: lamps out, two enemies pass 6.0 apart with no sighting and no round; lamps lit or one with night vision, they fight. The lamp fragment sent as an extra: plain bot lit, stealthy one dark, night-vision one dark; the dark one shot at lights up; withdrawn, lamps go out; a malformed extra is said once and skipped.
- **with no night settings a night world is played exactly as day**: 20 s, 8 bots, 0 intents differ.
- 500 characters, one situation (hurt, two men in sight, a call for help): fight 160, investigate 153, follow the caller 118, retreat 62, grenade 4, roam 2.
- **replay: 1500 thinks, 8 bots, a fresh engine fed the recorded events and worlds writes identical intents (0 differ).**
- items: a hurt bot uses its medkit and a healthy one does not; count 0 never tries; "inf" keeps using (7 in 20 s); the tree withdrawn, no more; a malformed item tree is said (item, line in ITS text) and skipped; greed 21 uses against 4 in 40 s; a missile is used with a man in sight under open sky, the head stays within 12 degrees of him for the 4 s of guide time (195 of 195 ticks) while the bot keeps moving; under a roof it is not used.
- settings: archetypes arriving after the bots re-draw the characters; cull, zone, protect, night.cone, per-bot edit, a gamemode's own key; a world for another map stops the bots.

### Think cost (M-series laptop, -O2; `bc_engine_think` wall time)

The host calls think 60 times a second; the server writes 30 worlds. A
call with a world already seen only repeats intents (well under 1 us), so
"a call" below averages the two; a call with a NEW world costs about twice it.

| scene | bots | us a call | us with a new world | worst call | expansions at most in a think |
|---|---|---|---|---|---|
| flat field with walls, 60 s, respawning | 12 | 75 | ~150 | 1387 | 3000 (the budget) |
| the same | 32 | 130 | ~260 | 1386 | 3000 |
| real maps (8, see below), 90 s | 12 | 65 to 446 | ~130 to ~890 | 2243 | 3000 |

The budget (3000 expansions a think, botd's default) is never exceeded.
What is NOT measured: how long a bot waits for a route on a real map
when twelve ask at once (a 50 000-expansion plan alone is 17 thinks,
0.28 s; shared, more), and anything on the container's CPU.

### Real maps (`BC_TEST_MAPS=dir build/tests/engine_test`; not in `make test`)

12 bots (tdm), 90 s, respawning, two spawns 120 apart, no editing:

| map | kills | stuck events | longest hold | plans (failed) |
|---|---|---|---|---|
| Parkour2 | 38 | **2** | 4.9 s | 784 (0) |
| shot0 | 30 | 0 | 2.6 s | 823 (23) |
| Temple | 28 | 0 | 1.8 s | 701 (0) |
| 2FortCTF | 17 | 0 | 2.2 s | 294 (91) |
| CubeMaze | 61 | 0 | 0.9 s | 852 (11) |
| BigPineTree | 46 | 0 | 0.9 s | 639 (113) |
| ClockTownarena | 28 | 0 | 3.0 s | 666 (130) |
| Pyeongyang | **3** | 0 | 1.8 s | 558 (**467**) |

Bots fight on all of them. Pyeongyang is the bad one: the two spawns I
picked cannot reach each other without editing, so nearly every plan
fails and each failure floods the pool (7.3 M expansions in 90 s) --
open item 1.

## (c) Linux

The whole suite was run on the final state in `alpine:3` for
`linux/amd64` (GCC, emulated), with `make B=/tmp/b test`: no warning,
every test green -- `senses_test` 529, `skills_test` 63, `engine_test`
154 -- with the same scenario numbers as on macOS (the 6 v 6 ends 3-6
after 9 s on both, the replay and the night-as-day comparison differ in
0 intents). Think cost there, emulated, for what it is worth: 170 us a
call for 12 bots, 311 us for 32, worst call 4.1 ms. Nothing in these
tests depends on wall time; the randomness is the bots' own.

## (d) WHAT THE SERVER MUST SEND (BL_EV_SET, "key=value")

`*` = may be sent for one bot (pid) as well as for everybody.

| key | value | meaning |
|---|---|---|
| `tree` * | a name, or the text of trees | default "default". An unknown name runs "default" (one level-1 line). A value with a newline is tree TEXT, compiled beside the built-in ones; its first tree is the one run. |
| `item.<name>` * | a count, or `inf` | what the bot holds. Send it whenever the count changes, `0` when gone. Sent for everybody it sets every bot. The engine counts one off itself when it asks to use one, until told. `<name>` up to 15 characters. |
| `item.<name>.tree` | tree text, or empty | the item's own decision; empty withdraws. Newlines as newlines; any consistent indent (tab, 2 or 4 spaces). Several root lines are a sequence. The engine puts `if has_item <name>` in front. A record is 1024 bytes at most, so about 1000 for the text. |
| `item.<name>.guide` | seconds | after `do use <name> enemy`, the head is kept on that man for this long (default 0). Also the action's third argument. |
| `extra.<name>.tree` | tree text, or empty | a script's addition to every bot, ticked at every decision; empty withdraws. Extras run in name order, each whatever the others answer. Keep to actions that end at once. |
| `night_vision` * | `0` / `1` | the bot sees by night as by day. |
| `night.sight` | `0` / `1` | the three rows of night sight hold (default 0: a night world is seen as day). |
| `night.cone` | degrees, whole angle | a lamp's cone (default 90, lib_flashlight's flashlight_cone). |
| `night.reach` | voxels | how far a lamp lights (default 60, flashlight_reach). |
| `night.far` | voxels | how far night vision sees a LIT lamp (default 192). |
| `cull` | `voxlap` / `openspades` | default openspades. |
| `archetypes` | `camper:2,pusher:3,...` | the mix; may arrive after the bots (characters are drawn again from the same seeds). |
| `edit` * | `none` / `dig` / `build` / `all` | what routes may do to the map (default none). |
| `spend` | n | blocks a route may use (50). |
| `water` | `lethal` / `safe` | |
| `zone` | `x0 y0 x1 y1 [nodig] [nobuild]`, or `clear` | a rectangle routes do not edit (both when neither is said). 32 at most. |
| `protect` | `x y z` | a voxel the server will refuse. |
| `sight` `fov` `notice` `memory` `relay` `board` `noise_secs` | numbers | the senses (senses.h has the defaults). |
| `ping_takers`, `ping_radius` | 2, 40 | who answers a ping. |
| anything else | | kept (64 keys) for a tree's `if setting <key> [value]`; one level-1 line the first time. A key the engine does not know sent for ONE bot is dropped silently. |

What a bot asks of the server for an item: `BL_AC_COMMAND` with
`inv <name>` or `inv <name> <x> <y> <z>` (one decimal each).

The pings bots make: `"Enemy"` at the enemy, `"Sniper"` at where a far
hit came from, `"Need help"` at themselves (tdm's own ping list has no
"Need help"; lib_botlink passes an unknown label through as text).

The words the vocabulary gives an item's or an extra's fragment are in
`core/vocab.h`; for items in particular: `has_item`, `health_below`,
`ammo_below`, `enemy_visible`, `enemy_within`, `enemy_beyond`,
`enemies_grouped <count> <radius>`, `sky_clear`, `allies_hurt_near`,
`is_night`, `target_in_cover`, and `do use <name> [self|enemy|group|<place>] [guide secs]`.

### The lamp fragment, for the server's night script, verbatim

Send it as `extra.night.tree=` followed by this (tabs, real newlines),
with `night.sight=1` and the cone and reach:

```
pick noise=0
	option none night_vision x10
		do lamp off
	option none hit_in_dark x10
		do lamp on
	option stealth night
		do lamp off
	option none night x1.2
		do lamp on
```

It reads: a bot with night vision stays dark; one shot at in the dark (no
night vision, hit in the last 8 s) lights up; otherwise the stealthy
(stealth weight over 1.2) stay dark and listen, the others light their
lamp. `noise=0` matters: the actions end at once, so the pick chooses
again at every decision, and with luck in it the lamp would flicker. By
day no option scores and the lamp is out (the engine never lights one by
day, and never at all unless a tree says `do lamp on`).

## (e) Open, most important first

1. **Goals that cannot be reached cost the most and are asked for again.**
   A failed plan floods up to the pool (131 072 nodes); the goal is then
   left alone 5 s (20 s after a GIVE_UP), but roam and the chase pick
   new unreachable ones. Wanted: a memory of unreachable REGIONS (a
   cheap flood-fill of connected floor, redone when the map changes), so
   such a goal is never planned at all. Pyeongyang above is the case.
2. **Stuck on Parkour2: 2 events in 90 s (4.9 s).** The net under
   everything (keys down, under 0.75 voxels moved in 2.5 s) fired 3
   times there and let go; untraced whether it is the follower or
   strafing against something.
3. **The head while walking a route is the follower's, exactly** (nav.h:
   its facing "is not a suggestion"), so on a route with nothing to look
   at the head turns as the follower steers, not as a person's would.
   With a target the aim model has the head and the follower's keys are
   re-expressed for it (8 ways) -- on plain steps only; on a jump, a
   drop, an edit the bot does not aim or fire. See "needed from others".
4. **A pick's `every` is its reaction time.** Mitigated with jolts
   (brain.h): an enemy coming into sight, a hit from nowhere, an order,
   a ping taken, a grenade make the tree be entered afresh. It is a
   `bt_reset`, which also clears any `cooldown` in the tree.
5. **Never run on a real server**: the trigger timing against lib_bot's
   recoil climb, the JUMP key seen for two server ticks, the 30 Hz world
   against the follower's tick-counted timeouts (they last twice as long
   in seconds as nav's tests assume), `inv` commands, pings through
   Teamplay -- all unproven.
6. `BL_AC_LINE` is written (a straight run of single-block bridge steps
   whose far end touches something) and **never taken in any test**: the
   bridge test bridges 4 blocks and jumps. Unverified code.
7. Not done at all: sights (secondary fire), sneaking (the stealth trait
   only decides the lamp), anything for the intel beyond `go_to
   enemy_intel`, the builder trait (no fortifying), footsteps beyond the
   notice radius (`BL_S_STEP` is handled if the server ever sends it).
8. Retreat finds cover within 20 voxels by sampling 64 places; nothing
   cleverer. A bot at low health peeks, retreats, peeks (6 s apart).
9. A setting unknown to the engine sent for one bot is dropped without a
   line. Per-bot tree TEXT replaces the one custom forest for everybody.
10. `tests/brain_sim.h` flies grenades with the engine's own
    `bc_grenade_fly`: the throw test cannot catch a flight that is wrong
    on both sides.

## (f) Needed from others

- **bt.h** -- (1) no way to tick something BESIDE a running branch: hence
  the `<name>_also` convention (engine.c ticks it before the main tree).
  A `parallel`/`also` node would make it the tree's own. (2) no way to
  tell a pick "choose now": hence jolts by `bt_reset`. (3) a pick whose
  chosen option fails at once FAILS without trying the next best, and
  chooses the same again next tick: every option's score must be 0 when
  its action cannot be done, and the shipped trees end in `limit 1 / do
  roam` as a net. Worth a line in bt.h; it is the first thing a tree
  author will trip on.
- **botlink.h / lib_botlink** -- the world lacks: a reload in progress
  (the engine assumes 2.5 s, 0.5 s a shotgun shell); what a bot holds
  and whether it has night vision (settings instead, see (d)); other
  players' blocks and grenades are 0. A refused action is never said:
  a refused dig is learned only by the follower's 180 ticks of waiting
  (6 s at 30 worlds a second). The spade's swing digs what it meets when
  it meets no man, so a spade fight eats walls -- the engine holds the
  trigger off unless within 3.3 and on target, which is all it can do.
- **nav.h** -- a flag in `bc_nav_cmd` saying "the head is free this
  tick" would replace my guess (free on WALK / SPRINT / CROUCH steps
  with no edit), and a facing the follower could be given would let a
  person's turn replace the snap. Its tick-counted limits assume 60
  ticks a second; here it is ticked once a world (30).
- **lsd_core.h** says body.c and map.c are its only users: `senses.c`
  now calls `bc_lsd_cast_ray` (the server's own ray, on purpose).
- **engine.h** -- nothing must change. Two things would help a host:
  `bc_vocab_dump` is in vocab.h (the host would include a core header
  beyond engine.h to list the vocabulary), and the internal counters
  (`bc_engine_stats_get`, brain.h) have no public door.

## (g) Traps

- `tree items` and `tree extras` exist only because the engine appends
  them to every text it compiles. A text that defines its own is left
  alone.
- Tree files are concatenated by botd: helper trees need names unique
  across files (`tdm_callouts`, not `callouts`).
- A fragment's actions must end at once in `extras` and in `_also`: a
  RUNNING one holds the seq there and the rest is not ticked.
- `do lamp` in a pick needs `noise=0` (see the fragment above).
- The wishes are wiped at each decision and re-stated by whatever the
  tree runs; the ROUTE is not: `bc_move_to` with the same place goes on,
  which is what makes a tree re-entered by a jolt seamless. A skill that
  wants a moving place must reuse `b->wish.goal` while the place is near
  it (go_to, follow, the chase do), or it plans every decision.
- The persona is drawn from its own stream of the seed so it can be
  drawn again when `archetypes` arrives after the bot; the thinking
  stream is another. The style draws happen at each new life.
- A bot told again with the same seed, level and gun is left alone
  (lib_botlink re-announces after every map); a different seed is a new bot.
- Crouch is only changed on the ground, and only up where there is room
  (body.h); the engine enforces it for the skills, the follower for itself.
- The aim model is given its own last output as "the body's orientation"
  (the world's is a tick or two old and would look like a teleport).
- `hurt_in_fight` is 0 for 6 s after a retreat ends, or a hurt careful
  bot would do nothing but retreat.
