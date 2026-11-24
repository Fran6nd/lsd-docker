/* skill_look.c -- Where a bot looks while it travels
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * A bot walking a route with nothing to aim at used to have the
 * follower's facing for a head: it turned exactly as it steered, cell by
 * cell, which reads as a machine on rails. Here the head is its own on
 * every stretch where the facing is not needed to make the move:
 *
 *  - MOSTLY AHEAD, but a few blocks ahead along the ROUTE (6), not at the
 *    next cell: the head comes round a corner before the feet do, and
 *    does not twitch with each stride.
 *  - GLANCES, timed by character and level (one every 2 to 6 s) and more
 *    than twice as often when alert (a noise, a hit, a man lost, within
 *    the last 12 s; the first of them comes at once): at the place most
 *    worth a look (where a noise came from, where a man was lost, where
 *    the enemy is expected), at an opening beside the route it is about
 *    to pass (a bearing 40 to 115 degrees off the way it goes along which
 *    it can see 14 blocks, best where the bearing next to it is shut: a
 *    corner), and over a shoulder now and then. A glance lasts the head's
 *    own reaction time and 0.45 to 1 s more: the aim model (aim.h) makes
 *    the turn, so it is a person's turn.
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
 *    aligned   fewer than 4 such steps ahead: the head is still the aim
 *              model's but looks where the follower faces, so that when
 *              the follower takes it back there is nothing to snap;
 *    kept      fewer than 2: the follower's, as before.
 * A glance is only begun with 6 such steps ahead. (Wanted from nav: a
 * flag in bc_nav_cmd, "the facing is free this tick", and how many ticks
 * it will stay so -- the follower knows both better than this guess.)
 */
#include <math.h>
#include <string.h>

#include "brain.h"

enum { CLEAR_GLANCE = 6, CLEAR_FREE = 4, CLEAR_KEPT = 2 };
static const float AHEAD = 6.0f;

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

static float flat(bl_vec3 a, bl_vec3 b)
{
	float dx = a.x - b.x, dy = a.y - b.y;

	return sqrtf(dx * dx + dy * dy);
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
	float v = bc_rng_range(&b->rng, 2.2f, 5.5f);

	if (ch < 0.6f) ch = 0.6f;
	if (ch > 1.6f) ch = 1.6f;
	v = v / ch * (1.25f - 0.05f * (float)b->level);
	if (alert_now(b)) v *= 0.45f;
	return (double)v;
}

/* What to glance at. `probe` is where the eye will be in a moment. */
static int choose(bc_bot *b, float hx, float hy, bl_vec3 probe, bl_vec3 *out)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int alert = alert_now(b), have_place = 0, what = 0;
	float w_place, w_side = 2.0f, w_back = alert ? 0.9f : 0.35f, x;
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

int bc_look_travel(bc_bot *b, const bc_nav_cmd *cmd, bl_vec3 *at)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const bc_nav_route *r = &b->mv.route;
	bc_gaze *g = &b->gaze;
	float hl = sqrtf(cmd->ori.x * cmd->ori.x + cmd->ori.y * cmd->ori.y), hx, hy;
	int i = cmd->step, k, clear;
	bl_vec3 ahead, probe;

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
	if (clear < CLEAR_FREE) {
		/* a move that needs the facing is near: look where the follower does */
		g->until = 0.0;
		*at = me->pos;
		at->x += hx * 8.0f;
		at->y += hy * 8.0f;
		return 1;
	}

	/* ahead: the first cell of the route that far off */
	for (k = i; k < r->n; k++) {
		ahead.x = (float)r->steps[k].to.x + 0.5f;
		ahead.y = (float)r->steps[k].to.y + 0.5f;
		ahead.z = (float)r->steps[k].to.z - 2.25f;
		if (flat(ahead, me->pos) >= AHEAD)
			break;
	}
	probe = me->pos;
	probe.x += hx * 3.0f;
	probe.y += hy * 3.0f;
	if (k >= r->n && flat(ahead, me->pos) < 2.5f) {
		ahead = me->pos;        /* nearly there: not at its own feet */
		ahead.x += hx * AHEAD;
		ahead.y += hy * AHEAD;
	}

	if (g->until > 0.0) {
		if (e->now < g->until) {
			*at = g->at;
			return 1;
		}
		g->until = 0.0;
		g->next_at = e->now + interval(b);
	}
	if (g->next_at == 0.0)
		g->next_at = e->now + (double)bc_rng_range(&b->rng, 0.6f, 2.5f);
	{
		/* something just happened: the next look does not wait its turn */
		int alert = alert_now(b);

		if (alert && !g->was_alert && g->next_at > e->now + 0.6)
			g->next_at = e->now + (double)(b->aim.tune.reaction_sec + bc_rng_range(&b->rng, 0.1f, 0.5f));
		g->was_alert = (uint8_t)alert;
	}
	if (e->now >= g->next_at && clear >= CLEAR_GLANCE) {
		if (choose(b, hx, hy, probe, &g->at)) {
			g->until = e->now + (double)(b->aim.tune.reaction_sec + bc_rng_range(&b->rng, 0.45f, 1.0f));
			g->glances++;
			e->stats.glances++;
			*at = g->at;
			return 1;
		}
		g->next_at = e->now + 0.5 * interval(b);
	}
	*at = ahead;
	return 1;
}
