/* skill_squad.c -- Leaders, and the bots that fall in behind them
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * A team of bots that each go their own way reads as a crowd. So, per
 * team, the engine keeps a few LEADERS, drawn at random among the team's
 * members -- bots AND people alike. Nobody is told: a person who is one
 * simply finds a few bots going where he goes.
 *
 *  - HOW MANY: one for every `leaders.per` members (5; 0: none), rounded,
 *    none for a team under three.
 *  - WHO: by lot. A person weighs `leaders.human` (2); a bot 0.5 + 0.4 x
 *    aggression + 0.3 x objective - 0.3 x caution (0.2 to 2): the bold
 *    lead, the careful follow.
 *  - HOW LONG: a term of 2 to 6 minutes, by lot; sooner if he leaves or
 *    changes team, dies twice within a minute, or (a bot) had to drop a
 *    goal it was stuck on (he is not leading anybody anywhere). Then
 *    another is drawn. Looked at twice a second.
 *    The dice are the engine's own (seeded at each map): the same events
 *    and worlds draw the same leaders.
 *
 * FOLLOWERS. A bot that is no leader may attach to one: not at all with
 * teamwork under 0.75 (loners), else to the nearest living leader who has
 * fewer than 4 followers. It looks again every 8 s and when its leader
 * dies. A leader who stays put longer than the bot's patience (10 s + 15
 * x teamwork) is left for half a minute: a man sniping or gone from his
 * keyboard does not hold three bots for ever.
 *
 * `follow leader` (bc_follow_leader) is more than walking behind:
 *  - a STATION of the bot's own, 4.5 voxels from him, at 100 or 150
 *    degrees to one side of the way he faces -- beside and behind, never
 *    in front of his gun, never a queue;
 *  - while he moves the station is where he will be in a second, not
 *    where he is: the bot goes where he goes, it does not chase his heels;
 *  - what he fights it fights: the man a leading bot has chosen, the man
 *    nearest a leading person's sights while he fires, and whoever last
 *    hurt him, are this bot's target if it can see them (bc_squad_target,
 *    asked by the target choice of skill_fight.c, so it holds in any
 *    branch of a tree);
 *  - when he stops it stops near him -- behind the nearest cover from
 *    where the enemy is, if there is some within 9 voxels of him, crouched
 *    there if the cover is low; else at its station, crouched if it is
 *    careful, watching away from him.
 * It is one weighed option in a tree (`option teamwork has_leader`):
 * being shot at, a man in sight, an item to use outweigh it by the
 * ordinary options, and it is taken up again afterwards.
 */
#include <math.h>
#include <string.h>

#include "brain.h"

static float flat(bl_vec3 a, bl_vec3 b)
{
	float dx = a.x - b.x, dy = a.y - b.y;

	return sqrtf(dx * dx + dy * dy);
}

int bc_is_leader(const bc_engine *e, int pid)
{
	int t, i;

	for (t = 0; t < 2; t++)
		for (i = 0; i < e->lead[t].n; i++)
			if (e->lead[t].pid[i] == pid)
				return 1;
	return 0;
}

static void lead_remove(bc_leaders *l, int i)
{
	int k;

	for (k = i; k + 1 < l->n; k++) {
		l->pid[k] = l->pid[k + 1];
		l->until[k] = l->until[k + 1];
		l->deaths[k] = l->deaths[k + 1];
		l->died_at[k] = l->died_at[k + 1];
	}
	l->n--;
}

void bc_leaders_died(bc_engine *e, int pid)
{
	int t, i;

	for (t = 0; t < 2; t++)
		for (i = 0; i < e->lead[t].n; i++)
			if (e->lead[t].pid[i] == pid) {
				bc_leaders *l = &e->lead[t];

				if (e->now - l->died_at[i] > 60.0) l->deaths[i] = 0;
				l->deaths[i]++;
				l->died_at[i] = e->now;
			}
}

void bc_leaders_think(bc_engine *e)
{
	int t, i;

	if (e->now < e->lead_at)
		return;
	e->lead_at = e->now + 0.5;
	for (t = 0; t < 2; t++) {
		bc_leaders *l = &e->lead[t];
		float w[BL_MAX_PLAYERS], sum = 0.0f;
		int members = 0, want;

		for (i = 0; i < BL_MAX_PLAYERS; i++) {
			const bl_player *p = &e->w.players[i];

			w[i] = 0.0f;
			if (p->team != t + 1 || (p->state != BL_ALIVE && p->state != BL_DEAD))
				continue;
			members++;
			if (p->state != BL_ALIVE || bc_is_leader(e, i))
				continue;
			if (p->flags & BL_F_BOT) {
				const bc_bot *b = bc_engine_bot(e, i);
				const float *tr;

				if (!b || e->now - b->stuck_out_at < 60.0) continue;
				tr = b->persona.trait;
				w[i] = 0.5f + 0.4f * tr[BC_T_AGGRESSION] + 0.3f * tr[BC_T_OBJECTIVE] - 0.3f * tr[BC_T_CAUTION];
				if (w[i] < 0.2f) w[i] = 0.2f;
				if (w[i] > 2.0f) w[i] = 2.0f;
			} else {
				w[i] = e->lead_human;
			}
			sum += w[i];
		}
		want = e->lead_per > 0 && members >= 3 ? (members + e->lead_per / 2) / e->lead_per : 0;
		if (want < 1 && e->lead_per > 0 && members >= 3) want = 1;
		if (want > BC_LEADERS_MAX) want = BC_LEADERS_MAX;
		for (i = l->n - 1; i >= 0; i--) {
			const bl_player *p = &e->w.players[l->pid[i]];
			const bc_bot *lb = bc_engine_bot(e, l->pid[i]);

			if (p->team != t + 1 || (p->state != BL_ALIVE && p->state != BL_DEAD) ||
			    (lb && e->now - lb->stuck_out_at < 60.0) ||
			    e->now >= l->until[i] || (l->deaths[i] >= 2 && e->now - l->died_at[i] < 60.0))
				lead_remove(l, i);
		}
		while (l->n > want)
			lead_remove(l, l->n - 1);
		while (l->n < want && sum > 0.0f) {
			float x = bc_rng_float(&e->rng) * sum;
			int pick = -1;

			for (i = 0; i < BL_MAX_PLAYERS; i++) {
				if (w[i] <= 0.0f) continue;
				pick = i;
				if (x < w[i]) break;
				x -= w[i];
			}
			if (pick < 0)
				break;
			sum -= w[pick];
			w[pick] = 0.0f;
			l->pid[l->n] = (uint8_t)pick;
			l->until[l->n] = e->now + (double)bc_rng_range(&e->rng, 120.0f, 360.0f);
			l->deaths[l->n] = 0;
			l->died_at[l->n] = -1e9;
			l->n++;
		}
	}
}

static int followers_of(const bc_engine *e, int leader, const bc_bot *but)
{
	int i, n = 0;

	for (i = 0; i < e->max_bots; i++) {
		const bc_bot *o = &e->bots[i];

		if (o->used && o->alive && o != but && o->squad.leader == leader && e->now >= o->squad.off_until)
			n++;
	}
	return n;
}

int bc_leader_of(bc_bot *b)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int team = me->team, i, cur = b->squad.leader;
	const bc_leaders *l;

	if (team < 1 || team > 2 || e->lead_per <= 0 || bc_is_leader(e, b->pid) ||
	    b->persona.trait[BC_T_TEAMWORK] < 0.75f || e->now < b->squad.off_until) {
		b->squad.leader = -1;
		return -1;
	}
	l = &e->lead[team - 1];
	if (cur >= 0 && (!bc_is_leader(e, cur) || e->w.players[cur].state != BL_ALIVE ||
	                 e->w.players[cur].team != team))
		cur = -1;
	if (cur < 0 || e->now >= b->squad.eval_at) {
		float best = 1e30f;
		int pick = -1;

		for (i = 0; i < l->n; i++) {
			const bl_player *p = &e->w.players[l->pid[i]];
			float d;

			if (p->state != BL_ALIVE || followers_of(e, l->pid[i], b) >= 4)
				continue;
			d = flat(p->pos, me->pos) - (l->pid[i] == cur ? 15.0f : 0.0f);     /* the one it has, rather */
			if (d < best) { best = d; pick = l->pid[i]; }
		}
		if (pick != cur)
			b->squad.still_since = e->now;
		cur = pick;
		b->squad.eval_at = e->now + 8.0;
	}
	b->squad.leader = (int16_t)cur;
	return cur;
}

int bc_leader_fighting(const bc_engine *e, int leader)
{
	const bl_player *p;
	const bc_bot *lb;

	if (leader < 0)
		return 0;
	p = &e->w.players[leader];
	lb = bc_engine_bot((bc_engine *)(uintptr_t)e, leader);
	if (lb)
		return lb->fight.target >= 0 && lb->senses.k[lb->fight.target].visible;
	return (p->flags & BL_F_FIRING) != 0 || e->now - e->hurt_at[leader] < 3.0;
}

int bc_squad_target(bc_bot *b)
{
	bc_engine *e = b->e;
	const bc_senses *s = &b->senses;
	int leader = b->squad.leader, i, best = -1;
	const bl_player *p;
	const bc_bot *lb;
	float bd = 0.9f;

	if (leader < 0 || e->now < b->squad.off_until || e->w.players[leader].state != BL_ALIVE)
		return -1;
	p = &e->w.players[leader];
	if (flat(p->pos, bc_me(b)->pos) > 40.0f)
		return -1;
	lb = bc_engine_bot(e, leader);
	if (lb && lb->fight.target >= 0 && s->k[lb->fight.target].visible)
		return lb->fight.target;
	if (!lb && (p->flags & BL_F_FIRING)) {
		/* the man nearest his sights, of those this bot sees */
		for (i = 0; i < BL_MAX_PLAYERS; i++) {
			float dx, dy, dz, l, c;

			if (!s->k[i].visible) continue;
			dx = e->w.players[i].pos.x - p->pos.x; dy = e->w.players[i].pos.y - p->pos.y;
			dz = e->w.players[i].pos.z - p->pos.z;
			l = sqrtf(dx * dx + dy * dy + dz * dz);
			if (l < 1e-3f) continue;
			c = (dx * p->ori.x + dy * p->ori.y + dz * p->ori.z) / l;
			if (c > bd) { bd = c; best = i; }
		}
		if (best >= 0)
			return best;
	}
	if (e->now - e->hurt_at[leader] < 5.0 && e->hurt_by[leader] != BL_NO_PLAYER &&
	    s->k[e->hurt_by[leader]].visible)
		return e->hurt_by[leader];
	return -1;
}

bt_status bc_follow_leader(bc_bot *b)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b), *p;
	const float *t = b->persona.trait;
	int leader = bc_leader_of(b), i, slot = 0;
	float hx, hy, hl, speed, a, ca, sa, sx, sy;
	bl_vec3 station;

	if (leader < 0)
		return BT_FAILURE;
	p = &e->w.players[leader];
	speed = sqrtf(p->vel.x * p->vel.x + p->vel.y * p->vel.y) * 32.0f;
	if (speed > 1.0f || flat(p->pos, b->squad.still_at) > 3.0f) {
		b->squad.still_since = e->now;
		b->squad.still_at = p->pos;
	}
	if (e->now - b->squad.still_since > 10.0 + 15.0 * (double)t[BC_T_TEAMWORK] && !bc_leader_fighting(e, leader)) {
		/* he is not going anywhere: its own way for a while */
		b->squad.off_until = e->now + 30.0;
		b->squad.leader = -1;
		return BT_FAILURE;
	}
	/* which of his followers it is: its side and its angle */
	for (i = 0; i < e->max_bots; i++) {
		const bc_bot *o = &e->bots[i];

		if (o->used && o->alive && o != b && o->squad.leader == leader && o->pid < b->pid)
			slot++;
	}
	/* the way he goes, else the way he faces */
	hx = speed > 2.0f ? p->vel.x : p->ori.x;
	hy = speed > 2.0f ? p->vel.y : p->ori.y;
	hl = sqrtf(hx * hx + hy * hy);
	if (hl < 1e-4f) { hx = 1.0f; hy = 0.0f; hl = 1.0f; }
	hx /= hl; hy /= hl;
	a = ((slot & 2) ? 2.6f : 1.75f) * ((slot & 1) ? -1.0f : 1.0f);
	ca = cosf(a); sa = sinf(a);
	sx = hx * ca - hy * sa;
	sy = hx * sa + hy * ca;
	station.x = p->pos.x + sx * 4.5f;
	station.y = p->pos.y + sy * 4.5f;
	station.z = p->pos.z;
	if (speed > 2.0f) {
		/* where he will be in a second */
		station.x += p->vel.x * 32.0f;
		station.y += p->vel.y * 32.0f;
	}
	{
		int tg = bc_squad_target(b);

		if (tg >= 0) b->fight.target = tg;
	}
	bc_fire_at_will(b);
	if (speed <= 1.0f && e->now - b->squad.still_since > 1.5 && e->have_map) {
		/* HE HAS STOPPED: not a ring of men standing in the open round
		 * him. Each takes the cover nearest its station from where the
		 * enemy is (the man being fought, a hit's source, else his
		 * area), if there is some within 9 of the leader. */
		bl_vec3 th;

		if ((bc_threat_place(b, &th) || bc_enemy_area(b, &th)) &&
		    bc_cover_query(b, th, BC_COVER_HIDE, NULL, 9, 48) && b->cq.found && flat(b->cq.best, p->pos) < 9.0f) {
			if (flat(me->pos, b->cq.best) > 0.7f && b->cq.best_d > 0) {
				bc_move_to(b, b->cq.best, 0.0f);
				return BT_RUNNING;
			}
			b->wish.move = BC_MOVE_NONE;
			b->wish.crouch = b->cq.crouch || t[BC_T_CAUTION] > 1.1f;
			if (b->wish.look == BC_LOOK_AHEAD) {
				b->wish.look = BC_LOOK_POINT;
				b->wish.look_at = th;
			}
			return BT_RUNNING;
		}
	}
	if (flat(me->pos, station) < (speed > 2.0f ? 2.0f : 3.0f) && fabsf(p->pos.z - me->pos.z) < 4.0f) {
		b->wish.move = BC_MOVE_NONE;
		if (speed <= 1.0f) {
			b->wish.crouch = t[BC_T_CAUTION] > 1.1f && e->now - b->squad.still_since > 2.0;
			if (b->wish.look == BC_LOOK_AHEAD) {
				/* watch outward: away from him, swept */
				float yaw = atan2f(sy, sx) + 0.6f * sinf(0.5f * (float)fmod(e->now, 1000.0) + b->sweep_phase);

				b->wish.look = BC_LOOK_POINT;
				b->wish.look_at.x = me->pos.x + cosf(yaw) * 20.0f;
				b->wish.look_at.y = me->pos.y + sinf(yaw) * 20.0f;
				b->wish.look_at.z = me->pos.z;
			}
		}
		return BT_RUNNING;
	}
	if (b->mv.goal_set && b->mv.state != BC_MV_IDLE && b->mv.state != BC_MV_FAILED &&
	    flat(b->wish.goal, station) < (speed > 2.0f ? 7.0f : 2.5f))
		station = b->wish.goal;
	if (bc_move_to(b, station, 1.0f) == BC_MV_FAILED) {
		/* no way to his side: to him */
		bc_move_to(b, p->pos, 2.0f);
	}
	return BT_RUNNING;
}
