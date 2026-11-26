/* kv6.h -- Voxel models (KV6, the game's model format), read from bytes
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * A KV6 file: "Kvxl"; a header (xsiz, ysiz, zsiz: uint32; xpivot, ypivot,
 * zpivot: float; blklen: uint32); blklen blocks (colour uint32 -- bytes
 * B, G, R, then 128 by custom --, z uint16, visible faces uint8, lighting
 * uint8); xoffset uint32[xsiz]; xyoffset uint16[xsiz * ysiz] (the blocks
 * of each column, x major, z rising within it). All little-endian. z
 * grows DOWN, as the map's does: zsiz - 1 is the model's bottom layer.
 * A file may leave out the voxels no face of which shows (a closed
 * inside): they are filled again here, as the game's loader does
 * (zerospades VoxelModel::HollowFill) -- what no air from outside the
 * volume reaches is solid.
 *
 * No I/O: the host reads the file (botd: the built-in structures/, then
 * the operator's) and hands the bytes over. Allocated once, at load. */
#ifndef BC_KV6_H
#define BC_KV6_H

#include <stddef.h>
#include <stdint.h>

enum { BC_KV6_SIDE_MAX = 64 };      /* a structure, not a map: 64 a side at most */

typedef struct bc_kv6_voxel {
	int16_t x, y, z;            /* in the model's volume; z down */
	int16_t pad_;
	uint32_t rgb;               /* 0x00RRGGBB */
} bc_kv6_voxel;

typedef struct bc_kv6 {
	int xs, ys, zs;
	float px, py, pz;           /* the pivot, in voxels */
	int n;
	bc_kv6_voxel *v;            /* every solid voxel (the inside filled), z
	                               falling (the bottom layer first), then y, x */
} bc_kv6;

/* 1, or 0 with the fault in err (and nothing kept) */
int bc_kv6_parse(const uint8_t *bytes, size_t n, bc_kv6 *out, char *err, size_t err_size);
void bc_kv6_free(bc_kv6 *m);

#endif
