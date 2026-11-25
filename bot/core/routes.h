/* routes.h -- THE ROUTE BOARD: one search for bots that go the same way
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * WHY. On a real map the planner is about 90% of the engine's time
 * (BRAIN-STATUS.md (c2)), and much of it is the same search made again:
 * a team's bots set off from round their base for the same flag, the same
 * tent, the same leader, and each searched the same way for itself.
 * Measured on prisonbreakv1 with 230 bots (BRAIN-STATUS.md (c3)): 37% of
 * the plans, holding 52% of the expansions, were made within two seconds
 * of a team-mate's plan to the very same goal from within 16 columns.
 * aosbot learned this on its Survive hordes (RouteBoard.cpp: thirty
 * zombies, the same 200 000-expansion search each) and this is its board,
 * kept to what the engine needs.
 *
 * WHAT. A bot whose route is about to be searched looks here first:
 *   - A ROUTE a team-mate found under two seconds ago (BC_ROUTE_TTL) for
 *     the same goal under the same rules, with a place on it within
 *     BC_ROUTE_REACH columns of where the bot stands: the bot searches only
 *     the short way ONTO it (a local search, nav.h policy.scope) and takes
 *     the rest. Its route is its own from its own start: the join is
 *     planned for its body, and the shared part is checked against the map
 *     as it is now before it is handed on (bc_nav_route_holds): one that
 *     an edit has broken is taken off the board, and the next bot that
 *     asks searches for itself and puts the new one up.
 *   - A CLAIM: a team-mate's search for the same question, from within
 *     BC_ROUTE_REACH, under way now. The bot waits for it (it walks on
 *     toward the goal meanwhile, as any bot waiting for a route does) and
 *     takes the route when it is put up. A claim is nothing but a search
 *     slot that says what it is searching: it ends with the search, so a
 *     waiter can never wait on a dead one.
 *   - Neither: it searches for itself, under a claim, and puts what it
 *     finds up for the others.
 * A capped search's partial route is put up too (a route toward the goal
 * as far as the cap reached): walking it and planning on from its end is
 * what its maker does, and every team-mate would have been capped at the
 * same place. A search that found no way is not: the team's memory of
 * goals with no way to them (skill_tactics.c, bc_unreach_*) already tells
 * the waiters, and no search is started for such a goal.
 *
 * THE SAME QUESTION (bc_route_key). Same team, same goal node, radius and
 * exactness, and the parts of the policy that choose the route: what may
 * be edited, water's prices and lethality, the greed, the descent and
 * ascent terms, the team's danger places. Never shared: a search bounded
 * to what is round the body (a shut-in bot), and a policy with dangers of
 * the bot's own (a flank's middle, the men a carrier avoids). The fail
 * memory, the protected voxels and the zones are the engine's, the same
 * for everybody at one moment, and are not compared. The cadence of
 * edits (by level) and the pouch only matter for a route that edits: a
 * route with no edits on it is handed to any pouch and cadence if it
 * arrives, a partial one only to a pouch no bigger than its maker's (one
 * with more blocks might bridge where he could not), and one with edits
 * only to the same pouch and cadence (aosbot's RouteBoard::adoptable).
 *
 * DETERMINISTIC. The board is the engine's state, read and written in the
 * planner's fixed order (skill_move.c, bc_movers_plan); a joined route is
 * a function of the board, the map and the bot.
 */
#ifndef BC_ROUTES_H
#define BC_ROUTES_H

#include <stdint.h>

#include "map.h"
#include "nav.h"

enum {
	BC_ROUTES_MAX = 32,         /* routes on the board; the oldest goes */
	BC_ROUTE_REACH = 16,        /* columns from a route (or a claimer's start) */
	BC_ROUTE_JOIN_SCOPE = BC_ROUTE_REACH + 8,   /* the join's local search */
	BC_ROUTE_DANGER_MAX = 4     /* a team's danger places (brain.h BC_DANGER_MAX) */
};
#define BC_ROUTE_TTL 2.0        /* seconds a route is handed on */

typedef struct bc_route_key {
	bc_nav_node goal;
	int16_t radius;
	uint8_t team, exact, long_search;
	uint8_t may_dig, may_build, may_jump, water_lethal, max_fall_damage, min_margin, blocks;
	float water_damage, water_secs, fail_secs, h_weight, descent_secs, ascent_secs;
	float dig_secs, build_secs;     /* compared only for a route that edits */
	int32_t ndanger;
	bc_nav_danger danger[BC_ROUTE_DANGER_MAX];
} bc_route_key;

typedef struct bc_shared_route {
	bc_route_key key;
	uint32_t id;                /* 0: an empty place */
	double at;                  /* when it was found */
	int32_t edits;              /* voxels it digs or builds */
	uint8_t reached;            /* it arrives (not a capped search's partial) */
	uint8_t pad_[7];
	bc_nav_route route;
} bc_shared_route;

typedef struct bc_route_board {
	bc_shared_route r[BC_ROUTES_MAX];
	uint32_t next_id;
} bc_route_board;

void bc_routes_clear(bc_route_board *bd);

/* The question a search under `p` asks, for a bot of `team` (1 or 2).
 * 0 when it may not be shared: a local search (scope), a danger list
 * longer than the team's (`team_dangers`: the first that many are the
 * team's; any more are the bot's own), another team. */
int bc_route_key_of(const bc_nav_policy *p, int team, int team_dangers, bc_nav_node goal,
                    int radius, int exact, int long_search, bc_route_key *out);

/* May a bot asking `mine` wait on a search asking `claim`? The same
 * question, and a pouch no bigger (whatever it finds is then for it). */
int bc_route_claim_fits(const bc_route_key *mine, const bc_route_key *claim);

/* May a bot asking `mine` take `r` (the pouch and cadence rules above)? */
int bc_route_adoptable(const bc_route_key *mine, const bc_shared_route *r);

/* Put a route up. Returns its id. */
uint32_t bc_routes_publish(bc_route_board *bd, const bc_route_key *k, const bc_nav_route *r,
                           int reached, double now);

/* The route for a bot asking `k` from `start`: the live, adoptable one with
 * a place nearest `start` within BC_ROUTE_REACH (the furthest along of
 * equals), where it can stand now; its shared part still holds on `m` (one
 * that does not is taken off). Its id and, in *step, the index of the place
 * (-1: the route's own start); 0 if none. */
uint32_t bc_routes_find(bc_route_board *bd, const bc_route_key *k, bc_nav_node start, double now,
                        const bc_nav_moves *t, const bc_map *m, int *step);

/* The route of that id, or NULL (gone: replaced, cleared). */
const bc_shared_route *bc_routes_get(const bc_route_board *bd, uint32_t id);

/* The node of place `step` of r (-1: its start). */
bc_nav_node bc_route_place(const bc_nav_route *r, int step);

/* `join` (from the bot to place `step` of `r`) and the rest of r after it,
 * as one route in `join`. Its revision is the map's now (`rev`): the shared
 * part was checked on it. Cut at BC_NAV_ROUTE_MAX steps (then partial). */
void bc_routes_splice(bc_nav_route *join, const bc_shared_route *r, int step, uint32_t rev);

#endif
