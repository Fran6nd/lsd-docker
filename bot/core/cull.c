/* cull.c -- Removing what a destroy left floating. See cull.h.
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * A port of lsd/src/libpvx2/src/cull.c. The shape of the original is kept
 * (same arrays, same order of visits, same early exits) so that a reader
 * can hold the two side by side; only the compiler builtins are replaced.
 */
#include "cull.h"

#include <string.h>

#define Z_GROUND_BIT ((uint64_t)1 << (BC_MAP_Z - 2))
#define Z_BOTTOM_BITS ((uint64_t)3 << (BC_MAP_Z - 2))

static int clz64(uint64_t v)
{
	int n = 0;
	if (v == 0)
		return 64;
	if (!(v >> 32)) { n += 32; v <<= 32; }
	if (!(v >> 48)) { n += 16; v <<= 16; }
	if (!(v >> 56)) { n += 8; v <<= 8; }
	if (!(v >> 60)) { n += 4; v <<= 4; }
	if (!(v >> 62)) { n += 2; v <<= 2; }
	if (!(v >> 63)) { n += 1; }
	return n;
}

static int popcount64(uint64_t v)
{
	int n = 0;

	for (; v; v &= v - 1)
		n++;
	return n;
}

static uint64_t low_bits(int len)
{
	return len >= 64 ? ~(uint64_t)0 : (((uint64_t)1 << len) - 1);
}

/* The run of solid voxels that contains z (which must be solid). */
static uint64_t isolate_col(uint64_t col, int z)
{
	int bits_le_z = clz64(~(col << ((BC_MAP_Z - 1) - z)));
	int bits_ge_z = bc_ctz64(~(col >> z));
	int bits_lt_z = bits_le_z - 1;
	int top = z - bits_lt_z;
	int len = bits_lt_z + bits_ge_z;

	return low_bits(len) << top;
}

/* Every run of `test` that has a voxel in `adjacent`. */
static uint64_t isolate_neighbors(uint64_t adjacent, uint64_t test)
{
	uint64_t checked = 0;

	for (;;) {
		int next = bc_ctz64(adjacent);

		if (next == BC_MAP_Z)
			break;
		checked |= isolate_col(test, next);
		adjacent &= ~checked;
	}
	return checked;
}

void bc_cull_init(bc_cull *c)
{
	memset(c, 0, sizeof *c);
}

void bc_cull_end(bc_cull *c)
{
	int32_t p = c->grnd_ptr;

	while (p-- > 0)
		c->grounded[c->grounded_xy[p]] = 0;
	c->grnd_ptr = 0;
}

static int unwind_floating(bc_map *m, bc_cull *c, int32_t trvr_ptr, bc_map_change *chg)
{
	int removed = 0;

	while (trvr_ptr-- > 0) {
		int32_t xy = c->traversed_xy[trvr_ptr];
		uint64_t gone = m->col[xy] & c->traversed[xy];
		uint64_t g;

		for (g = gone; g; g &= g - 1) {
			removed++;
			if (chg)
				bc_map_change_add(chg, xy % BC_MAP_X, xy / BC_MAP_X, bc_ctz64(g),
				                  BC_CELL_COLLAPSED);
		}
		m->col[xy] &= ~c->traversed[xy];
		c->traversed[xy] = 0;
	}
	if (removed)
		m->rev++;
	return removed;
}

static void unwind_grounded(bc_cull *c, int32_t base, int32_t trvr_ptr)
{
	while (trvr_ptr-- > base) {
		int32_t xy = c->traversed_xy[trvr_ptr];

		c->visiting[xy / 8] = 0;
		c->grounded[xy] |= c->traversed[xy];
		c->traversed[xy] = 0;
	}
}

/* Look at the column next door from a column whose traversed runs are
 * `col`. 1: the mass is grounded, stop everything. */
static int visitf(bc_cull *c, const bc_map *m, uint64_t col, int32_t xy,
                  int32_t *tovi_ptr, int32_t *trvr_ptr, int32_t *grnd_ptr)
{
	uint64_t travr = c->traversed[xy];
	uint64_t grnd = c->grounded[xy];
	uint64_t solid = m->col[xy];
	uint64_t untravr = solid & ~travr;
	uint64_t untravr_adjacent = untravr & col;
	uint64_t new_travr;

	if (!untravr_adjacent)
		return 0;
	if (col & grnd)
		return 1;

	new_travr = travr | isolate_neighbors(untravr_adjacent, solid);
	c->traversed[xy] = new_travr;

	if (travr == 0) {
		c->traversed_xy[(*trvr_ptr)++] = xy;
		if (grnd == 0)
			c->grounded_xy[(*grnd_ptr)++] = xy;
	}

	if (new_travr & Z_GROUND_BIT)
		return 1;

	if (c->visiting[xy / 8] & (1 << (xy & 7)))
		return 0;

	c->visiting[xy / 8] |= (uint8_t)(1 << (xy & 7));
	c->to_visit_xy[(*tovi_ptr)++] = xy;
	return 0;
}

/* The flood from a solid voxel (in the map), its runs noted in
 * traversed[] at traversed_xy[*trvr_ptr] on. 1: it reached the ground (what
 * it walked is unwound into grounded[], *trvr_ptr back where it was); 0:
 * the mass floats, and is left in traversed[] (*trvr_ptr past it). */
static int flood(const bc_map *m, bc_cull *c, int x, int y, int z, int32_t *trvr_ptr)
{
	int32_t base = *trvr_ptr;
	int32_t grnd_ptr = c->grnd_ptr;
	int32_t tovi_ptr = 0;
	int32_t xy = y * BC_MAP_X + x;
	uint64_t col = isolate_col(m->col[xy], z);

	c->traversed[xy] = col;
	c->traversed_xy[(*trvr_ptr)++] = xy;
	if (c->grounded[xy] == 0)
		c->grounded_xy[grnd_ptr++] = xy;
	if (col & Z_BOTTOM_BITS)
		goto grounded;

	for (;;) {
		if (xy % BC_MAP_X > 0 &&
		    visitf(c, m, col, xy - 1, &tovi_ptr, trvr_ptr, &grnd_ptr))
			goto grounded;
		if (xy % BC_MAP_X < BC_MAP_X - 1 &&
		    visitf(c, m, col, xy + 1, &tovi_ptr, trvr_ptr, &grnd_ptr))
			goto grounded;
		if (xy >= BC_MAP_X &&
		    visitf(c, m, col, xy - BC_MAP_X, &tovi_ptr, trvr_ptr, &grnd_ptr))
			goto grounded;
		if (xy < BC_MAP_XY - BC_MAP_X &&
		    visitf(c, m, col, xy + BC_MAP_X, &tovi_ptr, trvr_ptr, &grnd_ptr))
			goto grounded;

		if (tovi_ptr == 0)
			break;

		xy = c->to_visit_xy[--tovi_ptr];
		col = c->traversed[xy];
		c->visiting[xy / 8] &= (uint8_t)~(1 << (xy & 7));
	}
	return 0;

grounded:
	c->grnd_ptr = grnd_ptr;
	unwind_grounded(c, base, *trvr_ptr);
	*trvr_ptr = base;
	return 1;
}

int bc_cull_voxel(bc_map *m, bc_cull *c, int x, int y, int z, bc_map_change *chg)
{
	int32_t trvr_ptr = 0;

	if (!bc_map_in(x, y, z) || !(m->col[y * BC_MAP_X + x] & ((uint64_t)1 << z)))
		return 0;
	if (flood(m, c, x, y, z, &trvr_ptr))
		return 0;
	return unwind_floating(m, c, trvr_ptr, chg);
}

int bc_cull_would_drop(bc_map *m, bc_cull *c, int x, int y, int z, int also_x, int also_y, int also_z)
{
	static const int8_t d[6][3] = { {1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1} };
	int32_t trvr_ptr = 0, p;
	int cut[2][3], n_cut = 0, k, i, dropped = 0;

	cut[0][0] = x; cut[0][1] = y; cut[0][2] = z;
	cut[1][0] = also_x; cut[1][1] = also_y; cut[1][2] = also_z;
	/* the cut: taken out of the map, put back at the end */
	for (k = 0; k < 2; k++) {
		if (!bc_map_in(cut[k][0], cut[k][1], cut[k][2]) || cut[k][2] >= BC_MAP_GROUND_Z ||
		    !(m->col[cut[k][1] * BC_MAP_X + cut[k][0]] & ((uint64_t)1 << cut[k][2]))) {
			if (k == 0) return 0;
			break;
		}
		m->col[cut[k][1] * BC_MAP_X + cut[k][0]] &= ~((uint64_t)1 << cut[k][2]);
		n_cut++;
	}
	/* each neighbour's mass, as the server floods it; one that floats is
	 * counted, and taken out too until the end, so that a mass touching
	 * two neighbours is counted once and a later flood does not walk it */
	for (k = 0; k < n_cut; k++)
		for (i = 0; i < 6; i++) {
			int nx = cut[k][0] + d[i][0], ny = cut[k][1] + d[i][1], nz = cut[k][2] + d[i][2];
			int32_t from = trvr_ptr;

			if (!bc_map_in(nx, ny, nz) || !(m->col[ny * BC_MAP_X + nx] & ((uint64_t)1 << nz)))
				continue;
			if (flood(m, c, nx, ny, nz, &trvr_ptr))
				continue;
			for (p = from; p < trvr_ptr; p++) {
				int32_t xy = c->traversed_xy[p];

				dropped += popcount64(m->col[xy] & c->traversed[xy]);
				m->col[xy] &= ~c->traversed[xy];
			}
		}
	/* all back as it was: the masses, the cut, and nothing proven */
	while (trvr_ptr-- > 0) {
		int32_t xy = c->traversed_xy[trvr_ptr];

		m->col[xy] |= c->traversed[xy];
		c->traversed[xy] = 0;
	}
	for (k = 0; k < n_cut; k++)
		m->col[cut[k][1] * BC_MAP_X + cut[k][0]] |= (uint64_t)1 << cut[k][2];
	bc_cull_end(c);
	return dropped;
}
