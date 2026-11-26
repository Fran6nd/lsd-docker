/* lsd_core.c -- LSd's own world code, called by the engine.
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * See lsd_core.h for why. demoncore.c is compiled in a unit of its own
 * (bot/Makefile: upstream's file, under upstream's warnings), against
 * lsd_state.h in state.h's place; this file is the engine-side wrappers
 * over its functions, seen through the same header.
 *
 * demoncore.c is (c) Mathias Kaerlev 2011-2012 and the LSd authors, GPL-3.
 */
#include "lsd_core.h"

#include <string.h>

#include "lsd_state.h"
#include "demoncore.h"     /* the server's real one: the functions' prototypes */

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
