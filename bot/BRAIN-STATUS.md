# The brain: senses, skills, vocabulary, engine, trees -- where it stands

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
