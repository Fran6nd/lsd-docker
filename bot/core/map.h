/* map.h -- The world as the server has it: one 64-bit word per column
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * WHAT. A map is 512 x 512 columns of 64 voxels. Bit z of a column's word
 * is set when voxel z is solid, and z GROWS DOWNWARD: 0 is the sky, 61 is
 * the lowest voxel anybody can dig, 62 is the indestructible ground and 63
 * is what lies under the sea. A column whose only solid voxel is 63 is
 * WATER: a body there sinks until its feet are at 64 (see body.h).
 *
 * This is the server's own layout (libpvx2's MapCol), kept from aosbot
 * because everything the planner asks is a shift and a mask on one word:
 * "where can a body stand in this column" is four operations
 * (bc_map_stand_mask) and never a loop over z.
 *
 * WHY IT MUST NOT DRIFT. The engine plans on this copy. The server sends no
 * corrections: it announces block ACTIONS (a build, a destroy, a spade's
 * three voxels, a grenade's 3x3x3, a line) and expects every listener to
 * work out the same result -- including the part nobody announces, the
 * removal of whatever a destroy left floating. So each action here is the
 * server's code path, case for case (lsd/src/main.c block_action_rm,
 * block_action_cull, grenade_rmblocks; cull.h for the flood), the line is
 * the server's own DDA compiled in (lsd_core.h), and map_test replays
 * actions against expectations worked out from the server source.
 *
 * COLOURS are not kept. Nothing in the mechanics layer reads one, and the
 * server's 3 bytes a voxel would be 50 MiB against this struct's 2 MiB.
 *
 * REVISION. Every call that changes a voxel bumps `rev`. A plan remembers
 * the revision it was made on; a follower that sees another knows to look
 * at its route again (nav.h). Nothing else is recorded about a change.
 *
 * No I/O: bc_map_load_vxl reads a .vxl from bytes the caller read.
 */
#ifndef BC_MAP_H
#define BC_MAP_H

#include <stddef.h>
#include <stdint.h>

enum {
	BC_MAP_X = 512,
	BC_MAP_Y = 512,
	BC_MAP_Z = 64,
	BC_MAP_XY = BC_MAP_X * BC_MAP_Y,
	BC_MAP_GROUND_Z = 62,      /* z >= this cannot be dug or built on */
	BC_MAP_WATER_Z = 63        /* the floor of a water column */
};

/* The server's two ways of deciding which neighbours of a spade or a
 * grenade get the floating-block check (state.h CULL_PERSONALITY_*). LSd
 * starts as OpenSpades: only where a voxel was really removed. */
enum bc_cull_personality { BC_CULL_VOXLAP = 0, BC_CULL_OPENSPADES = 1 };

/* What the server announces (the protocol's BlockAction; bl_block_action). */
enum bc_block_action {
	BC_BLOCK_BUILD = 0,
	BC_BLOCK_DESTROY = 1,
	BC_BLOCK_SPADE = 2,        /* the voxel, the one above, the one below */
	BC_BLOCK_GRENADE = 3       /* 3x3x3 around the voxel */
};

struct bc_map_change;

typedef struct bc_map {
	uint64_t col[BC_MAP_XY];   /* [y * 512 + x], bit z = solid */
	uint32_t rev;              /* goes up at every change */
	uint8_t cull_personality;  /* bc_cull_personality */
	uint8_t pad_[3];
	struct bc_map_change *line_chg_;   /* private to bc_map_line; NULL */
} bc_map;

struct bc_cull;                /* cull.h: the flood's scratch, 7 MiB */

/* WHAT AN ACTION DID. The server's Lua cannot see a collapse (map_cull
 * tells nobody), so this engine's flood is the only place in the whole
 * system where a collapse is known -- and whoever applies an action is
 * the only one who can tell the rest of the engine: the senses (a
 * collapse is heard, and a body on it falls), the host (routes through
 * the box are void). Pass one to bc_map_apply / bc_map_line, or NULL.
 *
 * `cells` is optional: a buffer of the caller's for the voxels that
 * changed, the action's own first, the collapse's after. When more
 * changed than it holds, the counts and the box are still exact and `n`
 * stops at `cap`. */
enum {
	BC_CELL_COLLAPSED = 1 << 30,    /* removed by the flood, not named */
	BC_CELL_BUILT = 1 << 29         /* became solid (else: became air) */
};

typedef struct bc_map_change {
	int32_t direct;             /* voxels the action itself changed */
	int32_t collapsed;          /* voxels the flood removed besides */
	int16_t x0, y0, z0;         /* the box round everything that */
	int16_t x1, y1, z1;         /* changed; valid if anything did */
	uint32_t *cells;            /* x | y << 9 | z << 18 | BC_CELL_* */
	int32_t cap, n;
} bc_map_change;

/* Empty it, and give it a buffer (or NULL, 0). */
void bc_map_change_init(bc_map_change *c, uint32_t *cells, int32_t cap);

/* For cull.c and map.c: note one voxel changed. */
void bc_map_change_add(bc_map_change *c, int x, int y, int z, uint32_t flags);

/* An empty world: all air. rev restarts at 1.
 *
 * NOTE: this, bc_map_fill_flat and bc_map_load_vxl all leave
 * cull_personality at BC_CULL_OPENSPADES, LSd's own default. A host
 * whose server runs the other must set it again after every load. */
void bc_map_clear(bc_map *m);

/* A flat world for tests: every column solid from `ground_z` down. */
void bc_map_fill_flat(bc_map *m, int ground_z);

/* Load a .vxl (the VXL span format, as libpvx2's vxl_read does). 1 on
 * success; 0 when the bytes are not a whole map, and then the map is
 * whatever was read so far -- load another. */
int bc_map_load_vxl(bc_map *m, const uint8_t *data, size_t len);

static inline int bc_map_in(int x, int y, int z)
{
	return x >= 0 && x < BC_MAP_X && y >= 0 && y < BC_MAP_Y &&
	       z >= 0 && z < BC_MAP_Z;
}

/* The column's word; 0 outside the map. */
static inline uint64_t bc_map_col(const bc_map *m, int x, int y)
{
	if (x < 0 || x >= BC_MAP_X || y < 0 || y >= BC_MAP_Y)
		return 0;
	return m->col[y * BC_MAP_X + x];
}

/* Is the voxel solid? Outside the map sideways and below is solid, above
 * is air: what the physics takes it for. */
static inline int bc_map_solid(const bc_map *m, int x, int y, int z)
{
	if (z < 0)
		return 0;
	if (z >= BC_MAP_Z || x < 0 || x >= BC_MAP_X || y < 0 || y >= BC_MAP_Y)
		return 1;
	return (int)((m->col[y * BC_MAP_X + x] >> z) & 1);
}

/* Set or clear one voxel, no questions asked (a test building a scene, a
 * host patching a column). Bumps rev if it changed anything. Ignored
 * outside the map. */
void bc_map_set(bc_map *m, int x, int y, int z, int solid);

/* --- Block actions, as the server performs them ---------------------- */

/* One announced action (BL_EV_BLOCK). `cull` is the scratch for the
 * floating-block flood; it may be NULL for a build, and MUST NOT be for
 * anything else on a map that is to stay the server's. `chg`, if not
 * NULL, is ADDED to (bc_map_change_init it first; several actions may
 * be gathered in one). Returns how many voxels changed in all, the
 * collapse included.
 *
 * The two personalities differ only in WHICH neighbours get the flood:
 *   OPENSPADES (LSd's default, and what no stock script changes): the
 *     neighbours of voxels that were really removed. An action that
 *     removes nothing does nothing.
 *   VOXLAP: the neighbours of every voxel the action NAMES -- a destroy
 *     of air still checks its six neighbours, a spade all three levels,
 *     a grenade the whole 3x3x3 shell -- so it can bring down something
 *     that was already floating there.
 * Set bc_map.cull_personality to whichever the server runs; the host
 * should be told (the server's is `set_cull_personality` in Lua). */
int bc_map_apply(bc_map *m, struct bc_cull *cull, int action, int x, int y, int z,
                 bc_map_change *chg);

/* A line of blocks built between two voxels, both included (BL_EV_LINE):
 * the server's block_line. Returns how many voxels became solid. */
int bc_map_line(bc_map *m, int x1, int y1, int z1, int x2, int y2, int z2,
                bc_map_change *chg);

/* --- What the planner asks ------------------------------------------- */

/* The FLOORS of a column where a body can stand upright: bit z is set when
 * voxel z is solid and z-1, z-2, z-3 are air. A body is 2.7 tall; three
 * voxels is what the physics makes of that (nav_test measures it). The
 * sky rows are honest: a floor at z < 3 has less than three voxels of map
 * above it but air all the same. */
static inline uint64_t bc_map_stand_bits(uint64_t c)
{
	return c & ~(c << 1) & ~(c << 2) & ~(c << 3);
}

/* Floors where a body fits crouched but not upright: exactly two voxels of
 * air over them. */
static inline uint64_t bc_map_crouch_bits(uint64_t c)
{
	return c & ~(c << 1) & ~(c << 2) & (c << 3);
}

static inline uint64_t bc_map_stand_mask(const bc_map *m, int x, int y)
{
	return bc_map_stand_bits(bc_map_col(m, x, y));
}

/* Is (x, y) a water column -- nothing solid above the sea bed? */
static inline int bc_map_is_water(const bc_map *m, int x, int y)
{
	uint64_t c = bc_map_col(m, x, y);
	return c != 0 && (c & ~((uint64_t)1 << BC_MAP_WATER_Z)) == 0;
}

/* The first solid voxel at or below z in the column; 64 if none (never, on
 * a loaded map: 63 is always solid). */
int bc_map_floor_at_or_below(const bc_map *m, int x, int y, int z);

/* Index of the lowest set bit; 64 for 0. Here because every user of a
 * column word wants it and C11 has none. */
int bc_ctz64(uint64_t v);

#endif /* BC_MAP_H */
