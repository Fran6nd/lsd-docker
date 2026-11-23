/* nav_i.h -- nav's private parts, shared by its four files
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * nav.h is the module's documentation. This is only how it is split:
 *
 *   nav_exec.c    the controllers: how keys are chosen to do one move
 *   nav_moves.c   the measuring of the move table, by running those
 *                 controllers in built scenes
 *   nav_plan.c    the search, the policy's helpers, the edit moves
 *   nav_follow.c  the follower: a route, tick by tick
 *
 * The point of the split is the first line: the SAME controller code is
 * what gets measured, what the plan's table therefore describes, and what
 * the follower runs. There is no second opinion about a move anywhere.
 */
#ifndef BC_NAV_I_H
#define BC_NAV_I_H

#include "nav.h"

/* dir 0..7: E, SE, S, SW, W, NW, N, NE. Odd is diagonal. */
extern const int8_t bc_nav_dx[8];
extern const int8_t bc_nav_dy[8];

/* Where the feet rest on a node: on the voxel, or one deeper in water. */
static inline float nav_rest(int z)
{
	return z >= BC_MAP_WATER_Z ? 64.0f : (float)z;
}

static inline uint32_t nav_pack(bc_nav_node n)
{
	return ((uint32_t)n.x & 511u) | (((uint32_t)n.y & 511u) << 9) |
	       (((uint32_t)n.z & 63u) << 18) | (1u << 24);
}

static inline int nav_is_ground_kind(int k)
{
	return k == BC_NAV_WALK || k == BC_NAV_SPRINT || k == BC_NAV_CROUCH;
}

/* --- nav_exec.c ------------------------------------------------------ */

/* Is the body over the node's column with its feet about at its level? */
int nav_at(const bc_body *b, bc_nav_node n);

/* Standing on floor voxel z (not the server's flickering `airborne`). */
int nav_on_floor(const bc_body *b, int z);

/* Head for a point. `mode` is extra keys (BC_K_SPRINT, BC_K_SNEAK,
 * BC_K_CROUCH). With `arrive` it slows to stop there. */
void nav_law_steer(const bc_body *b, float tx, float ty, uint8_t mode, int arrive,
                   uint8_t *keys, bc_v3 *ori);

/* Emergency stop: push against the motion until still. *ori is left alone
 * when there is no motion to face. */
void nav_law_stop(const bc_body *b, uint8_t *keys, bc_v3 *ori);

/* The server's quirks about crouch (body.h): never change it in the air,
 * never stand up into a ceiling. Every key set goes through here last. */
uint8_t nav_crouch_guard(const bc_body *b, const bc_map *m, uint8_t keys);

/* A ballistic move being executed. */
typedef struct nav_shot {
	bc_nav_node from, to;
	uint8_t sprint;
	uint8_t runup;
	uint8_t max_damage;
	uint8_t diag;
} nav_shot;

/* Its progress: lives in bc_nav_follow (phase, attempts, air_keys). */
typedef struct nav_xs {
	uint8_t phase, attempts, air_keys;
	uint8_t damage;             /* out: what the landing cost */
	uint8_t ticks;              /* since the jump was pressed */
} nav_xs;

enum { NAV_XS_INIT = 0, NAV_XS_ALIGN, NAV_XS_RUN, NAV_XS_AIR, NAV_XS_BRAKE };

/* One tick of a jump / of a drop. 0: carry on with *keys, *ori. 1: done,
 * standing on `to`. Negative: -bc_nav_why. */
int nav_jump_tick(const nav_shot *s, nav_xs *xs, const bc_body *b, const bc_map *m,
                  uint8_t *keys, bc_v3 *ori);
int nav_drop_tick(const nav_shot *s, nav_xs *xs, const bc_body *b, const bc_map *m,
                  int tick, uint8_t *keys, bc_v3 *ori);

/* Would pressing jump `delay` ticks from now land the body on s->to?
 * Used by the jump controller and, to measure a move's window, by
 * nav_moves.c. */
int nav_jump_sim(const nav_shot *s, const bc_map *m, const bc_body *b0, int delay,
                 uint8_t air_keys);

/* The run-up law of a jump, exposed for the same reason. */
void nav_jump_run_law(const nav_shot *s, const bc_body *b, uint8_t *keys, bc_v3 *ori);

/* --- nav_plan.c ------------------------------------------------------ */

/* Does move `mv` fit on the map from `from` in direction `dir`: target
 * standable, swept voxels free, run-up floor there, diagonal corners
 * walkable? */
int nav_move_fits(const bc_nav_moves *t, const bc_map *m, int mv, bc_nav_node from, int dir);

/* Is there a floor at (x, y, z) with room over it to stand (1) or only to
 * crouch (2)? 0: neither. */
int nav_node_kind(const bc_map *m, int x, int y, int z);

/* The edits an edit move needs on the map as it is. Returns their number
 * (digs first, top down; then builds, support first), 0 when none are
 * left, -1 when it cannot be done (no support for a build, or the policy
 * -- if given -- refuses a voxel). */
int nav_edits(const bc_nav_moves *t, const bc_map *m, const bc_nav_policy *pol,
              bc_nav_node from, bc_nav_node to,
              bc_nav_node vox[8], uint8_t op[8], int *digs, int *builds);

#endif /* BC_NAV_I_H */
