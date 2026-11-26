/* kv6.c -- Voxel models (KV6), read from bytes. See kv6.h.
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * Read as the game reads it (zerospades VoxelModel::LoadKV6), and no
 * looser: a file the game would refuse is refused here, with the reason.
 * Every number is read a byte at a time, little-endian, so neither the
 * host's byte order nor the alignment of the bytes it hands over matters.
 *
 * Two things the game does not look at are not looked at here either:
 * xoffset (the blocks of each x slice; the columns' own counts in
 * xyoffset say the same and are what the blocks are walked by), and
 * whatever follows xyoffset (SLAB6 appends its palette, "SPal" and 768
 * bytes, to the files it saves).
 *
 * THE CLOSED INSIDE. A file lists the voxels that show; the game fills
 * in what no air from outside the volume reaches (HollowFill). Here too:
 * air is flooded through faces from every air cell on the volume's six
 * sides, and what is left is solid. Its colour is that of the first
 * listed voxel above it in its own column (z falling). One is always
 * there: the cells above an unreached one are unreached air or solid --
 * reached air above it would have flooded down into it -- and the top
 * layer's air is reached by construction, so going up one meets a
 * listed voxel before leaving the volume. The game paints the inside a
 * fixed colour instead, never seen; a bot building it has to choose a
 * block colour, and the roof's is the one a player would guess. */
#include "kv6.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* "Kvxl", then xsiz ysiz zsiz, xpivot ypivot zpivot, blklen: 4 bytes each */
enum { HEAD_BYTES = 4 + 7 * 4 };
/* a block: colour (4), z (2), visible faces (1), lighting (1) */
enum { BLOCK_BYTES = 8 };

/* the cells of the volume while it is read */
enum { CELL_AIR, CELL_SOLID, CELL_OUTSIDE };

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint16_t le16(const uint8_t *p)
{
	return (uint16_t)(p[0] | p[1] << 8);
}

static float lef(const uint8_t *p)
{
	uint32_t u = le32(p);
	float f;

	memcpy(&f, &u, sizeof f);
	return f;
}

static int fail(char *err, size_t err_size, const char *why)
{
	if (err && err_size) snprintf(err, err_size, "%s", why);
	return 0;
}

/* Air from outside: every air cell on a side of the volume, then through
 * faces. `stack` holds a cell index each, as many as there are cells. */
static void flood_outside(uint8_t *cell, int32_t *stack, int xs, int ys, int zs)
{
	int top = 0, x, y, z;

#define AT(x, y, z) ((x) + xs * ((y) + ys * (z)))
#define SEED(x, y, z) do { int32_t i_ = AT(x, y, z); \
		if (cell[i_] == CELL_AIR) { cell[i_] = CELL_OUTSIDE; stack[top++] = i_; } } while (0)
	for (z = 0; z < zs; z++)
		for (y = 0; y < ys; y++)
			for (x = 0; x < xs; x++)
				if (x == 0 || x == xs - 1 || y == 0 || y == ys - 1 || z == 0 || z == zs - 1)
					SEED(x, y, z);
	while (top > 0) {
		int32_t i = stack[--top];

		x = i % xs;
		y = i / xs % ys;
		z = i / xs / ys;
		if (x > 0) SEED(x - 1, y, z);
		if (x < xs - 1) SEED(x + 1, y, z);
		if (y > 0) SEED(x, y - 1, z);
		if (y < ys - 1) SEED(x, y + 1, z);
		if (z > 0) SEED(x, y, z - 1);
		if (z < zs - 1) SEED(x, y, z + 1);
	}
#undef SEED
#undef AT
}

int bc_kv6_parse(const uint8_t *bytes, size_t n, bc_kv6 *out, char *err, size_t err_size)
{
	uint32_t xs, ys, zs, blklen;
	size_t cells, need, blocks_at, xy_at, pos, c;
	uint8_t *cell = NULL;
	uint32_t *rgb = NULL;
	int32_t *stack = NULL;
	bc_kv6_voxel *v = NULL;
	float px, py, pz;
	int x, y, z, solid = 0, k;

	memset(out, 0, sizeof *out);
	if (n < HEAD_BYTES)
		return fail(err, err_size, "truncated: shorter than a KV6 header");
	if (memcmp(bytes, "Kvxl", 4))
		return fail(err, err_size, "not a KV6 file (no \"Kvxl\" at the start)");
	xs = le32(bytes + 4);
	ys = le32(bytes + 8);
	zs = le32(bytes + 12);
	px = lef(bytes + 16);
	py = lef(bytes + 20);
	pz = lef(bytes + 24);
	blklen = le32(bytes + 28);
	if (xs < 1 || xs > BC_KV6_SIDE_MAX || ys < 1 || ys > BC_KV6_SIDE_MAX || zs < 1 || zs > BC_KV6_SIDE_MAX) {
		if (err && err_size)
			snprintf(err, err_size, "size %ux%ux%u: each side 1 to %d", (unsigned)xs, (unsigned)ys,
			         (unsigned)zs, BC_KV6_SIDE_MAX);
		return 0;
	}
	if (!isfinite(px) || !isfinite(py) || !isfinite(pz))
		return fail(err, err_size, "the pivot is not a number");
	cells = (size_t)xs * ys * zs;
	/* no two blocks in one cell: more than the cells is a corrupt count,
	 * and refusing it here keeps the length below from overflowing */
	if (blklen > cells) {
		if (err && err_size)
			snprintf(err, err_size, "%u blocks in %zu cells", (unsigned)blklen, cells);
		return 0;
	}
	if (blklen == 0)
		return fail(err, err_size, "an empty model: no voxel listed");
	blocks_at = HEAD_BYTES;
	xy_at = blocks_at + (size_t)blklen * BLOCK_BYTES + (size_t)xs * 4;
	need = xy_at + (size_t)xs * ys * 2;
	if (n < need) {
		if (err && err_size)
			snprintf(err, err_size, "truncated: %zu bytes, %zu needed", n, need);
		return 0;
	}
	{
		uint32_t sum = 0;

		for (c = 0; c < (size_t)xs * ys; c++)
			sum += le16(bytes + xy_at + 2 * c);     /* at most 64*64*65535: no overflow */
		if (sum != blklen) {
			if (err && err_size)
				snprintf(err, err_size, "the columns hold %u blocks, the header says %u", (unsigned)sum,
				         (unsigned)blklen);
			return 0;
		}
	}

	cell = calloc(cells, 1);
	rgb = calloc(cells, sizeof *rgb);
	stack = malloc(cells * sizeof *stack);
	if (!cell || !rgb || !stack) {
		fail(err, err_size, "no memory");
		goto out;
	}

	/* the listed voxels, column by column (x major), z rising in each */
	pos = 0;
	for (x = 0; x < (int)xs; x++)
		for (y = 0; y < (int)ys; y++) {
			int span = le16(bytes + xy_at + 2 * ((size_t)x * ys + (size_t)y)), last = -1;

			for (; span > 0; span--, pos++) {
				const uint8_t *b = bytes + blocks_at + pos * BLOCK_BYTES;
				int bz = le16(b + 4);
				size_t i;

				if (bz >= (int)zs) {
					if (err && err_size)
						snprintf(err, err_size, "block %zu: z %d outside a model %u deep", pos, bz, (unsigned)zs);
					goto out;
				}
				if (bz <= last) {
					if (err && err_size)
						snprintf(err, err_size, "column (%d, %d): z %d after %d, not rising (a duplicate, or "
						         "not sorted)", x, y, bz, last);
					goto out;
				}
				last = bz;
				i = (size_t)x + xs * ((size_t)y + ys * (size_t)bz);
				cell[i] = CELL_SOLID;
				/* the bytes B, G, R (and a fourth, 128 by custom) */
				rgb[i] = (uint32_t)b[2] << 16 | (uint32_t)b[1] << 8 | b[0];
				solid++;
			}
		}

	/* THE CLOSED INSIDE (above) */
	flood_outside(cell, stack, (int)xs, (int)ys, (int)zs);
	for (z = 0; z < (int)zs; z++)
		for (y = 0; y < (int)ys; y++)
			for (x = 0; x < (int)xs; x++) {
				size_t i = (size_t)x + xs * ((size_t)y + ys * (size_t)z);

				if (cell[i] != CELL_AIR)
					continue;
				/* z rising: the cells above were already settled, so the
				 * one right above (z - 1; never off the top, whose air is
				 * all outside) holds the colour of the column's first
				 * listed voxel over this one */
				cell[i] = CELL_SOLID;
				rgb[i] = rgb[i - (size_t)xs * ys];
				solid++;
			}

	v = malloc((size_t)solid * sizeof *v);
	if (!v) {
		fail(err, err_size, "no memory");
		goto out;
	}
	k = 0;
	for (z = (int)zs - 1; z >= 0; z--)
		for (y = 0; y < (int)ys; y++)
			for (x = 0; x < (int)xs; x++) {
				size_t i = (size_t)x + xs * ((size_t)y + ys * (size_t)z);

				if (cell[i] != CELL_SOLID)
					continue;
				v[k].x = (int16_t)x;
				v[k].y = (int16_t)y;
				v[k].z = (int16_t)z;
				v[k].pad_ = 0;
				v[k].rgb = rgb[i];
				k++;
			}
	out->xs = (int)xs;
	out->ys = (int)ys;
	out->zs = (int)zs;
	out->px = px;
	out->py = py;
	out->pz = pz;
	out->n = solid;
	out->v = v;
out:
	free(cell);
	free(rgb);
	free(stack);
	return out->v != NULL;
}

void bc_kv6_free(bc_kv6 *m)
{
	free(m->v);
	memset(m, 0, sizeof *m);
}
