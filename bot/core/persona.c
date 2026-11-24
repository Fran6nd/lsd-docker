/* persona.c -- rolling a bot's character
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE. */
#include "persona.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* THE ARCHETYPE TABLE -- the place to tune the bots' characters.
 *
 * Per archetype, per trait: the CENTRE the trait is drawn around and the
 * SPREAD (standard deviation of the normal draw). Columns are the traits
 * in enum order from BC_T_AGGRESSION (BC_T_NONE is not rolled: it is 1).
 * Draws are clamped to [TRAIT_MIN, TRAIT_MAX]. A centre of 1 is "no
 * opinion"; 2 means the trait counts about twice as much in a `pick`.
 * tests/persona_test.c repeats the centres to pin them: change both.
 *
 *            aggr  caut  obj   team  build mark  flank stlth curio greed */
static const float centre[BC_A_COUNT][BC_T_COUNT - 1] = {
	/* soldier */ { 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f },
	/* camper  */ { 0.5f, 1.8f, 0.8f, 0.9f, 1.0f, 1.8f, 0.5f, 1.2f, 0.8f, 1.0f },
	/* pusher  */ { 1.9f, 0.6f, 1.6f, 1.0f, 0.8f, 0.8f, 0.8f, 0.5f, 0.9f, 1.3f },
	/* flanker */ { 1.2f, 0.9f, 1.0f, 0.7f, 0.8f, 0.9f, 1.9f, 1.8f, 1.1f, 1.0f },
	/* support */ { 0.8f, 1.1f, 1.1f, 1.9f, 1.6f, 0.9f, 0.7f, 0.9f, 0.9f, 1.0f },
	/* sapper  */ { 0.8f, 1.0f, 1.0f, 1.0f, 2.5f, 0.8f, 0.9f, 1.0f, 1.0f, 1.2f },
	/* scout   */ { 0.8f, 0.9f, 0.9f, 0.8f, 0.7f, 0.9f, 1.2f, 1.7f, 1.9f, 0.9f },
};
/* (The spreads were 0.15 for a soldier, 0.20, and 0.25 for an archetype's
 * own traits. With those, the one high trait decided: 98% of campers with
 * a rifle took a free perch, 95% of pushers went straight in, 96% of
 * supports followed. Now 0.25, 0.30 and 0.40: an archetype is still what
 * it is on the whole, and one in five or so of each does something else.) */
static const float spread[BC_A_COUNT][BC_T_COUNT - 1] = {
	/* soldier */ { 0.25f, 0.25f, 0.25f, 0.25f, 0.25f, 0.25f, 0.25f, 0.25f, 0.25f, 0.25f },
	/* camper  */ { 0.30f, 0.40f, 0.30f, 0.30f, 0.30f, 0.40f, 0.30f, 0.30f, 0.30f, 0.30f },
	/* pusher  */ { 0.40f, 0.30f, 0.40f, 0.30f, 0.30f, 0.30f, 0.30f, 0.30f, 0.30f, 0.40f },
	/* flanker */ { 0.30f, 0.30f, 0.30f, 0.30f, 0.30f, 0.30f, 0.40f, 0.40f, 0.30f, 0.30f },
	/* support */ { 0.30f, 0.30f, 0.30f, 0.40f, 0.40f, 0.30f, 0.30f, 0.30f, 0.30f, 0.30f },
	/* sapper  */ { 0.30f, 0.30f, 0.30f, 0.30f, 0.40f, 0.30f, 0.30f, 0.30f, 0.30f, 0.30f },
	/* scout   */ { 0.30f, 0.30f, 0.30f, 0.30f, 0.30f, 0.30f, 0.30f, 0.40f, 0.40f, 0.30f },
};

#define TRAIT_MIN 0.2f
#define TRAIT_MAX 3.0f

static const char *const trait_names[BC_T_COUNT] = {
	"none", "aggression", "caution", "objective", "teamwork", "builder",
	"marksman", "flank", "stealth", "curiosity", "greed",
};
static const char *const archetype_names[BC_A_COUNT] = {
	"soldier", "camper", "pusher", "flanker", "support", "sapper", "scout",
};

/* One line each, for whoever writes a tree or reads a bot's character:
 * VOCAB.md and the editor's schema are written from these. */
static const char *const trait_docs[BC_T_COUNT] = {
	"always 1: an option nobody's character moves",
	"take the fight, close the distance",
	"cover, retreat when hurt, keep range",
	"the intel, the point, the tower -- the game",
	"answer pings, escort, stay with the others",
	"dig and build rather than walk round",
	"fight from far, hold an angle",
	"go round rather than through",
	"sneak, lamp out, do not be heard",
	"go and look: noises, last-seen places",
	"use what it holds: items, grenades",
};
static const char *const archetype_docs[BC_A_COUNT] = {
	"the middle of everything",
	"careful and a marksman: holds an angle, keeps its distance, seldom goes in",
	"bold and keen on the game: straight at the enemy and at the objective",
	"goes round, and quietly: comes at the enemy from where he is not looking",
	"with the others: answers their calls, escorts, digs and builds for them",
	"digs and builds rather than walk round",
	"curious and quiet: goes to look at what it heard, alone if need be",
};

static int pick_archetype(bc_rng *rng, const float *weights)
{
	double sum = 0, x;
	int i, last = -1;
	if (weights) {
		for (i = 0; i < BC_A_COUNT; i++)
			if (weights[i] > 0) { sum += weights[i]; last = i; }
	}
	if (sum <= 0) return (int)bc_rng_below(rng, BC_A_COUNT);   /* NULL, or nothing allowed: even */
	x = (double)bc_rng_float(rng) * sum;
	for (i = 0; i < BC_A_COUNT; i++) {
		if (weights[i] <= 0) continue;
		if (x < weights[i]) return i;
		x -= weights[i];
	}
	return last;
}

void bc_persona_roll(bc_persona *p, bc_rng *rng, const float *weights, int level)
{
	int a = pick_archetype(rng, weights), t;
	p->archetype = (uint8_t)a;
	p->level = (uint8_t)(level < 1 ? 1 : level > 10 ? 10 : level);
	p->trait[BC_T_NONE] = 1.0f;
	for (t = 1; t < BC_T_COUNT; t++) {
		float v = centre[a][t - 1] + spread[a][t - 1] * bc_rng_normal(rng);
		p->trait[t] = v < TRAIT_MIN ? TRAIT_MIN : v > TRAIT_MAX ? TRAIT_MAX : v;
	}
}

static int by_name(const char *const *names, int n, const char *name)
{
	int i;
	if (!name) return -1;
	for (i = 0; i < n; i++)
		if (strcmp(names[i], name) == 0) return i;
	return -1;
}

int bc_trait_by_name(const char *name) { return by_name(trait_names, BC_T_COUNT, name); }
const char *bc_trait_name(int t) { return t >= 0 && t < BC_T_COUNT ? trait_names[t] : NULL; }
const char *bc_trait_doc(int t) { return t >= 0 && t < BC_T_COUNT ? trait_docs[t] : NULL; }
int bc_archetype_by_name(const char *name) { return by_name(archetype_names, BC_A_COUNT, name); }
const char *bc_archetype_doc(int a) { return a >= 0 && a < BC_A_COUNT ? archetype_docs[a] : NULL; }

int bc_archetype_trait(int a, int t, float *centre_out, float *spread_out)
{
	if (a < 0 || a >= BC_A_COUNT || t < 0 || t >= BC_T_COUNT) return 0;
	if (centre_out) *centre_out = t ? centre[a][t - 1] : 1.0f;
	if (spread_out) *spread_out = t ? spread[a][t - 1] : 0.0f;
	return 1;
}

void bc_trait_range(float *min_out, float *max_out)
{
	if (min_out) *min_out = TRAIT_MIN;
	if (max_out) *max_out = TRAIT_MAX;
}
const char *bc_archetype_name(int a) { return a >= 0 && a < BC_A_COUNT ? archetype_names[a] : NULL; }

int bc_archetype_weights(const char *text, float *weights)
{
	float w[BC_A_COUNT];
	const char *q;
	int i;
	if (!weights) return 0;
	if (!text) text = "";
	q = text;
	while (*q == ' ' || *q == '\t') q++;
	if (!*q) {
		for (i = 0; i < BC_A_COUNT; i++) weights[i] = 1.0f;
		return 1;
	}
	for (i = 0; i < BC_A_COUNT; i++) w[i] = 0.0f;
	for (;;) {
		char name[32];
		size_t n = 0;
		int a;
		float v = 1.0f;
		while (*q == ' ' || *q == '\t') q++;
		while (*q && *q != ':' && *q != ',' && *q != ' ' && *q != '\t') {
			if (n + 1 >= sizeof name) return 0;
			name[n++] = *q++;
		}
		name[n] = 0;
		a = bc_archetype_by_name(name);
		if (a < 0) return 0;
		while (*q == ' ' || *q == '\t') q++;
		if (*q == ':') {
			char *end;
			double d;
			q++;
			d = strtod(q, &end);
			if (end == q || !isfinite(d) || d < 0) return 0;
			v = (float)d;
			q = end;
			while (*q == ' ' || *q == '\t') q++;
		}
		w[a] = v;
		if (*q == ',') { q++; continue; }
		if (*q == 0) break;
		return 0;
	}
	for (i = 0; i < BC_A_COUNT; i++) weights[i] = w[i];
	return 1;
}
