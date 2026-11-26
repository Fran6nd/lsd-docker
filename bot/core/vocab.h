/* vocab.h -- The words a behaviour tree may use
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * THIS IS THE ENGINE'S WHOLE INTERFACE TO BEHAVIOUR. A tree (bt.h) is
 * made of these names and nothing else: a gamemode's author reads this
 * file, not the engine. So the words are few, named for what they do and
 * never for who uses them, and each has one line here. A mode that needs
 * a new word adds it HERE, neutral, with a test -- never an `if (mode)`
 * in the engine.
 *
 * Everything a condition or a score says about an ENEMY is what the bot
 * itself perceives (senses.h): in sight, remembered, heard, or told by
 * its team -- never what the server knows.
 *
 * THE WORDS THEMSELVES ARE NOT LISTED HERE. They are one table in
 * vocab.c -- each word with its arguments as data and its one line --
 * and what a person reads is written from that table, never by hand:
 *
 *     bot/VOCAB.md            every condition, score, action, value,
 *                             trait, archetype and place (`make -C bot doc`;
 *                             `make -C bot test` fails when it is stale)
 *     bttree --words          the same, a word a line
 *     bttree --schema         the same as JSON, for an editor
 *
 * A word added to the table is in all three. The VALUES -- the numbers a
 * tree compares (`if enemy_distance < 5`) -- are a table beside it, and
 * a condition or a score that asks the same as a comparison of one IS
 * that comparison (its `short_for`): one reading of each thing sensed.
 * The TRAITS and ARCHETYPES are persona.c's tables, the PLACES
 * skill_misc.c's (below: bc_place_at).
 *
 * TWO TREES A BOT. The tree named by the setting `tree` (say "tdm") is
 * the bot's MAIN tree: what it is doing. If the same text also has a
 * tree called "<name>_also" ("tdm_also"), it is ticked just before the
 * main one at every decision: that is where the things done BESIDE go --
 * the lamp, a ping, an item -- because bt.h's seq and select remember
 * where they were and would not come back to them while a fight is
 * RUNNING. Keep "_also" trees to actions that end at once.
 *
 * THE ITEMS TREE. `tree items` is always there to be included: the
 * engine writes it from what each inventory item brought with it
 * (engine.c). It fails at once for a bot with nothing to use.
 * THE EXTRAS TREE, `tree extras`, likewise: what the server's scripts
 * add to every bot (extra.<name>.tree), each part ticked at every
 * decision.
 *
 * BEING SHOT AT (`under_fire`) is being hurt by somebody, a round passing
 * within 2.5 voxels, or a team-mate killed within 12 (senses.h). COVER is
 * a place a threat cannot see a body standing in -- or only crouched
 * (skill_cover.c). A PERCH is a high place with a long view toward the
 * enemy and a way up, one bot at a time (skill_tactics.c). A LEADER is a
 * team member the engine drew by lot, bot or person, whom other bots may
 * follow (skill_squad.c). THE INTEL is one of the two objects the world
 * shows that a team may carry off (skill_objective.c has the server's
 * rules for them). None of these names a gamemode.
 *
 * NIGHT AND LAMPS ARE NOT THE ENGINE'S. The words is_night, lamp_on,
 * has_night_vision, night, night_vision, hit_in_dark and `do lamp` are
 * here for the fragment a server's night script sends as an extra; the
 * trees shipped in trees/ use none of them, and a bot never lights a
 * lamp unless a tree tells it to.
 *
 */
#ifndef BC_VOCAB_H
#define BC_VOCAB_H

#include <stddef.h>

#include "bt.h"

/* Register every word with its arguments (bt.h, bt_vocab_args: the
 * compiler then checks each use) -- a word that is short for a
 * comparison as that (bt_vocab_short) --, every value, the list of
 * places, and persona.h's traits, into `v`. 0 if one did not fit. */
int bc_vocab_register(bt_vocab *v);

/* The words as text, a word a line (the values are not among them):
 *   "cond health_below <hp> -- its health is under that (of 100) (short for `health < <hp>`)"
 * the usage written from the word's arguments (bc_vocab_usage).
 * Returns the length it has in full; writes at most out_size - 1. */
size_t bc_vocab_dump(char *out, size_t out_size);

/* How many words there are. */
int bc_vocab_count(void);

/* Word i, 0 <= i < bc_vocab_count(), as data. */
typedef struct bc_word {
	int kind;                   /* BT_WORD_COND, BT_WORD_SCORE, BT_WORD_ACTION */
	const char *name;
	const char *doc;            /* its one line */
	int n_args;
	const bt_arg_spec *args;    /* bt.h: name, type, required, default, range */
	const char *short_for;      /* the comparison it is short for, as bt.h's
	                               bt_vocab_short takes it ("health < $1"),
	                               or NULL */
} bc_word;
int bc_vocab_word(int i, bc_word *out);

/* What word i is short for, as a person reads it: "health < <hp>", the
 * word's own arguments in place of $1..; "" (and 0) for a word that is
 * not. Returns the length in full, as snprintf does. */
size_t bc_vocab_short_for(int i, char *out, size_t out_size);

/* THE VALUES a comparison compares, 0 <= i < bc_value_count(). */
typedef struct bc_value {
	const char *name;
	const char *doc;            /* its one line: what it is, when unknown */
	int n_args;
	const bt_arg_spec *args;    /* its own arguments ("distance <place>") */
	const bt_arg_spec *number;  /* what it is compared with: `name` its unit
	                               ("voxels"), has_min/min, has_max/max the
	                               range it keeps within */
	bt_value_fn fn;
} bc_value;
int bc_value_count(void);
int bc_value_at(int i, bc_value *out);
/* its arguments as a person writes them, as bc_vocab_usage */
size_t bc_value_usage(int i, char *out, size_t out_size);

/* Its arguments as a person writes them: "<place> [radius]" -- <x> must
 * be given, [x] may be, a|b|c is one of those words, ... any number
 * more. Returns the length in full, as snprintf does. */
size_t bc_vocab_usage(int i, char *out, size_t out_size);

/* THE PLACES an argument of the list "place" may name (skill_misc.c:
 * the table bc_place_of reads). `alias`: another name it answers to, or
 * NULL. Any of the three may be NULL when not wanted. 0 past the end. */
int bc_place_count(void);
int bc_place_at(int i, const char **name, const char **alias, const char **doc);

#endif
