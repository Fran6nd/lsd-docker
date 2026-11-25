/* persona.h -- What kind of player a bot is
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * Ten bots thinking with one tree should not be ten of the same bot. A
 * persona is a handful of TRAITS, each a weight around 1, rolled once
 * when the bot is made, from its own seed. The behaviour tree's
 * weighted choices (bt.h, `pick`) multiply every option's score by the
 * trait the option names, so the same situation is weighed differently
 * by each bot: one pushes where another holds.
 *
 * The roll is not flat. A bot is first given an ARCHETYPE -- camper,
 * pusher, flanker, support... -- drawn by the weights the server set
 * (`archetypes=camper:2,pusher:3,...`, all 1 when unset), and its
 * traits are then drawn around that archetype's centres with its
 * spread: a pusher is aggressive, but no two pushers alike.
 *
 * LEVEL is apart from character: 1-10, how good the bot is (reaction,
 * aim error, turn rate: aim.h's table), not what it prefers.
 */
#ifndef BC_PERSONA_H
#define BC_PERSONA_H

#include <stddef.h>
#include <stdint.h>
#include "rng.h"

enum bc_trait {
	BC_T_NONE = 0,         /* always 1: an option nobody's character moves */
	BC_T_AGGRESSION,       /* take the fight, close the distance */
	BC_T_CAUTION,          /* cover, retreat when hurt, keep range */
	BC_T_OBJECTIVE,        /* the intel, the point, the tower -- the game */
	BC_T_TEAMWORK,         /* answer pings, escort, stay with the others */
	BC_T_BUILDER,          /* dig and build rather than walk round */
	BC_T_MARKSMAN,         /* fight from far, hold an angle */
	BC_T_FLANK,            /* go round rather than through */
	BC_T_STEALTH,          /* sneak, lamp out, do not be heard */
	BC_T_CURIOSITY,        /* go and look: noises, last-seen places */
	BC_T_GREED,            /* use what it holds: items, grenades */
	BC_T_COUNT
};

enum bc_archetype {
	BC_A_SOLDIER = 0,      /* the middle of everything */
	BC_A_CAMPER,
	BC_A_PUSHER,
	BC_A_FLANKER,
	BC_A_SUPPORT,
	BC_A_SAPPER,
	BC_A_SCOUT,
	BC_A_COUNT
};

typedef struct bc_persona {
	float trait[BC_T_COUNT];   /* trait[BC_T_NONE] is 1 */
	uint8_t archetype;         /* bc_archetype */
	uint8_t level;             /* 1-10 */
} bc_persona;

/* Roll one. `weights` is BC_A_COUNT chances, or NULL for even ones.
 * Traits come out within [0.2, 3]. */
void bc_persona_roll(bc_persona *p, bc_rng *rng, const float *weights, int level);

/* "aggression" <-> BC_T_AGGRESSION, "camper" <-> BC_A_CAMPER, as trees
 * and settings name them; -1 for a name there is none of. */
int bc_trait_by_name(const char *name);
const char *bc_trait_name(int trait);
int bc_archetype_by_name(const char *name);
const char *bc_archetype_name(int archetype);

/* Their one line each, for a person: "take the fight, close the
 * distance". NULL for no such trait or archetype. */
const char *bc_trait_doc(int trait);
const char *bc_archetype_doc(int archetype);

/* What an archetype draws a trait around, and how widely (the standard
 * deviation of the draw): 1 and 0 for BC_T_NONE. 0 for no such pair. */
int bc_archetype_trait(int archetype, int trait, float *centre, float *spread);
/* the bounds every trait is kept within */
void bc_trait_range(float *min, float *max);

/* "camper:2,pusher:3" into BC_A_COUNT weights (those unnamed 0; all 1
 * when the text is empty). 0 on a name it does not know. */
int bc_archetype_weights(const char *text, float *weights);

/* THE KINDS AS DATA (trees/archetypes.txt). The table above is the
 * built-in one; a bot engine holds a table of its own -- the built-in
 * kinds, with what a text says over them: a kind of the same name
 * replaced, a new one added (an operator's own kind, then usable in the
 * `archetypes` weights). The text, a line a kind:
 *
 *     <name> <trait>=<centre>/<spread> ... [-- <its one line>]
 *
 * a trait not named drawn around 1 with the soldier's spread; `#` to the
 * end of a line is a comment. */
enum { BC_KINDS_MAX = 32, BC_KIND_NAME = 16, BC_KIND_DOC = 160 };

typedef struct bc_kind {
	char name[BC_KIND_NAME];
	char doc[BC_KIND_DOC];
	float centre[BC_T_COUNT], spread[BC_T_COUNT];   /* [BC_T_NONE]: 1 and 0 */
} bc_kind;

typedef struct bc_kinds {
	int n;
	bc_kind k[BC_KINDS_MAX];
} bc_kinds;

/* The built-in kinds, as the table above has them. */
void bc_kinds_builtin(bc_kinds *t);
/* `text` over what `t` holds. 1, or 0 with the first fault said in `err`
 * (and `t` as it was). */
int bc_kinds_parse(bc_kinds *t, const char *text, char *err, size_t errn);
/* The table as a text that bc_kinds_parse reads back as it is. */
size_t bc_kinds_write(const bc_kinds *t, char *out, size_t n);
int bc_kinds_by_name(const bc_kinds *t, const char *name);
/* "camper:2,pusher:3" into t->n weights (BC_KINDS_MAX room), as
 * bc_archetype_weights */
int bc_kinds_weights(const bc_kinds *t, const char *text, float *weights);
/* bc_persona_roll from a table: `weights` t->n chances, or NULL */
void bc_kinds_roll(const bc_kinds *t, bc_persona *p, bc_rng *rng, const float *weights, int level);

#endif
