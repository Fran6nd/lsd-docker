/* nav_sim.h -- the test bench for nav: a world, a body in it, and a loop
 * that plans, follows, plays the server for edits, and plans again when
 * the follower says to. Shared by nav_test.c's scenarios and its soak.
 *
 * The body is moved by bc_body_step on `truth` -- the map the "server"
 * has -- while the planner and the follower are given `m`, the map the
 * engine believes. They are the same map unless a test wants the engine
 * to be wrong about the world.
 */
#ifndef NAV_SIM_H
#define NAV_SIM_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "cull.h"
#include "nav.h"

typedef struct sim_world {
	bc_map *m, *truth;
	bc_cull *cull;
	bc_nav_moves *t;
	bc_nav_search *s;
	bc_nav_fail fail;
	bc_nav_protect prot;
	int latency;                /* ticks between a command and its effect */
	/* the server refuses edits in this box (and the engine is not told) */
	int srv_protect, sx0, sy0, sx1, sy1;
	/* at this tick somebody builds this box (announced: both maps) */
	int place_tick, px0, py0, pz0, px1, py1, pz1;
	/* at this tick somebody destroys this voxel (announced likewise) */
	int destroy_tick, dx, dy, dz;
	/* ...or, instead of at a tick, when the body's x passes this */
	float destroy_at_x;
	int verbose;
	int trace;                  /* print every tick (BC_SOAK_TRACE) */
} sim_world;

typedef struct sim_result {
	int arrived, ticks, plans, plan_fails, no_route;
	int gave_up;                /* the follower said BC_NAV_GIVE_UP */
	int plan_cap;               /* stopped by the bench's cap on plans */
	int step_fails, stale, off_route, why[8];
	unsigned kinds;             /* bit per bc_nav_kind actually executed */
	int waded;                  /* ticks with the body wading */
	/* THE GUARANTEE AGAINST GRINDING, measured from outside the follower:
	 * the longest run of ticks on which it answered FOLLOWING with a
	 * movement key held and no edit asked for, while the body stayed
	 * within a quarter of a voxel of where that run began. nav.h bounds
	 * it (2 * BC_NAV_STUCK_TICKS + BC_NAV_RECENTRE_TICKS, and the link's
	 * delay); the bench's own anchor is not the follower's, so a run seen
	 * here can straddle two of its, and the checks allow for that. */
	int max_still;
	int damage;                 /* hit points lost to falls */
	int edits;
	float max_feet;             /* the lowest the feet ever were (z grows down) */
	float route_secs;           /* the first plan's cost */
	float route_time;           /* ...and the part of it that is time: less
	                               what the policy charges for water */
	/* Walked against planned, by what the step was, on the first route
	 * while it is the only one: [kind][0 up, 1 level, 2 down][0 straight
	 * on, 1 after a turn of 45 degrees, 2 of 90 or more]. Ticks walked
	 * while the follower was on such a step, seconds the plan gave it. */
	int cat_ticks[BC_NAV_KINDS][3][3], cat_n[BC_NAV_KINDS][3][3];
	float cat_secs[BC_NAV_KINDS][3][3];
	unsigned max_exp, sum_exp, max_nodes;
	double plan_us, max_plan_us;
	int first_plan_status;
} sim_result;

static double sim_now_us(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1e6 + (double)ts.tv_nsec * 1e-3;
}

static int sim_hits_body(const bc_body *b, int x, int y, int z)
{
	float top = b->pos.z - 0.45f, bot = bc_body_feet(b);

	return b->pos.x + 0.45f > (float)x && b->pos.x - 0.45f < (float)(x + 1) &&
	       b->pos.y + 0.45f > (float)y && b->pos.y - 0.45f < (float)(y + 1) &&
	       bot > (float)z && top < (float)(z + 1);
}

static void sim_apply(sim_world *w, int action, int x, int y, int z)
{
	bc_map_apply(w->truth, w->cull, action, x, y, z, NULL);
	if (w->m != w->truth)
		bc_map_apply(w->m, w->cull, action, x, y, z, NULL);
}

static sim_result sim_run(sim_world *w, bc_nav_policy pol, bc_nav_node start, bc_nav_node goal,
                          int radius, int cap)
{
	static bc_nav_route route;
	sim_result R;
	bc_nav_follow f;
	bc_body b;
	bc_nav_cmd q[8];
	int tick = 0, need_plan = 1, edit_cool = 0, blocks = pol.blocks, refusals = 0;
	int partial_ends = 0, qn = 0, last_step = -1, still = 0;
	bc_v3 still_at;

	memset(&R, 0, sizeof R);
	memset(&f, 0, sizeof f);
	memset(q, 0, sizeof q);
	R.first_plan_status = -1;
	pol.fail = &w->fail;
	pol.protect = &w->prot;
	bc_body_place(&b, w->truth, (float)start.x + 0.5f, (float)start.y + 0.5f, start.z, 0);
	R.max_feet = bc_body_feet(&b);
	still_at = b.pos;

	while (tick < cap) {
		bc_nav_cmd cmd, act;
		int32_t dmg;
		int status;

		if (need_plan) {
			bc_nav_node cur;
			double t0;
			int st;

			if (!bc_nav_node_of_body(w->m, &b, &cur)) {
				bc_v3 o = {1.0f, 0.0f, 0.0f};

				bc_body_step(&b, w->truth, (uint8_t)(b.keys & BC_K_CROUCH), o, BC_BODY_DT);
				tick++;
				continue;
			}
			if (R.plans >= 40) {
				/* the bench's own stop. The follower's guarantee is
				 * BC_NAV_REPORTS_MAX reports a goal: this must never
				 * be what ends a run, and nav_test checks it is not. */
				R.plan_cap = 1;
				break;
			}
			pol.now = (double)tick / 60.0;
			pol.blocks = (uint8_t)blocks;
			t0 = sim_now_us();
			if (!bc_nav_plan_begin(w->s, w->t, w->m, &pol, cur, goal, radius)) {
				R.no_route = 1;
				break;
			}
			while ((st = bc_nav_plan_step(w->s, 4096)) == BC_NAV_MORE)
				;
			t0 = sim_now_us() - t0;
			R.plans++;
			R.plan_us += t0;
			if (t0 > R.max_plan_us)
				R.max_plan_us = t0;
			R.sum_exp += bc_nav_plan_expansions(w->s);
			if (bc_nav_plan_expansions(w->s) > R.max_exp)
				R.max_exp = bc_nav_plan_expansions(w->s);
			if (bc_nav_plan_nodes(w->s) > R.max_nodes)
				R.max_nodes = bc_nav_plan_nodes(w->s);
			bc_nav_plan_route(w->s, &route);
			if (R.first_plan_status < 0) {
				int i;

				R.first_plan_status = st;
				R.route_secs = R.route_time = route.secs;
				for (i = 0; i < route.n; i++)
					if (route.steps[i].flags & BC_NAV_F_WATER)
						R.route_time -= pol.water_secs;
			}
			if (w->verbose) {
				int i;

				printf("  plan %d: %s, %d steps, %.2fs, %u expansions:", R.plans,
				       st == BC_NAV_DONE ? "done" : "FAILED", route.n, (double)route.secs,
				       bc_nav_plan_expansions(w->s));
				for (i = 0; i < route.n && i < 40; i++)
					printf(" %s(%d,%d,%d)", bc_nav_kind_name(route.steps[i].kind),
					       route.steps[i].to.x, route.steps[i].to.y, route.steps[i].to.z);
				printf("\n");
			}
			if (st != BC_NAV_DONE) {
				R.plan_fails++;
				if (route.n == 0 || ++partial_ends > 2) {
					R.no_route = 1;
					break;
				}
			}
			/* the first route to a goal, or another to the same one */
			if (R.plans == 1)
				bc_nav_follow_begin(&f, &route);
			else
				bc_nav_follow_again(&f, &route);
			need_plan = 0;
		}

		status = bc_nav_follow_tick(&f, &route, w->t, w->m, &b, &pol, &cmd);
		if (status == BC_NAV_FOLLOWING) {
			if (cmd.step >= 0 && cmd.step < route.n)
				R.kinds |= 1u << route.steps[cmd.step].kind;
			if (R.plans == 1 && cmd.step >= 0 && cmd.step < route.n) {
				const bc_nav_step *sp = &route.steps[cmd.step];
				bc_nav_node from = cmd.step ? route.steps[cmd.step - 1].to : route.start;
				int dz = sp->to.z < from.z ? 0 : sp->to.z == from.z ? 1 : 2, tn = 0, i;

				if (cmd.step > 0 && sp->dir < 8 && route.steps[cmd.step - 1].dir < 8) {
					tn = (sp->dir - route.steps[cmd.step - 1].dir) & 7;
					tn = tn > 4 ? 8 - tn : tn;
					tn = tn > 2 ? 2 : tn;
				}
				R.cat_ticks[sp->kind][dz][tn]++;
				/* its planned seconds, once, and those of the ground steps
				 * ticked off since the last one seen */
				for (i = last_step + 1; i <= cmd.step; i++) {
					const bc_nav_step *q = &route.steps[i];
					bc_nav_node qf = i ? route.steps[i - 1].to : route.start;
					int qz = q->to.z < qf.z ? 0 : q->to.z == qf.z ? 1 : 2, qt = 0;

					if (i > 0 && q->dir < 8 && route.steps[i - 1].dir < 8) {
						qt = (q->dir - route.steps[i - 1].dir) & 7;
						qt = qt > 4 ? 8 - qt : qt;
						qt = qt > 2 ? 2 : qt;
					}
					R.cat_secs[q->kind][qz][qt] += q->secs -
						((q->flags & BC_NAV_F_WATER) ? pol.water_secs : 0.0f);
					R.cat_n[q->kind][qz][qt]++;
				}
				if (cmd.step > last_step)
					last_step = cmd.step;
			}
		} else if (status == BC_NAV_ARRIVED) {
			if (!route.partial) {
				R.arrived = 1;
				break;
			}
			need_plan = 1;
		} else if (status == BC_NAV_GIVE_UP) {
			R.gave_up = 1;
			if (w->verbose)
				printf("  tick %d: gave up (after %d reports; the last would have been why %d), "
				       "body (%.2f %.2f %.2f)\n", tick, f.reports, cmd.why, (double)b.pos.x,
				       (double)b.pos.y, (double)b.pos.z);
			break;
		} else if (status == BC_NAV_STEP_FAILED) {
			bc_nav_node a, c;
			int kind;

			R.step_fails++;
			R.why[cmd.why & 7]++;
			if (w->verbose)
				printf("  tick %d: step %d failed, why %d, body (%.2f %.2f %.2f)\n", tick,
				       cmd.step, cmd.why, (double)b.pos.x, (double)b.pos.y, (double)b.pos.z);
			if (bc_nav_follow_failed(&f, &route, &a, &c, &kind))
				bc_nav_fail_note(&w->fail, a, c, kind, (double)tick / 60.0, 30.0);
			if (cmd.why == BC_NAV_WHY_EDIT_REFUSED) {
				bc_nav_protect_add(&w->prot, f.edit_vox.x, f.edit_vox.y, f.edit_vox.z);
				/* what a skill would do (aosbot gave up digging after
				 * a run of refusals): twice bitten, stop editing */
				if (++refusals >= 2)
					pol.may_dig = pol.may_build = 0;
			}
			need_plan = 1;
		} else if (status == BC_NAV_ROUTE_STALE) {
			R.stale++;
			if (w->verbose)
				printf("  tick %d: route stale\n", tick);
			need_plan = 1;
		} else {
			R.off_route++;
			if (w->verbose)
				printf("  tick %d: off route, body (%.2f %.2f %.2f)\n", tick,
				       (double)b.pos.x, (double)b.pos.y, (double)b.pos.z);
			need_plan = 1;
		}

		/* the server, for edits: one every so often, some refused */
		if (edit_cool > 0)
			edit_cool--;
		if (cmd.edit != BC_NAV_EDIT_NONE && edit_cool == 0) {
			int refused = w->srv_protect && cmd.ex >= w->sx0 && cmd.ex <= w->sx1 &&
			              cmd.ey >= w->sy0 && cmd.ey <= w->sy1;

			if (cmd.edit == BC_NAV_EDIT_DIG && !refused) {
				sim_apply(w, BC_BLOCK_DESTROY, cmd.ex, cmd.ey, cmd.ez);
				edit_cool = (int)(pol.dig_secs * 60.0f);
				R.edits++;
			} else if (cmd.edit == BC_NAV_EDIT_BUILD && !refused && blocks > 0 &&
			           !sim_hits_body(&b, cmd.ex, cmd.ey, cmd.ez)) {
				sim_apply(w, BC_BLOCK_BUILD, cmd.ex, cmd.ey, cmd.ez);
				edit_cool = (int)(pol.build_secs * 60.0f);
				blocks--;
				R.edits++;
			}
		}

		/* the link: a command takes effect `latency` ticks later */
		q[qn % 8] = cmd;
		act = w->latency > 0 ? q[(qn + 8 - w->latency) % 8] : cmd;
		if (w->latency > qn)
			memset(&act, 0, sizeof act), act.ori.x = 1.0f;
		qn++;
		if (w->trace)
			printf("    t%-5d st %d step %3d keys %02x ori (%5.2f %5.2f) pos (%7.2f %7.2f) "
			       "feet %5.2f vel (%5.2f %5.2f %5.2f)%s\n", tick, status, cmd.step, act.keys,
			       (double)act.ori.x, (double)act.ori.y, (double)b.pos.x, (double)b.pos.y,
			       (double)bc_body_feet(&b), (double)(b.vel.x * 32.0f), (double)(b.vel.y * 32.0f),
			       (double)(b.vel.z * 32.0f), b.airborne ? " air" : "");
		dmg = bc_body_step(&b, w->truth, act.keys, act.ori, BC_BODY_DT);
		if (dmg > 0)
			R.damage += dmg;
		if (b.wade && !b.airborne)
			R.waded++;
		{
			float sx = b.pos.x - still_at.x, sy = b.pos.y - still_at.y, sz = b.pos.z - still_at.z;

			if (status != BC_NAV_FOLLOWING || cmd.edit != BC_NAV_EDIT_NONE ||
			    !(cmd.keys & (BC_K_FORWARD | BC_K_BACK | BC_K_LEFT | BC_K_RIGHT)) ||
			    sx * sx + sy * sy + sz * sz > 0.25f * 0.25f) {
				still_at = b.pos;
				still = 0;
			} else if (++still > R.max_still) {
				R.max_still = still;
			}
		}
		if (bc_body_feet(&b) > R.max_feet)
			R.max_feet = bc_body_feet(&b);
		tick++;

		if ((w->destroy_tick && tick == w->destroy_tick) ||
		    (w->destroy_at_x > 0.0f && b.pos.x >= w->destroy_at_x)) {
			sim_apply(w, BC_BLOCK_DESTROY, w->dx, w->dy, w->dz);
			w->destroy_at_x = 0.0f;
		}
		if (w->place_tick && tick == w->place_tick) {
			int x, y, z;

			for (z = w->pz0; z <= w->pz1; z++)
				for (y = w->py0; y <= w->py1; y++)
					for (x = w->px0; x <= w->px1; x++)
						sim_apply(w, BC_BLOCK_BUILD, x, y, z);
		}
	}
	R.ticks = tick;
	return R;
}

#endif /* NAV_SIM_H */
