/* lsd_core.h -- LSd's own world code, compiled into the engine
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * WHAT. The server's physics and voxel walks live in one file,
 * lsd/src/demoncore.c: move_player, the crouch change, the block line's
 * DDA, the ray cast, the grenade's flight. The engine compiles that file
 * as it stands, against this engine's map instead of the server's, and
 * lsd_core.c wraps it. Not a port, not a copy: the same source text, so the question
 * "would the server let a body through there" is answered by the code that
 * will answer it.
 *
 * WHY THIS WAY. aosbot carried a C++ transcription of this physics and its
 * executor steered by approximations of it on top; where the two differed
 * from the server a bot stood against a ledge it believed it could climb.
 * Here nothing above this file knows how a body moves -- nav measures its
 * moves by calling it (nav.h).
 *
 * HOW IT IS CUT OUT. demoncore.c wants demoncore.h, which wants state.h
 * (ENet, the Lua state, 256 players). lsd_state.h supplies, in state.h's
 * place and under its include guard, the few things demoncore.c really
 * reads: the vector typedefs, `Map` as a `bc_map *`, libpvx2's four map
 * accessors as inline functions over bc_map, and a private `struct Player`
 * with only the fields the physics touches. demoncore.h and protocol.h
 * are the server's real ones. If LSd's physics starts reading a new field
 * of struct Player, this stops compiling -- which is the drift alarm
 * wanted -- and body_test pins the trajectories besides.
 *
 * This header is the engine-side view: plain types, no LSd names. body.c
 * and map.c are its only users; everything else goes through body.h and
 * map.h.
 *
 * HOW IT IS BUILT (bot/Makefile). demoncore.c is upstream's file and is
 * compiled as upstream compiles it: in a unit of its own, under
 * lsd/Makefile's warnings, not the engine's -Werror -pedantic (gcc 13
 * warns on one of its casts; that is upstream's to weigh, and a warning in
 * upstream's code must not stop the engine building on one compiler and
 * not another). lsd_state.h is given to it with -include.
 *
 * Both it and the core are built with -ffp-contract=off: without it a
 * compiler may fuse a multiply and an add, and the same inputs would give
 * trajectories that differ in the last bit from one machine to the next.
 * The server's own build is whatever its compiler does; the follower
 * re-reads the true state every tick, so a last-bit difference is noise,
 * but the engine's tests must be exact.
 */
#ifndef BC_LSD_CORE_H
#define BC_LSD_CORE_H

#include "map.h"

/* The part of a player the server's physics reads and writes. */
typedef struct bc_lsd_player {
	float pos[3], ori[3], vel[3];
	int wade, airborne;
	uint8_t inputs;         /* the protocol's key bits (= bl_keys) */
	uint8_t scoped;         /* secondary held with the gun out: half speed */
} bc_lsd_player;

/* move_player: one tick of dt seconds. Returns the fall damage of a
 * landing this tick, -1 when there was no hard landing. Consumes the jump
 * bit of p->inputs, as the server does. */
int32_t bc_lsd_move_player(bc_lsd_player *p, float dt, const bc_map *m);

/* change_crouch: call only when the crouch key's state really changes. */
void bc_lsd_change_crouch(bc_lsd_player *p, int crouching, const bc_map *m);

/* block_line: every voxel on the line that was air becomes solid. Returns
 * how many did. Both ends must be inside the map. */
int bc_lsd_block_line(bc_map *m, int x1, int y1, int z1, int x2, int y2, int z2,
                      bc_map_change *chg);

/* cast_ray: is there a solid voxel between two points (both included)?
 * If `hit` is not NULL it gets the voxel that stopped the ray, or the last
 * voxel visited. The server's line of sight for a grenade's blast. */
int bc_lsd_cast_ray(const bc_map *m, const float from[3], const float to[3], int hit[3]);

/* clip_phys: is the point inside something a body cannot enter? */
int bc_lsd_clip(const bc_map *m, float x, float y, float z);

#endif /* BC_LSD_CORE_H */
