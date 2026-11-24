/* nav.h -- Getting a body from here to there: moves, plan, follower
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * WHY THIS IS NOT AOSBOT'S PLANNER. aosbot searched a 2D grid with a few
 * height layers and three hard-coded moves (step up 1, jump up 2, drop 5),
 * and its executor steered by its own idea of the physics. In play its
 * bots got stuck often and could not parkour: a one-voxel gap was a wall.
 * Both faults have one root -- the plan and the walk each GUESSED what a
 * body can do, and guessed differently from the server.
 *
 * Here nothing is guessed:
 *
 *   1. THE MOVES ARE MEASURED. At start-up bc_nav_moves_measure builds
 *      small scenes on a scratch map, puts a body in them (body.h: the
 *      server's own physics) and has the follower's own controllers try
 *      every move: walk, sprint, crouch-walk, step up, drop, standing jump
 *      and running jump for each gap length and height difference, wading,
 *      climbing out of water. What works goes in a table with what it
 *      costs in seconds, how much run-up it needs, how wide the window to
 *      press jump is, and the voxels the body swept (which must be free).
 *      If LSd's physics changes, the table changes with it -- and
 *      nav_test, which pins the table, says so.
 *   2. THE PLAN is an A* over the places a body can stand, (x, y, feet z),
 *      whose edges are that table. A running jump over three voxels of
 *      nothing is an edge like any other.
 *   3. THE FOLLOWER re-simulates before it commits. It does not press jump
 *      because the plan said so: it copies the body as it really is this
 *      tick, simulates the jump on the real map, and presses only if the
 *      copy lands. Otherwise it backs up for a longer run or reports the
 *      step failed. On the ground it only keeps a pace from which it has
 *      checked it can still stop without falling.
 *
 * WHAT IS KEPT FROM AOSBOT (docs/internals/03, 06), with its reasons:
 *   - The bit-column map (map.h) and the node convention: a node's z is
 *     the FLOOR voxel the feet are on.
 *   - Edit moves as edges with a price, so "dig through" and "walk round"
 *     compete in one search: dig a way in, dig down, lay a floor and cross
 *     (bridge), lay a step and climb (stairs), pillar up. The cheapest
 *     level wins on its own -- taking the first feasible one made a bot
 *     dig a block and put it back, for ever.
 *   - A build needs a face to stick to; the floor one stands on counts,
 *     which is what makes a causeway. A ramp into the open does not.
 *   - Protected voxels and no-dig/no-build zones are WALLS, not prices:
 *     any finite price gets paid, and a refused edit costs a block and
 *     three seconds each time.
 *   - Lethal water is never ENTERED, for the same reason; other water
 *     costs time (wading is two thirds of walking pace, measured) plus
 *     water_secs a voxel, because a body in water is a target, plus what
 *     its damage is worth (water_damage). A body already IN water, lethal
 *     or not, is always given the way out: see WATER below.
 *   - A diagonal step needs both its corner columns walkable: the server
 *     resolves x and y one after the other and a knife-edge diagonal put
 *     bots in the sea.
 *   - A crouch gap is a move, cheap enough that a lintel is ducked under
 *     and not dug out (its price is its measured time at 2.4 voxels/s).
 *   - The start of a plan is the floor under the body INCLUDING its
 *     corners: a body stands with its centre over thin air.
 *
 * UNITS. Cost is SECONDS throughout. The heuristic is straight-line
 * horizontal distance at the measured sprint speed, the fastest a body
 * crosses ground (a jump's flight is slower), so it never overestimates.
 *
 * COORDINATES. A node is (x, y, z): the column and the floor voxel. The
 * body standing there has its feet at z (the top face of that voxel) and
 * its eye near z - 2.25. A water node has z = 63 and the feet at 64.
 *
 * MEMORY, all the caller's:
 *   bc_nav_moves    the table: ~40 KiB, one per process, read-only after
 *                   measuring. Measuring needs a scratch bc_map (2 MiB)
 *                   for its duration only.
 *   bc_nav_search   one search in progress: bc_nav_search_size(max_nodes)
 *                   bytes, 48 a node; 6 MiB for the default 131072 nodes.
 *                   A bot needs one only while it plans, so a host keeps a
 *                   few and lends them.
 *   bc_nav_route    512 steps, 10 KiB, one per bot.
 *   bc_nav_follow   under 200 bytes, one per bot.
 *   bc_nav_fail     128 remembered failures, 2.5 KiB; shareable.
 *   bc_nav_protect  refused voxels, 36 KiB; shareable.
 * Nothing allocates, nothing is global, no call blocks: a plan is advanced
 * a budget of expansions at a time.
 *
 * WHAT IS NOT DONE (bot/NAV-STATUS.md has the list and the numbers):
 *   - Jumps go along an axis or a diagonal only, up to 7 columns; there
 *     are no knight's-move jumps and none measured under a low ceiling.
 *   - From water the moves are wading, the jump onto a bank one voxel
 *     up, and (with digging allowed) cutting a higher bank down to that.
 *     Nothing is built in the sea: see WATER below for why.
 *   - Drops are planned along an axis only (the table has diagonal ones).
 *   - A plan prices each edit against the map as it is: it does not know
 *     that an earlier step on the same route will have changed it, beyond
 *     the room the body itself stands in.
 *   - There is no coarse stage. Measured on eight real maps none is
 *     needed for a goal that can be reached (worst 73 000 nodes, 25 ms);
 *     a goal that cannot floods everything it can reach first, up to the
 *     pool. Give a search a budget and a deadline.
 *
 * WATER, as measured (body_test and nav_test pin it; NAV-STATUS.md has the
 * table). A water column is one whose only solid voxel is 63; a body in it
 * stands with its feet at 64 and WADES at two thirds of walking pace. There
 * is no deep water and no swimming: every sea is one voxel deep.
 *   - A bank whose top is z = 62 (the lowest land there is: one voxel above
 *     the sea bed's top, two above the wading feet) is NOT climbed by
 *     walking into it, at any pace. It is climbed by a JUMP pressed while
 *     walking or sneaking into it -- at any tick, from any distance that
 *     still reaches it in the air -- and by no jump with SPRINT held (the
 *     server's one-voxel haul, which finishes the climb, refuses a
 *     sprinter). The jump controller never sprints there.
 *   - A bank whose top is z = 61 or higher cannot be got onto from the
 *     water by any keys (short of the crouch-in-the-air fault of body.h,
 *     which nothing here uses). The plan goes ALONG the shore to a place
 *     where the bank is 62 -- or, when it may dig, cuts the bank column
 *     down to 62 from the water (voxels 61 and up; 62 cannot be dug) and
 *     jumps onto what is left: a DIG step whose motion is that jump.
 *   - Nothing can be BUILT to get out. The server builds at z <= 61 only,
 *     and a block at 61 is three above the wading feet: a higher bank, not
 *     a step.
 *   - A sea with no way out at all (every bank too high, no digging) is
 *     known at once: before a search from a water node to a goal on land,
 *     bc_nav_plan_begin floods the sea the start is in (bit rows, well
 *     under a millisecond) and looks for one place the body could leave
 *     it. With none the plan is FAILED straight away, with a route of no
 *     steps -- not after a search of the whole sea each time it is asked.
 */
#ifndef BC_NAV_H
#define BC_NAV_H

#include <stddef.h>
#include <stdint.h>

#include "body.h"
#include "map.h"

/* ================================================================== */
/* 1. THE MOVE TABLE                                                   */

/* What a route's step tells the body to do. */
enum bc_nav_kind {
	BC_NAV_NONE = 0,
	BC_NAV_WALK,      /* to the next column: level, one up (the free
	                     climb) or one down */
	BC_NAV_SPRINT,    /* the same at a run; never one up (no climb) */
	BC_NAV_CROUCH,    /* crouched, under a two-voxel ceiling */
	BC_NAV_DROP,      /* walk off an edge and land two or more below */
	BC_NAV_JUMP,      /* a jump from a standing start: up a two-voxel
	                     step, or over a short gap */
	BC_NAV_RUNJUMP,   /* a jump that needs speed: sprinting, and maybe
	                     `runup` columns of straight floor behind */
	BC_NAV_DIG,       /* remove voxels, then walk in */
	BC_NAV_BUILD,     /* place voxels (and maybe dig), then walk in:
	                     a bridge when level, a stair when one up */
	BC_NAV_PILLAR,    /* jump and place a voxel under the feet */
	BC_NAV_KINDS
};

const char *bc_nav_kind_name(int kind);

enum { BC_NAV_CLS_AXIS = 0, BC_NAV_CLS_DIAG = 1 };

enum {
	BC_NAV_MOVES_MAX = 512,
	BC_NAV_MASK_POOL = 6144,
	BC_NAV_JUMP_DMAX = 7,       /* columns along the direction */
	BC_NAV_DZ_MIN = -3,         /* up */
	BC_NAV_DZ_MAX = 9,          /* down */
	BC_NAV_DZ_N = 13,
	BC_NAV_MASK_Z0 = 6          /* a mask's bit k is the voxel at
	                               z = from.z - 6 + k */
};

/* One column of a swept volume, relative to the move's start column in
 * its canonical direction (+x for axis moves, +x+y for diagonal ones). */
typedef struct bc_nav_mcol {
	int8_t dx, dy;
	uint16_t bits;              /* voxels that must be air */
} bc_nav_mcol;

/* One measured move, in its canonical direction. */
typedef struct bc_nav_move {
	uint8_t kind;               /* bc_nav_kind */
	uint8_t cls;                /* axis or diagonal */
	int8_t d;                   /* columns travelled along the direction */
	int8_t dz;                  /* to.z - from.z: negative is up */
	uint8_t runup;              /* columns of level floor needed behind */
	uint8_t sprint;             /* held sprint */
	uint8_t margin;             /* how many consecutive ticks pressing
	                               jump works, from a standing start at
	                               the run-up's far end; 0 for non-jumps */
	uint8_t damage;             /* hit points the landing costs */
	uint8_t from_water;         /* measured starting in a water column */
	uint8_t pad_[3];
	float secs;                 /* what it takes */
	uint16_t mask_off, mask_n;  /* its swept columns in `cols` */
} bc_nav_move;

typedef struct bc_nav_moves {
	/* measured paces, voxels per second */
	float walk_speed, sprint_speed, crouch_speed, sneak_speed, wade_speed;
	/* measured body: voxels of air needed over a floor */
	uint8_t stand_cells, crouch_cells;
	uint8_t pad_[2];
	/* the widest gap (in whole voxels of nothing, same height) crossed
	 * at a walk and at a sprint, for the record */
	uint8_t gap_walk, gap_sprint;
	uint8_t pad2_[2];

	int32_t n;
	bc_nav_move mv[BC_NAV_MOVES_MAX];
	int32_t ncols;
	bc_nav_mcol cols[BC_NAV_MASK_POOL];

	/* indexes into mv, -1 when the body cannot do it */
	int16_t walk[2][3];         /* [cls][dz + 1] */
	int16_t sprint[2][3];
	int16_t crouch[2][3];
	int16_t drop[2][BC_NAV_DZ_N];                       /* [cls][dz - DZ_MIN] */
	int16_t jump[2][BC_NAV_JUMP_DMAX + 1][BC_NAV_DZ_N]; /* [cls][d][dz - DZ_MIN] */
	int16_t wade[2];            /* water to water */
	int16_t water_out[2][4];    /* [cls][voxels up]: from z = 63 to 63 - up */

	/* STRIDES IN CONTEXT. What a stride takes depends on the one before
	 * it: a climb halves the body's speed, a stair downward is taken half
	 * in the air where a body hardly accelerates, a turn has the old
	 * velocity to kill (it follows the facing with a quarter-second lag)
	 * and a start from rest has all of it to find. A lone stride's time
	 * (mv[].secs, measured once in a flat run) knows none of that, and
	 * plans priced with it alone came out a quarter short on hilly maps
	 * -- and wandered: with no price on a turn, every zigzag between two
	 * points costs the same as the straight way.
	 *
	 * So these too are measured, by having THE FOLLOWER walk built courses
	 * (flat, stairs up then down, down then up, turns of each angle) and
	 * timing it. The plan prices a WALK or SPRINT stride on land by them:
	 *   stride_secs[cls][before][dz + 1]   before: bc_nav_before
	 *   turn_secs[cls of the stride before][eighths of a turn, 1..4]
	 * added when the direction changes between two strides. */
	float stride_secs[2][4][3];
	float turn_secs[2][5];
} bc_nav_moves;

/* What the body was doing before a stride: climbing, running level, going
 * down, or anything that leaves it about at rest (the start of a route, a
 * landing, an edit, a crouch). */
enum bc_nav_before { BC_NAV_AFTER_UP = 0, BC_NAV_AFTER_LEVEL, BC_NAV_AFTER_DOWN, BC_NAV_AFTER_REST };

/* Measure everything. `scratch` is a map this call may scribble on (its
 * contents are lost); it is not kept. Takes a few hundred milliseconds:
 * once per process. Returns the number of moves found. */
int bc_nav_moves_measure(bc_nav_moves *t, bc_map *scratch);

/* ================================================================== */
/* 2. WHAT A PLAN MAY DO: the policy                                   */

typedef struct bc_nav_node { int16_t x, y, z; } bc_nav_node;

/* A rectangle of columns (corners included) where edits are refused: a
 * gamemode's rule known in advance -- babel's towers, a spawn. */
typedef struct bc_nav_zone {
	int16_t x0, y0, x1, y1;
	uint8_t no_dig, no_build;
	uint8_t pad_[2];
} bc_nav_zone;

/* Voxels the server refused to let somebody edit, learned one at a time.
 * A bit per column first, so the common answer ("no") is one load. */
enum { BC_NAV_PROTECT_MAX = 1024 };
typedef struct bc_nav_protect {
	uint64_t colbits[BC_MAP_XY / 64];
	uint32_t n;
	uint32_t vox[BC_NAV_PROTECT_MAX];
} bc_nav_protect;

void bc_nav_protect_clear(bc_nav_protect *p);
/* Remember a voxel. When full the oldest is forgotten (its column's bit
 * may stay set: a false "maybe", never a false "no"). */
void bc_nav_protect_add(bc_nav_protect *p, int x, int y, int z);
int bc_nav_protect_has(const bc_nav_protect *p, int x, int y, int z);

/* A place it is bad to be: every column entered within `radius` costs
 * weight * (1 - distance / radius) seconds more. */
typedef struct bc_nav_danger { float x, y, radius, weight; } bc_nav_danger;

/* Moves that failed in practice. The follower says a step failed; the
 * caller notes it here; plans made until it expires pay `penalty` seconds
 * for that exact move (from, to, kind), doubled for each repeat, so the
 * next plan goes another way if there is one and still has this way if
 * there is not. Shared between bots it is a team learning a map. */
enum { BC_NAV_FAIL_MAX = 128 };
typedef struct bc_nav_fail_entry {
	uint32_t from, to;          /* packed nodes; 0: empty */
	double until;               /* the caller's clock, seconds */
	uint8_t kind, count;
	uint8_t pad_[6];
} bc_nav_fail_entry;
typedef struct bc_nav_fail {
	bc_nav_fail_entry e[BC_NAV_FAIL_MAX];
} bc_nav_fail;

void bc_nav_fail_clear(bc_nav_fail *f);
void bc_nav_fail_note(bc_nav_fail *f, bc_nav_node from, bc_nav_node to, int kind,
                      double now, double ttl);
/* How many times the move is remembered failing (0: not). */
int bc_nav_fail_count(const bc_nav_fail *f, bc_nav_node from, bc_nav_node to, int kind,
                      double now);

typedef struct bc_nav_policy {
	uint8_t may_dig;            /* edit moves that remove voxels */
	uint8_t may_build;          /* edit moves that place voxels */
	uint8_t may_jump;           /* JUMP and RUNJUMP */
	uint8_t water_lethal;       /* never ENTER water. A body already in it
	                               may wade (how else would it get out),
	                               priced as water_damage 30 at least, so
	                               it leaves by the nearest bank */
	uint8_t blocks;             /* in the pouch now: builds on a route
	                               never exceed it */
	uint8_t max_fall_damage;    /* hit points a single landing may cost
	                               (0: only drops that do not hurt) */
	uint8_t min_margin;         /* a jump needs this wide a window, ticks.
	                               The follower needs three good ticks in
	                               a row to press, so 3 is the floor */
	uint8_t pad_;
	float dig_secs;             /* per voxel removed: the bot's cadence,
	                               never under the server's 0.2 */
	float build_secs;           /* per voxel placed: never under 0.5 */
	float water_secs;           /* extra per water column entered */
	float fail_secs;            /* price of a remembered failure */
	const bc_nav_zone *zones;
	int32_t nzones;
	const bc_nav_danger *danger;
	int32_t ndanger;
	const bc_nav_protect *protect;      /* or NULL */
	const bc_nav_fail *fail;            /* or NULL */
	double now;                         /* for `fail`'s expiries */
	/* WATER THAT HURTS: health a second a wading body loses (the server's
	 * "water.damage" setting; 0: none). Every second a route spends in
	 * the water costs this many seconds more -- one hit point is priced as
	 * one second of walking, BC_NAV_HP_SECS. So at 5 a second a ford three
	 * columns wide costs about eight seconds: taken when the way round is
	 * longer than that, and at 30 a second about fifty: nearly never. A
	 * body that starts in such water leaves it by the cheapest bank, which
	 * with any real damage is the nearest. A caller that wants a hurt bot
	 * more careful still gives a larger number (damage * 100 / health). */
	float water_damage;
	/* HOW GREEDY THE SEARCH IS: the heuristic is multiplied by this (0 or
	 * 1: as it is, and the route found is the cheapest there is). The
	 * heuristic is the sprint over open ground; on a map that is mostly
	 * sea, or hills, real routes cost several times that and an exact
	 * search looks at half the map before it is sure (measured, 40 bots
	 * on prisonbreakv1: 59 000 expansions a plan). At 1.5 a route may cost
	 * up to half as much again as the best -- in practice a few percent --
	 * and the search looks at a fraction of the nodes. For a caller with
	 * many bodies and one budget. nav's own tests run at 1. */
	float h_weight;
} bc_nav_policy;

/* What a hit point is worth, in seconds of route. */
#define BC_NAV_HP_SECS 1.0f
/* The damage rate water_lethal stands for when a body is already in it. */
#define BC_NAV_LETHAL_DAMAGE 30.0f

/* Walk, sprint, jump, drop where it does not hurt; no edits; water at
 * 0.5 s a column and harmless. dig 0.5 s, build 0.7 s a voxel when switched on
 * (aosbot's mid-skill cadences). */
void bc_nav_policy_default(bc_nav_policy *p);

/* ================================================================== */
/* 3. THE ROUTE                                                        */

enum { BC_NAV_ROUTE_MAX = 512 };

enum bc_nav_step_flags {
	BC_NAV_F_WATER = 1          /* the step ends in water */
};

/* One step: from the previous step's `to` (or the route's start). */
typedef struct bc_nav_step {
	bc_nav_node to;
	uint8_t kind;               /* bc_nav_kind */
	uint8_t dir;                /* 0..7: E, SE, S, SW, W, NW, N, NE (x
	                               grows east, y south); 8: straight up
	                               or down */
	uint8_t runup;              /* RUNJUMP: floor columns behind `from` */
	uint8_t digs, builds;       /* voxels to edit, as planned */
	uint8_t flags;
	int16_t move;               /* the motion: index in the table, or -1 */
	float secs;                 /* planned cost of this step */
} bc_nav_step;

typedef struct bc_nav_route {
	bc_nav_node start;
	bc_nav_node goal;
	uint32_t map_rev;           /* the map it was planned on */
	int32_t n;
	float secs;                 /* of the n steps kept */
	uint8_t partial;            /* does not reach the goal: the search
	                               failed and this leads to the nearest
	                               place reached, or it was cut at
	                               BC_NAV_ROUTE_MAX steps */
	uint8_t pad_[3];
	bc_nav_step steps[BC_NAV_ROUTE_MAX];
} bc_nav_route;

/* The voxels step i still needs edited, on the map as it is now, in the
 * order to do them. Returns how many (at most 8); op[k] is
 * BC_BLOCK_DESTROY or BC_BLOCK_BUILD. */
int bc_nav_step_edits(const bc_nav_route *r, int i, const bc_nav_moves *t, const bc_map *m,
                      bc_nav_node vox[8], uint8_t op[8]);

/* ================================================================== */
/* 4. THE SEARCH                                                       */

enum bc_nav_plan_status {
	BC_NAV_MORE = 0,            /* not done: call again */
	BC_NAV_DONE = 1,            /* the goal is reached */
	BC_NAV_FAILED = 2           /* no way (everything reachable was
	                               looked at) or out of nodes; a partial
	                               route to the nearest place is there
	                               for the asking */
};

typedef struct bc_nav_search bc_nav_search;

/* Bytes for a search of at most max_nodes nodes. 131072 covers nearly
 * every route on a 512 x 512 map (nav_test's soak reports the worst). */
size_t bc_nav_search_size(uint32_t max_nodes);

/* Lay a search out in the caller's memory (bc_nav_search_size bytes,
 * aligned as malloc aligns). */
bc_nav_search *bc_nav_search_init(void *mem, uint32_t max_nodes);

/* Start a plan. The table, map, and policy (and what it points to) must
 * stay where they are until the plan is done or abandoned. The goal is
 * reached at any node within goal_radius columns of `goal` (0: that very
 * column) whose z is within 1 of goal.z. Returns 0 if `start` is not a
 * place to stand. */
int bc_nav_plan_begin(bc_nav_search *s, const bc_nav_moves *t, const bc_map *m,
                      const bc_nav_policy *pol, bc_nav_node start, bc_nav_node goal,
                      int goal_radius);
/* (From a water node with no way out of its sea, to a goal on land, it
 * returns 1 and the plan is already BC_NAV_FAILED with no route: WATER,
 * in the header comment.) */

/* Advance by at most `budget` expansions. About 0.3 microseconds each on
 * flat ground, a few when jumps and edits are weighed. */
int bc_nav_plan_step(bc_nav_search *s, int budget);

/* The route found; after BC_NAV_FAILED, the partial one. Returns its
 * number of steps. */
int bc_nav_plan_route(const bc_nav_search *s, bc_nav_route *out);

/* Expansions so far and nodes in use, for budgets and reports. */
uint32_t bc_nav_plan_expansions(const bc_nav_search *s);
uint32_t bc_nav_plan_nodes(const bc_nav_search *s);

/* The node a body is standing on (or falling towards), corners included.
 * 0 if there is none within reach under it. */
int bc_nav_node_of_body(const bc_map *m, const bc_body *b, bc_nav_node *out);

/* The nearest place to stand to a point: in its column first (nearest in
 * z), then in rings out to `radius`. 0 if none. */
int bc_nav_snap(const bc_map *m, int x, int y, int z, int radius, bc_nav_node *out);

/* The same, but DRY: water columns are passed over. For a caller that
 * wants somewhere to go near a point that may be in the sea (a tent in the
 * water, a body wading): bc_nav_snap there answers the sea bed. */
int bc_nav_snap_dry(const bc_map *m, int x, int y, int z, int radius, bc_nav_node *out);

/* ================================================================== */
/* 5. THE FOLLOWER                                                     */

enum bc_nav_follow_status {
	BC_NAV_FOLLOWING = 0,
	BC_NAV_ARRIVED = 1,         /* standing on the route's last node */
	BC_NAV_STEP_FAILED = 2,     /* this step cannot be done from here:
	                               see `why`; note it and plan again */
	BC_NAV_ROUTE_STALE = 3,     /* the map changed and a step ahead is no
	                               longer possible as planned */
	BC_NAV_OFF_ROUTE = 4,       /* the body is not where the route is
	                               (knocked off, fell, respawned) */
	BC_NAV_GIVE_UP = 5          /* this goal is not being got to: the same
	                               report has come from the same place
	                               BC_NAV_REPEAT_MAX times, or there have
	                               been BC_NAV_REPORTS_MAX in all. Do not
	                               plan for it again now (see NEVER A LOOP
	                               below); cmd.why says what the last
	                               report would have been */
};

enum bc_nav_why {
	BC_NAV_WHY_NONE = 0,
	BC_NAV_WHY_STUCK,           /* keys held, no movement */
	BC_NAV_WHY_TIMEOUT,         /* the step took far longer than planned */
	BC_NAV_WHY_NO_JUMP,         /* no tick at which the simulated jump
	                               lands, even after a full run-up */
	BC_NAV_WHY_NO_DROP,         /* the simulated drop does not land there,
	                               or hurts too much */
	BC_NAV_WHY_EDIT_REFUSED     /* asked for an edit and it never came */
};

enum bc_nav_edit { BC_NAV_EDIT_NONE = 0, BC_NAV_EDIT_DIG = 1, BC_NAV_EDIT_BUILD = 2 };

/* What to do this tick. */
typedef struct bc_nav_cmd {
	uint8_t keys;               /* bc_keys */
	uint8_t edit;               /* bc_nav_edit: the follower cannot edit
	                               the world; it asks, every tick until
	                               the map shows it done. The caller paces
	                               the asking to the server's rate. */
	uint8_t why;                /* bc_nav_why, on STEP_FAILED */
	uint8_t pad_;
	int16_t ex, ey, ez;         /* the voxel to edit */
	int16_t step;               /* the step being done */
	bc_v3 ori;                  /* where to face: movement is relative to
	                               it, so it is not a suggestion */
} bc_nav_cmd;

enum {
	/* THE CONTRACT ON BEING STUCK. While it answers FOLLOWING and is not
	 * waiting on an edit, the follower never lets this many ticks pass
	 * without the body moving a quarter of a voxel before it changes
	 * what it is doing. The first time on a step, it RECENTRES: lets go,
	 * walks to the middle of the column its feet are in (always
	 * reachable; at most BC_NAV_RECENTRE_TICKS), and takes the step
	 * again from there -- the moves were measured centre to centre, and
	 * a body caught on a corner is usually half a voxel from where the
	 * move begins. The second time it answers STEP_FAILED (WHY_STUCK).
	 * So: never more than 2 * 45 + 40 ticks, a little over two seconds,
	 * from the last movement to the report. */
	BC_NAV_STUCK_TICKS = 45,
	BC_NAV_RECENTRE_TICKS = 40,
	/* An edit asked for and not seen done in this many ticks is refused. */
	BC_NAV_EDIT_WAIT_TICKS = 180,

	/* NEVER A LOOP. Every answer but FOLLOWING and a true ARRIVED tells
	 * the caller to plan again, and nothing in a plan promises that the
	 * new route will not end the way the last one did: a body sprinted
	 * into the same bad corner 23 times running in the first soak, a full
	 * lap of the hill between each, and a wall that only the server knows
	 * of is walked into for ever by a bot with no other way to its goal.
	 * The failure memory (bc_nav_fail) makes a repeat dearer, never
	 * impossible -- rightly, the only way there must stay a way.
	 *
	 * So the follower counts. It remembers its last BC_NAV_REPORT_SLOTS
	 * reports for a goal -- what was said (status and why) and the column
	 * and floor the body was on -- across the routes of that goal, as long
	 * as each new route is started with bc_nav_follow_again and not
	 * bc_nav_follow_begin. The BC_NAV_REPEAT_MAX-th time the same thing is
	 * said from the same place, and in any case the BC_NAV_REPORTS_MAX-th
	 * report for one goal, it answers BC_NAV_GIVE_UP instead. An ARRIVED
	 * at the end of a PARTIAL route counts as a report too (a route to
	 * "as near as I could get" that is followed, planned again and comes
	 * out the same is the same loop).
	 *
	 * What the caller does with it is its business -- another goal, the
	 * same one a good while later, a shout for help -- but planning for
	 * the same goal again at once is exactly what it says not to do.
	 * Whatever happens a goal costs at most BC_NAV_REPORTS_MAX plans. */
	BC_NAV_REPEAT_MAX = 3,
	BC_NAV_REPORTS_MAX = 32,
	BC_NAV_REPORT_SLOTS = 12
};

/* One remembered report (see NEVER A LOOP). */
typedef struct bc_nav_report {
	uint32_t cell;              /* packed node the body was on; 0: empty */
	uint8_t status, why, count;
	uint8_t age;                /* reports since it was last made */
} bc_nav_report;

typedef struct bc_nav_follow {
	int32_t step;
	uint32_t map_rev;
	uint16_t step_ticks;        /* spent on this step */
	uint16_t still_ticks;       /* since the body last moved */
	uint16_t edit_ticks;        /* asking for the same edit */
	uint8_t phase;
	uint8_t attempts;
	uint8_t air_keys;
	uint8_t started;
	uint8_t xs_ticks;
	uint8_t recentre;           /* ticks left of walking back to the
	                               middle of the column stood in */
	uint8_t recentred;          /* done once on this step already */
	uint8_t pad_[3];
	bc_v3 anchor;               /* where it last moved from */
	bc_nav_node edit_vox;
	bc_v3 last_ori;
	/* the reports made for this goal, kept by bc_nav_follow_again */
	uint16_t reports;
	uint8_t pad2_[2];
	bc_nav_report seen[BC_NAV_REPORT_SLOTS];
} bc_nav_follow;

/* Start following the first route to a NEW goal: forgets everything. */
void bc_nav_follow_begin(bc_nav_follow *f, const bc_nav_route *r);

/* Start following another route to the SAME goal, planned because the
 * follower said to: everything is reset but the record of what has been
 * reported for this goal, which is what lets the follower end a loop (see
 * NEVER A LOOP). `f` must have been through bc_nav_follow_begin once. */
void bc_nav_follow_again(bc_nav_follow *f, const bc_nav_route *r);

/* One tick: given the route, the body as it is and the map as it is, the
 * keys and the facing. Simulates on copies of `b` (hundreds of physics
 * steps at most, a few microseconds); allocates nothing.
 *
 * WHAT IT GUARANTEES
 *  - It never presses jump unless a simulation from the body's real state
 *    on the real map lands on the step's target -- for jump now, one tick
 *    late and two ticks late, so the link's delay does not matter. Within
 *    the window it presses late (while the window is still open five
 *    ticks on, it keeps running): an early jump lands short and is hauled
 *    up by the far lip, a late one lands well on.
 *  - It never walks off an edge unless the simulated drop lands on the
 *    step's target within policy->max_fall_damage.
 *  - On the ground it keeps the fastest pace (sprint, walk, sneak) from
 *    which a simulated emergency stop ends ON THE ROUTE'S SAFE CELLS: the
 *    body never below the route's floor on the way, and at rest with its
 *    centre over one of the route's own columns or a floor it can walk
 *    straight back from (two plain strides at most). It asks this for a
 *    stop begun three ticks from now -- the guarantee, which covers the
 *    link's delay -- and for one begun a quarter of a second from now --
 *    the foresight that slows it BEFORE a turn with a drop beside it.
 *    (Height alone was the first rule, and is not enough: a body that
 *    overshoots a turn onto a ledge at the route's own level is "not
 *    below the route", and neither is one hanging over a slope by a
 *    corner. Those were the lost routes of the first soak.)
 *  - It never changes crouch in the air, nor stands up under a ceiling
 *    (body.h says why).
 *  - It answers something other than FOLLOWING within BC_NAV_STUCK_TICKS
 *    of ceasing to make progress, with the keys released: the caller
 *    notes the failure (bc_nav_follow_failed + bc_nav_fail_note) and
 *    plans again from where the body is. It does not grind.
 *  - When the map's revision changes it re-checks every step ahead
 *    against the map and answers ROUTE_STALE if one no longer holds.
 *  - It does not loop: started on each new route with
 *    bc_nav_follow_again, it answers BC_NAV_GIVE_UP rather than say the
 *    same thing from the same place a third time (NEVER A LOOP, above).
 * On any answer but FOLLOWING the command brakes. */
int bc_nav_follow_tick(bc_nav_follow *f, const bc_nav_route *r, const bc_nav_moves *t,
                       const bc_map *m, const bc_body *b, const bc_nav_policy *pol,
                       bc_nav_cmd *out);

/* The move the follower was on, for bc_nav_fail_note. 0 if none. */
int bc_nav_follow_failed(const bc_nav_follow *f, const bc_nav_route *r,
                         bc_nav_node *from, bc_nav_node *to, int *kind);

#endif /* BC_NAV_H */
