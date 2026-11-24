/* nav_follow.c -- The follower: a route, one tick at a time
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * See nav.h for what it guarantees. How it is put together:
 *
 *   GROUND STEPS (walk, sprint, crouch) are followed several at a time:
 *   the body heads for the next column's middle and a step is ticked off
 *   when the body is over its column. The pace is the fastest of sprint,
 *   walk and sneak for which a simulation says: "three more ticks of this,
 *   then an emergency stop, and the body is still on the route's floor".
 *   So it sprints along a ledge and slows for the corner without anybody
 *   having said where the corner is.
 *
 *   JUMPS AND DROPS are handed to nav_exec.c's controllers, the ones the
 *   move table was measured with. A jump that lies straight ahead along
 *   the steps being walked is taken in stride (the body is "in its lane").
 *
 *   EDIT STEPS stand still, ask for one voxel at a time, and walk in when
 *   the map shows the work done.
 *
 * and, round all of it, the watch for the three ways a route goes wrong:
 * the body stops moving, the body is somewhere else, the map is no longer
 * the one the route was planned on.
 */
#include "nav_i.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#define SAFE_RUN_TICKS 3
#define SAFE_LOOK_TICKS 15
#define SAFE_STOP_TICKS 40

static bc_nav_node step_from(const bc_nav_route *r, int i)
{
	return i > 0 ? r->steps[i - 1].to : r->start;
}

static int is_jump_kind(int k)
{
	return k == BC_NAV_JUMP || k == BC_NAV_RUNJUMP;
}

static int is_edit_kind(int k)
{
	return k == BC_NAV_DIG || k == BC_NAV_BUILD || k == BC_NAV_PILLAR;
}

void bc_nav_follow_begin(bc_nav_follow *f, const bc_nav_route *r)
{
	memset(f, 0, sizeof *f);
	f->map_rev = r->map_rev;
	f->last_ori.x = 1.0f;
}

void bc_nav_follow_again(bc_nav_follow *f, const bc_nav_route *r)
{
	/* everything up to the record goes; the record stays */
	memset(f, 0, offsetof(bc_nav_follow, reports));
	f->map_rev = r->map_rev;
	f->last_ori.x = 1.0f;
}

/* NEVER A LOOP (nav.h): note a report, and say whether it is one too
 * many. The place is the floor the body is on -- or, for a body in the
 * air or in a hole nobody can stand in, the column it is in. */
static int one_too_many(bc_nav_follow *f, const bc_map *m, const bc_body *b, int status, int why)
{
	bc_nav_node here;
	uint32_t cell;
	int i, at = -1, old;

	if (!bc_nav_node_of_body(m, b, &here)) {
		here.x = (int16_t)floorf(b->pos.x);
		here.y = (int16_t)floorf(b->pos.y);
		here.z = 0;
	}
	cell = nav_pack(here);
	if (f->reports < 0xFFFF)
		f->reports++;
	for (i = 0; i < BC_NAV_REPORT_SLOTS; i++) {
		bc_nav_report *e = &f->seen[i];

		if (e->cell && e->age < 255)
			e->age++;
		if (e->cell == cell && e->status == status && e->why == why)
			at = i;
	}
	if (at < 0) {
		/* not said from here before: in an empty slot, or the stalest */
		for (i = 0, old = 0; i < BC_NAV_REPORT_SLOTS; i++) {
			if (!f->seen[i].cell) { old = i; break; }
			if (f->seen[i].age > f->seen[old].age)
				old = i;
		}
		at = old;
		f->seen[at].cell = cell;
		f->seen[at].status = (uint8_t)status;
		f->seen[at].why = (uint8_t)why;
		f->seen[at].count = 0;
	}
	f->seen[at].age = 0;
	if (f->seen[at].count < 255)
		f->seen[at].count++;
	return f->seen[at].count >= BC_NAV_REPEAT_MAX || f->reports >= BC_NAV_REPORTS_MAX;
}

static void set_step(bc_nav_follow *f, int i)
{
	f->step = i;
	f->step_ticks = 0;
	f->edit_ticks = 0;
	f->phase = 0;
	f->attempts = 0;
	f->air_keys = 0;
	f->xs_ticks = 0;
	f->recentre = 0;
	f->recentred = 0;
	f->edit_vox.x = f->edit_vox.y = f->edit_vox.z = -1;
}

/* --- ground steps ----------------------------------------------------- */

/* Tick off every ground step whose column the body is over -- the next
 * one, or one of the two after if it flew past (a body running down
 * stairs touches every other tread). */
static int ground_advance(const bc_nav_route *r, int i, const bc_body *b)
{
	for (;;) {
		int k, hit = 0;

		for (k = 0; k < 3 && i + k < r->n; k++) {
			if (!nav_is_ground_kind(r->steps[i + k].kind))
				break;
			if (nav_at(b, r->steps[i + k].to)) {
				i += k + 1;
				hit = 1;
				break;
			}
		}
		if (!hit)
			return i;
	}
}

/* The floor the body may be on while on step i: the lower of its ends. */
static float floor_limit(const bc_nav_route *r, int i)
{
	bc_nav_node a, b;

	if (r->n == 0)
		return nav_rest(r->start.z);
	if (i >= r->n)
		return nav_rest(r->steps[r->n - 1].to.z);
	a = step_from(r, i);
	if (!nav_is_ground_kind(r->steps[i].kind))
		return nav_rest(a.z);
	b = r->steps[i].to;
	return nav_rest(a.z > b.z ? a.z : b.z);
}

static void ground_law(const bc_nav_route *r, int i, const bc_body *b, uint8_t cand,
                       uint8_t *keys, bc_v3 *ori)
{
	bc_nav_node tgt;
	uint8_t mode = cand;
	int arrive = 0;

	if (i >= r->n) {
		tgt = r->n ? r->steps[r->n - 1].to : r->start;
		arrive = 1;
		mode &= (uint8_t)~BC_K_SPRINT;
	} else if (!nav_is_ground_kind(r->steps[i].kind)) {
		/* something that starts from standing: go to where it starts */
		tgt = step_from(r, i);
		arrive = 1;
		mode &= (uint8_t)~BC_K_SPRINT;
	} else {
		const bc_nav_step *st = &r->steps[i];
		bc_nav_node from = step_from(r, i);

		tgt = st->to;
		if (st->kind == BC_NAV_CROUCH)
			mode = BC_K_CROUCH;
		else if (st->kind == BC_NAV_WALK || st->to.z < from.z)
			mode &= (uint8_t)~BC_K_SPRINT;  /* a sprint does not climb */
		/* slow for the last step, and for one that ends where something
		 * starts from standing (a jump not in stride, a drop, an edit) */
		arrive = i == r->n - 1 || !nav_is_ground_kind(r->steps[i + 1].kind);
	}
	nav_law_steer(b, (float)tgt.x + 0.5f, (float)tgt.y + 0.5f, mode, arrive, keys, ori);
}

/* --- where a body may be ---------------------------------------------- */

/* Node k of a route: where step k starts (node 0 is the start, node n the
 * end). */
static bc_nav_node route_node(const bc_nav_route *r, int k)
{
	return k > 0 ? r->steps[k - 1].to : r->start;
}

/* The stretch of the route the body is on while it does step i: the two
 * nodes behind it (it has just been there), and ahead as far as the ground
 * steps run (the safety simulation ticks them off as it goes), eight at
 * most. */
static void route_window(const bc_nav_route *r, int i, int *lo, int *hi)
{
	int k = i < r->n ? i : r->n;

	*lo = k - 2 < 0 ? 0 : k - 2;
	while (k < r->n && k < i + 8 && nav_is_ground_kind(r->steps[k].kind))
		k++;
	*hi = k;
}

static int in_window(const bc_nav_route *r, int lo, int hi, int x, int y, int z)
{
	int k;

	for (k = lo; k <= hi; k++) {
		bc_nav_node n = route_node(r, k);

		if (n.x == x && n.y == y && n.z >= z - 1 && n.z <= z + 1)
			return 1;
	}
	return 0;
}

/* Is the floor (x, y, z) one of the window's nodes, or at most `depth`
 * plain strides from one -- strides a body WALKS: to a neighbour by a side
 * (not a corner), onto a floor it can stand on, level, one down or one up
 * (the free climb), and not into water from dry land? */
static int near_route(const bc_map *m, const bc_nav_route *r, int lo, int hi,
                      int x, int y, int z, int depth)
{
	int d;

	if (in_window(r, lo, hi, x, y, z))
		return 1;
	if (depth <= 0)
		return 0;
	for (d = 0; d < 8; d += 2) {
		int qx = x + bc_nav_dx[d], qy = y + bc_nav_dy[d], z0 = z > 0 ? z - 1 : 0, qz;
		uint64_t sb;

		if (qx < 0 || qx >= BC_MAP_X || qy < 0 || qy >= BC_MAP_Y)
			continue;
		sb = bc_map_stand_bits(m->col[qy * BC_MAP_X + qx]) >> z0;
		if (!sb)
			continue;
		qz = z0 + bc_ctz64(sb);
		if (qz > z + 1 || (qz >= BC_MAP_WATER_Z && z < BC_MAP_WATER_Z))
			continue;
		if (near_route(m, r, lo, hi, qx, qy, qz, depth - 1))
			return 1;
	}
	return 0;
}

/* THE SAFE CELLS of a route are its own columns and the floor a body can
 * walk straight back from: within two strides of them.
 *
 * Is the body on one -- its CENTRE over the column, its feet on that floor
 * (or held a little above it by a corner on a higher neighbour, as after
 * coming down a stair)? A body hanging by a corner with its centre over
 * nothing is standing, and is not safe: the next push takes it off. */
static int body_safe(const bc_nav_route *r, const bc_map *m, int i, const bc_body *b)
{
	int x = (int)floorf(b->pos.x), y = (int)floorf(b->pos.y), z, lo, hi;
	float feet = bc_body_feet(b), rest;

	if (x < 0 || x >= BC_MAP_X || y < 0 || y >= BC_MAP_Y)
		return 0;
	z = (int)floorf(feet + 0.1f);
	z = bc_map_floor_at_or_below(m, x, y, z < 0 ? 0 : z > BC_MAP_WATER_Z ? BC_MAP_WATER_Z : z);
	if (z > BC_MAP_WATER_Z)
		z = BC_MAP_WATER_Z;
	rest = nav_rest(z);
	if (feet < rest - 1.3f || feet > rest + 0.3f)
		return 0;
	route_window(r, i, &lo, &hi);
	return near_route(m, r, lo, hi, x, y, z, 2);
}

/* THE GROUND SAFETY RULE. "This pace for `run` more ticks, then an
 * emergency stop": where is the body when it has stopped? The pace is safe
 * if, all the way, it is never below the route's floor, never hurt, and
 * at the end it is at rest on one of the route's safe cells.
 *
 * It used to ask only the first half -- not below the route -- and a body
 * that sprinted down a stair and overshot the turn at the bottom slid
 * onto a ledge at the stair's own level, "safe", turned round at a sprint
 * and went off the stair's other side into the sea (every route lost on
 * Parkour2 in the first soak). Height says nothing about sideways.
 *
 * A body that is not on a safe cell to begin with (it landed from a jump
 * on a column's edge, was pushed, has just been given a new route) cannot
 * be held to that: it is let walk, never sprint, under the height rule
 * alone, until it is back on one. */
static int ground_safe(const bc_nav_route *r, const bc_map *m, int i0, const bc_body *b0,
                       uint8_t cand, int run)
{
	bc_body bb = *b0;
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	int i = i0, t, on;

	if (bc_body_feet(b0) > floor_limit(r, i0) + 0.3f)
		return 1;       /* already under it: nothing to learn here */
	on = body_safe(r, m, i0, b0);
	if (!on && (cand & BC_K_SPRINT))
		return 0;
	for (t = 0; t < run + SAFE_STOP_TICKS; t++) {
		uint8_t k;

		i = ground_advance(r, i, &bb);
		if (t < run)
			ground_law(r, i, &bb, cand, &k, &ori);
		else
			nav_law_stop(&bb, &k, &ori);
		if (bc_body_step(&bb, m, nav_crouch_guard(&bb, m, k), ori, BC_BODY_DT) > 0)
			return 0;
		if (bc_body_feet(&bb) > floor_limit(r, ground_advance(r, i, &bb)) + 0.3f)
			return 0;
		if (t >= run && bc_body_speed(&bb) < 0.3f && nav_on_floor(&bb, (int)floorf(bc_body_feet(&bb) + 0.1f)))
			break;
	}
	return !on || body_safe(r, m, i0, &bb);
}

static void ground_tick(const bc_nav_route *r, const bc_map *m, int i, const bc_body *b,
                        uint8_t *keys, bc_v3 *ori)
{
	static const uint8_t paces[3] = {BC_K_SPRINT, 0, BC_K_SNEAK};
	int first = 1, c;

	if (i < r->n && r->steps[i].kind == BC_NAV_SPRINT)
		first = 0;
	if (i < r->n && r->steps[i].kind == BC_NAV_CROUCH)
		first = 2;      /* crouched is slower than a sneak: one choice */
	/* Two questions of each pace. Could it still stop safely after the
	 * few ticks a command takes to arrive (SAFE_RUN_TICKS)? That one is
	 * the guarantee: while it holds tick after tick, a stop is always in
	 * hand. And could it after a quarter of a second more of this
	 * (SAFE_LOOK_TICKS)? That one is foresight: a body that will swing wide
	 * of a turn with a drop beside it slows BEFORE the turn, instead of
	 * running to the last tick a stop works and slamming to a halt there.
	 * The slowest pace is asked only the first. */
	for (c = first; c < 3; c++)
		if (ground_safe(r, m, i, b, paces[c], SAFE_RUN_TICKS) &&
		    (c == 2 || ground_safe(r, m, i, b, paces[c], SAFE_LOOK_TICKS))) {
			ground_law(r, i, b, paces[c], keys, ori);
			return;
		}
	nav_law_stop(b, keys, ori);
}

/* Is there a jump straight ahead along the ground steps from i, with the
 * body already in its lane? Its index, or -1. */
static int jump_in_stride(const bc_nav_route *r, int i, const bc_body *b)
{
	int j, k;

	for (j = i; j < r->n && j < i + 7; j++)
		if (!nav_is_ground_kind(r->steps[j].kind))
			break;
	if (j >= r->n || j == i || !is_jump_kind(r->steps[j].kind))
		return -1;
	{
		const bc_nav_step *js = &r->steps[j];
		bc_nav_node a = step_from(r, j);
		float dx = (float)(js->to.x - a.x), dy = (float)(js->to.y - a.y);
		float len = sqrtf(dx * dx + dy * dy);
		float ux = dx / len, uy = dy / len;
		float rx = b->pos.x - ((float)a.x + 0.5f), ry = b->pos.y - ((float)a.y + 0.5f);
		float lat = -rx * uy + ry * ux;
		float vlat = (-b->vel.x * uy + b->vel.y * ux) * 32.0f;
		float val = (b->vel.x * ux + b->vel.y * uy) * 32.0f;

		for (k = i; k < j; k++)
			if (r->steps[k].dir != js->dir || r->steps[k].to.z != a.z ||
			    r->steps[k].kind == BC_NAV_CROUCH)
				return -1;
		if (step_from(r, i).z != a.z)
			return -1;
		if (fabsf(lat) < 0.2f && fabsf(vlat) < 1.0f && val > 0.5f && nav_on_floor(b, a.z))
			return j;
	}
	return -1;
}

/* --- edit steps ------------------------------------------------------- */

static void look_at(const bc_body *b, bc_nav_node v, bc_v3 *ori)
{
	float dx = (float)v.x + 0.5f - b->pos.x, dy = (float)v.y + 0.5f - b->pos.y;
	float dz = (float)v.z + 0.5f - b->pos.z;
	float l = sqrtf(dx * dx + dy * dy + dz * dz);

	if (l > 1e-4f) {
		ori->x = dx / l; ori->y = dy / l; ori->z = dz / l;
	}
}

/* Ask for one voxel. Returns 0, or -why when it has been asked for too
 * long. */
static int ask(bc_nav_follow *f, const bc_body *b, bc_nav_node v, uint8_t op,
               bc_nav_cmd *out, bc_v3 *ori)
{
	if (f->edit_vox.x == v.x && f->edit_vox.y == v.y && f->edit_vox.z == v.z) {
		if (++f->edit_ticks > BC_NAV_EDIT_WAIT_TICKS)
			return -BC_NAV_WHY_EDIT_REFUSED;
	} else {
		f->edit_vox = v;
		f->edit_ticks = 0;
	}
	out->edit = op == BC_BLOCK_DESTROY ? BC_NAV_EDIT_DIG : BC_NAV_EDIT_BUILD;
	out->ex = v.x; out->ey = v.y; out->ez = v.z;
	look_at(b, v, ori);
	return 0;
}

static int edit_tick(bc_nav_follow *f, const bc_nav_route *r, const bc_nav_moves *t,
                     const bc_map *m, const bc_body *b, uint8_t *keys, bc_v3 *ori, bc_nav_cmd *out)
{
	const bc_nav_step *st = &r->steps[f->step];
	bc_nav_node from = step_from(r, f->step);
	bc_nav_node vox[8];
	uint8_t op[8];
	float cx = (float)from.x + 0.5f, cy = (float)from.y + 0.5f;
	float dx = cx - b->pos.x, dy = cy - b->pos.y;
	float off = sqrtf(dx * dx + dy * dy);
	int n = nav_edits(t, m, NULL, from, st->to, vox, op, NULL, NULL);
	int steady = nav_on_floor(b, from.z) && off < 0.3f && bc_body_speed(b) < 1.0f;

	if (n < 0)
		return -BC_NAV_WHY_EDIT_REFUSED;

	if (n > 0 && !(st->kind == BC_NAV_PILLAR && op[0] == BC_BLOCK_BUILD)) {
		/* work to do from where the step starts: stand there, ask */
		nav_law_steer(b, cx, cy, 0, 1, keys, ori);
		if (steady) {
			*keys = 0;
			return ask(f, b, vox[0], op[0], out, ori);
		}
		return 0;
	}

	if (st->kind == BC_NAV_PILLAR) {
		if (n == 0) {
			/* the block is in: come down on it */
			*keys = 0;
			return nav_at(b, st->to) && nav_on_floor(b, st->to.z);
		}
		if (nav_on_floor(b, from.z)) {
			if (f->phase == 2) {
				/* back down without the block having come */
				f->phase = 1;
				if (++f->attempts >= 4)
					return -BC_NAV_WHY_EDIT_REFUSED;
			}
			nav_law_steer(b, cx, cy, 0, 1, keys, ori);
			if (off < 0.2f && bc_body_speed(b) < 0.6f)
				*keys = BC_K_JUMP;      /* until the server takes it */
			return 0;
		}
		f->phase = 2;
		*keys = 0;
		if (bc_body_feet(b) < (float)st->to.z - 0.04f) {
			/* feet clear of the voxel: now, and every tick until it
			 * is there */
			out->edit = BC_NAV_EDIT_BUILD;
			out->ex = vox[0].x; out->ey = vox[0].y; out->ez = vox[0].z;
		}
		return 0;
	}

	/* nothing left to edit: go */
	if (from.z >= BC_MAP_WATER_Z && st->to.z < BC_MAP_WATER_Z && st->dir != 8) {
		/* ...out of the sea, onto the bank just cut down to 62. Wading
		 * into it climbs nothing (nav.h, WATER): this is the jump the
		 * table measured, by the controller that measured it, simulated
		 * from here before it is pressed like any other. */
		nav_shot s;
		nav_xs xs;
		int res;

		memset(&s, 0, sizeof s);
		s.from = from; s.to = st->to;
		xs.phase = f->phase; xs.attempts = f->attempts;
		xs.air_keys = f->air_keys; xs.damage = 0; xs.ticks = f->xs_ticks;
		res = nav_jump_tick(&s, &xs, b, m, keys, ori);
		f->phase = xs.phase; f->attempts = xs.attempts;
		f->air_keys = xs.air_keys; f->xs_ticks = xs.ticks;
		return res;
	}
	if (nav_at(b, st->to) && (st->dir != 8 || nav_on_floor(b, st->to.z)))
		return 1;
	nav_law_steer(b, (float)st->to.x + 0.5f, (float)st->to.y + 0.5f, 0,
	              st->dir == 8 || f->step == r->n - 1, keys, ori);
	return 0;
}

/* --- the route against the map ---------------------------------------- */

static int route_holds(const bc_nav_follow *f, const bc_nav_route *r, const bc_nav_moves *t,
                       const bc_map *m)
{
	int j;

	for (j = f->step; j < r->n && j < f->step + 96; j++) {
		const bc_nav_step *st = &r->steps[j];
		bc_nav_node from = step_from(r, j);

		if (is_edit_kind(st->kind)) {
			bc_nav_node vox[8];
			uint8_t op[8];
			int n = nav_edits(t, m, NULL, from, st->to, vox, op, NULL, NULL);

			if (n < 0)
				return 0;
			if (n > 0)
				return 1;   /* what lies past unfinished work
				               cannot be judged yet */
			continue;
		}
		if (j == f->step && (is_jump_kind(st->kind) || st->kind == BC_NAV_DROP) &&
		    f->phase == NAV_XS_AIR)
			continue;       /* in flight: too late to mind */
		if (st->move >= 0 && !nav_move_fits(t, m, st->move, from, st->dir))
			return 0;
	}
	return 1;
}

/* --- the tick ---------------------------------------------------------- */

static int finish(bc_nav_follow *f, const bc_nav_route *r, const bc_map *m, const bc_body *b,
                  bc_nav_cmd *out, int status, int why)
{
	bc_v3 ori = f->last_ori;
	uint8_t k;

	if ((status != BC_NAV_ARRIVED || r->partial) && one_too_many(f, m, b, status, why))
		status = BC_NAV_GIVE_UP;

	nav_law_stop(b, &k, &ori);
	out->keys = nav_crouch_guard(b, m, k);
	out->ori = ori;
	out->edit = BC_NAV_EDIT_NONE;
	out->why = (uint8_t)why;
	out->step = (int16_t)f->step;
	f->last_ori = ori;
	return status;
}

int bc_nav_follow_tick(bc_nav_follow *f, const bc_nav_route *r, const bc_nav_moves *t,
                       const bc_map *m, const bc_body *b, const bc_nav_policy *pol,
                       bc_nav_cmd *out)
{
	bc_v3 ori = f->last_ori;
	uint8_t keys = 0;
	int iter, res = 0;

	memset(out, 0, sizeof *out);
	if (!f->started) {
		f->started = 1;
		f->anchor = b->pos;
		set_step(f, 0);
	}
	if (ori.x == 0.0f && ori.y == 0.0f)
		ori.x = 1.0f;

	if (m->rev != f->map_rev) {
		f->map_rev = m->rev;
		if (!route_holds(f, r, t, m))
			return finish(f, r, m, b, out, BC_NAV_ROUTE_STALE, 0);
	}

	if (f->recentre) {
		/* unsticking: back to the middle of the column stood in */
		bc_nav_node here;
		float dx, dy;

		f->recentre--;
		if (bc_nav_node_of_body(m, b, &here)) {
			dx = (float)here.x + 0.5f - b->pos.x;
			dy = (float)here.y + 0.5f - b->pos.y;
			nav_law_steer(b, (float)here.x + 0.5f, (float)here.y + 0.5f, 0, 1, &keys, &ori);
			if (dx * dx + dy * dy < 0.08f * 0.08f && bc_body_speed(b) < 0.8f)
				f->recentre = 0;
		} else {
			f->recentre = 0;
		}
		if (f->recentre == 0) {
			/* and the step afresh: a jump or a drop is simulated
			 * again from here before anything is committed */
			f->phase = 0;
			f->xs_ticks = 0;
			f->still_ticks = 0;
			f->anchor = b->pos;
		}
		out->keys = nav_crouch_guard(b, m, keys);
		out->ori = ori;
		out->step = (int16_t)f->step;
		f->last_ori = ori;
		return BC_NAV_FOLLOWING;
	}

	for (iter = 0; iter < 6; iter++) {
		const bc_nav_step *st;
		bc_nav_node from;

		if (f->step >= r->n) {
			bc_nav_node last = r->n ? r->steps[r->n - 1].to : r->start;
			float dx = (float)last.x + 0.5f - b->pos.x, dy = (float)last.y + 0.5f - b->pos.y;

			/* There: over the middle of the last column and on its floor
			 * -- or at rest a voxel above it, which is where a body is
			 * that came in beside a higher neighbour. It is 0.9 wide in
			 * a column of 1: a corner over the neighbour's edge holds it
			 * up, and it comes down only within a twentieth of a voxel
			 * of dead centre. It is in the column it was sent to; to
			 * call that "not arrived" was to stand there until STUCK
			 * (Temple, a goal in the inner corner of a terrace). */
			if (nav_at(b, last) && dx * dx + dy * dy < 0.4f * 0.4f &&
			    (nav_on_floor(b, last.z) ||
			     (nav_on_or_above(b, last.z) && !b->airborne && bc_body_speed(b) < 0.5f)))
				return finish(f, r, m, b, out, BC_NAV_ARRIVED, 0);
			ground_tick(r, m, r->n, b, &keys, &ori);
			break;
		}
		st = &r->steps[f->step];
		from = step_from(r, f->step);

		if (nav_is_ground_kind(st->kind)) {
			int j = jump_in_stride(r, f->step, b);
			int i;

			if (j >= 0) {
				set_step(f, j);
				continue;
			}
			i = ground_advance(r, f->step, b);
			if (i != f->step) {
				set_step(f, i);
				continue;
			}
			ground_tick(r, m, f->step, b, &keys, &ori);
			break;
		}

		if (is_jump_kind(st->kind) || st->kind == BC_NAV_DROP) {
			nav_shot s;
			nav_xs xs;

			memset(&s, 0, sizeof s);
			s.from = from; s.to = st->to;
			s.runup = st->runup;
			s.sprint = st->move >= 0 ? t->mv[st->move].sprint : 0;
			s.max_damage = pol ? pol->max_fall_damage : 0;
			s.diag = st->dir & 1;
			xs.phase = f->phase; xs.attempts = f->attempts;
			xs.air_keys = f->air_keys; xs.damage = 0; xs.ticks = f->xs_ticks;
			if (st->kind == BC_NAV_DROP)
				res = nav_drop_tick(&s, &xs, b, m, f->step_ticks, &keys, &ori);
			else
				res = nav_jump_tick(&s, &xs, b, m, &keys, &ori);
			f->phase = xs.phase; f->attempts = xs.attempts;
			f->air_keys = xs.air_keys; f->xs_ticks = xs.ticks;
		} else {
			res = edit_tick(f, r, t, m, b, &keys, &ori, out);
		}
		if (res == 1) {
			set_step(f, f->step + 1);
			res = 0;
			continue;
		}
		if (res < 0)
			return finish(f, r, m, b, out, BC_NAV_STEP_FAILED, -res);
		break;
	}

	/* --- is this still going anywhere? --- */
	{
		float dx = b->pos.x - f->anchor.x, dy = b->pos.y - f->anchor.y,
		      dz = b->pos.z - f->anchor.z;
		int n = f->step < r->n ? f->step : r->n - 1;
		float planned = n >= 0 ? r->steps[n].secs : 0.0f;

		if (dx * dx + dy * dy + dz * dz > 0.25f * 0.25f || out->edit != BC_NAV_EDIT_NONE) {
			f->anchor = b->pos;
			f->still_ticks = 0;
		} else if (++f->still_ticks > BC_NAV_STUCK_TICKS) {
			f->still_ticks = 0;
			if (f->recentred || f->step >= r->n || is_edit_kind(r->steps[f->step].kind))
				return finish(f, r, m, b, out, BC_NAV_STEP_FAILED, BC_NAV_WHY_STUCK);
			f->recentred = 1;
			f->recentre = BC_NAV_RECENTRE_TICKS;
		}
		if (++f->step_ticks > (uint16_t)(planned * 3.0f * BC_BODY_HZ) + 300u)
			return finish(f, r, m, b, out, BC_NAV_STEP_FAILED, BC_NAV_WHY_TIMEOUT);
	}

	/* --- is the body where the route is? --- */
	if (f->step < r->n && !is_jump_kind(r->steps[f->step].kind) &&
	    r->steps[f->step].kind != BC_NAV_DROP) {
		bc_nav_node a = step_from(r, f->step), c = r->steps[f->step].to;
		float ax = (float)a.x + 0.5f, ay = (float)a.y + 0.5f;
		float cx = (float)c.x + 0.5f, cy = (float)c.y + 0.5f;
		float da = (b->pos.x - ax) * (b->pos.x - ax) + (b->pos.y - ay) * (b->pos.y - ay);
		float dc = (b->pos.x - cx) * (b->pos.x - cx) + (b->pos.y - cy) * (b->pos.y - cy);
		float low = nav_rest(a.z > c.z ? a.z : c.z);

		if ((da > 9.0f && dc > 9.0f) ||
		    (!b->airborne && b->vel.z == 0.0f && bc_body_feet(b) > low + 1.5f))
			return finish(f, r, m, b, out, BC_NAV_OFF_ROUTE, 0);
	}

	out->keys = nav_crouch_guard(b, m, keys);
	out->ori = ori;
	out->step = (int16_t)f->step;
	f->last_ori = ori;
	return BC_NAV_FOLLOWING;
}

int bc_nav_follow_failed(const bc_nav_follow *f, const bc_nav_route *r,
                         bc_nav_node *from, bc_nav_node *to, int *kind)
{
	if (f->step < 0 || f->step >= r->n)
		return 0;
	*from = step_from(r, f->step);
	*to = r->steps[f->step].to;
	*kind = r->steps[f->step].kind;
	return 1;
}
