/* lsd_core.c -- LSd's own world code, compiled into the engine.
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * See lsd_core.h for why. This file is three things: what demoncore.c
 * needs from the server's state.h and libpvx2 (stated over bc_map), then
 * demoncore.c itself, then the engine-side wrappers.
 *
 * demoncore.c is (c) Mathias Kaerlev 2011-2012 and the LSd authors, GPL-3.
 */
#include "lsd_core.h"

#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

/* --- 1. In state.h's place ------------------------------------------- */

/* state.h is the whole server (ENet, 256 players, the function table).
 * Its guard is claimed here so that neither demoncore.h nor veclib.h
 * pulls it in; what they need from it follows. */
#define LS2_SERVER_STATE_H
#include "protocol.h"      /* the real one: fvec3p, ivec3p, color, the key bits */

typedef uint64_t clk;
typedef ivec3p ivec3;
typedef fvec3p fvec3;
typedef bc_map *Map;

#define MAP_X BC_MAP_X
#define MAP_Y BC_MAP_Y
#define MAP_Z BC_MAP_Z

/* The fields of the server's struct Player that demoncore.c touches, with
 * the server's types. Order does not matter: it is only reached by name. */
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

/* --- 2. The server's file -------------------------------------------- */

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

#include "demoncore.c"

/* --- 3. The engine's side -------------------------------------------- */

static void to_lsd(struct Player *q, const bc_lsd_player *p)
{
	memset(q, 0, sizeof *q);
	q->pos.x = p->pos[0]; q->pos.y = p->pos[1]; q->pos.z = p->pos[2];
	q->ori.x = p->ori[0]; q->ori.y = p->ori[1]; q->ori.z = p->ori[2];
	q->vel.x = p->vel[0]; q->vel.y = p->vel[1]; q->vel.z = p->vel[2];
	q->wade = p->wade;
	q->airborne = p->airborne;
	q->inputs = p->inputs;
	/* The only use the physics has for the tool and the mouse: a gun
	 * with its sights up walks at half pace. */
	q->tool = p->scoped ? ToolTypeGun : ToolTypeSpade;
	q->mouseInputs = p->scoped ? GunInputTypeSecondary : 0;
}

static void from_lsd(bc_lsd_player *p, const struct Player *q)
{
	p->pos[0] = q->pos.x; p->pos[1] = q->pos.y; p->pos[2] = q->pos.z;
	p->vel[0] = q->vel.x; p->vel[1] = q->vel.y; p->vel[2] = q->vel.z;
	p->wade = q->wade;
	p->airborne = q->airborne;
	p->inputs = q->inputs;
}

int32_t bc_lsd_move_player(bc_lsd_player *p, float dt, const bc_map *m)
{
	struct Player q;
	int32_t r;

	to_lsd(&q, p);
	r = move_player(&q, dt, (Map)m, 0);
	from_lsd(p, &q);
	return r;
}

void bc_lsd_change_crouch(bc_lsd_player *p, int crouching, const bc_map *m)
{
	struct Player q;

	to_lsd(&q, p);
	change_crouch(crouching, &q, (Map)m, 0);
	from_lsd(p, &q);
}

int bc_lsd_block_line(bc_map *m, int x1, int y1, int z1, int x2, int y2, int z2,
                      bc_map_change *chg)
{
	ivec3 a, b;
	color none = {0, 0, 0};
	uint32_t before = m->rev;
	int made;

	if (!bc_map_in(x1, y1, z1) || !bc_map_in(x2, y2, z2))
		return 0;
	a.x = x1; a.y = y1; a.z = z1;
	b.x = x2; b.y = y2; b.z = z2;
	m->line_chg_ = chg;
	block_line(m, a, b, none);
	m->line_chg_ = NULL;
	made = (int)(m->rev - before);
	/* one action, one revision */
	m->rev = before + (made ? 1 : 0);
	return made;
}

int bc_lsd_cast_ray(const bc_map *m, const float from[3], const float to[3], int hit[3])
{
	fvec3 a, b;
	ivec3 v;
	int r;

	a.x = from[0]; a.y = from[1]; a.z = from[2];
	b.x = to[0]; b.y = to[1]; b.z = to[2];
	v.x = v.y = v.z = 0;
	r = cast_ray((Map)m, a, b, &v);
	if (hit) {
		hit[0] = v.x; hit[1] = v.y; hit[2] = v.z;
	}
	return r;
}

int bc_lsd_clip(const bc_map *m, float x, float y, float z)
{
	return clip_phys(x, y, z, (Map)m, 0);
}
