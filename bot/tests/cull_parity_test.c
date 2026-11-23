/* cull_parity_test.c -- bc_map against the server's own code, bit for bit.
 *
 * The engine's map must be the server's after every block action, the
 * collapse of what was left floating included, and nobody announces a
 * collapse: the only way to know the two agree is to run both.
 *
 * THE REFERENCE is the real thing wherever it can be compiled in:
 *   - lsd/src/libpvx2/src/cull.c  -- map_cull, the flood itself
 *   - lsd/src/libpvx2/src/read.c  -- vxl_read, the loader
 *   - lsd/src/libpvx2/src/map.c   -- the column accessors
 * are #included below, unmodified. What decides WHICH voxels are removed
 * and WHICH neighbours get the flood lives in lsd/src/main.c as static
 * functions inside the server (block_action_rm, block_action_cull,
 * grenade_rmblocks, grenade_cullblocks, cull_grenade) and cannot be
 * included without the whole server; it is copied here, statement for
 * statement, with st->globals.map spelt `ref`. So: the flood and the
 * loader are proven against the server's code; the action logic is
 * proven against a second, independent transcription of it.
 *
 * libpvx2 needs __builtin_clzg and the `assume` attribute (clang 19+,
 * GCC 14+). Where the compiler has neither this test says SKIPPED and
 * passes: it has then proven nothing.
 *
 *   BC_TEST_MAPS=dir   also run on every .vxl in dir (random actions on
 *                      real maps, and the loader compared)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cull.h"
#include "map.h"
#include "rng.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; \
	if (failed < 20) printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

#if defined(__has_builtin)
#if __has_builtin(__builtin_clzg) && __has_builtin(__builtin_ctzg)
#define HAVE_PVX2 1
#endif
#endif

#ifndef HAVE_PVX2

int main(void)
{
	printf("cull parity: SKIPPED -- this compiler cannot build lsd/src/libpvx2 "
	       "(needs __builtin_clzg: clang 19+, gcc 14+). Nothing was compared.\n");
	printf("0 checks, 0 failed\n");
	return 0;
}

#else

#include <dirent.h>

/* the server's own, unmodified. It is not written to this engine's
 * -pedantic (it returns void expressions); that is its business. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpedantic"
#include "libpvx2/src/cull.c"
#include "libpvx2/src/read.c"
#pragma GCC diagnostic pop

/* --- lsd/src/main.c, the statics, copied ------------------------------- */

#define CULL_PERSONALITY_VOXLAP 0
#define CULL_PERSONALITY_OPENSPADES 1

static Map ref;
static CullState refcull;
static int cullPersonality;

static int libspades_voxel_bounds_check_player(uint_fast32_t x, uint_fast32_t y, uint_fast32_t z)
{
	return (x < MAP_X && y < MAP_Y && z < (MAP_Z - 2));
}

static void set_empty3(int32_t x, int32_t y, int32_t z)
{
	map_destroy(ref, x, y, z);
}

static int get_solid3(int32_t x, int32_t y, int32_t z)
{
	return map_is_solid(ref, x, y, z);
}

static void cull3(int32_t x, int32_t y, int32_t z)
{
	if (x >= 0 && y >= 0 && x < 512 && y < 512 && z >= 0 && z < 64)
		map_cull(ref, refcull, x, y, z);
}

static void cull_grenade(uint_fast32_t x, uint_fast32_t y, uint_fast32_t z,
                         int_fast8_t xOffset, int_fast8_t yOffset, int_fast8_t zOffset)
{
	if (xOffset != 0 && yOffset != 0 && zOffset != 0) {
		cull3(x + xOffset * 2, y + yOffset, z + zOffset);
		cull3(x + xOffset, y + yOffset * 2, z + zOffset);
		cull3(x + xOffset, y + yOffset, z + zOffset * 2);
		return;
	}
	if (xOffset != 0 && yOffset != 0) {
		cull3(x + xOffset * 2, y + yOffset, z);
		cull3(x + xOffset, y + yOffset * 2, z);
		return;
	}
	if (xOffset != 0 && zOffset != 0) {
		cull3(x + xOffset * 2, y, z + zOffset);
		cull3(x + xOffset, y, z + zOffset * 2);
		return;
	}
	if (yOffset != 0 && zOffset != 0) {
		cull3(x, y + yOffset * 2, z + zOffset);
		cull3(x, y + yOffset, z + zOffset * 2);
		return;
	}
	if (xOffset != 0) {
		cull3(x + xOffset * 2, y, z);
		return;
	}
	if (yOffset != 0) {
		cull3(x, y + yOffset * 2, z);
		return;
	}
	if (zOffset != 0) {
		cull3(x, y, z + zOffset * 2);
		return;
	}
}

static void destroyGrenadeVoxel(uint_fast32_t x, uint_fast32_t y, uint_fast32_t z,
                                uint_fast32_t *solids, uint_fast32_t ctr,
                                int_fast8_t xOffset, int_fast8_t yOffset, int_fast8_t zOffset)
{
	if (!libspades_voxel_bounds_check_player(x + xOffset, y + yOffset, z + zOffset) ||
	    !map_is_solid(ref, x + xOffset, y + yOffset, z + zOffset))
		return;

	map_destroy(ref, x + xOffset, y + yOffset, z + zOffset);
	*solids |= ctr;
}

static void grenade_cullblocks(int px, int py, int pz, uint32_t solids)
{
	int ox, oy, oz;
	uint_fast32_t ctr = 1;

	for (oz = -1; oz <= 1; oz++) {
		for (oy = -1; oy <= 1; oy++) {
			for (ox = -1; ox <= 1; ox++) {
				if (solids & ctr || cullPersonality == CULL_PERSONALITY_VOXLAP) {
					cull_grenade(px, py, pz, ox, oy, oz);
				}
				ctr <<= 1;
			}
		}
	}
}

static uint32_t grenade_rmblocks(int px, int py, int pz)
{
	int ox, oy, oz;
	uint_fast32_t solids = 0;
	uint_fast32_t ctr = 1;

	for (oz = -1; oz <= 1; oz++) {
		for (oy = -1; oy <= 1; oy++) {
			for (ox = -1; ox <= 1; ox++) {
				destroyGrenadeVoxel(px, py, pz, &solids, ctr, ox, oy, oz);
				ctr <<= 1;
			}
		}
	}

	return solids;
}

static uint32_t block_action_rm(int px, int py, int pz, unsigned type)
{
	uint32_t mask = 0;
	int full = 0;

	switch (type) {
	case 1: /* destroy */
		if (get_solid3(px, py, pz)) {
			set_empty3(px, py, pz);
			mask = 1;
			full = 1;
		}
		break;
	case 2: /* 3x destroy */
		if (pz < 62 && get_solid3(px, py, pz)) {
			set_empty3(px, py, pz);
			mask |= 1;
		} if (pz < 61 && get_solid3(px, py, pz+1)) {
			mask |= 2;
			set_empty3(px, py, pz+1);
		} if (pz > 0 && get_solid3(px, py, pz-1)) {
			set_empty3(px, py, pz-1);
			mask |= 4;
		}

		full = mask == 7;
		break;
	case 3: /* nade destroy */
		mask = grenade_rmblocks(px, py, pz);
		full = (mask & 0x7ffdfff) == 0x7ffdfff;
		break;
	}

	if (mask == 0 && cullPersonality == CULL_PERSONALITY_OPENSPADES)
		return 0;

	/* full here is 0x20000000 if true */
	return (type << 30) | ((uint32_t)full << 29) | mask;
}

static void block_action_cull(int px, int py, int pz, uint32_t mask)
{
	uint32_t type = mask >> 30;

	switch (type) {
	case 1: /* Destroy */
		cull3(px-1, py, pz);
		cull3(px+1, py, pz);
		cull3(px, py-1, pz);
		cull3(px, py+1, pz);
		cull3(px, py, pz-1);
		cull3(px, py, pz+1);
		break;
	case 2: /* 3x destroy */
		if (mask & 4 || cullPersonality == CULL_PERSONALITY_VOXLAP) {
			cull3(px-1, py, pz-1);
			cull3(px+1, py, pz-1);
			cull3(px, py-1, pz-1);
			cull3(px, py+1, pz-1);
			cull3(px, py, pz-2);
		}

		if (mask & 2 || cullPersonality == CULL_PERSONALITY_VOXLAP) {
			cull3(px-1, py, pz+1);
			cull3(px+1, py, pz+1);
			cull3(px, py-1, pz+1);
			cull3(px, py+1, pz+1);
			cull3(px, py, pz+2);
		}

		if (mask & 1 || cullPersonality == CULL_PERSONALITY_VOXLAP) {
			cull3(px-1, py, pz);
			cull3(px+1, py, pz);
			cull3(px, py-1, pz);
			cull3(px, py+1, pz);
		}

		break;
	case 3: /* Nade destroy */
		grenade_cullblocks(px, py, pz, mask);
		break;
	default:
		return;
	}
}

static void ref_block_action(int px, int py, int pz, unsigned type)
{
	switch (type) {
	case 0: /* Build */
		map_create(ref, px, py, pz);
		break;
	default: /* Any of the destroy family */
		block_action_cull(px, py, pz, block_action_rm(px, py, pz, type));
		map_cull_end(refcull);
		break;
	}
}

/* --- the comparison ------------------------------------------------------ */

static bc_map *mine;
static bc_cull *mycull;
static uint32_t cellbuf[4096];

static int same(void)
{
	return memcmp(mine->col, ref->solidbuf, sizeof mine->col) == 0;
}

static int popcount64(uint64_t v)
{
	int n = 0;

	for (; v; v &= v - 1)
		n++;
	return n;
}

/* One action on both. Before the reference moves, the engine's report of
 * what changed is checked against the difference between the two maps. */
static long collapsed_total;

static void both(int x, int y, int z, int type)
{
	bc_map_change chg;
	int ret, diff = 0, inbox = 1, listed = 1, i;
	long xy;

	bc_map_change_init(&chg, cellbuf, 4096);
	ret = bc_map_apply(mine, mycull, type, x, y, z, &chg);
	for (xy = 0; xy < BC_MAP_XY; xy++) {
		uint64_t d = mine->col[xy] ^ ref->solidbuf[xy];

		if (!d)
			continue;
		diff += popcount64(d);
		for (; d; d &= d - 1) {
			int vz = bc_ctz64(d), vx = (int)(xy % BC_MAP_X), vy = (int)(xy / BC_MAP_X);

			if (vx < chg.x0 || vx > chg.x1 || vy < chg.y0 || vy > chg.y1 ||
			    vz < chg.z0 || vz > chg.z1)
				inbox = 0;
		}
	}
	for (i = 0; i < chg.n; i++) {
		int vx = (int)(chg.cells[i] & 511u), vy = (int)((chg.cells[i] >> 9) & 511u);
		int vz = (int)((chg.cells[i] >> 18) & 63u);

		/* every listed voxel really differs from the map before */
		if (!(((mine->col[vy * BC_MAP_X + vx] ^ ref->solidbuf[vy * BC_MAP_X + vx]) >> vz) & 1))
			listed = 0;
	}
	CHECK(ret == diff);
	CHECK(chg.direct + chg.collapsed == diff);
	CHECK(inbox);
	CHECK(listed);
	CHECK(chg.n == (diff < 4096 ? diff : 4096));
	collapsed_total += chg.collapsed;

	ref_block_action(x, y, z, (unsigned)type);
	CHECK(same());
}

static void set_both(int x, int y, int z, int solid)
{
	bc_map_set(mine, x, y, z, solid);
	if (solid)
		map_create(ref, x, y, z);
	else
		map_destroy(ref, x, y, z);
}

static void flat_both(void)
{
	long xy;

	bc_map_fill_flat(mine, 62);
	mine->cull_personality = (uint8_t)cullPersonality;      /* a fill resets it */
	for (xy = 0; xy < BC_MAP_XY; xy++)
		ref->solidbuf[xy] = mine->col[xy];
}

static void box_both(int x0, int y0, int z0, int x1, int y1, int z1)
{
	int x, y, z;

	for (z = z0; z <= z1; z++)
		for (y = y0; y <= y1; y++)
			for (x = x0; x <= x1; x++)
				set_both(x, y, z, 1);
}

static int count_box(int x0, int y0, int z0, int x1, int y1, int z1)
{
	int x, y, z, n = 0;

	for (z = z0; z <= z1; z++)
		for (y = y0; y <= y1; y++)
			for (x = x0; x <= x1; x++)
				n += bc_map_solid(mine, x, y, z);
	return n;
}

/* Structures built to fall, each with what must be left written down. */
static void synthetic(int personality)
{
	cullPersonality = personality;

	/* a tower: a pole with a platform on it. Cut the pole. */
	flat_both();
	box_both(100, 100, 40, 100, 100, 61);
	box_both(98, 98, 39, 102, 102, 39);
	CHECK(count_box(90, 90, 30, 110, 110, 61) == 22 + 25);
	both(100, 100, 55, BC_BLOCK_DESTROY);
	CHECK(count_box(90, 90, 30, 110, 110, 61) == 6);        /* the stump: 56..61 */

	/* a bridge between two towers: cut one end, it hangs; cut the other,
	 * it falls and the towers stay */
	flat_both();
	box_both(100, 100, 40, 100, 100, 61);
	box_both(120, 100, 40, 120, 100, 61);
	box_both(101, 100, 40, 119, 100, 40);
	both(101, 100, 40, BC_BLOCK_DESTROY);
	CHECK(count_box(101, 100, 40, 119, 100, 40) == 18);
	both(119, 100, 40, BC_BLOCK_DESTROY);
	CHECK(count_box(101, 100, 40, 119, 100, 40) == 0);
	CHECK(count_box(100, 100, 40, 100, 100, 61) == 22);
	CHECK(count_box(120, 100, 40, 120, 100, 61) == 22);

	/* an overhang: a slab out from a wall. Spade the root: the spade
	 * takes three voxels of the wall, the slab hung on the middle one */
	flat_both();
	box_both(100, 100, 30, 100, 110, 61);
	box_both(101, 105, 45, 108, 105, 45);
	both(101, 105, 45, BC_BLOCK_SPADE);
	CHECK(count_box(101, 105, 45, 108, 105, 45) == 0);
	CHECK(count_box(100, 100, 30, 100, 110, 61) == 11 * 32);

	/* a mass hanging by one voxel from a ceiling */
	flat_both();
	box_both(100, 100, 20, 100, 100, 61);           /* pole */
	box_both(100, 100, 20, 110, 110, 20);           /* ceiling */
	set_both(105, 105, 21, 1);                      /* the thread */
	box_both(103, 103, 22, 107, 107, 26);           /* the mass */
	both(105, 105, 21, BC_BLOCK_DESTROY);
	CHECK(count_box(103, 103, 22, 107, 107, 26) == 0);
	CHECK(count_box(100, 100, 20, 110, 110, 20) == 121);

	/* contact by an edge or a corner holds nothing: a cube touching a
	 * pole's top only diagonally is not attached once its one face-
	 * neighbour goes */
	flat_both();
	box_both(100, 100, 40, 100, 100, 61);           /* pole, top at 40 */
	set_both(101, 100, 40, 1);                      /* the face link */
	box_both(101, 101, 38, 103, 103, 39);           /* cube: touches (101,100,40) by edge */
	set_both(101, 100, 39, 1);                      /* face link up to the cube's row */
	set_both(101, 101, 39, 1);
	both(101, 100, 39, BC_BLOCK_DESTROY);
	/* (101,100,40) still hangs on the pole; the cube touched it and the
	 * pole only along edges */
	CHECK(bc_map_solid(mine, 101, 100, 40));
	CHECK(count_box(101, 101, 38, 103, 103, 39) == 0);

	/* a grenade under a floating island's only leg */
	flat_both();
	box_both(100, 100, 50, 100, 100, 61);
	box_both(96, 96, 47, 104, 104, 49);
	both(100, 100, 55, BC_BLOCK_GRENADE);
	CHECK(count_box(96, 96, 47, 104, 104, 49) == 0);

	/* the personalities part ways on actions that remove nothing: an
	 * island already floating (set by hand, so nobody culled it), and a
	 * destroy of the air beside it */
	flat_both();
	box_both(100, 100, 30, 104, 104, 32);
	both(105, 102, 31, BC_BLOCK_DESTROY);
	CHECK(count_box(100, 100, 30, 104, 104, 32) ==
	      (personality == BC_CULL_VOXLAP ? 0 : 75));
	flat_both();
	box_both(100, 100, 30, 104, 104, 32);
	both(102, 102, 28, BC_BLOCK_GRENADE);           /* air, a voxel above it */
	CHECK(count_box(100, 100, 30, 104, 104, 32) ==
	      (personality == BC_CULL_VOXLAP ? 0 : 75));
	flat_both();
	box_both(100, 100, 30, 104, 104, 32);
	both(102, 105, 31, BC_BLOCK_SPADE);
	CHECK(count_box(100, 100, 30, 104, 104, 32) ==
	      (personality == BC_CULL_VOXLAP ? 0 : 75));

	/* the ground itself is never culled, nor dug by spade or grenade */
	flat_both();
	both(200, 200, 62, BC_BLOCK_SPADE);
	both(200, 200, 62, BC_BLOCK_GRENADE);
	CHECK(bc_map_solid(mine, 200, 200, 62) && bc_map_solid(mine, 200, 200, 63));
	/* the edges of the map */
	both(0, 0, 61, BC_BLOCK_GRENADE);
	both(511, 511, 61, BC_BLOCK_GRENADE);
	both(0, 511, 0, BC_BLOCK_SPADE);
	both(511, 0, 61, BC_BLOCK_DESTROY);
}

/* Random actions where there is something to hit. */
static void random_actions(bc_rng *rng, int n, int personality)
{
	int i;

	CHECK(mine->cull_personality == personality && cullPersonality == personality);
	for (i = 0; i < n; i++) {
		int x = (int)bc_rng_below(rng, BC_MAP_X), y = (int)bc_rng_below(rng, BC_MAP_Y);
		uint64_t c = mine->col[y * BC_MAP_X + x];
		int top, z, type, tries;
		uint32_t r = bc_rng_below(rng, 100);

		/* half the time, look for a column with something over a gap --
		 * a roof, a branch, a bridge deck -- which is where a hit can
		 * cut something loose */
		for (tries = 0; tries < 60 && (i & 1); tries++) {
			int t0 = bc_ctz64(c);

			if (t0 < 62 && t0 + bc_ctz64(~(c >> t0)) < 62)
				break;
			x = (int)bc_rng_below(rng, BC_MAP_X);
			y = (int)bc_rng_below(rng, BC_MAP_Y);
			c = mine->col[y * BC_MAP_X + x];
		}
		top = bc_ctz64(c);

		/* mostly at the surface and just under or over it, where trees,
		 * roofs and bridges are; sometimes anywhere */
		if (bc_rng_below(rng, 10) < 8)
			z = top + (int)bc_rng_below(rng, 7) - 2;
		else
			z = (int)bc_rng_below(rng, 64);
		if (z < 0) z = 0;
		if (z > 63) z = 63;
		type = r < 45 ? BC_BLOCK_DESTROY : r < 70 ? BC_BLOCK_SPADE :
		       r < 95 ? BC_BLOCK_GRENADE : BC_BLOCK_BUILD;
		if (type == BC_BLOCK_BUILD && z >= 62)
			z = 61;
		both(x, y, z, type);
		/* and often again next to it: that is how things get cut loose */
		if (bc_rng_below(rng, 3) == 0 && x > 2 && x < 509 && y > 2 && y < 509) {
			both(x + 1, y, z, BC_BLOCK_GRENADE);
			both(x, y + 2, z, BC_BLOCK_SPADE);
			i += 2;
		}
	}
}

/* A town of thin things to knock down, for when there are no real maps. */
static void random_town(bc_rng *rng)
{
	int i;

	flat_both();
	for (i = 0; i < 4000; i++) {
		int x = 8 + (int)bc_rng_below(rng, 490), y = 8 + (int)bc_rng_below(rng, 490);
		int h = 3 + (int)bc_rng_below(rng, 25), k;

		box_both(x, y, 62 - h, x, y, 61);
		k = (int)bc_rng_below(rng, 4);
		if (k == 0)
			box_both(x, y, 62 - h, x + 6, y, 62 - h);
		else if (k == 1)
			box_both(x - 2, y - 2, 62 - h, x + 2, y + 2, 62 - h);
		else if (k == 2)
			box_both(x, y, 62 - h, x, y + 5, 62 - h + 1);
	}
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

int main(void)
{
	const char *dir = getenv("BC_TEST_MAPS");
	bc_rng rng;
	int p, before;

	mine = malloc(sizeof *mine);
	mycull = malloc(sizeof *mycull);
	bc_cull_init(mycull);
	if (!mine || !mycull || map_alloc(&ref) != 0 || map_cull_alloc(&refcull) != 0) {
		printf("out of memory\n");
		return 1;
	}
	bc_rng_seed(&rng, 0xC0FFEE, 7);

	for (p = 0; p < 2; p++) {
		before = checks;
		collapsed_total = 0;
		synthetic(p);
		printf("  synthetic structures, %s: %d checks, %ld voxels collapsed\n",
		       p == BC_CULL_VOXLAP ? "voxlap" : "openspades", checks - before, collapsed_total);
		before = checks;
		collapsed_total = 0;
		cullPersonality = p;
		random_town(&rng);
		CHECK(same());
		random_actions(&rng, 3000, p);
		printf("  random town, %s: 3000 actions, %d checks, %ld voxels collapsed\n",
		       p == BC_CULL_VOXLAP ? "voxlap" : "openspades", checks - before, collapsed_total);
	}

	if (!dir) {
		printf("  real maps: skipped (set BC_TEST_MAPS to a directory of .vxl files)\n");
	} else {
		DIR *d = opendir(dir);
		struct dirent *de;
		int maps = 0;

		while (d && (de = readdir(d)) != NULL && maps < 3) {
			size_t n = strlen(de->d_name), len = 0;
			char path[1024];
			unsigned char *bytes;

			if (n < 5 || strcmp(de->d_name + n - 4, ".vxl") != 0)
				continue;
			snprintf(path, sizeof path, "%s/%s", dir, de->d_name);
			bytes = slurp(path, &len);
			if (!bytes)
				continue;
			maps++;
			for (p = 0; p < 2; p++) {
				int ok_mine = bc_map_load_vxl(mine, bytes, len);
				int ok_ref = vxl_read(ref, bytes, len);

				cullPersonality = p;
				mine->cull_personality = (uint8_t)p;            /* so does a load */

				before = checks;
				collapsed_total = 0;
				/* the loader, against libpvx2's */
				CHECK(ok_mine == 1 && ok_ref == 1);
				CHECK(same());
				random_actions(&rng, 3000, p);
				printf("  %s, %s: loader identical, 3000 actions, %d checks, "
				       "%ld voxels collapsed\n", de->d_name,
				       p == BC_CULL_VOXLAP ? "voxlap" : "openspades", checks - before,
				       collapsed_total);
			}
			free(bytes);
		}
		if (d)
			closedir(d);
	}

	printf("cull parity: RAN against lsd/src/libpvx2 (cull.c, read.c, map.c compiled in)\n");
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}

#endif /* HAVE_PVX2 */
