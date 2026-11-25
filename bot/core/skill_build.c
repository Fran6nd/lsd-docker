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

bt_status bc_do_dig_at(void *bot, const bt_args *a, float dt)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	bl_vec3 p, c;
	int x, y, z;
	float dx, dy, dz;

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
		b->bld.started = 1;
		b->bld.until = e->now + 15.0;
	}
	if (e->now >= b->bld.until) {
		b->bld.started = 0;
		return BT_FAILURE;
	}
	c.x = (float)x + 0.5f; c.y = (float)y + 0.5f; c.z = (float)z + 0.5f;
	dx = c.x - me->pos.x; dy = c.y - me->pos.y; dz = c.z - me->pos.z;
	if (dx * dx + dy * dy + dz * dz > 4.0f * 4.0f) {
		/* near it first: a floor beside it, within reach */
		int st = bc_move_to(b, p, 2.0f);

		bc_fire_at_will(b);
		if (st == BC_MV_FAILED) {
			b->bld.started = 0;
			return BT_FAILURE;
		}
		return BT_RUNNING;
	}
	b->wish.move = BC_MOVE_NONE;
	b->wish.tool = BL_TOOL_SPADE;
	b->wish.look = BC_LOOK_POINT;
	b->wish.look_at = c;
	if (me->tool == BL_TOOL_SPADE && e->now >= b->bld.edit_at) {
		float l = sqrtf(dx * dx + dy * dy + dz * dz);

		if (l < 1e-3f || (dx * me->ori.x + dy * me->ori.y + dz * me->ori.z) / l > 0.8f) {
			bl_ac_block ac;

			memset(&ac, 0, sizeof ac);
			ac.x = (int16_t)x; ac.y = (int16_t)y; ac.z = (int16_t)z;
			ac.action = BL_B_DESTROY;
			if (e->host.action)
				e->host.action(e->host.ctx, BL_AC_BLOCK, b->pid, &ac, sizeof ac);
			e->stats.edits++;
			b->bld.edit_at = e->now + 0.4;
		}
	}
	return BT_RUNNING;
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
