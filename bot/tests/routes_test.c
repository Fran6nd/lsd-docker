/* routes_test.c -- the route board (core/routes.h): a team's bots going the
 * same way share one search; a joiner's route is its own, from its own
 * start, and holds on the map; a route an edit breaks is off the board and
 * replanned by everyone who had it. On the simulated server of brain_sim.h. */
#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40, WALL_X = 260, NEAR_Y = 254, FAR_Y = 300, BOTS = 6 };

/* A field cut by a wall too high to jump, with two gaps: a near one, on
 * the straight way, and a far one. Six bots of a team, side by side, all
 * sent to the same place beyond it. */
static bs_sim *field(int share)
{
	bs_sim *s = bs_new(G, 8);
	char set[64];
	int i;

	bs_box(s, WALL_X, 180, G - 4, WALL_X, 340, G - 1, 1);
	bs_box(s, WALL_X, NEAR_Y, G - 4, WALL_X, NEAR_Y + 2, G - 1, 0);
	bs_box(s, WALL_X, FAR_Y, G - 4, WALL_X, FAR_Y + 2, G - 1, 0);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	snprintf(set, sizeof set, "plan.share=%d", share);
	bs_set(s, BL_NO_PLAYER, set);
	bs_set(s, BL_NO_PLAYER, "place.spot=290.5 230.5 37.75");
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo go_to @spot\n\twait 60\n");
	for (i = 0; i < BOTS; i++)
		bs_add(s, i, 1, 1, 3 + i, BL_GUN_RIFLE, 700u + (uint32_t)i * 31u, 230.5f, 244.5f + 2.0f * (float)i, 1, 0);
	return s;
}

/* Does the route go through the wall at rows y0..y0+2? */
static int through(const bc_nav_route *r, int y0)
{
	int k;

	for (k = 0; k < r->n; k++)
		if (r->steps[k].to.x == WALL_X && r->steps[k].to.y >= y0 && r->steps[k].to.y <= y0 + 2)
			return 1;
	return 0;
}

static void test_share(void)
{
	bs_sim *s = field(1), *alone = field(0);
	const bc_engine_stats *st = bc_engine_stats_get(s->e);
	unsigned replans, plans_alone;
	int i, routes = 0, own_start = 0, holds = 0, whole = 0, near = 0, off_near = 0, there = 0;

	printf("six bots of a team, the same goal beyond a wall: one search\n");
	bs_run(s, 1.5);
	bs_run(alone, 1.5);
	plans_alone = bc_engine_stats_get(alone->e)->plans;
	printf("  in 1.5 s: %u searches and %u routes joined (%u waits); without the board %u searches\n",
	       (unsigned)st->plans, (unsigned)st->route_joins, (unsigned)st->route_waits, plans_alone);
	CHECK(st->route_joins >= BOTS - 2);
	CHECK(st->plans <= 2);
	CHECK(plans_alone >= BOTS);
	CHECK(st->route_join_fails == 0);
	for (i = 0; i < BOTS; i++) {
		const bc_bot *b = bc_engine_bot(s->e, i);
		const bc_nav_route *r = &b->mv.route;

		if (!b->mv.has_route)
			continue;
		routes++;
		/* its own: from where it stood when it asked, and every step
		 * of it fits the map now; whole to the goal */
		own_start += r->start.x == b->mv.plan_from.x && r->start.y == b->mv.plan_from.y && r->start.z == b->mv.plan_from.z;
		holds += bc_nav_route_holds(r, 0, r->n, s->e->moves, s->e->map);
		whole += !r->partial && r->n > 0 && abs(r->steps[r->n - 1].to.x - b->mv.goal.x) <= b->mv.radius &&
		         abs(r->steps[r->n - 1].to.y - b->mv.goal.y) <= b->mv.radius;
		near += through(r, NEAR_Y);
	}
	printf("  %d of %d bots on a route: %d from their own start, %d holding on the map, %d whole, %d by the near gap\n",
	       routes, BOTS, own_start, holds, whole, near);
	CHECK(routes == BOTS);
	CHECK(own_start == routes && holds == routes && whole == routes);
	CHECK(near == routes);

	printf("the near gap is walled up: everybody who had the route plans again\n");
	replans = st->replans;
	for (i = 0; i < 3; i++) {
		int z;

		for (z = G - 1; z >= G - 4; z--)
			bs_block(s, BL_NO_PLAYER, WALL_X, NEAR_Y + i, z, BL_B_BUILD);
	}
	bs_run(s, 2.0);
	for (i = 0; i < BOTS; i++) {
		const bc_bot *b = bc_engine_bot(s->e, i);

		off_near += !b->mv.has_route || !through(&b->mv.route, NEAR_Y);
	}
	printf("  %u replans; %d of %d bots off the walled-up way (routes %u shared, %u joined in all)\n",
	       (unsigned)(st->replans - replans), off_near, BOTS, (unsigned)st->routes_published, (unsigned)st->route_joins);
	CHECK(st->replans - replans >= (unsigned)near);
	CHECK(off_near == BOTS);
	bs_run(s, 40.0);
	for (i = 0; i < BOTS; i++) {
		float dx = s->p[i].body.pos.x - 290.5f, dy = s->p[i].body.pos.y - 230.5f;

		there += dx * dx + dy * dy < 3.0f * 3.0f;
	}
	printf("  %d of %d there by the far gap after 40 s\n", there, BOTS);
	CHECK(there == BOTS);
	bs_free(s);
	bs_free(alone);
}

/* The board itself: who may take what, and a broken route taken off. */
static void test_board(void)
{
	static bc_route_board bd;
	static bc_nav_route r;
	bc_map *m = malloc(sizeof *m);
	bc_nav_moves *t = malloc(sizeof *t);
	void *mem = malloc(bc_nav_search_size(131072));
	bc_nav_search *sr = bc_nav_search_init(mem, 131072);
	bc_nav_policy p;
	bc_nav_node a = { 100, 100, G }, b = { 140, 100, G }, near = { 101, 104, G };
	bc_route_key k, mine;
	bc_shared_route *sh;
	uint32_t id;
	int step = 0, z;

	printf("the board: what may be taken, and a route an edit breaks\n");
	bc_map_clear(m);
	bc_nav_moves_measure(t, m);     /* on an empty map, as the engine does */
	bc_map_fill_flat(m, G);
	bc_nav_policy_default(&p);
	CHECK(bc_nav_plan_begin(sr, t, m, &p, a, b, 0));
	CHECK(bc_nav_plan_step(sr, 100000) == BC_NAV_DONE);
	bc_nav_plan_route(sr, &r);
	bc_routes_clear(&bd);
	CHECK(bc_route_key_of(&p, 1, 0, b, 0, 0, 0, &k));
	id = bc_routes_publish(&bd, &k, &r, 1, 10.0);
	mine = k;
	CHECK(bc_routes_find(&bd, &mine, near, 11.0, t, m, &step) == id);
	CHECK(step >= -1 && step < 3);
	CHECK(bc_routes_find(&bd, &mine, near, 12.5, t, m, &step) == 0);      /* too old */
	mine.team = 2;
	CHECK(bc_routes_find(&bd, &mine, near, 11.0, t, m, &step) == 0);      /* the other team's */
	mine = k;
	mine.goal.x++;
	CHECK(bc_routes_find(&bd, &mine, near, 11.0, t, m, &step) == 0);      /* another goal */
	mine = k;
	mine.may_dig = 1;
	CHECK(bc_routes_find(&bd, &mine, near, 11.0, t, m, &step) == 0);      /* other rules */
	{
		/* no edits on it and it arrives: any pouch and cadence */
		mine = k;
		mine.blocks = 7;
		mine.dig_secs = 0.1f;
		CHECK(bc_routes_find(&bd, &mine, near, 11.0, t, m, &step) == id);
	}
	{
		/* a local search, or dangers of the bot's own: not shared */
		bc_nav_policy q = p;
		bc_nav_danger d = { 1, 1, 1, 1 };

		q.scope = 8;
		CHECK(!bc_route_key_of(&q, 1, 0, b, 0, 0, 0, &mine));
		q.scope = 0;
		q.danger = &d;
		q.ndanger = 1;
		CHECK(!bc_route_key_of(&q, 1, 0, b, 0, 0, 0, &mine));
		CHECK(bc_route_key_of(&q, 1, 1, b, 0, 0, 0, &mine));
		CHECK(!bc_route_claim_fits(&mine, &k));                 /* another danger list */
	}
	{
		/* a partial route: for a pouch no bigger than its maker's */
		bc_route_key part = k;

		part.blocks = 10;
		id = bc_routes_publish(&bd, &part, &r, 0, 10.0);
		mine = part;
		mine.blocks = 20;
		sh = (bc_shared_route *)bc_routes_get(&bd, id);
		CHECK(sh && !bc_route_adoptable(&mine, sh));
		mine.blocks = 5;
		CHECK(sh && bc_route_adoptable(&mine, sh));
	}
	/* a wall across it: the route no longer holds, and goes */
	for (z = G - 3; z < G; z++)
		bc_map_set(m, 120, 100, z, 1);
	mine = k;
	CHECK(bc_routes_find(&bd, &mine, near, 11.0, t, m, &step) == 0);
	CHECK(bc_routes_get(&bd, 1) == NULL);
	free(mem);
	free(t);
	free(m);
}

int main(void)
{
	test_board();
	test_share();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
