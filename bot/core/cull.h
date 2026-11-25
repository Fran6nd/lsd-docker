/* cull.h -- Removing what a destroy left floating
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * WHAT. After a voxel is destroyed the server looks at each neighbour it
 * had: if the solid mass that neighbour belongs to no longer touches the
 * ground (a voxel at z >= 62), the whole mass is removed. Nobody is told
 * which voxels went -- every client is expected to run the same flood. So
 * does the engine, or its map would keep bridges and tree tops the server
 * no longer has, and plan routes across them.
 *
 * This is libpvx2's map_cull (lsd/src/libpvx2/src/cull.c), ported
 * statement for statement into plain C11 (the original needs GCC 14's
 * __builtin_clzg and assume attributes). aosbot's Cull.cpp was the
 * client-side twin of the same idea; the server's is the one copied here
 * because it is the one that decides.
 *
 * HOW. Connectivity is by faces. The flood walks COLUMN RUNS, not voxels:
 * a run is a stretch of consecutive solid voxels in one column, found with
 * two bit scans, and two runs in neighbouring columns touch when their
 * words overlap. A hillside is a few hundred runs where it is a hundred
 * thousand voxels. It stops the moment it meets z = 62 -- almost at once
 * on ordinary ground, where the first run goes all the way down.
 *
 * One action culls several neighbours; what one flood proved grounded is
 * kept (`grounded`) so the next stops on touching it, and forgotten at
 * bc_cull_end -- the map has changed by the next action.
 *
 * MEMORY. bc_cull is the scratch: 7.1 MiB, the caller's, one per map (not
 * per bot). It holds nothing between actions; zero it once.
 */
#ifndef BC_CULL_H
#define BC_CULL_H

#include "map.h"

typedef struct bc_cull {
	int32_t grnd_ptr;
	uint64_t traversed[BC_MAP_XY];
	uint64_t grounded[BC_MAP_XY];
	int32_t traversed_xy[BC_MAP_XY];
	int32_t grounded_xy[BC_MAP_XY];
	int32_t to_visit_xy[BC_MAP_XY];
	uint8_t visiting[BC_MAP_XY / 8];
} bc_cull;

/* Zero the scratch. Once, after allocating it. */
void bc_cull_init(bc_cull *c);

/* If the voxel is solid and its mass does not reach the ground, remove the
 * mass. Returns the number of voxels removed (0: grounded, or not solid, or
 * outside the map). Each is noted in `chg` if that is not NULL. */
int bc_cull_voxel(bc_map *m, bc_cull *c, int x, int y, int z, bc_map_change *chg);

/* WHAT A CUT WOULD DROP: how many voxels the server's flood would remove
 * if the voxel (x, y, z) -- and, when it is solid too, (also_x, also_y,
 * also_z): a cut two blocks wide -- were dug out, the cut not counted.
 * The map is the same after as before (the cut and the masses are taken
 * out for the floods and put back; rev does not move), and so is the
 * scratch. 0 for a voxel that is not solid or is the map's ground. For a
 * mind choosing where to break a structure (skill_build.c, dig_weakest). */
int bc_cull_would_drop(bc_map *m, bc_cull *c, int x, int y, int z, int also_x, int also_y, int also_z);

/* The action is over: forget what was proven grounded. */
void bc_cull_end(bc_cull *c);

#endif /* BC_CULL_H */
