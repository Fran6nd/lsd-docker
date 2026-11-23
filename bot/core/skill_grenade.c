/* skill_grenade.c -- Throwing a grenade, and getting away from one
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * aosbot's Grenade.cpp and AI.cpp:8111-8670 (docs/internals/07), cut to
 * the mechanics. The server's side (lib_botlink do_grenade): the action
 * carries a velocity and a fuse (0..3 s); it turns the bot to face the
 * velocity and throws from the eye. So cooking is not holding the thing
 * in the hand here: the fuse asked for IS the cooking.
 *
 *  - THE ARC is solved in closed form (speed 32 voxels/s, gravity 32):
 *    a flat one and a lob. Which of the two is decided on a PERFECT fuse
 *    by flying both through the map; the fuse is shortened afterwards.
 *  - RANGE 8 to 32 (horizontal). Nearer than 8 it is one's own.
 *  - WHAT IS WORTH ONE: two or more enemies within 5.5 of each other; a
 *    man in sight from 14 away; the place somebody was lost under 5 s
 *    ago (he is behind something: that is what a grenade is for).
 *  - VETOES: no arc; the burst as flown would cost the thrower over 25;
 *    the burst would do under 22 + 35 x skill at the mark.
 *  - SLOPPINESS by level: the mark is off by up to 13% of the distance
 *    at skill 0; the fuse is cooked less.
 *  - IN HAND the bot STANDS (walking on it walked into its own blast),
 *    turns to the arc, and lets go only once the head really is within
 *    10 - 8 x skill degrees of it (a fixed 2 degrees meant level 1 never
 *    threw: it is inside its tremor). 2.5 s and it gives up.
 *  - AFTER: 8 s x (1.35 - 0.5 x skill) before the next.
 *
 * GETTING AWAY. An enemy's grenade whose flown burst would cost this bot
 * 25 or more is run from, straight away from the burst, after a reaction
 * of 0.75 - 0.45 x skill s; skill under 0.2 (levels 1-2) does not notice.
 */
#include <math.h>
#include <string.h>

#include "brain.h"

static const float G_STEP = 1.0f / 60.0f;

static int clipworld(const bc_map *m, int x, int y, int z)
{
	if (x < 0 || x >= BC_MAP_X || y < 0 || y >= BC_MAP_Y || z < 0)
		return 0;
	if (z == 63) z = 62;
	if (z >= 64) return 1;
	return bc_map_solid(m, x, y, z);
}

bl_vec3 bc_grenade_fly(const bc_map *m, bl_vec3 p, bl_vec3 v, float fuse)
{
	int guard;

	for (guard = 0; guard < 200; guard++) {
		bl_vec3 o = p;
		int ox, oy, oz, nx, ny, nz;

		fuse -= G_STEP;
		if (fuse <= 0.0f)
			break;
		v.z += G_STEP;
		p.x += v.x * 32.0f * G_STEP;
		p.y += v.y * 32.0f * G_STEP;
		p.z += v.z * 32.0f * G_STEP;
		if (!m)
			continue;
		ox = (int)floorf(o.x); oy = (int)floorf(o.y); oz = (int)floorf(o.z);
		nx = (int)floorf(p.x); ny = (int)floorf(p.y); nz = (int)floorf(p.z);
		if (clipworld(m, nx, ny, nz)) {
			if (oz != nz && ((ox == nx && oy == ny) || !clipworld(m, nx, ny, oz)))
				v.z = -v.z;
			else if (ox != nx && ((oy == ny && oz == nz) || !clipworld(m, ox, ny, nz)))
				v.x = -v.x;
			else if (oy != ny && ((ox == nx && oz == nz) || !clipworld(m, nx, oy, nz)))
				v.y = -v.y;
			p = o;
			v.x *= 0.36f; v.y *= 0.36f; v.z *= 0.36f;
		}
	}
	return p;
}

int bc_grenade_arc(bl_vec3 from, bl_vec3 to, int lob, bl_vec3 *vel, float *flight)
{
	const float S = 32.0f, G = 32.0f;
	float dx = to.x - from.x, dy = to.y - from.y;
	float r = sqrtf(dx * dx + dy * dy), h = from.z - to.z;     /* + : the mark is above */
	float k, disc, T, c, s, fl;

	if (r < 0.5f)
		return 0;
	k = G * r * r / (2.0f * S * S);
	disc = r * r - 4.0f * k * (h + k);
	if (disc < 0.0f)
		return 0;
	T = (r + (lob ? 1.0f : -1.0f) * sqrtf(disc)) / (2.0f * k);
	c = 1.0f / sqrtf(1.0f + T * T);
	s = T * c;
	if (c < 0.15f)
		return 0;
	fl = r / (S * c);
	if (!(fl <= 3.0f) || !(fl > 0.0f))
		return 0;
	vel->x = dx / r * c;
	vel->y = dy / r * c;
	vel->z = -s;
	*flight = fl;
	return 1;
}

static float d3(bl_vec3 a, bl_vec3 b)
{
	float x = a.x - b.x, y = a.y - b.y, z = a.z - b.z;

	return sqrtf(x * x + y * y + z * z);
}

int bc_grenade_plan(const bc_map *m, bl_vec3 from, bl_vec3 to, bl_vec3 *vel,
                    float *flight, bl_vec3 *burst)
{
	float best = 4.0f;      /* aosbot kArcMiss */
	int lob, found = 0;

	for (lob = 0; lob < 2; lob++) {
		bl_vec3 v, at;
		float fl, miss;

		if (!bc_grenade_arc(from, to, lob, &v, &fl))
			continue;
		at = bc_grenade_fly(m, from, v, fl + G_STEP);
		miss = d3(at, to);
		if (miss < best) {
			best = miss;
			*vel = v;
			*flight = fl;
			*burst = at;
			found = 1;
		}
	}
	return found;
}

float bc_grenade_damage(const bc_map *m, bl_vec3 at, bl_vec3 body)
{
	float dx = body.x - at.x, dy = body.y - at.y, dz = body.z - at.z, d2, dmg;
	bl_vec3 a = at;

	if (fabsf(dx) >= 16.0f || fabsf(dy) >= 16.0f || fabsf(dz) >= 16.0f)
		return 0.0f;
	/* a grenade at rest lies exactly on a voxel's face */
	a.z -= 0.5f;
	if (m && !bc_sight_clear(m, a, body))
		return 0.0f;
	d2 = dx * dx + dy * dy + dz * dz;
	if (d2 < 1e-3f)
		return 100.0f;
	dmg = 4096.0f / d2;
	return dmg > 100.0f ? 100.0f : dmg;
}

int bc_grenade_target(bc_bot *b, bl_vec3 *out)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bl_vec3 p;
	float dx, dy, flat;
	int t = b->fight.target, have = 0;

	if (bc_enemy_group(b, 2, 5.5f, &p))
		have = 1;
	else if (t >= 0 && b->senses.k[t].visible) {
		p = b->senses.k[t].pos;
		dx = p.x - me->pos.x; dy = p.y - me->pos.y;
		have = dx * dx + dy * dy >= 14.0f * 14.0f;
	} else if (b->senses.lost.valid && e->now - b->senses.lost.at < 5.0) {
		p = b->senses.lost.pos;
		have = 1;
	}
	if (!have)
		return 0;
	dx = p.x - me->pos.x; dy = p.y - me->pos.y;
	flat = sqrtf(dx * dx + dy * dy);
	if (flat < 8.0f || flat > 32.0f)
		return 0;
	p.z += 2.0f;            /* at his feet */
	*out = p;
	return 1;
}

bt_status bc_do_throw(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	float skill = bc_level(b->level)->grenade;

	(void)dt;
	if (b->nade.phase == 0) {
		bl_vec3 mark, vel, burst;
		float flight, fuse, d;

		if (e->now < b->nade.cd_until || me->grenades == 0 || !e->have_map)
			return BT_FAILURE;
		if (a->count > 0 ? !bc_place_of(b, a->text[0], &mark) : !bc_grenade_target(b, &mark))
			return BT_FAILURE;
		d = d3(mark, me->pos);
		mark.x += bc_rng_range(&b->rng, -1.0f, 1.0f) * d * 0.13f * (1.0f - skill);
		mark.y += bc_rng_range(&b->rng, -1.0f, 1.0f) * d * 0.13f * (1.0f - skill);
		if (!bc_grenade_plan(e->map, me->pos, mark, &vel, &flight, &burst)) {
			b->nade.cd_until = e->now + 1.0;
			return BT_FAILURE;
		}
		fuse = flight + (3.0f - flight) * (1.0f - skill) +
		       bc_rng_range(&b->rng, -0.15f, 0.15f) * (1.0f - skill);
		if (fuse < 0.35f) fuse = 0.35f;
		if (fuse > 3.0f) fuse = 3.0f;
		burst = bc_grenade_fly(e->map, me->pos, vel, fuse);
		if (bc_grenade_damage(e->map, burst, me->pos) > 25.0f) {
			b->nade.cd_until = e->now + 1.5;
			return BT_FAILURE;
		}
		if (bc_grenade_damage(NULL, burst, mark) < 22.0f + 35.0f * skill) {
			b->nade.cd_until = e->now + 1.0;
			return BT_FAILURE;
		}
		b->nade.phase = 1;
		b->nade.vel = vel;
		b->nade.fuse = fuse;
		b->nade.release_at = e->now + (double)(0.30f + 0.25f * (1.0f - skill));
		b->nade.give_up_at = e->now + 2.5;
	}
	/* in hand: stand, turn to the arc */
	b->wish.move = BC_MOVE_NONE;
	b->wish.tool = BL_TOOL_GRENADE;
	b->wish.fire_pid = -1;
	b->wish.look = BC_LOOK_POINT;
	b->wish.look_at.x = me->pos.x + b->nade.vel.x * 30.0f;
	b->wish.look_at.y = me->pos.y + b->nade.vel.y * 30.0f;
	b->wish.look_at.z = me->pos.z + b->nade.vel.z * 30.0f;
	if (e->now >= b->nade.release_at) {
		float dot = me->ori.x * b->nade.vel.x + me->ori.y * b->nade.vel.y + me->ori.z * b->nade.vel.z;
		float tol = (10.0f - 8.0f * skill) * 3.14159265f / 180.0f;

		if (dot >= cosf(tol)) {
			bl_ac_grenade g;

			/* what leaves the hand is where the head really points */
			g.vel = me->ori;
			g.fuse = b->nade.fuse;
			if (e->host.action)
				e->host.action(e->host.ctx, BL_AC_GRENADE, b->pid, &g, sizeof g);
			e->stats.grenades++;
			b->nade.phase = 0;
			b->nade.cd_until = e->now + (double)(8.0f * (1.35f - 0.5f * skill));
			return BT_SUCCESS;
		}
	}
	if (e->now >= b->nade.give_up_at) {
		b->nade.phase = 0;
		b->nade.cd_until = e->now + 2.0;
		return BT_FAILURE;
	}
	return BT_RUNNING;
}

float bc_grenade_threat(bc_bot *b, bl_vec3 *burst)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	float skill = bc_level(b->level)->grenade, worst = 0.0f;
	int i;

	if (skill < 0.2f)
		return 0.0f;
	for (i = 0; i < BC_GRENADES_MAX; i++) {
		const bc_nade *n = &e->nades[i];
		float dmg;

		if (!n->valid || n->team == me->team || e->now >= n->at ||
		    e->now < n->born + (double)(0.75f - 0.45f * skill))
			continue;
		dmg = bc_grenade_damage(e->have_map ? e->map : NULL, n->burst, me->pos);
		if (dmg > worst) {
			worst = dmg;
			if (burst) *burst = n->burst;
		}
	}
	return worst;
}

bt_status bc_do_evade(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	const bl_player *me = bc_me(b);
	bl_vec3 at;
	float dx, dy, l;

	(void)a; (void)dt;
	if (bc_grenade_threat(b, &at) < 25.0f)
		return BT_SUCCESS;
	dx = me->pos.x - at.x; dy = me->pos.y - at.y;
	l = sqrtf(dx * dx + dy * dy);
	if (l > 0.3f) { dx /= l; dy /= l; }
	else { dx = me->ori.x; dy = me->ori.y; }
	b->wish.fire_pid = -1;
	b->wish.crouch = 0;
	b->wish.look = BC_LOOK_POINT;
	b->wish.look_at.x = me->pos.x + dx * 20.0f;
	b->wish.look_at.y = me->pos.y + dy * 20.0f;
	b->wish.look_at.z = me->pos.z;
	b->wish.move = BC_MOVE_FREE;
	b->wish.sprint = 1;
	if (bc_walk_safe(b, dx, dy)) { b->wish.mx = dx; b->wish.my = dy; }
	else if (bc_walk_safe(b, -dy, dx)) { b->wish.mx = -dy; b->wish.my = dx; }
	else if (bc_walk_safe(b, dy, -dx)) { b->wish.mx = dy; b->wish.my = -dx; }
	else b->wish.mx = b->wish.my = 0.0f;
	return BT_RUNNING;
}
