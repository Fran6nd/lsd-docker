# The brain: senses, skills, vocabulary, engine, trees -- where it stands

The handover for whoever continues. State of 2026-11-25 ("CHECKPOINT
final"). `make -C bot test` builds with no warning and every test passes
on macOS arm64 (Apple clang 17). **Not re-run on Linux since the first
version** (which passed on Alpine x86-64); nothing added depends on the
platform, but it has not been checked.

Everything below was measured on `tests/brain_sim.h`, a server written
from reading `lib_botlink.lua`, `lib_bot.lua` and `ctf.lua`. The engine
also runs live (40 bots on the demo); what was seen there is said where
it bears.

## (a) What exists

| file | what it is |
|---|---|
| `core/senses.{h,c}` | What ONE bot knows: sight (the head's cone), night's three rows, memory, hearing, where a hit came from, alertness, the team's board. New: BEING SHOT AT (`shot_at`, `fire_since`): hurt, a round passing within 2.5, a mate killed within 12. |
| `core/brain.h` | PRIVATE: the bot, the engine, the wishes, the mover, and every skill's memory. |
| `core/engine.c` | engine.h. Settings, events, the trees (built-in, custom, ONE BOT'S OWN), the items and extras trees, the think loop, **the net under a stuck body**, waiting for a route, shut in. Its header is the documentation of all of these. |
| `core/skill_move.c` | One goal a bot, the shared searches, the follower obeyed; capped and greedy searches; the team's memory of no way; shut in; roam goals. |
| `core/skill_look.c` | The head while travelling: ahead along the route, glances. |
| `core/skill_cover.c` | The cover query (a budgeted flood); crouch, take_cover, advance_by_cover, fall_back_by_cover. |
| `core/skill_tactics.c` | seek, flank, hunt_noise, perches (take_high_ground, camp), leave_water, the unreachable memory. |
| `core/skill_objective.c` | The two intels and the bases: fetch, carry_home, escort, intercept, guard. Its header has the server's rules as read. |
| `core/skill_squad.c` | Leaders drawn by lot, followers, `follow leader`. |
| `core/skill_fight.c`, `skill_grenade.c`, `skill_misc.c` | As before (fight, grenades; go_to, investigate, roam, follow, hold, retreat, ping, use, lamp, obey). |
| `core/vocab.{h,c}` | THE vocabulary: 129 words, one table, one line each; vocab.h's lists are the table's, word for word. `bttree --words` prints it. |
| `trees/tdm.bt`, `ctf.bt`, `default.bt` | The shipped trees. `trees/parkour.bt` exists too (another agent's; existing words only: evade / leave_water / obey / go_to own_base). Each compiles alone. |
| `tests/brain_sim.h` | The simulated server, now with water that hurts and ctf.lua's intel rules. |
| `tests/bench.c` | THE BENCH (section (c)). Not a test. |

Tests, and what each is for (checks): `senses_test` 529, `skills_test`
63 (one skill at a time), `engine_test` 185 (the whole engine: teams,
pings, night, items, a bot's own tree, traits=, replay, cost),
`behaviour_test` 38 (the head, cover under fire, the net, water, waiting
for routes, a maze, a dig from the water), `tactics_test` 47 (flank,
hunt_noise, high ground, bounds by cover, the unreachable memory, shut
in, the split, 20 v 20), `squad_test` 15 (leaders), `ctf_test` 25 (a lone capture, 6 a side, the carrier, the thief, the split, replay),
`botd_test` 72 (the host, with the operator's trees).

## (b) What a bot does now, with its numbers

**The head while travelling: on the heading first** (skill_look.c,
2026-11-25, the owner's "look where they are headed"). The follower's
facing, turned to as a head turns (no reaction delay at each corner);
glances every 4.5 to 9 s (0.6 of that when alert), short (reaction, the
turn there, 0.25 to 0.55 s), at a place worth a look, an opening beside,
rarely over a shoulder. Travelling time with the head within 30 degrees
of the way it goes: 48 to 90% across the bench's scenes (was 22 to 72%).
24 bots walking past a still man in a corner behind their route: 0 see
him with the head locked to the steering (`gaze=0`), 8 with their own
(was 19 before heading-first), 20 of 24 once he makes a noise. WALKED UP
ON: a man kept 10 voxels behind a travelling bot for 20 s -- sneaking, 8
of 12 bots know of him, after 9 s on average (14.9 the longest; only the
glances over a shoulder find him); sprinting, 12 of 12 at once (a
sprinter's feet are heard at 12, half as far again as a walker's 8 --
added for this). On a jump or a drop with a man in sight the head stays on
him (22 of 30 ticks in the air).

**Shot at**: down in 0.07 s (`crouch`), then by character: fight back,
cover IN VIEW or face him, `fall_back_by_cover` (out of his sight in 3.5
s). The shipped trees: `if cover_in_view` / `do take_cover in_view`, else
`do crouch 3` -- nobody turns his back to look for cover. Cover only behind
it: head on the shooter 210 of 210 ticks, does not move back; cover ahead
to the side: in it at rest 2.1 s after the hit, the head within 45 degrees
of the shooter on 61 of 61 moving ticks; hit from behind by a man unseen:
turned to him in 1.0 s having moved 0.0, then into cover in view.
`take_cover` (any direction) is still a word: at rest behind a wall 6
voxels behind 3.4 s after the hit, backing to it with the head on him.
`advance_by_cover` crosses 84 voxels a man watches in his sight 4.9 s
against 11.1 s straight.

**With nobody in sight** (tdm): 200 characters with a perch free, a
rumour and a leader about: flank 43, hunt_noise 31, take_high_ground 16,
follow 54, seek 56; rifles go high 12, shotguns 0. `seek` (the
ENEMY'S BASE) is the last resort; roam only in a world with no bases or
no way to his. flank: 8 of 8 arrive, none nearer than 35 voxels to the
direct line in the middle, all from beyond the base, left 4, right 4.
Perches: two rifles take one each; a third gets none; shot at, it leaves.

**Leaders** (skill_squad.c): one for every `leaders.per` members (5),
bots and people alike, nobody told. Ten a team: 2 leaders each, 11
followers, none of the loners. A person chosen walks 62 voxels: 4 of 5
bots within 10 of him, never in front of his gun; they take the man he
fires at (5 of 5); when he stops they take cover near him (2 of 4 out of
sight, 0 before); killed, nobody waits; a leader who stays put is left
(10 s + 15 x teamwork).

**ctf** (trees/ctf.bt): a lone bot picks up after 11 s and captures after
23 s. The carrier fires 0 rounds at a harmless man 20 off its line. Our
intel taken: 4 of 5 go for the thief, all 5 are soon heading for a place
AHEAD of him; he is
dead in 8 s, and exactly 2 of 5 then stand guard over the intel where it
fell (nobody of ours can pick it up) while the other three get on with
the game. Ten a side, four games of 300 s (the bench): **9 captures,
every game has one, the first after 122 s on average.** HOW MUCH OF THAT
IS THE TREE: with each intel right beside its base (where the first tests
put it) the first tree made 1 capture in four games, this one makes 5 (in
3 of the 4 games); putting the intels 5 to 40 voxels out toward the
middle -- where the server's random placing has them (ctf.lua: x 64..127
with the tent at 72) -- makes it 9. So: the tree about five-fold on the
hard layout, the layout nearly two-fold more. What changed in the tree:
two guards at most, at home (`unguarded`, weighed by caution) or over a
dropped intel (whoever they are); a man far off is not worth stopping
for; the keen run on for the intel under fire; flankers break away round
the side; squads follow their leader into the fight. The test's own 6 a
side game reaches its first capture after 159 s (it has swung between 73
and 416 s as the trees and characters were tuned: one game is not a
measure, the bench's four are).

**Never stuck, never waiting** (engine.c's header has both in full):
- THE NET: 1.5 s pushing -> a jump; 1.5 more -> a step back, a sidestep
  with a jump, a new plan with the failed move priced; 1.5 more -> the
  goal is dropped, remembered as unreachable (team, 30 s), the tree
  entered afresh, 4 s somewhere else. Also 8 s on a route inside a
  4-voxel circle. One level-1 line a bot a minute. 6 bots wading at a
  bank the server has a voxel higher than the engine knows: longest in
  one cell with keys down 1.5 s.
- WAITING FOR A ROUTE (the live "frozen after a map change"): searches
  stop at `plan.cap` (8000) and the partial route is walked; they are
  greedy (`plan.greed` 1.5; 4 from or into water); a bot whose route is
  being searched walks at the goal meanwhile. Two islands in a sea, 40
  bots: as it was 6 of 40 hold a key 7 s after the start and 74% of the
  time is spent waiting; now 39 of 40 and 0.4%.
- SHUT IN: three searches in a row with no way, and no route is asked
  for 15 s; the bot paces and looks about. In a box with no door: 13
  searches a minute, never idle over 0.2 s; with `edit=dig` it digs out.
- WATER: `leave_water` above all but a grenade when the water hurts (6
  bots at 10 health a second: dry in 3.4 s, none dies); nobody takes
  cover, ducks or falls back in the sea; a dig asked for from the water
  works.

**A tree for one bot, traits, the operator's trees**: `tree=` for one
pid may be a name or TEXT of its own (kept for it alone, replaced in
play, freed with the bot; the RUNNING action is told to stop exactly
once; `leaks` finds none). `traits=aggression:2,caution:0.5` multiplies
on top of each bot's roll (200 bots hit with a man in sight: 123 fight
on, 184, and 33 with the opposite). botd loads `$LSD_DATA/trees/*.bt`
after the built-in ones, a same-named tree replacing the built-in, read
again at every map; run once for real: an operator's `tdm.bt` replaced
tdm, his `mine.bt` used a built-in helper tree, his `bad.bt` was said
("line 3: no action called no_such_thing (skipped)").

**Characters** (persona.c, changed here): the spreads went from 0.15 /
0.20 / 0.25 to 0.25 / 0.30 / 0.40 (soldier / a trait / an archetype's own
trait). With a perch free, a rumour and a leader: pushers seek 86% (was
95), supports follow 83% (96), flankers flank 76% (83), scouts hunt 55%
(68) -- and campers with a rifle still take the perch 95% (98): their
marksman centre is 1.8 and nothing else of theirs is near it. The
centres were not touched (persona_test pins them).

## (c) THE BENCH (`tests/bench.c`): the numbers a change is judged by

```
make -C bot build/tests/bench                  # (no `bench` target: the Makefile is not this agent's)
bot/build/tests/bench                          # every built-in scene, about 5 minutes
bot/build/tests/bench arena40 sea40            # those scenes
bot/build/tests/bench ctf:10 ctfnear:10
bot/build/tests/bench map:/path/prisonbreakv1.vxl 120
bot/build/tests/bench > before.txt ; ...change... ; bot/build/tests/bench > after.txt ; diff before.txt after.txt
```

One line a metric, `<scene> <metric> <value> <unit>`; everything but the
`think_*` lines is the same on every machine and run. bench.c's header
lists the scenes and metrics. **Run it from `bot/`** (it reads `trees/`;
elsewhere it says "trees: not found" and runs the built-in fallback tree)
and **rebuild it after any change to the words** (a tree naming a word the
binary lacks does not compile, and the fallback runs). THE BASELINE,
re-run 2026-11-25 after step B (heading-first head, cover in view,
sprinters heard at 12), M-series laptop, -O2; think is per call of
`bc_engine_think`; "head on" is the share of travelling time (moving, no
enemy in sight, not shot at for 3 s) with the head within 30 degrees of
the way the body goes, "away" the spells over 1 s with it over 60 off:

| scene | think mean us | worst us | no key % | waiting % | longest idle s | wading % | head on % | away | plans | capped | no way | exp / plan | kills | stuck | goals dropped | result s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| arena12 | 41.6 | 1068 | 16.9 | 0.0 | 3.9 | 0 | 71.1 | 1 | 610 | 4 | 0 | 441 | 36 | 0 | 0 | |
| arena32 | 82.5 | 1247 | 22.1 | 0.1 | 7.5 | 0 | 56.3 | 0 | 1222 | 0 | 0 | 170 | 82 | 0 | 0 | |
| arena40 | 118.9 | 1368 | 20.7 | 0.1 | 6.1 | 0 | 48.4 | 0 | 1489 | 4 | 0 | 194 | 91 | 0 | 0 | |
| fight6 | 23.4 | 987 | 10.8 | 0 | 1.5 | 0 | 77.5 | 0 | 139 | 0 | 0 | 97 | 8 | 0 | 0 | 13.7 |
| fight20 | 78.3 | 1220 | 22.8 | 0.0 | 6.0 | 0 | 69.5 | 0 | 720 | 1 | 0 | 152 | 33 | 0 | 0 | 30.0 |
| sea40 | 283.5 | 1394 | 11.0 | 0.7 | 13.2 | 14.2 | 89.9 | 2 | 983 | 242 | 0 | 2375 | 20 | 0 | 0 | |
| map:prisonbreakv1 | 367.4 | 2417 | 12.9 | 2.3 | 11.5 | 49.1 | 88.0 | 12 | 2185 | 610 | 26 | 3575 | 51 | 0 | 1 | |
| map:spud | 289.3 | 2405 | 13.3 | 1.2 | 8.1 | 0 | 82.3 | 6 | 2488 | 161 | 320 | 1683 | 80 | 0 | 1 | |
| map:Temple | 433.3 | 2309 | 19.9 | 0.8 | 10.4 | 0 | 82.1 | 6 | 2632 | 250 | 7 | 2109 | 77 | 0 | 0 | |
| map:CubeMaze | 389.3 | 1298 | 12.1 | 7.6 | 5.9 | 0 | 73.2 | 104 | 1516 | 518 | 513 | 5637 | 6 | 0 | 0 | |

("no key" includes holding in cover, camping and standing by a leader.
The real maps are not in the repo; `map:` takes a path. Before step B, the
same HEAD gave head on 22 to 47% in the built-in scenes (arena12 35,
arena32 22, arena40 33, fight6 44, fight20 43, sea40 72, ctf:10 47) and
388 spells away in ctf:10; the older table that stood here (2026-11-25,
"CHECKPOINT final") no longer matched HEAD before step B -- the sniper
role and the bridge had moved it.)

| scene | captures in 4 games | games with one | first, mean s | pickups | drops | kills | stuck | think mean us | head on % | away |
|---|---|---|---|---|---|---|---|---|---|---|
| ctf:10 | 4 | 2 of 4 | 50 | 24 | 19 | 739 | 0 | 74 | 76.6 | 62 |
| ctfnear:10 (each intel beside its base) | 8 | 3 of 4 | 51 | 28 | 20 | 696 | 0 | 68 | 76.7 | 73 |

(ctf:10 was 9 captures in the "CHECKPOINT final" table and 4 in 3 games
at HEAD before step B: the trees changed since (the sniper role). Item 13,
the sniper scenario, is where the ctf game is looked at again.)

## (d) WHAT THE SERVER MAY SEND (BL_EV_SET, "key=value")

`*` = may be sent for one bot (pid) as well as for everybody. engine.c's
header is the full list; new since the first version in **bold**.

| key | value | meaning |
|---|---|---|
| `tree` * | a name, or the text of trees | default "default". For everybody: an unknown name runs "default"; a value with a newline is tree TEXT compiled beside the built-in ones. **For one bot the text is that bot's own**; empty gives it back the world's tree; a text that does not compile changes nothing and is said with its line. |
| **`traits`** * | `aggression:2,caution:0.5` | each named trait multiplied, on top of each bot's roll, within 0.2 to 3; the two levels multiply; empty clears. |
| `archetypes` | `camper:2,pusher:3,...` | the mix; may arrive after the bots. |
| `item.<name>` *, `item.<name>.tree`, `item.<name>.guide`, `extra.<name>.tree` | | as before (an item's count, its own decision, its guide time; a script's addition to every bot). |
| `night_vision` *, `night.sight`, `night.cone`, `night.reach`, `night.far` | | as before. |
| `edit` * | `none` / `dig` / `build` / `all` | what routes may do to the map. |
| `spend`, `zone`, `protect`, `cull` | | as before. |
| `water` | `lethal` / `safe` | |
| **`water.damage`** | health a second | water that hurts: priced in routes by nav, and `leave_water` comes first. Lethal for routes at 30 or more, or when `water=lethal` and no damage is said. |
| **`leaders.per`** | n | one leader for every n of a team (5; 0: none). |
| **`leaders.human`** | weight | a person's weight in the draw, a bot's being about 1 (2). |
| **`gaze`** | `0` / `1` | 0: heads follow the steering, as before (1). |
| **`plan.cap`** | expansions | a search stops there and the partial route is walked (8000; 0: none). |
| **`plan.greed`** | factor | nav's `h_weight` (1.5; 1: exact searches, water as land). |
| **`plan.wait`** | `walk` / `stand` | what a bot does while its route is searched (walk). |
| `sight` `fov` `notice` `memory` `relay` `board` `noise_secs`, `ping_takers`, `ping_radius` | | as before. |
| anything else | | kept for a tree's `if setting <key> [value]`. |

botd: `--user-trees DIR` (default `$LSD_DATA/trees`, LSD_DATA: /data).

### The lamp fragment, for the server's night script

```
pick noise=0
	option none night_vision x10
		do lamp off
	option none hit_in_dark x10
		do lamp on
	option none quiet 25 x5
		do lamp on
	option stealth night
		do lamp off
	option none night x1.2
		do lamp on
```

The `quiet 25` line is new and is in the server's script (the
coordinator added it): without it two stealthy bots with no night vision
stay blind for good and a night game may never end (seen: 240 s, 1
against 5, nobody seeing anybody).

## (e) The vocabulary added (all neutral; vocab.h has every word)

- 2026-11-25: numbers that were fixed are arguments now, same defaults
  (DECISIONS.md, "Done in this step"): `camp [secs] [kills]`, `retreat
  [secs]`, `sniped [voxels] [secs]`, `outnumbered [radius]`,
  `target_in_cover [secs]`, `spotted_new [secs]`, `allies_hurt_near
  <radius> [hp]`, `carry_home [voxels]`. What still decides WHAT in C,
  and the plan for each: DECISIONS.md.

- shot at, cover: `under_fire`, `in_cover`, `pressed`, `standoff`,
  `enemy_far`; `crouch`, `take_cover`, `advance_by_cover`,
  `fall_back_by_cover`.
- nothing in sight: `flank_open`, `rumour`, `vantage [guns]`, `gun_is`,
  `mate_near`, `quiet`; `seek`, `flank`, `hunt_noise`,
  `take_high_ground`, `camp`.
- water: `in_harmful_water`, `harmful_water`; `leave_water`.
- the intels and bases: `carrying_intel`, `their_intel_home` /
  `_dropped` / `_carried`, `our_intel_home` / `_dropped` / `_taken`,
  `near_own_base`, `near_their_base`, `mates_near`, `unwatched`,
  `watched`, `unguarded [place] [radius] [count] [dropped]`; `fetch`,
  `carry_home`, `escort`, `intercept`, `guard`.
- leaders: `is_leader`, `has_leader`, `leader_near`, `leader_fighting`;
  `follow leader`.
- places: `enemy_area`, `rumour`, `vantage`, `leader`, `their_base`,
  `their_intel`, `our_intel`, `thief`, `carrier`, `intercept`.

## (f) The server's ctf rules, as read (2026-11-24: lsd/scripts/ctf.lua, catalog/overrides/lib_ctf.lua, lib_bot.lua, lsd/src/main.c)

A bot needs nothing special. The pickup loop is over every connected
player and `bot_create` connects its bot. Pickup: the first living player
of the OTHER team within 3 across of an intel on the ground (eye 4 above
to 1 below). Capture: carrying it within the same cylinder of one's OWN
tent; the intel then goes to a random place on its owners' side. Death
drops it where the carrier stood (`after_player_destroy`), and for 2 s
after any drop nobody picks up anything. A team can never touch its own
intel: a dropped one of ours can only be guarded. brain_sim.h plays
these rules.

## (g) Open, most important first

1. **Two equal teams of bots still mostly hold each other.** In the ctf
   game team 1's men were on their own third of the field most of the
   time; captures come from squads and flankers getting through, 9 in 20
   minutes of 10 a side. Whether that reads as a game on the demo is the
   owner's to judge.
2. **CubeMaze (real map, arbitrary spawns): the two teams never met** (0
   kills in 120 s, 490 of 1298 plans finding no way, 9% of the time
   waiting). Shut-in bots now pace instead of standing, but a bot that
   CAN move and whose every goal is unreachable is not helped. Not
   understood further; the spawns may simply be in closed cubes.
3. **prisonbreakv1: half the bot-time is wading** (50.8% with bases at
   the dry ground nearest 128,256 and 384,256; the real tents were never
   given). Probably the map. Fights in water have no scenario.
4. **Campers camp** (95% of those with a rifle and a free perch): see
   (b), characters. Only the centres can change that.
5. The long search (five caps) that follows capped routes getting no
   nearer has no scenario; the maze scenario did not need it.
6. Kills a minute are lower than before this work (cover, standing off):
   arena40 79 in 60 s against 170. Whether fights are too passive is a
   matter of taste to settle on the demo.
7. A glance drops the sprint while the head is turned (a body cannot run
   sideways): travelling bots are a little slower.
8. Never done: sights (secondary fire), sneaking, the builder trait
   (no fortifying), footsteps beyond the notice radius, `BL_AC_LINE` in
   any test.
9. Followers take cover when their leader stops, but do not peek from
   it; "whoever hurt the leader becomes the target" is wired and has no
   scenario.
10. `guard` picks a spot by the bot's own bearing, not by cover or
    height; `camp` is used for the perches.
11. An AddressSanitizer run of the tests was not possible on this macOS
    (ASan hangs at process start, before our code); `leaks --atExit` on
    engine_test reports none.

## (h) Needed from others

- **bt.h** -- (1) no way to tick something BESIDE a running branch: hence
  `<name>_also`. (2) no way to tell a pick "choose now": hence jolts by
  `bt_reset`, which also clears every cooldown and re-draws every pick --
  a bot's standing choice (flank, camp) is drawn again after each fight.
  A "re-choose this pick only" would be better. (3) a pick whose chosen
  option fails at once FAILS without trying the next best: every
  option's score must be 0 when its action cannot be done.
- **nav.h** -- a flag in `bc_nav_cmd` saying "the facing is free this
  tick" (and for how many ticks) would replace skill_look.c's guess from
  the route (plain strides over cells with nothing to fall off). One
  field was ADDED to nav by this agent: `bc_nav_policy.h_weight`
  (NAV-STATUS.md says so).
- **botlink / lib_botlink** -- the world lacks a reload in progress,
  other players' blocks and grenades; a refused action is never said.
- **bot/Makefile** -- a `bench` target (`$(B)/tests/bench` builds by the
  generic rule; it is only not named).
- **persona.c** was this agent's to change: spreads only (see (b)).

## (i) Traps

- `tree items` and `tree extras` exist only because the engine appends
  them to every text it compiles; a text that defines its own is left
  alone. Tree files are concatenated by botd: helper trees need names
  unique across files (`tdm_callouts`, `ctf_net`).
- A fragment's actions must end at once in `extras` and in `_also`.
- **A select remembers where it was**: a net at the bottom of a tree must
  be `limit 1` so the pick above is looked at again each second. The top
  of tdm.bt and ctf.bt is therefore ONE pick with trait `none` and
  factors far apart (a priority list looked at every second), and the
  weighed choices are the subtrees under it.
- The wishes are wiped at each decision; the ROUTE is not. A skill that
  wants a moving place must keep the goal in hand while the place is near
  it (15% of the way, for a man), or it plans every decision.
- **A tree entered afresh (a jolt) calls every RUNNING action's stop.**
  Cover and bounds keep what they were at for a second (they are asked
  again at once); flank starts over but keeps its side for a minute.
- **A cover search is not begun again because the bot moved** (it never
  finished while walking); only for another threat, purpose, or 6 voxels.
- The unreachable memory is keyed on where the bot SET OUT from, not on
  the dead end its partial routes led to.
- A per-bot tree TEXT in a test must be one text: two `tree=` texts for
  everybody replace each other. For one bot it is now its own.
- In the tests' arena a bot at y 256.5 does NOT see a man at x 246: a
  wall stands between (use y 264.5). "Hit with the man in sight" was not
  in sight for a long time.
- brain_sim's hit test kills with one rifle round to the head: a man who
  must stay alive needs his health put back every tick.
- The persona is drawn from its own stream of the seed (it can be drawn
  again when `archetypes` or `traits` arrives after the bot).
- Crouch is only changed on the ground; a wading body does not duck.
- `hp` in the world is a byte.
