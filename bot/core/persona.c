/* persona.c -- rolling a bot's character
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE. */
#include "persona.h"
#include <math.h>
#include <stdio.h>
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

static int pick_archetype(bc_rng *rng, const float *weights, int n)
{
	double sum = 0, x;
	int i, last = -1;
	if (weights) {
		for (i = 0; i < n; i++)
			if (weights[i] > 0) { sum += weights[i]; last = i; }
	}
	if (sum <= 0) return (int)bc_rng_below(rng, (uint32_t)n);   /* NULL, or nothing allowed: even */
	x = (double)bc_rng_float(rng) * sum;
	for (i = 0; i < n; i++) {
		if (weights[i] <= 0) continue;
		if (x < weights[i]) return i;
		x -= weights[i];
	}
	return last;
}

/* the traits drawn round a kind's centres (c, sp: [BC_T_COUNT - 1], from
 * BC_T_AGGRESSION) -- the one draw, for the built-in table and for any */
static void draw(bc_persona *p, bc_rng *rng, int a, const float *c, const float *sp, int level)
{
	int t;
	p->archetype = (uint8_t)a;
	p->level = (uint8_t)(level < 1 ? 1 : level > 10 ? 10 : level);
	p->trait[BC_T_NONE] = 1.0f;
	for (t = 1; t < BC_T_COUNT; t++) {
		float v = c[t - 1] + sp[t - 1] * bc_rng_normal(rng);
		p->trait[t] = v < TRAIT_MIN ? TRAIT_MIN : v > TRAIT_MAX ? TRAIT_MAX : v;
	}
}

void bc_persona_roll(bc_persona *p, bc_rng *rng, const float *weights, int level)
{
	int a = pick_archetype(rng, weights, BC_A_COUNT);
	draw(p, rng, a, centre[a], spread[a], level);
}

void bc_kinds_roll(const bc_kinds *t, bc_persona *p, bc_rng *rng, const float *weights, int level)
{
	int a = pick_archetype(rng, weights, t->n);
	draw(p, rng, a, t->k[a].centre + 1, t->k[a].spread + 1, level);
}

/* ---- the kinds as data ---------------------------------------------------- */

void bc_kinds_builtin(bc_kinds *t)
{
	int a, i;

	memset(t, 0, sizeof *t);
	for (a = 0; a < BC_A_COUNT; a++) {
		bc_kind *k = &t->k[a];

		strcpy(k->name, archetype_names[a]);
		snprintf(k->doc, sizeof k->doc, "%s", archetype_docs[a]);
		k->centre[BC_T_NONE] = 1.0f;
		for (i = 1; i < BC_T_COUNT; i++) {
			k->centre[i] = centre[a][i - 1];
			k->spread[i] = spread[a][i - 1];
		}
	}
	t->n = BC_A_COUNT;
}

int bc_kinds_by_name(const bc_kinds *t, const char *name)
{
	int i;

	for (i = 0; name && i < t->n; i++)
		if (!strcmp(t->k[i].name, name)) return i;
	return -1;
}

/* the next word of *at (spaces and tabs between), cut out in place */
static char *word(char **at)
{
	char *w = *at;

	while (*w == ' ' || *w == '\t' || *w == '\r') w++;
	if (!*w) return NULL;
	*at = w;
	while (**at && **at != ' ' && **at != '\t' && **at != '\r') (*at)++;
	if (**at) *(*at)++ = 0;
	return w;
}

static void fail(char *err, size_t errn, int line, const char *what, const char *at)
{
	if (err && errn) snprintf(err, errn, "line %d: %s%s%.40s%s", line, what, at ? " (\"" : "", at ? at : "", at ? "\")" : "");
}

int bc_kinds_parse(bc_kinds *t, const char *text, char *err, size_t errn)
{
	bc_kinds out = *t;
	const char *q = text ? text : "";
	int line = 0;

	while (*q) {
		char buf[1024], *c, *doc, *w, *save;
		size_t len = strcspn(q, "\n");
		bc_kind k;
		int a, i;

		line++;
		if (len >= sizeof buf) { fail(err, errn, line, "a line too long", NULL); return 0; }
		memcpy(buf, q, len);
		buf[len] = 0;
		q += len + (q[len] == '\n');
		if ((c = strchr(buf, '#')) != NULL) *c = 0;
		doc = strstr(buf, "--");
		if (doc) { *doc = 0; doc += 2; while (*doc == ' ' || *doc == '\t') doc++; }
		save = buf;
		w = word(&save);
		if (!w) continue;                       /* blank, or a comment */
		if (strlen(w) >= BC_KIND_NAME) { fail(err, errn, line, "a kind's name too long", w); return 0; }
		for (i = 0; w[i]; i++)
			if (!((w[i] >= 'a' && w[i] <= 'z') || (w[i] >= '0' && w[i] <= '9') || w[i] == '_')) {
				fail(err, errn, line, "a kind's name is lower-case letters, digits and _", w);
				return 0;
			}
		memset(&k, 0, sizeof k);
		strcpy(k.name, w);
		/* what is not said: drawn round 1, with the soldier's spread */
		k.centre[BC_T_NONE] = 1.0f;
		for (i = 1; i < BC_T_COUNT; i++) { k.centre[i] = 1.0f; k.spread[i] = spread[BC_A_SOLDIER][i - 1]; }
		while ((w = word(&save)) != NULL) {
			char *eq = strchr(w, '='), *sl, *end;
			double cv, sv;
			int tr;

			if (!eq) { fail(err, errn, line, "expected <trait>=<centre>/<spread>", w); return 0; }
			*eq = 0;
			tr = bc_trait_by_name(w);
			if (tr <= BC_T_NONE) { fail(err, errn, line, "no such trait", w); return 0; }
			sl = strchr(eq + 1, '/');
			cv = strtod(eq + 1, &end);
			if (end == eq + 1 || !sl || end != sl) { fail(err, errn, line, "expected <centre>/<spread>", eq + 1); return 0; }
			sv = strtod(sl + 1, &end);
			if (end == sl + 1 || *end) { fail(err, errn, line, "expected <centre>/<spread>", eq + 1); return 0; }
			if (!(cv >= TRAIT_MIN && cv <= TRAIT_MAX) || !(sv >= 0.0 && sv <= TRAIT_MAX)) {
				fail(err, errn, line, "a centre is within the traits' bounds (0.2 to 3), a spread 0 to 3", eq + 1);
				return 0;
			}
			k.centre[tr] = (float)cv;
			k.spread[tr] = (float)sv;
		}
		if (doc) snprintf(k.doc, sizeof k.doc, "%s", doc);
		a = bc_kinds_by_name(&out, k.name);
		if (a < 0) {
			if (out.n >= BC_KINDS_MAX) { fail(err, errn, line, "no room for another kind (32 at most)", k.name); return 0; }
			a = out.n++;
		} else if (!doc) {
			snprintf(k.doc, sizeof k.doc, "%s", out.k[a].doc);   /* its line, kept */
		}
		out.k[a] = k;
	}
	*t = out;
	return 1;
}

size_t bc_kinds_write(const bc_kinds *t, char *out, size_t n)
{
	size_t len = 0;
	int a, i;

	if (n) out[0] = 0;
	for (a = 0; a < t->n; a++) {
		len += (size_t)snprintf(out + (len < n ? len : n), len < n ? n - len : 0, "%s", t->k[a].name);
		for (i = 1; i < BC_T_COUNT; i++)
			len += (size_t)snprintf(out + (len < n ? len : n), len < n ? n - len : 0, " %s=%.2f/%.2f",
			                        trait_names[i], (double)t->k[a].centre[i], (double)t->k[a].spread[i]);
		len += (size_t)snprintf(out + (len < n ? len : n), len < n ? n - len : 0, "%s%s\n",
		                        t->k[a].doc[0] ? " -- " : "", t->k[a].doc);
	}
	return len;
}

int bc_kinds_weights(const bc_kinds *t, const char *text, float *weights)
{
	float w[BC_KINDS_MAX];
	const char *q;
	int i;
	if (!weights) return 0;
	if (!text) text = "";
	q = text;
	while (*q == ' ' || *q == '\t') q++;
	if (!*q) {
		for (i = 0; i < t->n; i++) weights[i] = 1.0f;
		return 1;
	}
	for (i = 0; i < t->n; i++) w[i] = 0.0f;
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
		a = bc_kinds_by_name(t, name);
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
	for (i = 0; i < t->n; i++) weights[i] = w[i];
	return 1;
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
