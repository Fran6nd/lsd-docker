/* skill_move.c -- Going somewhere: one goal, the shared planner, the follower
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * See skills.h (who owns the head) and nav.h (what the follower
 * promises). What this file adds to nav:
 *
 *  - ONE GOAL A BOT. A skill asks to be somewhere (bc_move_to); asking
 *    again for the same place costs nothing. A new place means a new
 *    plan, and while that waits its turn the old route is walked on if
 *    it leads nearly there (a chase), else the bot brakes.
 *  - THE SEARCHES ARE LENT. The engine has a few (6 MiB each); a bot
 *    holds one only while its plan runs. Who gets expansions first is
 *    who has waited longest (bc_movers_plan).
 *  - ONE SEARCH FOR A TEAM GOING THE SAME WAY (routes.h): before a bot is
 *    lent a search, the route board is asked -- a team-mate's fresh route
 *    to the same goal from near here is joined by a local search onto it;
 *    a team-mate's search for it under way is waited on; else the bot's
 *    own search is a claim, and what it finds goes up for the others.
 *  - WHAT THE FOLLOWER SAYS IS OBEYED AS nav.h PRESCRIBES: a failed step
 *    goes in the shared failure memory (30 s) and the route is planned
 *    again from where the body is; a refused edit protects the voxel,
 *    and twice refused the bot stops editing for a minute (aosbot gave
 *    up digging after a run of refusals: each one costs three seconds);
 *    a stale route or a body off it are planned again.
 *  - EDITS GO THROUGH THE SERVER'S CHECKS (lib_botlink do_block): the
 *    spade in hand to dig and the blocks to build, within 5 of the eye,
 *    never faster than it allows (0.25 s a dig, 0.1 s a block, 0.5 s a
 *    line) -- and slower by level, aosbot's cadence: a dig every 0.70 s
 *    at level 1 down to 0.30, a block every 0.85 down to 0.55. A straight
 *    run of single-block bridge steps whose far end touches something
 *    goes as ONE line (the server wants both ends attached).
 *  - A goal that cannot be reached is left alone for 5 s (aosbot): the
 *    search that proves it is the most expensive there is.
 *  - SHUT IN. A bot in a place with no way out of it (a closed cube, a pit)
 *    found no way to one goal, was given another by its tree, found no
 *    way to that, and so on: a search to the end every few seconds, for
 *    ever, and the bot standing meanwhile (CubeMaze: 240 of 1251 plans,
 *    one bot idle a minute). Now: three searches in a row that find no way
 *    (to whatever goals, within 20 s, no route found between) and the bot
 *    is SHUT IN for 15 s: bc_move_to answers FAILED without a search, and
 *    the engine has it pace and look about where it is (engine.c, decide).
 *    Then one search is let through; if that finds no way it is shut in
 *    again. So: at most about 4 searches a minute from a shut-in bot. With
 *    digging allowed the searches find a way (they dig) and none of this
 *    happens. A goal where it stands is ARRIVED while shut in (hold and
 *    camp work), and the condition `stranded` tells the tree, which decides
 *    what a bot with nowhere to go does (2026-11-25: hold and watch, shoot
 *    from there); the engine's pacing is only for a tree that says nothing.
 *  - NEVER A LOOP (nav.h). Another route to the SAME goal is started with
 *    bc_nav_follow_again, so the follower can count what it has reported
 *    for that goal; when it answers GIVE_UP the goal FAILS, and is
 *    remembered as given up for 20 s (the last four such goals), so the
 *    tree picks something else and does not come straight back.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "brain.h"

static const double FAIL_TTL = 30.0;
static const double UNREACHABLE_SECS = 5.0;
static const double GIVE_UP_SECS = 20.0;

void bc_body_of(const bl_player *p, bc_body *body)
{
	memset(body, 0, sizeof *body);
	body->pos.x = p->pos.x; body->pos.y = p->pos.y; body->pos.z = p->pos.z;
	body->vel.x = p->vel.x; body->vel.y = p->vel.y; body->vel.z = p->vel.z;
	body->keys = p->keys;
	if (p->flags & BL_F_CROUCH) body->keys |= BC_K_CROUCH;
	else body->keys &= (uint8_t)~BC_K_CROUCH;
	body->airborne = (p->flags & BL_F_AIRBORNE) != 0;
	body->wade = (p->flags & BL_F_WADING) != 0;
	body->scoped = (p->flags & BL_F_SCOPED) != 0 && p->tool == BL_TOOL_GUN;
}

void bc_mover_reset(bc_bot *b)
{
	bc_engine_search_release(b->e, b);
	b->mv.state = BC_MV_IDLE;
	b->mv.has_route = 0;
	b->mv.goal_set = 0;
	b->mv.noway = 0;
	b->mv.shut_until = b->mv.stranded_until = 0.0;
	b->mv.nocap = 0;
	b->mv.again = 0;
	b->mv.gave_n = 0;
	memset(b->mv.gave_until, 0, sizeof b->mv.gave_until);
	b->mv.partial_tries = b->mv.restarts = 0;
	b->mv.braking = 0;
	b->mv.refusals = 0;
	b->mv.retry_at = b->mv.edit_at = b->mv.noedit_until = b->mv.tool_grace = 0.0;
	b->mv.edit_tool = BL_TOOL_GUN;
	b->mv.search = -1;
	b->mv.join = 0;
	b->mv.solo = 0;
	memset(&b->mv.cmd, 0, sizeof b->mv.cmd);
}

void bc_move_stop(bc_bot *b)
{
	/* The route is kept: a skill that is asked again next decision (a
	 * pick that chose the same thing) goes on without a new plan. It is
	 * dropped by the next different goal. */
	b->wish.move = BC_MOVE_NONE;
}

static void replan(bc_bot *b, int brake)
{
	bc_engine *e = b->e;

	bc_engine_search_release(e, b);
	b->mv.state = BC_MV_PLANNING;
	b->mv.plan_since = e->now;
	b->mv.has_route = 0;
	b->mv.braking = (uint8_t)brake;
	b->mv.again = 1;
	e->stats.replans++;
}

static int move_to(bc_bot *b, bl_vec3 pos, float radius, int raw);

int bc_move_to(bc_bot *b, bl_vec3 pos, float radius)
{
	return move_to(b, pos, radius, 0);
}

/* The place's own column and floor (the voxel under an eye at `pos`),
 * not the nearest place to stand to it: a floor that is not there yet,
 * for a route that builds it (build_at). */
int bc_move_to_raw(bc_bot *b, bl_vec3 pos, float radius)
{
	return move_to(b, pos, radius, 1);
}

static int move_to(bc_bot *b, bl_vec3 pos, float radius, int raw)
{
	bc_engine *e = b->e;
	bc_mover *mv = &b->mv;
	bc_nav_node n;
	int r = (int)(radius + 0.5f);

	b->wish.move = BC_MOVE_GOTO;
	b->wish.goal = pos;
	b->wish.radius = radius;
	if (!e->have_map)
		return BC_MV_FAILED;
	{
		/* where it stands is reached, without a search (`hold self`
		 * asked a plan of nothing every few seconds, and a plan that
		 * finds the way told a shut-in bot it was free again) -- and while
		 * shut in, nothing farther is asked for */
		const bl_player *me = bc_me(b);
		float dx = pos.x - me->pos.x, dy = pos.y - me->pos.y;

		/* an exact goal (raw) is that floor, not one a voxel off it: a
		 * pillar's next block is one up from where the body stands */
		if (dx * dx + dy * dy <= (radius + 0.75f) * (radius + 0.75f) &&
		    (raw ? (int)floorf(pos.z + 2.25f + 0.5f) == (int)floorf(me->pos.z + 2.25f + 0.5f)
		         : fabsf(pos.z - me->pos.z) < 1.5f) &&
		    !(mv->goal_set && mv->state == BC_MV_FOLLOWING))
			return BC_MV_ARRIVED;
		/* shut in: no search over the map. A goal within the reach of one
		 * move (BC_NAV_JUMP_DMAX columns) is still asked for, by a LOCAL
		 * search (fill_policy: policy.scope) whose cost is bounded by what
		 * is round the body -- a stranded bot building its way out a block
		 * at a time (build_perch) */
		if (e->now < mv->shut_until && (fabsf(dx) > (float)BC_NAV_JUMP_DMAX || fabsf(dy) > (float)BC_NAV_JUMP_DMAX))
			return BC_MV_FAILED;
	}
	if (raw) {
		n.x = (int16_t)floorf(pos.x); n.y = (int16_t)floorf(pos.y); n.z = (int16_t)floorf(pos.z + 2.25f + 0.5f);
		if (!bc_map_in(n.x, n.y, n.z))
			return BC_MV_FAILED;
	} else if (!bc_nav_snap(e->map, (int)floorf(pos.x), (int)floorf(pos.y),
	                        (int)floorf(pos.z + 2.25f + 0.5f), 3, &n)) {
		return BC_MV_FAILED;
	}
	if (mv->goal_set && mv->goal.x == n.x && mv->goal.y == n.y && mv->goal.z == n.z &&
	    mv->radius == r && mv->exact == raw) {
		if (mv->state == BC_MV_FAILED && e->now >= mv->retry_at) {
			/* asked for again: not if the team still knows there is no way */
			const bl_player *me = bc_me(b);
			bc_nav_node from;
			double until;

			from.x = (int16_t)floorf(me->pos.x); from.y = (int16_t)floorf(me->pos.y);
			from.z = (int16_t)floorf(me->pos.z + 2.75f);
			until = bc_unreach_until(b, from, n);
			if (until > e->now) {
				mv->retry_at = until;
				return BC_MV_FAILED;
			}
			mv->state = BC_MV_PLANNING;
			mv->plan_since = e->now;
			mv->partial_tries = 0;
		} else if (mv->state == BC_MV_IDLE) {
			mv->state = BC_MV_PLANNING;
			mv->plan_since = e->now;
		}
		return mv->state;
	}
	/* a new place */
	{
		int dx = mv->goal.x - n.x, dy = mv->goal.y - n.y, i;
		int near = mv->goal_set && dx * dx + dy * dy <= 12 * 12;

		for (i = 0; i < 4; i++)
			if (e->now < mv->gave_until[i] && abs(mv->gave[i].x - n.x) <= 2 &&
			    abs(mv->gave[i].y - n.y) <= 2 && abs(mv->gave[i].z - n.z) <= 2) {
				bc_engine_search_release(e, b);
				mv->goal = n;
				mv->radius = (int16_t)r;
				mv->goal_set = 1;
				mv->has_route = 0;
				mv->state = BC_MV_FAILED;
				mv->retry_at = mv->gave_until[i];
				return BC_MV_FAILED;
			}

		{
			/* a goal the team found no way to from about here: not planned again */
			const bl_player *me = bc_me(b);
			bc_nav_node from;
			double until;

			from.x = (int16_t)floorf(me->pos.x); from.y = (int16_t)floorf(me->pos.y);
			from.z = (int16_t)floorf(me->pos.z + 2.75f);
			until = bc_unreach_until(b, from, n);
			if (until > e->now) {
				bc_engine_search_release(e, b);
				mv->goal = n;
				mv->radius = (int16_t)r;
				mv->goal_set = 1;
				mv->has_route = 0;
				mv->state = BC_MV_FAILED;
				mv->retry_at = until;
				return BC_MV_FAILED;
			}
		}
		bc_engine_search_release(e, b);
		if (!near)
			mv->has_route = 0;
		mv->exact = (uint8_t)raw;
		mv->goal = n;
		mv->radius = (int16_t)r;
		mv->goal_set = 1;
		mv->state = BC_MV_PLANNING;
		mv->plan_since = e->now;
		mv->partial_tries = mv->restarts = 0;
		mv->braking = 0;
		mv->again = 0;
		mv->nocap = 0;
		mv->solo = 0;
	}
	return mv->state;
}

void bc_move_replan(bc_bot *b)
{
	bc_mover *mv = &b->mv;

	if (!mv->goal_set || mv->state != BC_MV_FOLLOWING)
		return;
	bc_engine_search_release(b->e, b);
	mv->state = BC_MV_PLANNING;     /* has_route stays: it walks on meanwhile */
	mv->plan_since = b->e->now;
	mv->again = 1;
	mv->braking = 0;
}

/* --- PLAN -------------------------------------------------------------- */

/* The policy a search for b would be made under, its dangers in `danger`.
 * Returns how many of them are the team's (the first ones; any after are
 * the bot's own). */
static int fill_policy(bc_bot *b, bc_nav_policy *p, bc_nav_danger *danger)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const bc_level_row *lv = bc_level(b->level);
	int dig = e->may_dig, build = e->may_build, i, n = 0, team = me->team, team_n;

	bc_nav_policy_default(p);
	if (b->edit >= 0) {
		dig = b->edit & 1;
		build = (b->edit >> 1) & 1;
	}
	if (e->now < b->mv.noedit_until)
		dig = build = 0;
	p->may_dig = (uint8_t)dig;
	p->may_build = (uint8_t)build;
	/* water that hurts: nav prices it by the second, lets a body already
	 * in it out by the nearest bank, and never enters it when lethal */
	p->water_damage = e->water_damage;
	if (me->hp > 0 && me->hp < 100)
		p->water_damage = e->water_damage * 100.0f / (float)me->hp;     /* a hurt bot is more careful of it */
	p->water_lethal = (uint8_t)(e->water_damage >= 30.0f || (e->water_lethal && !(e->water_damage > 0.0f)));
	p->blocks = (uint8_t)(me->blocks < e->spend ? me->blocks : e->spend);
	/* aosbot's cadences (Dig.cpp), never under the server's */
	p->dig_secs = 0.70f - 0.40f * lv->dig;
	p->build_secs = 0.85f - 0.30f * lv->dig;
	p->h_weight = e->plan_greed;
	p->goal_exact_z = b->mv.exact;
	/* shut in (bc_move_to): only a local search, bounded by what is round
	 * the body */
	if (e->now < b->mv.shut_until)
		p->scope = BC_NAV_JUMP_DMAX;
	/* OFF A ROOF: the goal far below and edits allowed -- the way down is
	 * dug or built, and a search that takes going down for free floods the
	 * whole roof first (nav.h, descent_secs: 33 000 to 75 000 expansions on
	 * real roofs, past the cap and the long search; with this, 500 to
	 * 21 500, and the route a few percent dearer at most) */
	if ((dig || build) && b->mv.goal.z - (int)floorf(me->pos.z + 2.75f) > BC_NAV_DZ_MAX)
		p->descent_secs = bc_nav_dig_down_secs(p);
	/* and up: a stair or a pillar to a floor far above (build_at) */
	if (build && (int)floorf(me->pos.z + 2.75f) - b->mv.goal.z > 2)
		p->ascent_secs = bc_nav_climb_secs(p);
	/* A WAY THROUGH WATER. Wading costs seven times what the heuristic
	 * takes a column for (the sprint), so a search for a way across water
	 * first looks at all the land it could have walked in that time: the
	 * whole island (measured on prisonbreakv1: 59 000 expansions a plan,
	 * 40 bots waiting on 3 plans a second). From the water or to it the
	 * search is therefore made greedy -- in the sea the straight way is
	 * the way -- and water is priced for what it is, slow, not also as
	 * "a body in water is a target" (0.5 s a column). */
	if (e->plan_greed > 1.0f &&
	    (bc_map_is_water(e->map, (int)floorf(me->pos.x), (int)floorf(me->pos.y)) ||
	     bc_map_is_water(e->map, b->mv.goal.x, b->mv.goal.y))) {
		p->water_secs = 0.15f;
		if (p->h_weight < 4.0f) p->h_weight = 4.0f;
	}
	/* (from land to land the sea keeps its full price: a way round by
	 * land is taken when there is one of about the same length) */
	p->zones = e->zones;
	p->nzones = e->nzones;
	p->protect = &e->protect;
	p->fail = &e->fail;
	p->now = e->now;
	if (team >= 1 && team <= 2)
		for (i = 0; i < BC_DANGER_MAX; i++)
			if (e->now - e->danger_at[team - 1][i] < 35.0)   /* aosbot: 35 s */
				danger[n++] = e->danger[team - 1][i];
	team_n = n;
	if (b->flank.avoid_on)
		danger[n++] = b->flank.avoid;     /* a flank: not through the middle */
	for (i = 0; i < b->carry.n && i < BC_AVOID_MAX; i++)
		danger[n++] = b->carry.avoid[i];  /* a carrier: not past those men */
	p->danger = danger;
	p->ndanger = n;
	return team_n;
}

static void plan_done(bc_bot *b, int st)
{
	bc_engine *e = b->e;
	bc_mover *mv = &b->mv;
	int n = bc_nav_plan_route(e->search[mv->search], &mv->route);

	if (mv->join) {
		/* THE WAY ONTO A TEAM-MATE'S ROUTE (routes.h): with the rest of it,
		 * the bot's route -- as if its own search had found it */
		const bc_shared_route *r = bc_routes_get(&e->routes, mv->join);

		mv->join = 0;
		mv->pol.scope = 0;
		mv->pol.goal_exact_z = mv->exact;
		bc_engine_search_release(e, b);
		if (st != BC_NAV_DONE || !r) {
			/* no way onto it (or it has gone): this goal is searched alone */
			e->stats.route_join_fails++;
			mv->solo = 1;
			mv->has_route = 0;  /* its route was the join's scratch */
			return;
		}
		bc_routes_splice(&mv->route, r, mv->join_step, e->map->rev);
		n = mv->route.n;
		st = r->reached ? BC_NAV_DONE : BC_NAV_MORE;
		e->stats.route_joins++;
	} else {
		int s = mv->search;

		e->stats.plans++;
		/* under a claim: put up for the team -- a route, or a capped
		 * search's partial one (routes.h) */
		if (e->search_claim[s] && n > 0 && (st == BC_NAV_DONE || (st == BC_NAV_MORE && !mv->nocap))) {
			bc_routes_publish(&e->routes, &e->search_key[s], &mv->route, st == BC_NAV_DONE, e->now);
			e->stats.routes_published++;
		}
		bc_engine_search_release(e, b);
	}
	if (st == BC_NAV_DONE) {
		mv->noway = 0;
		if (n > 0) {
			/* a way somewhere far: not stranded (a step across its own
			 * roof, or the room it is shut in, is no way out) */
			int dx = mv->route.steps[n - 1].to.x - mv->plan_from.x, dy = mv->route.steps[n - 1].to.y - mv->plan_from.y;

			if (dx * dx + dy * dy > 30 * 30 || abs(mv->route.steps[n - 1].to.z - mv->plan_from.z) > BC_NAV_DZ_MAX)
				mv->stranded_until = 0.0;
		}
		if (n == 0) {
			mv->state = BC_MV_ARRIVED;
			mv->has_route = 0;
			return;
		}
	} else {
		/* no way found -- or (st still MORE) the search was stopped at its
		 * cap: the route leads to the nearest place it reached. A capped
		 * one is walked, and planned on from its end, as long as each
		 * brings the bot nearer; a proven dead end, twice. */
		int capped = st == BC_NAV_MORE;
		float d = 1e9f;

		if (n > 0) {
			float dx = (float)(mv->route.steps[n - 1].to.x - mv->goal.x), dy = (float)(mv->route.steps[n - 1].to.y - mv->goal.y);

			d = sqrtf(dx * dx + dy * dy);
		}
		if (capped) e->stats.plan_caps++;
		else e->stats.plan_fails++;
		if (capped && e->now < mv->stranded_until) {
			/* stranded: a capped search is not walked (a bridge built
			 * toward nowhere) nor followed by the long one -- it is taken
			 * as no way, and the bot stays stranded (what one costs at
			 * 230 bots: one capped search in 30 s) */
			capped = 0;
			e->stats.plan_fails++;
		}
		if (capped && mv->nocap) {
			/* the long search found no way either: as good as none */
			capped = 0;
			e->stats.plan_fails++;
		}
		if (capped && (n == 0 || mv->partial_tries >= 6 || (mv->partial_tries > 0 && d > mv->partial_d - 3.0f))) {
			/* capped searches are getting it no nearer (a maze, a long way
			 * round): one long search (five caps), which finds the way or
			 * is taken to show there is none */
			mv->nocap = 1;
			mv->state = BC_MV_PLANNING;
			mv->plan_since = e->now;
			mv->has_route = 0;
			return;
		}
		if (!capped && (n == 0 || mv->partial_tries >= 2 || mv->nocap)) {
			if (e->now - mv->noway_at > 20.0) mv->noway = 0;
			mv->noway_at = e->now;
			if (++mv->noway >= 3) {
				mv->noway = 2;          /* the next one that fails shuts it in again */
				/* shut in again while still stranded: twice as long */
				mv->shut_until = e->now + (e->now < mv->stranded_until ? 30.0 : 15.0);
				mv->stranded_until = e->now + 45.0;
				e->stats.shut_in++;
			}
			mv->state = BC_MV_FAILED;
			mv->has_route = 0;
			mv->retry_at = e->now + UNREACHABLE_SECS;
			/* the team need not find it out again -- from where this bot
			 * set out, not from the dead end its partial routes led it to */
			bc_unreach_note(b, mv->first_from, mv->goal);
			return;
		}
		mv->partial_tries++;
		mv->partial_d = d;
	}
	if (mv->again)
		bc_nav_follow_again(&mv->follow, &mv->route);
	else
		bc_nav_follow_begin(&mv->follow, &mv->route);
	mv->again = 1;          /* any further route to this goal is "another" */
	mv->state = BC_MV_FOLLOWING;
	mv->has_route = 1;
	mv->solo = 0;
	{
		/* The body did not stand still while the route was searched (it
		 * walked on toward the goal: engine.c, WAITING FOR A ROUTE), so it
		 * may be a few cells along it already: take the route up at the
		 * plain stride nearest to where it now is. Too far from all of
		 * them, the follower says OFF_ROUTE and the next plan is made
		 * from a standstill. */
		const bl_player *me = bc_me(b);
		float best = 1e30f;
		int k, at = 0;

		for (k = 0; k < mv->route.n && k < 14; k++) {
			const bc_nav_step *sp = &mv->route.steps[k];
			float dx, dy, d;

			if ((sp->kind != BC_NAV_WALK && sp->kind != BC_NAV_SPRINT) || sp->digs || sp->builds ||
			    (sp->flags & BC_NAV_F_WATER))
				break;
			dx = (float)sp->to.x + 0.5f - me->pos.x; dy = (float)sp->to.y + 0.5f - me->pos.y;
			d = dx * dx + dy * dy;
			if (d < best && abs(sp->to.z - (int)floorf(me->pos.z + 2.75f)) <= 1) { best = d; at = k + 1; }
		}
		if (best < 1.5f * 1.5f && at > 0 && at < mv->route.n) {
			float dx = (float)mv->route.start.x + 0.5f - me->pos.x, dy = (float)mv->route.start.y + 0.5f - me->pos.y;

			if (dx * dx + dy * dy > best)
				mv->follow.step = at;
		}
	}
}

/* A team-mate's search under way for the same question, set off from
 * within BC_ROUTE_REACH of `from` (routes.h, a CLAIM). */
static int claimed(const bc_engine *e, const bc_route_key *k, bc_nav_node from)
{
	int s;

	for (s = 0; s < e->nsearch; s++) {
		const bc_nav_node *p;
		int dx, dy, dz;

		if (e->search_owner[s] < 0 || !e->search_claim[s] || !bc_route_claim_fits(k, &e->search_key[s]))
			continue;
		p = &e->bots[e->search_owner[s]].mv.plan_from;
		dx = p->x - from.x; dy = p->y - from.y; dz = p->z - from.z;
		if (dx * dx + dy * dy + dz * dz <= BC_ROUTE_REACH * BC_ROUTE_REACH)
			return 1;
	}
	return 0;
}

void bc_movers_plan(bc_engine *e)
{
	int order[BL_MAX_PLAYERS], n = 0, i, j, active = 0, pass;

	for (i = 0; i < e->max_bots; i++) {
		bc_bot *b = &e->bots[i];

		if (b->used && b->alive && b->mv.state == BC_MV_PLANNING && b->wish.move == BC_MOVE_GOTO)
			order[n++] = i;
		else if (b->used && b->mv.search >= 0)
			bc_engine_search_release(e, b);      /* nobody is waiting for it */
	}
	/* longest wait first */
	for (i = 1; i < n; i++) {
		int v = order[i];

		for (j = i; j > 0 && e->bots[order[j - 1]].mv.plan_since > e->bots[v].mv.plan_since; j--)
			order[j] = order[j - 1];
		order[j] = v;
	}
	/* lend the searches */
	for (i = 0; i < n; i++) {
		bc_bot *b = &e->bots[order[i]];
		bc_mover *mv = &b->mv;
		bc_body body;
		bc_nav_node cur, goal;
		bc_nav_policy pol;
		bc_nav_danger danger[BC_DANGER_MAX + 1 + BC_AVOID_MAX];
		bc_route_key key;
		uint32_t join = 0;
		int s, share = 0, team_n, step = -1, radius;

		if (mv->search >= 0) {
			if (e->map->rev != mv->plan_rev && mv->restarts < 2) {
				mv->restarts++;
				bc_engine_search_release(e, b);     /* the map moved under it */
			} else {
				active++;
				continue;
			}
		}
		for (s = 0; s < e->nsearch && e->search_owner[s] >= 0; s++)
			;
		if (s == e->nsearch && !e->plan_share)
			continue;
		bc_body_of(bc_me(b), &body);
		if (mv->braking && bc_body_speed(&body) > 1.5f)
			continue;
		if (!bc_nav_node_of_body(e->map, &body, &cur))
			continue;                           /* in the air: next think */
		team_n = fill_policy(b, &pol, danger);
		if (e->plan_share && !mv->solo &&
		    bc_route_key_of(&pol, bc_me(b)->team, team_n, mv->goal, mv->radius, mv->exact, mv->nocap, &key)) {
			/* THE ROUTE BOARD (routes.h): a team-mate's route, or his
			 * search for it under way -- and no search the team knows
			 * finds no way */
			double until = bc_unreach_until(b, cur, mv->goal);

			if (until > e->now) {
				mv->state = BC_MV_FAILED;
				mv->has_route = 0;
				mv->retry_at = until;
				continue;
			}
			join = bc_routes_find(&e->routes, &key, cur, e->now, e->moves, e->map, &step);
			if (!join && claimed(e, &key, cur)) {
				e->stats.route_waits++;
				continue;
			}
			share = !join;
		}
		if (s == e->nsearch)
			continue;
		mv->pol = pol;
		memcpy(mv->danger, danger, sizeof mv->danger);
		mv->pol.danger = mv->danger;
		goal = mv->goal;
		radius = mv->radius;
		if (join) {
			/* only the way onto it: a local search to that very floor */
			goal = bc_route_place(&bc_routes_get(&e->routes, join)->route, step);
			radius = 0;
			mv->pol.scope = BC_ROUTE_JOIN_SCOPE;
			mv->pol.goal_exact_z = 1;
		}
		if (!bc_nav_plan_begin(e->search[s], e->moves, e->map, &mv->pol, cur, goal, radius)) {
			mv->pol.scope = 0;
			mv->pol.goal_exact_z = mv->exact;
			mv->state = BC_MV_FAILED;
			mv->retry_at = e->now + 0.5;
			continue;
		}
		e->search_owner[s] = order[i];
		e->search_claim[s] = (uint8_t)share;
		if (share)
			e->search_key[s] = key;
		mv->join = join;
		mv->join_step = (int16_t)step;
		mv->plan_from = cur;
		if (!mv->again && mv->partial_tries == 0)
			mv->first_from = cur;       /* where it set out for this goal from */
		mv->search = (int8_t)s;
		mv->plan_rev = e->map->rev;
		mv->expansions = 0;
		active++;
	}
	/* share the budget: an even share each, longest wait first; what the
	 * quick ones leave goes round again */
	for (pass = 0; pass < 2 && active > 0 && e->budget_left > 0; pass++) {
		int share = e->budget_left / active;

		if (share < 64) share = e->budget_left;
		for (i = 0; i < n && e->budget_left > 0; i++) {
			bc_bot *b = &e->bots[order[i]];
			bc_mover *mv = &b->mv;
			uint32_t before, used;
			int st, give;

			if (mv->search < 0 || mv->state != BC_MV_PLANNING)
				continue;
			give = share < e->budget_left ? share : e->budget_left;
			before = bc_nav_plan_expansions(e->search[mv->search]);
			st = bc_nav_plan_step(e->search[mv->search], give);
			used = bc_nav_plan_expansions(e->search[mv->search]) - before;
			if (used == 0) used = 1;
			mv->expansions += used;
			e->budget_left -= (int)used;
			e->stats.expansions += used;
			e->stats.last_expansions += used;
			/* stopped at the cap; the one long search a goal may get, at five caps */
			if (st != BC_NAV_MORE || (e->plan_cap > 0 && mv->expansions >= (uint32_t)e->plan_cap * (mv->nocap ? 5u : 1u))) {
				plan_done(b, st);
				active--;
			}
		}
	}
}

/* --- ACT --------------------------------------------------------------- */

static int solid_neighbour(const bc_map *m, int x, int y, int z)
{
	return bc_map_solid(m, x - 1, y, z) || bc_map_solid(m, x + 1, y, z) ||
	       bc_map_solid(m, x, y - 1, z) || bc_map_solid(m, x, y + 1, z) ||
	       (z > 0 && bc_map_solid(m, x, y, z - 1)) || bc_map_solid(m, x, y, z + 1);
}

static void send_block(bc_bot *b, int x, int y, int z, int action)
{
	bl_ac_block a;

	memset(&a, 0, sizeof a);
	a.x = (int16_t)x; a.y = (int16_t)y; a.z = (int16_t)z;
	a.action = (uint8_t)action;
	if (b->e->host.action)
		b->e->host.action(b->e->host.ctx, BL_AC_BLOCK, b->pid, &a, sizeof a);
	b->e->stats.edits++;
}

/* A bridge's steps ahead that make one straight line from (x, y, z). */
static int try_line(bc_bot *b, const bc_nav_cmd *cmd)
{
	bc_engine *e = b->e;
	const bc_mover *mv = &b->mv;
	const bl_player *me = bc_me(b);
	bc_nav_node vox[8], last, first;
	uint8_t op[8];
	int i, n = 1, dx = 0, dy = 0, dz = 0;

	first.x = last.x = cmd->ex; first.y = last.y = cmd->ey; first.z = last.z = cmd->ez;
	for (i = cmd->step + 1; i < mv->route.n && n < 8 && n < me->blocks; i++) {
		int k, ex, ey, ez;

		if (mv->route.steps[i].kind != BC_NAV_BUILD)
			break;
		k = bc_nav_step_edits(&mv->route, i, e->moves, e->map, vox, op);
		if (k != 1 || op[0] != BC_BLOCK_BUILD)
			break;
		ex = vox[0].x - last.x; ey = vox[0].y - last.y; ez = vox[0].z - last.z;
		if (abs(ex) + abs(ey) + abs(ez) != 1)
			break;
		if (n == 1) { dx = ex; dy = ey; dz = ez; }
		else if (ex != dx || ey != dy || ez != dz) break;
		last = vox[0];
		n++;
	}
	if (n < 2 || !solid_neighbour(e->map, last.x, last.y, last.z) ||
	    !solid_neighbour(e->map, first.x, first.y, first.z))
		return 0;
	{
		bl_ac_line a;

		a.x1 = first.x; a.y1 = first.y; a.z1 = first.z;
		a.x2 = last.x; a.y2 = last.y; a.z2 = last.z;
		if (e->host.action)
			e->host.action(e->host.ctx, BL_AC_LINE, b->pid, &a, sizeof a);
		e->stats.edits++;
	}
	return 1;
}

static void do_edit(bc_bot *b, const bc_nav_cmd *cmd)
{
	bc_engine *e = b->e;
	bc_mover *mv = &b->mv;
	const bl_player *me = bc_me(b);
	int tool = cmd->edit == BC_NAV_EDIT_DIG ? BL_TOOL_SPADE : BL_TOOL_BLOCK;

	mv->edit_tool = (uint8_t)tool;
	mv->tool_grace = e->now + 1.0;          /* aosbot kToolGraceSec */
	if (me->tool != tool || e->now < mv->edit_at)
		return;
	if (cmd->edit == BC_NAV_EDIT_DIG) {
		send_block(b, cmd->ex, cmd->ey, cmd->ez, BL_B_DESTROY);
		mv->edit_at = e->now + (double)(mv->pol.dig_secs < 0.26f ? 0.26f : mv->pol.dig_secs);
	} else if (try_line(b, cmd)) {
		mv->edit_at = e->now + (double)(mv->pol.build_secs < 0.52f ? 0.52f : mv->pol.build_secs);
	} else {
		send_block(b, cmd->ex, cmd->ey, cmd->ez, BL_B_BUILD);
		mv->edit_at = e->now + (double)mv->pol.build_secs;
	}
}

int bc_mover_act(bc_bot *b, const bc_body *body, bc_nav_cmd *cmd)
{
	bc_engine *e = b->e;
	bc_mover *mv = &b->mv;
	int st;

	memset(cmd, 0, sizeof *cmd);
	if (b->wish.move != BC_MOVE_GOTO || !mv->has_route || !e->have_map)
		return 0;
	mv->pol.now = e->now;
	st = bc_nav_follow_tick(&mv->follow, &mv->route, e->moves, e->map, body, &mv->pol, cmd);
	mv->last_status = st;
	mv->cmd = *cmd;
	switch (st) {
	case BC_NAV_FOLLOWING:
		if (cmd->edit != BC_NAV_EDIT_NONE)
			do_edit(b, cmd);
		return 1;
	case BC_NAV_ARRIVED:
		mv->has_route = 0;
		if (mv->state == BC_MV_FOLLOWING) {
			if (mv->route.partial)
				replan(b, 0);
			else
				mv->state = BC_MV_ARRIVED;
		}
		return 0;
	case BC_NAV_STEP_FAILED: {
		bc_nav_node from, to;
		int kind;

		if (bc_nav_follow_failed(&mv->follow, &mv->route, &from, &to, &kind))
			bc_nav_fail_note(&e->fail, from, to, kind, e->now, FAIL_TTL);
		if (cmd->why == BC_NAV_WHY_EDIT_REFUSED) {
			bc_nav_protect_add(&e->protect, mv->follow.edit_vox.x, mv->follow.edit_vox.y,
			                   mv->follow.edit_vox.z);
			if (++mv->refusals >= 2) {
				mv->noedit_until = e->now + 60.0;
				mv->refusals = 0;
			}
		}
		if (mv->state == BC_MV_FOLLOWING)
			replan(b, 1);
		else
			mv->has_route = 0;
		return 0;
	}
	case BC_NAV_GIVE_UP:
		/* the follower has said the same thing from the same place too
		 * often: this goal is not being got to. Not again for a while. */
		mv->has_route = 0;
		mv->state = BC_MV_FAILED;
		mv->retry_at = e->now + GIVE_UP_SECS;
		mv->gave[mv->gave_n & 3] = mv->goal;
		mv->gave_until[mv->gave_n & 3] = mv->retry_at;
		mv->gave_n++;
		{
			bc_nav_node from;

			if (bc_nav_node_of_body(e->map, body, &from))
				bc_unreach_note(b, from, mv->goal);
		}
		bc_engine_search_release(e, b);
		bc_engine_log(e, 0, "bot #%d: gave up on %d %d %d", b->pid, mv->goal.x, mv->goal.y, mv->goal.z);
		return 0;
	default:        /* stale, or off the route */
		if (mv->state == BC_MV_FOLLOWING)
			replan(b, st == BC_NAV_OFF_ROUTE);
		else {
			mv->has_route = 0;
			mv->braking = 1;
		}
		return 0;
	}
}

uint8_t bc_keys_toward(float mx, float my, bl_vec3 ori, uint8_t prev)
{
	float fl = sqrtf(ori.x * ori.x + ori.y * ori.y), fx, fy, f, r;
	uint8_t k = 0;

	if (fl < 1e-4f || (mx == 0.0f && my == 0.0f))
		return 0;
	fx = ori.x / fl;
	fy = ori.y / fl;
	f = mx * fx + my * fy;
	r = mx * -fy + my * fx;       /* right of east is south: y grows south */
	if (f > ((prev & BL_K_FORWARD) ? 0.15f : 0.35f)) k |= BL_K_FORWARD;
	else if (f < -((prev & BL_K_BACK) ? 0.15f : 0.35f)) k |= BL_K_BACK;
	if (r > ((prev & BL_K_RIGHT) ? 0.15f : 0.35f)) k |= BL_K_RIGHT;
	else if (r < -((prev & BL_K_LEFT) ? 0.15f : 0.35f)) k |= BL_K_LEFT;
	return k;
}

int bc_walk_safe(const bc_bot *b, float mx, float my)
{
	const bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bc_body body;
	bc_v3 ori;
	uint8_t keys;
	float z0;
	int i;

	if (!e->have_map)
		return 1;
	bc_body_of(me, &body);
	if (body.airborne)
		return 1;
	{
		/* an edge a step that way: the column there has no floor within
		 * a voxel of the feet and no wall to walk into. The simulation
		 * below misses a body already half over an edge (a bot fighting
		 * on a roof walked off it, 2026-11-25) */
		int fz = (int)floorf(me->pos.z + 2.75f), k;
		float l = sqrtf(mx * mx + my * my);

		for (k = 1; k <= 2 && l > 1e-3f; k++) {
			int x = (int)floorf(me->pos.x + mx / l * 0.8f * (float)k), y = (int)floorf(me->pos.y + my / l * 0.8f * (float)k);

			if (bc_map_is_water(e->map, x, y) || bc_floor_near(e->map, x, y, fz) >= 0 ||
			    bc_map_solid(e->map, x, y, fz - 1) || bc_map_solid(e->map, x, y, fz - 2))
				continue;
			return 0;
		}
	}
	ori.x = me->ori.x; ori.y = me->ori.y; ori.z = 0.0f;
	keys = (uint8_t)(bc_keys_toward(mx, my, me->ori, 0) | (body.keys & BC_K_CROUCH));
	z0 = bc_body_feet(&body);
	for (i = 0; i < 20; i++)
		bc_body_step(&body, e->map, keys, ori, BC_BODY_DT);
	for (i = 0; i < 14; i++)
		bc_body_step(&body, e->map, (uint8_t)(keys & BC_K_CROUCH), ori, BC_BODY_DT);
	if (bc_body_feet(&body) > z0 + 1.3f)
		return 0;
	if (body.wade && !(me->flags & BL_F_WADING))
		return 0;
	return 1;
}

int bc_find_cover(bc_bot *b, bl_vec3 threat, bl_vec3 *out)
{
	static const float radii[4] = { 5.0f, 9.0f, 14.0f, 20.0f };
	const bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	float tx = me->pos.x - threat.x, ty = me->pos.y - threat.y;
	float tl = sqrtf(tx * tx + ty * ty), best = 1e30f;
	int footz = (int)floorf(me->pos.z + 2.75f), r, a, found = 0;

	if (!e->have_map)
		return 0;
	if (tl > 1e-3f) { tx /= tl; ty /= tl; }
	for (r = 0; r < 4; r++) {
		for (a = 0; a < 16; a++) {
			float ang = (float)a * (6.2831853f / 16.0f);
			float cx = cosf(ang), cy = sinf(ang), cost;
			bc_nav_node n;
			bl_vec3 eye;

			if (!bc_nav_snap(e->map, (int)floorf(me->pos.x + cx * radii[r]),
			                 (int)floorf(me->pos.y + cy * radii[r]), footz, 1, &n))
				continue;
			if (bc_map_is_water(e->map, n.x, n.y) || abs(n.z - footz) > 4)
				continue;
			eye.x = (float)n.x + 0.5f; eye.y = (float)n.y + 0.5f; eye.z = (float)n.z - 2.25f;
			if (bc_sight_body(e->map, threat, eye, 0))
				continue;
			/* near is good; towards him is bad */
			cost = radii[r] - 6.0f * (cx * tx + cy * ty);
			if (cost < best) {
				best = cost;
				*out = eye;
				found = 1;
			}
		}
	}
	return found;
}

int bc_roam_goal(bc_bot *b, bl_vec3 *out)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	int team = me->team, other = team == 1 ? 2 : 1, tries, found = 0, own = 0;
	bl_vec3 base = me->pos, home = me->pos;
	float best = -1e30f, spread = 60.0f;

	if (!e->have_map)
		return 0;
	if (team >= 1 && team <= 2) {
		if (e->now - e->hot_at[team - 1] < 60.0) {
			base = e->hot[team - 1];
			spread = 24.0f;
		} else if (e->w.tent[other - 1].present && e->w.tent[team - 1].present) {
			/* the ground between the two bases: where the other team will be met */
			base.x = 0.5f * (e->w.tent[0].pos.x + e->w.tent[1].pos.x);
			base.y = 0.5f * (e->w.tent[0].pos.y + e->w.tent[1].pos.y);
			spread = 45.0f;
		}
		if (e->w.tent[team - 1].present) {
			home = e->w.tent[team - 1].pos;
			own = 1;
		}
	}
	/* of eight places, the one the team has been to least lately -- not
	 * the one nearest its own base (bots used to wander round their tent) */
	for (tries = 0; tries < 8; tries++) {
		float x, y, age, sc, hx, hy;
		bc_nav_node n, from;
		int vx, vy;

		x = base.x + bc_rng_range(&b->rng, -spread, spread);
		y = base.y + bc_rng_range(&b->rng, -spread, spread);
		if (x < 2.0f) x = 2.0f;
		if (x > 509.0f) x = 509.0f;
		if (y < 2.0f) y = 2.0f;
		if (y > 509.0f) y = 509.0f;
		/* the floor nearest the bot's own level: the topmost one sent
		 * aosbot's bots to the rooftops */
		if (!bc_nav_snap_dry(e->map, (int)x, (int)y, (int)floorf(me->pos.z + 2.75f), 48, &n))
			continue;       /* nothing but sea */
		from.x = (int16_t)floorf(me->pos.x); from.y = (int16_t)floorf(me->pos.y);
		from.z = (int16_t)floorf(me->pos.z + 2.75f);
		if (bc_unreach_until(b, from, n) > e->now)
			continue;       /* no way there, the team knows */
		hx = (float)n.x - me->pos.x; hy = (float)n.y - me->pos.y;
		if (hx * hx + hy * hy < 12.0f * 12.0f)
			continue;
		vx = n.x / (BC_MAP_X / BC_VISIT_N); vy = n.y / (BC_MAP_Y / BC_VISIT_N);
		age = team >= 1 && team <= 2 && e->visit[team - 1][vy * BC_VISIT_N + vx] > 0.0f
		      ? (float)e->now + 1.0f - e->visit[team - 1][vy * BC_VISIT_N + vx] : 120.0f;
		sc = (age > 120.0f ? 120.0f : age) / 40.0f + bc_frand(b);
		if (own) {
			hx = (float)n.x - home.x; hy = (float)n.y - home.y;
			if (hx * hx + hy * hy < 40.0f * 40.0f)
				sc -= 2.0f;
		}
		if (sc > best) {
			best = sc;
			out->x = (float)n.x + 0.5f;
			out->y = (float)n.y + 0.5f;
			out->z = (float)n.z - 2.25f;
			found = 1;
		}
	}
	return found;
}
