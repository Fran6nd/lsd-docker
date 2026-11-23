# Map, body, navigation: where it stands

Navigation was stopped here on purpose, in a usable state; what is left is
the TODO in (f). `make -C bot test` builds with no warnings and every test
passes on:

- macOS arm64, Apple clang 17 (the whole suite);
- Alpine 3 arm64, musl, GCC 15 (the whole suite);
- Alpine 3 x86-64 under emulation, and Debian arm64 glibc GCC 14: every
  test of map, cull, body and nav. On those two the suite as a whole does
  not pass, for reasons outside nav: see "needed from others" in (f).

The body's drift hash is the same value on all four.

Real maps are not in the repo. Tests that want them read a directory of
`.vxl` files from `BC_TEST_MAPS` and say "skipped" without it. The eight
used below were copied out of the `lsd-demo` container
(`docker cp lsd-demo:/data/maps/<name>.vxl <dir>/`).

## (a) What exists

| file | what it is |
|---|---|
| `core/map.{h,c}` | The world: one `uint64_t` a column, bit z = solid, z down. `.vxl` loader from bytes; raw set; the four block actions and the line as the server performs them; `bc_map_change` (what an action did, collapse included); standable/crouchable floors as bit operations. No colours. |
| `core/cull.{h,c}` | The floating-block flood: libpvx2's `map_cull` ported statement for statement to plain C11. 7.1 MiB scratch, caller's. |
| `core/lsd_core.{h,c}` | **LSd's own `lsd/src/demoncore.c`, `#include`d whole** and compiled against `bc_map`: `move_player`, `change_crouch`, `block_line`, `cast_ray`, `clip_phys`. `state.h` is replaced by the few definitions demoncore.c really reads; `demoncore.h` and `protocol.h` are the server's real ones. Not a port. |
| `core/body.{h,c}` | `bc_body` (pos, vel, keys, airborne, wade: 20 bytes) and `bc_body_step(body, map, keys, ori, dt)` in the server's order (input packet, then physics). `bc_body_place`, `bc_body_can_stand`, `bc_body_feet`. |
| `core/nav.h` | The module's documentation and whole public API. |
| `core/nav_i.h` | nav's private declarations, shared by its four files. |
| `core/nav_exec.c` | The controllers: laws (cheap rules for keys and facing) and simulations (a law run on a copy of the body through the real physics). Jump and drop controllers. |
| `core/nav_moves.c` | Measures the move table by running those controllers in built scenes, and the strides in context by running the follower on built courses. |
| `core/nav_plan.c` | A* over (x, y, floor z); policy, protected voxels, failure memory, edit moves; resumable. |
| `core/nav_follow.c` | The follower. |
| `tests/map_test.c` | Loader round trip, queries, every action with what it must leave, change reports, personalities, real maps. |
| `tests/cull_parity_test.c` | `bc_map` against the server's code compiled in beside it. |
| `tests/body_test.c` | The physics' known numbers, its quirks, and a hashed 3000-tick trajectory (drift alarm) with no libm in it. |
| `tests/nav_test.c`, `tests/nav_sim.h` | The pinned move table, about 50 scenarios (plan + follow in the simulated body), the soak. `nav_test -v NAME` shows one scenario's plans (every tick with `BC_SOAK_TRACE=1`); `--table` prints the table. |
| `Makefile` | One change: the core is built `-ffp-contract=off`, so trajectories are the same bits on every machine. |

API in one breath: `bc_map_load_vxl`, `bc_map_apply(map, cull, action, x, y, z, &change)`, `bc_map_line`;
`bc_body_step`; `bc_nav_moves_measure(table, scratch_map)`; `bc_nav_plan_begin` /
`bc_nav_plan_step(search, budget)` -> MORE / DONE / FAILED / `bc_nav_plan_route`;
`bc_nav_follow_tick(follow, route, table, map, body, policy, &cmd)` ->
FOLLOWING / ARRIVED / STEP_FAILED(why) / ROUTE_STALE / OFF_ROUTE / GIVE_UP;
`bc_nav_follow_begin` (a new goal) and `bc_nav_follow_again` (another route to the same one);
`bc_nav_fail_note`, `bc_nav_protect_add`, `bc_nav_node_of_body`, `bc_nav_snap`.

## (b) The measured move table

166 moves, measured in about 0.4 s at start-up from the server's physics.
`nav_test --table` prints all of it; `nav_test` pins its shape.

Paces (voxels/s): walk 8.0, sprint 10.4, sneak 4.0, crouch 2.4, wade 5.33.
A body stands in 3 voxels of air and crouches in 2. A jump rises 1.6 and
lasts 39 ticks.

**Gaps at the same height (voxels of nothing between take-off and landing):**

| gap | how | run-up | window to press jump |
|---|---|---|---|
| 1 | standing jump, walking | none | 12 ticks |
| **2** | **standing jump, walking** | **none** | **15 ticks** |
| 3 | standing jump, walking | none | 10 ticks |
| 4 | standing jump, walking | none | 5 ticks |
| 5 | sprint | 3 columns | 9 ticks |
| 6 | sprint | 3 columns | 4 ticks |
| 7 | cannot be done | | |

Widest gap with any run-up: **5 at a walk, 6 at a sprint.** "Standing"
means from rest at the back of the take-off column: the physics holds a
body up by any corner, so it takes off with its centre 0.45 past the edge
and has landed as soon as it overlaps the far column.

The two-voxel gap also goes one voxel **up** (standing, window 10) and one
**down** (standing, window 14), and two voxels up (standing, window 11).

Up: 1 voxel is a free climb at a walk (not sprinting, not crouched, not
looking steeply down); 2 voxels with a jump from standing; 3 never.
Down: drops of 2 to 9 voxels do not hurt (10: 1 hp, 11: 5, 12: 12, 13: 21, 14: 32).
Water: wading; out onto a bank 1 voxel above the sea bed's top by a jump
only (walking does not climb it); a bank 2 up cannot be reached.
Diagonals: standing jumps over 1 and 2 diagonal columns, sprint over 3 and 4.

**Strides in context** (new; `nav_test --table` prints them). A stride's
time depends on the one before it, so the follower is timed on built
courses and the plan prices a stride by what preceded it. Along an axis:
level 0.094 s; onto a stair up 0.133, each further step up 0.225, the first
level stride after a climb 0.317; onto a stair down 0.100, each further
0.244, level after it 0.267; the first stride from rest 0.33. A flight of n
steps adds 0.19 + 0.13 (n - 1) s going up and 0.11 + 0.15 (n - 1) s going
down. A turn at full pace adds 0.15 s (45 degrees), 0.38 (90), 0.41 (135).

## (c) Scenarios

All pass (315 checks); none is skipped. Each is plan + follower in the
simulated body until ARRIVED, with a tick cap. The ones from before this
session are unchanged and none was weakened:

- **Acceptance (`two_block_gap`, `_up`, `_down`)**: trench the width of the
  map, building off; crossed by a jump, one plan, no step failure, never in
  the trench, at command delays of 0, 1 and 2 ticks.
- `gap_1` .. `gap_6`, `gap_3_late`, `gap_6_late`, `gap_too_wide`, `gap_too_wide_bridged`,
  `parkour_three_gaps`, `parkour_diagonal`.
- `step_two_high`, `step_three_high_refused`, `stairs_natural`.
- `wall_walk_round`, `wall_dig_through`, `wall_no_dig_zone`, `wall_server_refuses`, `dig_down_and_out`.
- `stairs_up_cliff`, `pillar_up`, `build_no_blocks`, `crouch_gap`.
- `water_wade`, `water_costs`, `water_deadly`, `water_deadly_no_ford`.
- `drop_six`, `drop_too_deep`, `drop_too_deep_no_stairs`.
- `wedged_on_ledge`, `route_blocked_midway`, `floor_removed_midway`, `collapse_ahead`, `collapse_underfoot`.
- `fail_memory`, `resumable`.

New this session, each for a fault found in the soak (the "done" list in
(f) says which): `turn_below_stairs`, `turn_on_causeway`,
`turn_past_dead_end`, `goal_in_inner_corner`, `overshoot_loop`,
`zigzag_down`, `jump_down_onto_ledge_late`, `runjump_refused_late`,
`drop_into_water`, `wedged_no_other_way`, `partial_again_and_again`. The
turn and delay scenarios run at command delays of 0, 1 and 2 ticks.

## (d) Soak, real maps

`BC_TEST_MAPS=dir build/tests/nav_test`, with `BC_SOAK_PAIRS`,
`BC_SOAK_LATENCY`, `BC_SOAK_EDITS`, `BC_SOAK_MAP`, `BC_SOAK_PAIR`,
`BC_SOAK_SHOW`, `BC_SOAK_TRACE` (every tick of one pair) and
`BC_SOAK_COSTS` (walked against planned by kind of step): nav_test.c's
header. Random start/goal pairs at least 12 voxels apart, pool of 131072
nodes. "Reachable" = the first plan succeeded; "lost" = reachable and not
arrived. All eight maps (Parkour2, shot0, Temple, 2FortCTF, CubeMaze,
BigPineTree, ClockTownarena, Pyeongyang) in every row.

| run | checkpoint (before) | now |
|---|---|---|
| no edits, 500 pairs a map, delay 0 | 2513 of 2524 arrived, **11 lost**, 56 step failures, 17 off route | 2520 of 2520, **0 lost**, 2 step failures, 0 off route |
| no edits, 500 pairs, delay 1 | not run at 500 (at 200 pairs: 1009 of 1015, 6 lost) | 2520 of 2520, **0 lost**, 8 step failures |
| no edits, 500 pairs, delay 2 | 2503 of 2524, **21 lost**, 129 step failures, 61 off route | 2519 of 2520, **1 lost** (2FortCTF, (f)2), 39 step failures (23 of them jumps refused, (f)3) |
| **edits on**, 200 pairs a map, delay 1 | 1076 of 1099, **23 lost** (22 on Parkour2), 302 step failures, 118 off route | 986 of 993, **7 lost** (5 BigPineTree, 2 Parkour2: (f)1), 317 step failures (277 stuck on BigPineTree) |

The reachable counts differ a little between the columns because the plans
do (the cost model changed, and a drop into water that hurts is no longer
planned). **Not run:** edits at delays 0 and 2, edits at 500 pairs. Nothing
the edit soak found has been traced or fixed: it was run once, to have the
number.

Walked time against planned (delay 1, no edits, routes walked as first
planned): the mean per map was 1.03 to 1.26 at the checkpoint and is **0.97
to 1.03** now; the worst single route is 1.25 (was 2.09, on Temple). ClockTownarena's
average walk went from 37.1 s to 32.5 s for the same pairs: the routes are
straighter, not only better estimated.

Plans (delay 1, no edits): 2.6 to 17 ms and 8 800 to 78 000 expansions on
average per map, worst 43 ms. The context costs made Temple's searches
about twice as long as at the checkpoint (4.8 to 10 ms): the heuristic is
further below the real cost on hilly ground. Still no coarse stage needed.

Memory: search 5.5 MiB, table 35 KiB, route 10 KiB, follower under 200
bytes (it grew by the report memory), map 2 MiB, cull 7.1 MiB.

## (e) The later requirements

- **Two-block-gap acceptance test**: done, passing, see (c). Widest gaps reported in (b).
- **Collapse parity with the server's cull**: `tests/cull_parity_test.c`
  `#include`s the real `lsd/src/libpvx2/src/{cull.c,read.c,map.c}`
  unmodified and compares the whole map after every action. **It RAN and
  passed, locally** (Apple clang 17 has `__builtin_clzg`; no container
  needed): 36 236 checks in `make test` (synthetic towers, bridges, an
  overhang, a mass on one voxel, edge-only contact, map edges, 6000 random
  actions on a random town, both personalities), and 144 284 with
  `BC_TEST_MAPS` (3000 targeted actions x 2 personalities on Parkour2,
  shot0, Temple, plus the loader against libpvx2's `vxl_read`: identical).
  Honest limits: the action logic (which voxels, which neighbours) lives in
  `main.c` as statics and is compared against a second transcription in the
  test, not the server's object code; and real maps gave few collapses
  (0 to 636 voxels a run), the synthetic town 2000-2800. A compiler without
  the builtins prints SKIPPED and passes having proven nothing.
- **Collapse reporting**: `bc_map_apply(..., bc_map_change *)` gives the
  count the action changed, the count the flood removed, the box round all
  of it, and (optional caller buffer) the voxels, flagged collapsed/built.
  Checked against the map difference on every parity action.
- **Routes and collapse**: the follower re-checks every step ahead whenever
  `map->rev` changes, collapse or direct edit alike. `collapse_ahead`: a
  deck's one support is shot while the bot approaches; ROUTE_STALE, replan,
  the other way, never sets foot on it. `collapse_underfoot`: shot with the
  bot on it; it falls with the deck, replans from where it lands, climbs out.
- **Cull personalities**: OpenSpades (1) culls only round voxels really
  removed and does nothing for an action that removes nothing; Voxlap (0)
  culls round every voxel the action names (a destroy of air still checks
  its six neighbours; spade all three levels; grenade the whole shell).
  Both implemented and in the parity test. **The server's default is
  OPENSPADES** (`main.c:1737`) and no script in `lsd/scripts` calls
  `set_cull_personality`. `bc_map_clear` / `fill_flat` / `load_vxl` all
  reset `cull_personality` to OPENSPADES: a host on a Voxlap server must set
  it after every load. The found bug: I first had a Voxlap destroy of air do nothing.
- **Recentring**:
  (a) *steer to cell centres*: was already the design, kept. Ground steps
  head for the next column's middle; jumps align on the line through the
  two centres. There is no corner cutting or string pulling at all.
  (b) *recentre before reporting stuck*: implemented (after 45 still ticks,
  once per step: walk to the middle of the column stood in, re-simulate,
  then fail). **Measured: no change** -- 9 lost / 16 stuck before, 9 / 16
  after, same routes. Kept because it is cheap and bounded (contract in
  nav.h: at most 2 x 45 + 40 ticks to a report), but the soak does not
  support it; the stuck cases were not off-centre bodies.
  (c) *align the run-up, simulate from the actual state*: was the design;
  improved by braking hard before aligning and by slowing before any step
  that starts from standing. That, not (b), is what cut the losses.

## (f) TODO, most important first

Each: what is wrong / what it costs in play / what to do / how to see it.
`M=<dir of maps>`; `T=build/tests/nav_test`.

1. **With digging and building on, bots get stuck on BigPineTree and lose
   routes on Parkour2. Untraced.**
   In play: on BigPineTree about one route in 35 is abandoned after 14 to 25
   STUCK reports in a row (the follower's GIVE_UP ends it; before, it ground
   on until a cap), and 277 stuck reports in 181 routes means bots visibly
   standing against something for two seconds at a time. On Parkour2 two
   routes end in "edit refused, then no way".
   To do: trace one pair tick by tick; the likely places are an edit step
   whose body is not where `edit_tick` wants it, and building under foliage.
   `BC_TEST_MAPS=$M BC_SOAK_EDITS=1 BC_SOAK_MAP=BigPineTree.vxl BC_SOAK_PAIR=285,280,39,359,339,61 BC_SOAK_TRACE=1 $T`
   (others: `275,306,47,364,341,61`; Parkour2 `330,255,18,455,187,61`).
2. **One route lost at two ticks of delay, on 2FortCTF: five TIMEOUTs on one
   step, then GIVE_UP. Untraced.**
   In play: a bot stops trying for a goal it could reach; rare (1 in 2520).
   To do: trace it; a step that neither fails nor finishes in 3x its time.
   `BC_TEST_MAPS=$M BC_SOAK_LATENCY=2 BC_SOAK_MAP=2FortCTF.vxl BC_SOAK_PAIR=284,289,44,247,270,55 BC_SOAK_TRACE=1 $T`
3. **Jumps with a narrow window are refused at two ticks of delay.**
   In play: nothing is lost (the body brakes safely and plans another way),
   but a bot walks up to a jump, backs off and goes round: 23 times in 2520
   routes at delay 2, against 4 at delay 1.
   To do: either the caller raises `policy.min_margin` to 6 or 7 when the
   link is slow, or the run-up is aligned more tightly (0.12 voxel and
   0.8 voxel/s are allowed now) so the measured window is the one met.
   `BC_TEST_MAPS=$M BC_SOAK_LATENCY=2 BC_SOAK_MAP=2FortCTF.vxl BC_SOAK_PAIR=297,239,44,284,253,49 $T`
4. **Not done at all: swimming and banks beyond wade-and-jump-out, ladders
   of blocks, one-wide bridges under traffic, and crowds.** Nav is per bot
   and knows nothing of other bodies.
   In play: two bots wanting the same one-wide door or bridge from opposite
   ends will push against each other until both report STUCK, plan again,
   and may meet again (GIVE_UP bounds it at three times in the same spot).
   To do: an optional "cells others occupy or have claimed" input to
   `bc_nav_follow_tick`, so a body waits (bounded) or steps aside; a
   scenario of six bots through a door from both sides. No code exists.
5. **A sharp turn is taken wide.** The follower sprints into a 90-degree
   turn, overshoots by up to two voxels where there is floor to overshoot
   onto, and comes back to the line.
   In play: safe (the safety rule keeps it on floor it can walk back from)
   and priced (0.38 s a turn, so plans avoid turns), but it looks clumsy
   and `turn_below_stairs` walks 5.7 s for 4.7 planned.
   To do: slow for the corner in `ground_law` when the next stride turns by
   90 degrees or more, then measure again (the turn prices follow by
   themselves: they are timed from the follower).
   `$T -v turn_below_stairs` with `BC_SOAK_TRACE=1`.
6. **A stride's price depends on the stride before it; the search does not
   keep headings.** (`stride_secs` in nav_plan.c says so.)
   In play: nothing seen. Two ways to a node that differ by less than one
   turn may be ranked wrongly, and a route's `secs` can be off by a turn.
   To do: nothing, unless estimates matter to a tenth of a second.
7. **Searches on hilly maps take twice as long as before the cost model**
   (Temple 10 ms on average, was 4.8; worst still about 43 ms).
   In play: nothing seen at these sizes; an unreachable goal still floods
   up to the pool (5.5 MiB, about 40 ms).
   To do: if it matters, make the heuristic know height (a climb costs at
   least 0.13 s a voxel more than level ground).
8. **The planner prices later steps against the unedited map** (except the
   room the body stands in). A staircase built into the open pays for a
   support block it may not need. In play: slightly dearer builds.
9. No knight's-move jumps, no jumps under low ceilings, no diagonal drops
   in the planner, nothing but wade and climb-out from water. In play:
   routes a human would take are not found; the bot goes round or fails.
10. `tests/nav_test.c` `floor_removed_midway` has a leftover unused block
    (`w2`) and cuts the causeway before the second run, not during. Tidy.
11. A caller must react to EDIT_REFUSED by more than protecting one voxel
    (the test bench stops editing after two refusals, as aosbot did).

### Needed from others (not nav's files)

- `tests/botd_test.c:266` does not compile with GCC 14 on glibc
  (`-Werror=format-truncation`: a 300-byte string into 256). So on glibc
  `make test` builds nothing after it; nav's tests were run there by name.
- `tests/botd_test.c:310` (`fake.last_dt` between 0.012 and 0.03) failed
  once on Alpine x86-64 under emulation: a wall-clock bound.
- `tests/skills_test` exited non-zero on Alpine x86-64 under emulation
  (it passes on Alpine arm64 and macOS). Not looked into.
- The Makefile needed **no** change for Linux. Container builds here were
  done with `make B=/tmp/b test` on a read-only mount, so no Linux objects
  were ever written to `bot/build`.
- The brain: start each new route TO THE SAME GOAL with
  `bc_nav_follow_again`, not `bc_nav_follow_begin`, and handle
  `BC_NAV_GIVE_UP` (nav.h, NEVER A LOOP). With `_begin` every time,
  everything works as before and nothing ends a loop.

### Done this session, with the scenario that proves each

The scenario named first in each row was run with its fix taken out and
failed, then with it and passed -- except the two for GIVE_UP, which
cannot be run without it (they assert that answer), and the "also"
scenarios in the first row, which passed before as well and are there to
hold the ground.

| what was wrong | the fix | scenario |
|---|---|---|
| The ground safety rule judged by height only: a body overshot a turn onto a ledge at the route's level, came back at a sprint and went off the other side (all Parkour2 losses) | `ground_safe` (nav_follow.c): a simulated emergency stop must END at rest with the body's centre over the route's own columns or floor within two plain strides of them; asked for a stop 3 ticks from now (the guarantee) and 15 (the foresight that slows before a turn) | `turn_below_stairs`; also `turn_on_causeway`, `turn_past_dead_end`, `zigzag_down` |
| Temple's pair that looped on OFF_ROUTE for ever. Traced: NOT `bc_nav_node_of_body`. A sprint into a step with a slope beyond it "could stop" hanging by one corner; a tick of delay later it could not; the new plan led round the hill and into the same step at the same sprint | the same rule (a stop hanging by a corner is not a stop) | `overshoot_loop` |
| Nothing ended a loop of reports | `BC_NAV_GIVE_UP`: the third identical report from the same place, or the 32nd report for a goal; an ARRIVED on a partial route counts; kept across routes by `bc_nav_follow_again` | `wedged_no_other_way`, `partial_again_and_again`; the soak checks the bench's own cap is never what stops a run |
| A goal in the inner corner of a terrace was never "arrived at": the body rests a voxel above the floor, held by a corner on the neighbour's edge (the checkpoint's untraced Temple STUCKs) | ARRIVED also for a body at rest over the middle of the last column and up to a voxel above its floor | `goal_in_inner_corner` |
| A drop of nine voxels into water was planned and refused at the edge by the follower, from every edge in turn: in water the feet go one deeper, so it is a fall of ten, which hurts | the plan prices a drop into water as the drop one deeper, and refuses the deepest | `drop_into_water` |
| A refused run-up braked to a stop hanging off the take-off corner, and fell with two ticks of delay (2FortCTF, into a pit with no way out) | `can_still_stop` (nav_exec.c): three ticks of running before the brake, and the stop must end with the centre over floor at the take-off's level | `runjump_refused_late` |
| A jump down onto a ledge landed right and slid off the far edge when the brake came two ticks late (2FortCTF) | a jump is pressed only if the landing settles with the brake at once AND two ticks late | `jump_down_onto_ledge_late` |
| Planned time up to a quarter under walked, and not from stairs alone: no price on a turn made every zigzag as cheap as the straight way | strides and turns measured in context by timing the follower on built courses (`stride_secs`, `turn_secs`), and the plan prices by them | the soak's "the estimate" line (0.97 to 1.03 per map); `stairs_natural` 6.85 s walked for 6.97 planned (was 4.79) |
| body_test's drift hash fed on `cosf`/`sinf`, and its script never waded, never fell in a pit and never left its start | headings from a table of rational unit vectors (no libm in the script), a course it is taken all over, and checks that it was (air, water, crouch, step, pit, landings) | `body_test` drift: 0x417e74ea on all four platforms |

## (g) What the next agent must know

- **`airborne` is not "on the ground".** After any landing the body creeps
  down the last hundredths over several ticks with the flag set on most of
  them, and the server DROPS a jump pressed on such a tick. Everything in
  nav uses `nav_on_floor` (feet near the floor, falling slowly) and checks
  `vel.z < 0` after a jump tick to know it was taken. This cost an hour.
- **Changing crouch in the air lifts the eye 0.9 each time**, both ways
  (`change_crouch` falls into its un-crouch branch). Real clients never show
  it (they run their own physics); a server-moved bot would climb the sky.
  The follower never changes crouch off the ground. aosbot's "hold crouch
  through a pillar jump" must not be carried over.
- **Un-crouching is not checked by the server**: under a 2-voxel ceiling the
  head ends in a block and the body is stuck for good. `bc_body_can_stand`.
- **A sprint does not climb a kerb**, and each climb halves speed.
- **A body is held up by any corner.** It stands with its centre 0.45 over
  nothing, lands as soon as it overlaps a column, and after coming down a
  stair often rests on the tread above with its centre over the next
  column. Any test of "is it at X" that wants the centre in X's column and
  the feet exactly at X's height is wrong in all three cases.
- **A short jump is hauled up by the far lip** (the server's one-voxel
  climb works in the air). Legitimate, but ugly; the follower jumps late
  in its window to avoid it.
- **The body slides**: velocity follows facing with a 0.25 s time constant,
  2.6 voxels of coasting from a sprint. Stopping from 10.4 voxels/s takes
  about 1.3 voxels even pulling back. Every fall in the soak was this.
- **From water, walking does not climb onto a bank one up** on this server
  (aosbot's notes say a shore at 62 is a beach). Measured, not argued: the
  table has a jump there.
- **A stride's swept volume must be cut to its own columns.** The body's
  leading edge is over the column beyond well before its centre arrives;
  recorded naively, the mask forbade every staircase.
- **Dig lists come from the measured stride mask**, not from "three voxels
  of head room": stepping down into a tunnel needs a fourth voxel where the
  body enters a voxel higher than it will stand. The hand-written rule dug
  a hole the body could not get into.
- aosbot's planner constants were not carried over as numbers. Its reasons
  were (nav.h's "what is kept"). Its rule "jump only where the neighbour
  cannot be walked to" is mine too and is what keeps flat ground at 8 edges.
- The link: `BL_EV_BLOCK` with BUILD/DESTROY/SPADE/GRENADE and `BL_EV_LINE`
  map one to one onto `bc_map_apply` / `bc_map_line`. The follower assumes
  a JUMP key is an event applied on the tick it is seen with the body on
  the ground; lib_botlink must feed keys to the server the way
  `on_move_input` does (crouch change, jump refused in the air, then the tick).

- **"Still up" is not "standing".** A body held by one corner with its
  centre over nothing passes every test of height, and falls if anything
  differs from the simulation by a hundredth of a voxel -- which a tick of
  command delay does. Every simulated stop must end with the CENTRE over
  floor. Four of this session's fixes are this one sentence.
- **A body is 0.9 wide in a column of 1.** Beside a neighbour one voxel
  higher it comes down onto its own floor only within 0.05 of dead centre;
  otherwise it rests a voxel up. Never wait for "feet on the node's floor".
- **In water the feet are a voxel below the node** (z = 63, feet at 64): a
  drop into water is one deeper than the nodes say.
- **Costs are timed from the follower**, so changing how the follower
  walks changes the plan's prices by itself; nav_test pins the table's
  shape, not its times.
- To see that a scenario fails without a fix: there is no switch; take the
  fix out by hand, run `nav_test -v NAME`, put it back.

### Suggested changes to bot/README.md

- The mechanics row says "aosbot, ported". Map and cull are ported from the
  *server* (libpvx2), the physics is the server's file compiled in, and nav
  is new on aosbot's lessons. Its test rule ("a ported module replays cases
  recorded from aosbot") does not fit them: map and cull are tested against
  the server's code, nav against the physics.
- Add `lsd_core.*` to the table and say the core is built `-ffp-contract=off`.
- Say where test maps come from (`BC_TEST_MAPS`), or put two small `.vxl` in the repo.
