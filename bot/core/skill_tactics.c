/* skill_tactics.c -- What a bot does when nothing is in sight
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * New here. With nobody in sight a bot used to roam, and a team of twelve
 * walked the same line. These are the alternatives a tree picks among,
 * each a skill that ENDS (so the pick moves on), and what they share:
 *
 *  - WHERE THE ENEMY IS EXPECTED (bc_enemy_area): where the team last met
 *    him, if under a minute ago; else his base.
 *  - seek: to the enemy's base by the direct route -- the last resort of
 *    a tree, what a bot does rather than wander. There and nobody: on to
 *    where the team last met him, then back toward its own side of the
 *    map, and round again. A world with no bases, or a base there is no
 *    way to: roam.
 *  - flank: the same place the long way round. Two waypoints -- one
 *    abeam of the middle of the direct line, off it by half its length
 *    (30 to 90), one beyond the place on the same side -- then the place
 *    itself, so it is come at from behind. The side: the one with more
 *    to hide behind and fewer of the team's bad places, by the bot's own
 *    dice (a side is twice as likely per point of that). Routes while
 *    flanking pay to cross the middle (a danger circle on the direct
 *    line: nav's own weights), so the legs bulge and do not cut back.
 *  - hunt_noise: to the freshest RUMOUR of the enemy: a noise it heard
 *    (kept 30 s here), a team-mate's sighting on the board (30 s), where
 *    the team last met him (60 s). The careful take the nearest, the
 *    keen the most recent.
 *  - take_high_ground, camp: a PERCH is a floor at least 3 voxels above
 *    the ground 8 round it, from which 3 of 5 rays toward where the
 *    enemy is expected run 48 voxels clear, that a body can get up to
 *    (a flood back down from it over steps a body can climb reaches open
 *    ground), at least a quarter of the way from the team's base to the
 *    enemy's. They are found by a scan of the box round the two bases,
 *    one column in three each way, 24 columns a think (bc_tactics_think),
 *    kept per team (16), found again when the enemy's area moves 60
 *    voxels or after 3 minutes. A bot CLAIMS one (the team's board: two
 *    do not take the same); camp stays on it, crouched, sweeping the arc
 *    toward the enemy, firing at what appears, and leaves it after two
 *    kills, when it is shot at, or when its patience is out (25 to 120 s
 *    by caution and marksmanship) -- and takes another next time.
 *  - leave_water: out of water that hurts, to the nearest dry floor.
 *  - A TEAM'S MEMORY OF WHAT CANNOT BE REACHED (bc_unreach_*): a goal a
 *    plan found no way to, or the follower gave up on, or the watchdog
 *    dropped, is remembered with about where it was tried from, 30 s.
 *    bc_move_to answers FAILED at once for such a goal (within 5) asked
 *    for from about there (within 24) by a bot whose routes may do the
 *    same things -- so the search that floods the whole map to prove
 *    there is no way is run once, not once a bot.
 */
#include <math.h>
#include <string.h>

#include "brain.h"

static float flat(bl_vec3 a, bl_vec3 b)
{
	float dx = a.x - b.x, dy = a.y - b.y;

	return sqrtf(dx * dx + dy * dy);
}

static float clampf(float v, float lo, float hi)
{
	return v < lo ? lo : v > hi ? hi : v;
}

static bl_vec3 eye_of(bc_nav_node n)
{
	bl_vec3 p;

	p.x = (float)n.x + 0.5f; p.y = (float)n.y + 0.5f; p.z = (float)n.z - 2.25f;
	return p;
}

/* A place to stand near a point, dry: 1 and `out` (an eye). */
static int stand_near(const bc_bot *b, float x, float y, float z, int radius, bl_vec3 *out)
{
	const bc_engine *e = b->e;
	bc_nav_node n;

	x = clampf(x, 3.0f, 508.0f);
	y = clampf(y, 3.0f, 508.0f);
	if (!e->have_map || !bc_nav_snap(e->map, (int)x, (int)y, (int)floorf(z + 2.75f), radius, &n) ||
	    bc_map_is_water(e->map, n.x, n.y))
		return 0;
	*out = eye_of(n);
	return 1;
}

/* --- what cannot be reached --------------------------------------------- */

static uint8_t caps_of(const bc_bot *b)
{
	const bc_engine *e = b->e;
	int dig = e->may_dig, build = e->may_build;

	if (b->edit >= 0) { dig = b->edit & 1; build = (b->edit >> 1) & 1; }
	return (uint8_t)(dig | (build << 1));
}

void bc_unreach_note(bc_bot *b, bc_nav_node from, bc_nav_node to)
{
	bc_engine *e = b->e;
	int team = bc_me(b)->team, i, old = 0;
	bc_unreach *u;

	if (team < 1 || team > 2)
		return;
	u = e->unreach[team - 1];
	for (i = 1; i < BC_UNREACH_MAX; i++)
		if (u[i].until < u[old].until) old = i;
	u[old].from = from;
	u[old].to = to;
	u[old].until = e->now + 30.0;
	u[old].caps = caps_of(b);
}

double bc_unreach_until(bc_bot *b, bc_nav_node from, bc_nav_node to)
{
	bc_engine *e = b->e;
	int team = bc_me(b)->team, i;
	uint8_t caps = caps_of(b);

	if (team < 1 || team > 2)
		return 0.0;
	for (i = 0; i < BC_UNREACH_MAX; i++) {
		const bc_unreach *u = &e->unreach[team - 1][i];
		int dx, dy;

		if (u->until <= e->now || u->caps != caps)
			continue;
		dx = u->to.x - to.x; dy = u->to.y - to.y;
		if (dx * dx + dy * dy > 5 * 5 || u->to.z - to.z > 2 || to.z - u->to.z > 2)
			continue;
		dx = u->from.x - from.x; dy = u->from.y - from.y;
		if (dx * dx + dy * dy > 24 * 24)
			continue;
		e->stats.unreach_hits++;
		return u->until;
	}
	return 0.0;
}

/* --- where the enemy is ------------------------------------------------- */

int bc_enemy_area(bc_bot *b, bl_vec3 *out)
{
	bc_engine *e = b->e;
	int team = bc_me(b)->team;

	if (team < 1 || team > 2)
		return 0;
	if (e->now - e->hot_at[team - 1] < 60.0) {
		*out = e->hot[team - 1];
		return 1;
	}
	if (e->w.tent[2 - team].present) {
		*out = e->w.tent[2 - team].pos;
		return 1;
	}
	return 0;
}

float bc_rumour(bc_bot *b, bl_vec3 *out)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const bc_senses *s = &b->senses;
	const float *t = b->persona.trait;
	/* the keen go for the newest, the careful for the nearest */
	float w_age = 0.6f + 0.4f * t[BC_T_AGGRESSION], w_far = 0.3f + 0.5f * t[BC_T_CAUTION];
	float best = -1e30f, fresh = 0.0f;
	int team = me->team, i;

#define RUMOUR(pos_, age_, life_) do { \
		float age__ = (float)(age_), f__ = 1.0f - age__ / (life_), d__ = flat((pos_), me->pos), v__; \
		if (f__ > 0.0f && d__ > 10.0f && \
		    !(e->now < b->hunt.done_until && flat((pos_), b->hunt.done_pos) < 14.0f)) { \
			v__ = w_age * f__ - w_far * d__ / 100.0f; \
			if (v__ > best) { best = v__; fresh = f__; if (out) *out = (pos_); } \
		} \
	} while (0)

	if (s->noise.valid)
		RUMOUR(s->noise.pos, e->now - s->noise.at, 30.0f);
	if (s->lost.valid)
		RUMOUR(s->lost.pos, e->now - s->lost.at, 30.0f);
	if (team >= 1 && team <= 2) {
		for (i = 0; i < BL_MAX_PLAYERS; i++) {
			const bc_spot *sp = &e->board.spot[team - 1][i];

			if (sp->at < 0.0 || e->now - sp->since < (double)e->sense.relay ||
			    e->w.players[i].state != BL_ALIVE)
				continue;
			RUMOUR(sp->pos, e->now - sp->at, 30.0f);
		}
		if (e->hot_at[team - 1] > -1e8)
			RUMOUR(e->hot[team - 1], e->now - e->hot_at[team - 1], 60.0f);
	}
#undef RUMOUR
	return fresh < 0.0f ? 0.0f : fresh;
}

/* --- seek ----------------------------------------------------------------- */

/* the roam of skill_misc.c, for a world where there is nothing to seek */
bt_status bc_do_roam(void *bot, const bt_args *a, float dt);

bt_status bc_do_seek(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int team = me->team, st, tries;
	bl_vec3 p, own, his;

	if (team < 1 || team > 2 || !e->w.tent[2 - team].present || e->now < b->seek.roam_until)
		return bc_do_roam(bot, a, dt);
	his = e->w.tent[2 - team].pos;
	own = e->w.tent[team - 1].present ? e->w.tent[team - 1].pos : me->pos;
	for (tries = 0; tries < 3; tries++) {
		int ok = 1;

		switch (b->seek.leg % 3) {
		case 0:
			p = his;
			break;
		case 1:         /* where the team last met him, if that is somewhere else */
			ok = e->now - e->hot_at[team - 1] < 60.0 && flat(e->hot[team - 1], his) > 20.0f;
			p = e->hot[team - 1];
			break;
		default:        /* back toward its own side, as far as the middle */
			p.x = his.x + (own.x - his.x) * 0.5f;
			p.y = his.y + (own.y - his.y) * 0.5f;
			p.z = me->pos.z;
			ok = e->w.tent[team - 1].present && stand_near(b, p.x, p.y, p.z, 8, &p);
			break;
		}
		if (ok && flat(p, me->pos) > 8.0f)
			break;
		b->seek.leg++;      /* there already, or no such place: the next */
		b->seek.leg_since = e->now;
	}
	if (tries == 3)
		return bc_do_roam(bot, a, dt);
	if (b->seek.leg_since == 0.0)
		b->seek.leg_since = e->now;
	if (b->mv.goal_set && b->mv.state != BC_MV_IDLE && flat(b->wish.goal, p) < 3.0f)
		p = b->wish.goal;
	st = bc_move_to(b, p, 4.0f);
	bc_fire_at_will(b);
	if (st == BC_MV_ARRIVED) {
		b->seek.leg++;
		b->seek.fails = 0;
		b->seek.leg_since = e->now;
	} else if (st == BC_MV_FAILED) {
		b->seek.leg++;
		b->seek.leg_since = e->now;
		if (++b->seek.fails >= 3) {
			/* no way to any of it: wander, and try again in a while */
			b->seek.fails = 0;
			b->seek.roam_until = e->now + 20.0;
		}
	}
	return BT_RUNNING;
}

/* --- flank [place] -------------------------------------------------------- */

int bc_flank_open(bc_bot *b)
{
	bl_vec3 t;

	return b->e->now >= b->flank.cd_until && !bc_in_harmful_water(b) && bc_enemy_area(b, &t) &&
	       flat(t, bc_me(b)->pos) > 45.0f;
}

/* how good a side is to go round by: things to hide behind along it, less
 * the team's bad places near it */
static float side_worth(bc_bot *b, bl_vec3 from, bl_vec3 w1, bl_vec3 w2)
{
	bc_engine *e = b->e;
	int team = bc_me(b)->team, i, k;
	float worth = 0.0f;

	for (i = 1; i <= 8; i++) {
		float f = (float)i / 8.0f;
		bl_vec3 a = i <= 4 ? from : w1, c = i <= 4 ? w1 : w2, p;
		float g = i <= 4 ? f * 2.0f : f * 2.0f - 1.0f;
		int x, y, z, hid = 0;

		p.x = a.x + (c.x - a.x) * g; p.y = a.y + (c.y - a.y) * g;
		x = (int)p.x; y = (int)p.y;
		z = bc_map_floor_at_or_below(e->map, x, y, 0);
		/* something a body's height or more within two columns */
		for (k = 0; k < 4 && !hid; k++) {
			static const int8_t d[4][2] = { { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 } };
			int zz = bc_map_floor_at_or_below(e->map, x + d[k][0], y + d[k][1], 0);

			hid = zz <= z - 3;
		}
		worth += hid ? 0.25f : 0.0f;
		if (bc_map_is_water(e->map, x, y))
			worth -= 0.5f;
		if (team >= 1 && team <= 2)
			for (k = 0; k < BC_DANGER_MAX; k++)
				if (e->now - e->danger_at[team - 1][k] < 35.0) {
					float dx = e->danger[team - 1][k].x - p.x, dy = e->danger[team - 1][k].y - p.y;

					if (dx * dx + dy * dy < 20.0f * 20.0f)
						worth -= 0.3f;
				}
	}
	return worth;
}

static int flank_points(bc_bot *b, bl_vec3 target, int side, float scale, bl_vec3 w[2])
{
	const bl_player *me = bc_me(b);
	float dx = target.x - me->pos.x, dy = target.y - me->pos.y, l = sqrtf(dx * dx + dy * dy);
	float off = clampf(0.5f * l, 30.0f, 90.0f) * scale, ux, uy, px, py;

	if (l < 1.0f)
		return 0;
	ux = dx / l; uy = dy / l;
	px = -uy * (float)side; py = ux * (float)side;
	if (!stand_near(b, me->pos.x + ux * 0.5f * l + px * off, me->pos.y + uy * 0.5f * l + py * off, me->pos.z, 10, &w[0]))
		return 0;
	if (!stand_near(b, target.x + ux * clampf(0.25f * l, 12.0f, 28.0f) + px * 0.35f * off,
	                target.y + uy * clampf(0.25f * l, 12.0f, 28.0f) + py * 0.35f * off, target.z, 10, &w[1]))
		return 0;
	return 1;
}

bt_status bc_do_flank(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int st;

	(void)dt;
	if (bc_in_harmful_water(b)) {
		b->flank.phase = 0;
		b->flank.avoid_on = 0;
		return BT_FAILURE;
	}
	if (b->flank.phase == 0) {
		bl_vec3 target, w[2][2];
		float worth[2] = { 0.0f, 0.0f }, scale, p_right;
		int ok[2] = { 0, 0 }, s;

		if (e->now < b->flank.cd_until)
			return BT_FAILURE;
		if (a->count > 0 ? !bc_place_of(b, a->text[0], &target) : !bc_enemy_area(b, &target))
			return BT_FAILURE;
		if (flat(target, me->pos) < 30.0f) {
			b->flank.cd_until = e->now + 15.0;
			return BT_FAILURE;      /* too near to go round */
		}
		for (scale = 1.0f; scale > 0.4f && !ok[0] && !ok[1]; scale *= 0.6f)
			for (s = 0; s < 2; s++) {
				ok[s] = flank_points(b, target, s ? 1 : -1, scale, w[s]);
				if (ok[s]) worth[s] = side_worth(b, me->pos, w[s][0], w[s][1]);
			}
		if (!ok[0] && !ok[1]) {
			b->flank.cd_until = e->now + 30.0;
			return BT_FAILURE;      /* no ground either side */
		}
		/* twice as likely a point of worth; the bot's own leaning breaks a tie */
		p_right = 1.0f / (1.0f + powf(2.0f, worth[0] - worth[1] - 0.3f * (float)b->flank_side));
		s = !ok[1] ? 0 : !ok[0] ? 1 : bc_frand(b) < p_right;
		/* broken off for a fight and taken up again: the same way round */
		if (e->now < b->flank.side_until && ok[b->flank.side > 0])
			s = b->flank.side > 0;
		b->flank.side_until = e->now + 60.0;
		b->flank.side = (int8_t)(s ? 1 : -1);
		b->flank.w[0] = w[s][0];
		b->flank.w[1] = w[s][1];
		b->flank.w[2] = target;
		b->flank.phase = 1;
		b->flank.tries = 0;
		b->flank.leg_since = e->now;
		/* not through the middle: routes pay to cross the direct line */
		b->flank.avoid.x = 0.5f * (me->pos.x + target.x);
		b->flank.avoid.y = 0.5f * (me->pos.y + target.y);
		b->flank.avoid.radius = clampf(0.35f * flat(me->pos, target), 12.0f, 60.0f);
		b->flank.avoid.weight = 2.5f;
	}
	b->flank.avoid_on = 1;
	st = bc_move_to(b, b->flank.w[b->flank.phase - 1], b->flank.phase == 3 ? 5.0f : 4.0f);
	bc_fire_at_will(b);
	if (st == BC_MV_ARRIVED || (st == BC_MV_FAILED && b->flank.phase < 3) ||
	    (b->flank.phase < 3 && e->now - b->flank.leg_since > 90.0)) {
		/* a waypoint there is no way to is skipped: the next one still
		 * brings it round */
		if (st == BC_MV_FAILED && ++b->flank.tries >= 2)
			goto fail;
		b->flank.leg_since = e->now;
		if (++b->flank.phase > 3) {
			b->flank.phase = 0;
			b->flank.avoid_on = 0;
			b->flank.cd_until = e->now + 30.0;
			return BT_SUCCESS;
		}
	} else if (st == BC_MV_FAILED) {
		goto fail;
	}
	return BT_RUNNING;
fail:
	b->flank.phase = 0;
	b->flank.avoid_on = 0;
	b->flank.cd_until = e->now + 40.0;
	return BT_FAILURE;
}

/* --- hunt_noise ----------------------------------------------------------- */

bt_status bc_do_hunt_noise(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int st;

	(void)a; (void)dt;
	if (b->hunt.phase == 0) {
		if (e->now < b->hunt.cd_until || bc_rumour(b, &b->hunt.place) <= 0.0f)
			return BT_FAILURE;
		b->hunt.phase = 1;
	}
	st = bc_move_to(b, b->hunt.place, 4.0f);
	bc_fire_at_will(b);
	if (st == BC_MV_ARRIVED || st == BC_MV_FAILED ||
	    (flat(me->pos, b->hunt.place) < 8.0f && bc_sight_clear(e->map, me->pos, b->hunt.place))) {
		/* looked (or no way): that rumour is done with */
		b->hunt.phase = 0;
		b->hunt.done_pos = b->hunt.place;
		b->hunt.done_until = e->now + 30.0;
		if (b->senses.noise.valid && flat(b->senses.noise.pos, b->hunt.place) < 6.0f)
			b->senses.noise.valid = 0;
		if (st == BC_MV_FAILED) {
			b->hunt.cd_until = e->now + 10.0;
			return BT_FAILURE;
		}
		return BT_SUCCESS;
	}
	return BT_RUNNING;
}

/* --- perches -------------------------------------------------------------- */

void bc_tactics_map(bc_engine *e)
{
	memset(e->unreach, 0, sizeof e->unreach);
	memset(e->vantage, 0, sizeof e->vantage);
	memset(e->visit, 0, sizeof e->visit);
}

void bc_tactics_bot_gone(bc_bot *b)
{
	bc_engine *e = b->e;
	int t, i;

	for (t = 0; t < 2; t++)
		for (i = 0; i < BC_PERCH_MAX; i++)
			if (e->vantage[t].p[i].valid && e->vantage[t].p[i].claim == (int16_t)b->pid)
				e->vantage[t].p[i].claim = -1;
	b->camp.perch = -1;
	b->camp.camping = 0;
}

static int top_floor(const bc_map *m, int x, int y)
{
	uint64_t st = bc_map_stand_mask(m, x, y);

	return st ? bc_ctz64(st) : 64;
}

/* Can a body get up there? A flood back down from the perch over steps a
 * body can take upward (two voxels: a jump) must come out on open ground:
 * 20 columns away, or 300 cells. */
static int perch_reachable(const bc_map *m, bc_nav_node top)
{
	enum { W = 41, R = 20, QN = 320 };
	static const int8_t nb[4][2] = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } };
	uint8_t q[QN][3];
	uint64_t seen[(W * W + 63) / 64];
	int head = 0, tail = 0, k;

	memset(seen, 0, sizeof seen);
	q[tail][0] = R; q[tail][1] = R; q[tail][2] = (uint8_t)top.z; tail++;
	seen[(R * W + R) >> 6] |= (uint64_t)1 << ((R * W + R) & 63);
	while (head < tail) {
		int dx = q[head][0] - R, dy = q[head][1] - R, z = q[head][2];

		head++;
		for (k = 0; k < 4; k++) {
			int ex = dx + nb[k][0], ey = dy + nb[k][1], i, zz, fz = -1;
			uint64_t st;

			if (ex < -R || ex > R || ey < -R || ey > R)
				return 1;       /* far enough from it: the open */
			i = (ey + R) * W + ex + R;
			if ((seen[i >> 6] >> (i & 63)) & 1)
				continue;
			if (bc_map_is_water(m, top.x + ex, top.y + ey))
				continue;
			/* a floor from which the one in hand is at most two up, and
			 * not more than six below it (a way up need not be a way down) */
			st = bc_map_stand_mask(m, top.x + ex, top.y + ey);
			for (zz = z - 6 < 1 ? 1 : z - 6; zz <= z + 2 && zz <= BC_MAP_GROUND_Z; zz++)
				if ((st >> zz) & 1) { fz = zz; if (zz >= z - 1) break; }
			if (fz < 0)
				continue;
			seen[i >> 6] |= (uint64_t)1 << (i & 63);
			if (tail >= QN)
				return 1;
			q[tail][0] = (uint8_t)(ex + R); q[tail][1] = (uint8_t)(ey + R); q[tail][2] = (uint8_t)fz;
			tail++;
		}
	}
	return 0;
}

static void perch_offer(bc_vantage *v, bc_nav_node n, float score)
{
	int i, worst = -1;

	for (i = 0; i < BC_PERCH_MAX; i++) {
		bc_perch *p = &v->p[i];
		int dx, dy;

		if (!p->valid) {
			if (worst < 0 || v->p[worst].valid) worst = i;
			continue;
		}
		dx = p->n.x - n.x; dy = p->n.y - n.y;
		if (dx * dx + dy * dy < 7 * 7) {
			/* one perch a place: the better of the two */
			if (score > p->score && p->claim < 0) { p->n = n; p->score = score; }
			return;
		}
		if (worst < 0 || (v->p[worst].valid && p->score < v->p[worst].score && p->claim < 0)) worst = i;
	}
	if (worst < 0 || (v->p[worst].valid && (v->p[worst].score >= score || v->p[worst].claim >= 0)))
		return;
	memset(&v->p[worst], 0, sizeof v->p[worst]);
	v->p[worst].n = n;
	v->p[worst].score = score;
	v->p[worst].claim = -1;
	v->p[worst].valid = 1;
}

static void perch_look(bc_engine *e, int team, int x, int y)
{
	static const int8_t ring[8][2] = { { 8, 0 }, { 6, 6 }, { 0, 8 }, { -6, 6 }, { -8, 0 }, { -6, -6 }, { 0, -8 }, { 6, -6 } };
	bc_vantage *v = &e->vantage[team];
	const bc_map *m = e->map;
	int z = top_floor(m, x, y), k, n = 0, clear = 0;
	float round = 0.0f, adv, dx, dy, l, t, bx, by, bl;
	bc_nav_node node;
	bl_vec3 eye;

	e->stats.perch_columns++;
	if (z > BC_MAP_GROUND_Z - 1 || z < 3 || bc_map_is_water(m, x, y))
		return;
	for (k = 0; k < 8; k++) {
		int zz = top_floor(m, x + ring[k][0], y + ring[k][1]);

		if (zz > 63) zz = 63;
		round += (float)zz;
		n++;
	}
	adv = round / (float)n - (float)z;
	if (adv < 3.0f)
		return;
	/* on the enemy's side of its own base, short of his */
	bx = v->toward.x - v->from.x; by = v->toward.y - v->from.y;
	bl = bx * bx + by * by;
	t = bl > 1.0f ? (((float)x - v->from.x) * bx + ((float)y - v->from.y) * by) / bl : 0.5f;
	if (t < 0.25f || t > 0.9f)
		return;
	node.x = (int16_t)x; node.y = (int16_t)y; node.z = (int16_t)z;
	eye = eye_of(node);
	dx = v->toward.x - eye.x; dy = v->toward.y - eye.y;
	l = sqrtf(dx * dx + dy * dy);
	if (l < 25.0f)
		return;
	for (k = -2; k <= 2; k++) {
		float a = (float)k * 0.26f, ca = cosf(a), sa = sinf(a), reach = l < 48.0f ? l : 48.0f;
		bl_vec3 far;

		far.x = eye.x + (dx * ca - dy * sa) / l * reach;
		far.y = eye.y + (dx * sa + dy * ca) / l * reach;
		far.z = eye.z + adv;        /* down at the ground out there */
		clear += bc_sight_clear(m, eye, far);
	}
	if (clear < 3 || !perch_reachable(m, node))
		return;
	perch_offer(v, node, 2.0f * (adv > 10.0f ? 10.0f : adv) + 3.0f * (float)clear);
}

void bc_tactics_think(bc_engine *e)
{
	int team, budget;

	if (!e->have_world || !e->have_map)
		return;
	for (team = 0; team < 2; team++) {
		bc_vantage *v = &e->vantage[team];
		bl_vec3 from, toward;
		int w, h, any = 0, i;

		if (!e->w.tent[team].present || !e->w.tent[1 - team].present)
			continue;
		for (i = 0; i < e->max_bots && !any; i++)
			any = e->bots[i].used && e->w.players[e->bots[i].pid].team == team + 1;
		if (!any)
			continue;
		from = e->w.tent[team].pos;
		toward = e->w.tent[1 - team].pos;
		if (!v->started || v->map_seq != e->map_seq ||
		    (v->done && (e->now - v->done_at > 180.0 || flat(toward, v->toward) > 60.0f ||
		                 flat(from, v->from) > 60.0f))) {
			/* a new scan; the perches found stand until better ones come */
			if (v->map_seq != e->map_seq || !v->started)
				memset(v->p, 0, sizeof v->p);
			v->started = 1;
			v->done = 0;
			v->k = 0;
			v->map_seq = e->map_seq;
			v->from = from;
			v->toward = toward;
			v->x0 = (int16_t)clampf((from.x < toward.x ? from.x : toward.x) - 48.0f, 4.0f, 507.0f);
			v->x1 = (int16_t)clampf((from.x > toward.x ? from.x : toward.x) + 48.0f, 4.0f, 507.0f);
			v->y0 = (int16_t)clampf((from.y < toward.y ? from.y : toward.y) - 48.0f, 4.0f, 507.0f);
			v->y1 = (int16_t)clampf((from.y > toward.y ? from.y : toward.y) + 48.0f, 4.0f, 507.0f);
		}
		if (v->done)
			continue;
		w = (v->x1 - v->x0) / 3 + 1;
		h = (v->y1 - v->y0) / 3 + 1;
		for (budget = 24; budget > 0; budget--) {
			if (v->k >= (uint32_t)(w * h)) {
				v->done = 1;
				v->done_at = e->now;
				break;
			}
			perch_look(e, team, v->x0 + (int)(v->k % (uint32_t)w) * 3, v->y0 + (int)(v->k / (uint32_t)w) * 3);
			v->k++;
		}
	}
}

int bc_perch_pick(bc_bot *b, int claim)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int team = me->team, i, best = -1;
	float bs = -1e30f, ideal = me->gun == BL_GUN_RIFLE ? 75.0f : 45.0f;
	bc_vantage *v;
	bl_vec3 area;

	if (team < 1 || team > 2)
		return -1;
	v = &e->vantage[team - 1];
	if (!bc_enemy_area(b, &area))
		area = v->toward;
	for (i = 0; i < BC_PERCH_MAX; i++) {
		bc_perch *p = &v->p[i];
		bl_vec3 eye;
		float s;

		if (!p->valid || e->now < p->bad_until || i == b->camp.avoid)
			continue;
		if (p->claim >= 0 && p->claim != (int16_t)b->pid && e->now < p->claim_until)
			continue;
		eye = eye_of(p->n);
		if (flat(eye, me->pos) > 160.0f)
			continue;
		if (i == b->camp.perch) { best = i; break; }       /* the one it has */
		s = p->score - 0.15f * fabsf(flat(eye, area) - ideal) - 0.05f * flat(eye, me->pos);
		if (s > bs) { bs = s; best = i; }
	}
	if (best >= 0 && claim) {
		v->p[best].claim = (int16_t)b->pid;
		v->p[best].claim_until = e->now + 45.0;
		if (b->camp.perch != best) {
			b->camp.perch = (int8_t)best;
			b->camp.camping = 0;
		}
	}
	return best;
}

static bc_perch *my_perch(bc_bot *b)
{
	int team = bc_me(b)->team;
	bc_perch *p;

	if (team < 1 || team > 2 || b->camp.perch < 0)
		return NULL;
	p = &b->e->vantage[team - 1].p[b->camp.perch];
	return p->valid && p->claim == (int16_t)b->pid ? p : NULL;
}

static void perch_leave(bc_bot *b, int avoid)
{
	bc_perch *p = my_perch(b);

	if (p) p->claim = -1;
	if (avoid) b->camp.avoid = b->camp.perch;
	b->camp.perch = -1;
	b->camp.camping = 0;
}

bt_status bc_do_take_high_ground(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	bc_perch *p;
	int st;

	(void)a; (void)dt;
	if (e->now < b->camp.cd_until || bc_in_harmful_water(b))
		return BT_FAILURE;
	if (bc_perch_pick(b, 1) < 0 || !(p = my_perch(b)))
		return BT_FAILURE;
	st = bc_move_to(b, eye_of(p->n), 0.0f);
	bc_fire_at_will(b);
	if (st == BC_MV_FAILED) {
		p->bad_until = e->now + 120.0;      /* no way up after all */
		perch_leave(b, 1);
		b->camp.cd_until = e->now + 8.0;
		return BT_FAILURE;
	}
	return st == BC_MV_ARRIVED ? BT_SUCCESS : BT_RUNNING;
}

/* --- camp [secs] ---------------------------------------------------------- */

bt_status bc_do_camp(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const float *t = b->persona.trait;
	bc_perch *p = my_perch(b);
	bl_vec3 area;

	(void)dt;
	if (bc_in_harmful_water(b)) {
		perch_leave(b, 0);
		return BT_FAILURE;
	}
	if (!b->camp.camping) {
		float patience = a->count > 0 && a->num[0] > 0.0f ? a->num[0]
		                 : clampf(20.0f + 30.0f * t[BC_T_CAUTION] * t[BC_T_MARKSMAN], 25.0f, 120.0f);

		b->camp.camping = 1;
		b->camp.since = e->now;
		b->camp.kills0 = b->kills;
		b->camp.patience_until = e->now + (double)(patience * bc_rng_range(&b->rng, 0.8f, 1.2f));
	}
	if (p) p->claim_until = e->now + 45.0;
	/* found, done enough here, or bored: somewhere else next */
	if (b->senses.shot_at > b->camp.since || b->kills >= b->camp.kills0 + 2 || e->now >= b->camp.patience_until) {
		perch_leave(b, 1);
		b->camp.cd_until = e->now + 6.0;
		return BT_SUCCESS;
	}
	b->wish.move = BC_MOVE_NONE;
	b->wish.crouch = 1;
	bc_fire_at_will(b);
	if (b->wish.look == BC_LOOK_AHEAD && bc_enemy_area(b, &area) && flat(area, me->pos) > 4.0f) {
		/* the arc toward where he is expected, swept as a man's eyes do:
		 * 40 degrees either side, a sweep in 9 s, and a look at a noise */
		float yaw = atan2f(area.y - me->pos.y, area.x - me->pos.x) +
		            0.7f * sinf(0.7f * (float)fmod(e->now, 1000.0) + b->sweep_phase);
		bl_vec3 n;

		b->wish.look = BC_LOOK_POINT;
		if (bc_senses_search(&b->senses, &e->sense, e->now, &n, NULL) && fmod(e->now + (double)b->sweep_phase, 6.0) < 2.0) {
			b->wish.look_at = n;
		} else {
			b->wish.look_at.x = me->pos.x + cosf(yaw) * 30.0f;
			b->wish.look_at.y = me->pos.y + sinf(yaw) * 30.0f;
			b->wish.look_at.z = me->pos.z + (p ? 3.0f : 0.0f);
		}
	}
	return BT_RUNNING;
}

/* --- leave_water ---------------------------------------------------------- */

bt_status bc_do_leave_water(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int st;

	(void)a; (void)dt;
	if (!e->have_map)
		return BT_FAILURE;
	if (!(me->flags & BL_F_WADING) && !bc_map_is_water(e->map, (int)floorf(me->pos.x), (int)floorf(me->pos.y))) {
		b->dry.until = 0.0;
		b->dry.tries = 0;
		return BT_SUCCESS;
	}
	if (e->now < b->dry.cd_until)
		return BT_FAILURE;      /* it tried: there is no way out of this water near */
	if (e->now >= b->dry.until) {
		/* the nearest dry floor, ring by ring, but not one already found
		 * to have no way up to it */
		int cx = (int)floorf(me->pos.x), cy = (int)floorf(me->pos.y), r, k, found = 0;
		float best = 1e30f;

		for (r = 1; r <= 48 && !found; r++) {
			int steps = r * 8;

			for (k = 0; k < steps; k++) {
				float ang = (float)k * 6.2831853f / (float)steps, d;
				int x = cx + (int)lroundf(cosf(ang) * (float)r), y = cy + (int)lroundf(sinf(ang) * (float)r), z, j, bad = 0;
				bl_vec3 p;

				if (x < 1 || y < 1 || x > BC_MAP_X - 2 || y > BC_MAP_Y - 2 || bc_map_is_water(e->map, x, y))
					continue;
				/* a column inland, not the water's edge: a body that stops
				 * on the edge rests half in the sea */
				if (bc_map_is_water(e->map, x + 1, y) || bc_map_is_water(e->map, x - 1, y) ||
				    bc_map_is_water(e->map, x, y + 1) || bc_map_is_water(e->map, x, y - 1))
					continue;
				z = top_floor(e->map, x, y);
				if (z > BC_MAP_GROUND_Z)
					continue;
				/* the lowest floor of the column is the shore */
				{
					uint64_t st2 = bc_map_stand_mask(e->map, x, y);
					int zz;

					for (zz = BC_MAP_GROUND_Z; zz > z; zz--)
						if ((st2 >> zz) & 1) { z = zz; break; }
				}
				p.x = (float)x + 0.5f; p.y = (float)y + 0.5f; p.z = (float)z - 2.25f;
				for (j = 0; j < 4 && !bad; j++)
					bad = j < b->dry.tries && flat(p, b->dry.bad[j]) < 6.0f;
				if (bad)
					continue;
				d = flat(p, me->pos) + 2.0f * (float)(BC_MAP_GROUND_Z - z);
				if (d < best) { best = d; b->dry.goal = p; found = 1; }
			}
		}
		if (!found) {
			b->dry.tries = 0;
			b->dry.cd_until = e->now + 20.0;
			return BT_FAILURE;
		}
		b->dry.until = e->now + 12.0;
	}
	st = bc_move_to(b, b->dry.goal, 0.0f);
	bc_fire_at_will(b);
	if (st == BC_MV_FAILED || st == BC_MV_ARRIVED) {
		/* no way, or "there" and still in the water: not that place */
		b->dry.bad[b->dry.tries & 3] = b->dry.goal;
		b->dry.until = 0.0;         /* another bank */
		if (++b->dry.tries >= 3) {
			/* three banks and no way up any: this water is where it is
			 * for now. It gets on with the game from here. */
			b->dry.tries = 0;
			b->dry.cd_until = e->now + 20.0;
			return BT_FAILURE;
		}
	}
	return BT_RUNNING;
}

void bc_do_tactics_stop(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a;
	b->flank.avoid_on = 0;
	b->hunt.phase = 0;
	b->dry.until = 0.0;
	/* a flank or a camp that is left for a fight is not taken up where it
	 * was: the flank starts over from where the bot then is, the perch is
	 * kept (its claim runs out by itself) */
	b->flank.phase = 0;
	bc_move_stop(b);
}
