/* routes.c -- routes.h: the route board
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 */
#include <string.h>

#include "routes.h"

void bc_routes_clear(bc_route_board *bd)
{
	int i;

	for (i = 0; i < BC_ROUTES_MAX; i++)
		bd->r[i].id = 0;
}

int bc_route_key_of(const bc_nav_policy *p, int team, int team_dangers, bc_nav_node goal,
                    int radius, int exact, int long_search, bc_route_key *out)
{
	int i;

	if (team < 1 || team > 2 || p->scope != 0 || p->ndanger > team_dangers ||
	    p->ndanger > BC_ROUTE_DANGER_MAX)
		return 0;
	memset(out, 0, sizeof *out);
	out->goal = goal;
	out->radius = (int16_t)radius;
	out->team = (uint8_t)team;
	out->exact = (uint8_t)(exact != 0);
	out->long_search = (uint8_t)(long_search != 0);
	out->may_dig = p->may_dig;
	out->may_build = p->may_build;
	out->may_jump = p->may_jump;
	out->water_lethal = p->water_lethal;
	out->max_fall_damage = p->max_fall_damage;
	out->min_margin = p->min_margin;
	out->blocks = p->blocks;
	out->water_damage = p->water_damage;
	out->water_secs = p->water_secs;
	out->fail_secs = p->fail_secs;
	out->h_weight = p->h_weight;
	out->descent_secs = p->descent_secs;
	out->ascent_secs = p->ascent_secs;
	out->dig_secs = p->dig_secs;
	out->build_secs = p->build_secs;
	out->ndanger = p->ndanger;
	for (i = 0; i < p->ndanger; i++)
		out->danger[i] = p->danger[i];
	return 1;
}

static int same_node(bc_nav_node a, bc_nav_node b)
{
	return a.x == b.x && a.y == b.y && a.z == b.z;
}

/* The same question, the pouch and the cadence apart. */
static int same_question(const bc_route_key *a, const bc_route_key *b)
{
	int i;

	if (!same_node(a->goal, b->goal) || a->radius != b->radius || a->team != b->team ||
	    a->exact != b->exact || a->may_dig != b->may_dig || a->may_build != b->may_build ||
	    a->may_jump != b->may_jump || a->water_lethal != b->water_lethal ||
	    a->max_fall_damage != b->max_fall_damage || a->min_margin != b->min_margin ||
	    a->water_damage != b->water_damage || a->water_secs != b->water_secs ||
	    a->fail_secs != b->fail_secs || a->h_weight != b->h_weight ||
	    a->descent_secs != b->descent_secs || a->ascent_secs != b->ascent_secs ||
	    a->ndanger != b->ndanger)
		return 0;
	for (i = 0; i < a->ndanger; i++)
		if (a->danger[i].x != b->danger[i].x || a->danger[i].y != b->danger[i].y ||
		    a->danger[i].radius != b->danger[i].radius || a->danger[i].weight != b->danger[i].weight)
			return 0;
	return 1;
}

static int same_edits(const bc_route_key *a, const bc_route_key *b)
{
	return a->blocks == b->blocks && a->dig_secs == b->dig_secs && a->build_secs == b->build_secs;
}

int bc_route_claim_fits(const bc_route_key *mine, const bc_route_key *claim)
{
	if (!same_question(mine, claim) || mine->long_search != claim->long_search)
		return 0;
	if (mine->may_dig || mine->may_build)
		return same_edits(mine, claim);  /* whatever it finds may edit */
	return 1;
}

int bc_route_adoptable(const bc_route_key *mine, const bc_shared_route *r)
{
	if (!same_question(mine, &r->key))
		return 0;
	if (r->edits > 0)
		return same_edits(mine, &r->key);
	if (r->reached)
		return 1;
	/* a partial route is what this long a search reaches: for the same
	 * length of search, and a pouch no bigger than its maker's */
	return mine->long_search == r->key.long_search && mine->blocks <= r->key.blocks;
}

uint32_t bc_routes_publish(bc_route_board *bd, const bc_route_key *k, const bc_nav_route *r,
                           int reached, double now)
{
	int i, at = 0, edits = 0;

	for (i = 0; i < BC_ROUTES_MAX; i++) {
		if (bd->r[i].id == 0) { at = i; break; }
		if (bd->r[i].at < bd->r[at].at) at = i;
	}
	for (i = 0; i < r->n; i++)
		edits += r->steps[i].digs + r->steps[i].builds;
	if (++bd->next_id == 0)
		bd->next_id = 1;
	bd->r[at].key = *k;
	bd->r[at].id = bd->next_id;
	bd->r[at].at = now;
	bd->r[at].edits = edits;
	bd->r[at].reached = (uint8_t)(reached != 0);
	memcpy(&bd->r[at].route, r, offsetof(bc_nav_route, steps) + (size_t)r->n * sizeof r->steps[0]);
	return bd->next_id;
}

const bc_shared_route *bc_routes_get(const bc_route_board *bd, uint32_t id)
{
	int i;

	if (id == 0)
		return NULL;
	for (i = 0; i < BC_ROUTES_MAX; i++)
		if (bd->r[i].id == id)
			return &bd->r[i];
	return NULL;
}

bc_nav_node bc_route_place(const bc_nav_route *r, int step)
{
	return step < 0 ? r->start : r->steps[step].to;
}

static int stands(const bc_map *m, bc_nav_node n)
{
	bc_nav_node s;

	return bc_nav_snap(m, n.x, n.y, n.z, 0, &s) && s.z == n.z;
}

/* The place of `sr` nearest `start` within BC_ROUTE_REACH where a body can
 * stand now (the furthest along of equals), and its squared distance;
 * -2 for none. */
static int nearest_place(const bc_shared_route *sr, bc_nav_node start, const bc_map *m, int *dist)
{
	int j, best = -2, best_d = BC_ROUTE_REACH * BC_ROUTE_REACH + 1;

	for (j = -1; j < sr->route.n; j++) {
		bc_nav_node p = bc_route_place(&sr->route, j);
		int dx = p.x - start.x, dy = p.y - start.y, dz = p.z - start.z, d = dx * dx + dy * dy + dz * dz;

		if (d <= best_d && stands(m, p)) {     /* <=: the furthest along of equals */
			best_d = d;
			best = j;
		}
	}
	*dist = best_d;
	return best;
}

uint32_t bc_routes_find(bc_route_board *bd, const bc_route_key *k, bc_nav_node start, double now,
                        const bc_nav_moves *t, const bc_map *m, int *step)
{
	for (;;) {
		/* the nearest of every route that may be taken (the first put up
		 * of equals); then whether its shared part still holds -- one an
		 * edit broke goes, and the next nearest is looked at */
		bc_shared_route *win = NULL;
		int i, at = -2, at_d = 0;

		for (i = 0; i < BC_ROUTES_MAX; i++) {
			bc_shared_route *sr = &bd->r[i];
			int d, j;

			if (sr->id == 0 || now - sr->at > BC_ROUTE_TTL || !bc_route_adoptable(k, sr))
				continue;
			j = nearest_place(sr, start, m, &d);
			if (j < -1 || (win && (d > at_d || (d == at_d && sr->id > win->id))))
				continue;
			win = sr;
			at = j;
			at_d = d;
		}
		if (!win)
			return 0;
		if (win->route.map_rev != m->rev && !bc_nav_route_holds(&win->route, at + 1, win->route.n, t, m)) {
			win->id = 0;    /* an edit broke it: off the board */
			continue;
		}
		*step = at;
		return win->id;
	}
}

void bc_routes_splice(bc_nav_route *join, const bc_shared_route *r, int step, uint32_t rev)
{
	int j;

	for (j = step + 1; j < r->route.n; j++) {
		if (join->n >= BC_NAV_ROUTE_MAX) {
			join->partial = 1;
			break;
		}
		join->steps[join->n++] = r->route.steps[j];
		join->secs += r->route.steps[j].secs;
	}
	if (!r->reached)
		join->partial = 1;
	join->goal = r->route.goal;
	join->map_rev = rev;
}
