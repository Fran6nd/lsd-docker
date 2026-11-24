/* skill_cover.c -- Cover: finding it, taking it, moving from one to the next
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * New here (aosbot had none; the first version sampled 64 places on four
 * rings and took the nearest the enemy could not see).
 *
 * THE QUERY (bc_cover_query). Given a bot, a THREAT (an eye: a man, or
 * where a hit came from -- a threat farther than 96 is taken as a
 * direction and brought in to 96) and a reach, it floods the floor a body
 * can WALK from where the bot stands -- column to column, a voxel up or
 * down at most, never the sea -- outward, nearest first, out to `radius`
 * columns (14 at most), and asks of each cell: can the threat see a body
 * standing here (the senses' own three rays, the server's ray cast)? If
 * it can, a body crouched here? A cell that hides a standing body is
 * COVER; one that hides only a crouched body is cover MARKED AS SUCH
 * (cq.crouch). Each is given a price, the lowest wins:
 *     the steps to walk there (the flood's own count: round a wall, not
 *       through it)
 *   + 2.5 if it only hides a crouched body
 *   + 1.5 for each side the threat need only step 3 voxels to to see it
 *       (how well hidden)
 *   + 3   if there is no floor to walk to on the side away from the
 *       threat (no line of retreat: a corner to die in)
 *   + 8   if a team-mate stands within 1.5 of it, 5 if one is on his way
 *       to it or holds it
 *   and by what the cover is for:
 *     HIDE      + 0.35 a voxel it brings the bot nearer the threat
 *     ADVANCE   - 1.3 a voxel it brings the bot nearer `toward`; only
 *               cells at least 2.5 nearer count, and none that costs more
 *               than 1.6 steps a voxel gained, plus 4 (a covered detour
 *               "of similar cost", not a tour of the map)
 *     BACK      the same toward the place fallen back on, and never a
 *               cell nearer the threat than the bot is
 *     VIEW      HIDE, but only cells within a cone (120 degrees, the
 *               whole angle) about the bearing to the threat -- cover it
 *               can see as it faces him, ahead or across, never behind its
 *               back -- and + 0.1 a voxel nearer him, not 0.35. Run to its
 *               end at once (bc_cover_view): the condition cover_in_view
 *               must answer now, and take_cover in_view takes its answer
 *               from the cache.
 * BUDGETED: `budget` cells are examined a call (the skills give 48 to 64:
 * a cell is two to six rays), the search keeps its place in the bot and
 * goes on at the next decision -- a full reach takes a third of a second,
 * and with HIDE it stops as soon as no farther cell could win. CACHED: the
 * answer stands a second for the same threat (within 3), place (within 2)
 * and purpose.
 *
 * THE SKILLS on it:
 *   crouch            the flinch: down where it stands, facing the shot,
 *                     0.3 to 1 s by character. Once a burst of fire.
 *   take_cover        the best cover from the threat (`in_view`: in view
 *                     of it, else FAILURE so the tree has it face him),
 *                     turned to him first, then moving there WITH THE
 *                     HEAD ON HIM -- backing, sidestepping, never turning
 *                     round to run (the owner: "you do not watch back to
 *                     find cover"); there,
 *                     crouched if the cover needs it, facing the threat,
 *                     PEEKING to fire: standing up from behind a low wall,
 *                     a step out from behind a high one, then back.
 *                     Campers peek rarely and stay long (hold 11 s, a peek
 *                     every 5.5 s); pushers barely stop (0.8 s). With no
 *                     cover in reach: crouched where it stands, turned to
 *                     the threat, shooting if it sees him.
 *   advance_by_cover  toward a place in BOUNDS: the next cover that gains
 *   fall_back_by_cover  ground, a pause there by character (0.15 to 2.5
 *                     s), the next; where no cover gains ground, a run of
 *                     1.6 s toward the place and a new look.
 *
 * WHY WAYPOINTS AND NOT A NAV COST. bc_nav_policy's danger is circles
 * (x, y, radius, weight); "exposed to that man" is not a circle but the
 * shadow of every wall, and a circle round the threat only says "stay
 * away", which is not cover. So the bounds are goals given to go-to one
 * at a time, each found by the query above; between two of them the route
 * is nav's own. The flank (skill_tactics.c) does use a danger circle: it
 * wants exactly "not through the middle".
 */
#include <math.h>
#include <string.h>

#include "brain.h"

enum { CQ_NONE = 0, CQ_SEARCH, CQ_DONE };

static float flat(bl_vec3 a, bl_vec3 b)
{
	float dx = a.x - b.x, dy = a.y - b.y;

	return sqrtf(dx * dx + dy * dy);
}

static float clampf(float v, float lo, float hi)
{
	return v < lo ? lo : v > hi ? hi : v;
}

int bc_floor_near(const bc_map *m, int x, int y, int z)
{
	static const int8_t dz[3] = { 0, -1, 1 };
	uint64_t st;
	int k;

	if (x < 1 || y < 1 || x > BC_MAP_X - 2 || y > BC_MAP_Y - 2 || bc_map_is_water(m, x, y))
		return -1;
	st = bc_map_stand_mask(m, x, y);
	for (k = 0; k < 3; k++) {
		int zz = z + dz[k];

		if (zz >= 1 && zz <= BC_MAP_GROUND_Z && ((st >> zz) & 1))
			return zz;
	}
	return -1;
}

int bc_in_harmful_water(const bc_bot *b)
{
	const bc_engine *e = b->e;
	const bl_player *me = bc_me(b);

	if (e->now < b->dry.cd_until)
		return 0;               /* no way out was found: it is not asked for every second */

	if (!(e->water_damage > 0.0f) && !e->water_lethal)
		return 0;
	if (me->flags & BL_F_WADING)
		return 1;
	return e->have_map && bc_map_is_water(e->map, (int)floorf(me->pos.x), (int)floorf(me->pos.y)) &&
	       me->pos.z > 59.0f;
}

int bc_threat_place(bc_bot *b, bl_vec3 *out)
{
	const bc_senses *s = &b->senses;
	double now = b->e->now;
	int t = b->fight.target;

	if (t >= 0 && s->k[t].visible) { *out = s->k[t].pos; return 1; }
	if (s->nearest >= 0) { *out = s->k[s->nearest].pos; return 1; }
	if (s->threat.valid && now - s->threat.at < 8.0) { *out = s->threat.pos; return 1; }
	if (t >= 0 && now - s->k[t].seen_at < 6.0) { *out = s->k[t].pos; return 1; }
	if (s->lost.valid && now - s->lost.at < 8.0) { *out = s->lost.pos; return 1; }
	if (s->nearest_known >= 0) { *out = s->k[s->nearest_known].pos; return 1; }
	if (s->noise.valid && now - s->noise.at < 6.0) { *out = s->noise.pos; return 1; }
	return 0;
}

int bc_exposed_to(const bc_bot *b, bl_vec3 threat)
{
	const bl_player *me = bc_me(b);

	return bc_sight_body(b->e->have_map ? b->e->map : NULL, threat, me->pos, (me->flags & BL_F_CROUCH) != 0);
}

/* a threat far off is a direction: the rays need not run the whole map */
static bl_vec3 near_threat(bl_vec3 me, bl_vec3 threat)
{
	float dx = threat.x - me.x, dy = threat.y - me.y, dz = threat.z - me.z;
	float l = sqrtf(dx * dx + dy * dy + dz * dz);

	if (l > 96.0f) {
		threat.x = me.x + dx / l * 96.0f;
		threat.y = me.y + dy / l * 96.0f;
		threat.z = me.z + dz / l * 96.0f;
	}
	return threat;
}

static int cq_seen(bc_cover_q *q, int dx, int dy)
{
	int i = (dy + BC_COVER_R) * BC_COVER_W + dx + BC_COVER_R;

	if ((q->seen[i >> 6] >> (i & 63)) & 1)
		return 1;
	q->seen[i >> 6] |= (uint64_t)1 << (i & 63);
	return 0;
}

static void cq_push(bc_cover_q *q, int dx, int dy, int z, int d)
{
	if (q->tail >= BC_COVER_QUEUE)
		return;
	q->q[q->tail][0] = (uint8_t)(dx + BC_COVER_R);
	q->q[q->tail][1] = (uint8_t)(dy + BC_COVER_R);
	q->q[q->tail][2] = (uint8_t)z;
	q->q[q->tail][3] = (uint8_t)d;
	q->tail++;
}

static void cq_begin(bc_bot *b, bl_vec3 threat, int mode, const bl_vec3 *toward, int radius, float cone)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bc_cover_q *q = &b->cq;
	bc_nav_node n;

	q->state = CQ_SEARCH;
	q->found = q->crouch = 0;
	q->best_d = 0;
	q->mode = (uint8_t)mode;
	q->radius = (int16_t)(radius > BC_COVER_R ? BC_COVER_R : radius < 2 ? 2 : radius);
	q->threat = threat;
	q->has_toward = toward != NULL;
	if (toward) q->toward = *toward;
	q->me = me->pos;
	q->me_td = flat(me->pos, threat);
	q->me_dd = toward ? flat(me->pos, *toward) : 0.0f;
	q->cone = cone;
	q->wide = cone <= -1.0f ? -2.0f : cosf(fminf(3.14159265f, acosf(cone) + 0.52f));
	q->best_score = 1e30f;
	q->head = q->tail = 0;
	q->cells = 0;
	memset(q->seen, 0, sizeof q->seen);
	e->stats.covers++;
	if (!e->have_map || !bc_nav_snap(e->map, (int)floorf(me->pos.x), (int)floorf(me->pos.y),
	                                 (int)floorf(me->pos.z + 2.75f), 1, &n) ||
	    bc_map_is_water(e->map, n.x, n.y)) {
		q->state = CQ_DONE;
		q->at = e->now;
		return;
	}
	q->origin = n;
	cq_seen(q, 0, 0);
	cq_push(q, 0, 0, n.z, 0);
}

/* is somebody of the team there, or going there? */
static float mates_at(const bc_bot *b, bl_vec3 c)
{
	const bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	float add = 0.0f;
	int i;

	for (i = 0; i < e->max_bots; i++) {
		const bc_bot *o = &e->bots[i];
		const bl_player *p;

		if (!o->used || !o->alive || o == b)
			continue;
		p = &e->w.players[o->pid];
		if (p->team != me->team)
			continue;
		if (flat(p->pos, c) < 1.5f)
			return 8.0f;
		if ((o->tc.phase && flat(o->tc.goal, c) < 1.5f) || (o->bd.phase >= 2 && flat(o->bd.goal, c) < 1.5f))
			add = 5.0f;
	}
	if (add == 0.0f)
		for (i = 0; i < BL_MAX_PLAYERS; i++) {
			const bl_player *p = &e->w.players[i];

			/* the team-mates that are not bots */
			if (i != b->pid && p->state == BL_ALIVE && p->team == me->team && !(p->flags & BL_F_BOT) &&
			    flat(p->pos, c) < 1.5f)
				return 8.0f;
		}
	return add;
}

static int cover_query(bc_bot *b, bl_vec3 threat, int mode, const bl_vec3 *toward, int radius, int budget, float cone);

int bc_cover_query(bc_bot *b, bl_vec3 threat, int mode, const bl_vec3 *toward, int radius, int budget)
{
	return cover_query(b, threat, mode, toward, radius, budget, -1.0f);
}

int bc_cover_view(bc_bot *b, bl_vec3 threat, int radius, float degrees)
{
	float cone = cosf(0.5f * degrees * 3.14159265f / 180.0f);

	if (degrees >= 360.0f) cone = -1.0f;
	cover_query(b, threat, BC_COVER_VIEW, NULL, radius, BC_COVER_QUEUE, cone);
	return b->cq.state == CQ_DONE && b->cq.found;
}

static int cover_query(bc_bot *b, bl_vec3 threat, int mode, const bl_vec3 *toward, int radius, int budget, float cone)
{
	static const int8_t nb[8][2] = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } };
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bc_cover_q *q = &b->cq;
	const bc_map *m = e->map;
	int same;

	threat = near_threat(me->pos, threat);
	/* the same question: the same threat and purpose, asked from about the
	 * same place -- a search in progress is not begun again because the
	 * bot walked on meanwhile (it never ended), only when it has gone far */
	same = q->state != CQ_NONE && q->mode == mode && flat(q->threat, threat) < 3.0f &&
	       flat(q->me, me->pos) < (q->state == CQ_SEARCH ? 6.0f : 2.0f) && q->has_toward == (toward != NULL) &&
	       (!toward || flat(q->toward, *toward) < 4.0f) &&
	       (mode != BC_COVER_VIEW || (q->radius == (radius > BC_COVER_R ? BC_COVER_R : radius < 2 ? 2 : radius) &&
	                                  fabsf(q->cone - cone) < 1e-3f));
	if (same && q->state == CQ_DONE && e->now - q->at < 1.0)
		return 1;
	if (!same || q->state == CQ_DONE)
		cq_begin(b, threat, mode, toward, radius, cone);

	while (q->state == CQ_SEARCH && budget-- > 0 && q->head < q->tail) {
		const uint8_t *c = q->q[q->head++];
		int dx = (int)c[0] - BC_COVER_R, dy = (int)c[1] - BC_COVER_R, z = c[2], d = c[3];
		int x = q->origin.x + dx, y = q->origin.y + dy, k, crouch = 0, back = 0;
		float sc, tl, td, sx, sy, gain = 0.0f;
		bl_vec3 eye, ce, side;

		/* nearest first: once walking there alone costs more than the best
		 * found, nothing farther can win */
		if ((q->mode == BC_COVER_HIDE || q->mode == BC_COVER_VIEW) && 0.6f * (float)d > q->best_score) {
			q->head = q->tail;
			break;
		}
		if (q->mode == BC_COVER_VIEW && d >= 2) {
			/* well outside the cone (by 30 degrees more): neither looked
			 * at nor flooded on -- a way to cover in view does not go
			 * round behind the bot. Two thirds of the flood saved */
			float tx = q->threat.x - q->me.x, ty = q->threat.y - q->me.y, tl0 = sqrtf(tx * tx + ty * ty);
			float bl = sqrtf((float)(dx * dx + dy * dy));

			if (tl0 > 1e-3f && ((float)dx * tx + (float)dy * ty) / (bl * tl0) < q->wide)
				continue;
		}
		q->cells++;
		e->stats.cover_cells++;
		if (d < q->radius)
			for (k = 0; k < 8; k++) {
				int ex = dx + nb[k][0], ey = dy + nb[k][1], fz;

				if (ex < -BC_COVER_R || ex > BC_COVER_R || ey < -BC_COVER_R || ey > BC_COVER_R)
					continue;
				fz = bc_floor_near(m, q->origin.x + ex, q->origin.y + ey, z);
				if (fz < 0 || cq_seen(q, ex, ey))
					continue;
				cq_push(q, ex, ey, fz, d + 1);
			}

		eye.x = (float)x + 0.5f; eye.y = (float)y + 0.5f; eye.z = (float)z - 2.25f;
		td = flat(eye, q->threat);
		sc = (float)d;
		if (q->mode == BC_COVER_HIDE) {
			sc += 0.35f * (q->me_td - td);
		} else if (q->mode == BC_COVER_VIEW) {
			/* in the cone toward him, as it faces him: ahead or across,
			 * never behind its back. Nearer him is no fault here */
			if (d > 0) {
				float bx = eye.x - q->me.x, by = eye.y - q->me.y, tx = q->threat.x - q->me.x, ty = q->threat.y - q->me.y;
				float bl = sqrtf(bx * bx + by * by), tl0 = sqrtf(tx * tx + ty * ty);

				if (bl > 1e-3f && tl0 > 1e-3f && (bx * tx + by * ty) / (bl * tl0) < q->cone)
					continue;
			}
			sc += 0.1f * (q->me_td - td);
		} else {
			gain = q->me_dd - flat(eye, q->toward);
			if (gain < 2.5f || (float)d > 1.6f * gain + 4.0f)
				continue;
			if (q->mode == BC_COVER_BACK && td < q->me_td - 1.0f)
				continue;
			sc -= 1.3f * gain;
		}
		if (sc >= q->best_score)
			continue;
		ce = eye;
		if (bc_sight_body(m, q->threat, eye, 0)) {
			ce.z += 0.9f;
			if (bc_sight_body(m, q->threat, ce, 1))
				continue;       /* he sees a body here whatever it does */
			crouch = 1;
			sc += 2.5f;
		}
		if (sc >= q->best_score)
			continue;
		/* how well hidden: from a threat that steps aside */
		tl = td > 1e-3f ? td : 1.0f;
		sx = -(eye.y - q->threat.y) / tl * 3.0f;
		sy = (eye.x - q->threat.x) / tl * 3.0f;
		for (k = -1; k <= 1; k += 2) {
			side = q->threat;
			side.x += sx * (float)k;
			side.y += sy * (float)k;
			if (bc_sight_body(m, side, ce, crouch))
				sc += 1.5f;
		}
		/* a way out on the side away from him */
		for (k = 0; k < 8 && !back; k++)
			if ((float)nb[k][0] * (eye.x - q->threat.x) + (float)nb[k][1] * (eye.y - q->threat.y) > 0.0f &&
			    bc_floor_near(m, x + nb[k][0], y + nb[k][1], z) >= 0)
				back = 1;
		if (!back)
			sc += 3.0f;
		if (sc >= q->best_score)
			continue;
		sc += mates_at(b, eye);
		if (sc >= q->best_score)
			continue;
		q->best_score = sc;
		q->best = eye;
		q->best_d = (uint8_t)d;
		q->crouch = (uint8_t)crouch;
		q->found = 1;
	}
	if (q->state == CQ_SEARCH && q->head >= q->tail) {
		q->state = CQ_DONE;
		q->at = e->now;
	}
	return q->state == CQ_DONE;
}

/* --- the wishes of a body in cover -------------------------------------- */

static void look_at_place(bc_bot *b, bl_vec3 p)
{
	if (b->wish.look != BC_LOOK_AHEAD)
		return;                 /* a man in its sights already */
	b->wish.look = BC_LOOK_POINT;
	b->wish.look_at = p;
}

/* stand on a spot: walk the last half voxel there, then stop */
static void stand_on(bc_bot *b, bl_vec3 spot)
{
	const bl_player *me = bc_me(b);
	float dx = spot.x - me->pos.x, dy = spot.y - me->pos.y, l = sqrtf(dx * dx + dy * dy);

	b->wish.move = BC_MOVE_FREE;
	b->wish.mx = b->wish.my = 0.0f;
	if (l > 0.3f && l < 3.0f && bc_walk_safe(b, dx / l, dy / l)) {
		b->wish.mx = dx / l;
		b->wish.my = dy / l;
		b->wish.sneak = l < 1.0f;       /* the last step slowly, or it slides past */
	}
}

static int wet(const bc_bot *b)
{
	const bl_player *me = bc_me(b);

	return (me->flags & BL_F_WADING) != 0 ||
	       (b->e->have_map && bc_map_is_water(b->e->map, (int)floorf(me->pos.x), (int)floorf(me->pos.y)));
}

/* --- crouch [secs] ------------------------------------------------------- */

bt_status bc_do_crouch(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	bl_vec3 th;

	(void)dt;
	if (wet(b)) {
		b->cr.until = 0.0;
		return BT_SUCCESS;      /* a wading body does not duck: it gets out */
	}
	if (b->cr.until == 0.0) {
		float secs = a->count > 0 ? a->num[0] : 0.0f;

		if (secs <= 0.0f) {
			/* the flinch: once for a burst of fire */
			if (b->cr.flinched_for == b->senses.fire_since)
				return BT_SUCCESS;
			b->cr.flinched_for = b->senses.fire_since;
			secs = clampf(0.25f + 0.35f * b->persona.trait[BC_T_CAUTION], 0.3f, 1.0f);
		}
		b->cr.until = e->now + (double)secs;
	}
	if (e->now >= b->cr.until) {
		b->cr.until = 0.0;
		return BT_SUCCESS;
	}
	b->wish.move = BC_MOVE_NONE;
	b->wish.crouch = 1;
	bc_fire_at_will(b);
	if (bc_threat_place(b, &th))
		look_at_place(b, th);
	return BT_RUNNING;
}

/* --- take_cover ---------------------------------------------------------- */

enum { TC_NONE = 0, TC_SEARCH, TC_GO, TC_HOLD, TC_BARE };

static void tc_arrive(bc_bot *b, bl_vec3 threat)
{
	static const int8_t nb[8][2] = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } };
	bc_engine *e = b->e;
	const float *t = b->persona.trait;
	int x = (int)floorf(b->tc.goal.x), y = (int)floorf(b->tc.goal.y), z = (int)floorf(b->tc.goal.z + 2.75f), k;
	float best = 1e30f;

	b->tc.phase = TC_HOLD;
	/* campers stay, pushers barely stop */
	b->tc.until = e->now + (double)clampf(6.0f * t[BC_T_CAUTION] - 3.0f * t[BC_T_AGGRESSION] + 2.0f, 0.8f, 14.0f);
	b->tc.peek_at = e->now + (double)(clampf(1.5f + 2.5f * t[BC_T_CAUTION] - 1.0f * t[BC_T_AGGRESSION], 1.0f, 6.0f) *
	                                  bc_rng_range(&b->rng, 0.3f, 0.8f));
	b->tc.peeking = 0;
	b->tc.seen_since = 0.0;
	b->tc.has_peek = 0;
	if (b->tc.crouch)
		return;                 /* it peeks by standing up */
	/* behind a high wall: the cell beside from which he can be seen */
	for (k = 0; k < 8; k++) {
		int fz = bc_floor_near(e->map, x + nb[k][0], y + nb[k][1], z);
		bl_vec3 eye;
		float d;

		if (fz < 0)
			continue;
		eye.x = (float)(x + nb[k][0]) + 0.5f; eye.y = (float)(y + nb[k][1]) + 0.5f; eye.z = (float)fz - 2.25f;
		if (!bc_sight_body(e->map, threat, eye, 0))
			continue;
		d = (k >= 4 ? 0.4f : 0.0f) + 0.01f * flat(eye, threat);
		if (d < best) {
			best = d;
			b->tc.peek = eye;
			b->tc.has_peek = 1;
		}
	}
}

bt_status bc_do_take_cover(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const float *t = b->persona.trait;
	int view = a && a->count > 0 && !strcmp(a->text[0], "in_view");
	int radius = a && a->count > 1 && a->num[1] > 0.0f ? (int)a->num[1] : 12;
	float degrees = a && a->count > 2 && a->num[2] > 0.0f ? a->num[2] : 120.0f;
	bl_vec3 th;
	int st;

	if (!bc_threat_place(b, &th)) {
		b->tc.phase = TC_NONE;
		return BT_FAILURE;
	}
	if (wet(b)) {
		/* nobody takes cover in the sea: out of it, shooting */
		b->tc.phase = TC_NONE;
		return bc_do_leave_water(bot, a, dt) == BT_FAILURE ? BT_FAILURE : BT_RUNNING;
	}
	if (e->now - b->tc.asked_at > 1.0 || b->tc.view != view)
		b->tc.phase = TC_NONE;
	b->tc.asked_at = e->now;
	b->tc.view = (uint8_t)view;
	if (b->tc.phase == TC_NONE) {
		b->tc.phase = TC_SEARCH;
		b->tc.tries = 0;
	}
	switch (b->tc.phase) {
	case TC_SEARCH:
		/* down and turned to it while it looks for somewhere */
		b->wish.move = BC_MOVE_NONE;
		b->wish.crouch = 1;
		bc_fire_at_will(b);
		look_at_place(b, th);
		if (view) {
			/* only what it can see facing him; none: the tree's again
			 * (it faces him, or falls back: its choice, not this word's) */
			if (!bc_cover_view(b, th, radius, degrees)) {
				b->tc.phase = TC_NONE;
				return BT_FAILURE;
			}
		} else if (!bc_cover_query(b, th, BC_COVER_HIDE, NULL, radius, 48)) {
			return BT_RUNNING;
		}
		if (!b->cq.found) {
			b->tc.phase = TC_BARE;
			b->tc.until = e->now + (double)bc_rng_range(&b->rng, 2.0f, 3.5f);
			return BT_RUNNING;
		}
		b->tc.goal = b->cq.best;
		b->tc.crouch = b->cq.crouch;
		b->tc.go_since = e->now;
		if (b->cq.best_d == 0)
			tc_arrive(b, th);
		else
			b->tc.phase = TC_GO;
		return BT_RUNNING;
	case TC_GO:
		/* the head on him all the way: it backs or sidesteps to the cover,
		 * it does not turn round to run there. And it turns to him before
		 * it sets off (hit from behind: it looks first) */
		look_at_place(b, th);
		if (t[BC_T_AGGRESSION] > 1.3f)
			bc_fire_at_will(b);         /* a pusher shoots on the way */
		{
			float dx = th.x - me->pos.x, dy = th.y - me->pos.y, l = sqrtf(dx * dx + dy * dy);

			if (l > 1e-3f && (dx * me->ori.x + dy * me->ori.y) / l < 0.8f && e->now - b->tc.go_since < 1.5) {
				b->wish.move = BC_MOVE_NONE;
				b->wish.crouch = 1;
				return BT_RUNNING;
			}
		}
		st = bc_move_to(b, b->tc.goal, 0.0f);
		if (st == BC_MV_ARRIVED) {
			tc_arrive(b, th);
		} else if (st == BC_MV_FAILED || e->now - b->tc.go_since > 8.0) {
			b->cq.state = 0;
			b->tc.phase = ++b->tc.tries < 2 ? TC_SEARCH : TC_BARE;
			b->tc.until = e->now + 2.5;
		}
		return BT_RUNNING;
	case TC_HOLD:
		if (e->now >= b->tc.until) {
			b->tc.phase = TC_NONE;
			return BT_SUCCESS;
		}
		if (b->tc.peeking && e->now >= b->tc.peek_until) {
			b->tc.peeking = 0;
			b->tc.peek_at = e->now + (double)(clampf(1.5f + 2.5f * t[BC_T_CAUTION] - 1.0f * t[BC_T_AGGRESSION], 1.0f, 6.0f) *
			                                  bc_rng_range(&b->rng, 0.7f, 1.3f));
		} else if (!b->tc.peeking && e->now >= b->tc.peek_at && (b->tc.crouch || b->tc.has_peek)) {
			b->tc.peeking = 1;
			b->tc.peek_until = e->now + (double)(b->aim.tune.reaction_sec + bc_rng_range(&b->rng, 0.7f, 1.4f) *
			                                     (0.6f + 0.4f * t[BC_T_AGGRESSION]));
		}
		if (b->tc.peeking) {
			if (b->tc.crouch) stand_on(b, b->tc.goal);
			else stand_on(b, b->tc.peek);
			bc_fire_at_will(b);
			b->tc.seen_since = 0.0;
		} else {
			stand_on(b, b->tc.goal);
			b->wish.crouch = b->tc.crouch;
			/* out of the peek and he still sees it: this is no cover (he
			 * moved). Another, twice; then it is the tree's again. */
			if (b->senses.n_visible > 0 && flat(me->pos, b->tc.goal) < 0.6f) {
				if (b->tc.seen_since == 0.0) b->tc.seen_since = e->now;
				bc_fire_at_will(b);
				if (e->now - b->tc.seen_since > 1.0) {
					b->cq.state = 0;
					if (++b->tc.tries >= 3) {
						b->tc.phase = TC_NONE;
						return BT_SUCCESS;
					}
					b->tc.phase = TC_SEARCH;
				}
			} else {
				b->tc.seen_since = 0.0;
			}
		}
		look_at_place(b, th);
		return BT_RUNNING;
	default:    /* TC_BARE: nothing to get behind */
		b->wish.move = BC_MOVE_NONE;
		b->wish.crouch = 1;
		bc_fire_at_will(b);
		look_at_place(b, th);
		if (e->now >= b->tc.until) {
			b->tc.phase = TC_NONE;
			return BT_SUCCESS;
		}
		return BT_RUNNING;
	}
}

/* --- advance_by_cover <place>, fall_back_by_cover [place] ---------------- */

enum { BD_NONE = 0, BD_SEARCH, BD_GO, BD_PAUSE, BD_RUN };

static bt_status bounds(bc_bot *b, bl_vec3 dest, int mode, float arrive)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const float *t = b->persona.trait;
	bl_vec3 th;
	int st, have_th = bc_threat_place(b, &th);

	if (bc_in_harmful_water(b)) {
		b->bd.phase = BD_NONE;
		return BT_FAILURE;
	}
	if (!have_th) {
		if (mode == BC_COVER_BACK) {
			b->bd.phase = BD_NONE;
			return BT_FAILURE;
		}
		th = dest;              /* going at a place: that is where he is taken to be */
	}
	if (e->now - b->bd.asked_at > 1.0)
		b->bd.phase = BD_NONE;
	b->bd.asked_at = e->now;
	if (b->bd.phase == BD_NONE || b->bd.mode != mode || flat(b->bd.dest, dest) > 12.0f) {
		b->bd.phase = BD_SEARCH;
		b->bd.mode = (uint8_t)mode;
		b->bd.dest = dest;
		b->bd.bounds = 0;
		b->bd.since = e->now;
		b->bd.quiet_since = e->now;
		b->cq.state = 0;
	}
	/* a place that moves (a man): followed when it has moved a good part
	 * of the way there is to it -- every new place is a new route */
	if (flat(dest, b->bd.dest) > clampf(0.15f * flat(dest, me->pos), 4.0f, 14.0f))
		b->bd.dest = dest;
	dest = b->bd.dest;

	if (wet(b) && mode == BC_COVER_BACK) {
		/* falling back in the sea is getting out of it: the nearest dry
		 * ground, not a base a hundred voxels of wading away */
		b->bd.phase = BD_NONE;
		return bc_do_leave_water(b, NULL, 0.0f) == BT_FAILURE ? BT_FAILURE : BT_RUNNING;
	}
	if (wet(b)) {
		/* no cover in the sea, and no pausing in it: straight on */
		b->bd.phase = BD_RUN;
		b->bd.until = e->now + 1.0;
		st = bc_move_to(b, dest, arrive);
		if (mode == BC_COVER_ADVANCE) bc_fire_at_will(b);
		if (st == BC_MV_FAILED || st == BC_MV_ARRIVED) b->bd.phase = BD_NONE;
		return st == BC_MV_FAILED ? BT_FAILURE : st == BC_MV_ARRIVED ? BT_SUCCESS : BT_RUNNING;
	}
	if (flat(me->pos, dest) <= arrive + 1.5f) {
		b->bd.phase = BD_NONE;
		return BT_SUCCESS;
	}
	if (mode == BC_COVER_BACK) {
		/* far enough back: out of his sight and no round for 3 s */
		if (bc_exposed_to(b, th) || e->now - b->senses.shot_at < 3.0)
			b->bd.quiet_since = e->now;
		if ((b->bd.bounds >= 1 && e->now - b->bd.quiet_since > 1.5) || e->now - b->bd.since > 25.0) {
			b->bd.phase = BD_NONE;
			return BT_SUCCESS;
		}
	} else if (e->now - b->bd.since > 90.0) {
		b->bd.phase = BD_NONE;
		return BT_FAILURE;
	}

	switch (b->bd.phase) {
	case BD_SEARCH:
		/* on toward it while the next cover is looked for (a third of a
		 * second): straight, not by a route that would be thrown away for
		 * the route to the cover -- two plans a bound, with forty bots
		 * sharing one planner, was a third of all the plans asked for */
		if (b->bd.bounds > 0) {
			/* in cover already: the next one is looked for from it */
			stand_on(b, b->bd.goal);
			b->wish.crouch = b->bd.crouch;
		} else {
			float dx = dest.x - me->pos.x, dy = dest.y - me->pos.y, l = sqrtf(dx * dx + dy * dy);

			b->wish.move = BC_MOVE_FREE;
			if (l > 1.0f && bc_walk_safe(b, dx / l, dy / l)) {
				b->wish.mx = dx / l;
				b->wish.my = dy / l;
			}
		}
		st = BC_MV_PLANNING;
		if (mode == BC_COVER_ADVANCE) bc_fire_at_will(b);
		if (!bc_cover_query(b, th, mode, &dest, BC_COVER_R, 64))
			return BT_RUNNING;
		if (b->cq.found && b->cq.best_d > 0) {
			b->bd.goal = b->cq.best;
			b->bd.crouch = b->cq.crouch;
			b->bd.phase = BD_GO;
			b->bd.until = e->now + 8.0;
		} else {
			if (st == BC_MV_FAILED) {
				b->bd.phase = BD_NONE;
				return BT_FAILURE;      /* no cover and no way */
			}
			b->bd.phase = BD_RUN;
			b->bd.until = e->now + 1.6;
		}
		return BT_RUNNING;
	case BD_GO:
		st = bc_move_to(b, b->bd.goal, 0.0f);
		if (mode == BC_COVER_ADVANCE) bc_fire_at_will(b);
		if (st == BC_MV_ARRIVED) {
			b->bd.phase = BD_PAUSE;
			b->bd.bounds++;
			b->bd.until = e->now + (double)(clampf(0.3f + 1.2f * t[BC_T_CAUTION] - 0.5f * t[BC_T_AGGRESSION], 0.15f, 2.5f) *
			                                bc_rng_range(&b->rng, 0.7f, 1.3f));
		} else if (st == BC_MV_FAILED || e->now >= b->bd.until) {
			b->cq.state = 0;
			b->bd.phase = BD_RUN;
			b->bd.until = e->now + 1.6;
		}
		return BT_RUNNING;
	case BD_PAUSE:
		stand_on(b, b->bd.goal);
		b->wish.crouch = b->bd.crouch;
		bc_fire_at_will(b);
		look_at_place(b, th);
		if (e->now >= b->bd.until) {
			b->cq.state = 0;
			b->bd.phase = BD_SEARCH;
		}
		return BT_RUNNING;
	default:    /* BD_RUN: no cover that gains ground: a run, then look again */
		st = bc_move_to(b, dest, arrive);
		if (mode == BC_COVER_ADVANCE) bc_fire_at_will(b);
		if (st == BC_MV_FAILED) {
			b->bd.phase = BD_NONE;
			return BT_FAILURE;
		}
		if (st == BC_MV_ARRIVED) {
			b->bd.phase = BD_NONE;
			return BT_SUCCESS;
		}
		if (e->now >= b->bd.until) {
			b->cq.state = 0;
			b->bd.phase = BD_SEARCH;
		}
		return BT_RUNNING;
	}
}

bt_status bc_do_advance_by_cover(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	const char *name = a->count > 0 ? a->text[0] : "enemy";
	bl_vec3 dest;
	float arrive = a->count > 1 && a->num[1] > 0.0f ? a->num[1] : 3.0f;

	(void)dt;
	if (!bc_place_of(b, name, &dest)) {
		b->bd.phase = BD_NONE;
		return BT_FAILURE;
	}
	/* at a man: as near as it would fight him from */
	if (!strcmp(name, "enemy") && a->count < 2)
		arrive = bc_hold_range(b);
	return bounds(b, dest, BC_COVER_ADVANCE, arrive);
}

bt_status bc_do_fall_back_by_cover(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	const bl_player *me = bc_me(b);
	bl_vec3 dest, th;

	(void)dt;
	if (b->bd.phase != BD_NONE && b->bd.mode == BC_COVER_BACK) {
		dest = b->bd.dest;
	} else if (!bc_place_of(b, a->count > 0 ? a->text[0] : "own_base", &dest) || flat(dest, me->pos) < 12.0f) {
		/* no such place, or it is there already: straight away from him */
		float dx, dy, l;

		if (!bc_threat_place(b, &th))
			return BT_FAILURE;
		dx = me->pos.x - th.x; dy = me->pos.y - th.y;
		l = sqrtf(dx * dx + dy * dy);
		if (l < 1e-3f) { dx = 1.0f; dy = 0.0f; l = 1.0f; }
		dest = me->pos;
		dest.x = clampf(me->pos.x + dx / l * 40.0f, 3.0f, 508.0f);
		dest.y = clampf(me->pos.y + dy / l * 40.0f, 3.0f, 508.0f);
	}
	b->wish.fire_pid = -1;
	return bounds(b, dest, BC_COVER_BACK, 3.0f);
}

void bc_do_cover_stop(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	b->e->stats.action_stops++;

	(void)a;
	/* What it was at is kept: a tree entered afresh (a man came into sight,
	 * a round landed) asks for the same thing again at once, and a bound
	 * half run or a cover just reached is not started over from the open.
	 * Left for over a second, it is forgotten (take_cover and bounds look
	 * at when they were last asked). */
	b->cr.until = 0.0;
	bc_move_stop(b);
}
