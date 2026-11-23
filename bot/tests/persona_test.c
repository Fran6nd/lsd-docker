/* persona_test.c -- rolls are reproducible, readable as their archetype, and weighted */
#include "persona.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

/* the centres in persona.c's table, pinned here: tune both together */
static const float centre[BC_A_COUNT][BC_T_COUNT - 1] = {
	{ 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f },
	{ 0.5f, 1.8f, 0.8f, 0.9f, 1.0f, 1.8f, 0.5f, 1.2f, 0.8f, 1.0f },
	{ 1.9f, 0.6f, 1.6f, 1.0f, 0.8f, 0.8f, 0.8f, 0.5f, 0.9f, 1.3f },
	{ 1.2f, 0.9f, 1.0f, 0.7f, 0.8f, 0.9f, 1.9f, 1.8f, 1.1f, 1.0f },
	{ 0.8f, 1.1f, 1.1f, 1.9f, 1.6f, 0.9f, 0.7f, 0.9f, 0.9f, 1.0f },
	{ 0.8f, 1.0f, 1.0f, 1.0f, 2.5f, 0.8f, 0.9f, 1.0f, 1.0f, 1.2f },
	{ 0.8f, 0.9f, 0.9f, 0.8f, 0.7f, 0.9f, 1.2f, 1.7f, 1.9f, 0.9f },
};

static int same(const bc_persona *a, const bc_persona *b)
{
	int t;
	for (t = 0; t < BC_T_COUNT; t++) if (a->trait[t] != b->trait[t]) return 0;
	return a->archetype == b->archetype && a->level == b->level;
}

int main(void)
{
	bc_rng r1, r2;
	bc_persona p, q;
	int i, t, a, n = 3500;
	static double sum[BC_A_COUNT][BC_T_COUNT];
	static int cnt[BC_A_COUNT];
	float w[BC_A_COUNT] = { 3, 1, 2, 0, 1, 1, 2 }, wsum = 10;
	int drawn[BC_A_COUNT] = {0};

	/* same seed, same persona; different seeds differ */
	bc_rng_seed(&r1, 99, 0); bc_persona_roll(&p, &r1, NULL, 5);
	bc_rng_seed(&r2, 99, 0); bc_persona_roll(&q, &r2, NULL, 5);
	CHECK(same(&p, &q));
	{
		int differ = 0;
		for (i = 0; i < 20; i++) {
			bc_rng_seed(&r2, 1000 + (uint64_t)i, 0);
			bc_persona_roll(&q, &r2, NULL, 5);
			differ += !same(&p, &q);
		}
		CHECK(differ == 20);
	}

	/* clamps */
	bc_rng_seed(&r1, 5, 0);
	bc_persona_roll(&p, &r1, NULL, 0);   CHECK(p.level == 1);
	bc_persona_roll(&p, &r1, NULL, -4);  CHECK(p.level == 1);
	bc_persona_roll(&p, &r1, NULL, 99);  CHECK(p.level == 10);
	bc_persona_roll(&p, &r1, NULL, 7);   CHECK(p.level == 7);

	/* means near their centres; every trait in range; NONE exactly 1 */
	bc_rng_seed(&r1, 12345, 0);
	for (i = 0; i < n; i++) {
		bc_persona_roll(&p, &r1, NULL, 5);
		CHECK(p.archetype < BC_A_COUNT);
		CHECK(p.trait[BC_T_NONE] == 1.0f);
		for (t = 1; t < BC_T_COUNT; t++) {
			CHECK(p.trait[t] >= 0.2f && p.trait[t] <= 3.0f);
			sum[p.archetype][t] += p.trait[t];
		}
		cnt[p.archetype]++;
	}
	for (a = 0; a < BC_A_COUNT; a++) {
		CHECK(cnt[a] > 300);
		for (t = 1; t < BC_T_COUNT; t++)
			CHECK(fabs(sum[a][t] / cnt[a] - centre[a][t - 1]) < 0.1);
	}
	/* each reads as its name */
	CHECK(centre[BC_A_CAMPER][BC_T_CAUTION - 1] > 1.5f && centre[BC_A_CAMPER][BC_T_MARKSMAN - 1] > 1.5f);
	CHECK(sum[BC_A_CAMPER][BC_T_AGGRESSION] / cnt[BC_A_CAMPER] < 0.7);
	CHECK(sum[BC_A_PUSHER][BC_T_AGGRESSION] / cnt[BC_A_PUSHER] > 1.5);
	CHECK(sum[BC_A_PUSHER][BC_T_OBJECTIVE] / cnt[BC_A_PUSHER] > 1.3);
	CHECK(sum[BC_A_FLANKER][BC_T_FLANK] / cnt[BC_A_FLANKER] > 1.5);
	CHECK(sum[BC_A_FLANKER][BC_T_STEALTH] / cnt[BC_A_FLANKER] > 1.5);
	CHECK(sum[BC_A_SUPPORT][BC_T_TEAMWORK] / cnt[BC_A_SUPPORT] > 1.5);
	CHECK(sum[BC_A_SUPPORT][BC_T_BUILDER] / cnt[BC_A_SUPPORT] > 1.3);
	CHECK(sum[BC_A_SAPPER][BC_T_BUILDER] / cnt[BC_A_SAPPER] > 2.2);
	CHECK(sum[BC_A_SCOUT][BC_T_CURIOSITY] / cnt[BC_A_SCOUT] > 1.5);
	CHECK(sum[BC_A_SCOUT][BC_T_STEALTH] / cnt[BC_A_SCOUT] > 1.4);
	/* the spread is real: two pushers differ */
	{
		float first = -1; int var = 0;
		bc_rng_seed(&r1, 3, 0);
		for (i = 0; i < 400 && var < 10; i++) {
			float w1[BC_A_COUNT] = { 0, 0, 1, 0, 0, 0, 0 };
			bc_persona_roll(&p, &r1, w1, 5);
			CHECK(p.archetype == BC_A_PUSHER);
			if (first < 0) first = p.trait[BC_T_AGGRESSION];
			else if (p.trait[BC_T_AGGRESSION] != first) var++;
		}
		CHECK(var >= 10);
	}

	/* archetypes in proportion to weights; weight 0 never */
	bc_rng_seed(&r1, 777, 0);
	for (i = 0; i < n; i++) { bc_persona_roll(&p, &r1, w, 5); drawn[p.archetype]++; }
	for (a = 0; a < BC_A_COUNT; a++) CHECK(fabs((double)drawn[a] / n - w[a] / wsum) < 0.03);
	CHECK(drawn[BC_A_FLANKER] == 0);
	/* all-zero weights fall back to even rather than loop or crash */
	{
		float z[BC_A_COUNT] = {0};
		bc_persona_roll(&p, &r1, z, 5);
		CHECK(p.archetype < BC_A_COUNT);
	}

	/* names */
	for (t = 0; t < BC_T_COUNT; t++) CHECK(bc_trait_by_name(bc_trait_name(t)) == t);
	for (a = 0; a < BC_A_COUNT; a++) CHECK(bc_archetype_by_name(bc_archetype_name(a)) == a);
	CHECK(bc_trait_by_name("aggression") == BC_T_AGGRESSION);
	CHECK(bc_trait_by_name("none") == BC_T_NONE);
	CHECK(bc_archetype_by_name("camper") == BC_A_CAMPER);
	CHECK(bc_trait_by_name("bogus") == -1 && bc_trait_by_name(NULL) == -1 && bc_trait_by_name("") == -1);
	CHECK(bc_archetype_by_name("bogus") == -1 && bc_archetype_by_name(NULL) == -1);
	CHECK(bc_trait_name(-1) == NULL && bc_trait_name(BC_T_COUNT) == NULL);
	CHECK(bc_archetype_name(BC_A_COUNT) == NULL);

	/* weights text */
	{
		float x[BC_A_COUNT];
		for (i = 0; i < BC_A_COUNT; i++) x[i] = 7;
		CHECK(bc_archetype_weights("camper:2,pusher:3", x));
		CHECK(x[BC_A_CAMPER] == 2 && x[BC_A_PUSHER] == 3 && x[BC_A_SOLDIER] == 0 && x[BC_A_SCOUT] == 0);
		CHECK(bc_archetype_weights("", x));
		for (i = 0; i < BC_A_COUNT; i++) CHECK(x[i] == 1);
		for (i = 0; i < BC_A_COUNT; i++) x[i] = 7;
		CHECK(bc_archetype_weights(NULL, x) && x[0] == 1);
		CHECK(bc_archetype_weights(" camper : 2.5 , scout ", x));
		CHECK(x[BC_A_CAMPER] == 2.5f && x[BC_A_SCOUT] == 1 && x[BC_A_PUSHER] == 0);
		for (i = 0; i < BC_A_COUNT; i++) x[i] = 7;
		CHECK(!bc_archetype_weights("bogus:2", x));
		CHECK(!bc_archetype_weights("camper:x", x));
		CHECK(!bc_archetype_weights("camper:-1", x));
		CHECK(!bc_archetype_weights("camper:2,", x));
		CHECK(!bc_archetype_weights("camper:2 pusher:3", x));
		CHECK(!bc_archetype_weights("camper:2,nope", x));
		for (i = 0; i < BC_A_COUNT; i++) CHECK(x[i] == 7);   /* untouched on failure */
		CHECK(!bc_archetype_weights("camper", NULL));
	}

	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
