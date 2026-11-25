/* skill_build.c -- Building and breaking at a place a tree names
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * New (2026-11-25), for a mode where what is built IS the game -- a
 * tower to an objective in the sky (babel) -- and for any script that
 * wants a bot to put a block somewhere or take one away. Routes already
 * dig and build on the way to a place (nav.h); these two make a place's
 * very floor, or a voxel's removal, the purpose. The engine knows no
 * tower and no mode: the script names the place (`@<name>`, the bridge).
 *
 *  - build_at <place>   stand on the floor under the place: the voxel an
 *                       eye at the place would stand on. Not snapped to
 *                       the nearest floor there is (go_to does that): a
 *                       floor that is not there is BUILT, by the route --
 *                       up a stair and one more step, a bridge: what a
 *                       player could build from where it stands (a face
 *                       it sees; lib_botlink holds a bot to that). Needs
 *                       the setting edit to allow building
 *                       (and digging, where the way needs it). SUCCESS
 *                       standing there; FAILURE no such place, edits not
 *                       allowed, no way (the route's own failure).
 *  - dig_at <place>     the voxel at the place (the block, not a floor:
 *                       a script names a block "x y z") is taken away:
 *                       near enough to reach it (4 of the eye; the
 *                       server allows 5), spade out, the head on it,
 *                       dug at the bot's cadence. SUCCESS when it is gone
 *                       (or was); FAILURE no such place, digging not
 *                       allowed, no way near, or 15 s without it going.
 */
#include <math.h>
#include <string.h>

#include "brain.h"

/* a zone the server's rules keep this bot's hands off (the setting zone:
 * everybody's, or its team's) -- what the planner's routes respect too */
static int zoned(const bc_bot *b, int x, int y, int dig)
{
	const bc_engine *e = b->e;
	int i, team = bc_me(b)->team;

	for (i = 0; i < e->nzones; i++) {
		const bc_nav_zone *z = &e->zones[i];

		if (x >= z->x0 && x <= z->x1 && y >= z->y0 && y <= z->y1 &&
		    (z->team == 0 || z->team == team) && (dig ? z->no_dig : z->no_build))
			return 1;
	}
	return 0;
}

static int may_edit(const bc_bot *b, int dig)
{
	const bc_engine *e = b->e;
	int d = e->may_dig, bu = e->may_build;

	if (b->edit >= 0) { d = b->edit & 1; bu = (b->edit >> 1) & 1; }
	return dig ? d : bu;
}

bt_status bc_do_build_at(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bl_vec3 p;
	int st;

	(void)dt;
	if (a->count < 1 || !bc_place_of(b, a->text[0], &p) || !may_edit(b, 0))
		return BT_FAILURE;
	st = bc_move_to_raw(b, p, 0.0f);
	bc_fire_at_will(b);
	return st == BC_MV_ARRIVED ? BT_SUCCESS : st == BC_MV_FAILED ? BT_FAILURE : BT_RUNNING;
}

/* WHERE TO STAND for an edit of (x, y, z): the nearest floor (to the bot)
 * within the server's reach of it from which a player could make it --
 * a build against a solid neighbour's face on the voxel's side, a dig of
 * a face open to the air, in clear sight (bc_nav_sees_edit: lib_botlink's
 * rule) -- and, for a build, not where the body would stand in its way.
 * Into b->bld.from; 0 for none. */
static int edit_stand(bc_bot *b, int x, int y, int z, int build)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	float best = 1e30f;
	int sx, sy, found = 0;

	/* the columns within the server's reach of 5 (bc_nav_sees_edit says
	 * which of their floors are near enough, and see a face) */
	for (sy = y - 5; sy <= y + 5; sy++)
		for (sx = x - 5; sx <= x + 5; sx++) {
			uint64_t st = bc_map_stand_bits(bc_map_col(e->map, sx, sy));

			for (; st; st &= st - 1) {
				bc_nav_node n;
				float dx, dy, dz, d;

				n.x = (int16_t)sx; n.y = (int16_t)sy; n.z = (int16_t)bc_ctz64(st);
				if (n.z >= BC_MAP_WATER_Z)
					continue;
				/* the body (the three cells over the floor) is not the voxel */
				if (sx == x && sy == y && z < n.z && z >= n.z - 3)
					continue;
				/* nor, for a dig, the floor it stands on */
				if (!build && sx == x && sy == y && z == n.z)
					continue;
				if (!bc_nav_sees_edit(e->map, n, x, y, z, build))
					continue;
				dx = (float)sx + 0.5f - me->pos.x; dy = (float)sy + 0.5f - me->pos.y;
				dz = (float)n.z - 2.25f - me->pos.z;
				d = dx * dx + dy * dy + dz * dz;
				if (d < best) {
					best = d;
					b->bld.from = n;
					found = 1;
				}
			}
		}
	return found;
}

/* The edit of (x, y, z) made, as a player makes it: to the stand
 * edit_stand chose (b->bld.from) by an exact route, then the tool out, the
 * head on the voxel, and the edit sent when the bot's own eye sees it as
 * the server will judge it. RUNNING till then; SUCCESS when the voxel is
 * as wanted; FAILURE no way to the stand, or past b->bld.until. The
 * caller starts b->bld (started, until, from). */
static bt_status edit_voxel(bc_bot *b, int x, int y, int z, int build)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bl_vec3 stand;
	float eye[3];
	int st;

	if (bc_map_solid(e->map, x, y, z) == build)
		return BT_SUCCESS;
	if (e->now >= b->bld.until)
		return BT_FAILURE;
	stand.x = (float)b->bld.from.x + 0.5f; stand.y = (float)b->bld.from.y + 0.5f;
	stand.z = (float)b->bld.from.z - 2.25f;
	st = bc_move_to_raw(b, stand, 0.0f);
	bc_fire_at_will(b);
	if (st == BC_MV_FAILED)
		return BT_FAILURE;
	if (st != BC_MV_ARRIVED)
		return BT_RUNNING;
	b->wish.move = BC_MOVE_NONE;
	b->wish.tool = build ? BL_TOOL_BLOCK : BL_TOOL_SPADE;
	b->wish.look = BC_LOOK_POINT;
	b->wish.look_at.x = (float)x + 0.5f; b->wish.look_at.y = (float)y + 0.5f; b->wish.look_at.z = (float)z + 0.5f;
	eye[0] = me->pos.x; eye[1] = me->pos.y; eye[2] = me->pos.z;
	if (me->tool == (build ? BL_TOOL_BLOCK : BL_TOOL_SPADE) && e->now >= b->bld.edit_at &&
	    bc_nav_sees_edit_from(e->map, b->bld.from, eye, x, y, z, build)) {
		bl_ac_block ac;

		memset(&ac, 0, sizeof ac);
		ac.x = (int16_t)x; ac.y = (int16_t)y; ac.z = (int16_t)z;
		ac.action = build ? BL_B_BUILD : BL_B_DESTROY;
		if (e->host.action)
			e->host.action(e->host.ctx, BL_AC_BLOCK, b->pid, &ac, sizeof ac);
		e->stats.edits++;
		b->bld.edit_at = e->now + (build ? 0.5 : 0.4);
	}
	return BT_RUNNING;
}

bt_status bc_do_dig_at(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	bl_vec3 p;
	bt_status r;
	int x, y, z;

	(void)dt;
	if (a->count < 1 || !bc_place_of(b, a->text[0], &p) || !e->have_map || !may_edit(b, 1)) {
		b->bld.started = 0;
		return BT_FAILURE;
	}
	x = (int)floorf(p.x); y = (int)floorf(p.y); z = (int)floorf(p.z);
	if (!bc_map_in(x, y, z) || !bc_map_solid(e->map, x, y, z)) {
		b->bld.started = 0;
		return BT_SUCCESS;
	}
	if (!b->bld.started) {
		if (zoned(b, x, y, 1) || !edit_stand(b, x, y, z, 0))
			return BT_FAILURE;
		b->bld.started = 1;
		b->bld.until = e->now + 15.0;
	}
	r = edit_voxel(b, x, y, z, 0);
	if (r != BT_RUNNING)
		b->bld.started = 0;
	return r;
}

/* --- dig_weakest <place> [voxels] ----------------------------------------
 *
 * Breaking a structure where it falls most. Of the solid voxels within
 * `voxels` of the place that a player could dig (from a floor in reach
 * that sees a face of it open to the air: edit_stand; not the map's
 * ground), the one whose removal the server's cull answers
 * with the most voxels dropped (bc_cull_would_drop: the engine floods its
 * map as the server floods its own). A structure with no such block -- two
 * wide, propped -- is cut a block wide: the voxel and one beside it, the
 * pair that drops the most. Chosen once, when it starts. HOW it is cut is
 * the cheapest it has, block by block: the weapon the tree names (an
 * item: `dig_weakest @breach 6 rocket`), a grenade -- both from where it
 * stands, at a block in its sight, the grenade landing on it (the
 * server's 3x3x3) and it clear of the blast -- else dug as dig_at digs. SUCCESS when the cut is made (or the
 * blocks went otherwise); FAILURE nothing there drops anything, digging not
 * allowed, no way near, 15 s on one voxel. */

static int open_face(const bc_map *m, int x, int y, int z)
{
	return !bc_map_solid(m, x + 1, y, z) || !bc_map_solid(m, x - 1, y, z) ||
	       !bc_map_solid(m, x, y + 1, z) || !bc_map_solid(m, x, y - 1, z) ||
	       !bc_map_solid(m, x, y, z + 1) || !bc_map_solid(m, x, y, z - 1);
}

/* a face of the voxel open to the air, in clear sight of the eye: what a
 * grenade or a weapon is aimed at (from any distance; the spade's own
 * rule, with its reach, is bc_nav_sees_edit) */
static int face_in_sight(const bc_bot *b, int x, int y, int z, bl_vec3 *at)
{
	/* the top first: what a grenade lands on and lies on till it bursts */
	static const int8_t f[6][3] = { {0,0,-1}, {1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1} };
	const bc_engine *e = b->e;
	bl_vec3 eye = bc_me(b)->pos, p;
	int i;

	for (i = 0; i < 6; i++) {
		if (bc_map_solid(e->map, x + f[i][0], y + f[i][1], z + f[i][2]))
			continue;
		p.x = (float)x + 0.5f + 0.55f * (float)f[i][0];
		p.y = (float)y + 0.5f + 0.55f * (float)f[i][1];
		p.z = (float)z + 0.5f + 0.55f * (float)f[i][2];
		if (bc_sight_clear(e->map, eye, p)) {
			if (at) *at = p;
			return 1;
		}
	}
	return 0;
}

static int in_sight(const bc_bot *b, int x, int y, int z)
{
	return face_in_sight(b, x, y, z, NULL);
}

/* a grenade from where it stands at a voxel it sees (a face of it in
 * sight), aimed at an open face -- its top first: what a lob lands on,
 * seen or not from below -- that lands with the voxel in its crater: the
 * aim in *mark */
static int grenade_takes(const bc_bot *b, int x, int y, int z, bl_vec3 *mark)
{
	static const int8_t f[6][3] = { {0,0,-1}, {1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1} };
	const bc_engine *e = b->e;
	bl_vec3 eye = bc_me(b)->pos, p, vel;
	float flight;
	int i;

	if (!in_sight(b, x, y, z))
		return 0;
	for (i = 0; i < 6; i++) {
		if (bc_map_solid(e->map, x + f[i][0], y + f[i][1], z + f[i][2]))
			continue;
		p.x = (float)x + 0.5f + 0.55f * (float)f[i][0];
		p.y = (float)y + 0.5f + 0.55f * (float)f[i][1];
		p.z = (float)z + 0.5f + 0.55f * (float)f[i][2];
		if (bc_grenade_lands(e->map, eye, p, x, y, z, &vel, &flight)) {
			if (mark) *mark = p;
			return 1;
		}
	}
	return 0;
}

/* a block of a cut it can make, and how dear: 2 from where it stands
 * (with a weapon the tree names, in its sight; with a grenade, one that
 * lands on it from here), 1 from a floor that digs it (walked to), 0 not */
static int cuttable(bc_bot *b, int x, int y, int z, int with_item, int with_grenade)
{
	if ((with_item && in_sight(b, x, y, z)) || (with_grenade && grenade_takes(b, x, y, z, NULL)))
		return 2;
	return edit_stand(b, x, y, z, 0) ? 1 : 0;
}

static int choose_cut(bc_bot *b, bl_vec3 at, int r, int with_item, int with_grenade)
{
	static const int8_t d[6][3] = { {1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1} };
	bc_engine *e = b->e;
	int ax = (int)floorf(at.x), ay = (int)floorf(at.y), az = (int)floorf(at.z);
	int x, y, z, i, pass, best = 0, best_how = 0;

	b->bld.n_cut = 0;
	for (pass = 0; pass < 2 && best == 0; pass++)
		for (z = az - r; z <= az + r; z++)
			for (y = ay - r; y <= ay + r; y++)
				for (x = ax - r; x <= ax + r; x++) {
					if ((x - ax) * (x - ax) + (y - ay) * (y - ay) + (z - az) * (z - az) > r * r ||
					    z < 0 || z >= BC_MAP_GROUND_Z || !bc_map_solid(e->map, x, y, z) ||
					    !open_face(e->map, x, y, z) || zoned(b, x, y, 1))
						continue;
					for (i = pass ? 0 : 5; i < 6; i++) {
						int wx = x + d[i][0], wy = y + d[i][1], wz = z + d[i][2], n;

						if (pass && (wz >= BC_MAP_GROUND_Z || !bc_map_solid(e->map, wx, wy, wz) || zoned(b, wx, wy, 1)))
							continue;
						n = pass ? bc_cull_would_drop(e->map, e->cull, x, y, z, wx, wy, wz)
						         : bc_cull_would_drop(e->map, e->cull, x, y, z, -1, -1, -1);
						/* only a cut a player could make: each block of it
						 * dug from a floor that sees a face of it */
						/* the most it drops; of equals, the one cut from
						 * where it stands rather than walked to */
						if (n > 0 && n >= best) {
							int how = cuttable(b, x, y, z, with_item, with_grenade);

							if (how && pass) {
								int h2 = cuttable(b, wx, wy, wz, with_item, with_grenade);

								how = h2 < how ? h2 : how;
							}
							if (!how || (n == best && how <= best_how))
								continue;
							best_how = how;
							best = n;
							b->bld.cut[0].x = (int16_t)x; b->bld.cut[0].y = (int16_t)y; b->bld.cut[0].z = (int16_t)z;
							b->bld.cut[1].x = (int16_t)wx; b->bld.cut[1].y = (int16_t)wy; b->bld.cut[1].z = (int16_t)wz;
							b->bld.n_cut = (uint8_t)(pass ? 2 : 1);
						}
					}
				}
	return best;
}

bt_status bc_do_dig_weakest(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	const char *item = a->count > 2 && a->text[2] && a->text[2][0] ? a->text[2] : NULL;
	bl_vec3 p;
	bt_status r = BT_SUCCESS;
	int k, with_item, with_grenade;

	(void)dt;
	if (a->count < 1 || !bc_place_of(b, a->text[0], &p) || !e->have_map || !e->cull || !may_edit(b, 1)) {
		b->bld.started = 0;
		return BT_FAILURE;
	}
	with_item = item && bc_item_count(b, item) > 0;
	with_grenade = me->grenades > 0;
	if (!b->bld.started) {
		if (choose_cut(b, p, a->count > 1 && a->num[1] > 0.0f ? (int)(a->num[1] + 0.5f) : 6, with_item, with_grenade) == 0)
			return BT_FAILURE;
		b->bld.started = 1;
		b->bld.dx = -1;             /* which voxel of the cut it stands for: none yet */
		b->bld.blast = 0;
		b->bld.until = e->now + 15.0;
	}
	for (k = 0; k < b->bld.n_cut; k++) {
		const bc_nav_node *v = &b->bld.cut[k];
		bl_vec3 c, face;

		if (!bc_map_solid(e->map, v->x, v->y, v->z))
			continue;
		if (e->now >= b->bld.until) {
			r = BT_FAILURE;
			break;
		}
		c.x = (float)v->x + 0.5f; c.y = (float)v->y + 0.5f; c.z = (float)v->z + 0.5f;
		/* a blast on its way: it waits for it, watching */
		if (b->bld.blast && e->now < b->bld.edit_at) {
			b->wish.move = BC_MOVE_NONE;
			b->wish.look = BC_LOOK_POINT;
			b->wish.look_at = c;
			return BT_RUNNING;
		}
		b->bld.blast = 0;
		/* HOW, the cheapest it has: the weapon the tree named, a grenade,
		 * then the spade -- the first two from where it stands, at a block
		 * in its sight */
		if (b->nade.phase == 0 && in_sight(b, v->x, v->y, v->z)) {
			if (item && bc_item_use_at(b, item, c)) {
				b->bld.blast = 1;
				b->bld.edit_at = e->now + 3.0;      /* a weapon's flight, and the blast */
				return BT_RUNNING;
			}
		}
		if (me->grenades > 0 && (b->nade.phase != 0 || grenade_takes(b, v->x, v->y, v->z, &face))) {
			/* at the face it sees (its top first): a grenade lands on a
			 * block, it does not go into one */
			bt_status t = bc_throw_at(b, b->nade.phase != 0 ? c : face, 1);

			if (t == BT_RUNNING)
				return BT_RUNNING;
			if (t == BT_SUCCESS) {
				b->bld.blast = 1;
				b->bld.edit_at = e->now + (double)b->nade.fuse + 0.5;
				return BT_RUNNING;
			}
		}
		if (b->bld.dx != k) {
			/* this voxel's own stand */
			if (!edit_stand(b, v->x, v->y, v->z, 0)) {
				r = BT_FAILURE;
				break;
			}
			b->bld.dx = (int8_t)k;
		}
		r = edit_voxel(b, v->x, v->y, v->z, 0);
		break;
	}
	if (r == BT_RUNNING)
		return r;
	b->bld.started = 0;
	return r;
}

/* --- build_cover -----------------------------------------------------------
 *
 * Shot at with no cover in view: cover made where it stands. A wall two
 * high in the column beside it toward the man who shot it (the trees'
 * `threat`), on the axis nearest the way to him -- enough to hide a
 * crouched body -- the middle first, then a column either side while it
 * has the blocks: one to three wide. Each block as a player puts it: the
 * first on the floor's top face, the second on top of the first, both
 * under its eye, sent when its own eye sees the face (edit_voxel). Not
 * where a zone forbids building. SUCCESS the middle stands (the sides as
 * far as blocks and sight allow); FAILURE nobody shot at it, no block in
 * hand, building not allowed, in the air, or the middle cannot be made. */

/* the cells of the wall, middle first: index k -> (x, y, z) */
static void cover_cell(const bc_bot *b, int k, int *x, int *y, int *z)
{
	int w = k / 2 == 0 ? 0 : k / 2 == 1 ? -1 : 1;   /* middle, one side, the other */
	int px = -b->bld.dy, py = b->bld.dx;            /* across the way to him */

	*x = b->bld.from.x + b->bld.dx + w * px;
	*y = b->bld.from.y + b->bld.dy + w * py;
	*z = b->bld.from.z - 1 - (k & 1);               /* on the floor, then on it */
}

bt_status bc_do_build_cover(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bl_vec3 th;
	int k;

	(void)a; (void)dt;
	if (!e->have_map || !may_edit(b, 0)) {
		b->bld.started = 0;
		return BT_FAILURE;
	}
	if (!b->bld.started) {
		bc_body body;
		bc_nav_node at;
		float dx, dy;

		if (me->blocks < 2 || !bc_place_of(b, "threat", &th))
			return BT_FAILURE;
		bc_body_of(me, &body);
		if (!bc_nav_node_of_body(e->map, &body, &at))
			return BT_FAILURE;
		dx = th.x - me->pos.x; dy = th.y - me->pos.y;
		b->bld.from = at;
		b->bld.dx = (int8_t)(fabsf(dx) >= fabsf(dy) ? (dx > 0.0f ? 1 : -1) : 0);
		b->bld.dy = (int8_t)(fabsf(dx) >= fabsf(dy) ? 0 : (dy > 0.0f ? 1 : -1));
		b->bld.started = 1;
		b->bld.until = e->now + 8.0;
	}
	for (k = 0; k < 6; k++) {
		int x, y, z;
		bt_status r;
		float eye[3];

		cover_cell(b, k, &x, &y, &z);
		if (!bc_map_in(x, y, z) || bc_map_solid(e->map, x, y, z))
			continue;
		/* a side it cannot make (no block left, a zone, out of its own
		 * eye's sight where it stands -- it does not move for a side --,
		 * nothing to put it against): the wall is as wide as it gets */
		eye[0] = me->pos.x; eye[1] = me->pos.y; eye[2] = me->pos.z;
		if (k >= 2 && (me->blocks == 0 || zoned(b, x, y, 0) ||
		               !bc_nav_sees_edit_from(e->map, b->bld.from, eye, x, y, z, 1)))
			continue;
		if (k < 2 && (me->blocks == 0 || zoned(b, x, y, 0) ||
		              !bc_nav_sees_edit(e->map, b->bld.from, x, y, z, 1))) {
			b->bld.started = 0;
			return BT_FAILURE;
		}
		r = edit_voxel(b, x, y, z, 1);
		if (r == BT_FAILURE) {
			if (k < 2) { b->bld.started = 0; return BT_FAILURE; }
			continue;
		}
		if (r == BT_RUNNING) {
			b->wish.crouch = 0;         /* up to put it on: the face under its eye */
			return BT_RUNNING;
		}
	}
	b->bld.started = 0;
	return BT_SUCCESS;
}

/* --- put_at <place> -------------------------------------------------------
 *
 * A block at a voxel a script names ("x y z"), placed as a player places
 * one: against a solid neighbour's face that it sees, within reach
 * (bc_nav_sees_edit, lib_botlink's rule). Where to stand is the nearest
 * floor round the voxel from which the placement is legal -- not in the
 * voxel's way -- gone to by an exact route (one that may build its own
 * way). For what build_at cannot do: a block that is not a floor to stand
 * on (a pillar under a stair, a second row beside one). SUCCESS when the
 * voxel is solid (or was); FAILURE no such place, building not allowed,
 * no block in hand, nowhere it can be placed from, no way there, 15 s. */

bt_status bc_do_put_at(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	bl_vec3 p;
	bt_status r;
	int x, y, z;

	(void)dt;
	if (a->count < 1 || !bc_place_of(b, a->text[0], &p) || !e->have_map || !may_edit(b, 0)) {
		b->bld.started = 0;
		return BT_FAILURE;
	}
	x = (int)floorf(p.x); y = (int)floorf(p.y); z = (int)floorf(p.z);
	if (!bc_map_in(x, y, z) || bc_map_solid(e->map, x, y, z)) {
		b->bld.started = 0;
		return bc_map_in(x, y, z) ? BT_SUCCESS : BT_FAILURE;
	}
	if (!b->bld.started) {
		if (bc_me(b)->blocks == 0 || zoned(b, x, y, 0) || !edit_stand(b, x, y, z, 1))
			return BT_FAILURE;
		b->bld.started = 1;
		b->bld.until = e->now + 15.0;
	}
	r = edit_voxel(b, x, y, z, 1);
	if (r != BT_RUNNING)
		b->bld.started = 0;
	return r;
}

void bc_do_build_stop(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a;
	b->e->stats.action_stops++;
	b->bld.started = 0;
	bc_move_stop(b);
}

/* --- build_perch [place] -------------------------------------------------
 *
 * A bot up where it cannot get down (a roof, a slab at the top of the map:
 * `stranded`) is not useless: its height is a vantage. It builds a LEVEL
 * WALKWAY from where it stands toward the place (default: the enemy's
 * base), along the axis nearest the way to it, at its own floor's height,
 * a block a step -- each step a route of one bridge block (build_at's way:
 * the block against the far face of the last, put in from its edge, as a
 * player would) -- and stops where it first sees the place within its
 * gun's reach, or where its blocks run out (it has what it was spawned
 * with, 50, and one back for each block it digs: nothing is restocked up
 * there), or at what is in the way (a voxel where the body would stand) or
 * the map's edge. SUCCESS there (the tree then camps); FAILURE building not
 * allowed, no block in hand, no such place. */

static int perch_sees(const bc_bot *b, bl_vec3 eye, bl_vec3 place)
{
	float dx = place.x - eye.x, dy = place.y - eye.y, dz = place.z - eye.z;

	return dx * dx + dy * dy + dz * dz <= bc_gun_reach(b) * bc_gun_reach(b) &&
	       bc_sight_clear(b->e->map, eye, place);
}

bt_status bc_do_build_perch(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bl_vec3 place, eye;
	bc_nav_node at, next;
	bc_body body;
	int st, k;

	(void)dt;
	if (!bc_place_of(b, a->count > 0 ? a->text[0] : "enemy_base", &place) || !e->have_map || !may_edit(b, 0)) {
		b->bld.started = 0;
		return BT_FAILURE;
	}
	bc_body_of(me, &body);
	if (!bc_nav_node_of_body(e->map, &body, &at))
		return BT_RUNNING;      /* in the air: where it lands decides */
	if (!b->bld.started) {
		float dx = place.x - me->pos.x, dy = place.y - me->pos.y;

		if (me->blocks == 0)
			return BT_FAILURE;
		b->bld.started = 1;
		b->bld.from = at;
		b->bld.dx = (int8_t)(fabsf(dx) >= fabsf(dy) ? (dx > 0.0f ? 1 : -1) : 0);
		b->bld.dy = (int8_t)(fabsf(dx) >= fabsf(dy) ? 0 : (dy > 0.0f ? 1 : -1));
	}
	eye.x = (float)at.x + 0.5f; eye.y = (float)at.y + 0.5f; eye.z = (float)at.z - 2.25f;
	/* the next cell of the walkway: the first one along the line from
	 * where it set out that has no floor at that height */
	next = b->bld.from;
	for (k = 1; k < 512; k++) {
		next.x = (int16_t)(b->bld.from.x + k * b->bld.dx);
		next.y = (int16_t)(b->bld.from.y + k * b->bld.dy);
		if (!bc_map_in(next.x, next.y, next.z) || !bc_map_solid(e->map, next.x, next.y, next.z))
			break;
	}
	if (perch_sees(b, eye, place)) {
		b->bld.started = 0;
		return BT_SUCCESS;          /* it sees the place, in reach */
	}
	{
		/* nowhere further: the map's edge, something where the body would
		 * stand, or no block left -- to the walkway's end, and done there */
		int end = next.x < 1 || next.y < 1 || next.x > BC_MAP_X - 2 || next.y > BC_MAP_Y - 2 || me->blocks == 0, z;

		for (z = next.z - 3; z < next.z && !end; z++)
			if (z >= 0 && bc_map_solid(e->map, next.x, next.y, z))
				end = 1;
		if (end) {
			next.x = (int16_t)(next.x - b->bld.dx);
			next.y = (int16_t)(next.y - b->bld.dy);
			if (at.x == next.x && at.y == next.y) {
				b->bld.started = 0;
				return BT_SUCCESS;
			}
		}
	}
	{
		bl_vec3 p;

		p.x = (float)next.x + 0.5f; p.y = (float)next.y + 0.5f; p.z = (float)next.z - 2.25f;
		st = bc_move_to_raw(b, p, 0.0f);
	}
	bc_fire_at_will(b);
	if (st == BC_MV_FAILED) {
		b->bld.started = 0;
		return BT_FAILURE;
	}
	return BT_RUNNING;
}
