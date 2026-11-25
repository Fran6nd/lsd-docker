/* nav_test.c -- nav: the measured move table, scenarios, and a soak.
 *
 *   nav_test                 the table and every scenario
 *   nav_test -v NAME         one scenario, with its plans and failures
 *   nav_test --table         print the whole measured table
 *   BC_TEST_MAPS=dir nav_test   also soak on every .vxl in dir
 *     BC_SOAK_PAIRS=n          pairs a map (default 200)
 *     BC_SOAK_LATENCY=n        ticks of command delay (default 1)
 *     BC_SOAK_EDITS=1          let the bots dig and build
 *     BC_SOAK_WATER=1          every other pair STARTS in the water (a random
 *                              water column), and those are reported apart.
 *                              Without it starts and goals are both dry land
 *                              -- which is all the soak sampled before a map
 *                              with its tents in the sea showed what that hid
 *     BC_SOAK_NODES=n          the search's node pool (default 131072)
 *     BC_SOAK_SHOW=1           print each pair that did not arrive, or took
 *                              far from its estimate
 *     BC_SOAK_COSTS=1          walked against planned, by kind of step
 *     BC_SOAK_MAP=file.vxl     that map only
 *     BC_SOAK_PAIR=ax,ay,az,bx,by,bz   that pair only, with its plans
 *     BC_SOAK_TRACE=1          ...and every tick of it
 *
 * Every scenario is the whole chain: plan on the map, follow in a body
 * moved by the server's physics, until the follower says ARRIVED or the
 * tick cap runs out.
 */
#include <dirent.h>

#include "nav_i.h"
#include "nav_sim.h"
#include "rng.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; \
	printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

#define G 40                    /* the ground in the synthetic scenes */
#define K(k) (1u << (k))
#define JUMPS (K(BC_NAV_JUMP) | K(BC_NAV_RUNJUMP))

static sim_world W;
static const char *only;        /* -v NAME */
static unsigned pool_nodes = 1u << 17;

/* --- scene building ---------------------------------------------------- */

static void col_top(bc_map *m, int x, int y, int top)
{
	if (x < 0 || x >= BC_MAP_X || y < 0 || y >= BC_MAP_Y)
		return;
	m->col[y * BC_MAP_X + x] = top >= 64 ? 0 : ~(uint64_t)0 << top;
	m->rev++;
}

static void area_top(bc_map *m, int x0, int y0, int x1, int y1, int top)
{
	int x, y;

	for (y = y0; y <= y1; y++)
		for (x = x0; x <= x1; x++)
			col_top(m, x, y, top);
}

static void box(bc_map *m, int x0, int y0, int z0, int x1, int y1, int z1, int solid)
{
	int x, y, z;

	for (z = z0; z <= z1; z++)
		for (y = y0; y <= y1; y++)
			for (x = x0; x <= x1; x++)
				bc_map_set(m, x, y, z, solid);
}

static bc_nav_node node(int x, int y, int z)
{
	bc_nav_node n;

	n.x = (int16_t)x; n.y = (int16_t)y; n.z = (int16_t)z;
	return n;
}

static void fresh(int ground)
{
	bc_map_fill_flat(W.m, ground);
	W.truth = W.m;
	bc_nav_fail_clear(&W.fail);
	bc_nav_protect_clear(&W.prot);
	W.srv_protect = 0;
	W.place_tick = 0;
	W.destroy_tick = 0;
	W.destroy_at_x = 0.0f;
	W.latency = 0;
}

static int begin(const char *name)
{
	if (only && strcmp(only, name) != 0)
		return 0;
	W.verbose = only != NULL;
	W.trace = only != NULL && getenv("BC_SOAK_TRACE") != NULL;
	if (only)
		printf("== %s\n", name);
	return 1;
}

/* every edit a route asked for that the server's rule refused (a face the
 * eye could not see): none, over every scenario and the soak */
static int all_vis_refused;

static void report(const char *name, const sim_result *r)
{
	printf("  %-28s %s in %5.2fs (planned %5.2fs), %d plan(s), %u exp, kinds:", name,
	       r->arrived ? "arrived" : "NOT ARRIVED", (double)r->ticks / 60.0, (double)r->route_secs,
	       r->plans, r->max_exp);
	{
		int k;

		for (k = 1; k < BC_NAV_KINDS; k++)
			if (r->kinds & K(k))
				printf(" %s", bc_nav_kind_name(k));
	}
	if (r->step_fails || r->stale || r->off_route)
		printf("  [%d step fail, %d stale, %d off]", r->step_fails, r->stale, r->off_route);
	if (r->vis_refused)
		printf("  [%d edits not in the eye's sight, refused]", r->vis_refused);
	printf("\n");
	all_vis_refused += r->vis_refused;
}

/* --- the table ---------------------------------------------------------- */

static void print_table(const bc_nav_moves *t)
{
	int i;

	printf("pace: walk %.3f sprint %.3f crouch %.3f sneak %.3f wade %.3f voxels/s\n",
	       (double)t->walk_speed, (double)t->sprint_speed, (double)t->crouch_speed,
	       (double)t->sneak_speed, (double)t->wade_speed);
	printf("body: stands in %d voxels, crouches in %d; widest level gap: %d at a walk, "
	       "%d at a sprint\n", t->stand_cells, t->crouch_cells, t->gap_walk, t->gap_sprint);
	for (i = 0; i < 2; i++) {
		static const char *const before[4] = {"a climb", "a level run", "a step down", "rest"};
		int a;

		for (a = 0; a < 4; a++)
			printf("stride %s after %-12s up %.3fs  level %.3fs  down %.3fs\n",
			       i ? "diag" : "axis", before[a], (double)t->stride_secs[i][a][0],
			       (double)t->stride_secs[i][a][1], (double)t->stride_secs[i][a][2]);
		printf("turn out of %s strides: 45 deg +%.3fs  90 +%.3fs  135 +%.3fs  180 +%.3fs\n",
		       i ? "diag" : "axis", (double)t->turn_secs[i][1], (double)t->turn_secs[i][2],
		       (double)t->turn_secs[i][3], (double)t->turn_secs[i][4]);
	}
	for (i = 0; i < t->n; i++) {
		const bc_nav_move *v = &t->mv[i];

		printf("%3d %-7s %s d=%d dz=%+d runup=%d sprint=%d window=%3d dmg=%2d %s %.3fs %2d cols\n",
		       i, bc_nav_kind_name(v->kind), v->cls ? "diag" : "axis", v->d, v->dz, v->runup,
		       v->sprint, v->margin, v->damage, v->from_water ? "water" : "land ",
		       (double)v->secs, v->mask_n);
	}
}

/* What is pinned is what a move IS -- kind, shape, run-up, sprint, damage
 * -- not its time or its window to the tick, which a harmless change to a
 * controller's law moves. A change in the physics moves the first. */
static uint32_t table_sum(const bc_nav_moves *t)
{
	uint32_t h = 2166136261u;
	int i;

	for (i = 0; i < t->n; i++) {
		const bc_nav_move *v = &t->mv[i];
		uint8_t b[8];
		int k;

		b[0] = v->kind; b[1] = v->cls; b[2] = (uint8_t)v->d; b[3] = (uint8_t)v->dz;
		b[4] = v->runup; b[5] = v->sprint; b[6] = v->damage; b[7] = v->from_water;
		for (k = 0; k < 8; k++)
			h = (h ^ b[k]) * 16777619u;
	}
	return h;
}

static const bc_nav_move *jump_of(const bc_nav_moves *t, int cls, int d, int dz)
{
	int i = t->jump[cls][d][dz - BC_NAV_DZ_MIN];

	return i >= 0 ? &t->mv[i] : NULL;
}

static void test_table(void)
{
	const bc_nav_moves *t = W.t;
	const bc_nav_move *v;
	int d;

	/* the body and its paces: the server's constants, seen from outside */
	CHECK(t->stand_cells == 3);
	CHECK(t->crouch_cells == 2);
	CHECK(t->walk_speed > 7.99f && t->walk_speed < 8.01f);
	CHECK(t->sprint_speed > 10.39f && t->sprint_speed < 10.41f);
	CHECK(t->crouch_speed > 2.39f && t->crouch_speed < 2.41f);
	CHECK(t->sneak_speed > 3.99f && t->sneak_speed < 4.01f);
	CHECK(t->wade_speed > 5.32f && t->wade_speed < 5.35f);

	/* strides */
	CHECK(t->walk[0][0] >= 0);          /* a walk climbs one */
	CHECK(t->sprint[0][0] < 0);         /* a sprint does not */
	CHECK(t->crouch[0][0] < 0);         /* nor a crouch */
	CHECK(t->walk[0][1] >= 0 && t->sprint[0][1] >= 0 && t->crouch[0][1] >= 0);
	CHECK(t->walk[1][1] >= 0 && t->sprint[1][1] >= 0);
	if (t->sprint[0][1] >= 0 && t->walk[0][1] >= 0)
		CHECK(t->mv[t->sprint[0][1]].secs < t->mv[t->walk[0][1]].secs);

	/* up: two voxels with a jump, never three */
	v = jump_of(t, 0, 1, -2);
	CHECK(v && v->kind == BC_NAV_JUMP && v->runup == 0);
	CHECK(jump_of(t, 0, 1, -3) == NULL);
	CHECK(jump_of(t, 1, 1, -2) != NULL);

	/* across: what the owner calls parkour. From a standing start a body
	 * clears 1, 2, 3 and 4 voxels of nothing; 5 and 6 need a sprint and
	 * three columns of run-up; 7 cannot be done. */
	for (d = 2; d <= 5; d++) {
		v = jump_of(t, 0, d, 0);
		CHECK(v && v->kind == BC_NAV_JUMP && v->runup == 0 && v->margin >= 5);
	}
	v = jump_of(t, 0, 6, 0);
	CHECK(v && v->kind == BC_NAV_RUNJUMP && v->sprint && v->margin >= 5);
	v = jump_of(t, 0, 7, 0);
	CHECK(v && v->kind == BC_NAV_RUNJUMP && v->sprint && v->margin >= 3);
	CHECK(t->gap_walk == 5);
	CHECK(t->gap_sprint == 6);
	/* the two-voxel gap, one up and one down as well */
	CHECK(jump_of(t, 0, 3, -1) != NULL);
	CHECK(jump_of(t, 0, 3, 1) != NULL);

	/* down: nine voxels do not hurt, and the table knows what does */
	CHECK(t->drop[0][9 - BC_NAV_DZ_MIN] >= 0);
	if (t->drop[0][9 - BC_NAV_DZ_MIN] >= 0)
		CHECK(t->mv[t->drop[0][9 - BC_NAV_DZ_MIN]].damage == 0);

	/* water: wading is slow, the bank one up needs a jump, two up is a wall */
	CHECK(t->wade[0] >= 0 && t->wade[1] >= 0);
	CHECK(t->water_out[0][1] >= 0 && t->mv[t->water_out[0][1]].kind == BC_NAV_JUMP);
	CHECK(t->water_out[0][2] < 0);

	/* and the whole shape of it */
	CHECK(t->n == 166);
	CHECK(table_sum(t) == 0x11e9f6b8u);
	if (table_sum(t) != 0x11e9f6b8u || t->n != 166)
		printf("  table: %d moves, sum 0x%08x -- the physics or a controller changed; "
		       "run `nav_test --table`, read it, then pin the new values\n",
		       t->n, table_sum(t));
}

/* --- scenarios ----------------------------------------------------------- */

/* Ground, a trench the whole width of the map `gap` voxels wide (so there
 * is no way round), ground again `dz` lower. */
static void trench_scene(int gap, int dz)
{
	fresh(G);
	area_top(W.m, 110, 0, 110 + gap - 1, BC_MAP_Y - 1, 62);
	if (dz)
		area_top(W.m, 110 + gap, 0, BC_MAP_X - 1, BC_MAP_Y - 1, G + dz);
}

static sim_result cross_trench(int gap, int dz, const bc_nav_policy *pol)
{
	return sim_run(&W, *pol, node(100, 100, G), node(110 + gap + 6, 100, G + dz), 0, 3000);
}

static void test_gaps(void)
{
	bc_nav_policy pol;
	sim_result r;
	char name[64];
	int gap;

	bc_nav_policy_default(&pol);
	pol.min_margin = 3;

	/* every width the table says a body clears, by plan and follower */
	for (gap = 1; gap <= W.t->gap_sprint; gap++) {
		snprintf(name, sizeof name, "gap_%d", gap);
		if (!begin(name))
			continue;
		trench_scene(gap, 0);
		r = cross_trench(gap, 0, &pol);
		report(name, &r);
		CHECK(r.arrived);
		CHECK(r.kinds & JUMPS);
		CHECK(r.max_feet < G + 1.2f);   /* never in the trench (a short jump
		                                   is pulled up by the far lip: the
		                                   server's climb, a voxel at most) */
		CHECK(r.damage == 0);
		if (gap <= 4)
			CHECK(r.kinds & K(BC_NAV_JUMP));        /* no run-up needed */
		else if (gap >= 5)
			CHECK(r.kinds & K(BC_NAV_RUNJUMP));     /* sprint and run-up */
	}

	/* at the very top of the map (a slab at z 0, the head above the
	 * map) a jump is the jump measured lower down: above the map is air to
	 * the server's physics (demoncore.c phys_solid) as to ours. Every
	 * width, crossed as at the bottom of a deep drop: the same ticks, no
	 * fall. (A rule that refused jumps in the map's top three voxels was
	 * added for a fall seen live on keidoro's slab; the physics does not
	 * give it -- this -- and the same change stopped the net's step back
	 * and sidestep from walking off an edge.) */
	if (begin("top_of_map_jumps")) {
		sim_result top, low;

		memset(&top, 0, sizeof top);
		memset(&low, 0, sizeof low);
		for (gap = 1; gap <= W.t->gap_sprint; gap++) {
			int z;

			for (z = 0; z <= 10; z += 10) {
				fresh(40);
				box(W.m, 80, 80, z, 109, 120, z, 1);
				box(W.m, 110 + gap, 80, z, 140, 120, z, 1);
				r = sim_run(&W, pol, node(100, 100, z), node(110 + gap + 6, 100, z), 0, 3000);
				if (z == 0) top = r; else low = r;
			}
			CHECK(top.arrived && top.damage == 0 && top.max_feet < 1.2f);
			CHECK(top.ticks == low.ticks && top.kinds == low.kinds);
		}
		report("top_of_map_jumps (the widest)", &top);
	}

	/* the same with the link's delay: commands land two ticks late */
	if (begin("gap_3_late")) {
		trench_scene(3, 0);
		W.latency = 2;
		r = cross_trench(3, 0, &pol);
		report("gap_3_late", &r);
		CHECK(r.arrived && r.max_feet < G + 1.2f);
	}
	if (begin("gap_6_late")) {
		trench_scene(6, 0);
		W.latency = 2;
		r = cross_trench(6, 0, &pol);
		report("gap_6_late", &r);
		CHECK(r.arrived && r.max_feet < G + 1.2f);
	}

	/* one voxel too wide: refused... */
	if (begin("gap_too_wide")) {
		gap = W.t->gap_sprint + 1;
		trench_scene(gap, 0);
		r = cross_trench(gap, 0, &pol);
		report("gap_too_wide", &r);
		CHECK(!r.arrived);
		CHECK(r.first_plan_status == BC_NAV_FAILED);
		CHECK(r.max_feet < G + 0.5f);   /* and it did not try */
	}
	/* ...and bridged when building is allowed */
	if (begin("gap_too_wide_bridged")) {
		gap = W.t->gap_sprint + 1;
		trench_scene(gap, 0);
		pol.may_build = 1;
		pol.blocks = 20;
		r = cross_trench(gap, 0, &pol);
		report("gap_too_wide_bridged", &r);
		CHECK(r.arrived);
		CHECK(r.kinds & K(BC_NAV_BUILD));
		CHECK(r.max_feet < G + 1.2f);
	}
}

/* THE ACCEPTANCE TEST. "Parkour" is: a bot must jump a two-block-long gap
 * -- a run-up, a jump, land on the far side. Level, then with the far
 * side one higher and one lower. It must JUMP: the trench spans the map
 * (no way round) and building is off. */
static void test_two_block_gap(void)
{
	static const struct { const char *name; int dz; } c[3] = {
		{"two_block_gap", 0}, {"two_block_gap_up", -1}, {"two_block_gap_down", 1}
	};
	bc_nav_policy pol;
	sim_result r;
	int i, lat;

	bc_nav_policy_default(&pol);
	for (i = 0; i < 3; i++) {
		if (!begin(c[i].name))
			continue;
		for (lat = 0; lat <= 2; lat++) {
			trench_scene(2, c[i].dz);
			W.latency = lat;
			r = cross_trench(2, c[i].dz, &pol);
			if (lat == 0)
				report(c[i].name, &r);
			CHECK(r.arrived);
			CHECK(r.kinds & JUMPS);
			CHECK(!(r.kinds & (K(BC_NAV_BUILD) | K(BC_NAV_DIG) | K(BC_NAV_PILLAR))));
			CHECK(r.max_feet < G + (c[i].dz > 0 ? c[i].dz : 0) + 0.5f);
			CHECK(r.damage == 0);
			CHECK(r.plans == 1 && r.step_fails == 0);
			CHECK(r.ticks < 60 * 6);        /* ~19 voxels: no dithering */
		}
	}
}

/* THE LINK'S DELAY. The follower sees the body as it is and its keys act
 * a tick or two later. A commitment that is right only if they act at
 * once is a coin tossed, and both of these were lost on 2FortCTF at two
 * ticks of delay, each into a pit with no way out. */
static void test_delay(void)
{
	bc_nav_policy pol;
	sim_result r;
	int lat;

	bc_nav_policy_default(&pol);
	if (begin("jump_down_onto_ledge_late")) {
		/* A terrace, six voxels below it a ledge three deep, six below
		 * that the ground -- and no way back up from the ground. The goal
		 * is the ledge's outer edge, and the plan is a jump from the
		 * terrace straight to it. The body came down on it, and the brake
		 * came two ticks late. */
		for (lat = 0; lat <= 2; lat++) {
			fresh(55);
			area_top(W.m, 231, 265, 237, 286, 43);
			area_top(W.m, 228, 287, 237, 289, 49);
			W.latency = lat;
			r = sim_run(&W, pol, node(233, 266, 43), node(232, 289, 49), 0, 3000);
			if (lat == 2)
				report("jump_down_onto_ledge_late", &r);
			CHECK(r.arrived);
			CHECK(r.max_feet < 49.5f && r.damage == 0);
		}
	}
	if (begin("runjump_refused_late")) {
		/* Two platforms corner to corner across a pit, four columns of
		 * nothing on the diagonal: a sprinting jump with a window of five
		 * ticks, from the very corner. When the window does not come the
		 * body must brake -- and a brake that ends hanging off the corner
		 * by a twentieth of a voxel is not one. There is another way
		 * round, a long one; whatever it does, it must not be in the pit. */
		for (lat = 0; lat <= 2; lat++) {
			fresh(49);
			area_top(W.m, 295, 230, 298, 248, 44);
			area_top(W.m, 286, 252, 290, 262, 44);
			area_top(W.m, 299, 230, 320, 232, 44);          /* the long way */
			area_top(W.m, 318, 233, 320, 262, 44);
			area_top(W.m, 291, 260, 317, 262, 44);
			W.latency = lat;
			r = sim_run(&W, pol, node(297, 239, 44), node(288, 258, 44), 0, 6000);
			if (lat == 2)
				report("runjump_refused_late", &r);
			CHECK(r.arrived);
			CHECK(r.max_feet < 44.5f && r.damage == 0);
		}
	}
}

static void test_parkour(void)
{
	bc_nav_policy pol;
	sim_result r;

	if (!begin("parkour_three_gaps"))
		return;
	bc_nav_policy_default(&pol);
	/* ground | 2 | a two-voxel ledge | 3 | a one-voxel pillar, one up |
	 * 2 | ground one down: ledge to ledge, no room for a run-up */
	fresh(G);
	area_top(W.m, 110, 0, 119, BC_MAP_Y - 1, 62);
	col_top(W.m, 112, 100, G);
	col_top(W.m, 113, 100, G);
	col_top(W.m, 117, 100, G - 1);
	area_top(W.m, 120, 0, BC_MAP_X - 1, BC_MAP_Y - 1, G);
	r = sim_run(&W, pol, node(100, 100, G), node(126, 100, G), 0, 3000);
	report("parkour_three_gaps", &r);
	CHECK(r.arrived);
	CHECK(r.kinds & JUMPS);
	CHECK(r.max_feet < G + 1.2f);
	CHECK(r.damage == 0);

	if (!begin("parkour_diagonal"))
		return;
	/* pillars set on a diagonal, two apart */
	fresh(G);
	area_top(W.m, 110, 0, 119, BC_MAP_Y - 1, 62);
	col_top(W.m, 111, 101, G);
	col_top(W.m, 113, 103, G);
	col_top(W.m, 115, 105, G);
	col_top(W.m, 117, 105, G);
	col_top(W.m, 119, 105, G);
	r = sim_run(&W, pol, node(100, 100, G), node(126, 105, G), 0, 3000);
	report("parkour_diagonal", &r);
	CHECK(r.arrived);
	CHECK(r.max_feet < G + 1.2f);
}

static void test_steps_and_walls(void)
{
	bc_nav_policy pol;
	sim_result r;

	bc_nav_policy_default(&pol);
	if (begin("step_two_high")) {
		fresh(G);
		area_top(W.m, 115, 0, BC_MAP_X - 1, BC_MAP_Y - 1, G - 2);
		r = sim_run(&W, pol, node(100, 100, G), node(125, 100, G - 2), 0, 2000);
		report("step_two_high", &r);
		CHECK(r.arrived);
		CHECK(r.kinds & K(BC_NAV_JUMP));
	}
	if (begin("step_three_high_refused")) {
		fresh(G);
		area_top(W.m, 115, 0, BC_MAP_X - 1, BC_MAP_Y - 1, G - 3);
		r = sim_run(&W, pol, node(100, 100, G), node(125, 100, G - 3), 0, 2000);
		report("step_three_high_refused", &r);
		CHECK(!r.arrived && r.first_plan_status == BC_NAV_FAILED);
	}
	if (begin("stairs_natural")) {
		int i;

		/* a staircase up ten and down again: the free climb, at a walk */
		fresh(G);
		for (i = 0; i < 10; i++)
			area_top(W.m, 110 + i, 0, 129 - i, BC_MAP_Y - 1, G - 1 - i);
		r = sim_run(&W, pol, node(100, 100, G), node(140, 100, G), 0, 2000);
		report("stairs_natural", &r);
		CHECK(r.arrived && r.damage == 0 && r.step_fails == 0);
	}

	pol.may_dig = 1;
	if (begin("wall_walk_round")) {
		/* seven voxels of wall: round it is under a second, through it
		 * is three digs */
		fresh(G);
		box(W.m, 115, 97, G - 4, 115, 103, G - 1, 1);
		r = sim_run(&W, pol, node(100, 100, G), node(125, 100, G), 0, 2000);
		report("wall_walk_round", &r);
		CHECK(r.arrived);
		CHECK(!(r.kinds & K(BC_NAV_DIG)) && r.edits == 0);
	}
	if (begin("wall_dig_through")) {
		/* the same wall the width of the map: through it */
		fresh(G);
		box(W.m, 115, 0, G - 4, 115, BC_MAP_Y - 1, G - 1, 1);
		r = sim_run(&W, pol, node(100, 100, G), node(125, 100, G), 0, 2000);
		report("wall_dig_through", &r);
		CHECK(r.arrived);
		CHECK((r.kinds & K(BC_NAV_DIG)) && r.edits >= 2);
	}
	if (begin("wall_no_dig_zone")) {
		/* a way round sixty voxels off, and a rule against digging */
		bc_nav_zone z = {110, 0, 120, BC_MAP_Y - 1, 1, 1, {0, 0}};

		fresh(G);
		box(W.m, 115, 0, G - 4, 115, BC_MAP_Y - 1, G - 1, 1);
		box(W.m, 115, 160, G - 4, 115, 162, G - 1, 0);
		pol.zones = &z;
		pol.nzones = 1;
		r = sim_run(&W, pol, node(100, 100, G), node(125, 100, G), 0, 4000);
		report("wall_no_dig_zone", &r);
		CHECK(r.arrived);
		CHECK(r.edits == 0 && !(r.kinds & K(BC_NAV_DIG)));
		pol.zones = NULL;
		pol.nzones = 0;
	}
	if (begin("wall_server_refuses")) {
		/* the same, but nobody told the engine: it asks, is refused,
		 * learns, and goes round */
		fresh(G);
		box(W.m, 115, 0, G - 4, 115, BC_MAP_Y - 1, G - 1, 1);
		box(W.m, 115, 130, G - 4, 115, 132, G - 1, 0);
		W.srv_protect = 1;
		W.sx0 = 110; W.sx1 = 120; W.sy0 = 0; W.sy1 = BC_MAP_Y - 1;
		r = sim_run(&W, pol, node(100, 100, G), node(125, 100, G), 0, 6000);
		report("wall_server_refuses", &r);
		CHECK(r.arrived);
		CHECK(r.why[BC_NAV_WHY_EDIT_REFUSED] >= 1);
		CHECK(r.edits == 0);
	}
	if (begin("dig_down_and_out")) {
		/* the goal is in a room under the ground: down through the roof */
		fresh(G);
		box(W.m, 120, 98, G + 3, 124, 102, G + 5, 0);
		r = sim_run(&W, pol, node(100, 100, G), node(122, 100, G + 6), 0, 3000);
		report("dig_down_and_out", &r);
		CHECK(r.arrived);
		CHECK(r.kinds & K(BC_NAV_DIG));
	}
}

static void test_building(void)
{
	bc_nav_policy pol;
	sim_result r;

	bc_nav_policy_default(&pol);
	pol.may_build = 1;
	pol.blocks = 30;
	if (begin("stairs_up_cliff")) {
		/* five voxels of cliff the width of the map */
		fresh(G);
		area_top(W.m, 115, 0, BC_MAP_X - 1, BC_MAP_Y - 1, G - 5);
		r = sim_run(&W, pol, node(100, 100, G), node(125, 100, G - 5), 0, 4000);
		report("stairs_up_cliff", &r);
		CHECK(r.arrived);
		CHECK(r.kinds & (K(BC_NAV_BUILD) | K(BC_NAV_PILLAR)));
		CHECK(r.edits >= 3);
	}
	if (begin("pillar_up")) {
		/* a ledge four up over open ground, nothing beside it to build
		 * stairs against but the body's own column */
		fresh(G);
		box(W.m, 120, 100, G - 4, 124, 100, G - 4, 1);
		r = sim_run(&W, pol, node(100, 100, G), node(122, 100, G - 4), 0, 4000);
		report("pillar_up", &r);
		CHECK(r.arrived);
		CHECK(r.edits >= 2);
	}
	if (begin("build_no_blocks")) {
		fresh(G);
		area_top(W.m, 115, 0, BC_MAP_X - 1, BC_MAP_Y - 1, G - 5);
		pol.blocks = 0;
		r = sim_run(&W, pol, node(100, 100, G), node(125, 100, G - 5), 0, 2000);
		report("build_no_blocks", &r);
		CHECK(!r.arrived && r.edits == 0);
	}
}

static void test_crouch(void)
{
	bc_nav_policy pol;
	sim_result r;

	if (!begin("crouch_gap"))
		return;
	bc_nav_policy_default(&pol);
	/* a wall three thick, the width of the map, with a hole two high */
	fresh(G);
	box(W.m, 115, 0, G - 8, 117, BC_MAP_Y - 1, G - 1, 1);
	box(W.m, 115, 100, G - 2, 117, 100, G - 1, 0);
	r = sim_run(&W, pol, node(100, 100, G), node(125, 100, G), 0, 2000);
	report("crouch_gap", &r);
	CHECK(r.arrived);
	CHECK(r.kinds & K(BC_NAV_CROUCH));
	CHECK(r.step_fails == 0);
}

static void test_water(void)
{
	bc_nav_policy pol;
	sim_result r;

	bc_nav_policy_default(&pol);
	if (begin("water_wade")) {
		/* a channel three wide the width of the map: wade, jump out */
		fresh(62);
		area_top(W.m, 120, 0, 122, BC_MAP_Y - 1, 63);
		r = sim_run(&W, pol, node(110, 100, 62), node(130, 100, 62), 0, 2000);
		report("water_wade", &r);
		CHECK(r.arrived);
		CHECK(r.waded > 0);
	}
	if (begin("water_costs")) {
		/* the same with a ford sixteen voxels off: dry feet are cheaper */
		fresh(62);
		area_top(W.m, 120, 0, 122, BC_MAP_Y - 1, 63);
		area_top(W.m, 120, 108, 122, 109, 62);
		r = sim_run(&W, pol, node(110, 100, 62), node(130, 100, 62), 0, 2000);
		report("water_costs", &r);
		CHECK(r.arrived);
		CHECK(r.waded == 0);
	}
	if (begin("water_deadly")) {
		/* water that kills, and the only ford two hundred voxels away */
		fresh(62);
		area_top(W.m, 120, 0, 122, BC_MAP_Y - 1, 63);
		area_top(W.m, 120, 300, 122, 301, 62);
		pol.water_lethal = 1;
		r = sim_run(&W, pol, node(110, 100, 62), node(130, 100, 62), 0, 6000);
		report("water_deadly", &r);
		CHECK(r.arrived);
		CHECK(r.waded == 0);
		CHECK(r.max_feet < 62.5f);
	}
	if (begin("water_deadly_no_ford")) {
		fresh(62);
		area_top(W.m, 120, 0, 122, BC_MAP_Y - 1, 63);
		pol.water_lethal = 1;
		pol.may_jump = 0;       /* three wide could be jumped */
		r = sim_run(&W, pol, node(110, 100, 62), node(130, 100, 62), 0, 2000);
		report("water_deadly_no_ford", &r);
		CHECK(!r.arrived && r.waded == 0);
	}
}


/* OUT OF THE WATER (nav.h, WATER). Found on a real server: a map whose
 * tents stand in the sea, so every bot spawns wading. What a wading body
 * can do is measured (body_test pins it): onto a bank at 62 by a jump and
 * by nothing else; onto a higher bank not at all. */

/* The longest a follower may be seen holding a movement key with the body
 * still (nav_sim.h, max_still): its own bound, twice over because the
 * bench's anchor is not its anchor, and the link's delay. */
#define STILL_MAX (2 * (2 * BC_NAV_STUCK_TICKS + BC_NAV_RECENTRE_TICKS) + 8)

/* The sea everywhere, and land from x = 120 east with its top at `top`. */
static void shore_scene(int top)
{
	fresh(63);
	area_top(W.m, 120, 0, BC_MAP_X - 1, BC_MAP_Y - 1, top);
}

/* spud's west shore as it is on the map, x 96..120 by y 246..258: where
 * the bots of the live server stood. Tops of the columns. */
static const uint8_t spud_shore[13][25] = {
	{63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,61,60,59,57,56,34,34,33,32},
	{63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,61,59,58,57,35,34,34,34,33},
	{63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,62,60,59,58,57,56,35,34,33,33},
	{63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,61,59,58,57,56,56,55,54,32,33},
	{63,63,63,63,63,63,63,63,63,63,63,63,63,63,62,60,59,58,57,56,55,55,35,33,33},
	{63,63,63,63,63,63,63,63,63,63,63,63,63,63,61,60,58,57,57,56,55,55,54,34,33},
	{63,63,63,63,63,63,63,63,63,63,63,63,63,63,61,59,58,57,56,56,55,55,54,53,33},
	{63,63,63,63,63,63,63,63,63,63,63,63,63,62,60,59,58,57,56,56,55,54,54,53,53},
	{63,63,63,63,63,63,63,63,63,63,63,63,63,61,60,58,57,57,56,56,55,54,54,53,53},
	{63,63,63,63,63,63,63,63,63,63,63,63,63,61,60,58,57,57,56,56,55,54,54,53,53},
	{63,63,63,63,63,63,63,63,63,63,63,63,63,61,60,58,57,57,56,56,55,55,54,53,53},
	{63,63,63,63,63,63,63,63,63,63,63,63,63,61,60,59,58,57,56,56,55,55,54,53,53},
	{63,63,63,63,63,63,63,63,63,63,63,63,63,62,60,59,58,57,57,56,55,55,54,54,53}
};

static void test_water_out(void)
{
	static bc_map truth;
	bc_nav_policy pol;
	sim_result r;
	int lat, x, y;

	bc_nav_policy_default(&pol);
	if (begin("water_out_bank")) {
		/* the bank at 62: the one height there is to climb. Straight at
		 * it, and at a shore that runs on the diagonal. */
		for (lat = 0; lat <= 2; lat++) {
			shore_scene(62);
			W.latency = lat;
			r = sim_run(&W, pol, node(110, 100, 63), node(126, 100, 62), 0, 2000);
			if (lat == 1)
				report("water_out_bank", &r);
			CHECK(r.arrived);
			CHECK(r.kinds & K(BC_NAV_JUMP));
			CHECK(r.plans == 1 && r.step_fails == 0);
			CHECK(r.waded > 0 && r.max_still < STILL_MAX);
			CHECK(r.ticks < 60 * 6);

			fresh(63);
			for (y = 0; y < BC_MAP_Y; y++)
				for (x = 0; x < BC_MAP_X; x++)
					if (x + y >= 230)
						col_top(W.m, x, y, 62);
			W.latency = lat;
			r = sim_run(&W, pol, node(110, 100, 63), node(122, 114, 62), 0, 2000);
			CHECK(r.arrived && r.plans == 1 && r.step_fails == 0);
			CHECK(r.max_still < STILL_MAX);
		}
		/* and onto a beach with the land rising behind it */
		shore_scene(62);
		area_top(W.m, 121, 0, BC_MAP_X - 1, BC_MAP_Y - 1, 60);
		area_top(W.m, 122, 0, BC_MAP_X - 1, BC_MAP_Y - 1, 59);
		r = sim_run(&W, pol, node(110, 100, 63), node(126, 100, 59), 0, 2000);
		CHECK(r.arrived && r.step_fails == 0);
	}
	if (begin("water_out_too_high")) {
		/* A bank at 61, and one at 60, the width of the map: no keys get a
		 * wading body onto either. The plan must say so AT ONCE: not one
		 * node expanded, not a search of 250 000 columns of sea every time
		 * somebody asks (five times a minute, by every bot in it). */
		int top;

		for (top = 61; top >= 60; top--) {
			shore_scene(top);
			r = sim_run(&W, pol, node(110, 100, 63), node(126, 100, top), 0, 2000);
			if (top == 61)
				report("water_out_too_high", &r);
			CHECK(!r.arrived && r.no_route);
			CHECK(r.first_plan_status == BC_NAV_FAILED);
			CHECK(r.plans == 1 && r.max_exp == 0);
			CHECK(r.ticks == 0);            /* and it did not set off */
		}
		if (only)
			printf("  the sea searched for a way out in %.0f us\n", r.plan_us);
		/* nor does BUILDING get it out: the lowest voxel the server lets
		 * anybody place is 61, three above the wading feet */
		shore_scene(61);
		pol.may_build = 1;
		pol.blocks = 30;
		r = sim_run(&W, pol, node(110, 100, 63), node(126, 100, 61), 0, 2000);
		CHECK(!r.arrived && r.max_exp == 0 && r.edits == 0);
		pol.may_build = 0;
		pol.blocks = 0;
		/* a goal IN that sea is still a goal */
		r = sim_run(&W, pol, node(110, 100, 63), node(100, 120, 63), 0, 2000);
		CHECK(r.arrived);
	}
	if (begin("water_out_along_shore")) {
		/* the same bank, with one place ten columns along where it is 62 */
		for (lat = 0; lat <= 2; lat++) {
			shore_scene(61);
			area_top(W.m, 120, 110, 121, 111, 62);
			W.latency = lat;
			r = sim_run(&W, pol, node(117, 100, 63), node(126, 100, 61), 0, 3000);
			if (lat == 1)
				report("water_out_along_shore", &r);
			CHECK(r.arrived);
			CHECK(r.plans == 1 && r.step_fails == 0 && r.edits == 0);
			CHECK(r.max_still < STILL_MAX);
		}
	}
	if (begin("water_out_dig")) {
		/* too high everywhere, and digging allowed: the bank is cut down
		 * to 62 from the water (61 is the lowest voxel that can be dug)
		 * and jumped onto. At 61 that is one voxel; at 59 it is three, and
		 * the notch it leaves is climbed out of like any other. */
		int top;

		pol.may_dig = 1;
		for (top = 61; top >= 59; top -= 2)
			for (lat = 0; lat <= 2; lat++) {
				shore_scene(top);
				W.latency = lat;
				r = sim_run(&W, pol, node(116, 100, 63), node(126, 100, top), 0, 4000);
				if (lat == 1)
					report(top == 61 ? "water_out_dig" : "water_out_dig (bank at 59)", &r);
				CHECK(r.arrived);
				CHECK((r.kinds & K(BC_NAV_DIG)) && r.edits >= 62 - top);
				CHECK(r.step_fails == 0 && r.max_still < STILL_MAX);
			}
		/* ...unless the bank may not be dug */
		{
			bc_nav_zone z = {118, 0, 124, BC_MAP_Y - 1, 1, 1, {0, 0}};

			shore_scene(61);
			pol.zones = &z;
			pol.nzones = 1;
			r = sim_run(&W, pol, node(116, 100, 63), node(126, 100, 61), 0, 2000);
			CHECK(!r.arrived && r.max_exp == 0 && r.edits == 0);
			pol.zones = NULL;
			pol.nzones = 0;
		}
		pol.may_dig = 0;
	}
	if (begin("water_spawn")) {
		/* The live server's situation, cut out of its map: the tent in the
		 * sea, the shore as it is there -- 61 along most of it, 62 at four
		 * places -- and everywhere else a wall. From the tent to the top
		 * of the beach. */
		for (lat = 0; lat <= 2; lat++) {
			fresh(63);
			area_top(W.m, 110, 0, 140, BC_MAP_Y - 1, 61);
			for (y = 0; y < 13; y++) {
				for (x = 0; x < 25; x++)
					col_top(W.m, 96 + x, 246 + y, spud_shore[y][x]);
				area_top(W.m, 121, 246 + y, 140, 246 + y, spud_shore[y][24]);
			}
			W.latency = lat;
			r = sim_run(&W, pol, node(72, 256, 63), node(119, 256, 53), 0, 60 * 40);
			if (lat == 1)
				report("water_spawn", &r);
			CHECK(r.arrived);
			CHECK(r.kinds & K(BC_NAV_JUMP));
			CHECK(r.waded > 60 * 5 && r.max_still < STILL_MAX);
			CHECK(!r.gave_up && r.plans <= 2);
		}
	}

	/* THE GUARANTEE (nav.h): whatever is wrong, a follower does not hold a
	 * key against no progress without saying so. In the water the paces
	 * are others (wading is 5.3 voxels a second, not 8 or 10.4) and the
	 * body's feet are a voxel under its node: the same bound must hold. */
	if (begin("water_wall_unknown")) {
		/* a rock in the sea that the engine does not know of, on the way
		 * to an island: waded into, reported, gone round */
		for (lat = 0; lat <= 2; lat++) {
			fresh(63);
			area_top(W.m, 130, 90, 140, 110, 62);
			memcpy(&truth, W.m, sizeof truth);
			col_top(&truth, 120, 100, 50);
			W.truth = &truth;
			W.latency = lat;
			r = sim_run(&W, pol, node(110, 100, 63), node(135, 100, 62), 0, 60 * 60);
			if (lat == 1)
				report("water_wall_unknown", &r);
			CHECK(r.arrived);
			CHECK(r.why[BC_NAV_WHY_STUCK] >= 1);
			CHECK(r.max_still < STILL_MAX);
			CHECK(r.ticks < 60 * 20);
			W.truth = W.m;
		}
	}
	if (begin("water_bank_lie")) {
		/* The engine believes the bank is 62 here; it is 61 (a kerb along
		 * three columns of shore that nobody announced). The jump is
		 * simulated on the engine's map and lands; on the server's it does
		 * not. That must be a report within the bound -- NO_JUMP after the
		 * controller's tries, not a body pressed to the bank for ever --
		 * and the next plan must leave by somewhere else. */
		for (lat = 0; lat <= 2; lat++) {
			shore_scene(62);
			memcpy(&truth, W.m, sizeof truth);
			area_top(&truth, 120, 99, 120, 101, 61);
			W.truth = &truth;
			W.latency = lat;
			r = sim_run(&W, pol, node(114, 100, 63), node(126, 100, 62), 0, 60 * 60);
			if (lat == 1)
				report("water_bank_lie", &r);
			CHECK(r.arrived);
			CHECK(r.step_fails >= 1);
			CHECK(r.max_still < STILL_MAX);
			CHECK(!r.plan_cap && r.ticks < 60 * 40);
			W.truth = W.m;
		}
	}
	if (begin("water_bank_lie_everywhere")) {
		/* ...and when the whole shore is such a lie there is nowhere else:
		 * every plan is a jump the server will not have. The follower must
		 * END it (GIVE_UP), from the water as from anywhere, well inside
		 * the bench's cap, and never stand silent on the way. */
		for (lat = 0; lat <= 2; lat++) {
			shore_scene(62);
			memcpy(&truth, W.m, sizeof truth);
			area_top(&truth, 120, 0, BC_MAP_X - 1, BC_MAP_Y - 1, 61);
			W.truth = &truth;
			W.latency = lat;
			r = sim_run(&W, pol, node(114, 100, 63), node(126, 100, 62), 0, 60 * 600);
			if (lat == 1) {
				report("water_bank_lie_everywhere", &r);
				printf("  %-28s %d reports, the longest still with a key held %d ticks\n", "",
				       r.step_fails, r.max_still);
			}
			CHECK(!r.arrived);
			CHECK(r.gave_up && !r.plan_cap);
			CHECK(r.plans <= BC_NAV_REPORTS_MAX);
			CHECK(r.max_still < STILL_MAX);
			W.truth = W.m;
		}
	}
	if (begin("water_channel_closed")) {
		/* a wall in the sea with one gap the engine believes in and the
		 * server does not have: waded into three times, then GIVE_UP */
		fresh(63);
		area_top(W.m, 120, 0, 122, BC_MAP_Y - 1, 50);
		area_top(W.m, 120, 100, 122, 100, 63);
		area_top(W.m, 130, 90, 140, 110, 62);
		memcpy(&truth, W.m, sizeof truth);
		area_top(&truth, 120, 100, 122, 100, 50);
		W.truth = &truth;
		r = sim_run(&W, pol, node(114, 100, 63), node(135, 100, 62), 0, 60 * 120);
		report("water_channel_closed", &r);
		CHECK(!r.arrived);
		CHECK(r.gave_up && !r.plan_cap);
		CHECK(r.plans == BC_NAV_REPEAT_MAX);
		CHECK(r.why[BC_NAV_WHY_STUCK] == BC_NAV_REPEAT_MAX - 1);
		CHECK(r.max_still < STILL_MAX);
		CHECK(r.ticks < 60 * 20);
		W.truth = W.m;
	}
}

/* WATER THAT HURTS (nav.h). The server says what a map's water does
 * ("water.damage", health a second); the policy prices it. */
static void test_water_harmful(void)
{
	bc_nav_policy pol;
	sim_result r;
	int k;

	if (begin("water_harmful_leave")) {
		/* A strait thirteen wide between two shores, a causeway across it
		 * sixty columns south, and a body IN the water three columns from
		 * the west shore with its goal on the east one. In harmless water
		 * it wades across. In water that hurts it turns its back on the
		 * goal, leaves by the west bank and goes round -- and the same
		 * when the water is declared lethal, which no longer means "a
		 * body in it has no route at all". */
		for (k = 0; k < 3; k++) {
			bc_nav_policy_default(&pol);
			if (k == 1) pol.water_damage = 20.0f;
			if (k == 2) pol.water_lethal = 1;
			fresh(63);
			area_top(W.m, 0, 0, 106, BC_MAP_Y - 1, 62);
			area_top(W.m, 120, 0, BC_MAP_X - 1, BC_MAP_Y - 1, 62);
			area_top(W.m, 107, 160, 119, 161, 62);
			r = sim_run(&W, pol, node(109, 100, 63), node(125, 100, 62), 0, 60 * 60);
			report(k == 0 ? "water_harmful_leave (safe)" : k == 1 ? "water_harmful_leave" :
			       "water_harmful_leave (lethal)", &r);
			CHECK(r.arrived && r.plans == 1 && r.step_fails == 0);
			if (k == 0)
				CHECK(r.waded > 100);           /* ten columns of it */
			else
				CHECK(r.waded < 80);            /* three, and the jump out */
		}
	}
	if (begin("water_harmful_ford")) {
		/* A channel three wide the width of the map, and dry land across
		 * it a hundred columns off: twenty seconds' walk round. At 5 a
		 * second the crossing costs about eight seconds of health and is
		 * taken; at 30 a second about fifty, and it is not. */
		static const float dmg[3] = {0.0f, 5.0f, 30.0f};

		for (k = 0; k < 3; k++) {
			bc_nav_policy_default(&pol);
			pol.water_damage = dmg[k];
			fresh(62);
			area_top(W.m, 120, 0, 122, BC_MAP_Y - 1, 63);
			area_top(W.m, 120, 200, 122, 201, 62);
			r = sim_run(&W, pol, node(110, 100, 62), node(130, 100, 62), 0, 60 * 60);
			if (k)
				report(k == 1 ? "water_harmful_ford (5/s)" : "water_harmful_ford (30/s)", &r);
			CHECK(r.arrived && r.step_fails == 0);
			if (k < 2)
				CHECK(r.waded > 0);
			else
				CHECK(r.waded == 0 && r.max_feet < 62.5f);
		}
	}
}

static void test_drops(void)
{
	bc_nav_policy pol;
	sim_result r;
	int i;

	bc_nav_policy_default(&pol);
	if (begin("drop_six")) {
		fresh(G);
		area_top(W.m, 0, 0, 110, BC_MAP_Y - 1, G - 6);
		r = sim_run(&W, pol, node(100, 100, G - 6), node(120, 100, G), 0, 2000);
		report("drop_six", &r);
		CHECK(r.arrived);
		CHECK(r.damage == 0);
		CHECK(r.kinds & (K(BC_NAV_DROP) | JUMPS));
	}
	if (begin("drop_into_water")) {
		/* A rock nine voxels over the sea, a bank across the water, and
		 * a stair down the rock's far side. Nine voxels onto land do not
		 * hurt; into water the feet sink one more and it is a fall of
		 * ten, which does. The plan must know it: it once planned the
		 * jump off, the follower's simulation refused it at the edge,
		 * and the next plan was the same drop from the next column. */
		fresh(63);
		area_top(W.m, 100, 98, 104, 102, 54);
		for (i = 1; i <= 8; i++)
			area_top(W.m, 100 - i, 100, 100 - i, 100, 54 + i);
		area_top(W.m, 120, 90, 130, 110, 62);
		r = sim_run(&W, pol, node(103, 100, 54), node(125, 100, 62), 0, 4000);
		report("drop_into_water", &r);
		CHECK(r.arrived);
		CHECK(r.damage == 0 && r.step_fails == 0 && r.plans == 1);
		/* (it does drop in, from part of the way down the stair) */
		/* eight voxels up it is a fall of nine: taken */
		fresh(63);
		area_top(W.m, 100, 98, 104, 102, 55);
		area_top(W.m, 120, 90, 130, 110, 62);
		r = sim_run(&W, pol, node(103, 100, 55), node(125, 100, 62), 0, 4000);
		CHECK(r.arrived && r.damage == 0 && r.step_fails == 0);
		CHECK(r.kinds & K(BC_NAV_DROP));
	}
	if (begin("drop_too_deep")) {
		/* a plateau fifteen up; the only harmless way down is a
		 * staircase a hundred voxels along the edge */
		fresh(G);
		area_top(W.m, 0, 0, 110, BC_MAP_Y - 1, G - 15);
		for (i = 1; i < 15; i++)
			area_top(W.m, 110 + i, 200, 110 + i, 201, G - 15 + i);
		r = sim_run(&W, pol, node(100, 100, G - 15), node(130, 100, G), 0, 6000);
		report("drop_too_deep", &r);
		CHECK(r.arrived);
		CHECK(r.damage == 0);
	}
	if (begin("drop_too_deep_no_stairs")) {
		fresh(G);
		area_top(W.m, 0, 0, 110, BC_MAP_Y - 1, G - 15);
		r = sim_run(&W, pol, node(100, 100, G - 15), node(130, 100, G), 0, 2000);
		report("drop_too_deep_no_stairs", &r);
		CHECK(!r.arrived);
		CHECK(r.damage == 0 && r.max_feet < G - 15 + 0.5f);     /* stayed up */
	}
}

/* OFF THE ROOF (2026-11-25, the owner's live case: "bots stuck on map's
 * roof ... not attempting a bridge toward a building that could help them
 * get down"). A body on a roof higher than a safe drop (9) with digging
 * and building allowed must find the cheapest of: a dig down through the
 * roof onto a floor a safe drop below (and on down), a level bridge to a
 * lower roof it can drop onto, a stair built DOWN into the open air (each
 * step hung from the one before: a block under the step it stands on,
 * then the next step beside that). With no edits it must stay up. */
static void hollow_tower(int x0, int y0, int x1, int y1, int top)
{
	box(W.m, x0, y0, top, x1, y1, G - 1, 1);
	box(W.m, x0 + 1, y0 + 1, top + 1, x1 - 1, y1 - 1, G - 1, 0);
}

static void test_off_the_roof(void)
{
	bc_nav_policy pol;
	sim_result r;
	int i;

	bc_nav_policy_default(&pol);
	pol.may_dig = pol.may_build = 1;
	pol.blocks = 50;
	if (begin("roof_dig_down")) {
		/* a hollow building 18 high with a floor 9 below its roof: dig
		 * the roof, drop, dig that floor, drop, and out through the wall */
		fresh(G);
		hollow_tower(100, 95, 110, 105, G - 18);
		box(W.m, 101, 96, G - 9, 109, 104, G - 9, 1);
		r = sim_run(&W, pol, node(105, 100, G - 18), node(130, 100, G), 0, 60 * 60);
		report("roof_dig_down", &r);
		CHECK(r.arrived && r.damage == 0);
		CHECK(r.kinds & K(BC_NAV_DIG));
	}
	if (begin("roof_bridge")) {
		/* a hollow tower 20 high, nothing inside to land on; 3 voxels
		 * off, a building 11 high with a stair down its far side */
		fresh(G);
		hollow_tower(100, 95, 104, 105, G - 20);
		area_top(W.m, 108, 90, 118, 110, G - 11);
		for (i = 1; i < 11; i++)
			area_top(W.m, 118 + i, 100, 118 + i, 101, G - 11 + i);
		r = sim_run(&W, pol, node(102, 100, G - 20), node(140, 100, G), 0, 60 * 60);
		report("roof_bridge", &r);
		CHECK(r.arrived && r.damage == 0);
		CHECK(r.kinds & K(BC_NAV_BUILD));
		CHECK(r.edits <= 12);
	}
	if (begin("roof_stair_down")) {
		/* a hollow tower 14 high, alone, building allowed and digging
		 * not (edit=build; with digging it digs down a wall): a stair
		 * down its side into the air until a drop is safe */
		pol.may_dig = 0;
		fresh(G);
		hollow_tower(100, 95, 104, 105, G - 14);
		r = sim_run(&W, pol, node(102, 100, G - 14), node(130, 100, G), 0, 60 * 60);
		report("roof_stair_down", &r);
		CHECK(r.arrived && r.damage == 0);
		CHECK(r.kinds & K(BC_NAV_BUILD));
		CHECK(!(r.kinds & K(BC_NAV_DIG)));
		pol.may_dig = 1;
	}
	if (begin("roof_middle")) {
		/* from the middle of a hollow roof: no step down into the room
		 * under the roof without digging the roof out of the way */
		fresh(G);
		hollow_tower(100, 95, 104, 105, G - 14);
		r = sim_run(&W, pol, node(102, 100, G - 14), node(140, 100, G), 0, 60 * 60);
		report("roof_middle", &r);
		CHECK(r.arrived && r.damage == 0);
		CHECK(r.ticks < 60 * 20);
		/* the same, searched as the engine searches a way down (greedy,
		 * and the goal far below priced: nav.h descent_secs) */
		fresh(G);
		hollow_tower(100, 95, 104, 105, G - 14);
		pol.h_weight = 1.5f;
		pol.descent_secs = 1.5f;
		r = sim_run(&W, pol, node(102, 100, G - 14), node(140, 100, G), 0, 60 * 60);
		report("roof_middle (descent priced)", &r);
		CHECK(r.arrived && r.damage == 0);
		CHECK(r.ticks < 60 * 20);
		pol.h_weight = 0.0f;
		pol.descent_secs = 0.0f;
	}
	if (begin("ceiling_slab")) {
		/* A one-voxel slab at the very top of the map (z 0, a body's head
		 * above the map), the ground 40 below -- keidoro's, where bots
		 * spawned (tentspawns puts a spawn on a column's top). Under part
		 * of it a floor at 8 with a stair from it to the ground. */
		fresh(G);
		box(W.m, 90, 90, 0, 120, 110, 0, 1);
		box(W.m, 100, 96, 8, 106, 104, 8, 1);
		for (i = 1; i <= G - 8; i++)
			box(W.m, 106 + i, 100, 8 + i, 106 + i, 100, G - 1, 1);
		/* nothing allowed: no way (the whole slab, 651 columns, flooded) */
		bc_nav_policy_default(&pol);
		r = sim_run(&W, pol, node(103, 100, 0), node(150, 100, G), 0, 600);
		report("ceiling_slab (no edits)", &r);
		CHECK(!r.arrived && r.damage == 0 && r.max_feet < 0.5f);
		/* digging: dig the voxel it stands on, drop 8 onto the floor under,
		 * and down its stair */
		pol.may_dig = 1;
		pol.descent_secs = 1.5f;
		r = sim_run(&W, pol, node(103, 100, 0), node(150, 100, G), 0, 60 * 60);
		report("ceiling_slab (dig, drop)", &r);
		CHECK(r.arrived && r.damage == 0);
		CHECK(r.kinds & K(BC_NAV_DIG));
		/* the ground 20 under it and nothing else, building too: no way.
		 * A stair DOWN into the open cannot be built: its next step would
		 * go against the underside of the floor stood on, which nobody
		 * can aim at (the owner's rule; lib_botlink refuses it). It stays
		 * up: stranded */
		fresh(20);
		box(W.m, 90, 90, 0, 120, 110, 0, 1);
		pol.may_build = 1;
		pol.blocks = 50;
		pol.h_weight = 1.5f;
		r = sim_run(&W, pol, node(118, 100, 0), node(150, 100, 20), 0, 600);
		report("ceiling_slab (nothing under it within reach: stays)", &r);
		CHECK(!r.arrived && r.damage == 0 && r.max_feet < 0.5f);
		/* a tower whose top is 9 under the slab, 4 off its edge: a LEVEL
		 * bridge at the slab's height to over it (each block against the
		 * far face of the last, from the edge), and the drop */
		fresh(20);
		box(W.m, 90, 90, 0, 120, 110, 0, 1);
		box(W.m, 125, 98, 9, 127, 102, 19, 1);
		r = sim_run(&W, pol, node(118, 100, 0), node(150, 100, 20), 0, 60 * 90);
		report("ceiling_slab (a tower 9 under it: bridge, drop)", &r);
		CHECK(r.arrived && r.damage == 0);
		CHECK(r.kinds & K(BC_NAV_BUILD));
		bc_nav_policy_default(&pol);
		pol.may_dig = pol.may_build = 1;
		pol.blocks = 50;
	}
	if (begin("roof_no_edits")) {
		/* the same tower, nothing allowed: it stays up, and the search
		 * that proves there is no way is small (the roof) */
		bc_nav_policy_default(&pol);
		fresh(G);
		hollow_tower(100, 95, 104, 105, G - 14);
		r = sim_run(&W, pol, node(102, 100, G - 14), node(130, 100, G), 0, 600);
		report("roof_no_edits", &r);
		CHECK(!r.arrived && r.damage == 0 && r.max_feet < G - 14 + 0.5f);
	}
}

/* SIDEWAYS. The ground safety rule once looked at height only, and what
 * it lost were bodies that overshot a turn. These are those places. */
static void test_turns(void)
{
	bc_nav_policy pol;
	sim_result r;
	int k, lat;

	bc_nav_policy_default(&pol);
	if (begin("turn_below_stairs")) {
		/* Parkour2's corner, as it is on the map: a platform three wide
		 * running east, a landing one down at its end, and from the
		 * landing a stair three wide going north down to a quay -- all of
		 * it standing in the sea, with no way out of the water. The route
		 * keeps to the platform's north edge and turns down the stair's
		 * WEST edge; a body that overshoots the turn eastward is still on
		 * the landing, and one that comes back from there at a run goes
		 * off the west edge. */
		for (lat = 0; lat <= 2; lat++) {
			fresh(63);
			area_top(W.m, 90, 100, 104, 102, 52);
			area_top(W.m, 105, 100, 107, 102, 53);
			for (k = 0; k < 8; k++)
				area_top(W.m, 105, 99 - k, 107, 99 - k, 54 + k);
			area_top(W.m, 105, 80, 107, 91, 61);
			W.latency = lat;
			r = sim_run(&W, pol, node(92, 100, 52), node(105, 84, 61), 0, 3000);
			if (lat == 1)
				report("turn_below_stairs", &r);
			CHECK(r.arrived);
			CHECK(r.plans == 1 && r.off_route == 0 && r.step_fails == 0);
			CHECK(r.waded == 0 && r.max_feet < 61.5f);
			CHECK(r.damage == 0);
		}
	}
	if (begin("turn_on_causeway")) {
		/* one voxel wide, a right angle, forty voxels of air below: no
		 * overshoot at all is survivable. It must still take the straights
		 * at a run -- under twice the planned time. */
		for (lat = 0; lat <= 2; lat++) {
			fresh(62);
			area_top(W.m, 100, 100, 125, 100, 22);
			area_top(W.m, 125, 100, 125, 125, 22);
			area_top(W.m, 125, 125, 150, 125, 22);
			W.latency = lat;
			r = sim_run(&W, pol, node(101, 100, 22), node(149, 125, 22), 0, 3000);
			if (lat == 1)
				report("turn_on_causeway", &r);
			CHECK(r.arrived);
			CHECK(r.plans == 1 && r.off_route == 0 && r.step_fails == 0);
			CHECK(r.max_feet < 22.5f && r.damage == 0);
			CHECK((float)r.ticks / 60.0f < r.route_secs * 2.0f);
		}
	}
	if (begin("turn_past_dead_end")) {
		/* the same causeway, but the first straight runs on two voxels
		 * past the turn and stops: somewhere to overshoot to at the
		 * route's own height, and nothing beyond it */
		for (lat = 0; lat <= 2; lat++) {
			fresh(62);
			area_top(W.m, 100, 100, 127, 100, 22);
			area_top(W.m, 125, 100, 125, 125, 22);
			W.latency = lat;
			r = sim_run(&W, pol, node(101, 100, 22), node(125, 124, 22), 0, 3000);
			if (lat == 1)
				report("turn_past_dead_end", &r);
			CHECK(r.arrived);
			CHECK(r.plans == 1 && r.off_route == 0 && r.step_fails == 0);
			CHECK(r.max_feet < 22.5f && r.damage == 0);
		}
	}
	if (begin("goal_in_inner_corner")) {
		/* Temple again (26,140,51 -> 497,479,55): the goal is the inner
		 * corner of a terrace one voxel high, reached along its foot. The
		 * body brushes the terrace's edge, is lifted onto it by one corner
		 * (the free climb), and comes to rest over the middle of the goal
		 * column a voxel above its floor. */
		for (lat = 0; lat <= 2; lat++) {
			fresh(55);
			area_top(W.m, 496, 440, 511, 478, 54);
			area_top(W.m, 498, 479, 511, 479, 54);
			W.latency = lat;
			r = sim_run(&W, pol, node(489, 475, 55), node(497, 479, 55), 0, 1200);
			if (lat == 0)
				report("goal_in_inner_corner", &r);
			CHECK(r.arrived);
			CHECK(r.plans == 1 && r.step_fails == 0);
			CHECK(r.ticks < 60 * 5);
		}
	}
	if (begin("overshoot_loop")) {
		/* Temple's pair that never arrived (245,450,52 -> 203,232,43), cut
		 * down to what did it. The goal is a notch two voxels deep in the
		 * edge of a terrace; the way into it is along the terrace's edge
		 * at a run, one step down, and a turn back of 135 degrees. Past
		 * the step the slope goes on down, two voxels and then three. The
		 * old rule let the body sprint at the step, because an emergency
		 * stop "held" -- by one corner, on the step, centre over the
		 * slope. One tick of command delay later it did not hold: down
		 * the slope, OFF_ROUTE, a new plan all the way round by the ramp
		 * and up onto the terrace -- and into the same step at the same
		 * run. 23 times, until the test bench stopped counting. */
		for (lat = 0; lat <= 2; lat++) {
			fresh(47);
			area_top(W.m, 196, 233, 204, 250, 41);        /* the terrace */
			col_top(W.m, 204, 232, 41);
			col_top(W.m, 202, 232, 41);
			col_top(W.m, 203, 232, 43);                   /* the notch */
			col_top(W.m, 203, 231, 43);
			col_top(W.m, 204, 231, 42);                   /* the step */
			col_top(W.m, 204, 230, 44);                   /* the slope */
			for (k = 0; k < 5; k++)                       /* a ramp back up */
				area_top(W.m, 190 + k, 244, 190 + k, 246, 46 - k);
			area_top(W.m, 195, 244, 195, 246, 41);
			W.latency = lat;
			r = sim_run(&W, pol, node(204, 249, 41), node(203, 232, 43), 0, 6000);
			if (lat == 1)
				report("overshoot_loop", &r);
			CHECK(r.arrived);
			CHECK(r.off_route == 0 && r.plans == 1);
			CHECK(r.max_feet < 43.5f && r.damage == 0);
		}
	}
	if (begin("zigzag_down")) {
		/* a stair one wide that doubles back at every landing, down a
		 * cliff: four turns, each at the bottom of a descent, each with
		 * the drop beside it */
		for (lat = 0; lat <= 2; lat++) {
			int leg, z = 20;

			fresh(62);
			area_top(W.m, 90, 100, 100, 100, z);
			for (leg = 0; leg < 4; leg++) {
				int y = 100 + leg, dir = (leg & 1) ? -1 : 1, x = (leg & 1) ? 109 : 101;

				for (k = 0; k < 8; k++)
					col_top(W.m, x + dir * k, y, ++z);
				/* the landing: the stair's last tread, and beside it the
				 * first of the next flight */
				col_top(W.m, x + dir * 8, y, z);
				col_top(W.m, x + dir * 8, y + 1, z);
			}
			area_top(W.m, 101, 104, 120, 104, z);
			W.latency = lat;
			r = sim_run(&W, pol, node(92, 100, 20), node(118, 104, z), 0, 6000);
			if (lat == 1)
				report("zigzag_down", &r);
			CHECK(r.arrived);
			CHECK(r.off_route == 0 && r.damage == 0);
			CHECK(r.max_feet < (float)z + 0.5f);
		}
	}
}

/* A wall with two doors. */
static void two_doors(bc_map *m)
{
	box(m, 115, 0, G - 6, 115, BC_MAP_Y - 1, G - 1, 1);
	box(m, 115, 100, G - 3, 115, 100, G - 1, 0);
	box(m, 115, 112, G - 3, 115, 112, G - 1, 0);
}

static void test_surprises(void)
{
	static bc_map truth;
	bc_nav_policy pol;
	sim_result r;

	bc_nav_policy_default(&pol);
	if (begin("wedged_on_ledge")) {
		/* The engine believes the near door is open. It is not: there
		 * is a ledge two high in it that nobody announced. The bot
		 * walks into it; the follower must say so (not grind), the
		 * failure must be remembered, and the next plan must take the
		 * far door. */
		fresh(G);
		two_doors(W.m);
		memcpy(&truth, W.m, sizeof truth);
		box(&truth, 115, 100, G - 2, 115, 100, G - 1, 1);
		W.truth = &truth;
		r = sim_run(&W, pol, node(100, 100, G), node(125, 100, G), 0, 3000);
		report("wedged_on_ledge", &r);
		CHECK(r.arrived);
		CHECK(r.why[BC_NAV_WHY_STUCK] >= 1);
		CHECK(r.plans >= 2 && r.plans <= 4);
		/* reported within the contract: a few ticks to walk there, then
		 * no more than BC_NAV_STUCK_TICKS standing against it */
		CHECK(r.ticks < 60 * 12);
		W.truth = W.m;
	}
	if (begin("wedged_no_other_way")) {
		/* The same lie about the world, but the near door is the ONLY
		 * door. Every plan goes through it -- a remembered failure is a
		 * price, and the only way is worth any price -- and every walk
		 * ends against the ledge. That is a loop, and nothing but the
		 * follower can end it: the third time it would report STUCK from
		 * that spot it says GIVE_UP instead. */
		fresh(G);
		box(W.m, 115, 0, G - 6, 115, BC_MAP_Y - 1, G - 1, 1);
		box(W.m, 115, 100, G - 3, 115, 100, G - 1, 0);
		memcpy(&truth, W.m, sizeof truth);
		box(&truth, 115, 100, G - 2, 115, 100, G - 1, 1);
		W.truth = &truth;
		r = sim_run(&W, pol, node(100, 100, G), node(125, 100, G), 0, 60 * 60);
		report("wedged_no_other_way", &r);
		CHECK(!r.arrived);
		CHECK(r.gave_up && !r.plan_cap);
		CHECK(r.plans == BC_NAV_REPEAT_MAX);
		CHECK(r.why[BC_NAV_WHY_STUCK] == BC_NAV_REPEAT_MAX - 1);
		/* three walks of a few ticks and three times the stuck contract */
		CHECK(r.ticks < 60 * 15);
		W.truth = W.m;
	}
	if (begin("partial_again_and_again")) {
		/* a goal behind a wall the width of the map, no digging: every
		 * plan fails and offers a route to "as near as it got". Following
		 * that and planning again from its end is the same loop with no
		 * failure in it; the follower counts those arrivals too. */
		static bc_nav_route route;
		bc_nav_follow f;
		bc_nav_cmd cmd;
		bc_body b;
		int st, n_arrived = 0, n_plans = 0, t, gave = 0;

		fresh(G);
		box(W.m, 115, 0, G - 6, 115, BC_MAP_Y - 1, G - 1, 1);
		bc_body_place(&b, W.m, 100.5f, 100.5f, G, 0);
		memset(&f, 0, sizeof f);
		for (t = 0; t < 60 * 60 && !gave && n_plans < 40;) {
			bc_nav_node cur;

			CHECK(bc_nav_node_of_body(W.m, &b, &cur));
			CHECK(bc_nav_plan_begin(W.s, W.t, W.m, &pol, cur, node(125, 100, G), 0));
			while ((st = bc_nav_plan_step(W.s, 100000)) == BC_NAV_MORE)
				;
			CHECK(st == BC_NAV_FAILED);
			bc_nav_plan_route(W.s, &route);
			CHECK(route.partial);
			if (n_plans++ == 0)
				bc_nav_follow_begin(&f, &route);
			else
				bc_nav_follow_again(&f, &route);
			for (; t < 60 * 60; t++) {
				st = bc_nav_follow_tick(&f, &route, W.t, W.m, &b, &pol, &cmd);
				bc_body_step(&b, W.m, cmd.keys, cmd.ori, BC_BODY_DT);
				if (st == BC_NAV_GIVE_UP)
					gave = 1;
				if (st == BC_NAV_ARRIVED)
					n_arrived++;
				if (st != BC_NAV_FOLLOWING)
					break;
			}
		}
		printf("  %-28s %d plans, %d partial arrivals, then %s\n", "partial_again_and_again",
		       n_plans, n_arrived, gave ? "GIVE_UP" : "nothing");
		CHECK(gave);
		/* the third arrival at the same dead end is the one not reported */
		CHECK(n_plans == BC_NAV_REPEAT_MAX && n_arrived == BC_NAV_REPEAT_MAX - 1);
	}
	if (begin("route_blocked_midway")) {
		/* Both doors open; half a second in, somebody bricks up the
		 * near one (announced: the engine's map changes). */
		fresh(G);
		two_doors(W.m);
		W.place_tick = 30;
		W.px0 = 115; W.py0 = 100; W.pz0 = G - 3;
		W.px1 = 115; W.py1 = 100; W.pz1 = G - 1;
		r = sim_run(&W, pol, node(100, 100, G), node(125, 100, G), 0, 3000);
		report("route_blocked_midway", &r);
		CHECK(r.arrived);
		CHECK(r.stale >= 1);
		CHECK(r.step_fails == 0);       /* it knew before it got there */
	}
	if (begin("floor_removed_midway")) {
		/* a causeway over a pit; its middle is blown out as the bot
		 * sets off. It must not run into the hole. */
		fresh(G);
		area_top(W.m, 110, 0, 125, BC_MAP_Y - 1, 62);
		area_top(W.m, 110, 100, 125, 100, G);
		area_top(W.m, 110, 140, 125, 141, G);
		r.arrived = 0;
		{
			/* blow it by hand at tick 20: a destroy, not a build */
			sim_world w2 = W;

			(void)w2;
		}
		W.place_tick = 0;
		r = sim_run(&W, pol, node(100, 100, G), node(104, 100, G), 0, 600);
		CHECK(r.arrived);
		/* now cut twelve voxels out and go: too wide to jump */
		area_top(W.m, 112, 100, 123, 100, 62);
		r = sim_run(&W, pol, node(104, 100, G), node(130, 100, G), 0, 4000);
		report("floor_removed_midway", &r);
		CHECK(r.arrived);
		CHECK(r.max_feet < G + 0.5f);
	}
}

/* COLLAPSE. Nobody announces what a destroy leaves floating: the engine's
 * own flood removes it (cull.h), and a route across what fell must be
 * dropped at once. A deck one voxel thick over a pit, a voxel short of the
 * near bank (so it hangs from the far bank alone), and one shot at the
 * voxel it hangs by. */
static void deck_scene(int pit_floor)
{
	int x;

	fresh(G);
	area_top(W.m, 110, 0, 125, BC_MAP_Y - 1, pit_floor);
	for (x = 111; x <= 125; x++)
		bc_map_set(W.m, x, 100, G, 1);
	W.dx = 125; W.dy = 100; W.dz = G;
}

static void test_collapse(void)
{
	bc_nav_policy pol;
	sim_result r;
	int i;

	bc_nav_policy_default(&pol);
	if (begin("collapse_ahead")) {
		/* shot out while the bot is still coming: it must not set foot
		 * on a deck that is no longer there. Another way, forty off. */
		deck_scene(62);
		area_top(W.m, 110, 140, 125, 141, G);
		W.destroy_tick = 20;
		r = sim_run(&W, pol, node(100, 100, G), node(130, 100, G), 0, 4000);
		report("collapse_ahead", &r);
		CHECK(!bc_map_solid(W.m, 118, 100, G));         /* the deck fell */
		CHECK(bc_map_solid(W.m, 126, 100, G));          /* the bank did not */
		CHECK(r.arrived);
		CHECK(r.stale >= 1);
		CHECK(r.max_feet < G + 1.2f);
		CHECK(r.damage == 0);
	}
	if (begin("collapse_underfoot")) {
		/* shot out with the bot on it: it falls with the deck (six
		 * voxels: no harm), and must plan again from where it lands --
		 * there is a ramp out of the pit */
		deck_scene(G + 6);
		for (i = 0; i < 6; i++)
			area_top(W.m, 120 + i, 104, 120 + i, 105, G + 5 - i);
		W.destroy_at_x = 116.0f;
		r = sim_run(&W, pol, node(100, 100, G), node(130, 100, G), 0, 4000);
		report("collapse_underfoot", &r);
		CHECK(!bc_map_solid(W.m, 118, 100, G));
		CHECK(r.arrived);
		CHECK(r.stale + r.off_route >= 1);
		CHECK(r.plans >= 2);
		CHECK(r.max_feet > G + 5.0f);                   /* it did fall */
		CHECK(r.damage == 0);
	}
}

static void test_fail_memory(void)
{
	bc_nav_fail f;
	bc_nav_node a = node(1, 2, 3), b = node(2, 2, 3);

	if (!begin("fail_memory"))
		return;
	bc_nav_fail_clear(&f);
	CHECK(bc_nav_fail_count(&f, a, b, BC_NAV_WALK, 0.0) == 0);
	bc_nav_fail_note(&f, a, b, BC_NAV_WALK, 10.0, 30.0);
	CHECK(bc_nav_fail_count(&f, a, b, BC_NAV_WALK, 11.0) == 1);
	CHECK(bc_nav_fail_count(&f, a, b, BC_NAV_JUMP, 11.0) == 0);
	CHECK(bc_nav_fail_count(&f, b, a, BC_NAV_WALK, 11.0) == 0);
	bc_nav_fail_note(&f, a, b, BC_NAV_WALK, 12.0, 30.0);
	CHECK(bc_nav_fail_count(&f, a, b, BC_NAV_WALK, 13.0) == 2);
	CHECK(bc_nav_fail_count(&f, a, b, BC_NAV_WALK, 43.0) == 0);     /* expired */
	{
		bc_nav_protect *p = malloc(sizeof *p);

		bc_nav_protect_clear(p);
		CHECK(!bc_nav_protect_has(p, 5, 6, 7));
		bc_nav_protect_add(p, 5, 6, 7);
		CHECK(bc_nav_protect_has(p, 5, 6, 7));
		CHECK(!bc_nav_protect_has(p, 5, 6, 8));
		CHECK(!bc_nav_protect_has(p, 6, 6, 7));
		free(p);
	}
}

/* A search is resumable: the same plan in slices of 50 expansions. */
static void test_resumable(void)
{
	static bc_nav_route a, b;
	bc_nav_policy pol;
	int st, steps = 0;

	if (!begin("resumable"))
		return;
	bc_nav_policy_default(&pol);
	fresh(G);
	two_doors(W.m);
	CHECK(bc_nav_plan_begin(W.s, W.t, W.m, &pol, node(100, 100, G), node(200, 300, G), 0));
	while (bc_nav_plan_step(W.s, 1000000) == BC_NAV_MORE)
		;
	bc_nav_plan_route(W.s, &a);
	CHECK(bc_nav_plan_begin(W.s, W.t, W.m, &pol, node(100, 100, G), node(200, 300, G), 0));
	while ((st = bc_nav_plan_step(W.s, 50)) == BC_NAV_MORE)
		steps++;
	bc_nav_plan_route(W.s, &b);
	CHECK(st == BC_NAV_DONE && steps > 10);
	CHECK(a.n == b.n && a.n > 100 && !a.partial);
	CHECK(memcmp(a.steps, b.steps, sizeof(bc_nav_step) * (size_t)a.n) == 0);
	printf("  %-28s %d steps, %.2fs, %u expansions in %d slices of 50\n", "resumable", a.n,
	       (double)a.secs, bc_nav_plan_expansions(W.s), steps + 1);

	/* out of nodes: fails, and says where it had got to */
	{
		void *mem = malloc(bc_nav_search_size(256));
		bc_nav_search *small = bc_nav_search_init(mem, 256);

		CHECK(bc_nav_plan_begin(small, W.t, W.m, &pol, node(100, 100, G), node(200, 300, G), 0));
		while ((st = bc_nav_plan_step(small, 1000)) == BC_NAV_MORE)
			;
		CHECK(st == BC_NAV_FAILED);
		CHECK(bc_nav_plan_nodes(small) <= 256);
		bc_nav_plan_route(small, &b);
		CHECK(b.partial && b.n > 0);
		free(mem);
	}
}

/* --- the soak ------------------------------------------------------------ */

static unsigned char *slurp(const char *path, size_t *len)
{
	FILE *fp = fopen(path, "rb");
	unsigned char *buf;
	long n;

	if (!fp)
		return NULL;
	fseek(fp, 0, SEEK_END);
	n = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	buf = malloc((size_t)n + 1);
	*len = fread(buf, 1, (size_t)n, fp);
	fclose(fp);
	return buf;
}

static int pick_node(bc_rng *rng, const bc_map *m, bc_nav_node *out)
{
	int tries;

	for (tries = 0; tries < 20000; tries++) {
		int x = 8 + (int)bc_rng_below(rng, BC_MAP_X - 16);
		int y = 8 + (int)bc_rng_below(rng, BC_MAP_Y - 16);
		int z = (int)bc_rng_below(rng, 62);

		if (bc_nav_snap(m, x, y, z, 0, out) && out->z < BC_MAP_WATER_Z)
			return 1;
	}
	return 0;
}

/* A random water column: where a bot spawns on a map with its tent in the
 * sea, or falls in. */
static int pick_water(bc_rng *rng, const bc_map *m, bc_nav_node *out)
{
	int tries;

	for (tries = 0; tries < 20000; tries++) {
		int x = 8 + (int)bc_rng_below(rng, BC_MAP_X - 16);
		int y = 8 + (int)bc_rng_below(rng, BC_MAP_Y - 16);

		if (bc_map_is_water(m, x, y)) {
			*out = node(x, y, BC_MAP_WATER_Z);
			return 1;
		}
	}
	return 0;
}

/* THE REAL MAP of the live bug, when it is there (BC_TEST_MAPS/spud.vxl):
 * both tents stand in the sea. From one to the other -- out of the water,
 * across the island, into the water again -- at each delay. */
static void test_spud(void)
{
	const char *dir = getenv("BC_TEST_MAPS");
	char path[1024];
	unsigned char *bytes;
	size_t len = 0;
	bc_nav_policy pol;
	sim_result r;
	int lat;

	if (!begin("spud_tent_to_tent"))
		return;
	snprintf(path, sizeof path, "%s/spud.vxl", dir ? dir : ".");
	bytes = dir ? slurp(path, &len) : NULL;
	if (!bytes) {
		printf("  %-28s skipped (no spud.vxl in BC_TEST_MAPS)\n", "spud_tent_to_tent");
		return;
	}
	bc_nav_policy_default(&pol);
	for (lat = 0; lat <= 2; lat++) {
		fresh(63);
		CHECK(bc_map_load_vxl(W.m, bytes, len));
		W.latency = lat;
		r = sim_run(&W, pol, node(72, 256, 63), node(440, 256, 63), 0, 60 * 240);
		if (lat == 1)
			report("spud_tent_to_tent", &r);
		CHECK(r.first_plan_status == BC_NAV_DONE);
		CHECK(r.arrived && !r.gave_up);
		CHECK(r.kinds & K(BC_NAV_JUMP));
		CHECK(r.max_still < STILL_MAX);
	}
	free(bytes);
}

static void soak_map(const char *dir, const char *file, int pairs, int latency, int edits)
{
	char path[1024];
	unsigned char *bytes;
	size_t len = 0;
	bc_rng rng;
	bc_nav_policy pol;
	int tried = 0, reachable = 0, arrived = 0, unreach = 0, exhausted = 0;
	int step_fails = 0, stale = 0, off = 0, why[8] = {0}, hurt = 0, plans = 0, i;
	int gave_up = 0, capped = 0, max_still = 0;
	int wet_starts = getenv("BC_SOAK_WATER") != NULL && atoi(getenv("BC_SOAK_WATER")) > 0;
	/* the starts in the water, apart: [0] tried, [1] reachable, [2] arrived,
	 * [3] stuck reports, [4] every other report, [5] the follower gave up */
	int wet[6] = {0};
	static int cat_ticks[BC_NAV_KINDS][3][3], cat_n[BC_NAV_KINDS][3][3];
	static float cat_secs[BC_NAV_KINDS][3][3];
	double sum_time = 0, sum_ratio = 0, worst_ratio = 0;
	int n_clean = 0, n_over = 0;
	unsigned max_exp = 0, max_nodes = 0;
	double sum_exp = 0, sum_us = 0, max_us = 0, sum_secs = 0, sum_ticks = 0;
	int worst_ticks = 0;

	snprintf(path, sizeof path, "%s/%s", dir, file);
	bytes = slurp(path, &len);
	if (!bytes || !bc_map_load_vxl(W.m, bytes, len)) {
		printf("  %-22s could not be loaded\n", file);
		free(bytes);
		return;
	}
	free(bytes);
	W.truth = W.m;
	bc_rng_seed(&rng, 0x5eed, 54);
	bc_nav_policy_default(&pol);
	if (edits) {
		pol.may_dig = pol.may_build = 1;
		pol.blocks = 50;
	}

	while (tried < pairs) {
		bc_nav_node a, b;
		sim_result r;
		static bc_map backup;
		int dx, dy, one[6];

		int in_water = wet_starts && (tried & 1);

		if (!(in_water ? pick_water(&rng, W.m, &a) : pick_node(&rng, W.m, &a)) ||
		    !pick_node(&rng, W.m, &b)) {
			if (in_water) {         /* a map with no sea */
				wet_starts = 0;
				continue;
			}
			break;
		}
		dx = a.x - b.x; dy = a.y - b.y;
		if (dx * dx + dy * dy < 12 * 12)
			continue;
		tried++;
		bc_nav_fail_clear(&W.fail);
		bc_nav_protect_clear(&W.prot);
		W.latency = latency;
		W.verbose = 0;
		/* BC_SOAK_PAIR="ax,ay,az,bx,by,bz": that pair only, and talk */
		if (getenv("BC_SOAK_PAIR") &&
		    sscanf(getenv("BC_SOAK_PAIR"), "%d,%d,%d,%d,%d,%d", &one[0], &one[1], &one[2],
		           &one[3], &one[4], &one[5]) == 6) {
			a = node(one[0], one[1], one[2]);
			b = node(one[3], one[4], one[5]);
			W.verbose = 1;
			W.trace = getenv("BC_SOAK_TRACE") != NULL;
			tried = pairs;
		}
		if (edits)
			memcpy(&backup, W.m, sizeof backup);
		r = sim_run(&W, pol, a, b, 0, 60 * 240);
		if (edits)
			memcpy(W.m, &backup, sizeof backup);
		plans += r.plans;
		sum_exp += r.sum_exp;
		sum_us += r.plan_us;
		if (r.max_plan_us > max_us)
			max_us = r.max_plan_us;
		if (r.max_exp > max_exp)
			max_exp = r.max_exp;
		if (r.max_nodes > max_nodes)
			max_nodes = r.max_nodes;
		if (r.max_still > max_still)
			max_still = r.max_still;
		if (in_water) {
			wet[0]++;
			if (r.first_plan_status == BC_NAV_DONE) {
				wet[1]++;
				wet[2] += r.arrived;
				wet[3] += r.why[BC_NAV_WHY_STUCK] + r.why[BC_NAV_WHY_TIMEOUT];
				wet[4] += r.step_fails - r.why[BC_NAV_WHY_STUCK] - r.why[BC_NAV_WHY_TIMEOUT] +
				          r.off_route + r.stale;
				wet[5] += r.gave_up;
			}
		}
		if (r.first_plan_status != BC_NAV_DONE) {
			/* not a reachable pair: no way, or the search ran out */
			if (r.max_nodes >= pool_nodes)
				exhausted++;
			else
				unreach++;
			continue;
		}
		reachable++;
		gave_up += r.gave_up;
		all_vis_refused += r.vis_refused;
		capped += r.plan_cap;
		step_fails += r.step_fails;
		stale += r.stale;
		off += r.off_route;
		for (i = 0; i < 8; i++)
			why[i] += r.why[i];
		if (r.damage)
			hurt++;
		if (r.arrived && r.plans == 1 && r.route_time > 2.0f) {
			/* a route walked as planned: what the cost model is judged on */
			double ratio = r.ticks / 60.0 / r.route_time;
			int k, z, t;

			n_clean++;
			sum_ratio += ratio;
			if (ratio > worst_ratio)
				worst_ratio = ratio;
			if (ratio > 1.25 || ratio < 0.8) {
				n_over++;
				if (getenv("BC_SOAK_SHOW"))
					printf("    off the estimate: (%d,%d,%d) -> (%d,%d,%d): walked %.1fs, "
					       "planned %.1fs\n", a.x, a.y, a.z, b.x, b.y, b.z, r.ticks / 60.0,
					       (double)r.route_time);
			}
			for (k = 0; k < BC_NAV_KINDS; k++)
				for (z = 0; z < 3; z++)
					for (t = 0; t < 3; t++) {
						cat_ticks[k][z][t] += r.cat_ticks[k][z][t];
						cat_n[k][z][t] += r.cat_n[k][z][t];
						cat_secs[k][z][t] += r.cat_secs[k][z][t];
					}
		}
		if (r.arrived && r.step_fails && getenv("BC_SOAK_SHOW"))
			printf("    reported on the way: (%d,%d,%d) -> (%d,%d,%d): stuck %d timeout %d "
			       "jump %d drop %d\n", a.x, a.y, a.z, b.x, b.y, b.z, r.why[BC_NAV_WHY_STUCK],
			       r.why[BC_NAV_WHY_TIMEOUT], r.why[BC_NAV_WHY_NO_JUMP], r.why[BC_NAV_WHY_NO_DROP]);
		if (r.arrived) {
			arrived++;
			sum_secs += r.route_secs;
			sum_time += r.route_time;
			sum_ticks += r.ticks;
			if (r.ticks > worst_ticks)
				worst_ticks = r.ticks;
		} else if (getenv("BC_SOAK_SHOW")) {
			printf("    lost: (%d,%d,%d) -> (%d,%d,%d): %d plans, %d step fails "
			       "[stuck %d timeout %d jump %d drop %d edit %d], %d off, %d stale, no_route %d, "
			       "gave up %d, %d ticks\n",
			       a.x, a.y, a.z, b.x, b.y, b.z, r.plans, r.step_fails,
			       r.why[BC_NAV_WHY_STUCK], r.why[BC_NAV_WHY_TIMEOUT],
			       r.why[BC_NAV_WHY_NO_JUMP], r.why[BC_NAV_WHY_NO_DROP],
			       r.why[BC_NAV_WHY_EDIT_REFUSED], r.off_route, r.stale,
			       r.no_route, r.gave_up, r.ticks);
		}
	}
	printf("  %-20s %3d pairs: %3d reachable (%d no way, %d out of nodes); "
	       "arrived %3d = %5.1f%%, lost %d (the follower gave up on %d)\n", file, tried,
	       reachable, unreach, exhausted, arrived,
	       reachable ? 100.0 * arrived / reachable : 0.0, reachable - arrived, gave_up);
	printf("  %-20s step failures %d (stuck %d, timeout %d, no jump %d, no drop %d, edit %d), "
	       "stale %d, off route %d, hurt on %d routes\n", "", step_fails, why[BC_NAV_WHY_STUCK],
	       why[BC_NAV_WHY_TIMEOUT], why[BC_NAV_WHY_NO_JUMP], why[BC_NAV_WHY_NO_DROP],
	       why[BC_NAV_WHY_EDIT_REFUSED], stale, off, hurt);
	printf("  %-20s %d plans: %.0f expansions and %.0f us on average, worst %u expansions, "
	       "%.0f us, %u nodes; walked %.1fs for %.1fs planned on average, longest %.0fs\n",
	       "", plans, plans ? sum_exp / plans : 0.0, plans ? sum_us / plans : 0.0, max_exp,
	       max_us, max_nodes, arrived ? sum_ticks / 60.0 / arrived : 0.0,
	       arrived ? sum_secs / arrived : 0.0, worst_ticks / 60.0);
	printf("  %-20s the estimate: walked/planned time %.3f over all arrivals; on the %d "
	       "routes walked as first planned, mean %.3f, worst %.2f, %d outside 0.8-1.25\n", "",
	       sum_time > 0 ? sum_ticks / 60.0 / sum_time : 0.0, n_clean,
	       n_clean ? sum_ratio / n_clean : 0.0, worst_ratio, n_over);
	if (wet[0])
		printf("  %-20s STARTS IN THE WATER: %d of the pairs, %d reachable; arrived %d, lost %d "
		       "(gave up %d); stuck or timed out %d times, other reports %d\n", "", wet[0], wet[1],
		       wet[2], wet[1] - wet[2], wet[5], wet[3], wet[4]);
	printf("  %-20s the longest a movement key was held with the body still: %d ticks "
	       "(must be under %d)\n", "", max_still, STILL_MAX);
	if (getenv("BC_SOAK_COSTS")) {
		static const char *const zn[3] = {"up", "level", "down"};
		static const char *const tn[3] = {"straight", "turn 45", "turn 90+"};
		int k, z, t;

		for (k = 0; k < BC_NAV_KINDS; k++)
			for (z = 0; z < 3; z++)
				for (t = 0; t < 3; t++)
					if (cat_n[k][z][t] > 0)
						printf("    cost %-8s %-5s %-9s %7d steps: walked %.3fs each, "
						       "planned %.3fs (%+.0f s in all)\n", bc_nav_kind_name(k),
						       zn[z], tn[t], cat_n[k][z][t],
						       cat_ticks[k][z][t] / 60.0 / cat_n[k][z][t],
						       (double)cat_secs[k][z][t] / cat_n[k][z][t],
						       cat_ticks[k][z][t] / 60.0 - (double)cat_secs[k][z][t]);
		memset(cat_ticks, 0, sizeof cat_ticks);
		memset(cat_n, 0, sizeof cat_n);
		memset(cat_secs, 0, sizeof cat_secs);
	}
	/* no run may go on until the bench stops it: the follower ends loops */
	CHECK(capped == 0);
	/* and nobody stands pressing a key against nothing without saying so */
	CHECK(max_still < STILL_MAX);
	/* a soak is a measurement, but a collapse is a failure */
	CHECK(reachable == 0 || arrived * 100 >= reachable * 90);
}

static void soak(void)
{
	const char *dir = getenv("BC_TEST_MAPS");
	const char *e;
	int pairs = 200, latency = 1, edits = 0;
	DIR *d;
	struct dirent *de;

	if (!dir) {
		printf("soak: skipped (set BC_TEST_MAPS to a directory of .vxl files)\n");
		return;
	}
	if ((e = getenv("BC_SOAK_PAIRS")) != NULL)
		pairs = atoi(e);
	if ((e = getenv("BC_SOAK_LATENCY")) != NULL)
		latency = atoi(e);
	if ((e = getenv("BC_SOAK_EDITS")) != NULL)
		edits = atoi(e);
	d = opendir(dir);
	if (!d) {
		printf("soak: cannot open %s\n", dir);
		return;
	}
	printf("soak: %d pairs a map, command delay %d tick(s), edits %s, search memory %.1f MiB\n",
	       pairs, latency, edits ? "on" : "off",
	       (double)bc_nav_search_size(pool_nodes) / (1024.0 * 1024.0));
	while ((de = readdir(d)) != NULL) {
		size_t n = strlen(de->d_name);

		if (getenv("BC_SOAK_MAP") && strcmp(getenv("BC_SOAK_MAP"), de->d_name) != 0)
			continue;
		if (n > 4 && strcmp(de->d_name + n - 4, ".vxl") == 0)
			soak_map(dir, de->d_name, pairs, latency, edits);
	}
	closedir(d);
}

int main(int argc, char **argv)
{
	static bc_map map;
	static bc_cull cull;
	static bc_nav_moves moves;
	double t0;
	int table = 0, i;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--table") == 0)
			table = 1;
		else if (strcmp(argv[i], "-v") == 0 && i + 1 < argc)
			only = argv[++i];
	}

	memset(&W, 0, sizeof W);
	W.m = W.truth = &map;
	W.cull = &cull;
	W.t = &moves;
	bc_cull_init(&cull);
	if (getenv("BC_SOAK_NODES"))
		pool_nodes = (unsigned)atoi(getenv("BC_SOAK_NODES"));
	W.s = bc_nav_search_init(malloc(bc_nav_search_size(pool_nodes)), pool_nodes);

	t0 = sim_now_us();
	bc_nav_moves_measure(&moves, &map);
	t0 = sim_now_us() - t0;
	if (table) {
		print_table(&moves);
		return 0;
	}
	printf("move table: %d moves, %d mask columns, measured in %.0f ms; a body clears %d "
	       "voxels at a walk, %d at a sprint\n", moves.n, moves.ncols, t0 / 1000.0,
	       moves.gap_walk, moves.gap_sprint);

	if (!only)
		test_table();
	test_two_block_gap();
	test_gaps();
	test_parkour();
	test_delay();
	test_steps_and_walls();
	test_building();
	test_crouch();
	test_water();
	test_water_out();
	test_water_harmful();
	test_drops();
	test_off_the_roof();
	test_turns();
	test_surprises();
	test_collapse();
	test_fail_memory();
	test_resumable();
	test_spud();
	if (!only)
		soak();
	/* what a player could do from where it stands, and nothing more: the
	 * server's rule (lib_botlink do_block), played by the simulation */
	printf("edits refused for not being in the eye's sight, every scenario%s: %d\n",
	       getenv("BC_TEST_MAPS") ? " and the soak" : "", all_vis_refused);
	CHECK(all_vis_refused == 0);

	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
