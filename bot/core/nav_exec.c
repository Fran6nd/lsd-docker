/* nav_exec.c -- The controllers: choosing keys to do one move
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * See nav.h for the design and nav_i.h for how nav is split.
 *
 * Two kinds of code live here and they must not be confused:
 *
 *   LAWS are cheap rules that turn "where the body is, where it should
 *   go" into keys and a facing. They contain rough numbers about the
 *   physics (how far a body coasts) and are allowed to be wrong: nothing
 *   is ever decided on a law's say-so.
 *
 *   SIMULATIONS run a law on a COPY of the body through the real physics
 *   to see what would happen. Every commitment -- pressing jump, walking
 *   off an edge -- is made only on a simulation's say-so.
 *
 * So the laws' rough numbers set how well a move is done, never whether
 * it is safe to try, and a change in the server's physics degrades this
 * file gracefully instead of silently.
 */
#include "nav_i.h"

#include <math.h>
#include <stdlib.h>

const int8_t bc_nav_dx[8] = {1, 1, 0, -1, -1, -1, 0, 1};
const int8_t bc_nav_dy[8] = {0, 1, 1, 1, 0, -1, -1, -1};

/* How long ground friction takes to eat a speed: v/4 voxels of coasting
 * from v voxels a second. In the air it is v/1. Rough, see above. */
#define COAST_GROUND 0.25f
#define COAST_AIR 1.0f

int nav_at(const bc_body *b, bc_nav_node n)
{
	float feet, r;

	if ((int)floorf(b->pos.x) != n.x || (int)floorf(b->pos.y) != n.y)
		return 0;
	feet = bc_body_feet(b);
	r = nav_rest(n.z);
	return feet > r - 1.3f && feet < r + 0.25f;
}

/* Standing on the floor voxel z, or within a hair of it and settling.
 * NOT the server's `airborne` flag: after a landing the body creeps down
 * the last few hundredths over several ticks and the flag says "in the
 * air" for most of them (and the server refuses a jump on those ticks). */
int nav_on_floor(const bc_body *b, int z)
{
	float f = bc_body_feet(b), r = nav_rest(z);

	return f > r - 0.35f && f < r + 0.25f && b->vel.z >= 0.0f && b->vel.z < 0.12f;
}

/* The same, or held up a little higher: a body that came down a stair is
 * often resting with one corner still on the tread above. It is "at" the
 * lower column all the same, and will drop onto it as it moves. */
static int on_or_above(const bc_body *b, int z)
{
	float f = bc_body_feet(b), r = nav_rest(z);

	return f > r - 1.3f && f < r + 0.25f && b->vel.z >= 0.0f && b->vel.z < 0.12f;
}

uint8_t nav_crouch_guard(const bc_body *b, const bc_map *m, uint8_t keys)
{
	if (b->airborne)
		return (uint8_t)((keys & ~BC_K_CROUCH) | (b->keys & BC_K_CROUCH));
	if ((b->keys & BC_K_CROUCH) && !(keys & BC_K_CROUCH) && !bc_body_can_stand(b, m))
		keys |= BC_K_CROUCH;
	return keys;
}

void nav_law_steer(const bc_body *b, float tx, float ty, uint8_t mode, int arrive,
                   uint8_t *keys, bc_v3 *ori)
{
	float dx = tx - b->pos.x, dy = ty - b->pos.y;
	float dist = sqrtf(dx * dx + dy * dy);
	float vx = b->vel.x * 32.0f, vy = b->vel.y * 32.0f;
	float ux, uy, val, px, py, lead, ax, ay, al;
	uint8_t k = (uint8_t)(BC_K_FORWARD | mode);

	if (dist < 1e-4f) {
		ux = ori->x; uy = ori->y;
		if (ux == 0.0f && uy == 0.0f)
			ux = 1.0f;
	} else {
		ux = dx / dist; uy = dy / dist;
	}
	/* The body slides: its velocity takes a quarter of a second to
	 * follow its facing, two voxels at a walk. Facing the target is
	 * therefore wrong after any turn; face so that the push also
	 * cancels the sideways part of the velocity. */
	val = vx * ux + vy * uy;
	px = vx - val * ux; py = vy - val * uy;
	lead = dist > 0.75f ? dist : 0.75f;
	ax = ux * lead - COAST_GROUND * px;
	ay = uy * lead - COAST_GROUND * py;
	al = sqrtf(ax * ax + ay * ay);
	if (al < 1e-5f) { ax = ux; ay = uy; al = 1.0f; }
	ori->x = ax / al; ori->y = ay / al; ori->z = 0.0f;

	if (arrive) {
		float speed = sqrtf(vx * vx + vy * vy);
		float coast = (val > 0.0f ? val : 0.0f) * (b->airborne ? COAST_AIR : COAST_GROUND);
		uint8_t held = (uint8_t)(mode & BC_K_CROUCH);

		if (speed > 2.0f && val < 0.5f * speed) {
			/* going fast and not towards it (just told to stop
			 * somewhere it has already passed, or beside it): no
			 * finesse, kill the speed first */
			nav_law_stop(b, keys, ori);
			return;
		}
		if (dist < 0.06f && speed < 1.0f)
			k = held;
		else if (coast > dist * 1.5f + 0.05f)
			k = (uint8_t)(BC_K_BACK | held);
		else if (coast > dist * 0.85f)
			k = held;
		else if (dist < 0.7f)
			k = (uint8_t)(BC_K_FORWARD | BC_K_SNEAK | held);
		else
			k = (uint8_t)(BC_K_FORWARD | (mode & ~BC_K_SPRINT));
	}
	*keys = k;
}

void nav_law_stop(const bc_body *b, uint8_t *keys, bc_v3 *ori)
{
	float vx = b->vel.x * 32.0f, vy = b->vel.y * 32.0f;
	float speed = sqrtf(vx * vx + vy * vy);
	uint8_t held = (uint8_t)(b->keys & BC_K_CROUCH);

	if (speed > 0.6f) {
		/* face the way it is going and pull back: the same push as
		 * turning round, without the head spinning */
		ori->x = vx / speed; ori->y = vy / speed; ori->z = 0.0f;
		*keys = (uint8_t)(BC_K_BACK | held);
	} else {
		*keys = held;
	}
}

/* --- a shot's geometry ------------------------------------------------ */

typedef struct geom {
	float ax, ay;               /* centre of the take-off column */
	float bx, by;               /* centre of the landing column */
	float ux, uy;               /* unit direction */
	float cell;                 /* length of one column along it */
} geom;

static geom shot_geom(const nav_shot *s)
{
	geom g;
	float dx = (float)(s->to.x - s->from.x), dy = (float)(s->to.y - s->from.y);
	float len = sqrtf(dx * dx + dy * dy);
	int d = abs(s->to.x - s->from.x) > abs(s->to.y - s->from.y) ?
	        abs(s->to.x - s->from.x) : abs(s->to.y - s->from.y);

	g.ax = (float)s->from.x + 0.5f; g.ay = (float)s->from.y + 0.5f;
	g.bx = (float)s->to.x + 0.5f; g.by = (float)s->to.y + 0.5f;
	if (len < 1e-6f) { g.ux = 1.0f; g.uy = 0.0f; g.cell = 1.0f; }
	else { g.ux = dx / len; g.uy = dy / len; g.cell = len / (float)(d ? d : 1); }
	return g;
}

void nav_jump_run_law(const nav_shot *s, const bc_body *b, uint8_t *keys, bc_v3 *ori)
{
	geom g = shot_geom(s);

	nav_law_steer(b, g.bx, g.by, s->sprint ? BC_K_SPRINT : 0, 0, keys, ori);
}

static void air_law(const nav_shot *s, const bc_body *b, uint8_t air_keys,
                    uint8_t *keys, bc_v3 *ori)
{
	geom g = shot_geom(s);
	uint8_t k;

	nav_law_steer(b, g.bx, g.by, 0, 0, &k, ori);
	if ((b->pos.x - g.bx) * g.ux + (b->pos.y - g.by) * g.uy > 0.0f) {
		/* past the middle of the landing column: do not turn round in
		 * the air, keep facing along the jump */
		ori->x = g.ux; ori->y = g.uy; ori->z = 0.0f;
	}
	*keys = (uint8_t)(air_keys | (b->keys & BC_K_CROUCH));
}

/* Is the body's box over the node's column by a safe margin? A body is
 * held up by any corner, so it has LANDED on a column as soon as it
 * overlaps it -- its centre may still be over the gap. */
static int over(const bc_body *b, bc_nav_node n)
{
	return fabsf(b->pos.x - ((float)n.x + 0.5f)) < 0.9f &&
	       fabsf(b->pos.y - ((float)n.y + 0.5f)) < 0.9f;
}

static void land_law(const nav_shot *s, const bc_body *b, uint8_t *keys, bc_v3 *ori)
{
	nav_law_steer(b, (float)s->to.x + 0.5f, (float)s->to.y + 0.5f, 0, 1, keys, ori);
}

/* After a landing: does the body get to the middle of the column and stay
 * on that floor? */
static int settles(const nav_shot *s, const bc_map *m, bc_body *bb)
{
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	float lim = nav_rest(s->to.z) + 0.3f;
	uint8_t k;
	int t, in = 0;

	for (t = 0; t < 40 && in < 6; t++) {
		land_law(s, bb, &k, &ori);
		bc_body_step(bb, m, k, ori, BC_BODY_DT);
		if (bc_body_feet(bb) > lim)
			return 0;
		in = nav_at(bb, s->to) ? in + 1 : 0;
	}
	return in >= 6;
}

/* Fly the copy to the ground under `air_keys`. 1: it is down on s->to and
 * stays there. */
static int fly(const nav_shot *s, const bc_map *m, bc_body *bb, uint8_t air_keys,
               uint8_t *damage)
{
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	uint8_t k;
	int t;

	for (t = 0; t < 150 && bb->airborne; t++) {
		int32_t dmg;

		air_law(s, bb, air_keys, &k, &ori);
		dmg = bc_body_step(bb, m, k, ori, BC_BODY_DT);
		if (dmg > 0) {
			if (dmg > (int32_t)s->max_damage)
				return 0;
			if (damage)
				*damage = (uint8_t)dmg;
		}
	}
	if (bb->airborne || !over(bb, s->to) || !nav_on_floor(bb, s->to.z))
		return 0;       /* still falling, or down on something else */
	return settles(s, m, bb);
}

int nav_jump_sim(const nav_shot *s, const bc_map *m, const bc_body *b0, int delay,
                 uint8_t air_keys)
{
	bc_body bb = *b0;
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	uint8_t k;
	int i;

	for (i = 0; i < delay; i++) {
		nav_jump_run_law(s, &bb, &k, &ori);
		bc_body_step(&bb, m, k, ori, BC_BODY_DT);
		if (bc_body_feet(&bb) > nav_rest(s->from.z) + 0.3f)
			return 0;       /* ran off the end */
	}
	nav_jump_run_law(s, &bb, &k, &ori);
	bc_body_step(&bb, m, (uint8_t)(k | BC_K_JUMP), ori, BC_BODY_DT);
	if (!(bb.vel.z < 0.0f) || !bb.airborne)
		return 0;       /* the server did not take the jump this tick */
	return fly(s, m, &bb, air_keys, NULL);
}

/* One more tick of running, then an emergency stop: still up there? */
static int can_still_stop(const nav_shot *s, const bc_map *m, const bc_body *b0, int run_ticks)
{
	bc_body bb = *b0;
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	float lim = nav_rest(s->from.z) + 0.3f;
	uint8_t k;
	int i;

	for (i = 0; i < run_ticks + 24; i++) {
		if (i < run_ticks)
			nav_jump_run_law(s, &bb, &k, &ori);
		else
			nav_law_stop(&bb, &k, &ori);
		bc_body_step(&bb, m, k, ori, BC_BODY_DT);
		if (bc_body_feet(&bb) > lim)
			return 0;
	}
	return 1;
}

/* Keeping on running, is there a moment ahead when the jump can be
 * pressed (three good ticks in a row)? Then being unable to stop is not a
 * reason to brake: the body is committed to a jump it has checked. */
static int window_ahead(const nav_shot *s, const bc_map *m, const bc_body *b0)
{
	bc_body bb = *b0;
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	float lim = nav_rest(s->from.z) + 0.3f;
	uint8_t k;
	int i, run = 0;

	for (i = 0; i < 40; i++) {
		if (nav_jump_sim(s, m, &bb, 0, BC_K_FORWARD) || nav_jump_sim(s, m, &bb, 0, 0)) {
			if (++run >= 3)
				return 1;
		} else {
			run = 0;
		}
		nav_jump_run_law(s, &bb, &k, &ori);
		bc_body_step(&bb, m, k, ori, BC_BODY_DT);
		if (bc_body_feet(&bb) > lim)
			return 0;
	}
	return 0;
}

int nav_jump_tick(const nav_shot *s, nav_xs *xs, const bc_body *b, const bc_map *m,
                  uint8_t *keys, bc_v3 *ori)
{
	geom g = shot_geom(s);
	float rx = b->pos.x - g.ax, ry = b->pos.y - g.ay;
	float along = rx * g.ux + ry * g.uy;
	float lat = -rx * g.uy + ry * g.ux;
	float vx = b->vel.x * 32.0f, vy = b->vel.y * 32.0f;
	float val = vx * g.ux + vy * g.uy;
	float vlat = -vx * g.uy + vy * g.ux;
	float speed = sqrtf(vx * vx + vy * vy);

	if (xs->phase == NAV_XS_INIT || (xs->phase == NAV_XS_ALIGN && xs->attempts == 0)) {
		/* Already in the lane and not going backwards: no need to walk
		 * to the start of the run-up, the simulation will say whether
		 * this speed does. This is how a jump is taken in stride. (Not
		 * after a failed attempt: then the full run-up, from rest, as
		 * measured.) */
		int in_lane = on_or_above(b, s->from.z) && fabsf(lat) < 0.2f && fabsf(vlat) < 1.0f &&
		              val > -0.5f && along < 0.35f &&
		              along > -((float)s->runup + 8.5f) * g.cell;
		xs->phase = in_lane ? NAV_XS_RUN : NAV_XS_ALIGN;
	}

	if (xs->phase == NAV_XS_BRAKE) {
		nav_law_stop(b, keys, ori);
		if (speed < 0.4f && on_or_above(b, s->from.z)) {
			if (++xs->attempts >= 3)
				return -BC_NAV_WHY_NO_JUMP;
			xs->phase = NAV_XS_ALIGN;
		}
		return 0;
	}

	if (xs->phase == NAV_XS_ALIGN) {
		/* The start of the run: `runup` columns back, or for a
		 * standing jump the back of the take-off column. */
		float back = s->runup ? (float)s->runup * g.cell : 0.3f;
		float tx = g.ax - back * g.ux, ty = g.ay - back * g.uy;
		float dx = tx - b->pos.x, dy = ty - b->pos.y;

		if (dx * dx + dy * dy < 0.12f * 0.12f && speed < 0.8f &&
		    on_or_above(b, s->from.z)) {
			xs->phase = NAV_XS_RUN;
		} else {
			if (speed > 2.5f && !can_still_stop(s, m, b, 2))
				nav_law_stop(b, keys, ori);     /* the edge first */
			else
				nav_law_steer(b, tx, ty, 0, 1, keys, ori);
			return 0;
		}
	}

	if (xs->phase == NAV_XS_RUN) {
		uint8_t air = BC_K_FORWARD;
		int ok0;

		if (bc_body_feet(b) > nav_rest(s->from.z) + 0.3f) {
			/* below the run-up without having jumped: fell off it,
			 * or was pushed */
			nav_law_stop(b, keys, ori);
			return -BC_NAV_WHY_NO_JUMP;
		}
		nav_jump_run_law(s, b, keys, ori);

		ok0 = nav_jump_sim(s, m, b, 0, air);
		if (!ok0) {
			air = 0;
			ok0 = nav_jump_sim(s, m, b, 0, air);
		}
		/* Jump on the first of three good ticks: the command reaches
		 * the server a tick or two after the state it was thought
		 * from, and lateness must not turn a jump into a fall. */
		if (ok0 && nav_jump_sim(s, m, b, 1, air) && nav_jump_sim(s, m, b, 2, air) &&
		    /* ...but not the first such tick there is. Early in the
		     * window the jump lands short and is hauled up by the far
		     * lip; late in it, it lands well on. While the window will
		     * still be open five ticks on and the body is still
		     * closing on the edge, keep running. */
		    !(speed > 1.0f && nav_jump_sim(s, m, b, 5, air) && nav_jump_sim(s, m, b, 4, air) &&
		      nav_jump_sim(s, m, b, 3, air))) {
			*keys |= BC_K_JUMP;
			xs->air_keys = air;
			xs->phase = NAV_XS_AIR;
			xs->ticks = 0;
			return 0;
		}
		if (!can_still_stop(s, m, b, 2) && !window_ahead(s, m, b)) {
			if (ok0 && !can_still_stop(s, m, b, 0)) {
				/* too late to stop, and a jump now lands: jump */
				*keys |= BC_K_JUMP;
				xs->air_keys = air;
				xs->phase = NAV_XS_AIR;
				xs->ticks = 0;
				return 0;
			}
			xs->phase = NAV_XS_BRAKE;
			nav_law_stop(b, keys, ori);
		}
		return 0;
	}

	/* NAV_XS_AIR */
	if (xs->ticks < 255)
		xs->ticks++;
	if (nav_at(b, s->to) && nav_on_floor(b, s->to.z))
		return 1;
	if (xs->ticks >= 3 && over(b, s->to) && nav_on_floor(b, s->to.z)) {
		/* down on the edge of it: walk in */
		land_law(s, b, keys, ori);
		return 0;
	}
	if (xs->ticks >= 3 && s->to.z != s->from.z && nav_on_floor(b, s->from.z) &&
	    fabsf(along) < 1.2f) {
		/* still on the take-off floor: the jump was not taken (the
		 * command came on a tick the server had the body "in the
		 * air"). Run at it again. */
		if (++xs->attempts >= 4)
			return -BC_NAV_WHY_NO_JUMP;
		xs->phase = NAV_XS_RUN;
		nav_jump_run_law(s, b, keys, ori);
		return 0;
	}
	if (xs->ticks >= 3 && !b->airborne && b->vel.z == 0.0f) {
		if (s->to.z == s->from.z && fabsf(along) < 1.2f &&
		    nav_on_floor(b, s->from.z)) {
			if (++xs->attempts >= 4)
				return -BC_NAV_WHY_NO_JUMP;
			xs->phase = NAV_XS_RUN;
			nav_jump_run_law(s, b, keys, ori);
			return 0;
		}
		return -BC_NAV_WHY_NO_JUMP;     /* down somewhere else */
	}
	{
		/* Trim the flight: of holding forward, holding nothing and
		 * pulling back, keep to the planned one while it still lands,
		 * else take one that does. */
		static const uint8_t opt[3] = {BC_K_FORWARD, 0, BC_K_BACK};
		uint8_t pick = xs->air_keys;
		bc_body bb = *b;
		int i;

		if (!fly(s, m, &bb, pick, NULL)) {
			for (i = 0; i < 3; i++) {
				if (opt[i] == xs->air_keys)
					continue;
				bb = *b;
				if (fly(s, m, &bb, opt[i], NULL)) {
					pick = opt[i];
					break;
				}
			}
		}
		xs->air_keys = pick;
		air_law(s, b, pick, keys, ori);
	}
	return 0;
}

/* --- drops ------------------------------------------------------------ */

static void drop_law(const nav_shot *s, const bc_body *b, uint8_t *keys, bc_v3 *ori)
{
	geom g = shot_geom(s);

	nav_law_steer(b, g.bx, g.by, 0, 1, keys, ori);
}

static int drop_sim(const nav_shot *s, const bc_map *m, const bc_body *b0, uint8_t *damage)
{
	bc_body bb = *b0;
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	uint8_t k;
	int t;

	for (t = 0; t < 300; t++) {
		int32_t dmg;

		drop_law(s, &bb, &k, &ori);
		dmg = bc_body_step(&bb, m, k, ori, BC_BODY_DT);
		if (dmg > 0) {
			if (dmg > (int32_t)s->max_damage)
				return 0;
			if (damage)
				*damage = (uint8_t)dmg;
		}
		if (nav_at(&bb, s->to) && nav_on_floor(&bb, s->to.z))
			return settles(s, m, &bb);
		if (!bb.airborne && bb.vel.z == 0.0f &&
		    bc_body_feet(&bb) > nav_rest(s->to.z) + 0.3f)
			return 0;       /* down, and lower than meant */
		/* (down on that level but a column on is not a failure: the
		 * law walks it back, and the loop's length is the limit) */
	}
	return 0;
}

int nav_drop_tick(const nav_shot *s, nav_xs *xs, const bc_body *b, const bc_map *m,
                  int tick, uint8_t *keys, bc_v3 *ori)
{
	if (nav_at(b, s->to) && nav_on_floor(b, s->to.z))
		return 1;
	if (on_or_above(b, s->from.z)) {
		/* still up: check (again, now and then: the body is not where
		 * it was) that walking off from here ends on the target */
		if (xs->phase == NAV_XS_INIT || (tick & 3) == 0) {
			uint8_t dmg = 0;

			if (!drop_sim(s, m, b, &dmg)) {
				nav_law_stop(b, keys, ori);
				return -BC_NAV_WHY_NO_DROP;
			}
			xs->damage = dmg;
		}
		xs->phase = NAV_XS_RUN;
	} else if (!b->airborne && b->vel.z == 0.0f &&
	           bc_body_feet(b) > nav_rest(s->to.z) + 0.3f) {
		/* down, and lower than meant */
		nav_law_stop(b, keys, ori);
		return -BC_NAV_WHY_NO_DROP;
	}
	drop_law(s, b, keys, ori);
	return 0;
}
