/* map.c -- The world as the server has it. See map.h.
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * The loader follows lsd/src/libpvx2/src/read.c; the block actions follow
 * lsd/src/main.c (block_action, block_action_rm, block_action_cull,
 * grenade_rmblocks, grenade_cullblocks, cull_grenade), case for case and
 * in the same order, because the order of the floods is part of the
 * result only in theory and it costs nothing to keep.
 */
#include "map.h"

#include <string.h>

#include "cull.h"
#include "lsd_core.h"

int bc_ctz64(uint64_t v)
{
	int n = 0;

	if (v == 0)
		return 64;
	if (!(v & 0xFFFFFFFFu)) { n += 32; v >>= 32; }
	if (!(v & 0xFFFFu)) { n += 16; v >>= 16; }
	if (!(v & 0xFFu)) { n += 8; v >>= 8; }
	if (!(v & 0xFu)) { n += 4; v >>= 4; }
	if (!(v & 0x3u)) { n += 2; v >>= 2; }
	if (!(v & 0x1u)) { n += 1; }
	return n;
}

void bc_map_clear(bc_map *m)
{
	memset(m->col, 0, sizeof m->col);
	m->rev = 1;
	m->cull_personality = BC_CULL_OPENSPADES;
	memset(m->pad_, 0, sizeof m->pad_);
	m->line_chg_ = NULL;
}

void bc_map_fill_flat(bc_map *m, int ground_z)
{
	uint64_t c;
	long i;

	if (ground_z < 0)
		ground_z = 0;
	if (ground_z > BC_MAP_Z - 1)
		ground_z = BC_MAP_Z - 1;
	c = ~(uint64_t)0 << ground_z;
	bc_map_clear(m);
	for (i = 0; i < BC_MAP_XY; i++)
		m->col[i] = c;
}

/* Bits z .. z+len-1. */
static uint64_t range_bits(int z, int len)
{
	uint64_t b;

	if (len <= 0 || z >= BC_MAP_Z)
		return 0;
	b = len >= 64 ? ~(uint64_t)0 : (((uint64_t)1 << len) - 1);
	return b << z;
}

/* The VXL format, a column at a time. Each column is a chain of spans:
 *
 *   byte 0  N: length of this span in 4-byte words, header included; 0 on
 *              the column's last span
 *   byte 1  S: first voxel of the span's coloured top run
 *   byte 2  E: last voxel of that run (E = S - 1: no run)
 *   byte 3  A: first voxel of the air above the run (unused on the first
 *              span: everything above S is air)
 *   then the top run's colours, 4 bytes each, and -- unless it is the last
 *   span -- the colours of a bottom run that ends where the NEXT span's
 *   air begins.
 *
 * Solid is everything from S down to the next span's A, the uncoloured
 * inside included; on the last span, everything from S to the bottom. */
int bc_map_load_vxl(bc_map *m, const uint8_t *data, size_t len)
{
	const uint8_t *p = data;
	const uint8_t *end = data + len;
	long xy;

	bc_map_clear(m);

	for (xy = 0; xy < BC_MAP_XY; xy++) {
		uint64_t col = 0;

		for (;;) {
			int n, s, e, top_len, bottom_len, next_air;

			if (end - p < 4)
				return 0;
			n = p[0];
			s = p[1];
			e = p[2];
			top_len = e - s + 1;
			if (e >= BC_MAP_Z || n > BC_MAP_Z + 1 || s > e + 1)
				return 0;

			if (n == 0) {
				/* last span: its colours, then solid to the bottom */
				if (end - p < 4 + 4 * (long)top_len)
					return 0;
				col |= range_bits(s, BC_MAP_Z - s);
				p += 4 + 4 * top_len;
				break;
			}

			bottom_len = (n - 1) - top_len;
			if (bottom_len < 0)
				return 0;
			/* the next span's header must be there to read its A */
			if (end - p < 4 * (long)n + 4)
				return 0;
			next_air = p[4 * n + 3];
			if (next_air > BC_MAP_Z || e + 1 > next_air - bottom_len)
				return 0;
			col |= range_bits(s, next_air - s);
			p += 4 * n;
		}
		m->col[xy] = col;
	}
	m->rev++;
	return 1;
}

void bc_map_set(bc_map *m, int x, int y, int z, int solid)
{
	uint64_t *c, bit;

	if (!bc_map_in(x, y, z))
		return;
	c = &m->col[y * BC_MAP_X + x];
	bit = (uint64_t)1 << z;
	if (solid ? !(*c & bit) : !!(*c & bit)) {
		*c ^= bit;
		m->rev++;
	}
}

int bc_map_floor_at_or_below(const bc_map *m, int x, int y, int z)
{
	uint64_t c = bc_map_col(m, x, y);

	if (z < 0)
		z = 0;
	if (z >= BC_MAP_Z)
		return BC_MAP_Z;
	return z + bc_ctz64(c >> z);
}

/* --- what changed ------------------------------------------------------ */

void bc_map_change_init(bc_map_change *c, uint32_t *cells, int32_t cap)
{
	memset(c, 0, sizeof *c);
	c->cells = cells;
	c->cap = cells ? cap : 0;
}

void bc_map_change_add(bc_map_change *c, int x, int y, int z, uint32_t flags)
{
	if (c->direct + c->collapsed == 0) {
		c->x0 = c->x1 = (int16_t)x;
		c->y0 = c->y1 = (int16_t)y;
		c->z0 = c->z1 = (int16_t)z;
	} else {
		if (x < c->x0) c->x0 = (int16_t)x;
		if (x > c->x1) c->x1 = (int16_t)x;
		if (y < c->y0) c->y0 = (int16_t)y;
		if (y > c->y1) c->y1 = (int16_t)y;
		if (z < c->z0) c->z0 = (int16_t)z;
		if (z > c->z1) c->z1 = (int16_t)z;
	}
	if (flags & BC_CELL_COLLAPSED)
		c->collapsed++;
	else
		c->direct++;
	if (c->n < c->cap)
		c->cells[c->n++] = ((uint32_t)x & 511u) | (((uint32_t)y & 511u) << 9) |
		                   (((uint32_t)z & 63u) << 18) | flags;
}

/* --- destroys --------------------------------------------------------- */

/* Everything below is lsd/src/main.c, function for function:
 *   take          set_empty after get_solid
 *   cull3         cull3 (the bounds are in bc_cull_voxel)
 *   cull_grenade  cull_grenade
 *   bc_map_apply  block_action -> block_action_rm, then block_action_cull,
 *                 then finish_cull
 * with `mask` the same bits the server keeps: which of the named voxels
 * were solid. */

typedef struct ctx {
	bc_map *m;
	bc_cull *c;
	bc_map_change *chg;
	int total;
} ctx;

static int take(ctx *k, int x, int y, int z)
{
	uint64_t *c, bit;

	if (!bc_map_in(x, y, z))
		return 0;
	c = &k->m->col[y * BC_MAP_X + x];
	bit = (uint64_t)1 << z;
	if (!(*c & bit))
		return 0;
	*c &= ~bit;
	k->total++;
	if (k->chg)
		bc_map_change_add(k->chg, x, y, z, 0);
	return 1;
}

static void cull3(ctx *k, int x, int y, int z)
{
	if (k->c)
		k->total += bc_cull_voxel(k->m, k->c, x, y, z, k->chg);
}

/* main.c cull_grenade: for a voxel at offset (ox, oy, oz) of the blast,
 * the voxels just outside the blast that touch it. */
static void cull_grenade(ctx *k, int x, int y, int z, int ox, int oy, int oz)
{
	if (ox != 0 && oy != 0 && oz != 0) {
		cull3(k, x + ox * 2, y + oy, z + oz);
		cull3(k, x + ox, y + oy * 2, z + oz);
		cull3(k, x + ox, y + oy, z + oz * 2);
		return;
	}
	if (ox != 0 && oy != 0) {
		cull3(k, x + ox * 2, y + oy, z);
		cull3(k, x + ox, y + oy * 2, z);
		return;
	}
	if (ox != 0 && oz != 0) {
		cull3(k, x + ox * 2, y, z + oz);
		cull3(k, x + ox, y, z + oz * 2);
		return;
	}
	if (oy != 0 && oz != 0) {
		cull3(k, x, y + oy * 2, z + oz);
		cull3(k, x, y + oy, z + oz * 2);
		return;
	}
	if (ox != 0) {
		cull3(k, x + ox * 2, y, z);
		return;
	}
	if (oy != 0) {
		cull3(k, x, y + oy * 2, z);
		return;
	}
	if (oz != 0) {
		cull3(k, x, y, z + oz * 2);
		return;
	}
}

int bc_map_apply(bc_map *m, bc_cull *c, int action, int x, int y, int z, bc_map_change *chg)
{
	int voxlap = m->cull_personality == BC_CULL_VOXLAP;
	uint32_t mask = 0, ctr;
	int ox, oy, oz;
	ctx k;

	k.m = m; k.c = c; k.chg = chg; k.total = 0;

	switch (action) {
	case BC_BLOCK_BUILD:
		if (!bc_map_in(x, y, z) || bc_map_solid(m, x, y, z))
			return 0;
		m->col[y * BC_MAP_X + x] |= (uint64_t)1 << z;
		m->rev++;
		if (chg)
			bc_map_change_add(chg, x, y, z, BC_CELL_BUILT);
		return 1;

	case BC_BLOCK_DESTROY:
		if (!bc_map_in(x, y, z))
			return 0;
		if (take(&k, x, y, z))
			mask = 1;
		if (mask == 0 && !voxlap)
			return 0;
		cull3(&k, x - 1, y, z);
		cull3(&k, x + 1, y, z);
		cull3(&k, x, y - 1, z);
		cull3(&k, x, y + 1, z);
		cull3(&k, x, y, z - 1);
		cull3(&k, x, y, z + 1);
		break;

	case BC_BLOCK_SPADE:
		if (z < 62 && take(&k, x, y, z))
			mask |= 1;
		if (z < 61 && take(&k, x, y, z + 1))
			mask |= 2;
		if (z > 0 && take(&k, x, y, z - 1))
			mask |= 4;
		if (mask == 0 && !voxlap)
			return 0;
		if ((mask & 4) || voxlap) {
			cull3(&k, x - 1, y, z - 1);
			cull3(&k, x + 1, y, z - 1);
			cull3(&k, x, y - 1, z - 1);
			cull3(&k, x, y + 1, z - 1);
			cull3(&k, x, y, z - 2);
		}
		if ((mask & 2) || voxlap) {
			cull3(&k, x - 1, y, z + 1);
			cull3(&k, x + 1, y, z + 1);
			cull3(&k, x, y - 1, z + 1);
			cull3(&k, x, y + 1, z + 1);
			cull3(&k, x, y, z + 2);
		}
		if ((mask & 1) || voxlap) {
			cull3(&k, x - 1, y, z);
			cull3(&k, x + 1, y, z);
			cull3(&k, x, y - 1, z);
			cull3(&k, x, y + 1, z);
		}
		break;

	case BC_BLOCK_GRENADE:
		ctr = 1;
		for (oz = -1; oz <= 1; oz++)
			for (oy = -1; oy <= 1; oy++)
				for (ox = -1; ox <= 1; ox++) {
					/* the server's bounds: nothing at z >= 62 */
					if (z + oz < BC_MAP_GROUND_Z && take(&k, x + ox, y + oy, z + oz))
						mask |= ctr;
					ctr <<= 1;
				}
		if (mask == 0 && !voxlap)
			return 0;
		ctr = 1;
		for (oz = -1; oz <= 1; oz++)
			for (oy = -1; oy <= 1; oy++)
				for (ox = -1; ox <= 1; ox++) {
					if ((mask & ctr) || voxlap)
						cull_grenade(&k, x, y, z, ox, oy, oz);
					ctr <<= 1;
				}
		break;

	default:
		return 0;
	}

	if (c)
		bc_cull_end(c);
	if (k.total)
		m->rev++;
	return k.total;
}

int bc_map_line(bc_map *m, int x1, int y1, int z1, int x2, int y2, int z2, bc_map_change *chg)
{
	return bc_lsd_block_line(m, x1, y1, z1, x2, y2, z2, chg);
}
