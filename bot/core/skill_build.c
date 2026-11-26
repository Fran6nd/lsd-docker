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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "brain.h"

/* a zone the server's rules keep this bot's hands off (the setting zone:
 * everybody's, or its team's) -- what the planner's routes respect too */
static int zoned_for(const bc_engine *e, int team, int x, int y, int dig)
{
	int i;

	for (i = 0; i < e->nzones; i++) {
		const bc_nav_zone *z = &e->zones[i];

		if (x >= z->x0 && x <= z->x1 && y >= z->y0 && y <= z->y1 &&
		    (z->team == 0 || z->team == team) && (dig ? z->no_dig : z->no_build))
			return 1;
	}
	return 0;
}

static int zoned(const bc_bot *b, int x, int y, int dig)
{
	return zoned_for(b->e, bc_me(b)->team, x, y, dig);
}

/* BUILDING IS A HELD FOCUS (the owner: "bots switch tool between each
 * block they place. ... when focusing on building, only an enemy
 * running/shooting (heard close) or a grenade should distract them, or an
 * enemy in their field of view"). The wishes are stated anew each tick,
 * the gun by default (engine.c), and a builder walking from one part's
 * stand to the next, or waiting for its next block, used to take the gun
 * out between every two blocks. A skill that builds holds the block out
 * the whole time (hold_block), and only this says when the focus is
 * broken -- the one place:
 *   - an enemy in sight (sight is the field of view: senses.c);
 *   - shot at: hurt by somebody, a round close by, a team-mate killed by
 *     it (senses' shot_at, `under_fire`'s), within FOCUS_SECS;
 *   - an enemy heard close, shooting or running (a shot, a step), within
 *     FOCUS_NEAR and FOCUS_SECS;
 *   - a grenade it would be hurt by (as the jolt that wakes every pick,
 *     engine.c: a threat of 25 or more).
 * Then the wishes are the fight's (fire_at_will takes the gun out). */
static const double FOCUS_SECS = 2.0;    /* a moment to look up and place it */
static const float FOCUS_NEAR = 15.0f;   /* close: a sprint of two seconds */

static int focus_broken(bc_bot *b)
{
	const bc_engine *e = b->e;
	const bc_senses *s = &b->senses;
	const bl_player *me = bc_me(b);

	if (s->n_visible > 0 || e->now - s->shot_at < FOCUS_SECS || bc_grenade_threat(b, NULL) >= 25.0f)
		return 1;
	if (s->noise.valid && e->now - s->noise.at < FOCUS_SECS &&
	    (s->noise.kind == BL_S_SHOT || s->noise.kind == BL_S_STEP) &&
	    (s->noise.by == BL_NO_PLAYER || e->w.players[s->noise.by].team != me->team)) {
		float dx = s->noise.pos.x - me->pos.x, dy = s->noise.pos.y - me->pos.y, dz = s->noise.pos.z - me->pos.z;

		if (dx * dx + dy * dy + dz * dz <= FOCUS_NEAR * FOCUS_NEAR)
			return 1;
	}
	return 0;
}

/* a building skill's tick done (r its status): while it goes on, the
 * block in hand -- or, the focus broken, the gun, and what to shoot at
 * (the edit waits: edit_voxel puts nothing but with the block out) */
static bt_status hold_block(bc_bot *b, bt_status r)
{
	if (r != BT_RUNNING)
		return r;
	if (focus_broken(b)) {
		b->wish.tool = BL_TOOL_GUN;
		bc_fire_at_will(b);
	} else {
		b->wish.tool = BL_TOOL_BLOCK;
	}
	return r;
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
	return hold_block(b, st == BC_MV_ARRIVED ? BT_SUCCESS : st == BC_MV_FAILED ? BT_FAILURE : BT_RUNNING);
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
 * as wanted; FAILURE no way to the stand, or past b->bld.until -- `secs`
 * at the stand: on the way there it is pushed on (the way is the route's
 * to fail, as build_at's is; a builder from across the map is no slower
 * a builder). The caller starts b->bld (started, until, from). */
static const double EDIT_SECS = 15.0;   /* at the stand, and the edit not made: given up */

static bt_status edit_voxel(bc_bot *b, int x, int y, int z, int build, double secs)
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
	if (st != BC_MV_ARRIVED) {
		b->bld.until = e->now + secs;
		return BT_RUNNING;
	}
	b->wish.move = BC_MOVE_NONE;
	b->wish.tool = build ? BL_TOOL_BLOCK : BL_TOOL_SPADE;
	b->wish.look = BC_LOOK_POINT;
	b->wish.look_at.x = (float)x + 0.5f; b->wish.look_at.y = (float)y + 0.5f; b->wish.look_at.z = (float)z + 0.5f;
	eye[0] = me->pos.x; eye[1] = me->pos.y; eye[2] = me->pos.z;
	if (!bc_nav_sees_edit_from(e->map, b->bld.from, eye, x, y, z, build)) {
		/* not from here. From the stand's middle no more either (a block
		 * put since, a team-mate's, between): another stand, or none;
		 * from its middle still: there, as the follower stands for an
		 * edit (the body is a little off it) */
		float cx = (float)b->bld.from.x + 0.5f - me->pos.x, cy = (float)b->bld.from.y + 0.5f - me->pos.y;

		if (!bc_nav_sees_edit(e->map, b->bld.from, x, y, z, build))
			return edit_stand(b, x, y, z, build) ? BT_RUNNING : BT_FAILURE;
		b->wish.move = BC_MOVE_FREE;
		b->wish.mx = cx; b->wish.my = cy;
		return BT_RUNNING;
	}
	if (me->tool == (build ? BL_TOOL_BLOCK : BL_TOOL_SPADE) && e->now >= b->bld.edit_at) {
		if (build && b->bld.line) {
			/* a block line from here (its start the placement a player
			 * makes, where the drag begins) to the caller's end */
			bl_ac_line ac;

			ac.x1 = (int16_t)x; ac.y1 = (int16_t)y; ac.z1 = (int16_t)z;
			ac.x2 = b->bld.line_to.x; ac.y2 = b->bld.line_to.y; ac.z2 = b->bld.line_to.z;
			if (e->host.action)
				e->host.action(e->host.ctx, BL_AC_LINE, b->pid, &ac, sizeof ac);
		} else {
			bl_ac_block ac;

			memset(&ac, 0, sizeof ac);
			ac.x = (int16_t)x; ac.y = (int16_t)y; ac.z = (int16_t)z;
			ac.action = build ? BL_B_BUILD : BL_B_DESTROY;
			if (e->host.action)
				e->host.action(e->host.ctx, BL_AC_BLOCK, b->pid, &ac, sizeof ac);
		}
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
		b->bld.until = e->now + EDIT_SECS;
	}
	r = edit_voxel(b, x, y, z, 0, EDIT_SECS);
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
		b->bld.until = e->now + EDIT_SECS;
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
		r = edit_voxel(b, v->x, v->y, v->z, 0, EDIT_SECS);
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
		r = edit_voxel(b, x, y, z, 1, 8.0);
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

/* --- build_part <blueprint> -------------------------------------------------
 *
 * Builds a blueprint (blueprint.h) with the rest of its team, a PART at a
 * time: the first voxel of the list not yet solid that can be put now (a
 * solid face to go against, and no earlier part still to come under it in
 * its column: the list is in the order things rest on one another), with
 * nobody in it, nobody else's, not marked; it goes there and, within
 * reach of it, CLAIMS it (bc_claim: a part is a duty for one), builds it
 * (part_start says how) and takes the next. A part it could not make is
 * marked for everybody for 30 s (as the team's no-way memory keeps a
 * goal). RUNNING while it works; SUCCESS the blueprint is whole; FAILURE
 * no such blueprint, building not allowed, no block, or no part free for
 * it (all built, claimed, waiting or marked). */

static const double PART_MARK = 30.0;

static void part_name(const bc_blueprint *bp, int i, char *out, size_t n)
{
	snprintf(out, n, "%s#%d", bp->name, i);
}

static int face_neighbour(const bc_map *m, int x, int y, int z)
{
	return bc_map_solid(m, x + 1, y, z) || bc_map_solid(m, x - 1, y, z) || bc_map_solid(m, x, y + 1, z) ||
	       bc_map_solid(m, x, y - 1, z) || bc_map_solid(m, x, y, z + 1) || (z > 0 && bc_map_solid(m, x, y, z - 1));
}

/* a body (anybody's, alive) in the voxel: a block cannot go there now --
 * not a part nobody can make, one somebody is standing in */
static int body_in(const bc_engine *e, const bc_bot *self, int x, int y, int z)
{
	int i;

	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		const bl_player *p = &e->w.players[i];

		if (p->state != BL_ALIVE || (self && i == self->pid))
			continue;
		if (p->pos.x + 0.45f > (float)x && p->pos.x - 0.45f < (float)x + 1.0f &&
		    p->pos.y + 0.45f > (float)y && p->pos.y - 0.45f < (float)y + 1.0f &&
		    (float)z + 1.0f > p->pos.z - 0.5f && (float)z < p->pos.z + 2.25f)
			return 1;
	}
	return 0;
}

/* an earlier part of the list, not built yet, under this one in its
 * column: the list's order is what rests on what, and a block put over
 * one that is still to come would cover it from every eye (a riser under
 * a step already laid) */
static int waits_on_below(const bc_engine *e, const bc_blueprint *bp, int i)
{
	const bc_bp_cell *c = &bp->cells[i];
	int j;

	for (j = 0; j < i; j++) {
		const bc_bp_cell *u = &bp->cells[j];

		if (u->x == c->x && u->y == c->y && u->z > c->z && !bc_map_solid(e->map, u->x, u->y, u->z))
			return 1;
	}
	return 0;
}

/* the part of bp this bot works at -- holds, or is on its way to (named
 * in its slot, not claimed yet: slot.since kept fresh, slot.at not) --,
 * or -1 */
static int held_part(const bc_bot *b, const bc_blueprint *bp)
{
	size_t l = strlen(bp->name);

	if ((b->e->now - b->slot.at > 2.0 && b->e->now - b->slot.since > 2.0) || strncmp(b->slot.name, bp->name, l) ||
	    b->slot.name[l] != '#')
		return -1;
	return atoi(b->slot.name + l + 1);
}

/* within the server's reach of it (5 of the eye to the voxel's middle:
 * bc_nav_sees_edit's): where a part is claimed. On the way it is not --
 * a builder held up on the way, or gone a long way round, keeps it from
 * nobody: whoever gets there first makes it, the others the next */
static int part_near(const bc_bot *b, const bc_bp_cell *c)
{
	const bl_player *me = bc_me(b);
	float dx = (float)c->x + 0.5f - me->pos.x, dy = (float)c->y + 0.5f - me->pos.y, dz = (float)c->z + 0.5f - me->pos.z;

	return dx * dx + dy * dy + dz * dz <= 5.0f * 5.0f;
}

static void part_let_go(bc_bot *b)
{
	b->slot.name[0] = 0;
	b->bld.started = 0;
}

/* a body's box (as body_in has it) at (x, y) with its eye at ez in a
 * part still to come */
static int box_in_parts(const bc_engine *e, const bc_blueprint *bp, float x, float y, float ez)
{
	int i;

	for (i = 0; i < bp->n; i++) {
		const bc_bp_cell *c = &bp->cells[i];

		if (x + 0.45f > (float)c->x && x - 0.45f < (float)c->x + 1.0f && y + 0.45f > (float)c->y &&
		    y - 0.45f < (float)c->y + 1.0f && (float)c->z + 1.0f > ez - 0.5f && (float)c->z < ez + 2.25f &&
		    !bc_map_solid(e->map, c->x, c->y, c->z))
			return 1;
	}
	return 0;
}

/* NO PART FOR IT, and standing where one goes: off it, to the nearest
 * floor round it that is in no part's way (a builder with nothing to put
 * does not stand where another would put: two waiting in one part kept
 * it from each other for good). 1 on its way, 0 not in the way (or
 * nowhere better). */
static int step_off_parts(bc_bot *b, const bc_blueprint *bp)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bc_nav_node best;
	float bd = 1e30f;
	int sx, sy, mv, x0 = (int)floorf(me->pos.x), y0 = (int)floorf(me->pos.y);
	bl_vec3 p;

	if (!box_in_parts(e, bp, me->pos.x, me->pos.y, me->pos.z))
		return 0;
	memset(&best, 0, sizeof best);  /* set by the scan below before it is read */
	for (sy = y0 - 2; sy <= y0 + 2; sy++)
		for (sx = x0 - 2; sx <= x0 + 2; sx++) {
			uint64_t st = bc_map_stand_bits(bc_map_col(e->map, sx, sy));

			for (; st; st &= st - 1) {
				bc_nav_node n;
				float dx, dy, dz, d;

				n.x = (int16_t)sx; n.y = (int16_t)sy; n.z = (int16_t)bc_ctz64(st);
				if (n.z >= BC_MAP_WATER_Z || box_in_parts(e, bp, (float)sx + 0.5f, (float)sy + 0.5f, (float)n.z - 2.25f))
					continue;
				dx = (float)sx + 0.5f - me->pos.x; dy = (float)sy + 0.5f - me->pos.y;
				dz = (float)n.z - 2.25f - me->pos.z;
				d = dx * dx + dy * dy + dz * dz;
				if (d < bd) { bd = d; best = n; }
			}
		}
	if (bd > 1e29f)
		return 0;
	p.x = (float)best.x + 0.5f; p.y = (float)best.y + 0.5f; p.z = (float)best.z - 2.25f;
	mv = bc_move_to_raw(b, p, 0.0f);
	return mv == BC_MV_PLANNING || mv == BC_MV_FOLLOWING;
}

/* THE PART AS A SEGMENT: from part i, the parts of the list that carry on
 * straight from it along one axis -- not solid, free (nobody else's, not
 * left alone) -- as far as one whose far side touches something solid
 * already: the server's block line takes its end only where a block
 * could go (lib_botlink do_line: a neighbour at each end), so a segment
 * runs between two anchors -- a prop from the ground up to its step, a
 * link from a pillar to a stair. As many as the blocks in hand. One line
 * from one stand instead of a block at a time. 1 and its end, or 0 (a
 * block alone). */
static int part_run(const bc_bot *b, const bc_blueprint *bp, int i, bc_nav_node *end)
{
	static const int D[6][3] = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } };
	const bc_engine *e = b->e;
	const bc_bp_cell *c = &bp->cells[i];
	uint64_t on[6] = { 0 };             /* bit k: a free part k along that axis */
	int j, d, best = 0, most = bc_me(b)->blocks;

	for (j = 0; j < bp->n; j++) {
		const bc_bp_cell *o = &bp->cells[j];
		int dx = o->x - c->x, dy = o->y - c->y, dz = o->z - c->z, k;
		char name[48];

		if (j == i || (!!dx + !!dy + !!dz) != 1 || o->rgb != c->rgb || bc_map_solid(e->map, o->x, o->y, o->z) ||
		    e->now < o->bad_until || body_in(e, NULL, o->x, o->y, o->z))
			continue;           /* (a line is one colour, the start's; and goes through nobody: not its own builder either) */
		k = abs(dx + dy + dz);
		/* (one beside it with a part still to come under it would cover
		 * that part; one over it in its own column covers only the run) */
		if (k >= 64 || ((o->x != c->x || o->y != c->y) && waits_on_below(e, bp, j)))
			continue;
		part_name(bp, j, name, sizeof name);
		if (!bc_claim((bc_bot *)b, name, 1, 0))
			continue;
		d = dx ? (dx > 0 ? 0 : 1) : dy ? (dy > 0 ? 2 : 3) : (dz > 0 ? 4 : 5);
		on[d] |= (uint64_t)1 << k;
	}
	for (d = 0; d < 6; d++) {
		int k;

		for (k = 1; k < 64 && k < most && (on[d] >> k & 1u); k++) {
			int x = c->x + D[d][0] * k, y = c->y + D[d][1] * k, z = c->z + D[d][2] * k, f, anchored = 0;

			for (f = 0; f < 6; f++)
				anchored |= bc_map_solid(e->map, x + D[f][0], y + D[f][1], z + D[f][2]);
			if (anchored && k > best) {
				best = k;
				end->x = (int16_t)x; end->y = (int16_t)y; end->z = (int16_t)z;
			}
		}
	}
	return best > 0;
}

/* Can the part be made as a floor stood on with one block: air for a body
 * over it, and a floor beside it level with it or one lower, from where
 * the route lays it and steps on? (With none, the route would pillar up
 * to it through what is under it -- other parts, out of their order and
 * in this one's colour.) */
static int laid_from_beside(const bc_map *m, const bc_bp_cell *c)
{
	static const int D[4][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } };
	int k;

	if (bc_map_solid(m, c->x, c->y, c->z - 1) || bc_map_solid(m, c->x, c->y, c->z - 2))
		return 0;
	for (k = 0; k < 4; k++) {
		uint64_t st = bc_map_stand_mask(m, c->x + D[k][0], c->y + D[k][1]);

		if ((st >> c->z & 1u) || (c->z + 1 < 64 && (st >> (c->z + 1) & 1u)))
			return 1;
	}
	return 0;
}

/* Start part i. The FIRST part left -- the structure's edge, that
 * nothing before it will make a floor for -- when it can be a floor laid
 * with one block from a floor beside it (laid_from_beside) is made as
 * build_at makes one: stood on, the route building it as it climbs, the
 * quickest way up a stair. Any other part
 * is put from a floor that sees a face for it (edit_stand); the first too
 * when it cannot be a floor, or the way onto it was not found last time.
 * A later part no floor sees waits for the parts before it (not looked at
 * again till the map changes); the first that cannot be made either way
 * is marked. 1 started (b->bld), 0 not. */
static int part_start(bc_bot *b, bc_blueprint *bp, int i, int first)
{
	bc_engine *e = b->e;
	bc_bp_cell *c = &bp->cells[i];

	b->bld.until = e->now + EDIT_SECS;
	if (first && !c->climb_failed && laid_from_beside(e->map, c)) {
		b->bld.started = 2;
		return 1;
	}
	if (c->unseen == e->map->rev + 1u && !first)
		return 0;
	if (edit_stand(b, c->x, c->y, c->z, 1)) {
		c->unseen = 0;
		b->bld.started = 1;
		return 1;
	}
	c->unseen = e->map->rev + 1u;
	if (first) {
		c->climb_failed = 0;
		bc_engine_log(e, 1, "bot #%d: %s part %d %d %d: no floor sees it, none to stand on: left %.0f s",
		              b->pid, bp->name, c->x, c->y, c->z, PART_MARK);
		c->bad_until = e->now + PART_MARK;
	}
	return 0;
}

static bt_status build_part_tick(bc_bot *b, const bt_args *a, float dt);

bt_status bc_do_build_part(void *bot, const bt_args *a, float dt)
{
	return hold_block(bot, build_part_tick(bot, a, dt));
}

static bt_status build_part_tick(bc_bot *b, const bt_args *a, float dt)
{
	bc_engine *e = b->e;
	bc_blueprint *bp;
	char name[48];
	int i, cur, first = -1, left = 0, can = 0;

	(void)dt;
	if (a->count < 1 || !(bp = bc_blueprint_for(b, a->text[0])) || !e->have_map || !may_edit(b, 0) ||
	    bc_me(b)->blocks == 0)
		return BT_FAILURE;
	cur = held_part(b, bp);
	if (cur >= bp->n || (cur >= 0 && (bc_map_solid(e->map, bp->cells[cur].x, bp->cells[cur].y, bp->cells[cur].z) ||
	                                  e->now < bp->cells[cur].bad_until || !b->bld.started))) {
		part_let_go(b);
		cur = -1;
	}
	if (cur < 0) {
		b->bld.started = 0;
		for (i = 0; i < bp->n; i++) {
			const bc_bp_cell *c = &bp->cells[i];

			if (bc_map_solid(e->map, c->x, c->y, c->z))
				continue;
			left++;
			can += face_neighbour(e->map, c->x, c->y, c->z);
			if (cur >= 0 || e->now < c->bad_until)
				continue;
			if (first < 0)
				first = i;
			if (e->now < c->noway_until && (c->noway[b->pid >> 6] >> (b->pid & 63) & 1u))
				continue;
			if (!face_neighbour(e->map, c->x, c->y, c->z) || zoned(b, c->x, c->y, 0) ||
			    body_in(e, b, c->x, c->y, c->z) || waits_on_below(e, bp, i))
				continue;
			part_name(bp, i, name, sizeof name);
			if (bc_claim(b, name, 1, 0) && part_start(b, bp, i, i == first))
				cur = i;
		}
		if (cur < 0 && !can && !strncmp(bp->name, "order", 5)) {
			char err[64];

			/* a leader's order, built whole -- or all that is left of it
			 * would float (what held it was no part of it: in a zone,
			 * dug): forgotten, his next is a new one */
			bc_engine_log(e, 0, "%s: %s", bp->name, left ? "the rest would float: left" : "built whole");
			bc_blueprint_set(e->blueprints, bp->name, "", err, sizeof err);
			return BT_SUCCESS;
		}
		if (cur < 0)
			return !left ? BT_SUCCESS : step_off_parts(b, bp) ? BT_RUNNING : BT_FAILURE;
	}
	part_name(bp, cur, name, sizeof name);
	{
		const bc_bp_cell *c = &bp->cells[cur];
		int claimed = !strcmp(b->slot.name, name) && e->now - b->slot.at <= 2.0;
		bt_status r;

		/* claimed there (and kept); on the way, only named -- and let go
		 * as soon as somebody there has claimed it */
		if (!bc_claim(b, name, 1, claimed || part_near(b, c))) {
			part_let_go(b);
			return BT_RUNNING;
		}
		if (!claimed && !part_near(b, c)) {
			snprintf(b->slot.name, sizeof b->slot.name, "%s", name);
			b->slot.since = e->now;
		}

		/* somebody else standing in it: another part meanwhile, this one
		 * not marked */
		if (body_in(e, b, c->x, c->y, c->z)) {
			part_let_go(b);
			return BT_RUNNING;
		}
		/* in the part's own colour (a prefab's), asked once */
		if ((c->rgb & BC_BP_RGB) && b->rgb != c->rgb) {
			uint32_t col = c->rgb & 0xFFFFFFu;

			if (e->host.action)
				e->host.action(e->host.ctx, BL_AC_COLOR, b->pid, &col, sizeof col);
			b->rgb = c->rgb;
		}
		if (b->bld.started == 1) {
			b->bld.line = (uint8_t)part_run(b, bp, cur, &b->bld.line_to);
			r = edit_voxel(b, c->x, c->y, c->z, 1, EDIT_SECS);
			b->bld.line = 0;
		} else {
			bl_vec3 eye;
			int st;

			eye.x = (float)c->x + 0.5f; eye.y = (float)c->y + 0.5f; eye.z = (float)c->z - 2.25f;
			st = bc_move_to_raw(b, eye, 0.0f);
			bc_fire_at_will(b);
			r = st == BC_MV_ARRIVED || bc_map_solid(e->map, c->x, c->y, c->z) ? BT_SUCCESS
			  : st == BC_MV_FAILED ? BT_FAILURE : BT_RUNNING;
		}
		if (r == BT_FAILURE && b->bld.started == 2) {
			bp->cells[cur].climb_failed = 1;        /* no way onto it: put from beside it, next */
		} else if (r == BT_FAILURE && e->now < b->bld.until) {
			/* no way to its stand FROM HERE: left by this one, for the
			 * others to try (the structure's first part marked for
			 * everybody held the whole of it up 30 s) */
			bc_bp_cell *m = &bp->cells[cur];

			if (e->now >= m->noway_until)
				memset(m->noway, 0, sizeof m->noway);
			m->noway[b->pid >> 6] |= (uint64_t)1 << (b->pid & 63);
			m->noway_until = e->now + PART_MARK;
			bc_engine_log(e, 1, "bot #%d: %s part %d %d %d: no way to where it is put from: left by it %.0f s",
			              b->pid, bp->name, c->x, c->y, c->z, PART_MARK);
		} else if (r == BT_FAILURE) {
			bc_engine_log(e, 1, "bot #%d: %s part %d %d %d: not put in %.0f s at its stand: left %.0f s", b->pid,
			              bp->name, c->x, c->y, c->z, EDIT_SECS, PART_MARK);
			bp->cells[cur].bad_until = e->now + PART_MARK;
			bp->cells[cur].climb_failed = 0;
		}
		if (r != BT_RUNNING)
			part_let_go(b);         /* the next, at the next tick */
		return BT_RUNNING;
	}
}

/* --- brace <blueprint> -------------------------------------------------------
 *
 * LINKS (the owner: "tie a stair to the ground, to a pillar, or to another
 * stair ... so a single cut cannot drop it"). Of the blueprint's voxels
 * built, the one whose cut would drop the most (bc_cull_would_drop: the
 * server's own flood); the mass that would drop (link_mass); in it, the
 * voxel halfway along its longest stretch from the cut -- held there, the
 * worst cut left drops half; beside that voxel, face to face, the
 * shortest column of air down to something solid (the ground, a pillar,
 * another stair) that is no part of the team's structures and not where
 * it may not build: a LINK, one block line between two anchors. Posted
 * as the blueprint "<name>.link" (its team's if the structure is) and
 * built as any (build_part: the line from the bottom, from a stand that
 * sees where it starts). Worth it while that cut drops more than the
 * link costs in blocks. RUNNING while one is built; FAILURE no such
 * blueprint, nothing worth a link, no column for one. */

enum { LINK_MASS_MAX = 4096 };      /* a structure's mass looked at: more is "held" */

/* the voxels that would fall if (cx, cy, cz) were dug -- the masses
 * round it, each flooded through faces on its own, that do not reach the
 * ground (one that does, or that is more than LINK_MASS_MAX, is held) --
 * in flood order from the cut (depth[k]: steps from it). How many. */
static int link_mass(const bc_map *m, int cx, int cy, int cz, bc_nav_node *out, uint16_t *depth)
{
	static const int F[6][3] = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } };
	int n = 0, s, f, k;

	for (s = 0; s < 6; s++) {
		int sx = cx + F[s][0], sy = cy + F[s][1], sz = cz + F[s][2], n0 = n, head = n, held = 0, seen = 0;

		if (!bc_map_in(sx, sy, sz) || !bc_map_solid(m, sx, sy, sz))
			continue;
		for (k = 0; k < n && !seen; k++)
			seen = out[k].x == sx && out[k].y == sy && out[k].z == sz;
		if (seen)
			continue;               /* in a mass already found */
		out[n].x = (int16_t)sx; out[n].y = (int16_t)sy; out[n].z = (int16_t)sz;
		depth[n++] = 1;
		while (head < n && !held) {
			bc_nav_node v = out[head];

			if (v.z >= BC_MAP_GROUND_Z) {
				held = 1;           /* it reaches the ground */
				break;
			}
			for (f = 0; f < 6 && !held; f++) {
				int x = v.x + F[f][0], y = v.y + F[f][1], z = v.z + F[f][2];

				if ((x == cx && y == cy && z == cz) || !bc_map_in(x, y, z) || !bc_map_solid(m, x, y, z))
					continue;
				for (k = n0, seen = 0; k < n && !seen; k++)
					seen = out[k].x == x && out[k].y == y && out[k].z == z;
				if (seen)
					continue;
				if (n == LINK_MASS_MAX) {
					held = 1;       /* as good as held */
					break;
				}
				out[n].x = (int16_t)x; out[n].y = (int16_t)y; out[n].z = (int16_t)z;
				depth[n++] = (uint16_t)(depth[head] + 1);
			}
			head++;
		}
		if (held)
			n = n0;
	}
	return n;
}

bt_status bc_do_brace(void *bot, const bt_args *a, float dt)
{
	static const int S[4][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } };
	bc_bot *b = bot;
	bc_engine *e = b->e;
	bc_blueprint *src, *link;
	char lname[BC_BLUEPRINT_NAME], full[BC_BLUEPRINT_NAME + 4], err[96];
	const bc_nav_protect *parts;
	bc_nav_node *mass, cut, w;
	uint16_t *depth;
	bc_bp_cell cells[64];
	int i, k, worst = 0, n, deepest = 0, best_len = 64, team = bc_me(b)->team, ncells = 0;
	bt_args sub;

	(void)dt;
	memset(&cut, 0, sizeof cut);
	if (a->count < 1 || !(src = bc_blueprint_for(b, a->text[0])) || !e->have_map || !may_edit(b, 0))
		return BT_FAILURE;
	if (snprintf(lname, sizeof lname, "%s.link", a->text[0]) >= (int)sizeof lname)
		return BT_FAILURE;
	/* the link being built: on with it */
	if ((link = bc_blueprint_for(b, lname)) != NULL) {
		for (i = 0; i < link->n && bc_map_solid(e->map, link->cells[i].x, link->cells[i].y, link->cells[i].z); i++) ;
		if (i < link->n) {
			sub = *a;
			sub.text[0] = lname;
			return bc_do_build_part(bot, &sub, dt);
		}
	}
	/* the worst cut */
	for (i = 0; i < src->n; i++) {
		const bc_bp_cell *c = &src->cells[i];

		if (!bc_map_solid(e->map, c->x, c->y, c->z))
			continue;
		n = bc_cull_would_drop(e->map, e->cull, c->x, c->y, c->z, -1, -1, -1);
		if (n > worst) {
			worst = n;
			cut.x = c->x; cut.y = c->y; cut.z = c->z;
		}
	}
	if (worst <= 1)
		return BT_FAILURE;
	/* (a decision now and then, not a tick's work: allocated for it) */
	mass = malloc(LINK_MASS_MAX * sizeof *mass);
	depth = malloc(LINK_MASS_MAX * sizeof *depth);
	if (!mass || !depth) {
		free(mass);
		free(depth);
		return BT_FAILURE;
	}
	n = link_mass(e->map, cut.x, cut.y, cut.z, mass, depth);
	for (k = 0; k < n; k++)
		if (depth[k] > deepest) deepest = depth[k];
	parts = bc_parts_for(e, team);
	/* halfway along the longest stretch: of the voxels at that depth, the
	 * one with the shortest column beside it */
	for (k = 0; k < n; k++) {
		int sd;

		if (depth[k] != (deepest + 1) / 2)
			continue;
		w = mass[k];
		for (sd = 0; sd < 4; sd++) {
			int px = w.x + S[sd][0], py = w.y + S[sd][1], g, z, ok = 1;

			if (!bc_map_in(px, py, w.z) || bc_map_solid(e->map, px, py, w.z) || zoned(b, px, py, 0))
				continue;
			g = bc_map_floor_at_or_below(e->map, px, py, w.z + 1);
			if (g >= 64 || g - w.z >= best_len || g - w.z > bc_me(b)->blocks)
				continue;
			/* its anchor below is no part of what would fall */
			for (z = 0; z < n && ok; z++)
				ok = !(mass[z].x == px && mass[z].y == py && mass[z].z == g);
			if (!ok)
				continue;
			for (z = w.z; z < g && ok; z++)
				ok = !(parts && bc_nav_protect_has(parts, px, py, z));
			if (!ok)
				continue;
			best_len = g - w.z;
			ncells = 0;
			for (z = g - 1; z >= w.z; z--) {        /* from the bottom: what rests on what */
				memset(&cells[ncells], 0, sizeof cells[ncells]);
				cells[ncells].x = (int16_t)px; cells[ncells].y = (int16_t)py; cells[ncells].z = (int16_t)z;
				ncells++;
			}
		}
	}
	free(mass);
	free(depth);
	if (!ncells || worst <= ncells)
		return BT_FAILURE;          /* no column for one, or not worth its blocks */
	if (strchr(src->name, '@') && (team == 1 || team == 2))
		snprintf(full, sizeof full, "%s@%d", lname, team);
	else
		snprintf(full, sizeof full, "%s", lname);
	if (!bc_blueprint_put(e->blueprints, full, cells, ncells, err, sizeof err)) {
		bc_engine_log(e, 1, "bot #%d: brace %s: %s", b->pid, src->name, err);
		return BT_FAILURE;
	}
	bc_engine_log(e, 0, "bot #%d: brace %s: a cut at %d %d %d drops %d: a link of %d up to %d %d %d", b->pid, src->name,
	              cut.x, cut.y, cut.z, worst, ncells, cells[ncells - 1].x, cells[ncells - 1].y, cells[ncells - 1].z);
	return hold_block(b, BT_RUNNING);
}

/* --- orders: a leader's prefab ---------------------------------------------
 *
 * A LEADER (skill_squad.c: every person, and the bots drawn) may order a
 * structure (a prefab, blueprint.h) built: its voxels set on the map at a
 * point, front turned toward him -- the bunker's door, the mirador's
 * first step on his side, its back to where he looks --, as the
 * blueprint "order<pid>", which his squad builds (`build_part leader`).
 * A new order of his replaces the last; built whole, it is forgotten. */

static void order_name(int leader, char *out, size_t n)
{
	snprintf(out, n, "order%d", leader);
}

/* A STAIR TO HERE (babel's "Build stairs here", a leader's ping on the
 * spot to reach: a platform's edge, a pillar's top). The solid voxel at
 * the spot is what it leads onto; its top step is the column beside it on
 * the leader's side, a voxel lower (a step up onto it); from there one
 * column and one voxel a step, down and toward him, to the first step
 * that rests on something solid -- each step and the voxel under it (its
 * riser), as babel's straight stair is laid (lib_stairs). Bottom first:
 * what rests on what. How many cells, at most max. */
enum { STAIR_STEPS_MAX = 63 };      /* the map's height: a stair from its top to its bottom */

static int stair_to_cells(const bc_map *m, int x, int y, int gz, int quarter, bc_bp_cell *out, int max)
{
	static const int Q[4][2] = { { 0, 1 }, { -1, 0 }, { 0, -1 }, { 1, 0 } };   /* toward the leader */
	bc_bp_cell steps[STAIR_STEPS_MAX * 2];
	int k, n = 0, dx = Q[quarter & 3][0], dy = Q[quarter & 3][1];

	for (k = 1; k <= STAIR_STEPS_MAX; k++) {
		int sx = x + dx * k, sy = y + dy * k, sz = gz + k;

		if (!bc_map_in(sx, sy, sz) || sz >= BC_MAP_GROUND_Z)
			break;
		if (bc_map_solid(m, sx, sy, sz))
			break;                  /* the ground (or a wall) reached: what is laid stands on it */
		memset(&steps[n], 0, sizeof steps[n]);
		steps[n].x = (int16_t)sx; steps[n].y = (int16_t)sy; steps[n].z = (int16_t)sz;
		n++;
		if (bc_map_solid(m, sx, sy, sz + 1))
			break;                  /* this step rests on something */
		memset(&steps[n], 0, sizeof steps[n]);
		steps[n].x = (int16_t)sx; steps[n].y = (int16_t)sy; steps[n].z = (int16_t)(sz + 1);
		n++;                        /* its riser */
	}
	/* bottom first: the last laid out is the lowest; a step's riser before it */
	for (k = 0; k < n && k < max; k++)
		out[k] = steps[n - 1 - k];
	return k;
}

int bc_order_build(bc_engine *e, int leader, const char *structure, bl_vec3 at, bl_vec3 look)
{
	bc_bp_cell *cells;
	const bc_kv6 *m = e->structures ? bc_structure_get(e->structures, structure) : NULL;
	char name[32], err[96];
	int x = (int)floorf(at.x), y = (int)floorf(at.y), gz, quarter, n;

	if ((!m && strcmp(structure, "stairs")) || !e->have_map || !e->blueprints || !bc_is_leader(e, leader) ||
	    !bc_map_in(x, y, 0))
		return 0;
	gz = bc_map_floor_at_or_below(e->map, x, y, (int)floorf(at.z) < 0 ? 0 : (int)floorf(at.z));
	if (gz >= 64)
		return 0;
	/* his side: the quarter nearest the way back to him (against his look) */
	quarter = fabsf(look.x) > fabsf(look.y) ? (look.x > 0.0f ? 1 : 3) : (look.y > 0.0f ? 2 : 0);
	/* an order is rare (a person's ping, a tree's choice): its cells are
	 * allocated for it, not kept */
	if (!(cells = malloc((size_t)(m ? m->n : STAIR_STEPS_MAX * 2) * sizeof *cells)))
		return 0;
	n = m ? bc_structure_cells(m, x, y, gz, quarter, cells, m->n)
	      : stair_to_cells(e->map, x, y, gz, quarter, cells, STAIR_STEPS_MAX * 2);
	{
		/* what the server would refuse him is no part of it: where his
		 * team may not build (the zones a script set: the filter's), and
		 * what is solid already (the ground under an uneven footprint) */
		int k, kept = 0, team = e->w.players[leader].team;

		for (k = 0; k < n; k++)
			if (!zoned_for(e, team, cells[k].x, cells[k].y, 0) && !bc_map_solid(e->map, cells[k].x, cells[k].y, cells[k].z))
				cells[kept++] = cells[k];
		n = kept;
	}
	order_name(leader, name, sizeof name);
	if (n <= 0 || !bc_blueprint_put(e->blueprints, name, cells, n, err, sizeof err)) {
		bc_engine_log(e, 1, "order of #%d: %s at %d %d %d: %s", leader, structure, x, y, gz, n <= 0 ? "off the map" : err);
		free(cells);
		return 0;
	}
	free(cells);
	bc_engine_log(e, 0, "order of #%d: %s at %d %d %d, %d voxels", leader, structure, x, y, gz, n);
	return 1;
}

/* the way from the leader to the spot, flat (the side he is on is the
 * other end of it); where he stands on it, the way he looks */
static bl_vec3 toward(bl_vec3 from, bl_vec3 to, bl_vec3 ori)
{
	bl_vec3 d = to;

	d.x -= from.x; d.y -= from.y; d.z = 0.0f;
	return d.x * d.x + d.y * d.y > 1.0f ? d : ori;
}

int bc_order_from_ping(bc_engine *e, int by, const char *reason, bl_vec3 at)
{
	char word[BC_BLUEPRINT_NAME];
	size_t i;

	/* "Build <structure> [here]", as the pie's build wedges say it */
	if (strncmp(reason, "Build ", 6) && strncmp(reason, "build ", 6))
		return 0;
	for (i = 0; reason[6 + i] && reason[6 + i] != ' ' && i + 1 < sizeof word; i++)
		word[i] = (char)(reason[6 + i] >= 'A' && reason[6 + i] <= 'Z' ? reason[6 + i] - 'A' + 'a' : reason[6 + i]);
	word[i] = 0;
	if (strcmp(word, "stairs") && (!e->structures || !bc_structure_get(e->structures, word)))
		return 0;           /* "Build here" (babel's): a place, as any ping */
	if (by < 0 || by >= BL_MAX_PLAYERS || !bc_is_leader(e, by)) {
		bc_engine_log(e, 0, "build ping of #%d (%s) ignored: not a leader", by, word);
		return 1;           /* a build call, not a place to go: nobody answers it */
	}
	bc_order_build(e, by, word, at, toward(e->w.players[by].pos, at, e->w.players[by].ori));
	return 1;
}

/* --- order_build <structure> [place] ------------------------------------- */

bt_status bc_do_order_build(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bl_vec3 p;

	(void)dt;
	if (a->count < 1 || !bc_place_of(b, a->count > 1 ? a->text[1] : "self", &p))
		return BT_FAILURE;
	return bc_order_build(b->e, b->pid, a->text[0], p, toward(bc_me(b)->pos, p, bc_me(b)->ori)) ? BT_SUCCESS : BT_FAILURE;
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
		b->bld.until = e->now + EDIT_SECS;
	}
	r = edit_voxel(b, x, y, z, 1, EDIT_SECS);
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
