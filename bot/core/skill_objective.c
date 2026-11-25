/* skill_objective.c -- The two objects a team may carry off, and the bases
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * The world shows two objects (bl_world.intel[team - 1]: where, and who
 * holds it) and two bases (tent[]). What they are FOR is a gamemode's
 * rule and is not known here; these are the neutral things a tree can do
 * with them, written against the one set of rules the server has for
 * them (lsd/scripts/ctf.lua, catalog/overrides/lib_ctf.lua), read
 * 2026-11-24:
 *
 *  - PICKING UP is walking onto it: every tick, the first living player
 *    of the OTHER team within 3 voxels across of an object on the ground
 *    (and with its eye between 4 above and 1 below it) is given it. The
 *    loop is over every connected player, and a bot is one (lib_bot's
 *    bot_create calls on_successful_connect): a bot picks up as a man
 *    does. A team cannot touch its OWN object: one dropped lies where it
 *    fell until an enemy takes it again. There is no "return".
 *  - CAPTURING is carrying it to within 3 across of one's OWN base, the
 *    same cylinder. The team scores; the object is put back at a random
 *    place on its owners' side. Nothing else is asked (one's own object
 *    need not be at home).
 *  - DYING drops it where the carrier stood, and for 2 s after ANY drop
 *    nobody picks up anything (one timer for both objects).
 *
 * WHAT THE ENGINE MAKES OF IT (bc_objective_world): each object is HOME
 * (lying where the server put it), CARRIED, or DROPPED (it was carried
 * and now lies somewhere without its carrier's team having scored).
 * Every change is news to both teams -- a client shows it -- so every
 * bot's tree is entered afresh (a jolt). For the same reason a CARRIER'S
 * PLACE IS KNOWN to everybody, unlike an ordinary enemy's: `thief` and
 * `carrier` are the world's own positions, not the senses'.
 *
 * THE SKILLS:
 *   fetch        to the other team's object where it lies, and onto it.
 *   carry_home   the carrier runs for its own base. Its route keeps away
 *                from the enemies it knows of (nav's danger circles, 18
 *                round each of the nearest three, planned again when they
 *                move), and it shoots only at a man within 14: it does
 *                not stop to duel.
 *   escort       beside the team-mate who carries: a station 6 ahead of
 *                him toward the base and 3 to a side of its own, shooting
 *                what it sees.
 *   intercept    cut the thief off: to the point of his way home it can
 *                reach before he does (where he is GOING, not where he
 *                was), else to his base ahead of him; in sight, fight him.
 *   guard        near a place (default: its team's object), at a spot of
 *                its own a few voxels off toward where the enemy comes
 *                from, crouched, watching that way.
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

/* WHICH OBJECT IS WHOSE. Two in the world (ctf): a team goes for the
 * other's and keeps its own. ONE (babel: one intel in the sky that either
 * team carries home): it is the one each goes for and the one each keeps
 * from the other. An object the server keeps out of the map (babel puts
 * its second at infinity) is none. */
static int obj_here(const bc_engine *e, int t)
{
	const bl_object *o = &e->w.intel[t];

	return o->present && o->pos.x >= 0.0f && o->pos.x < (float)BC_MAP_X &&
	       o->pos.y >= 0.0f && o->pos.y < (float)BC_MAP_Y;
}

static int obj_alone(const bc_engine *e)
{
	return obj_here(e, 0) != obj_here(e, 1);
}

int bc_obj_theirs(const bc_engine *e, int team)
{
	if (team < 1 || team > 2) return -1;
	if (obj_here(e, 2 - team)) return 2 - team;
	return obj_alone(e) ? team - 1 : -1;
}

int bc_obj_ours(const bc_engine *e, int team)
{
	if (team < 1 || team > 2) return -1;
	if (obj_here(e, team - 1)) return team - 1;
	return obj_alone(e) ? 2 - team : -1;
}

/* the team of whoever holds object t, 0 for nobody */
static int holder_team(const bc_engine *e, int t)
{
	int h = e->w.intel[t].holder;

	return h == BL_NO_PLAYER ? 0 : e->w.players[h].team;
}

void bc_objective_world(bc_engine *e)
{
	int t, i, news = 0;

	for (t = 0; t < 2; t++) {
		const bl_object *o = &e->w.intel[t];
		bc_objstate *st = &e->obj[t];
		int state = st->state;

		if (!obj_here(e, t)) {
			st->state = BC_OBJ_HOME;
			st->holder = BL_NO_PLAYER;
			continue;
		}
		if (o->holder != BL_NO_PLAYER) {
			if (st->state != BC_OBJ_CARRIED || st->holder != o->holder) {
				int ct = e->w.players[o->holder].team;

				st->score = ct >= 1 && ct <= 2 ? e->w.score[ct - 1] : 0;
				st->since = e->now;
				news = 1;
			}
			state = BC_OBJ_CARRIED;
			st->holder = o->holder;
		} else if (st->state == BC_OBJ_CARRIED) {
			int ct = st->holder != BL_NO_PLAYER ? e->w.players[st->holder].team : 0;

			/* let go: taken home (his team scored), or fallen */
			state = ct >= 1 && ct <= 2 && e->w.score[ct - 1] != st->score ? BC_OBJ_HOME : BC_OBJ_DROPPED;
			st->holder = BL_NO_PLAYER;
			st->since = e->now;
			news = 1;
		} else if (st->state == BC_OBJ_DROPPED && flat(o->pos, st->pos) > 3.0f) {
			state = BC_OBJ_HOME;        /* the server put it somewhere else */
			st->since = e->now;
			news = 1;
		}
		st->state = (uint8_t)state;
		st->pos = o->pos;
	}
	if (news)
		for (i = 0; i < e->max_bots; i++)
			if (e->bots[i].used)
				e->bots[i].jolt = 1;
}

int bc_obj_state(const bc_bot *b, int own)
{
	const bc_engine *e = b->e;
	int team = bc_me(b)->team, t = own ? bc_obj_ours(e, team) : bc_obj_theirs(e, team), st;

	if (t < 0)
		return -1;
	st = e->obj[t].state;
	/* the one object of a game with one: lying, it is theirs to fetch and
	 * nothing of ours to guard; carried, theirs carried by a mate, ours
	 * taken by an enemy */
	if (obj_alone(e)) {
		if (st != BC_OBJ_CARRIED)
			return own ? -1 : st;
		return (holder_team(e, t) == team) == !own ? st : -1;
	}
	return st;
}

int bc_carrying(const bc_bot *b)
{
	const bc_engine *e = b->e;
	int t = bc_obj_theirs(e, bc_me(b)->team);

	return t >= 0 && e->w.intel[t].holder == b->pid;
}

int bc_objective_place(bc_bot *b, const char *name, bl_vec3 *out)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int team = me->team, other = team == 1 ? 2 : 1;

	if (team < 1 || team > 2)
		return 0;
	if (!strcmp(name, "carrier")) {
		int t = bc_obj_theirs(e, team);
		const bl_object *o = t >= 0 ? &e->w.intel[t] : NULL;

		if (!o || o->holder == BL_NO_PLAYER || o->holder == b->pid || holder_team(e, t) != team ||
		    e->w.players[o->holder].state != BL_ALIVE)
			return 0;
		*out = e->w.players[o->holder].pos;
		return 1;
	}
	if (!strcmp(name, "thief") || !strcmp(name, "intercept")) {
		int ot = bc_obj_ours(e, team);
		const bl_object *o = ot >= 0 ? &e->w.intel[ot] : NULL;
		const bl_player *th;
		bl_vec3 base, p;
		float dx, dy, l2, t;

		if (!o || o->holder == BL_NO_PLAYER || holder_team(e, ot) != other ||
		    e->w.players[o->holder].state != BL_ALIVE)
			return 0;
		th = &e->w.players[o->holder];
		*out = th->pos;
		if (name[0] == 't' || !e->w.tent[other - 1].present || flat(me->pos, th->pos) < 20.0f)
			return 1;
		/* the point of his way home nearest this bot; if he will be past
		 * it first, farther along, down to his base itself */
		base = e->w.tent[other - 1].pos;
		dx = base.x - th->pos.x; dy = base.y - th->pos.y;
		l2 = dx * dx + dy * dy;
		if (l2 < 1.0f)
			return 1;
		t = clampf(((me->pos.x - th->pos.x) * dx + (me->pos.y - th->pos.y) * dy) / l2, 0.0f, 1.0f);
		for (; t < 1.0f; t += 0.15f) {
			p.x = th->pos.x + dx * t; p.y = th->pos.y + dy * t; p.z = th->pos.z;
			if (flat(me->pos, p) <= flat(th->pos, p) + 4.0f)
				break;
		}
		if (t >= 1.0f) t = 0.92f;
		out->x = th->pos.x + dx * t;
		out->y = th->pos.y + dy * t;
		out->z = th->pos.z + (base.z - th->pos.z) * t;
		return 1;
	}
	return 0;
}

/* a moving place: keep the goal in hand while it is near enough */
static int go(bc_bot *b, bl_vec3 p, float radius, float slack)
{
	if (b->mv.goal_set && b->mv.state != BC_MV_IDLE && b->mv.state != BC_MV_FAILED &&
	    flat(b->wish.goal, p) < slack)
		p = b->wish.goal;
	return bc_move_to(b, p, radius);
}

/* --- fetch ---------------------------------------------------------------- */

bt_status bc_do_fetch(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int team = me->team, st;
	const bl_object *o;

	(void)a; (void)dt;
	if (team < 1 || team > 2)
		return BT_FAILURE;
	if (bc_obj_theirs(e, team) < 0)
		return BT_FAILURE;
	o = &e->w.intel[bc_obj_theirs(e, team)];
	if (bc_carrying(b)) {
		b->fetch.stand_since = 0.0;
		return BT_SUCCESS;
	}
	if (o->holder != BL_NO_PLAYER)
		return BT_FAILURE;      /* somebody has it */
	st = bc_move_to(b, o->pos, 1.0f);
	bc_fire_at_will(b);
	if (st == BC_MV_FAILED)
		return BT_FAILURE;
	if (st == BC_MV_ARRIVED) {
		/* on it and not given it yet (the server waits 2 s after a drop):
		 * stay on it; if that lasts, step off and on */
		if (b->fetch.stand_since == 0.0) b->fetch.stand_since = e->now;
		if (e->now - b->fetch.stand_since > 4.0) {
			b->fetch.stand_since = 0.0;
			return BT_FAILURE;
		}
	} else {
		b->fetch.stand_since = 0.0;
	}
	return BT_RUNNING;
}

/* --- carry_home ----------------------------------------------------------- */

bt_status bc_do_carry_home(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const bc_senses *s = &b->senses;
	int team = me->team, i, n = 0, st, changed = 0;
	bc_nav_danger found[BC_AVOID_MAX];
	float fd[BC_AVOID_MAX];
	bl_vec3 home;

	(void)dt;
	if (!bc_carrying(b) || !e->w.tent[team - 1].present) {
		b->carry.n = 0;
		return bc_carrying(b) ? BT_FAILURE : BT_SUCCESS;
	}
	home = e->w.tent[team - 1].pos;
	/* the nearest enemies it knows of: the route keeps away from them */
	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		float d;
		int k, at;

		if (!s->k[i].visible && bc_senses_confidence(s, &e->sense, i, e->now) < 0.5f)
			continue;
		d = flat(s->k[i].pos, me->pos);
		if (d > 70.0f || flat(s->k[i].pos, home) < 10.0f)
			continue;           /* far off, or sitting on the base: no way round that */
		for (at = 0; at < n && fd[at] <= d; at++)
			;
		if (at >= BC_AVOID_MAX)
			continue;
		if (n < BC_AVOID_MAX) n++;
		for (k = n - 1; k > at; k--) { found[k] = found[k - 1]; fd[k] = fd[k - 1]; }
		found[at].x = s->k[i].pos.x; found[at].y = s->k[i].pos.y;
		found[at].radius = 18.0f; found[at].weight = 3.0f;
		fd[at] = d;
	}
	if (n != b->carry.n)
		changed = 1;
	for (i = 0; i < n && !changed; i++) {
		float dx = found[i].x - b->carry.avoid[i].x, dy = found[i].y - b->carry.avoid[i].y;

		changed = dx * dx + dy * dy > 8.0f * 8.0f;
	}
	if (changed && e->now >= b->carry.plan_at) {
		memcpy(b->carry.avoid, found, sizeof found);
		b->carry.n = (uint8_t)n;
		b->carry.plan_at = e->now + 2.0;
		bc_move_replan(b);
	}
	st = bc_move_to(b, home, 1.0f);
	/* it does not stop to duel: only a man it is about to run into */
	if (s->nearest >= 0 && flat(s->k[s->nearest].pos, me->pos) < (a->count > 0 && a->num[0] > 0.0f ? a->num[0] : 14.0f))
		bc_fire_at_will(b);
	if (st == BC_MV_FAILED) {
		if (b->carry.n) {
			b->carry.n = 0;     /* no way round them: through, then */
			return BT_RUNNING;
		}
		return BT_FAILURE;
	}
	return BT_RUNNING;          /* until the server takes it (the tree sees carrying end) */
}

/* --- escort --------------------------------------------------------------- */

bt_status bc_do_escort(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int team = me->team;
	bl_vec3 c, station;
	float dx = 0.0f, dy = 0.0f, l, side;

	(void)a; (void)dt;
	if (!bc_objective_place(b, "carrier", &c))
		return BT_FAILURE;
	bc_fire_at_will(b);
	if (e->w.tent[team - 1].present) {
		dx = e->w.tent[team - 1].pos.x - c.x;
		dy = e->w.tent[team - 1].pos.y - c.y;
	}
	l = sqrtf(dx * dx + dy * dy);
	if (l < 1.0f) { dx = 1.0f; dy = 0.0f; l = 1.0f; }
	side = sinf(b->station_bearing) >= 0.0f ? 3.0f : -3.0f;
	/* ahead of him on his way, and to a side: not in his path */
	station.x = c.x + dx / l * 6.0f - dy / l * side;
	station.y = c.y + dy / l * 6.0f + dx / l * side;
	station.z = c.z;
	if (l < 8.0f)
		station = c;            /* he is nearly home: with him */
	if (flat(me->pos, station) < 3.0f) {
		b->wish.move = BC_MOVE_NONE;
		return BT_RUNNING;
	}
	go(b, station, 1.0f, 4.0f);
	return BT_RUNNING;
}

/* --- intercept ------------------------------------------------------------ */

bt_status bc_do_intercept(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	int team = bc_me(b)->team, thief;
	bl_vec3 p;

	if (team < 1 || team > 2 || !bc_objective_place(b, "intercept", &p))
		return BT_FAILURE;      /* nobody has it (any more) */
	thief = e->w.intel[bc_obj_ours(e, team)].holder;   /* (there is one: intercept found him) */
	if (b->senses.k[thief].visible) {
		bt_status r;

		b->fight.target = thief;        /* him before anybody */
		r = bc_do_fight(b, a, dt);
		return r == BT_FAILURE ? BT_RUNNING : r;
	}
	go(b, p, 3.0f, 6.0f);
	bc_fire_at_will(b);
	return BT_RUNNING;
}

/* --- guard [place] [secs] ------------------------------------------------- */

bt_status bc_do_guard(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bl_vec3 place, from;
	int st;

	(void)dt;
	if (!bc_place_of(b, a->count > 0 ? a->text[0] : "own_intel", &place))
		return BT_FAILURE;
	if (!b->guard.started || flat(place, b->guard.place) > 10.0f) {
		float secs = a->count > 1 && a->num[1] > 0.0f ? a->num[1] : 30.0f, yaw, r, dx, dy;
		bc_nav_node n;

		/* a spot of its own, on the side the enemy comes from */
		yaw = b->station_bearing;
		if (bc_enemy_area(b, &from) && flat(from, place) > 10.0f) {
			dx = from.x - place.x; dy = from.y - place.y;
			yaw = atan2f(dy, dx) + 1.2f * sinf(b->station_bearing);
		}
		r = 4.0f + 4.0f * fabsf(cosf(b->station_bearing * 1.7f));
		b->guard.spot = place;
		if (e->have_map && bc_nav_snap_dry(e->map, (int)clampf(place.x + cosf(yaw) * r, 3.0f, 508.0f),
		                                   (int)clampf(place.y + sinf(yaw) * r, 3.0f, 508.0f),
		                                   (int)floorf(place.z + 2.75f), 4, &n)) {
			b->guard.spot.x = (float)n.x + 0.5f;
			b->guard.spot.y = (float)n.y + 0.5f;
			b->guard.spot.z = (float)n.z - 2.25f;
		}
		b->guard.place = place;
		b->guard.started = 1;
		b->guard.until = e->now + (double)secs * (double)bc_rng_range(&b->rng, 0.8f, 1.2f);
	}
	if (e->now >= b->guard.until) {
		b->guard.started = 0;
		return BT_SUCCESS;
	}
	st = bc_move_to(b, b->guard.spot, 1.0f);
	bc_fire_at_will(b);
	if (st == BC_MV_FAILED) {
		b->guard.started = 0;
		return BT_FAILURE;
	}
	if (st == BC_MV_ARRIVED) {
		b->wish.move = BC_MOVE_NONE;
		b->wish.crouch = b->persona.trait[BC_T_CAUTION] > 1.0f;
		if (b->wish.look == BC_LOOK_AHEAD) {
			/* watch the way they come: out from the place, swept */
			float yaw;

			if (!bc_enemy_area(b, &from) || flat(from, me->pos) < 6.0f) {
				from = me->pos;
				from.x += me->pos.x - place.x;
				from.y += me->pos.y - place.y;
			}
			yaw = atan2f(from.y - me->pos.y, from.x - me->pos.x) +
			      0.8f * sinf(0.6f * (float)fmod(e->now, 1000.0) + b->sweep_phase);
			b->wish.look = BC_LOOK_POINT;
			b->wish.look_at.x = me->pos.x + cosf(yaw) * 25.0f;
			b->wish.look_at.y = me->pos.y + sinf(yaw) * 25.0f;
			b->wish.look_at.z = me->pos.z;
		}
	}
	return BT_RUNNING;
}

void bc_do_objective_stop(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	b->e->stats.action_stops++;

	(void)a;
	b->guard.started = 0;
	b->fetch.stand_since = 0.0;
	b->carry.n = 0;
	bc_move_stop(b);
}
