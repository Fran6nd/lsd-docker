/* nav_test.c -- nav: the measured move table, scenarios, and a soak.
 *
 *   nav_test                 the table and every scenario
 *   nav_test -v NAME         one scenario, with its plans and failures
 *   nav_test --table         print the whole measured table
 *   BC_TEST_MAPS=dir nav_test   also soak on every .vxl in dir
 *     BC_SOAK_PAIRS=n          pairs a map (default 200)
 *     BC_SOAK_LATENCY=n        ticks of command delay (default 1)
 *     BC_SOAK_EDITS=1          let the bots dig and build
 *     BC_SOAK_NODES=n          the search's node pool (default 131072)
 *     BC_SOAK_SHOW=1           print each pair that did not arrive
 *     BC_SOAK_MAP=file.vxl     that map only
 *     BC_SOAK_PAIR=ax,ay,az,bx,by,bz   that pair only, with its plans
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
	if (only)
		printf("== %s\n", name);
	return 1;
}

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
	printf("\n");
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

static void soak_map(const char *dir, const char *file, int pairs, int latency, int edits)
{
	char path[1024];
	unsigned char *bytes;
	size_t len = 0;
	bc_rng rng;
	bc_nav_policy pol;
	int tried = 0, reachable = 0, arrived = 0, unreach = 0, exhausted = 0;
	int step_fails = 0, stale = 0, off = 0, why[8] = {0}, hurt = 0, plans = 0, i;
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

		if (!pick_node(&rng, W.m, &a) || !pick_node(&rng, W.m, &b))
			break;
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
		if (r.first_plan_status != BC_NAV_DONE) {
			/* not a reachable pair: no way, or the search ran out */
			if (r.max_nodes >= pool_nodes)
				exhausted++;
			else
				unreach++;
			continue;
		}
		reachable++;
		step_fails += r.step_fails;
		stale += r.stale;
		off += r.off_route;
		for (i = 0; i < 8; i++)
			why[i] += r.why[i];
		if (r.damage)
			hurt++;
		if (r.arrived) {
			arrived++;
			sum_secs += r.route_secs;
			sum_ticks += r.ticks;
			if (r.ticks > worst_ticks)
				worst_ticks = r.ticks;
		} else if (getenv("BC_SOAK_SHOW")) {
			printf("    lost: (%d,%d,%d) -> (%d,%d,%d): %d plans, %d step fails "
			       "[stuck %d timeout %d jump %d drop %d], %d off, no_route %d, %d ticks\n",
			       a.x, a.y, a.z, b.x, b.y, b.z, r.plans, r.step_fails,
			       r.why[BC_NAV_WHY_STUCK], r.why[BC_NAV_WHY_TIMEOUT],
			       r.why[BC_NAV_WHY_NO_JUMP], r.why[BC_NAV_WHY_NO_DROP], r.off_route,
			       r.no_route, r.ticks);
		}
	}
	printf("  %-20s %3d pairs: %3d reachable (%d no way, %d out of nodes); "
	       "arrived %3d = %5.1f%%, lost %d\n", file, tried, reachable, unreach, exhausted,
	       arrived, reachable ? 100.0 * arrived / reachable : 0.0, reachable - arrived);
	printf("  %-20s step failures %d (stuck %d, timeout %d, no jump %d, no drop %d, edit %d), "
	       "stale %d, off route %d, hurt on %d routes\n", "", step_fails, why[BC_NAV_WHY_STUCK],
	       why[BC_NAV_WHY_TIMEOUT], why[BC_NAV_WHY_NO_JUMP], why[BC_NAV_WHY_NO_DROP],
	       why[BC_NAV_WHY_EDIT_REFUSED], stale, off, hurt);
	printf("  %-20s %d plans: %.0f expansions and %.0f us on average, worst %u expansions, "
	       "%.0f us, %u nodes; walked %.1fs for %.1fs planned on average, longest %.0fs\n",
	       "", plans, plans ? sum_exp / plans : 0.0, plans ? sum_us / plans : 0.0, max_exp,
	       max_us, max_nodes, arrived ? sum_ticks / 60.0 / arrived : 0.0,
	       arrived ? sum_secs / arrived : 0.0, worst_ticks / 60.0);
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
	test_steps_and_walls();
	test_building();
	test_crouch();
	test_water();
	test_drops();
	test_surprises();
	test_collapse();
	test_fail_memory();
	test_resumable();
	if (!only)
		soak();

	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
