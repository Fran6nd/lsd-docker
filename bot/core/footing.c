/* footing.c -- footing.h: is this step safe
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 */
#include <math.h>

#include "footing.h"

/* How long the keys are pressed, and how long the body is then left to
 * come to rest, in ticks of BC_BODY_DT: a third of a second, a quarter. */
enum { PRESS_TICKS = 20, REST_TICKS = 14 };

int bc_footing_dir(uint8_t keys, bc_v3 ori, float *mx, float *my)
{
	float fl = sqrtf(ori.x * ori.x + ori.y * ori.y), fx, fy, f, r, l;

	f = (float)((keys & BC_K_FORWARD) != 0) - (float)((keys & BC_K_BACK) != 0);
	r = (float)((keys & BC_K_RIGHT) != 0) - (float)((keys & BC_K_LEFT) != 0);
	if (fl < 1e-4f || (f == 0.0f && r == 0.0f))
		return 0;
	fx = ori.x / fl;
	fy = ori.y / fl;
	*mx = fx * f - fy * r;      /* right of east is south: y grows south */
	*my = fy * f + fx * r;
	l = sqrtf(*mx * *mx + *my * *my);
	*mx /= l;
	*my /= l;
	return 1;
}

/* A floor for feet at `fz` in column (x, y): its top within a voxel of
 * them, or (stepping onto a wall) solid where the body would walk into it. */
static int footing_at(const bc_map *m, int x, int y, int fz)
{
	int z;

	if (bc_map_is_water(m, x, y))
		return 1;       /* the sea is a floor; whether it may be entered is asked below */
	for (z = fz - 2; z <= fz + 1; z++)
		if (bc_map_solid(m, x, y, z))
			return 1;
	return 0;
}

int bc_footing_keys(const bc_map *m, const bc_body *b, uint8_t keys, bc_v3 ori)
{
	bc_body sim = *b;
	float mx, my, z0;
	int i, k, fz;

	if (b->airborne)
		return 1;
	if (bc_footing_dir(keys, ori, &mx, &my)) {
		/* the column a step and two that way */
		fz = (int)floorf(bc_body_feet(b) + 0.5f);
		for (k = 1; k <= 2; k++)
			if (!footing_at(m, (int)floorf(b->pos.x + mx * 0.8f * (float)k),
			                (int)floorf(b->pos.y + my * 0.8f * (float)k), fz))
				return 0;
	} else if (!(keys & BC_K_JUMP)) {
		return 1;       /* nothing that moves it */
	}
	ori.z = 0.0f;
	z0 = bc_body_feet(b);
	for (i = 0; i < PRESS_TICKS; i++)
		bc_body_step(&sim, m, keys, ori, BC_BODY_DT);
	for (i = 0; i < REST_TICKS; i++)
		bc_body_step(&sim, m, (uint8_t)(keys & BC_K_CROUCH), ori, BC_BODY_DT);
	if (bc_body_feet(&sim) > z0 + BC_FOOTING_DROP)
		return 0;
	if (sim.wade && !b->wade)
		return 0;
	return 1;
}
