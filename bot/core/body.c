/* body.c -- A player's body, moved by the server's own physics. See body.h.
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * The order of a step is the server's order within a tick: the input
 * packet first (funcs_event.c on_move_input: the crouch change, then the
 * jump refused in the air, then the keys stored), the physics after
 * (main.c tick -> move_player).
 */
#include "body.h"

#include <math.h>
#include <string.h>

#include "lsd_core.h"

void bc_body_init(bc_body *b, bc_v3 pos)
{
	memset(b, 0, sizeof *b);
	b->pos = pos;
}

static void load(bc_lsd_player *p, const bc_body *b, bc_v3 ori)
{
	p->pos[0] = b->pos.x; p->pos[1] = b->pos.y; p->pos[2] = b->pos.z;
	p->vel[0] = b->vel.x; p->vel[1] = b->vel.y; p->vel[2] = b->vel.z;
	p->ori[0] = ori.x; p->ori[1] = ori.y; p->ori[2] = ori.z;
	p->wade = b->wade;
	p->airborne = b->airborne;
	p->inputs = b->keys;
	p->scoped = b->scoped;
}

static void store(bc_body *b, const bc_lsd_player *p)
{
	b->pos.x = p->pos[0]; b->pos.y = p->pos[1]; b->pos.z = p->pos[2];
	b->vel.x = p->vel[0]; b->vel.y = p->vel[1]; b->vel.z = p->vel[2];
	b->wade = (uint8_t)(p->wade != 0);
	b->airborne = (uint8_t)(p->airborne != 0);
	b->keys = p->inputs;
}

int32_t bc_body_step(bc_body *b, const bc_map *m, uint8_t keys, bc_v3 ori, float dt)
{
	bc_lsd_player p;
	int32_t r;

	load(&p, b, ori);
	if ((keys ^ p.inputs) & BC_K_CROUCH)
		bc_lsd_change_crouch(&p, keys & BC_K_CROUCH, m);
	if ((keys & BC_K_JUMP) && p.airborne)
		keys &= (uint8_t)~BC_K_JUMP;
	p.inputs = keys;
	r = bc_lsd_move_player(&p, dt, m);
	store(b, &p);
	return r;
}

void bc_body_place(bc_body *b, const bc_map *m, float x, float y, int floor_z, int crouched)
{
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	uint8_t keys = crouched ? BC_K_CROUCH : 0;
	int i, n;

	memset(b, 0, sizeof *b);
	b->pos.x = x;
	b->pos.y = y;
	/* a little above, and let the physics put it down */
	b->pos.z = (float)floor_z - (crouched ? 1.35f : 2.25f) - 0.05f;
	b->keys = keys;
	b->airborne = 1;
	/* The first touch is not rest: the body creeps down the last
	 * hundredths over several ticks, "airborne" on most of them. Rest is
	 * when the floor stops it tick after tick. */
	for (i = 0, n = 0; i < 480 && n < 4; i++) {
		bc_body_step(b, m, keys, ori, BC_BODY_DT);
		n = (!b->airborne && b->vel.z == 0.0f) ? n + 1 : 0;
	}
	b->vel.x = b->vel.y = 0.0f;
}

int bc_body_can_stand(const bc_body *b, const bc_map *m)
{
	float z = b->pos.z - 1.35f;

	if (!(b->keys & BC_K_CROUCH))
		return 1;
	return !bc_lsd_clip(m, b->pos.x - 0.45f, b->pos.y - 0.45f, z) &&
	       !bc_lsd_clip(m, b->pos.x - 0.45f, b->pos.y + 0.45f, z) &&
	       !bc_lsd_clip(m, b->pos.x + 0.45f, b->pos.y - 0.45f, z) &&
	       !bc_lsd_clip(m, b->pos.x + 0.45f, b->pos.y + 0.45f, z);
}

float bc_body_speed(const bc_body *b)
{
	return 32.0f * sqrtf(b->vel.x * b->vel.x + b->vel.y * b->vel.y);
}
