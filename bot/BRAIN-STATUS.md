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

## (c2) SCALE: 230 bots (2026-11-25, WORK.md item 18)

**What the owner saw with "230 bots"** was not 230 bots: botd was sized
for 64 (`--bots` defaulted to 64 and the entrypoint gave none), so 166
stood still, and the server carried 230 peerless players through Lua
send paths that walked every player for every packet. Now botd is sized
for every seat (255, the default and the entrypoint's), and nothing is
built, sent or walked for a bot: one rule, lib_bot's THE PEOPLE --
`people_in(set)`, piditer without the bots, over the people kept from
connects and disconnects (no walk, no per-tick list) -- which every loop
for a client's sake uses: lib_bot's send guard and its late
send_player_update hook (no World Update built for a bot, under an
upstream command_ups), lib_player_limit, lib_edit_mode,
lib_player_properties, lib_night, lib_ext_policy, lib_headless; afkick's
override gives a bot no timer (item 19 replaced the per-tick caches and
the command_ups copy this section first described).

**Measured** on a container of its own (M-series laptop, Docker
Desktop, arm64 native, other containers running), one headless client
that speaks Player Limit connected as a spectator,
60 s a point, after 50 s of play. CPU is percent of ONE core
(/proc/<pid>/stat); tick = the server's whole tick, Lua and C
(`mod.xearly` before/after); UPS = ticks a second, min / p1 / median over
whole seconds; keys = alive bots holding a movement key at a sample,
moved = alive bots that moved over 2 voxels in 8 s. BEFORE = master at
9d7d14c (botd at 255, no send-path fix), AFTER = this branch.

ctf, prisonbreakv1, engine_bots_edit=all:

| bots | | server % | botd % | tick p50 / p99 / max ms | ticks over 25 ms a min | UPS min/p1/med | botd round mean / worst ms | keys % | moved % | client UPS min / med, gap max ms |
|---|---|---|---|---|---|---|---|---|---|---|
| 40 | before | 7.5 | 2.9 | 0.57 / 1.8 / 2.9 | 0 | 60/60/61 | 0.41 / 7.3 | 75 | 83 | 59 / 60, 26 |
| 40 | after | 6.9 | 3.9 | 0.46 / 1.7 / 2.8 | 0 | 60/60/61 | 0.56 / 10.4 | 87 | 93 | 59 / 60, 25 |
| 100 | before | 10.7 | 7.9 | 0.98 / 6.5 / 17.3 | 0 | 60/60/61 | 1.22 / 10.0 | 89 | 96 | 59 / 60, 33 |
| 100 | after | 8.6 | 9.3 | 0.70 / 2.1 / 3.8 | 0 | 60/60/61 | 1.47 / 19.6 | 87 | 95 | 60 / 60, 20 |
| 160 | before | 15.3 | 11.9 | 1.60 / 16.3 / 36.4 | 4 | 60/60/61 | 1.96 / 10.9 | 83 | 88 | 59 / 60, 52 |
| 160 | after | 10.0 | 11.4 | 0.98 / 2.8 / 37.1 | 2 | 60/60/61 | 1.85 / 24.4 | 84 | 94 | 59 / 60, 53 |
| 230 | before | 22.1 | 13.5 | 2.63 / 29.9 / 57.5 | 58 | 60/60/61 | 2.19 / 11.8 | 84 | 89 | 59 / 60, 73 |
| 230 | after | 13.2 | 15.6 | 1.35 / 4.6 / 45.9 | 1 | 60/60/61 | 2.61 / 34.9 | 81 | 90 | 59 / 60, 62 |

tdm, the generated flat map, no edits:

| bots | | server % | botd % | tick p50 / p99 / max ms | ticks over 25 ms a min | UPS min/p1/med | botd round mean / worst ms | keys % | moved % | client UPS min / med, gap max ms |
|---|---|---|---|---|---|---|---|---|---|---|
| 40 | before | 9.3 | 3.2 | 0.79 / 2.8 / 5.7 | 0 | 60/60/61 | 0.43 / 3.4 | 96 | 100 | 59 / 60, 23 |
| 40 | after | 7.5 | 2.3 | 0.56 / 1.8 / 3.1 | 0 | 60/60/61 | 0.28 / 3.9 | 93 | 99 | 59 / 60, 35 |
| 100 | before | 11.2 | 4.6 | 1.19 / 4.4 / 10.8 | 0 | 60/60/61 | 0.70 / 5.2 | 90 | 97 | 59 / 60, 26 |
| 100 | after | 9.4 | 5.2 | 0.86 / 2.5 / 4.0 | 0 | 60/60/60 | 0.80 / 5.5 | 94 | 99 | 59 / 60, 26 |
| 160 | before | 14.5 | 7.0 | 1.83 / 4.3 / 10.2 | 0 | 60/60/61 | 1.10 / 4.9 | 93 | 97 | 60 / 60, 26 |
| 160 | after | 11.6 | 7.6 | 1.21 / 3.6 / 49.4 | 1 | 60/60/61 | 1.19 / 14.2 | 89 | 98 | 59 / 60, 34 |
| 230 | before | 20.3 | 8.9 | 2.12 / 6.6 / 105 | 2 | 55/55/61 | 1.42 / 14.2 | 92 | 99 | 53 / 60, 121 |
| 230 | after | 14.3 | 9.4 | 1.58 / 6.7 / 92 | 13 | 54/54/61 | 1.48 / 30.0 | 89 | 99 | 55 / 60, 141 |

The 230 rows on the flat map each had one second at 54-55 ticks: a tick
of about 100 ms, at the same moment as botd's "stall: woke 50-70 ms
late" -- both processes were held by the host (Docker Desktop's VM, with
other containers and a build running beside), not by their own work: the
server's tick p99 is 6.7 ms. The same host effect is behind most of the
"worst" columns.

botd's rounds are its own clock (60 a second); the world comes at 30
(`botlink_world_hz`), and a bot decides at 20 in four phases, acts at
every world. Its worst round rose with the planner's budget (below) and
stays inside two periods; no "stall" line in any run above.

**What was done, and what each bought** (commits on the branch, in order):

1. botd sized for every seat: 64 -> 255 (entrypoint, botd's default; a
   bot the engine has no room for is said with the option to raise). The
   only other cap that 115 a side outgrew: a team's leaders, 8 -> 52;
   since item 19 the set holds as many as a team has players (it cannot
   overflow whatever `leaders.per`), and the live grenades the engine
   tracks are three a player (16 before, the oldest silently lost).
   botd's RSS at 255: 35-40 MB.
2. THE PLANNER'S BUDGET grows with the fleet (engine.h): a think spends
   the larger of `--budget` (3000) and each bot's share, `--plan-rate`
   (4500 expansions a second, 75 a think at 60) times the bots -- the
   same numbers as "3000 for 40 bots, more in proportion", said as the
   model it is (item 19). A fixed
   budget planned about 11 routes a second for everybody: bench map230
   (prisonbreakv1, 120 s): waiting for a route 32.7% -> 2.1% of the bots'
   time, no key 51 -> 24%, plans 1280 -> 11045, kills 130 -> 251; a think
   1.1 -> 2.8 ms (a call; the host calls twice a world), worst 4 -> 20 ms.
   Up to 40 bots nothing moves (the whole baseline above is unchanged).
3. `people_in` (lib_bot) and the overrides: command_ups built a World
   Update for EVERY player, bots included, 60 times a second (230 builds
   of a 255-entry packet a tick, each sent nowhere); afkick walked every
   player three times at each input of anybody (bots' inputs: hundreds a
   second). 230 bots + a client: server 19 -> 12.5%, tick p50 2.4 -> 1.4
   ms, p99 6.4 -> 4.1 ms; the VM's samples 2287 -> 1296 per 12 s.
4. lib_player_properties: no snapshot of every player every tick when no
   client has agreed to be told; its viewers are looked for among people.

**Where the cost is now, at 230** (LuaJIT profiler, 12 s, one client):
the C core's tick (physics for every body, core.lua:84, about a quarter),
writing the world for botd (lib_botlink.lua:866, 9%: fill_player, 12 API
calls a player), lib_ctf's per-player intel check (8%), lib_player_limit
(6%), noclip, jp, ctf, fall_damage, lib_night (1.5-5% each: per-player
tick loops upstream's, needed for bots as for people). botd on a real map
is the planner (nav_move_fits, relax, plan_step: about 90% of a think);
on a flat field, sight (bc_lsd__cast_ray: 55% of the time, 98% of a
think's own cost at arena230 -- every bot looks at every enemy in its
cone, three rays each, at 20 Hz).

**The limit on this machine**: 230 bots hold 60 ticks a second (UPS min
60 over every minute measured) with the server at 13% of a core and botd
at 16%. Neither is near a core; what limits first is the client's link:
a World Update carries every slot up to the highest living id, 24 bytes
each, 60 a second -- 5.5 KB, 324 kB/s (2.6 Mbit/s) a person at 230.
ENet sends a packet over the MTU as reliable fragments (4 a packet). A
link that cannot carry that queues: the protocol lets a client ask for
fewer (`/ups 30`, `/ups 20`: command_ups, now built for people only),
and it lets nothing smaller per packet (the update is indexed by player
id). Tried and dropped: sending it as unreliable fragments
(ENET_PACKET_FLAG_UNRELIABLE_FRAGMENT, a patch to funcs_send.c): under
netem 40 ms 1% loss the client got 51 updates a second (min 11) against
60 (min 57) reliable; 3% loss 41 against 60; 4 Mbit at 80 ms 45 against
67. Reliable is the better of the two.

**Measuring again**: `tests/bench.c` takes `arena<N>`, `ctf:<n>` and
`map<N>:<file>` up to 254 bots (BENCH_BUDGET=n: a map scene's budget,
522 at 230 being the old fixed 3000). The live harness (a probe module
through `lsdctl exec`, a CPU reader on /proc, a headless Player Limit
client in Python with pyenet: ENet connect with data 3, join as a
spectator on StateData, answer the version request as a ZeroSpades
newer than 0.1.3 and echo the ExtInfo list, then count packet 2) is
described in WORK.md's log for item 18; it is not kept in the repo.

Bench at scale, AFTER (deterministic but for think):

| scene | think mean / worst us | no key % | waiting % | head on % | plans | kills | stuck |
|---|---|---|---|---|---|---|---|
| arena100 | 449 / 3432 | 22.1 | 0.3 | 42.2 | 2992 | 193 | 0 |
| arena160 | 925 / 6037 | 21.9 | 0.5 | 26.9 | 4945 | 285 | 0 |
| arena230 | 1554 / 8652 | 25.7 | 5.1 | 47.4 | 6391 | 360 | 0 |
| map230:prisonbreakv1 | 2786 / 19754 | 24.3 | 2.1 | 82.8 | 11045 | 251 | 0 |
| ctf:115 (four games) | 1147 / 13249 | 21.7 | 5.4 | 75.2 | | 8911 | 0 |

ctf:115 makes no capture in four games of 300 s (115 a side on a pitch
made for 10: the bench's town is 150 voxels across). Not looked at here:
it is the trees' (item 13).

## (c3) PARALLEL: the route board and the planner on threads (2026-11-25, WORK.md item 20)

The owner asked: "search for optimization doable for the server:
multi threading bots? like have 4 parallel threads?" Two things were
built, both of them: ONE SEARCH FOR A TEAM GOING THE SAME WAY (the route
board, core/routes.h) and THE PLANNER ON THREADS (botd --threads,
botd/pool.h, engine.h "THE PLANNER'S WORK AS UNITS").

**Where the time goes, before** (bench, M-series laptop, load about 4 on
14 cores, quiet; think = one bc_engine_think; planner = the searches'
units, timed by the bench's runner):

| scene | think mean us | planner share of a think | what the rest is |
|---|---|---|---|
| map230:prisonbreakv1 | 3050 | 63% | decide (sight, trees), act |
| ctf:115 | 1770 | 26% | sight on a crowded town |
| arena230 (flat) | 1540 | 5% | sight: bc_lsd__cast_ray 55% of all time ((c2)) |

The server process (LSd, C and LuaJIT, one thread) was read for what
could leave its thread: little. A World Update is a 255-slot loop and a
memcpy for each PERSON (none for a bot since item 18/21), sent
uncompressed (ENet's range coder is off); the map's compression for a
joining client is OpenMP-parallel already and happens at a join; the
map file botd reads is written once a map. ENet is not thread-safe and
every send comes from Lua, so moving sends off the thread would need a
queue in front of ENet for a few percent of a tick. What costs the
server at 230 bots is Lua's per-tick work and the C physics ((c2)),
which share the Lua state: nothing to run beside it. **So: nothing on
the server; the work is in botd.**

**What repeats.** A plan log of map230 (60 s, every search's start,
goal, team and cost): 37% of the plans, holding 52% of the expansions,
were begun within 2 s of a team-mate's search to the SAME goal node from
within 16 columns (within 32: 40% / 56%; goals within 2 columns: 48% /
57%). On arena230: 15% / 12%. Estimated gain of a board: up to half the
planner's expansions on a real map; measured: 16% (a join is a search
too, and a route is handed on only under the same rules -- see
routes.h, THE SAME QUESTION).

**Candidates, estimated then measured** (map230, think mean):

| | estimate | measured | decisions |
|---|---|---|---|
| route board (plan.share=1) | planner -30 to -50% | planner -28%, think -18% (3050 -> 2500 us); expansions -16%; waiting for a route 2.8 -> 1.4% | change (they are the point) |
| planner on 4 threads | planner / 2 to / 3 (4 search slots at most, unequal units) | planner -55% (1930 -> 875 us with or without the board), think -35% (3050 -> 1975 us) | identical, think for think |
| both | | think -35% (1975 us): with 4 threads the think waits on its longest unit, which the board does not shorten; the board's gain is then CPU (fewer expansions) and routes sooner (waiting halved) | |
| 2 threads | | think 2130 us (-30%) | identical |
| sight in parallel (not built) | arena230 think -40% at 4 threads (sight 55% of it) | -- | needs a two-phase sight: the rays per bot apart, then the team board's reads and writes in bot order (senses.c writes the board as it sees) |

Measured twice each, the same within 4%; worst thinks 8.5 to 11 ms in
every setting (not the planner: the decide burst). With every bot
deciding sight-heavy on a flat field, the threads buy nothing (planner
5%).

**Determinism.** The board is engine state, read and written in the
planner's fixed order. The units of one pass of the budget get equal
shares fixed before any runs, and what they found is applied after, in
the slots' bots' order (longest waiting first); a thin budget's units go
one at a time. So: the bench's deterministic metrics are identical at 1,
2 and 4 threads (map230, arena230, ctf:115: every line but think_*);
tests/parallel_test.c hashes every intent of every think of a 20-a-side
game at 0 (no runner), 1, 2, 3 and 4 threads, board on and off, budget
shared and thin: the same hash; under ThreadSanitizer (gcc 14, Linux) it
reports nothing. With plan.share=0 the engine is master's, metric for
metric over every scene of the bench.

**The bench, board on (deterministic; before -> after, 120 s / 4 games):**

| scene | plans (own) | joins | expansions | waiting % | no key % | kills |
|---|---|---|---|---|---|---|
| map230:prisonbreakv1 | 9730 -> 8559 | 2668 | 52.8M -> 44.2M | 2.8 -> 1.4 | 24.5 -> 23.4 | 328 -> 305 |
| arena230 | 6281 -> 5703 | 510 | 821k -> 651k | 5.1 -> 5.2 | 25.7 -> 25.9 | 358 -> 372 |
| ctf:115 | | | | 5.2 -> 5.2 | 21.0 -> 21.2 | 8895 -> 8724 |
| map:CubeMaze (40) | 995 -> 998 | 71 | | 6.9 -> 4.5 | 54.5 -> 54.8 | 3 -> 3 |
| map:prisonbreakv1 (40) | 2107 -> 1880 | 322 | | 1.6 -> 2.4 | 14.2 -> 14.3 | 54 -> 53 |

The default scenes move as any change to routes moves them: ctf:10 11 ->
7 captures (4 of 4 games with one still), fight20 to the last man 30 ->
21 s, sea40 wading 14 -> 26%. arena230's head-on-heading 40 -> 18% is
not the board: at 230 on a flat field a bot is hardly ever travelling
with nobody in sight (about 600 samples in the whole run), and those on
joined routes were 79% on their heading (instrumented).

**Again after master's babel planner changes** (is_goal a disc, exact
goals; map230, 60 s, quiet): think 2945 -> 2228 us with the board (-24%)
-> 1871 us with it and 4 threads (-36%); expansions 26.6M -> 16.8M
(-37%); waiting for a route 4.2 -> 0.9%; every deterministic line the
same at 1 and 4 threads.

**Live** (a container of its own, lsd-par: ctf, prisonbreakv1,
engine_bots_edit=all; one headless Player Limit client on the Mac
against the published port; 60 s a point after 65 s of play; CPU is
percent of ONE core from /proc/<pid>/stat, botd's threads summed;
round = botd's whole round, from its health line, which now gives p50
and p99; tick = the server's, probe on mod.xearly; the machine shared
with other agents' containers, load 1.4 to 5 in the rows below):

| bots | | server % | botd % | botd round mean / p99 / worst ms | server tick p99 / max ms | server UPS min | client UPS min / med, gap max ms | keys % |
|---|---|---|---|---|---|---|---|---|
| 100 | before (share 0, 1 thread) | 8.2 | 9.7 | 1.33 / 15.7 / 23.8 | 2.05 / 4.9 | 60 | 59 / 60, 22 | 81 |
| 100 | board | 8.4 | 10.0 | 1.57 / 15.9 / 24.0 | 2.16 / 27.3 | 60 | 60 / 60, 50 | 84 |
| 100 | board + 4 threads | 8.0 | 16.1 | 1.83 / 14.3 / 31.6 | 2.02 / 5.0 | 60 | 59 / 60, 28 | 89 |
| 200 | before (two runs) | 10.8, 10.1 | 25.1, 20.4 | 2.5-3.2 / 28.5-31.4 / 42-45 | 3.4-3.5 / 5.1-5.6 | 60 | 59 / 60, 25 | 84-86 |
| 200 | board (two runs) | 9.1, 9.3 | 20.1, 21.7 | 3.1-3.3 / 27.0-28.1 / 38-40 | 2.9-3.0 / 5.2-10.7 | 60 | 59 / 60, 23-32 | 85-87 |
| 200 | board + 4 threads (two runs) | 10.1, 9.0 | 20.9, 18.4 | 2.5-2.8 / 27.7-30.2 / 36-40 | 2.8-3.3 / 5.4-6.5 | 60 | 59-60 / 60, 21-23 | 83-88 |

A third 200-bot run fell while the host was loaded (load 7 to 10: another
agent's demo container was restarting): server UPS min 46 and 37, tick max
138 and 103 ms, botd's worst round 485 and 840 ms, the client at 52
updates a second at worst -- in the board and the board + threads rows
alike, and in the server and botd AT THE SAME MOMENTS. **On the owner's
question** (do the client's dropped updates come from botd's planning
loading the VM?): not on this evidence. botd used a fifth to a quarter
of one core at 200 bots, whatever the setting; in every quiet run the
client got 59-60 updates a second with gaps under 33 ms; the drops came
only with the HOST loaded, and they hit the server and botd together,
which a busy botd cannot do to the server on a 14-core VM.

**What it says.** The board takes planning work off (bench: expansions
-16 to -37%, routes come sooner), and botd's CPU at 200 is 20-22% with
it against 20-25% without (noise of the same size). Live, botd's p99
round (27-31 ms at 200) is NOT the planner: it stayed where it was with
the board and with 4 threads. The bench's planner share (54% of a think
at map230) is higher than live, where fewer bots plan at once and
decide bursts (every bot deciding in the same think) and sight make the
slow rounds. So `--threads` stays at 1 by default (botlink_threads;
docs/administer.md); at 100 bots four threads cost 6% of a core more for
nothing measurable. Next, by these numbers: the slow round itself --
which phase (decide, sight) makes botd's p99 30 ms at 200 -- and sight
in two phases (the rays in parallel, the board in order), the one
remaining piece that threads could speed on a flat field. **(c4) found
otherwise: the slow round IS the planner's** -- one long search spending
the whole share of a think, which threads cannot cut; four threads left
the p99 alone for that reason.

**Found on the way** (fixed, its own commit): a botd killed and started
again at once by the entrypoint (inside `botlink_stale`, 2 s) was never
told the bots, the map or the settings -- lib_botlink only resynced an
engine after a silence. Now a change of `engine_pid` is a new engine
(tests/botlink_test.lua 9a).

## (c4) THE SLOW ROUND: what made botd's p99 at 200 bots, and the planner's bound (2026-11-25, WORK.md item 24)

The owner, on "every bot deciding in the same round, and sight":
"multithreadable? optimizing it is top priority". Measured first; the
guess was wrong.

**How it was measured.** A profiling build (not in the repo: a clock
around each phase of `bc_engine_think` and of botd's round, the totals
printed with the health line) in a container of its own (lsd-p99: ctf,
prisonbreakv1, engine_bots_edit=all, as in (c3)), a headless client on
the Mac counting World Updates, 60 s a point after 65 s of play; and the
bench with the same clock per think. Phases: world (copy, objectives,
leaders), sight (the rays), tree (taking in what was seen, the board,
the tree), plan (route searches), tactics (perch scan), act (follower,
head, trigger); events (the server's records, before the think).

**What made the slow round (master, live, 200 bots, the host quiet; a
slow round is one over the 16.7 ms period: 210 of 3600 in the minute):**

| | rounds | round ms | events | world | sight | tree | plan | tactics | act | bots deciding |
|---|---|---|---|---|---|---|---|---|---|---|
| every round | 3600 | 3.43 | 0.00 | 0.00 | 0.49 | 0.16 | 2.28 | 0.00 | 0.49 | 62 |
| the slow ones | 210 | 25.4 | 0.00 | 0.00 | 1.07 | 0.34 | **22.95** | 0.00 | 0.99 | 127 |
| the worst | 1 | 39.7 | 0.00 | 0.01 | 2.06 | 0.42 | **36.1** | 0.00 | 1.08 | 154 |

At 100 bots the same: 38 slow rounds of 18.2 ms, 17.3 of them the
planner; the worst 27.8 ms, 27.1 the planner. Three more minutes at 200
(two of them on master after 4939f5f) gave 95 to 149 slow rounds, 90 to
93% planner. **The slow round is the planner's.** Sight is about a
millisecond of it, the trees a third of one; cover and perch searches,
events and jolts (0.4 a round) are nothing to see. (c3)'s "not the
planner" came from its p99 not moving with four threads: a slow round is
ONE long search spending the think's whole share -- 75 x 200 = 15000
expansions at about 1.6 us each -- and one search is one job, which
threads do not cut.

The bench says the same (map230:prisonbreakv1, 60 s, one thread): with
edit=all as live the planner is 83% of a think and the p99 30 to 34 ms;
without edits p99 9 ms (the planner 64% of the top 1%). On the flat
arena230 the top 1% are the planner's too (2.1 of 6.3 ms), and sight is
two thirds of an ordinary think.

**What bunched, in the think's structure:**

1. **The planner's budget is a count, and a round is a time.** An
   expansion costs from under 1 us (a plain field) to over 2 (a real map,
   bots that may dig and build: sees_edit, nav_move_fits), and a think's
   share at 200 bots, spent by one long search, is 25 to 40 ms.
2. **The decide phases collapsed.** A bot decided when a counter passed
   DECIDE_PERIOD, four phases by slot; a counter more than a period ahead
   (a round over about 33 ms, a map load) was reset to 0, and every bot so
   reset decided with the others from then on. Four phases at 30 worlds
   a second gave 50% or 75% of the bots in a think, even when whole.
3. Every other round does nothing (the world comes at 30, botd thinks at
   60, and a think without a new world leaves the intents as they are).
   Spreading the planner over those rounds was built and measured: rounds
   as short as with the bound, but ctf_test's six a side, at 8 seeds, went
   from a capture in every game (53 to 141 s) to none in 2 -- planning
   between worlds, at half the numbers to keep the rate, moved the routes
   enough to matter. Taken out; the bound alone does it.

**What was changed** (commits on the branch):

1. SIGHT IN TWO HALVES (senses.h): `bc_senses_look` casts the rays for
   one bot and writes only its own `bc_look`; `bc_senses_take` takes in
   what it saw -- memory, the team's board, the alertness -- bot after bot
   in slot order. The rays read only the map, the world and the bot's own
   memory, which nothing writes during the pass, so the outcome is byte
   for byte the old one (every deterministic line of the bench identical,
   every scene; parallel_test's hashes master's). THE THINK'S WORK AS
   JOBS (engine.h): one runner for both kinds the core hands out, sight (a
   job a bot whose turn it is) and route searches; botd runs them on its
   pool. The bench gives think p50/p99 and sight's share.
2. TURNS AT A PHASE OF THEIR OWN (engine.c, THE THINK): a bot decides
   DECIDE_PERIOD apart at a phase from its slot (the golden ratio's
   sequence, so any number of bots spreads evenly: two thirds of them a
   think at 30 worlds, give or take one), and the phase is a time, not a
   count: after a late think each bot decides once and the next think is
   back to its share.
3. THE PLANNER'S BOUND (engine.h; botd.c): the core takes, as it takes
   the budget, a bound on a think's expansions; botd keeps what an
   expansion has been costing it (the planner's jobs' time over the
   expansions they took, a moving mean) and bounds each think to what fits
   in `--plan-ms` (8 of 16.7). Its health line says the bound, the least
   it fell to in the window, and the cost.

Not done, and why: **a pair's sight once for both** (the three rays go
from an eye to a head, a chest and legs, so A-sees-B and B-sees-A are
different rays: sharing them would change what bots see); **culling by
a spatial grid** (the cheap tests before the rays are a field of view, a
range and a team already, and live sight is under a millisecond a
round); **the trees in parallel** (a third of a millisecond a round, and
their words write shared state all over: the team's board and pings,
perch claims, leaders, the unreachable memory, `hot`, `visit`, the route
board through bc_move_to, the order of the actions to the server -- two
phases for all of it would be a rewrite for nothing measurable).

**Live, before -> after** (the same container and client; one thread
unless said; "after" the branch as committed; 60 s a point, so botd's
CPU and the share of bots holding keys, 74 to 90%, move from minute to
minute in both):

| bots | | botd % | round mean / p50 / p99 / worst ms | slow rounds a minute | server tick p99 ms | client updates/s min / med | plan bound (least) | us an expansion |
|---|---|---|---|---|---|---|---|---|
| 100 | before (master 28e28bb) | 18.3 | 2.67 / 0.1 / 16.9 / 27.8 | 38 | 1.85 | 59 / 60 | -- | -- |
| 100 | before (master 4939f5f) | 7.2 | 1.01 / 0.3 / 14.0 / 29.5 | 14 | 2.55 | 59 / 60 | -- | -- |
| 100 | **after** | 6.9 | 1.00 / 0.2 / **9.8** / 14.7 | 0 | 2.13 | 60 / 60 | 4665 (2310) | 1.71 |
| 200 | before (28e28bb, two runs) | 24.9, 16.4 | 3.43, 2.79 mean; p99 30.2, 34.3; worst 39.7, 39.1 | 210, 149 | 3.1-3.4 | 59 / 60 | -- | -- |
| 200 | before (4939f5f) | 15.5 | 2.39 / 1.1 / 30.9 / 48.5 | 95 | 3.93 | 59 / 60 | -- | -- |
| 200 | **after** | 28.4 | 4.71 / 0.3 / **13.7** / 34.3 | 10 | 3.82 | 56 / 60 | 4149 (2495) | 1.93 |

The "after" at 200 ran with the host at load 9 to 11 (the server's own
ticks reached 84 ms in it, UPS 56 at worst, the client too): its worst
round and botd's CPU are the host's. Earlier runs of the design that
also planned between worlds, quieter, gave p99 11.7 to 13.9 ms at 200 and
9.1 to 10.3 at 100. Runs with the host at load 17 to 54 (other agents'
work, the owner's game) are not in the table: every phase of both
processes five times slower, the server's UPS 32 to 49, the bound at its
floor of 500 -- the VM starved, not botd's work.

**The default thread count stays 1.** With the planner bounded, one
thread holds the p99 under the period; four made no round shorter (p99
13.9 and 12.6 against 12.5 and 13.7 in the runs measured side by side,
worst 20.7 and 16.7 against 25.0 and 22.6: noise of the same size) and
cost up to 5% of a core more. What threads buy now is more planning in a
round -- the bound rose from about 4400 to 6900 expansions, the cost per
expansion, threads and all, from 1.8 to 1.2 us -- that is, routes sooner
when many bots need one; and in the bench sight on four threads halves a
think on a flat field (arena230 1655 -> 852 us, p99 5.0 -> 2.9 ms). An
operator with cores to spare and a crowded map may set botlink_threads 4.

**Determinism.** tests/parallel_test.c hashes every intent of every think
of a 20-a-side game with no runner and at 1 to 8 threads, the route
board on and off, the budget shared and thin: the same hash every time
(sight's jobs and the planner's both on the pool). Under ThreadSanitizer
(gcc 14, Linux, -O1) it reports nothing. The bench's deterministic lines
are identical at 1 and 4 threads (map230, arena230). The replay tests
(engine_test, ctf_test) pass.

**The bench, master (4939f5f) -> the branch** (the bench has no clock and
so no bound: what moves its deterministic lines is the turns' phases;
the think's time is the branch's own, master's was measured with the
host loaded and is left out):

| scene | think mean / p99 / worst us | plans | expansions | waiting % | no key % | longest idle s | head on % | kills |
|---|---|---|---|---|---|---|---|---|
| map230:prisonbreakv1 (60 s) | 2584 / 8400 / 9258 | 3869 -> 3929 | 17.9M -> 19.9M | 0.9 -> 1.1 | 22.1 -> 23.5 | 43.3 -> 44.6 | 86.3 -> 85.7 | 99 -> 114 |
| the same, edit=all | 7335 / 32400 / 42695 | 5476 -> 5378 | 18.9M -> 16.8M | 3.9 -> 2.5 | 29.3 -> 31.2 | 30.9 -> 44.1 | 78.5 -> 78.6 | 151 -> 168 |
| arena230 | 1071 / 3000 / 7813 | 5425 -> 5353 | 502k -> 502k | 5.1 -> 5.1 | 34.9 -> 35.9 | 39.2 -> 23.6 | 28.7 -> 10.4 | 807 -> 802 |
| ctf:115 (4 games) | 1142 / 7800 / 12803 | | | 5.2 -> 5.2 | 22.6 -> 24.4 | | 67.4 -> 67.1 | 9440 -> 9298 |

The default scenes move as a change of timing moves them: arena12/32/40
no key 21.4/25.7/25.5 -> 24.3/25.9/26.5%, head on 57/32/13 -> 62/35/38%;
fight6 to the last man 21.2 -> 15.6 s, fight20 32.6 -> 46.4 s (its
longest idle 6.9 -> 38 s: a bot holding in cover); sea40 wading 24.9 ->
30.6%; ctf:10 4 -> 2 captures in 4 games; nothing stuck anywhere.
ctf_test's six a side, 8 seeds: a capture in all 8 on master (53 to 141
s) and on the branch (48 to 215 s).

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
| **`gaze`** | `0` / `1` | 0: heads follow the steering, as before (1). |
| **`plan.cap`** | expansions | a search stops there and the partial route is walked (8000; 0: none). |
| **`plan.greed`** | factor | nav's `h_weight` (1.5; 1: exact searches, water as land). |
| **`plan.wait`** | `walk` / `stand` | what a bot does while its route is searched (walk). |
| **`plan.share`** | `0` / `1` | the route board (core/routes.h): a team's bots going the same way share one search (1). |
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

- 2026-11-25 (step C, off the roof): `stranded` (condition, score). In
  the trees: `option none stranded x20` -> `<mode>_stranded` (fight what it
  sees, crouch facing a shot, else hold and watch). Scenario in
  tactics_test, "a bot on a roof with no way down": no edits, 60 s -- 8
  searches, still on the roof, a movement key down on 32 of 1800 ticks,
  `hold` on 1734, 20 rounds at a man who comes in sight; edits allowed --
  on the ground after 4.9 s, health 100, 13 searches. Found on the way and
  fixed: the net took strafing for pushing and its jump threw a bot
  fighting on a roof's edge off it; `bc_walk_safe` missed a body already
  half over an edge; a flinch jump now needs floor where it lands; a bot
  did not walk on toward a goal far below while its route was searched (it
  walked off the start of a route whose first step is an edit).

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
