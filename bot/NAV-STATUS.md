# Map, body, navigation: where it stands

A checkpoint, written for whoever continues. `make -C bot test` builds with
no warnings and every test passes (macOS arm64, Apple clang 17). **It has
not been built with GCC or on Linux**: see the open list.

Real maps are not in the repo. Tests that want them read a directory of
`.vxl` files from `BC_TEST_MAPS` and say "skipped" without it. The eight
used below were copied out of the `lsd-demo` container (`/data/maps`).

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
| `core/nav_moves.c` | Measures the move table by running those controllers in built scenes. |
| `core/nav_plan.c` | A* over (x, y, floor z); policy, protected voxels, failure memory, edit moves; resumable. |
| `core/nav_follow.c` | The follower. |
| `tests/map_test.c` | Loader round trip, queries, every action with what it must leave, change reports, personalities, real maps. |
| `tests/cull_parity_test.c` | `bc_map` against the server's code compiled in beside it. |
| `tests/body_test.c` | The physics' known numbers, its quirks, and a hashed 3000-tick trajectory (drift alarm). |
| `tests/nav_test.c`, `tests/nav_sim.h` | The pinned move table, about 40 scenarios (plan + follow in the simulated body), the soak. `nav_test -v NAME` shows one scenario's plans; `--table` prints the table. |
| `Makefile` | One change: the core is built `-ffp-contract=off`, so trajectories are the same bits on every machine. |

API in one breath: `bc_map_load_vxl`, `bc_map_apply(map, cull, action, x, y, z, &change)`, `bc_map_line`;
`bc_body_step`; `bc_nav_moves_measure(table, scratch_map)`; `bc_nav_plan_begin` /
`bc_nav_plan_step(search, budget)` -> MORE / DONE / FAILED / `bc_nav_plan_route`;
`bc_nav_follow_tick(follow, route, table, map, body, policy, &cmd)` ->
FOLLOWING / ARRIVED / STEP_FAILED(why) / ROUTE_STALE / OFF_ROUTE;
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

## (c) Scenarios

All pass (220 checks); none is skipped. Each is plan + follower in the
simulated body until ARRIVED, with a tick cap.

- **Acceptance (`two_block_gap`, `_up`, `_down`)**: trench the width of the
  map, building off; crossed by a jump, one plan, no step failure, never in
  the trench, at command delays of 0, 1 and 2 ticks. 2.4 to 2.7 s for 19 voxels.
- `gap_1` .. `gap_6`: each jumpable width; 1-4 by JUMP, 5-6 by RUNJUMP.
  `gap_3_late`, `gap_6_late`: with 2 ticks of command delay.
- `gap_too_wide` (7): refused, the bot does not try. `gap_too_wide_bridged`: crossed with BUILD.
- `parkour_three_gaps` (ledge to ledge, one pillar a voxel up, no run-up room), `parkour_diagonal`.
- `step_two_high`, `step_three_high_refused`, `stairs_natural`.
- `wall_walk_round`, `wall_dig_through`, `wall_no_dig_zone`, `wall_server_refuses`
  (asks, is refused, learns the voxel, goes round), `dig_down_and_out`.
- `stairs_up_cliff`, `pillar_up`, `build_no_blocks`.
- `crouch_gap` (two-high hole through a three-thick wall).
- `water_wade`, `water_costs` (takes the ford), `water_deadly` (200-voxel detour, dry), `water_deadly_no_ford`.
- `drop_six`, `drop_too_deep` (takes the stairs, unhurt), `drop_too_deep_no_stairs` (stays up).
- `wedged_on_ledge` (the engine's map is wrong; follower reports STUCK, failure is remembered, next plan takes the other door), `route_blocked_midway` (ROUTE_STALE before it gets there), `floor_removed_midway`.
- `collapse_ahead`, `collapse_underfoot` (below).
- `fail_memory`, `resumable` (same route in slices of 50 expansions; a 256-node pool fails with a partial route).

## (d) Soak, real maps

`BC_TEST_MAPS=dir build/tests/nav_test`. 200 random start/goal pairs a
map, at least 12 voxels apart, 1 tick of command delay, no edits, pool of
131072 nodes (5.5 MiB). "Reachable" = the first plan succeeded.

| map | reachable | arrived | lost | step failures (all replanned) |
|---|---|---|---|---|
| Parkour2 | 95 | 90 (94.7%) | 5 | 0 |
| shot0 | 90 | 90 | 0 | 0 |
| Temple | 200 | 199 (99.5%) | 1 | 9 (8 stuck, 1 drop) |
| 2FortCTF | 68 | 68 | 0 | 1 (jump) |
| CubeMaze | 50 | 50 | 0 | 0 |
| BigPineTree | 166 | 166 | 0 | 0 |
| ClockTownarena | 153 | 153 | 0 | 0 |
| Pyeongyang | 193 | 193 | 0 | 0 |
| **all** | **1015** | **1009 (99.4%)** | **6** | **10** |

- **Arrival 99.4%. Stuck reports: 8 in 1015 routes (0.8%), every one
  recovered by replanning.** Lost: 6, none of them a bot grinding; see (f)1.
- Plans that reached their goal: 4 to 16 ms and 14 000 to 80 000 expansions
  on average per map (0.2-0.3 us an expansion); worst 73 000 nodes, 25 ms.
- Every "out of nodes" at 131072 was a goal that cannot be reached at all:
  rerun with 524288 nodes, the reachable counts were identical. A full
  flood of a map is up to 265 000 nodes, 80 ms. **No coarse stage is needed
  on these maps**; an unreachable goal is the expensive case.
- Walked time against planned: 1.0 to 1.25 (worst on Temple, CubeMaze, ClockTown: stairs, (f)4).
- Memory: search 5.5 MiB (22 MiB at 524288 nodes), table 35 KiB, route 10 KiB, follower < 100 bytes, map 2 MiB, cull 7.1 MiB.
- **Not run:** soak with edits (`BC_SOAK_EDITS=1` exists, untried), delays of 0 and 2 ticks, more than 200 pairs.

Progress of the same soak during the work: first full run 9 lost and 16
stuck; after the fixes of the last hour 6 lost and 8 stuck.

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

## (f) Open, most important first

1. **The ground safety rule judges by height only.** A pace is "safe" if a
   simulated emergency stop keeps the feet no lower than the lower end of
   the current step. Beside a turn at the bottom of a staircase, a ledge at
   that same height is "safe" to slide onto, and it may lead nowhere: all 5
   Parkour2 losses (sprints down a stair, overshoots the turn at 9 voxels/s
   onto a side ledge, falls on into the sea; goal then unreachable). Next:
   in `ground_safe` also require the body to stay over the route's columns
   or their neighbours (or: that a plan from where the stop ends still
   exists and costs no more), and slow for turns after a descent.
2. **The Temple loss**: 23 OFF_ROUTE in a row on one pair, never arrives.
   Untraced. `BC_SOAK_MAP=Temple.vxl BC_SOAK_PAIR=245,450,52,203,232,43`
   reproduces it. Probably a replan start node that the body is not really
   on (`bc_nav_node_of_body` picking a column under a corner).
3. **Never built with GCC or on Linux**, where botd will run.
   `lsd_core.c` compiling demoncore.c under `-pedantic -Werror` may need a
   cast or two there, and `cull_parity_test.c` uses a `#pragma GCC
   diagnostic` round the libpvx2 includes. body_test's drift hash uses
   `cosf`/`sinf` for the script's facings: if it differs on glibc, replace
   them with a table before believing it.
4. **Stairs cost more than planned** (walked/planned up to 1.25): the
   stride up was timed from a flat run; each climb halves speed. Measure it
   on a staircase (third tread onward).
5. **The 8 stuck reports on Temple**: recovered, but untraced. Likely
   bodies on a neighbour's higher edge during ground steps.
6. **Edits in the soak**: never run. The scenarios pass; real maps will find things.
   A caller must also react to EDIT_REFUSED by more than protecting one
   voxel (the test harness stops editing after two refusals, as aosbot did after a run).
7. No knight's-move jumps, no jumps under low ceilings, no diagonal drops in
   the planner, nothing but wade/climb-out from water (nav.h lists these).
8. `tests/nav_test.c` `floor_removed_midway` has a leftover unused block
   (`w2`) and is weaker than its name: it cuts the causeway before the
   second run, not during. Harmless; tidy it.
9. The planner prices later steps against the unedited map (except the room
   the body stands in). Fine for tunnels and bridges; a staircase built
   into the open pays for a support block it may not need.

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

### Suggested changes to bot/README.md

- The mechanics row says "aosbot, ported". Map and cull are ported from the
  *server* (libpvx2), the physics is the server's file compiled in, and nav
  is new on aosbot's lessons. Its test rule ("a ported module replays cases
  recorded from aosbot") does not fit them: map and cull are tested against
  the server's code, nav against the physics.
- Add `lsd_core.*` to the table and say the core is built `-ffp-contract=off`.
- Say where test maps come from (`BC_TEST_MAPS`), or put two small `.vxl` in the repo.
