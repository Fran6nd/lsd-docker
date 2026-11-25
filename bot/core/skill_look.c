/* skill_look.c -- Where a bot looks while it travels
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * A bot walking a route with nothing to aim at used to have the
 * follower's facing for a head: it turned exactly as it steered, cell by
 * cell, which reads as a machine on rails. Then (2026-11-24) the head was
 * the aim model's on every plain stretch, at a point 6 blocks ahead along
 * the route, with a glance every 2 to 6 s of up to 1.5 s: measured on the
 * bench, the head was within 30 degrees of the way the body went only a
 * third to a half of the travelling time (corners re-triggered the aim
 * model's reaction delay at every turn of a route, and the glances were
 * long). The owner: "bots should look where they are headed more". So now
 * (2026-11-25), HEADING FIRST, glances the exception:
 *
 *  - ON THE HEADING: the follower's own facing, but turned to as a head
 *    turns (bc_look_heading: most of the error at once, eased, at most
 *    400 degrees a second, no reaction delay -- a walker does not "react"
 *    to his own path), and the keys re-expressed for that head. So no
 *    twitch cell by cell, and no lag of half a second at each corner.
 *  - GLANCES, short and fewer: one every 4.5 to 9 s by character and
 *    level, 0.6 of that when alert (a noise, a hit, a man lost, within the
 *    last 12 s; the first comes at once), lasting the head's reaction time,
 *    the turn there (at about 300 degrees a second) and 0.25 to 0.55 s
 *    to take it in, the aim model (aim.h) making the turn there
 *    and bc_look_heading the turn back. At the place most worth a look
 *    (where a noise came from, a man was lost, the enemy is expected), at
 *    an opening beside the route it is about to pass (a bearing 40 to 115
 *    degrees off the way it goes along which it can see 14 blocks, best
 *    after a wall: a corner), and over a shoulder rarely (more when alert).
 *  - Sight is the head's cone (senses.c reads the facing the server has),
 *    so a glance that falls on an enemy is how he gets seen.
 *
 * WHEN THE FOLLOWER KEEPS THE HEAD. nav.h's facing "is not a suggestion":
 * the follower simulated the move with it. With the head elsewhere the
 * engine re-expresses the follower's keys for the facing the head has
 * (8 ways, so up to 22 degrees off), which is harmless on open ground and
 * not on a ledge. nav.h has no "the head is free" flag, so it is decided
 * here, from the route:
 *    free      the step in hand and the next are plain strides (WALK,
 *              SPRINT, CROUCH, no edit, not into water) over cells with
 *              nothing to fall off beside them: each of the 8 columns
 *              round has a wall, or a floor at most one down;
 *    aligned   fewer than 4 such steps ahead: on the heading, no glance
 *              begun, so that when the follower takes it back there is
 *              nothing to snap;
 *    kept      fewer than 2: the follower's, as before.
 * A glance is only begun with 6 such steps ahead. (Wanted from nav: a
 * flag in bc_nav_cmd, "the facing is free this tick", and how many ticks
 * it will stay so -- the follower knows both better than this guess.)
 */
#include <math.h>
#include <string.h>

#include "brain.h"

enum { CLEAR_GLANCE = 6, CLEAR_FREE = 4, CLEAR_KEPT = 2 };

static int plain_step(const bc_nav_step *s)
{
	return (s->kind == BC_NAV_WALK || s->kind == BC_NAV_SPRINT || s->kind == BC_NAV_CROUCH) &&
	       !s->digs && !s->builds && !(s->flags & BC_NAV_F_WATER);
}

/* nothing to fall off, round a floor */
static int open_cell(const bc_map *m, bc_nav_node n)
{
	static const int8_t d[8][2] = { { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } };
	int z0 = n.z - 3 < 0 ? 0 : n.z - 3, z1 = n.z + 1 > 63 ? 63 : n.z + 1, k;
	uint64_t mask = (z1 >= 63 ? ~(uint64_t)0 : (((uint64_t)1 << (z1 + 1)) - 1)) & ~(((uint64_t)1 << z0) - 1);

	for (k = 0; k < 8; k++) {
		int x = n.x + d[k][0], y = n.y + d[k][1];

		if (x < 0 || y < 0 || x >= BC_MAP_X || y >= BC_MAP_Y)
			continue;
		if (!(bc_map_col(m, x, y) & mask) || bc_map_is_water(m, x, y))
			return 0;
	}
	return 1;
}

static int alert_now(const bc_bot *b)
{
	const bc_senses *s = &b->senses;
	double now = b->e->now, t = s->shot_at;

	if (s->noise.valid && s->noise.at > t) t = s->noise.at;
	if (s->threat.valid && s->threat.at > t) t = s->threat.at;
	if (s->lost.valid && s->lost.at > t) t = s->lost.at;
	if (s->last_sight > t) t = s->last_sight;
	return now - t < 12.0;
}

static double interval(bc_bot *b)
{
	const float *t = b->persona.trait;
	float ch = 0.55f + 0.25f * t[BC_T_CURIOSITY] + 0.20f * t[BC_T_CAUTION];
	float v = bc_rng_range(&b->rng, 4.5f, 9.0f);

	if (ch < 0.6f) ch = 0.6f;
	if (ch > 1.6f) ch = 1.6f;
	v = v / ch * (1.25f - 0.05f * (float)b->level);
	if (alert_now(b)) v *= 0.6f;
	return (double)v;
}

/* What to glance at. `probe` is where the eye will be in a moment. */
static int choose(bc_bot *b, float hx, float hy, bl_vec3 probe, bl_vec3 *out)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int alert = alert_now(b), have_place = 0, what = 0;
	float w_place, w_side = 2.0f, w_back = alert ? 0.6f : 0.15f, x;
	bl_vec3 place;

	if (bc_senses_search(&b->senses, &e->sense, e->now, &place, &what) || bc_enemy_area(b, &place)) {
		float dx = place.x - me->pos.x, dy = place.y - me->pos.y, l = sqrtf(dx * dx + dy * dy);

		/* not what it is walking at already */
		have_place = l > 4.0f && (dx * hx + dy * hy) / l < 0.82f;
	}
	w_place = !have_place ? 0.0f : (what >= 1 && what <= 3) ? 3.0f : 0.8f;
	x = bc_frand(b) * (w_place + w_side + w_back);
	if (x < w_place) {
		*out = place;
		b->gaze.kind = 1;
		return 1;
	}
	if (x < w_place + w_side) {
		static const float deg[4] = { 40.0f, 65.0f, 90.0f, 115.0f };
		float best = 0.0f, bx = 0.0f, by = 0.0f;
		int side, k;

		for (side = -1; side <= 1; side += 2) {
			int shut = 1;       /* the bearing before this one could not be seen along */

			for (k = 0; k < 4; k++) {
				float a = (float)side * deg[k] * 3.14159265f / 180.0f, ca = cosf(a), sa = sinf(a);
				float dx = hx * ca - hy * sa, dy = hx * sa + hy * ca, w;
				bl_vec3 far = probe;

				far.x += dx * 14.0f; far.y += dy * 14.0f;
				if (!bc_sight_clear(e->map, probe, far)) {
					shut = 1;
					continue;
				}
				/* an opening after a wall is a corner: worth more */
				w = (shut && k > 0 ? 2.0f : 1.0f) * (0.2f + bc_frand(b));
				shut = 0;
				if (w > best) { best = w; bx = dx; by = dy; }
			}
		}
		if (best > 0.0f) {
			*out = probe;
			out->x += bx * 20.0f; out->y += by * 20.0f;
			b->gaze.kind = 2;
			return 1;
		}
		if (bc_frand(b) > 0.5f)
			return 0;       /* walls on both sides: nothing to look at */
	}
	{
		float a = (bc_frand(b) < 0.5f ? -1.0f : 1.0f) * bc_rng_range(&b->rng, 2.1f, 2.9f);
		float ca = cosf(a), sa = sinf(a);

		*out = me->pos;
		out->x += (hx * ca - hy * sa) * 20.0f;
		out->y += (hx * sa + hy * ca) * 20.0f;
		b->gaze.kind = 3;
	}
	return 1;
}

static float wrap(float a)
{
	while (a > 3.14159265f) a -= 6.2831853f;
	while (a < -3.14159265f) a += 6.2831853f;
	return a;
}

bc_aim_v3 bc_look_heading(const bc_bot *b, bc_aim_v3 want, float dt)
{
	bc_aim_v3 cur = b->aim.ori, o;
	float cy = atan2f(cur.y, cur.x), cp = asinf(cur.z < -1.0f ? -1.0f : cur.z > 1.0f ? 1.0f : cur.z);
	float wy = atan2f(want.y, want.x), wp = asinf(want.z < -1.0f ? -1.0f : want.z > 1.0f ? 1.0f : want.z);
	float ey = wrap(wy - cy), ep = wp - cp, f = 1.0f - expf(-12.0f * dt), cap = 7.0f * dt;     /* 400 degrees a second */
	float sy = ey * f, sp = ep * f;

	if (!(cur.x == cur.x) || (cur.x == 0.0f && cur.y == 0.0f && cur.z == 0.0f))
		return want;
	if (sy > cap) sy = cap;
	if (sy < -cap) sy = -cap;
	if (fabsf(ey) < 0.02f) sy = ey;
	cy += sy;
	cp += sp;
	o.x = cosf(cy) * cosf(cp);
	o.y = sinf(cy) * cosf(cp);
	o.z = sinf(cp);
	return o;
}

int bc_look_travel(bc_bot *b, const bc_nav_cmd *cmd, bl_vec3 *at)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const bc_nav_route *r = &b->mv.route;
	bc_gaze *g = &b->gaze;
	float hl = sqrtf(cmd->ori.x * cmd->ori.x + cmd->ori.y * cmd->ori.y), hx, hy;
	int i = cmd->step, k, clear;
	bl_vec3 probe;

	if (i < 0 || i >= r->n || hl < 1e-4f || !e->have_map) {
		g->until = 0.0;
		return 0;
	}
	hx = cmd->ori.x / hl;
	hy = cmd->ori.y / hl;
	if (!open_cell(e->map, i > 0 ? r->steps[i - 1].to : r->start)) {
		g->until = 0.0;
		return 0;
	}
	for (k = i; k < r->n && k < i + CLEAR_GLANCE; k++)
		if (!plain_step(&r->steps[k]) || !open_cell(e->map, r->steps[k].to))
			break;
	clear = k == r->n ? CLEAR_GLANCE : k - i;
	if (clear < CLEAR_KEPT) {
		g->until = 0.0;
		return 0;
	}
	{
		/* SHOT AT, OR THE MAN WHO DID IT IN SIGHT: the head stays on him and
		 * the body goes where the route goes -- backwards or to the side
		 * (the keys follow the head) -- never its back to him, whatever it
		 * is doing (falling back, a duty that lies behind it). The man's
		 * place is the trees' `threat` (its senses: 8 s, kept where he is
		 * while it sees him). Not where a move needs the facing (a jump,
		 * an edit: above); and not for a man carrying the objective home:
		 * he runs for it, flat out -- backwards he could not sprint, and
		 * every man he faced would be a duel (carry_home: "it does not
		 * stop to duel") */
		bl_vec3 th;

		if (!bc_carrying(b) && bc_place_of(b, "threat", &th)) {
			g->until = 0.0;
			*at = th;
			return 1;
		}
	}
	if (clear < CLEAR_FREE) {
		/* a move that needs the facing is near: on the heading, so that
		 * when the follower takes it back there is nothing to snap */
		g->until = 0.0;
		return 2;
	}
	probe = me->pos;
	probe.x += hx * 3.0f;
	probe.y += hy * 3.0f;

	if (g->until > 0.0) {
		if (e->now < g->until) {
			*at = g->at;
			return 1;
		}
		g->until = 0.0;
		g->next_at = e->now + interval(b);
	}
	if (g->next_at == 0.0)
		g->next_at = e->now + (double)bc_rng_range(&b->rng, 1.5f, 4.0f);
	{
		/* something just happened: the next look does not wait its turn */
		int alert = alert_now(b);

		if (alert && !g->was_alert && g->next_at > e->now + 0.6)
			g->next_at = e->now + (double)(b->aim.tune.reaction_sec + bc_rng_range(&b->rng, 0.1f, 0.5f));
		g->was_alert = (uint8_t)alert;
	}
	if (e->now >= g->next_at && clear >= CLEAR_GLANCE) {
		if (choose(b, hx, hy, probe, &g->at)) {
			/* long enough to get there (the turn, at about 300 degrees
			 * a second) and take it in; no longer */
			float dx = g->at.x - me->pos.x, dy = g->at.y - me->pos.y, l = sqrtf(dx * dx + dy * dy);
			float turn = l > 1e-3f ? acosf(fmaxf(-1.0f, fminf(1.0f, (dx * hx + dy * hy) / l))) / 5.2f : 0.0f;

			g->until = e->now + (double)(b->aim.tune.reaction_sec + turn + bc_rng_range(&b->rng, 0.25f, 0.55f));
			g->glances++;
			e->stats.glances++;
			*at = g->at;
			return 1;
		}
		g->next_at = e->now + 0.5 * interval(b);
	}
	return 2;
}
