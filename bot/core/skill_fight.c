/* skill_fight.c -- Fighting a man: whom, from how far, when to pull
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * The reasons are in skills.h. The server's side (lib_botlink trigger):
 * a held primary with the gun out fires the server's own hit test along
 * the bot's facing, at the gun's interval, one round off the magazine
 * each; with the spade out it swings (reach 3, every 0.25 s) and, when
 * the swing meets no man, digs what it meets. So the trigger must come
 * up when the head is not on him -- a spade swung at nothing eats the
 * wall.
 */
#include <math.h>
#include <string.h>

#include "brain.h"

/* aosbot Level.cpp:57-68 */
static const bc_level_row LEVELS[10] = {
	/* aggr  dodge crouch sprint reload sense  dig   nade */
	{ 0.20f, 0.10f, 0.10f, 0.30f, 0.05f, 0.06f, 0.05f, 0.05f },
	{ 0.28f, 0.20f, 0.16f, 0.38f, 0.14f, 0.15f, 0.14f, 0.14f },
	{ 0.36f, 0.30f, 0.22f, 0.45f, 0.24f, 0.25f, 0.24f, 0.24f },
	{ 0.44f, 0.40f, 0.28f, 0.52f, 0.34f, 0.35f, 0.34f, 0.34f },
	{ 0.52f, 0.50f, 0.35f, 0.58f, 0.44f, 0.45f, 0.44f, 0.44f },
	{ 0.60f, 0.58f, 0.42f, 0.64f, 0.54f, 0.55f, 0.54f, 0.54f },
	{ 0.68f, 0.66f, 0.48f, 0.70f, 0.64f, 0.65f, 0.64f, 0.64f },
	{ 0.76f, 0.74f, 0.54f, 0.76f, 0.74f, 0.75f, 0.74f, 0.74f },
	{ 0.85f, 0.82f, 0.60f, 0.82f, 0.85f, 0.86f, 0.85f, 0.85f },
	{ 0.95f, 0.90f, 0.66f, 0.88f, 0.95f, 0.96f, 0.95f, 0.95f }
};

/* aosbot AI.cpp:77-93 (WeaponProfile) and Ammo.cpp; the interval is the
 * server's (lib_bot WEAPON.fire) */
static const bc_gun_row GUNS[3] = {
	{ 120.0f, 0.50f, 0.15f, 0.35f, 0.50f, 1.10f, 2.5f, 10 },   /* rifle */
	{  80.0f, 0.10f, 0.35f, 0.80f, 0.40f, 0.90f, 2.5f, 30 },   /* smg */
	{  35.0f, 1.00f, 0.10f, 0.20f, 0.70f, 1.40f, 0.5f, 6 }     /* shotgun: a shell */
};

const bc_level_row *bc_level(int level)
{
	if (level < 1) level = 1;
	if (level > 10) level = 10;
	return &LEVELS[level - 1];
}

const bc_gun_row *bc_gun(int gun)
{
	return &GUNS[gun >= 0 && gun <= 2 ? gun : 0];
}

static float clampf(float v, float lo, float hi)
{
	return v < lo ? lo : v > hi ? hi : v;
}

float bc_gun_reach(const bc_bot *b)
{
	const bc_gun_row *g = bc_gun(bc_me(b)->gun);

	return g->reach * (0.75f + 0.23f * bc_level(b->level)->aggression);
}

float bc_engage_range(const bc_bot *b)
{
	return bc_gun_reach(b) * b->fight.engage_frac;
}

float bc_hold_range(const bc_bot *b)
{
	float engage = bc_engage_range(b);
	const float *t = b->persona.trait;
	/* the character: a marksman and a careful bot stay out, a pusher closes */
	float ch = clampf(1.0f + 0.5f * (t[BC_T_MARKSMAN] - 1.0f) + 0.3f * (t[BC_T_CAUTION] - 1.0f) -
	                  0.4f * (t[BC_T_AGGRESSION] - 1.0f), 0.5f, 2.5f);
	float hold = clampf(engage * 0.35f, 6.0f, 18.0f) * ch;

	return hold > engage * 0.8f ? engage * 0.8f : hold;
}

static float rank(const bl_player *me, bl_vec3 p)
{
	float dx = p.x - me->pos.x, dy = p.y - me->pos.y, dz = 0.5f * (p.z - me->pos.z);

	return dx * dx + dy * dy + dz * dz;
}

void bc_fight_select(bc_bot *b)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bc_senses *s = &b->senses;
	bc_fight *f = &b->fight;
	int held = f->target, nearest = -1, shooter = -1, i, pick;
	float best = 1e30f;

	for (i = 0; i < BL_MAX_PLAYERS; i++)
		if (s->k[i].visible) {
			float r = rank(me, s->k[i].pos);

			if (r < best) { best = r; nearest = i; }
		}
	if (s->threat.valid && s->threat.by != BL_NO_PLAYER && e->now - s->threat.at < 8.0 &&
	    s->k[s->threat.by].visible)
		shooter = s->threat.by;

	if (held >= 0) {
		const bl_player *t = &e->w.players[held];

		if (t->state != BL_ALIVE || t->team == me->team) {
			if (t->state != BL_ALIVE)
				f->kill_at = e->now;
			held = -1;
		}
	}
	pick = held;
	if (held >= 0 && s->k[held].visible) {
		if (nearest != held && e->now - f->target_since >= 1.2 &&
		    best < 0.25f * rank(me, s->k[held].pos))
			pick = nearest;
	} else if (held >= 0) {
		double grace = s->n_visible > 0 ? 0.35 : 1.5;

		if (shooter >= 0) pick = shooter;
		else if (e->now - s->k[held].seen_at > grace) pick = nearest;
	} else {
		pick = shooter >= 0 ? shooter : nearest;
	}
	{
		/* what its leader fights, it fights (skill_squad.c) */
		int sq = bc_squad_target(b);

		if (sq >= 0 && s->k[sq].visible) pick = sq;
	}
	if (pick != f->target) {
		f->target = pick;
		f->target_since = e->now;
		if (pick >= 0) {
			/* a new man: a new opening distance, a new whim */
			f->engage_frac = clampf(b->style_engage + bc_rng_range(&b->rng, -0.225f, 0.225f),
			                        0.55f, 1.0f);
			f->melee = bc_frand(b) < 0.08f;
		}
		f->strafing = 0;
	}
}

/* floor (or a wall) all the way a jump that way would carry it: 1 to 3
 * voxels on, within a voxel of the feet */
static int jump_safe(const bc_bot *b, float mx, float my)
{
	const bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int fz = (int)floorf(me->pos.z + 2.75f), k;

	if (!e->have_map)
		return 1;
	for (k = 1; k <= 3; k++) {
		int x = (int)floorf(me->pos.x + mx * (float)k), y = (int)floorf(me->pos.y + my * (float)k);

		if (bc_floor_near(e->map, x, y, fz) < 0 && !bc_map_solid(e->map, x, y, fz - 1))
			return 0;
	}
	return 1;
}

static void strafe(bc_bot *b, bl_vec3 at, float flat, float hold, int melee, float dt)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const bc_level_row *lv = bc_level(b->level);
	bc_fight *f = &b->fight;
	int flinch = e->now - b->senses.hurt_at < 1.5;
	float fl = flinch ? 1.6f : 1.0f;       /* aosbot kFlinchScale */
	float tx = at.x - me->pos.x, ty = at.y - me->pos.y, radial, side, mx, my, l;
	int tries;

	if (flat > 1e-3f) { tx /= flat; ty /= flat; }
	if (e->now >= f->strafe_until || f->strafe_dir == 0) {
		f->strafe_dir = bc_frand(b) < 0.5f ? -1 : 1;
		f->orbit_bias = bc_rng_range(&b->rng, -0.3f, 0.3f);
		f->strafe_until = e->now + (double)bc_rng_range(&b->rng, 0.35f, 1.10f);
	}
	radial = f->orbit_bias;
	if (flat > hold) radial += clampf((flat - hold) / (hold > 1.0f ? hold : 1.0f), 0.0f, 1.0f);
	if (flat < 0.45f * hold) radial -= 0.35f;
	radial = clampf(radial, -0.5f, 1.0f);
	side = clampf(lv->dodge * b->style_dodge * fl * 1.6f, 0.0f, 1.0f);
	if (melee) { radial = 1.0f; side = 0.0f; }

	for (tries = 0; tries < 3; tries++) {
		float d = (float)f->strafe_dir;

		mx = -ty * d * side + tx * radial;
		my = tx * d * side + ty * radial;
		l = sqrtf(mx * mx + my * my);
		if (l < 0.3f) { mx = my = 0.0f; break; }
		mx /= l; my /= l;
		if (bc_walk_safe(b, mx, my))
			break;
		/* an edge or the sea that way: the other side, then stand */
		if (tries == 0) {
			f->strafe_dir = -f->strafe_dir;
			f->strafe_until = e->now + (double)bc_rng_range(&b->rng, 0.4f, 0.9f);
		} else if (tries == 1) {
			side = 0.0f;
			radial = radial > 0.0f ? -0.5f : 0.0f;
		} else {
			mx = my = 0.0f;
		}
	}
	b->wish.move = BC_MOVE_FREE;
	b->wish.mx = mx;
	b->wish.my = my;

	if (!melee) {
		/* crouch in bouts; a jump now and then when just hit */
		if (e->now < f->crouch_until) {
			b->wish.crouch = 1;
		} else if (e->now >= f->crouch_cd_until &&
		           bc_frand(b) < 1.1f * lv->crouch * b->style_crouch * fl * dt) {
			f->crouch_until = e->now + (double)bc_rng_range(&b->rng, 0.35f, 1.20f);
			f->crouch_cd_until = f->crouch_until + (double)bc_rng_range(&b->rng, 1.6f, 4.4f);
			b->wish.crouch = 1;
		}
		if (flinch && !b->wish.crouch && e->now >= f->jump_cd_until && (mx != 0.0f || my != 0.0f) &&
		    bc_frand(b) < 1.5f * lv->dodge * b->style_dodge * dt && jump_safe(b, mx, my)) {
			f->jump_cd_until = e->now + (double)bc_rng_range(&b->rng, 2.0f, 5.0f);
			b->wish.jump = 1;
		}
	}
}

bt_status bc_do_fight(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bc_fight *f = &b->fight;
	const bc_known *k;
	float dx, dy, dz, flat, hold;
	int t = f->target, melee, st;

	(void)a;
	if (t < 0)
		return e->now - f->kill_at < 0.5 ? BT_SUCCESS : BT_FAILURE;
	k = &b->senses.k[t];
	dx = k->pos.x - me->pos.x; dy = k->pos.y - me->pos.y; dz = k->pos.z - me->pos.z;
	flat = sqrtf(dx * dx + dy * dy);
	melee = (me->mag == 0 && me->reserve == 0) ||
	        (f->melee && flat <= 5.0f && fabsf(dz) <= 4.0f) ||
	        (me->mag == 0 && flat <= 4.0f);
	hold = melee ? 0.0f : bc_hold_range(b);
	b->wish.tool = melee ? BL_TOOL_SPADE : BL_TOOL_GUN;
	b->wish.crouch = b->wish.jump = 0;

	if (!k->visible) {
		/* lost a moment ago: to where he was, the head on the place while
		 * the place is in its sight; round a wall, where it goes */
		if (flat < 24.0f && bc_sight_clear(e->have_map ? e->map : NULL, me->pos, k->pos)) {
			b->wish.look = BC_LOOK_POINT;
			b->wish.look_at = k->pos;
		}
		b->wish.fire_pid = -1;
		f->strafing = 0;
		bc_move_to(b, k->pos, 2.0f);
		return BT_RUNNING;
	}
	b->wish.look = BC_LOOK_TARGET;
	b->wish.look_pid = (int16_t)t;
	b->wish.fire_pid = (int16_t)t;

	if (flat > (melee ? 2.0f : hold * 1.35f) && !(f->strafing && flat < hold * 1.6f)) {
		float gx = b->wish.goal.x - k->pos.x, gy = b->wish.goal.y - k->pos.y;
		float radius = melee ? 1.0f : clampf(hold * 0.8f, 2.0f, 12.0f);

		f->strafing = 0;
		/* chase: a new route only when he has moved from the old goal
		 * (aosbot replanned every 0.8 s) */
		if (b->mv.goal_set &&
		    (b->mv.state == BC_MV_PLANNING || b->mv.state == BC_MV_FOLLOWING) &&
		    (gx * gx + gy * gy < 16.0f + 0.03f * flat * flat || e->now < f->chase_at))
			st = bc_move_to(b, b->wish.goal, b->wish.radius);
		else {
			st = bc_move_to(b, k->pos, radius);
			f->chase_at = e->now + 0.8;
		}
		if (st != BC_MV_FAILED && st != BC_MV_ARRIVED)
			return BT_RUNNING;
		/* no way to him: fight from here */
	}
	f->strafing = 1;
	strafe(b, k->pos, flat, hold, melee, dt);
	return BT_RUNNING;
}

void bc_fire_at_will(bc_bot *b)
{
	const bl_player *me = bc_me(b);
	int t = b->fight.target;
	float dx, dy;

	if (t < 0 || !b->senses.k[t].visible)
		return;
	/* no rounds in the gun nor besides: nothing to fire at will (a man the
	 * server disarmed -- a hostage -- walks on without aiming at anybody) */
	if (me->mag == 0 && me->reserve == 0)
		return;
	dx = b->senses.k[t].pos.x - me->pos.x;
	dy = b->senses.k[t].pos.y - me->pos.y;
	if (sqrtf(dx * dx + dy * dy) > bc_engage_range(b))
		return;
	b->wish.look = BC_LOOK_TARGET;
	b->wish.look_pid = (int16_t)t;
	b->wish.fire_pid = (int16_t)t;
	b->wish.tool = BL_TOOL_GUN;
}

/* A team-mate in the line (aosbot AI.cpp:7864): within 0.75 of the ray,
 * between the muzzle and the man. */
static int mate_in_line(const bc_bot *b, float tdist)
{
	const bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int i;

	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		const bl_player *p = &e->w.players[i];
		float dx, dy, dz, t, ox, oy, rz;

		if (i == b->pid || p->state != BL_ALIVE || p->team != me->team)
			continue;
		dx = p->pos.x - me->pos.x; dy = p->pos.y - me->pos.y; dz = p->pos.z - me->pos.z;
		t = dx * me->ori.x + dy * me->ori.y + dz * me->ori.z;
		if (t <= 0.4f || t >= tdist + 0.5f)
			continue;
		ox = dx - me->ori.x * t;
		oy = dy - me->ori.y * t;
		if (ox * ox + oy * oy > 0.75f * 0.75f)
			continue;
		rz = me->pos.z + me->ori.z * t;
		if (rz >= p->pos.z - 0.6f && rz <= p->pos.z + 2.8f)
			return 1;
	}
	return 0;
}

uint8_t bc_fight_trigger(bc_bot *b, int on_target, float dist)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const bc_gun_row *g = bc_gun(me->gun);
	bc_fight *f = &b->fight;

	if (b->wish.fire_pid < 0 || !on_target || e->hold_fire) {
		f->burst_until = 0.0;
		return 0;
	}
	if (b->wish.tool == BL_TOOL_SPADE)
		return (me->tool == BL_TOOL_SPADE && dist < 3.3f) ? BL_M_PRIMARY : 0;
	if (me->tool != BL_TOOL_GUN || me->mag == 0 || e->now < f->reloading_until ||
	    e->now < f->fire_block_until || dist > bc_engage_range(b) || dist >= 126.0f)
		return 0;
	if (e->now >= f->ff_until && mate_in_line(b, dist))
		f->ff_until = e->now + 0.35;
	if (e->now < f->ff_until) {
		f->burst_until = 0.0;
		return 0;
	}
	if (e->now < f->burst_until)
		return BL_M_PRIMARY;
	if (e->now >= f->gap_until) {
		float burst = bc_rng_range(&b->rng, g->burst_min, g->burst_max);
		float gap = bc_rng_range(&b->rng, g->gap_min, g->gap_max);

		f->burst_until = e->now + (double)burst;
		f->gap_until = e->now + (double)(gap > burst ? gap : burst + 0.1f);
		return BL_M_PRIMARY;
	}
	return 0;
}

int bc_reload_act(bc_bot *b)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const bc_gun_row *g = bc_gun(me->gun);
	const bc_level_row *lv = bc_level(b->level);
	bc_fight *f = &b->fight;
	int fighting = b->wish.fire_pid >= 0 || b->senses.n_visible > 0, wanted;

	if (me->tool != BL_TOOL_GUN || me->reserve == 0 || me->mag >= g->mag ||
	    e->now < f->reloading_until) {
		f->reload_since = 0.0;
		return 0;
	}
	wanted = me->mag == 0 ||
	         (!fighting && (float)me->mag <= (0.10f + 0.40f * lv->reload) * (float)g->mag);
	if (!wanted) {
		f->reload_since = 0.0;
		return 0;
	}
	if (f->reload_since == 0.0)
		f->reload_since = e->now;
	/* it has to be noticed first: 1.24 s at level 1, 0.21 at 10 */
	if (e->now - f->reload_since < (double)(1.30f - 1.15f * lv->reload))
		return 0;
	f->reload_since = 0.0;
	f->reloading_until = e->now + (double)(me->gun == BL_GUN_SHOTGUN
	                     ? g->reload_secs * (float)(g->mag - me->mag) : g->reload_secs);
	return 1;
}
