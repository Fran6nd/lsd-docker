/* footing.h -- IS THIS STEP SAFE: the one rule for a body moved without a
 * planned route
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * A route's steps were planned against the map (nav.h), and the follower
 * that walks them reads the body every tick. Everything else that moves a
 * body -- a step aside out of a team-mate or across his line of fire, a
 * walk on toward the goal while the route is searched, the stop, the
 * net's step back and its sidestep, a tree's strafe or its run from a
 * grenade -- moves onto a floor nobody planned. One test answers for all
 * of them, for the keys as they will be pressed and the facing as it will
 * be: the body that presses them a third of a second and lets go keeps its
 * feet (they come down no more than BC_FOOTING_DROP), it does not walk
 * into water it is not already in, and a step or two that way there is a
 * floor near the feet or a wall to walk into (the simulation misses a body
 * already half over an edge). A body in the air steers nothing: always
 * safe.
 *
 * The engine holds the keys it presses of its own to it (engine.c act,
 * FOOTING); a skill that walks a body asks it of the keys it would press.
 * Asked for by babel's carriers, seen to fall 26 to 30 voxels off the top
 * of their own stair with an enemy shooting (WORK.md item 25);
 * tests/footing_test.c holds the rule, and a stair one voxel wide walked
 * under fire -- that fall itself it has not made happen.
 */
#ifndef BC_FOOTING_H
#define BC_FOOTING_H

#include <stdint.h>

#include "body.h"
#include "map.h"

/* How far the feet may come down and the step still be a step (a stair's
 * step down is one voxel; a drop is more). */
#define BC_FOOTING_DROP 1.3f

/* Safe to press `keys` (bl_keys / bc_keys: movement, JUMP, SPRINT, CROUCH,
 * SNEAK) for the body `b`, facing `ori`? */
int bc_footing_keys(const bc_map *m, const bc_body *b, uint8_t keys, bc_v3 ori);

/* The world direction (a unit, in *mx, *my) the movement keys take a body
 * facing `ori`; 0 when they take it nowhere. */
int bc_footing_dir(uint8_t keys, bc_v3 ori, float *mx, float *my);

#endif
