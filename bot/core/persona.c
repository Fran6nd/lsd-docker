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
static const float spread[BC_A_COUNT][BC_T_COUNT - 1] = {
	/* soldier */ { 0.15f, 0.15f, 0.15f, 0.15f, 0.15f, 0.15f, 0.15f, 0.15f, 0.15f, 0.15f },
	/* camper  */ { 0.20f, 0.25f, 0.20f, 0.20f, 0.20f, 0.25f, 0.20f, 0.20f, 0.20f, 0.20f },
	/* pusher  */ { 0.25f, 0.20f, 0.25f, 0.20f, 0.20f, 0.20f, 0.20f, 0.20f, 0.20f, 0.25f },
	/* flanker */ { 0.20f, 0.20f, 0.20f, 0.20f, 0.20f, 0.20f, 0.25f, 0.25f, 0.20f, 0.20f },
	/* support */ { 0.20f, 0.20f, 0.20f, 0.25f, 0.25f, 0.20f, 0.20f, 0.20f, 0.20f, 0.20f },
	/* sapper  */ { 0.20f, 0.20f, 0.20f, 0.20f, 0.25f, 0.20f, 0.20f, 0.20f, 0.20f, 0.20f },
	/* scout   */ { 0.20f, 0.20f, 0.20f, 0.20f, 0.20f, 0.20f, 0.20f, 0.25f, 0.25f, 0.20f },
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
int bc_archetype_by_name(const char *name) { return by_name(archetype_names, BC_A_COUNT, name); }
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
