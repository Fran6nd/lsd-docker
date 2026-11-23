/* map_test.c -- map and cull: the loader, the queries, every block action
 * with what it must leave, the collapse, and the report of what changed.
 *
 *   BC_TEST_MAPS=dir   also load every .vxl in dir
 *
 * (That the result is the SERVER's, bit for bit, is cull_parity_test's
 * business: it runs the server's code beside this.)
 */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cull.h"
#include "map.h"
#include "rng.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; \
	if (failed < 30) printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static bc_map *m, *m2;
static bc_cull *cull;

static int popcount64(uint64_t v)
{
	int n = 0;

	for (; v; v &= v - 1)
		n++;
	return n;
}

static int count_box(int x0, int y0, int z0, int x1, int y1, int z1)
{
	int x, y, z, n = 0;

	for (z = z0; z <= z1; z++)
		for (y = y0; y <= y1; y++)
			for (x = x0; x <= x1; x++)
				n += bc_map_solid(m, x, y, z);
	return n;
}

static void box(int x0, int y0, int z0, int x1, int y1, int z1)
{
	int x, y, z;

	for (z = z0; z <= z1; z++)
		for (y = y0; y <= y1; y++)
			for (x = x0; x <= x1; x++)
				bc_map_set(m, x, y, z, 1);
}

/* --- a .vxl written by hand, to read back -------------------------------- */

/* Encode a map as VXL: every solid run a span, all of it "coloured top"
 * except the last, which is one coloured voxel and solid to the bottom. */
static size_t write_vxl(const bc_map *src, unsigned char *out)
{
	size_t n = 0;
	long xy;

	for (xy = 0; xy < BC_MAP_XY; xy++) {
		uint64_t c = src->col[xy];
		int z = 0, air_start = 0;

		for (;;) {
			int s, e, k;

			while (z < 64 && !((c >> z) & 1))
				z++;
			s = z;
			while (z < 64 && ((c >> z) & 1))
				z++;
			e = z - 1;
			if (e == 63) {
				out[n++] = 0; out[n++] = (unsigned char)s; out[n++] = (unsigned char)s;
				out[n++] = (unsigned char)air_start;
				out[n++] = 1; out[n++] = 2; out[n++] = 3; out[n++] = 0x7f;
				break;
			}
			out[n++] = (unsigned char)(1 + (e - s + 1));
			out[n++] = (unsigned char)s; out[n++] = (unsigned char)e;
			out[n++] = (unsigned char)air_start;
			for (k = s; k <= e; k++) {
				out[n++] = 1; out[n++] = 2; out[n++] = 3; out[n++] = 0x7f;
			}
			air_start = e + 1;
		}
	}
	return n;
}

static void test_loader(void)
{
	static unsigned char buf[BC_MAP_XY * 40];
	bc_rng rng;
	size_t len;
	long xy;

	bc_rng_seed(&rng, 1, 2);
	/* a random world: every column the sea bed plus a few runs */
	bc_map_clear(m);
	for (xy = 0; xy < BC_MAP_XY; xy++) {
		uint64_t c = (uint64_t)1 << 63;
		int k, runs = (int)bc_rng_below(&rng, 4);

		for (k = 0; k < runs; k++) {
			int s = (int)bc_rng_below(&rng, 62), l = 1 + (int)bc_rng_below(&rng, 9);

			c |= (l >= 64 ? ~(uint64_t)0 : (((uint64_t)1 << l) - 1)) << s;
		}
		if (bc_rng_below(&rng, 3))
			c |= ~(uint64_t)0 << (40 + (int)bc_rng_below(&rng, 22));
		m->col[xy] = c;
	}
	len = write_vxl(m, buf);
	CHECK(len < sizeof buf);
	CHECK(bc_map_load_vxl(m2, buf, len) == 1);
	CHECK(memcmp(m->col, m2->col, sizeof m->col) == 0);
	CHECK(m2->cull_personality == BC_CULL_OPENSPADES);

	/* cut short, it says so and does not read past the end */
	CHECK(bc_map_load_vxl(m2, buf, len - 1) == 0);
	CHECK(bc_map_load_vxl(m2, buf, len / 2) == 0);
	CHECK(bc_map_load_vxl(m2, buf, 3) == 0);
	CHECK(bc_map_load_vxl(m2, buf, 0) == 0);
	/* nonsense: a top run that ends below the map */
	{
		unsigned char bad[8] = {0, 10, 70, 0, 0, 0, 0, 0};

		CHECK(bc_map_load_vxl(m2, bad, sizeof bad) == 0);
	}
}

static void test_queries(void)
{
	uint32_t rev;

	bc_map_fill_flat(m, 40);
	CHECK(m->rev == 1);
	CHECK(bc_map_solid(m, 10, 10, 40) && !bc_map_solid(m, 10, 10, 39));
	/* outside: walls and a floor, open sky */
	CHECK(bc_map_solid(m, -1, 10, 20) && bc_map_solid(m, 512, 10, 20));
	CHECK(bc_map_solid(m, 10, -1, 20) && bc_map_solid(m, 10, 512, 20));
	CHECK(bc_map_solid(m, 10, 10, 64) && !bc_map_solid(m, 10, 10, -1));
	CHECK(bc_map_col(m, -1, 0) == 0);

	/* the revision moves when, and only when, something changes */
	rev = m->rev;
	bc_map_set(m, 10, 10, 40, 1);
	CHECK(m->rev == rev);
	bc_map_set(m, 10, 10, 39, 1);
	CHECK(m->rev == rev + 1 && bc_map_solid(m, 10, 10, 39));
	bc_map_set(m, 10, 10, 39, 0);
	CHECK(m->rev == rev + 2 && !bc_map_solid(m, 10, 10, 39));
	bc_map_set(m, 600, 10, 39, 1);
	CHECK(m->rev == rev + 2);

	/* standing needs three voxels of air, crouching exactly two */
	CHECK(bc_map_stand_mask(m, 20, 20) == (uint64_t)1 << 40);
	bc_map_set(m, 20, 20, 36, 1);                   /* a lintel 3 up: still stands */
	CHECK((bc_map_stand_mask(m, 20, 20) >> 40) & 1);
	CHECK((bc_map_stand_mask(m, 20, 20) >> 36) & 1);        /* and on the lintel */
	bc_map_set(m, 20, 20, 37, 1);                   /* 2 up: crouch only */
	CHECK(!((bc_map_stand_mask(m, 20, 20) >> 40) & 1));
	CHECK((bc_map_crouch_bits(bc_map_col(m, 20, 20)) >> 40) & 1);
	bc_map_set(m, 20, 20, 38, 1);                   /* 1 up: neither */
	CHECK(!((bc_map_crouch_bits(bc_map_col(m, 20, 20)) >> 40) & 1));
	/* a floor at the top of the map: the sky is air */
	bc_map_set(m, 21, 21, 1, 1);
	CHECK((bc_map_stand_mask(m, 21, 21) >> 1) & 1);

	CHECK(bc_map_floor_at_or_below(m, 30, 30, 0) == 40);
	CHECK(bc_map_floor_at_or_below(m, 30, 30, 40) == 40);
	CHECK(bc_map_floor_at_or_below(m, 30, 30, 41) == 41);
	CHECK(!bc_map_is_water(m, 30, 30));
	bc_map_fill_flat(m, 63);
	CHECK(bc_map_is_water(m, 30, 30));
	CHECK((bc_map_stand_mask(m, 30, 30) >> 63) & 1);

	CHECK(bc_ctz64(0) == 64 && bc_ctz64(1) == 0 && bc_ctz64((uint64_t)1 << 63) == 63);
	CHECK(bc_ctz64(0x8000) == 15);
}

static void test_actions(void)
{
	uint32_t cells[256];
	bc_map_change chg;
	uint32_t rev;
	int n;

	/* BUILD */
	bc_map_fill_flat(m, 40);
	bc_map_change_init(&chg, cells, 256);
	rev = m->rev;
	CHECK(bc_map_apply(m, NULL, BC_BLOCK_BUILD, 50, 50, 39, &chg) == 1);
	CHECK(bc_map_solid(m, 50, 50, 39) && m->rev == rev + 1);
	CHECK(chg.direct == 1 && chg.collapsed == 0 && chg.n == 1);
	CHECK(cells[0] == ((50u | (50u << 9) | (39u << 18)) | BC_CELL_BUILT));
	CHECK(chg.x0 == 50 && chg.x1 == 50 && chg.z0 == 39 && chg.z1 == 39);
	CHECK(bc_map_apply(m, NULL, BC_BLOCK_BUILD, 50, 50, 39, &chg) == 0);    /* already */
	CHECK(bc_map_apply(m, NULL, BC_BLOCK_BUILD, 50, 50, 99, &chg) == 0);    /* nowhere */
	CHECK(m->rev == rev + 1 && chg.direct == 1);

	/* DESTROY, nothing hanging: one voxel */
	bc_map_change_init(&chg, cells, 256);
	CHECK(bc_map_apply(m, cull, BC_BLOCK_DESTROY, 50, 50, 39, &chg) == 1);
	CHECK(!bc_map_solid(m, 50, 50, 39));
	CHECK(chg.direct == 1 && chg.collapsed == 0);
	CHECK(bc_map_apply(m, cull, BC_BLOCK_DESTROY, 50, 50, 39, &chg) == 0);  /* air */

	/* DESTROY with a collapse: a pole with a 5x5 platform on it. The
	 * report says how much fell, where, and which voxels. */
	bc_map_fill_flat(m, 62);
	box(100, 100, 40, 100, 100, 61);
	box(98, 98, 39, 102, 102, 39);
	bc_map_change_init(&chg, cells, 256);
	rev = m->rev;
	n = bc_map_apply(m, cull, BC_BLOCK_DESTROY, 100, 100, 55, &chg);
	CHECK(n == 1 + 15 + 25);                        /* the voxel, pole 40..54, platform */
	CHECK(chg.direct == 1 && chg.collapsed == 40 && chg.n == 41);
	CHECK(chg.x0 == 98 && chg.x1 == 102 && chg.y0 == 98 && chg.y1 == 102);
	CHECK(chg.z0 == 39 && chg.z1 == 55);
	CHECK(!(cells[0] & BC_CELL_COLLAPSED) && (cells[1] & BC_CELL_COLLAPSED));
	CHECK(count_box(90, 90, 30, 110, 110, 61) == 6);        /* the stump */
	CHECK(m->rev > rev);
	{
		/* every listed voxel is one that is gone */
		int i, ok = 1;

		for (i = 0; i < chg.n; i++)
			ok &= !bc_map_solid(m, (int)(cells[i] & 511), (int)((cells[i] >> 9) & 511),
			                    (int)((cells[i] >> 18) & 63));
		CHECK(ok);
	}
	/* a buffer too small: the counts and the box are still whole */
	bc_map_fill_flat(m, 62);
	box(100, 100, 40, 100, 100, 61);
	box(98, 98, 39, 102, 102, 39);
	bc_map_change_init(&chg, cells, 8);
	CHECK(bc_map_apply(m, cull, BC_BLOCK_DESTROY, 100, 100, 55, &chg) == 41);
	CHECK(chg.collapsed == 40 && chg.n == 8 && chg.x0 == 98 && chg.z0 == 39);
	/* and no report asked for at all */
	bc_map_fill_flat(m, 62);
	box(100, 100, 40, 100, 100, 61);
	CHECK(bc_map_apply(m, cull, BC_BLOCK_DESTROY, 100, 100, 55, NULL) == 16);

	/* what holds: a mass that still touches the ground some other way */
	bc_map_fill_flat(m, 62);
	box(100, 100, 40, 100, 100, 61);
	box(104, 100, 40, 104, 100, 61);
	box(100, 100, 40, 104, 100, 40);
	CHECK(bc_map_apply(m, cull, BC_BLOCK_DESTROY, 100, 100, 55, NULL) == 1);
	CHECK(bc_map_solid(m, 100, 100, 41) && bc_map_solid(m, 102, 100, 40));
	/* touching by an edge is not holding */
	bc_map_fill_flat(m, 62);
	box(100, 100, 40, 100, 100, 61);
	bc_map_set(m, 101, 100, 39, 1);                 /* edge to the pole's top */
	bc_map_set(m, 100, 100, 39, 1);                 /* its real link */
	CHECK(bc_map_apply(m, cull, BC_BLOCK_DESTROY, 100, 100, 39, NULL) == 2);
	CHECK(!bc_map_solid(m, 101, 100, 39));

	/* SPADE: the voxel, the one above, the one below -- and the ground
	 * is never dug */
	bc_map_fill_flat(m, 40);
	CHECK(bc_map_apply(m, cull, BC_BLOCK_SPADE, 60, 60, 41, NULL) == 3);
	CHECK(!bc_map_solid(m, 60, 60, 40) && !bc_map_solid(m, 60, 60, 42));
	CHECK(bc_map_solid(m, 60, 60, 43));
	CHECK(bc_map_apply(m, cull, BC_BLOCK_SPADE, 61, 61, 39, NULL) == 1);    /* only below */
	bc_map_fill_flat(m, 60);
	CHECK(bc_map_apply(m, cull, BC_BLOCK_SPADE, 60, 60, 61, NULL) == 2);    /* 61, 60: not 62 */
	CHECK(bc_map_solid(m, 60, 60, 62));
	CHECK(bc_map_apply(m, cull, BC_BLOCK_SPADE, 62, 62, 62, NULL) == 1);    /* the one above */
	CHECK(bc_map_solid(m, 62, 62, 62) && !bc_map_solid(m, 62, 62, 61));

	/* GRENADE: 3x3x3, nothing at 62 or below, nothing outside the map */
	bc_map_fill_flat(m, 40);
	CHECK(bc_map_apply(m, cull, BC_BLOCK_GRENADE, 70, 70, 40, NULL) == 18);
	CHECK(count_box(69, 69, 40, 71, 71, 42) == 9);
	bc_map_fill_flat(m, 60);
	CHECK(bc_map_apply(m, cull, BC_BLOCK_GRENADE, 70, 70, 62, NULL) == 9);  /* 61 only */
	CHECK(count_box(69, 69, 62, 71, 71, 63) == 18);
	CHECK(bc_map_apply(m, cull, BC_BLOCK_GRENADE, 0, 0, 61, NULL) == 4 * 2);        /* a corner */
	CHECK(bc_map_apply(m, cull, BC_BLOCK_GRENADE, 300, 300, 20, NULL) == 0);        /* thin air */

	/* an action that is not one */
	CHECK(bc_map_apply(m, cull, 9, 70, 70, 41, NULL) == 0);

	/* LINE: the server's walk -- one axis a step, both ends included */
	bc_map_fill_flat(m, 62);
	bc_map_change_init(&chg, cells, 256);
	rev = m->rev;
	CHECK(bc_map_line(m, 10, 10, 30, 15, 10, 30, &chg) == 6);
	CHECK(count_box(10, 10, 30, 15, 10, 30) == 6);
	CHECK(m->rev == rev + 1);
	CHECK(chg.direct == 6 && chg.x0 == 10 && chg.x1 == 15 && chg.n == 6);
	CHECK(cells[0] & BC_CELL_BUILT);
	CHECK(bc_map_line(m, 10, 10, 30, 15, 10, 30, NULL) == 0);       /* all there already */
	CHECK(bc_map_line(m, 20, 20, 20, 23, 23, 23, NULL) == 10);      /* 1 + 3 + 3 + 3 */
	CHECK(bc_map_solid(m, 20, 20, 20) && bc_map_solid(m, 23, 23, 23));
	CHECK(bc_map_line(m, 30, 30, 30, 30, 30, 30, NULL) == 1);       /* a point */
	CHECK(bc_map_line(m, 30, 30, 30, 30, 30, 99, NULL) == 0);       /* an end outside */
}

static void test_personality(void)
{
	/* an island set down floating, and an action beside it that removes
	 * nothing: Voxlap checks the neighbours anyway, OpenSpades does not */
	bc_map_fill_flat(m, 62);
	box(100, 100, 30, 104, 104, 32);
	CHECK(bc_map_apply(m, cull, BC_BLOCK_DESTROY, 105, 102, 31, NULL) == 0);
	CHECK(count_box(100, 100, 30, 104, 104, 32) == 75);
	m->cull_personality = BC_CULL_VOXLAP;
	CHECK(bc_map_apply(m, cull, BC_BLOCK_DESTROY, 105, 102, 31, NULL) == 75);
	CHECK(count_box(100, 100, 30, 104, 104, 32) == 0);
	bc_map_fill_flat(m, 62);
	CHECK(m->cull_personality == BC_CULL_OPENSPADES);       /* a fill resets it */
}

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

static void test_real_maps(void)
{
	const char *dir = getenv("BC_TEST_MAPS");
	DIR *d;
	struct dirent *de;

	if (!dir) {
		printf("  real maps: skipped (set BC_TEST_MAPS to a directory of .vxl files)\n");
		return;
	}
	d = opendir(dir);
	while (d && (de = readdir(d)) != NULL) {
		size_t n = strlen(de->d_name), len = 0;
		char path[1024];
		unsigned char *bytes;
		long xy, water = 0, solid = 0, floors = 0;
		int bed = 1;

		if (n < 5 || strcmp(de->d_name + n - 4, ".vxl") != 0)
			continue;
		snprintf(path, sizeof path, "%s/%s", dir, de->d_name);
		bytes = slurp(path, &len);
		if (!bytes)
			continue;
		CHECK(bc_map_load_vxl(m, bytes, len) == 1);
		for (xy = 0; xy < BC_MAP_XY; xy++) {
			bed &= (int)(m->col[xy] >> 63);
			water += bc_map_is_water(m, (int)(xy % 512), (int)(xy / 512));
			solid += popcount64(m->col[xy]);
			floors += popcount64(bc_map_stand_bits(m->col[xy]));
		}
		CHECK(bed);                             /* the sea bed is everywhere */
		CHECK(floors >= BC_MAP_XY / 2);         /* and there is somewhere to stand */
		/* the same bytes, the same map; a byte short, a refusal */
		CHECK(bc_map_load_vxl(m2, bytes, len) == 1);
		CHECK(memcmp(m->col, m2->col, sizeof m->col) == 0);
		CHECK(bc_map_load_vxl(m2, bytes, len - 5) == 0);
		printf("  %-22s %7zu bytes: %ld solid voxels, %ld water columns, %ld floors to stand on\n",
		       de->d_name, len, solid, water, floors);
		free(bytes);
	}
	if (d)
		closedir(d);
}

int main(void)
{
	m = malloc(sizeof *m);
	m2 = malloc(sizeof *m2);
	cull = malloc(sizeof *cull);
	if (!m || !m2 || !cull)
		return 1;
	bc_cull_init(cull);

	test_loader();
	test_queries();
	test_actions();
	test_personality();
	test_real_maps();

	printf("%d checks, %d failed\n", checks, failed);
	free(m); free(m2); free(cull);
	return failed != 0;
}
