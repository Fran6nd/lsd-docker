/* blueprint.h -- Structures to build, as data, shared out a part at a time
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * A BLUEPRINT is a structure a team is to build: an ordered list of
 * voxels, what rests on another after it (a stair from the ground up, a
 * pillar from its foot). A server script says it through the bridge --
 * the setting blueprint.<name>=x y z; x y z; ... (team-scoped as places
 * are: blueprint.stair@1) -- or a leader's order makes it (skill_build.c).
 * A bot builds one with `build_part <name>`: it takes a PART -- one voxel
 * not yet solid, that can be put now, nobody else's -- builds it, and
 * takes the next. Whose a part is, is the one claim the engine has
 * (bc_claim, brain.h: a named duty for a few; a part is one for one bot),
 * so builders spread over the structure instead of chasing its next step
 * together. A part nobody could make (no stand sees it, the server
 * refused it) is left alone for a while, by everybody.
 *
 * MEMORY. The list is allocated when the setting comes, freed when it is
 * replaced or forgotten: never on a tick. */
#ifndef BC_BLUEPRINT_H
#define BC_BLUEPRINT_H

#include <stddef.h>
#include <stdint.h>

#include "kv6.h"

enum { BC_BLUEPRINTS_MAX = 16, BC_BLUEPRINT_NAME = 24, BC_BLUEPRINT_CELLS_MAX = 8192, BC_STRUCTURES_MAX = 16 };
#define BC_BP_RGB 0x01000000u    /* a cell's rgb says a colour */

typedef struct bc_bp_cell {
	int16_t x, y, z;
	uint8_t climb_failed;       /* made as a floor, the way there not found: put it next time */
	uint8_t pad_;
	uint32_t unseen;            /* no floor saw it on the map at revision unseen - 1 (0: not looked) */
	uint32_t rgb;               /* the colour it is built in, BC_BP_RGB | 0xRRGGBB; 0: the builder's own */
	double bad_until;           /* nobody could make it: not before this */
	double noway_until;         /* these found no way to it (a way is from where one is: */
	uint64_t noway[4];          /* the others still try), bit pid, till then */
} bc_bp_cell;

typedef struct bc_blueprint {
	char name[BC_BLUEPRINT_NAME];   /* as the setting named it, "@1"/"@2" kept */
	int n;
	uint32_t hash;              /* of its text: the same again changes nothing */
	bc_bp_cell *cells;
} bc_blueprint;

typedef struct bc_blueprints {
	bc_blueprint bp[BC_BLUEPRINTS_MAX];
	uint32_t version;           /* goes up when one is set, replaced or forgotten */
} bc_blueprints;

/* "x y z; x y z; ..." for `name`; an empty text forgets it. 1, or 0 with
 * the fault in err (the blueprint as it was). */
int bc_blueprint_set(bc_blueprints *t, const char *name, const char *text, char *err, size_t err_size);
/* the same from cells (x, y, z, rgb; the rest is the blueprint's own), as
 * a leader's order makes one; the same cells again change nothing */
int bc_blueprint_put(bc_blueprints *t, const char *name, const bc_bp_cell *cells, int n, char *err, size_t err_size);
/* by its exact name (team scope is the caller's: name@team, then name) */
bc_blueprint *bc_blueprint_get(bc_blueprints *t, const char *name);
void bc_blueprints_free(bc_blueprints *t);

/* STRUCTURES (prefabs): voxel models a leader may order built, by name */
typedef struct bc_structures {
	char name[BC_STRUCTURES_MAX][BC_BLUEPRINT_NAME];
	bc_kv6 model[BC_STRUCTURES_MAX];
} bc_structures;

/* the model's voxels set on the map: its pivot (the ground under the
 * middle of its footprint) on the floor at (x, y, ground_z) -- ground_z
 * the solid voxel stood on --, its front (+y in the model) turned to face
 * `quarter` quarter-turns from +y (0: +y, 1: -x, 2: -y, 3: +x: the way the
 * orderer looks), in the model's order (its bottom layer first: what
 * rests on what); voxels off the map left out. How many, at most max. */
int bc_structure_cells(const bc_kv6 *m, int x, int y, int ground_z, int quarter, bc_bp_cell *out, int max);
const bc_kv6 *bc_structure_get(const bc_structures *s, const char *name);
void bc_structures_free(bc_structures *s);

#endif
