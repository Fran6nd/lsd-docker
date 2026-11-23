/* body.h -- A player's body, moved by the server's own physics
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * WHAT. A bc_body is where a player is and how it is moving; bc_body_step
 * advances it one tick under a set of keys and a facing, exactly as the
 * server will: it calls LSd's move_player and change_crouch, the same
 * source the server is built from (lsd_core.h). Nothing in the engine
 * knows the physics' numbers. What a body can do -- how far it jumps, how
 * fast it walks, what it fits under -- is found by stepping one and
 * looking (nav.h measures its whole move table this way), so that a
 * simulated move is the move that will happen.
 *
 * A body is 20 bytes of plain data: copy it to try something, throw the
 * copy away. That is how the follower checks a jump before it leaves the
 * ground.
 *
 * THE BODY, as measured (body_test pins these):
 *  - `pos` is the EYE, the position the server reports (bl_player.pos).
 *  - Upright, the feet are 2.25 below the eye and the top of the head
 *    0.45 above it: 2.7 tall, needing 3 voxels. Crouched, the eye drops
 *    0.9: feet 1.35 below, needing 2 voxels.
 *  - It is 0.9 wide: 0.45 each side of pos on x and y. It is held up by
 *    ANY of its four bottom corners, so it stands with its centre up to
 *    0.45 past an edge.
 *  - z grows downward. Standing on a floor voxel F the feet rest a hair
 *    above z = F (bc_body_feet) and the eye near F - 2.25.
 *  - In a water column (map.h) the feet sink to 64, one below the sea
 *    bed's top, and `wade` is set once the eye is under z = 61.
 *
 * WHAT THE SERVER DOES WITH KEYS, kept here because it surprises:
 *  - JUMP is an event, not a state: the tick it is seen with the body on
 *    the ground, vertical speed becomes -0.36 and the bit is consumed. In
 *    the air it is dropped.
 *  - Walking into a step one voxel high CLIMBS it (the body is lifted one
 *    voxel, its speed halved) -- but only when neither sprinting nor
 *    crouching, and looking less than 30 degrees down. A sprinting body
 *    stops dead against a kerb.
 *  - Changing the crouch key IN THE AIR lifts the eye 0.9 each time, either
 *    way (change_crouch falls into its un-crouch branch). A client never
 *    shows this because clients run their own physics; a bot is moved by
 *    the server and would visibly hop. The follower therefore never
 *    changes crouch off the ground, and nobody above it should.
 *  - Un-crouching on the ground is not checked for head room by the server.
 *    Under a two-voxel ceiling the head ends inside a block and the body
 *    cannot move again. Ask bc_body_can_stand first.
 *
 * TIME. dt is an argument, as everywhere; the server ticks at
 * BC_BODY_HZ and every measurement in nav is in those ticks.
 */
#ifndef BC_BODY_H
#define BC_BODY_H

#include <stdint.h>

#include "map.h"

#define BC_BODY_HZ 60
#define BC_BODY_DT (1.0f / 60.0f)

typedef struct bc_v3 { float x, y, z; } bc_v3;

/* The protocol's keys; the same bits as bl_keys. */
enum bc_keys {
	BC_K_FORWARD = 1, BC_K_BACK = 2, BC_K_LEFT = 4, BC_K_RIGHT = 8,
	BC_K_JUMP = 16, BC_K_CROUCH = 32, BC_K_SNEAK = 64, BC_K_SPRINT = 128
};

typedef struct bc_body {
	bc_v3 pos;              /* the eye */
	bc_v3 vel;              /* voxels per tick-second / 32, as the server keeps it */
	uint8_t keys;           /* held as of the last step; CROUCH here is the
	                           body's crouch state */
	uint8_t airborne;
	uint8_t wade;
	uint8_t scoped;         /* gun out with its sights up: half pace */
} bc_body;

/* A body at rest with its eye at pos, upright, no keys. */
void bc_body_init(bc_body *b, bc_v3 pos);

/* A body standing at rest at (x, y) on the floor voxel floor_z, upright
 * (or crouched), exactly where the physics lets it settle. */
void bc_body_place(bc_body *b, const bc_map *m, float x, float y, int floor_z, int crouched);

/* One tick. `keys` are what is held this tick (a fresh InputData), `ori`
 * where the head points (need not be unit; only its horizontal direction
 * and whether it looks steeply down matter). Returns the fall damage of a
 * hard landing this tick, 0 for a landing that only slows, -1 otherwise. */
int32_t bc_body_step(bc_body *b, const bc_map *m, uint8_t keys, bc_v3 ori, float dt);

/* Where the soles are (z, growing downward). */
static inline float bc_body_feet(const bc_body *b)
{
	return b->pos.z + ((b->keys & BC_K_CROUCH) ? 1.35f : 2.25f);
}

/* Could this (crouched, grounded) body stand up without its head entering
 * a block? Always 1 for an upright body. */
int bc_body_can_stand(const bc_body *b, const bc_map *m);

/* Horizontal speed in voxels per second. */
float bc_body_speed(const bc_body *b);

#endif /* BC_BODY_H */
