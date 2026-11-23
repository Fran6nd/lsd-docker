/* body_test.c -- body: that the server's physics is what is compiled in,
 * and that it has not drifted.
 *
 * Three kinds of check:
 *   - the numbers every Ace of Spades player knows (paces, jump height,
 *     the one-voxel climb, where a fall starts to hurt), read off the body
 *     from outside;
 *   - the server's surprises that body.h warns of, pinned so that a fix
 *     upstream is noticed;
 *   - a long scripted run over an obstacle course, hashed: any change to
 *     lsd/src/demoncore.c that moves a body by one bit fails here.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "body.h"
#include "rng.h"

/* pinned on arm64 macOS, clang 17 */
#define DRIFT_HASH 0xbcc4329fu

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; \
	printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)
#define NEAR(a, b, e) (fabs((double)(a) - (double)(b)) < (e))

static bc_map *m;
static const bc_v3 east = {1.0f, 0.0f, 0.0f};

static void run(bc_body *b, uint8_t keys, int ticks)
{
	int i;

	for (i = 0; i < ticks; i++)
		bc_body_step(b, m, keys, east, BC_BODY_DT);
}

static float pace(uint8_t keys, int scoped)
{
	bc_body b;

	bc_body_place(&b, m, 100.5f, 100.5f, 40, (keys & BC_K_CROUCH) != 0);
	b.scoped = (uint8_t)scoped;
	run(&b, (uint8_t)(BC_K_FORWARD | keys), 240);
	return bc_body_speed(&b);
}

static void test_shape(void)
{
	bc_body b;

	bc_map_fill_flat(m, 40);
	bc_body_place(&b, m, 100.5f, 100.5f, 40, 0);
	CHECK(!b.airborne && b.vel.z == 0.0f);
	CHECK(bc_body_feet(&b) < 40.0f && bc_body_feet(&b) > 39.97f);
	CHECK(NEAR(b.pos.z, 40.0 - 2.25, 0.03));
	bc_body_place(&b, m, 100.5f, 100.5f, 40, 1);
	CHECK(NEAR(b.pos.z, 40.0 - 1.35, 0.03));        /* crouched: the eye 0.9 lower */
	CHECK(NEAR(bc_body_feet(&b), 40.0, 0.03));
	CHECK(bc_body_can_stand(&b, m));

	/* under a ceiling two voxels up a crouched body must stay crouched */
	bc_map_set(m, 100, 100, 37, 1);
	CHECK(!bc_body_can_stand(&b, m));
	bc_map_set(m, 100, 100, 37, 0);
	bc_map_set(m, 100, 100, 36, 1);                 /* three up: room */
	CHECK(bc_body_can_stand(&b, m));

	/* held up by a corner: the centre 0.4 past an edge */
	bc_map_fill_flat(m, 62);
	bc_map_set(m, 100, 100, 40, 1);
	bc_body_place(&b, m, 101.4f, 100.5f, 40, 0);
	CHECK(NEAR(bc_body_feet(&b), 40.0, 0.03));
	bc_body_place(&b, m, 101.5f, 100.5f, 40, 0);    /* 0.5 past: nothing under it */
	CHECK(bc_body_feet(&b) > 60.0f);

	/* water: the feet a voxel under the sea bed's top, wading */
	bc_map_fill_flat(m, 63);
	bc_body_place(&b, m, 100.5f, 100.5f, 63, 0);
	CHECK(NEAR(bc_body_feet(&b), 64.0, 0.03) && b.wade);
	bc_map_fill_flat(m, 62);
	bc_body_place(&b, m, 100.5f, 100.5f, 62, 0);
	CHECK(NEAR(bc_body_feet(&b), 62.0, 0.03) && !b.wade);
}

static void test_paces(void)
{
	bc_body b;

	bc_map_fill_flat(m, 40);
	CHECK(NEAR(pace(0, 0), 8.0, 0.01));
	CHECK(NEAR(pace(BC_K_SPRINT, 0), 10.4, 0.01));
	CHECK(NEAR(pace(BC_K_CROUCH, 0), 2.4, 0.01));
	CHECK(NEAR(pace(BC_K_SNEAK, 0), 4.0, 0.01));
	CHECK(NEAR(pace(0, 1), 4.0, 0.01));             /* sights up */
	bc_map_fill_flat(m, 63);
	bc_body_place(&b, m, 100.5f, 100.5f, 63, 0);
	run(&b, BC_K_FORWARD, 240);
	CHECK(NEAR(bc_body_speed(&b), 5.333, 0.01));    /* wading: two thirds */
}

static void test_jump_and_climb(void)
{
	bc_body b;
	float z0, top;
	int i, air;

	/* a jump: 1.6 up, 39 ticks, and an event not a state */
	bc_map_fill_flat(m, 40);
	bc_body_place(&b, m, 100.5f, 100.5f, 40, 0);
	z0 = top = b.pos.z;
	bc_body_step(&b, m, BC_K_JUMP, east, BC_BODY_DT);
	CHECK(b.vel.z < 0.0f && b.airborne);
	CHECK(!(b.keys & BC_K_JUMP));                   /* consumed */
	for (air = 1; air < 200 && b.airborne; air++) {
		float vz = b.vel.z;

		bc_body_step(&b, m, BC_K_JUMP, east, BC_BODY_DT);       /* held: ignored in the air */
		if (b.airborne)
			CHECK(b.vel.z > vz);
		if (b.pos.z < top)
			top = b.pos.z;
	}
	CHECK(air == 39);
	CHECK(NEAR(z0 - top, 1.60, 0.02));

	/* a step one high: a walk climbs it; a sprint, a crouch, or a head
	 * bowed past 30 degrees does not */
	for (i = 0; i < 4; i++) {
		bc_v3 ori = east;
		uint8_t keys = BC_K_FORWARD;
		int x, y;

		bc_map_fill_flat(m, 40);
		for (y = 95; y < 106; y++)
			for (x = 104; x < 120; x++)
				bc_map_set(m, x, y, 39, 1);
		if (i == 1) keys |= BC_K_SPRINT;
		if (i == 2) keys |= BC_K_CROUCH;
		if (i == 3) { ori.x = 0.8f; ori.z = 0.6f; }
		bc_body_place(&b, m, 100.5f, 100.5f, 40, i == 2);
		for (x = 0; x < 100; x++)
			bc_body_step(&b, m, keys, ori, BC_BODY_DT);
		if (i == 0)
			CHECK(b.pos.x > 106.0f && NEAR(bc_body_feet(&b), 39.0, 0.03));
		else
			CHECK(b.pos.x < 103.6f && NEAR(bc_body_feet(&b), 40.0, 0.03));
	}
}

/* Walk off a ledge h voxels up; what the landing costs. */
static int fall(int h)
{
	bc_body b;
	int x, i;

	bc_map_fill_flat(m, 40);
	for (x = 90; x <= 100; x++)
		for (i = 40 - h; i < 40; i++)
			bc_map_set(m, x, 100, i, 1);
	bc_body_place(&b, m, 100.5f, 100.5f, 40 - h, 0);
	for (i = 0; i < 600; i++) {
		int32_t d = bc_body_step(&b, m, BC_K_FORWARD, east, BC_BODY_DT);

		if (d >= 0)
			return (int)d;
	}
	return -1;
}

static void test_falls(void)
{
	/* nine voxels is free; then it climbs fast (the server's formula) */
	CHECK(fall(2) == 0 && fall(9) == 0);
	CHECK(fall(10) == 1);
	CHECK(fall(11) == 5);
	CHECK(fall(12) == 12);
	CHECK(fall(13) == 21);
	CHECK(fall(14) == 32);
	CHECK(fall(1) == -1);                           /* a step down is not a landing */
}

static void test_quirks(void)
{
	bc_body b;
	float z;
	int i, air = 0;

	/* crouch changed in the air lifts the eye 0.9, both ways */
	bc_map_fill_flat(m, 40);
	bc_body_place(&b, m, 100.5f, 100.5f, 40, 0);
	bc_body_step(&b, m, BC_K_JUMP, east, BC_BODY_DT);
	run(&b, 0, 5);
	z = b.pos.z;
	bc_body_step(&b, m, BC_K_CROUCH, east, BC_BODY_DT);
	CHECK(b.pos.z < z - 0.8f);
	z = b.pos.z;
	bc_body_step(&b, m, 0, east, BC_BODY_DT);
	CHECK(b.pos.z < z - 0.8f);

	/* after a landing the body is "airborne" for most of the ticks it
	 * takes to settle the last hundredths -- and a jump asked then is
	 * dropped */
	bc_body_place(&b, m, 100.5f, 100.5f, 40, 0);
	bc_body_step(&b, m, BC_K_JUMP, east, BC_BODY_DT);
	while (b.airborne)
		bc_body_step(&b, m, 0, east, BC_BODY_DT);
	for (i = 0; i < 12; i++) {
		bc_body_step(&b, m, 0, east, BC_BODY_DT);
		air += b.airborne;
	}
	CHECK(air >= 3);
	CHECK(bc_body_feet(&b) > 39.6f);                /* yet it never left the floor */
}

/* The drift alarm: 3000 ticks of keys drawn from a fixed seed over a
 * course with steps, walls, a pit, a ceiling and water. */
static void test_drift(void)
{
	bc_rng rng;
	bc_body b;
	uint32_t h = 2166136261u;
	uint8_t keys = 0;
	bc_v3 ori = east;
	int x, y, i;

	bc_map_fill_flat(m, 40);
	for (y = 80; y < 120; y++)
		for (x = 80; x < 120; x++) {
			int top = 40 - ((x * 7 + y * 3) % 5 == 0) - ((x + y) % 11 == 0) * 2;

			if ((x * 5 + y) % 23 == 0)
				top = 44;
			if (x > 112)
				top = 63;
			m->col[y * BC_MAP_X + x] = ~(uint64_t)0 << top;
			if ((x + 2 * y) % 13 == 0 && top < 63)
				m->col[y * BC_MAP_X + x] |= (uint64_t)1 << (top - 3);
		}
	bc_rng_seed(&rng, 2026, 11);
	bc_body_place(&b, m, 100.5f, 100.5f, 40, 0);
	for (i = 0; i < 3000; i++) {
		unsigned char raw[24];
		int k;

		if (i % 20 == 0) {
			float a = bc_rng_range(&rng, 0.0f, 6.2831853f);

			keys = (uint8_t)bc_rng_below(&rng, 256);
			if (b.airborne)         /* body.h: never change crouch in the air */
				keys = (uint8_t)((keys & ~BC_K_CROUCH) | (b.keys & BC_K_CROUCH));
			ori.x = cosf(a); ori.y = sinf(a); ori.z = bc_rng_range(&rng, -0.4f, 0.7f);
		} else {
			keys = (uint8_t)((keys & ~(BC_K_JUMP | BC_K_CROUCH)) | (b.keys & BC_K_CROUCH));
		}
		bc_body_step(&b, m, keys, ori, BC_BODY_DT);
		if (b.pos.x < 82.0f || b.pos.x > 118.0f || b.pos.y < 82.0f || b.pos.y > 118.0f)
			bc_body_place(&b, m, 100.5f, 100.5f, 40, 0);
		memcpy(raw, &b.pos, 12);
		memcpy(raw + 12, &b.vel, 12);
		for (k = 0; k < 24; k++)
			h = (h ^ raw[k]) * 16777619u;
	}
	printf("  drift: 3000 scripted ticks, trajectory hash 0x%08x\n", h);
	CHECK(h == DRIFT_HASH);
	if (h != DRIFT_HASH)
		printf("  the trajectory changed: lsd/src/demoncore.c did, or this machine's "
		       "float arithmetic differs (the engine is built -ffp-contract=off;\n"
		       "  cosf/sinf feed the script's facings and may differ in the last bit "
		       "between C libraries). If the checks above still pass, read the\n"
		       "  physics diff, then pin the new hash -- and expect nav_test's table "
		       "to want the same.\n");
}

int main(void)
{
	m = malloc(sizeof *m);
	if (!m)
		return 1;
	test_shape();
	test_paces();
	test_jump_and_climb();
	test_falls();
	test_quirks();
	test_drift();
	printf("%d checks, %d failed\n", checks, failed);
	free(m);
	return failed != 0;
}
