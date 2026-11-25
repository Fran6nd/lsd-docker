/* parallel_test.c -- the planner's units on threads change nothing: the
 * same seed is the same intents, think for think, whether the core runs
 * the units itself or botd's pool (botd/pool.h) runs them on 1, 2, 3 or 4
 * threads (core/engine.h, THE PLANNER'S WORK AS UNITS). A game of 20 a
 * side on a field of walls, the route board on and off, with the budget
 * the planner shares out and with one too thin to share (the units handed
 * over one at a time). On the simulated server of brain_sim.h. */
#include "brain_sim.h"
#include "../botd/pool.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40 };

static long batches, together;

static void unit_job(void *ctx, int i)
{
	bc_plan_unit_run(&((bc_plan_unit *)ctx)[i]);
}

static void run_units(void *pool, bc_plan_unit *u, int n)
{
	batches++;
	together += n > 1;
	botd_pool_run(pool, unit_job, u, n);
}

/* FNV-1a over everything the bots said */
static uint64_t hash(uint64_t h, const void *p, size_t n)
{
	const unsigned char *c = p;

	while (n--) { h ^= *c++; h *= 1099511628211ull; }
	return h;
}

typedef struct outcome { uint64_t intents; uint32_t plans, expansions, joins, kills; } outcome;

/* threads 0: no runner (the core runs the units itself) */
static outcome game(int threads, int share, int thin)
{
	bs_sim *s = bs_new(G, 40);
	botd_pool *pool = threads > 0 ? botd_pool_new(threads) : NULL;
	const bc_engine_stats *st;
	outcome o;
	char set[32];
	int i, k;

	s->have_tents = 1;
	s->tent[0].x = 190.5f; s->tent[0].y = 256.5f; s->tent[0].z = (float)G - 2.25f;
	s->tent[1].x = 320.5f; s->tent[1].y = 256.5f; s->tent[1].z = (float)G - 2.25f;
	for (i = 0; i < 40; i++) {
		int x = 206 + (i % 8) * 13 + (i * 5) % 7, y = 206 + (i / 8) * 21 + (i * 11) % 9;

		if (i % 2) bs_box(s, x, y, G - 4, x, y + 6, G - 1, 1);
		else bs_box(s, x, y, G - 4, x + 6, y, G - 1, 1);
	}
	bs_start(s);
	if (pool)
		bc_engine_plan_runner(s->e, run_units, pool);
	if (thin) {
		/* a budget too thin to share: the units one at a time */
		s->budget = 90;
		bc_engine_plan_rate(s->e, 0, 60);
	}
	snprintf(set, sizeof set, "plan.share=%d", share);
	bs_set(s, BL_NO_PLAYER, set);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	s->respawn = 3.0;
	for (i = 0; i < 20; i++) {
		bs_add(s, i, 1, 1, 3 + (i * 3) % 7, i % 3, 2026u + (uint32_t)i * 7919u, 192.5f + (float)(i % 4) * 2.5f, 232.5f + 2.5f * (float)i, 1, 0);
		bs_add(s, 100 + i, 1, 2, 3 + (i * 5) % 7, (i + 1) % 3, 2526u + (uint32_t)i * 104729u, 318.5f - (float)(i % 4) * 2.5f, 232.5f + 2.5f * (float)i, -1, 0);
	}
	o.intents = 1469598103934665603ull;
	for (k = 0; k < 60 * 25; k++) {
		bs_step(s);
		o.intents = hash(o.intents, s->intents, sizeof s->intents);
	}
	st = bc_engine_stats_get(s->e);
	o.plans = st->plans;
	o.expansions = st->expansions;
	o.joins = st->route_joins;
	o.kills = (uint32_t)(s->kills[1] + s->kills[2]);
	bs_free(s);
	botd_pool_free(pool);
	return o;
}

static void same_whatever_the_threads(int share, int thin)
{
	outcome base = game(0, share, thin);
	int t;

	printf("route board %s, %s budget: %u plans, %u expansions, %u joins, %u kills, intents %016llx\n",
	       share ? "on" : "off", thin ? "a thin" : "the shared", base.plans, base.expansions, base.joins, base.kills,
	       (unsigned long long)base.intents);
	CHECK(base.plans > 50);
	for (t = 1; t <= 4; t++) {
		outcome o;

		batches = together = 0;
		o = game(t, share, thin);
		printf("  %d thread%s: %s (%ld batches, %ld of several units)\n", t, t == 1 ? " " : "s",
		       o.intents == base.intents && o.plans == base.plans && o.expansions == base.expansions ? "the same" : "DIFFERENT",
		       batches, together);
		CHECK(o.intents == base.intents);
		CHECK(o.plans == base.plans && o.expansions == base.expansions && o.joins == base.joins && o.kills == base.kills);
		CHECK(batches > 0);
		if (thin) CHECK(together == 0);
		else CHECK(together > 0);
	}
}

int main(void)
{
	same_whatever_the_threads(1, 0);
	same_whatever_the_threads(0, 0);
	same_whatever_the_threads(1, 1);
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
