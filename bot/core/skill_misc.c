/* skill_misc.c -- The other leaves: go, look into, roam, follow, hold,
 * retreat, ping, use, lamp, obey
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * Each is asked again at every decision and re-states its wishes
 * (skills.h); what it remembers is in the bot. The reasons that are
 * aosbot's are marked; retreat, ping and use are new and their numbers
 * are first guesses.
 *
 *  - INVESTIGATE. aosbot turned its head to a noise and never its feet.
 *    Here the bot goes: to within sight of the place, then looks round
 *    it (three looks, a second or so each) with the human aim, and then
 *    FORGETS that place -- or it would go back to it for ever.
 *  - ROAM is never "stand". With nothing known a bot walks to where its
 *    team last met the other (the engine remembers), else to the other
 *    team's base, else anywhere -- the floor nearest its own level, not
 *    the topmost (aosbot's bots took to the roofs), never the sea.
 *  - FOLLOW keeps a station 3 voxels from its man at a bearing of the
 *    bot's own (aosbot kStation), so three followers are not a queue.
 *  - HOLD watches: the head sweeps +-29 degrees about the bearing to
 *    where the enemy is thought to be, 14 s a sweep (aosbot's standing
 *    watch); a head held still is a tripod.
 *  - RETREAT is to a place the threat cannot see (bc_find_cover), at a
 *    run, back turned; it ends hidden, or after 10 s.
 *  - PING. A bot low on teamwork lets occasions pass (half the time at
 *    teamwork 1) and waits longer before the next (10 s / teamwork). A
 *    place the team already has a ping of that kind near is not pinged
 *    again. The server allows a ping a second from one player.
 *  - USE asks the server to use an inventory item ("inv <name> [x y
 *    z]"). The engine knows no item by name: what it holds is told
 *    (item.<name>=<count>), when to use it is the item's own tree.
 */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "brain.h"

static float flat_dist(bl_vec3 a, bl_vec3 b)
{
	float dx = a.x - b.x, dy = a.y - b.y;

	return sqrtf(dx * dx + dy * dy);
}

int bc_mates_within(const bc_bot *b, bl_vec3 at, float radius)
{
	const bl_player *me = bc_me(b);
	int i, n = 0;

	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		const bl_player *p = &b->e->w.players[i];

		if (i != b->pid && p->state == BL_ALIVE && p->team == me->team &&
		    flat_dist(p->pos, at) <= radius)
			n++;
	}
	return n;
}

int bc_nearest_mate(const bc_bot *b, float *dist)
{
	const bl_player *me = bc_me(b);
	float best = 1e30f;
	int i, who = -1;

	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		const bl_player *p = &b->e->w.players[i];
		float d;

		if (i == b->pid || p->state != BL_ALIVE || p->team != me->team)
			continue;
		d = flat_dist(p->pos, me->pos);
		if (d < best) { best = d; who = i; }
	}
	if (dist) *dist = best;
	return who;
}

int bc_enemy_group(bc_bot *b, int n, float radius, bl_vec3 *out)
{
	bc_engine *e = b->e;
	const bc_senses *s = &b->senses;
	int i, j, best = 0;

	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		bl_vec3 sum;
		int c = 0;

		if (!s->k[i].visible && bc_senses_confidence(s, &e->sense, i, e->now) < 0.6f)
			continue;
		sum.x = sum.y = sum.z = 0.0f;
		for (j = 0; j < BL_MAX_PLAYERS; j++) {
			float dx, dy, dz;

			if (!s->k[j].visible && bc_senses_confidence(s, &e->sense, j, e->now) < 0.6f)
				continue;
			dx = s->k[j].pos.x - s->k[i].pos.x;
			dy = s->k[j].pos.y - s->k[i].pos.y;
			dz = s->k[j].pos.z - s->k[i].pos.z;
			if (dx * dx + dy * dy + dz * dz > radius * radius)
				continue;
			sum.x += s->k[j].pos.x; sum.y += s->k[j].pos.y; sum.z += s->k[j].pos.z;
			c++;
		}
		if (c >= n && c > best) {
			best = c;
			if (out) {
				out->x = sum.x / (float)c; out->y = sum.y / (float)c; out->z = sum.z / (float)c;
			}
		}
	}
	return best;
}

int bc_place_of(bc_bot *b, const char *name, bl_vec3 *out)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const bc_senses *s = &b->senses;
	int team = me->team, other = team == 1 ? 2 : 1, i;

	if (!name || !strcmp(name, "self")) { *out = me->pos; return 1; }
	if (!strcmp(name, "enemy")) {
		i = b->fight.target >= 0 ? b->fight.target : s->nearest >= 0 ? s->nearest : s->nearest_known;
		if (i < 0) return 0;
		*out = s->k[i].pos;
		return 1;
	}
	if (!strcmp(name, "last_seen")) {
		if (!s->lost.valid || e->now - s->lost.at > (double)e->sense.memory) return 0;
		*out = s->lost.pos;
		return 1;
	}
	if (!strcmp(name, "noise")) {
		if (!s->noise.valid || e->now - s->noise.at > (double)e->sense.noise_secs) return 0;
		*out = s->noise.pos;
		return 1;
	}
	if (!strcmp(name, "threat")) {
		if (!s->threat.valid || e->now - s->threat.at > 8.0) return 0;
		*out = s->threat.pos;
		return 1;
	}
	if (!strcmp(name, "search"))
		return bc_senses_search(s, &e->sense, e->now, out, NULL);
	if (!strcmp(name, "ping") || !strcmp(name, "caller")) {
		if (!b->ping.taken || e->now >= b->ping.until) return 0;
		*out = b->ping.pos;
		if (name[0] == 'c' || b->ping.kind == BC_PING_HELP) {
			const bl_player *p = &e->w.players[b->ping.by];

			if (p->state == BL_ALIVE) *out = p->pos;
		}
		return 1;
	}
	if (!strcmp(name, "order")) {
		if (b->order.order == BL_O_NONE) return 0;
		if (b->order.order == BL_O_HUNT || b->order.order == BL_O_FOLLOW) {
			if (e->w.players[b->order.target].state != BL_ALIVE) return 0;
			*out = e->w.players[b->order.target].pos;
		} else {
			*out = b->order.pos;
		}
		return 1;
	}
	if (!strcmp(name, "mate")) {
		i = bc_nearest_mate(b, NULL);
		if (i < 0) return 0;
		*out = e->w.players[i].pos;
		return 1;
	}
	if (!strcmp(name, "enemy_group") || !strcmp(name, "group"))
		return bc_enemy_group(b, 2, 6.0f, out) > 0;
	if (!strcmp(name, "cover")) {
		bl_vec3 th;

		if (!bc_place_of(b, "enemy", &th) && !bc_place_of(b, "threat", &th)) return 0;
		return bc_find_cover(b, th, out);
	}
	if (!strcmp(name, "thief") || !strcmp(name, "carrier") || !strcmp(name, "intercept"))
		return bc_objective_place(b, name, out);
	if (!strcmp(name, "leader")) {
		i = bc_leader_of(b);
		if (i < 0) return 0;
		*out = e->w.players[i].pos;
		return 1;
	}
	if (!strcmp(name, "enemy_area"))
		return bc_enemy_area(b, out);
	if (!strcmp(name, "rumour"))
		return bc_rumour(b, out) > 0.0f;
	if (!strcmp(name, "vantage")) {
		int i = bc_perch_pick(b, 0);

		if (i < 0 || team < 1 || team > 2) return 0;
		out->x = (float)e->vantage[team - 1].p[i].n.x + 0.5f;
		out->y = (float)e->vantage[team - 1].p[i].n.y + 0.5f;
		out->z = (float)e->vantage[team - 1].p[i].n.z - 2.25f;
		return 1;
	}
	if (team < 1 || team > 2)
		return 0;
	if (!strcmp(name, "hot")) {
		if (e->now - e->hot_at[team - 1] > 60.0) return 0;
		*out = e->hot[team - 1];
		return 1;
	}
	{
		const bl_object *o = NULL;

		if (!strcmp(name, "enemy_base") || !strcmp(name, "their_base")) o = &e->w.tent[other - 1];
		else if (!strcmp(name, "own_base")) o = &e->w.tent[team - 1];
		else if (!strcmp(name, "enemy_intel") || !strcmp(name, "their_intel")) o = &e->w.intel[other - 1];
		else if (!strcmp(name, "own_intel") || !strcmp(name, "our_intel")) o = &e->w.intel[team - 1];
		if (!o || !o->present) return 0;
		*out = o->pos;
		return 1;
	}
}

bc_item *bc_item_find(bc_bot *b, const char *name, int make)
{
	int i;

	for (i = 0; i < BC_ITEMS_MAX; i++)
		if (b->items[i].name[0] && !strcmp(b->items[i].name, name))
			return &b->items[i];
	if (!make || strlen(name) >= sizeof b->items[0].name)
		return NULL;
	for (i = 0; i < BC_ITEMS_MAX; i++)
		if (!b->items[i].name[0] || b->items[i].count == 0) {
			memset(&b->items[i], 0, sizeof b->items[i]);
			strcpy(b->items[i].name, name);
			return &b->items[i];
		}
	return NULL;
}

int bc_item_count(const bc_bot *b, const char *name)
{
	int i;

	for (i = 0; i < BC_ITEMS_MAX; i++)
		if (b->items[i].name[0] && !strcmp(b->items[i].name, name))
			return b->items[i].count;
	return 0;
}

void bc_do_stop(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a;
	b->nade.phase = 0;
	b->inv.phase = 0;
	b->hold.started = 0;
	b->cover.valid = 0;
	bc_move_stop(b);
}

/* --- go_to <place> [radius] -------------------------------------------- */

bt_status bc_do_go_to(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bl_vec3 p;
	int st;

	(void)dt;
	if (!bc_place_of(b, a->count > 0 ? a->text[0] : "self", &p))
		return BT_FAILURE;
	/* a place that moves (a man): keep the route while it is near enough */
	if (b->mv.goal_set && flat_dist(b->wish.goal, p) < 3.0f &&
	    b->mv.state != BC_MV_IDLE)
		p = b->wish.goal;
	st = bc_move_to(b, p, a->count > 1 && a->num[1] > 0.0f ? a->num[1] : 2.0f);
	bc_fire_at_will(b);
	if (st != BC_MV_ARRIVED && st != BC_MV_FAILED) return BT_RUNNING;
	/* a ping gone to (or that cannot be) is answered */
	if (a->count > 0 && (!strcmp(a->text[0], "ping") || !strcmp(a->text[0], "caller")))
		b->ping.taken = 0;
	return st == BC_MV_ARRIVED ? BT_SUCCESS : BT_FAILURE;
}

/* --- looking round ------------------------------------------------------ */

static bt_status look_round(bc_bot *b)
{
	static const float turn[3] = { -1.2f, 1.2f, 3.0f };
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	float yaw;

	if (b->inv.looks == 0 && b->inv.until == 0.0) {
		b->inv.base_yaw = atan2f(me->ori.y, me->ori.x);
		b->inv.until = e->now + (double)bc_rng_range(&b->rng, 0.7f, 1.3f);
	}
	if (e->now >= b->inv.until) {
		if (++b->inv.looks >= 3) {
			b->inv.looks = 0;
			b->inv.until = 0.0;
			return BT_SUCCESS;
		}
		b->inv.until = e->now + (double)bc_rng_range(&b->rng, 0.7f, 1.3f);
	}
	yaw = b->inv.base_yaw + turn[b->inv.looks];
	b->wish.move = BC_MOVE_NONE;
	b->wish.look = BC_LOOK_POINT;
	b->wish.look_at.x = me->pos.x + cosf(yaw) * 12.0f;
	b->wish.look_at.y = me->pos.y + sinf(yaw) * 12.0f;
	b->wish.look_at.z = me->pos.z;
	bc_fire_at_will(b);
	return BT_RUNNING;
}

bt_status bc_do_look_around(void *bot, const bt_args *a, float dt)
{
	(void)a; (void)dt;
	return look_round(bot);
}

bt_status bc_do_investigate(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bl_vec3 p;
	int what, st;

	(void)a; (void)dt;
	if (b->inv.phase == 2) {
		if (look_round(b) == BT_RUNNING)
			return BT_RUNNING;
		bc_senses_searched(&b->senses, b->inv.what);
		b->inv.phase = 0;
		return BT_SUCCESS;
	}
	if (!bc_senses_search(&b->senses, &e->sense, e->now, &p, &what)) {
		b->inv.phase = 0;
		return BT_FAILURE;
	}
	if (b->inv.phase == 0 || what != b->inv.what || flat_dist(p, b->inv.place) > 8.0f) {
		b->inv.phase = 1;
		b->inv.what = (uint8_t)what;
		b->inv.place = p;
		b->inv.looks = 0;
		b->inv.until = 0.0;
	}
	st = bc_move_to(b, b->inv.place, 3.0f);
	b->wish.look = BC_LOOK_POINT;
	b->wish.look_at = b->inv.place;
	bc_fire_at_will(b);
	if (st == BC_MV_FAILED) {
		bc_senses_searched(&b->senses, b->inv.what);
		b->inv.phase = 0;
		return BT_FAILURE;
	}
	/* there, or near enough to see the place: look round */
	if (st == BC_MV_ARRIVED || (flat_dist(me->pos, b->inv.place) < 6.0f &&
	    bc_sight_clear(e->have_map ? e->map : NULL, me->pos, b->inv.place)))
		b->inv.phase = 2;
	return BT_RUNNING;
}

/* --- roam --------------------------------------------------------------- */

bt_status bc_do_roam(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	int st;

	(void)a; (void)dt;
	if (!b->roam.valid || e->now >= b->roam.until) {
		if (!bc_roam_goal(b, &b->roam.goal)) {
			/* nowhere found. Not "walk the way it faces": a bot in the sea
			 * did that against a bank for minutes. To the nearest dry
			 * floor if it is not on one; else it stands. */
			const bl_player *me = bc_me(b);
			bc_nav_node n;

			if (e->have_map && bc_nav_snap_dry(e->map, (int)floorf(me->pos.x), (int)floorf(me->pos.y),
			                                   (int)floorf(me->pos.z + 2.75f), 64, &n) &&
			    (n.x != (int)floorf(me->pos.x) || n.y != (int)floorf(me->pos.y))) {
				bl_vec3 dry;

				dry.x = (float)n.x + 0.5f; dry.y = (float)n.y + 0.5f; dry.z = (float)n.z - 2.25f;
				bc_move_to(b, dry, 1.0f);
			}
			bc_fire_at_will(b);
			return BT_RUNNING;
		}
		b->roam.valid = 1;
		b->roam.until = e->now + (double)bc_rng_range(&b->rng, 20.0f, 40.0f);
	}
	st = bc_move_to(b, b->roam.goal, 2.0f);
	bc_fire_at_will(b);
	if (st == BC_MV_ARRIVED || st == BC_MV_FAILED)
		b->roam.valid = 0;      /* there, or no way: somewhere else next time */
	return BT_RUNNING;
}

/* --- follow [mate|caller|order] ----------------------------------------- */

static bt_status follow_pid(bc_bot *b, int who)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b), *p;
	bl_vec3 station;

	if (who < 0 || who >= BL_MAX_PLAYERS || e->w.players[who].state != BL_ALIVE)
		return BT_FAILURE;
	p = &e->w.players[who];
	bc_fire_at_will(b);
	if (flat_dist(p->pos, me->pos) < 5.0f && fabsf(p->pos.z - me->pos.z) < 3.0f) {
		b->wish.move = BC_MOVE_NONE;
		if (b->wish.look == BC_LOOK_AHEAD) {
			/* look where he looks */
			b->wish.look = BC_LOOK_POINT;
			b->wish.look_at.x = me->pos.x + p->ori.x * 20.0f;
			b->wish.look_at.y = me->pos.y + p->ori.y * 20.0f;
			b->wish.look_at.z = me->pos.z;
		}
		return BT_RUNNING;
	}
	station.x = p->pos.x + cosf(b->station_bearing) * 3.0f;
	station.y = p->pos.y + sinf(b->station_bearing) * 3.0f;
	station.z = p->pos.z;
	if (b->mv.goal_set && b->mv.state != BC_MV_IDLE &&
	    b->mv.state != BC_MV_FAILED && flat_dist(b->wish.goal, station) < 4.0f)
		station = b->wish.goal;
	bc_move_to(b, station, 1.0f);
	return BT_RUNNING;
}

bt_status bc_do_follow(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const char *who = a->count > 0 ? a->text[0] : "mate";

	(void)dt;
	if (!strcmp(who, "leader"))
		return bc_follow_leader(b);
	if (!strcmp(who, "caller"))
		return b->ping.taken && e->now < b->ping.until ? follow_pid(b, b->ping.by) : BT_FAILURE;
	if (!strcmp(who, "order"))
		return b->order.order != BL_O_NONE ? follow_pid(b, b->order.target) : BT_FAILURE;
	b->following = 1;
	if (e->now < b->follow.cd_until)
		return BT_FAILURE;
	if (b->follow.leader < 0 || e->now >= b->follow.pick_at ||
	    e->w.players[b->follow.leader].state != BL_ALIVE ||
	    e->w.players[b->follow.leader].team != bc_me(b)->team) {
		/* the nearest team-mate who is not himself following somebody:
		 * two that follow each other stand and wait for ever */
		const bl_player *me = bc_me(b);
		float best = 1e30f;
		int i;

		b->follow.leader = -1;
		for (i = 0; i < BL_MAX_PLAYERS; i++) {
			const bl_player *p = &e->w.players[i];
			const bc_bot *o = bc_engine_bot(e, i);
			float d;

			if (i == b->pid || p->state != BL_ALIVE || p->team != me->team || (o && o->following))
				continue;
			d = flat_dist(p->pos, me->pos);
			if (d < best) { best = d; b->follow.leader = i; }
		}
		b->follow.pick_at = e->now + 12.0;
		b->follow.still_since = e->now;
	}
	if (b->follow.leader >= 0) {
		const bl_player *p = &e->w.players[b->follow.leader];

		/* a man who stays put is not going anywhere: after a while, its own way */
		if (p->vel.x * p->vel.x + p->vel.y * p->vel.y > 0.001f || flat_dist(p->pos, bc_me(b)->pos) > 8.0f)
			b->follow.still_since = e->now;
		if (e->now - b->follow.still_since > 4.0 + 4.0 * (double)b->persona.trait[BC_T_TEAMWORK]) {
			b->follow.leader = -1;
			b->follow.cd_until = e->now + 20.0;
			return BT_FAILURE;
		}
	}
	return follow_pid(b, b->follow.leader);
}

/* --- hold [place] [secs] ------------------------------------------------ */

static void watch(bc_bot *b)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bl_vec3 to;
	float yaw;

	if (b->wish.look != BC_LOOK_AHEAD)
		return;
	if (!bc_place_of(b, "search", &to) && !bc_place_of(b, "hot", &to) &&
	    !bc_place_of(b, "enemy_base", &to))
		return;
	if (flat_dist(to, me->pos) < 4.0f)
		return;
	yaw = atan2f(to.y - me->pos.y, to.x - me->pos.x) +
	      0.5f * sinf(0.45f * (float)fmod(e->now, 1000.0) + b->sweep_phase);
	b->wish.look = BC_LOOK_POINT;
	b->wish.look_at.x = me->pos.x + cosf(yaw) * 20.0f;
	b->wish.look_at.y = me->pos.y + sinf(yaw) * 20.0f;
	b->wish.look_at.z = me->pos.z;
}

static bt_status hold_at(bc_bot *b, bl_vec3 place, double until)
{
	bc_engine *e = b->e;
	int st = bc_move_to(b, place, 1.0f);

	bc_fire_at_will(b);
	if (st == BC_MV_FAILED)
		return BT_FAILURE;
	if (st == BC_MV_ARRIVED) {
		b->wish.move = BC_MOVE_NONE;
		b->wish.crouch = b->persona.trait[BC_T_CAUTION] > 1.2f;
		watch(b);
	}
	if (until >= 0.0 && e->now >= until)
		return BT_SUCCESS;
	return BT_RUNNING;
}

bt_status bc_do_hold(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	bt_status r;

	(void)dt;
	if (!b->hold.started) {
		if (!bc_place_of(b, a->count > 0 ? a->text[0] : "self", &b->hold.place))
			return BT_FAILURE;
		b->hold.started = 1;
		b->hold.until = e->now + (double)(a->count > 1 && a->num[1] > 0.0f ? a->num[1] : 8.0f);
	}
	r = hold_at(b, b->hold.place, b->hold.until);
	if (r != BT_RUNNING)
		b->hold.started = 0;
	return r;
}

/* --- retreat ------------------------------------------------------------ */

bt_status bc_do_retreat(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bl_vec3 threat;
	int st;

	(void)a; (void)dt;
	if (!bc_place_of(b, "enemy", &threat) && !bc_place_of(b, "threat", &threat)) {
		b->cover.valid = 0;
		return BT_FAILURE;
	}
	if (!b->cover.valid) {
		if (!bc_find_cover(b, threat, &b->cover.goal)) {
			/* nothing to hide behind: away from him */
			float dx = me->pos.x - threat.x, dy = me->pos.y - threat.y;
			float l = sqrtf(dx * dx + dy * dy);

			if (l < 1e-3f) { dx = 1.0f; dy = 0.0f; l = 1.0f; }
			b->cover.goal.x = me->pos.x + dx / l * 18.0f;
			b->cover.goal.y = me->pos.y + dy / l * 18.0f;
			b->cover.goal.z = me->pos.z;
		}
		b->cover.valid = 1;
		b->cover.since = e->now;
		b->cover.until = e->now + 10.0;
	}
	st = bc_move_to(b, b->cover.goal, 1.0f);
	b->wish.fire_pid = -1;
	if (st == BC_MV_FAILED) {
		b->cover.valid = 0;
		return BT_FAILURE;
	}
	if (st == BC_MV_ARRIVED) {
		if (b->senses.n_visible == 0 || e->now >= b->cover.until) {
			b->cover.valid = 0;
			b->cover.since = e->now;
			return BT_SUCCESS;
		}
		b->cover.valid = 0;     /* he can still see it: another place */
		return BT_RUNNING;
	}
	if (e->now >= b->cover.until) {
		b->cover.valid = 0;
		b->cover.since = e->now;
		return BT_SUCCESS;
	}
	return BT_RUNNING;
}

/* --- ping <place> <label...> -------------------------------------------- */

bt_status bc_do_ping(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	float teamwork = b->persona.trait[BC_T_TEAMWORK];
	bl_ac_ping ac;
	size_t n = 0;
	int i, kind;

	(void)dt;
	if (e->now < b->ping.cd_until)
		return BT_FAILURE;
	memset(&ac, 0, sizeof ac);
	if (!bc_place_of(b, a->count > 0 ? a->text[0] : "self", &ac.pos))
		return BT_FAILURE;
	for (i = 1; i < a->count; i++)
		n += (size_t)snprintf(ac.reason + n, sizeof ac.reason - n, "%s%s", i > 1 ? " " : "", a->text[i]);
	if (a->count < 2)
		strcpy(ac.reason, "Enemy");
	kind = bc_ping_kind(ac.reason);
	if (bc_board_pinged(&e->board, me->team, ac.pos, kind, 20.0f, e->now)) {
		b->ping.cd_until = e->now + 2.0;
		return BT_FAILURE;      /* the team knows */
	}
	if (bc_frand(b) > 0.5f * teamwork) {
		b->ping.cd_until = e->now + 4.0;
		return BT_FAILURE;      /* not one to say so */
	}
	if (ac.pos.x < 0.0f) ac.pos.x = 0.0f;
	if (ac.pos.y < 0.0f) ac.pos.y = 0.0f;
	if (ac.pos.z < 0.0f) ac.pos.z = 0.0f;
	if (ac.pos.z > 63.0f) ac.pos.z = 63.0f;
	if (e->host.action)
		e->host.action(e->host.ctx, BL_AC_PING, b->pid, &ac, sizeof ac);
	bc_board_ping(&e->board, me->team, b->pid, ac.pos, kind, e->now, 15.0);
	e->stats.pings++;
	{
		double cd = 10.0 / (double)(teamwork > 0.2f ? teamwork : 0.2f);

		b->ping.cd_until = e->now + (cd < 4.0 ? 4.0 : cd > 30.0 ? 30.0 : cd);
	}
	return BT_SUCCESS;
}

/* --- use <name> [self|enemy|group|<place>] [guide secs] ------------------ */

bt_status bc_do_use(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	float greed = b->persona.trait[BC_T_GREED];
	const char *where = a->count > 1 ? a->text[1] : "self";
	bc_item *it;
	bl_vec3 p;
	char cmd[96];
	float guide = a->count > 2 ? a->num[2] : 0.0f;
	int i, aimed = strcmp(where, "self") != 0, tpid = -1;

	(void)dt;
	if (a->count < 1 || !(it = bc_item_find(b, a->text[0], 0)) || it->count == 0)
		return BT_FAILURE;
	if (e->now < it->cd_until || e->now < b->use_at)
		return BT_FAILURE;
	if (aimed) {
		if (!strcmp(where, "enemy")) {
			/* a man in sight, or where he was a moment ago */
			tpid = b->fight.target >= 0 ? b->fight.target : b->senses.nearest;
			if (tpid < 0) return BT_FAILURE;
			p = b->senses.k[tpid].pos;
			p.z += 1.0f;
		} else if (!bc_place_of(b, where, &p)) {
			return BT_FAILURE;
		}
		snprintf(cmd, sizeof cmd, "inv %s %.1f %.1f %.1f", it->name, (double)p.x, (double)p.y, (double)p.z);
	} else {
		snprintf(cmd, sizeof cmd, "inv %s", it->name);
	}
	if (e->host.action)
		e->host.action(e->host.ctx, BL_AC_COMMAND, b->pid, cmd, (uint32_t)strlen(cmd) + 1);
	e->stats.uses++;
	/* the server says what is left; until it does, count it gone */
	if (it->count > 0)
		it->count--;
	/* a greedy bot is quicker to use the next thing; nobody spams a use
	 * the server may have refused */
	if (greed < 0.3f) greed = 0.3f;
	it->cd_until = e->now + 4.0 / (double)greed;
	b->use_at = e->now + 1.5 / (double)greed;
	for (i = 0; i < e->nidefs; i++)
		if (!e->idefs[i].extra && !strcmp(e->idefs[i].name, it->name) && guide <= 0.0f)
			guide = e->idefs[i].guide;
	if (aimed && guide > 0.0f) {
		b->guide.until = e->now + (double)guide;
		b->guide.pid = tpid;
		b->guide.at = p;
	}
	return BT_SUCCESS;
}

bt_status bc_do_lamp(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	const char *m = a->count > 0 ? a->text[0] : "auto";

	(void)dt;
	b->lamp = !strcmp(m, "on") ? BC_LAMP_ON : !strcmp(m, "off") ? BC_LAMP_OFF : BC_LAMP_AUTO;
	return BT_SUCCESS;
}

bt_status bc_do_reload(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	const bl_player *me = bc_me(b);

	(void)a; (void)dt;
	if (me->tool != BL_TOOL_GUN || me->reserve == 0 || me->mag >= bc_gun(me->gun)->mag ||
	    b->e->now < b->fight.reloading_until)
		return BT_FAILURE;
	b->reload_pulse = 1;
	return BT_SUCCESS;
}

/* --- obey --------------------------------------------------------------- */

bt_status bc_do_obey(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	bc_order *o = &b->order;
	bt_status r;

	if (o->order != BL_O_NONE && o->until >= 0.0 && e->now >= o->until)
		o->order = BL_O_NONE;
	switch (o->order) {
	case BL_O_GOTO:
		r = hold_at(b, o->pos, o->until);
		/* with no time given, a GOTO is done on getting there */
		if (o->until < 0.0 && b->mv.state == BC_MV_ARRIVED && b->wish.move == BC_MOVE_NONE)
			r = BT_SUCCESS;
		break;
	case BL_O_HOLD:
		r = hold_at(b, o->pos, o->until);
		break;
	case BL_O_FOLLOW:
		r = follow_pid(b, o->target);
		break;
	case BL_O_HUNT: {
		const bl_player *t = &e->w.players[o->target];

		if (t->state != BL_ALIVE) { r = BT_SUCCESS; break; }
		if (b->senses.k[o->target].visible) {
			b->fight.target = o->target;
			r = bc_do_fight(b, a, dt);
			if (r == BT_FAILURE) r = BT_RUNNING;
		} else {
			/* the order says who; where he is, it is given to know */
			bl_vec3 p = t->pos;

			if (b->mv.goal_set && b->mv.state != BC_MV_IDLE &&
			    b->mv.state != BC_MV_FAILED && flat_dist(b->wish.goal, p) < 4.0f)
				p = b->wish.goal;
			bc_move_to(b, p, 3.0f);
			bc_fire_at_will(b);
			r = BT_RUNNING;
		}
		break;
	}
	default:
		return BT_FAILURE;
	}
	if (r != BT_RUNNING)
		o->order = BL_O_NONE;
	return r;
}
