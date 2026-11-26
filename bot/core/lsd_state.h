/* lsd_state.h -- what lsd/src/demoncore.c needs from the server, over
 * bc_map, in state.h's place.
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * Read by the two units that meet at demoncore.c's functions: the one
 * that compiles demoncore.c itself (bot/Makefile gives it this header with
 * -include, ahead of the file's own first line) and lsd_core.c, which
 * calls them. Both see the same types and the same names here.
 *
 * state.h is the whole server (ENet, 256 players, the function table).
 * Its guard is claimed here so that neither demoncore.h nor veclib.h
 * pulls it in; what they need from it follows. If LSd's physics starts
 * reading a new field of struct Player, demoncore.c stops compiling --
 * the drift alarm wanted.
 */
#ifndef BC_LSD_STATE_H
#define BC_LSD_STATE_H

#define LS2_SERVER_STATE_H
#include "protocol.h"      /* the real one: fvec3p, ivec3p, color, the key bits */

#include "map.h"

typedef uint64_t clk;
typedef ivec3p ivec3;
typedef fvec3p fvec3;
typedef bc_map *Map;

#define MAP_X BC_MAP_X
#define MAP_Y BC_MAP_Y
#define MAP_Z BC_MAP_Z

/* The fields of the server's struct Player that demoncore.c touches, with
 * the server's types. Order does not matter: it is only reached by name.
 * (The vectors are packed types in a struct that is not packed: they sit
 * at their floats' alignment, so demoncore.c's cast of &pos to an aligned
 * union -- the warning gcc 13 gives on it -- reads aligned memory here.) */
struct Player {
	fvec3 pos;
	fvec3 ori;
	fvec3 vel;
	int wade;
	int airborne;
	uint8_t inputs;
	uint8_t mouseInputs;
	uint8_t tool;
};

/* libpvx2's accessors, the four that demoncore.c calls. */
static inline long map_to_xy(int x, int y)
{
	return (long)y * BC_MAP_X + x;
}

static inline int map_is_solid_xy(Map map, long xy, int z)
{
	return (int)((map->col[xy] >> z) & 1);
}

static inline int map_is_solid(Map map, int x, int y, int z)
{
	return map_is_solid_xy(map, map_to_xy(x, y), z);
}

/* block_line is the only caller: every voxel it makes is noted for
 * whoever asked (the pointer is put in the map's padding for the length of
 * the one call -- demoncore.c's signatures are not this file's to change).
 */
static inline void map_create_xy(Map map, long xy, int z)
{
	map->col[xy] |= (uint64_t)1 << z;
	map->rev++;
	if (map->line_chg_)
		bc_map_change_add(map->line_chg_, (int)(xy % BC_MAP_X), (int)(xy / BC_MAP_X), z,
		                  BC_CELL_BUILT);
}

/* Colours are not kept (map.h). */
#define map_set_color_xy(map, xy, z, c, n) ((void)(c))

/* Its functions are not static; keep them out of everybody's way. */
#define clip_phys bc_lsd__clip_phys
#define cast_start bc_lsd__cast_start
#define cast_step bc_lsd__cast_step
#define cast_ray bc_lsd__cast_ray
#define cast_ray_last bc_lsd__cast_ray_last
#define block_line_start bc_lsd__block_line_start
#define block_line_step bc_lsd__block_line_step
#define block_line bc_lsd__block_line
#define change_crouch bc_lsd__change_crouch
#define change_crouch_me bc_lsd__change_crouch_me
#define move_player bc_lsd__move_player
#define move_grenade bc_lsd__move_grenade

#endif /* BC_LSD_STATE_H */
