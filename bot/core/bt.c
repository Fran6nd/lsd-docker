/* bt.c -- the behaviour tree runtime and its text compiler
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * SEMANTICS, in one place.
 *
 * seq and select HAVE MEMORY: when a child answers RUNNING, the next tick
 * resumes at that child, and the children before it are not asked again.
 * Predictable, and cheap; the price is that a select does not notice that
 * a higher rule has become true while a lower one is RUNNING. Re-deciding
 * is `pick`'s job: it asks again every `every` seconds and weighs the
 * options anew. When a pick changes its choice, the abandoned option's
 * RUNNING actions are stop()ed, once, and everything remembered under it
 * is forgotten.
 *
 * The same goes for every way a branch can stop being ticked: a pick
 * changing its choice (or finding nothing to choose), a `limit` firing,
 * bt_reset. Every action RUNNING under the branch gets stop() exactly
 * once. An action that itself returned SUCCESS or FAILURE is not stopped:
 * it is over.
 *
 * Time. A bt_state keeps a clock, advanced by ctx->dt at the start of each
 * bt_tick (so tick several trees of one state in a frame and it runs on
 * for each). wait, limit, cooldown and pick's `every` all read that clock,
 * so a timer is right even in a branch that was not ticked meanwhile. A
 * timer starts at the first tick that reaches the node: `wait 1` ticked
 * with dt 0.5 is RUNNING, RUNNING, SUCCESS. `limit` asks its child first
 * and then checks the time. `cooldown` starts when the child answers
 * SUCCESS or FAILURE, not when it is abandoned. Abandoning a branch
 * resets its waits and limits but not a cooldown inside it; bt_reset
 * clears all.
 *
 * Tree references are expanded when compiling ("as if written here"), so
 * each use of a tree has its own state; bt_forest_nodes counts the
 * expanded nodes. A tree's root need not be indented under its header.
 *
 * Memory. bt_compile builds the forest in one block and the source it
 * was read from in another, which the forest owns (temporary working
 * memory is freed before it returns). bt_tick, bt_describe and the
 * bt_state_* readers allocate nothing; bt_tick recurses at most
 * BT_DEPTH_MAX deep.
 *
 * ONE PARSER. bt_parse and bt_compile read the text with the same code
 * (parse_text); the first stops there and hands out the source, the
 * second goes on to look up the references and open them. So what an
 * editor is shown and what a bot runs cannot disagree about what a line
 * means. What a tick reads (bnode, slot) holds nothing for the editor:
 * comments, columns and which node came from where are kept beside it
 * (bt_source, fmeta), not in it.
 */
#include "bt.h"
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* the same numbers as bt.h's bt_kind, K_REF being BT_K_TREE */
enum { K_SEQ, K_SELECT, K_PICK, K_OPTION, K_IF, K_UNLESS, K_DO, K_WAIT,
       K_INVERT, K_ALWAYS, K_NEVER, K_COOLDOWN, K_LIMIT, K_REF };

static const char *const kw[] = { "seq", "select", "pick", "option", "if", "unless",
	"do", "wait", "invert", "always", "never", "cooldown", "limit", "tree" };

enum { VOCAB_MAX = 512, TOKENS_MAX = 16, NODES_MAX = 1 << 18 };

/* ---- the vocabulary -------------------------------------------------- */

enum { VK_COND, VK_SCORE, VK_ACTION, VK_TRAIT };

typedef struct ventry {
	int kind;
	char name[BT_NAME_MAX];
	bt_cond_fn cond;
	bt_score_fn score;
	bt_action_fn action;
	bt_stop_fn stop;
	int trait;
	const bt_arg_spec *specs;   /* its arguments, if the host said (bt_vocab_args) */
	int nspecs;                 /* -1: it did not, and nothing is checked */
} ventry;

enum { SETS_MAX = 8 };

struct bt_vocab {
	int n, nsets;
	struct { char name[BT_NAME_MAX]; char *values; } set[SETS_MAX];
	ventry e[VOCAB_MAX];
};

bt_vocab *bt_vocab_new(void) { return calloc(1, sizeof(bt_vocab)); }
void bt_vocab_free(bt_vocab *v)
{
	int i;
	for (i = 0; v && i < v->nsets; i++) free(v->set[i].values);
	free(v);
}

static const ventry *vfind(const bt_vocab *v, int kind, const char *name)
{
	int i;
	for (i = 0; i < v->n; i++)
		if (v->e[i].kind == kind && strcmp(v->e[i].name, name) == 0) return &v->e[i];
	return NULL;
}

static ventry *vadd(bt_vocab *v, int kind, const char *name)
{
	ventry *e;
	if (!v || !name || !*name || strlen(name) >= BT_NAME_MAX) return NULL;
	if (v->n >= VOCAB_MAX || vfind(v, kind, name)) return NULL;
	e = &v->e[v->n++];
	memset(e, 0, sizeof *e);
	e->kind = kind;
	e->nspecs = -1;
	strcpy(e->name, name);
	return e;
}

int bt_vocab_cond(bt_vocab *v, const char *name, bt_cond_fn fn)
{
	ventry *e;
	if (!fn || !(e = vadd(v, VK_COND, name))) return 0;
	e->cond = fn;
	return 1;
}

int bt_vocab_score(bt_vocab *v, const char *name, bt_score_fn fn)
{
	ventry *e;
	if (!fn || !(e = vadd(v, VK_SCORE, name))) return 0;
	e->score = fn;
	return 1;
}

int bt_vocab_action(bt_vocab *v, const char *name, bt_action_fn fn, bt_stop_fn stop)
{
	ventry *e;
	if (!fn || !(e = vadd(v, VK_ACTION, name))) return 0;
	e->action = fn;
	e->stop = stop;
	return 1;
}

int bt_vocab_trait(bt_vocab *v, const char *name, int index)
{
	ventry *e;
	if (index < 0 || !(e = vadd(v, VK_TRAIT, name))) return 0;
	e->trait = index;
	return 1;
}

int bt_vocab_args(bt_vocab *v, int kind, const char *name, const bt_arg_spec *specs, int n)
{
	int i;
	if (!v || !name || n < 0 || n > BT_ARGS_MAX || (n && !specs)) return 0;
	if (kind != BT_WORD_COND && kind != BT_WORD_SCORE && kind != BT_WORD_ACTION) return 0;
	for (i = 0; i < v->n; i++)
		if (v->e[i].kind == kind && strcmp(v->e[i].name, name) == 0) {
			v->e[i].specs = specs;
			v->e[i].nspecs = n;
			return 1;
		}
	return 0;
}

int bt_vocab_set(bt_vocab *v, const char *name, const char *values)
{
	int i;
	char *copy;
	if (!v || !name || !values || !*name || strlen(name) >= BT_NAME_MAX) return 0;
	for (i = 0; i < v->nsets; i++)
		if (strcmp(v->set[i].name, name) == 0) break;
	if (i == SETS_MAX) return 0;
	copy = malloc(strlen(values) + 1);
	if (!copy) return 0;
	strcpy(copy, values);
	if (i < v->nsets) free(v->set[i].values);
	else strcpy(v->set[v->nsets++].name, name);
	v->set[i].values = copy;
	return 1;
}

const char *bt_vocab_set_values(const bt_vocab *v, const char *name)
{
	int i;
	for (i = 0; v && name && i < v->nsets; i++)
		if (strcmp(v->set[i].name, name) == 0) return v->set[i].values;
	return NULL;
}

/* ---- the compiled forest -------------------------------------------- */

/* a pick that keeps what it drew (roll=once, roll=life), against one that
 * chooses again (plain, roll=each) */
#define ROLE(n) ((n)->roll == BT_ROLL_ONCE || (n)->roll == BT_ROLL_LIFE)

typedef struct bnode {
	uint8_t kind;
	uint8_t roll;           /* pick: BT_ROLL_* */
	int32_t end;            /* index one past this node's subtree */
	int32_t trait;          /* option: index into the weights; a pick that
	                           rolls: its key (the same wherever and however
	                           often its tree is compiled) */
	int32_t line;
	const char *name;       /* leaf name; option: its score's name */
	const char *trait_name; /* option */
	bt_args args;
	bt_cond_fn cond;
	bt_score_fn score;
	bt_action_fn action;
	bt_stop_fn stop;
	float secs, every, sticky, noise, factor;
} bnode;

typedef struct ftree { char name[BT_NAME_MAX]; int32_t root; } ftree;

/* what is known of a forest node that no tick reads */
typedef struct fmeta { int32_t src, via, parent; } fmeta;

/* the text as written: bt.h, "the source" */
typedef struct snode {
	uint8_t kind, written, roll;
	int32_t end;            /* index one past its subtree, in the source */
	int32_t parent, tree, line, col, depth, nchild;
	const char *text, *name, *trait, *note, *above;
	bt_args args;
	float secs, every, sticky, noise, factor;
} snode;

typedef struct stree {
	char name[BT_NAME_MAX];
	int32_t first, end, line, header;
	const char *note, *above;
} stree;

struct bt_source {
	int n_nodes, n_trees;
	snode *nodes;
	stree *trees;
	const char *tail;
};

struct bt_forest {
	size_t n_nodes;
	int n_trees;
	bnode *nodes;
	ftree *trees;
	fmeta *meta;
	bt_source *src;
};

void bt_source_free(bt_source *src) { free(src); }
void bt_forest_free(bt_forest *f) { if (f) free(f->src); free(f); }
size_t bt_forest_nodes(const bt_forest *f) { return f->n_nodes; }

int bt_forest_find(const bt_forest *f, const char *name)
{
	int i;
	if (!f || !name) return -1;
	for (i = 0; i < f->n_trees; i++)
		if (strcmp(f->trees[i].name, name) == 0) return i;
	return -1;
}

/* ---- compiling ------------------------------------------------------- */

typedef struct pnode {
	bnode n;
	int parent, nchild, ref;
	char *refname;
	int col, depth, written;
	int bad;                /* its words were wrong: kept for its place, checked no further */
	char *text, *note, *above;
} pnode;

typedef struct ptree {
	char name[BT_NAME_MAX];
	int first, hline, base;
	int header;
	int npick;              /* picks read so far: a rolling pick's ordinal */
	char *note, *above;
} ptree;

typedef struct tok { const char *s; size_t n; } tok;

typedef struct P {
	const bt_vocab *v;
	bt_diag *out;           /* the mistakes found, at most maxd of them */
	int nd, maxd;
	int failed;             /* stop reading: maxd mistakes, or no memory */
	int lost;               /* a line was dropped for a mistake: what follows
	                           from it (a child with no parent) is not said */
	const char *lstart;     /* the line being read, and the column of the */
	int col;                /* word a mistake found now would be about */
	char *ab;               /* comments and empty lines met since the last node */
	size_t nab, capab;
	fmeta *ex; size_t capex;        /* beside em, node for node */
	pnode *pn; size_t npn, cappn;
	ptree *pt; size_t npt, cappt;
	char **pool; size_t npool, cappool;
	bnode *em; size_t nem, capem;
	int *tstack; size_t tsp;
	int stack[BT_DEPTH_MAX]; int sp;
	int style, unit, implicit;
} P;

static void fail(P *p, int line, const char *fmt, ...)
{
	va_list ap;
	bt_diag *d;
	int i;
	if (p->failed) return;
	d = &p->out[p->nd];
	d->line = line;
	d->column = line > 0 ? p->col : 0;
	va_start(ap, fmt);
	vsnprintf(d->message, sizeof d->message, fmt, ap);
	va_end(ap);
	for (i = 0; i < p->nd; i++)             /* said already (a circle, met from each end) */
		if (p->out[i].line == line && !strcmp(p->out[i].message, d->message)) return;
	p->nd++;
	if (p->nd >= p->maxd || line <= 0) p->failed = 1;
}

/* a mistake of shape: not said when it follows from a line dropped above */
#define SHAPE(p, line, ...) do { if (!(p)->lost) fail(p, line, __VA_ARGS__); } while (0)

static void *grow(P *p, void *arr, size_t *cap, size_t need, size_t esz)
{
	size_t nc;
	void *q;
	if (need <= *cap) return arr;
	nc = *cap ? *cap * 2 : 16;
	while (nc < need) nc *= 2;
	q = realloc(arr, nc * esz);
	if (!q) { fail(p, 0, "out of memory"); return arr; }
	*cap = nc;
	return q;
}

static char *dups(P *p, const char *s, size_t n)
{
	char *d = malloc(n + 1);
	if (!d) { fail(p, 0, "out of memory"); return NULL; }
	memcpy(d, s, n);
	d[n] = 0;
	p->pool = grow(p, p->pool, &p->cappool, p->npool + 1, sizeof *p->pool);
	if (p->failed) { free(d); return NULL; }
	p->pool[p->npool++] = d;
	return d;
}

/* a mistake found from here on is about this word */
static void at(P *p, tok t) { p->col = (int)(t.s - p->lstart) + 1; }

static int tokeq(tok t, const char *s) { return strlen(s) == t.n && memcmp(t.s, s, t.n) == 0; }

/* a whole token that is a finite number */
static int tonum(const char *s, float *out)
{
	char *end;
	double d;
	if (!*s) return 0;
	d = strtod(s, &end);
	if (*end || !isfinite(d)) return 0;
	*out = (float)d;
	return 1;
}

static int is_leaf(int k) { return k == K_IF || k == K_UNLESS || k == K_DO || k == K_WAIT || k == K_REF; }
static int is_decor(int k) { return k == K_INVERT || k == K_ALWAYS || k == K_NEVER || k == K_COOLDOWN || k == K_LIMIT; }

/* is the word one of "a|b|c"? An entry that ends in `*` ("@*") is any
 * word that begins so and goes on as a name does (letters, digits, _). */
static int in_list(const char *list, tok w)
{
	while (list && *list) {
		size_t n = strcspn(list, "|"), i;
		if (n == w.n && !memcmp(list, w.s, n)) return 1;
		if (n > 1 && list[n - 1] == '*' && w.n >= n && w.n < BT_NAME_MAX && !memcmp(list, w.s, n - 1)) {
			for (i = n - 1; i < w.n; i++) {
				char c = w.s[i];
				if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) break;
			}
			if (i == w.n) return 1;
		}
		list += n + (list[n] == '|');
	}
	return 0;
}

/* a leaf's arguments against what the host said the word takes */
static int check_args(P *p, const ventry *e, const tok *t, int from, int to, int line)
{
	int n = to - from, i, need = 0;
	if (!e || e->nspecs < 0) return 1;
	for (i = 0; i < e->nspecs; i++) if (e->specs[i].required) need = i + 1;
	if (n < need) {
		fail(p, line, "%s: <%s> is missing", e->name, e->specs[n].name);
		return 0;
	}
	for (i = 0; i < n; i++) {
		const bt_arg_spec *s;
		const tok w = t[from + i];
		char word[48];
		float v;
		at(p, w);
		if (i >= e->nspecs && !(e->nspecs && e->specs[e->nspecs - 1].repeat)) {
			if (e->nspecs == 0) fail(p, line, "%s takes no argument", e->name);
			else fail(p, line, "%s takes %d argument%s at most", e->name, e->nspecs, e->nspecs > 1 ? "s" : "");
			return 0;
		}
		s = &e->specs[i < e->nspecs ? i : e->nspecs - 1];
		snprintf(word, sizeof word, "%.*s", (int)(w.n < sizeof word ? w.n : sizeof word - 1), w.s);
		if (s->type == BT_ARG_NUMBER) {
			if (w.n >= sizeof word || !tonum(word, &v)) {
				fail(p, line, "%s: <%s> is a number, not '%s'", e->name, s->name, word);
				return 0;
			}
			if ((s->has_min && v < s->min) || (s->has_max && v > s->max)) {
				if (s->has_min && s->has_max)
					fail(p, line, "%s: <%s> must be between %g and %g", e->name, s->name, (double)s->min, (double)s->max);
				else if (s->has_min)
					fail(p, line, "%s: <%s> must be %g or more", e->name, s->name, (double)s->min);
				else
					fail(p, line, "%s: <%s> must be %g or less", e->name, s->name, (double)s->max);
				return 0;
			}
		} else if (s->type == BT_ARG_ONE_OF) {
			const char *set = s->set ? bt_vocab_set_values(p->v, s->set) : NULL;
			if (in_list(s->values, w) || in_list(set, w)) continue;
			if (s->set && !set) continue;           /* a list the host never gave: not checked */
			if (s->set && s->values)
				fail(p, line, "%s: '%s' is neither %s nor a %s", e->name, word, s->values, s->set);
			else if (s->set)
				fail(p, line, "%s: no %s called %s", e->name, s->set, word);
			else
				fail(p, line, "%s: '%s' is not one of %s", e->name, word, s->values ? s->values : "");
			return 0;
		}
	}
	return 1;
}

static int set_args(P *p, bnode *b, const ventry *e, const tok *t, int from, int to, int line)
{
	int i;
	if (!check_args(p, e, t, from, to, line)) return 0;
	if (to - from > BT_ARGS_MAX) {
		fail(p, line, "'%s' takes at most %d arguments", kw[b->kind], BT_ARGS_MAX);
		return 0;
	}
	for (i = from; i < to; i++) {
		const char *s = dups(p, t[i].s, t[i].n);
		if (!s) return 0;
		b->args.text[b->args.count] = s;
		if (!tonum(s, &b->args.num[b->args.count])) b->args.num[b->args.count] = 0;
		b->args.count++;
	}
	return 1;
}

static int valid_name(const tok t)
{
	size_t i;
	if (t.n == 0 || t.n >= BT_NAME_MAX) return 0;
	for (i = 0; i < t.n; i++) {
		char c = t.s[i];
		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
		      c == '_' || c == '-' || c == '.')) return 0;
	}
	return 1;
}

/* a node's own words -> b. false (with the error set) if wrong */
static int fill_node(P *p, pnode *pn, const tok *t, int nt, int line)
{
	bnode *b = &pn->n;
	const ventry *e;
	char nm[BT_NAME_MAX * 2];
	int i;
	b->line = line;
	b->factor = 1.0f;
	b->every = 2.0f;
	b->sticky = 0.25f;
	b->noise = 0.1f;
	pn->ref = -1;
	pn->parent = -1;
	for (i = 0; i < (int)(sizeof kw / sizeof *kw); i++)
		if (tokeq(t[0], kw[i])) break;
	if (i == (int)(sizeof kw / sizeof *kw)) {
		fail(p, line, "unknown node '%.*s'", (int)t[0].n, t[0].s);
		return 0;
	}
	b->kind = (uint8_t)i;
	switch (b->kind) {
	case K_SEQ: case K_SELECT: case K_INVERT: case K_ALWAYS: case K_NEVER:
		if (nt != 1) { fail(p, line, "'%s' takes no arguments", kw[b->kind]); return 0; }
		return 1;
	case K_PICK:
		for (i = 1; i < nt; i++) {
			const char *eq = memchr(t[i].s, '=', t[i].n);
			size_t kn = eq ? (size_t)(eq - t[i].s) : t[i].n;
			float val = 0;
			char *vs;
			at(p, t[i]);
			if (!eq || kn == 0) { fail(p, line, "pick: expected key=value, got '%.*s'", (int)t[i].n, t[i].s); return 0; }
			vs = dups(p, eq + 1, t[i].n - kn - 1);
			if (!vs) return 0;
			if (kn == 4 && !memcmp(t[i].s, "roll", 4)) {
				if (!strcmp(vs, "weighed")) b->roll = BT_ROLL_WEIGHED;
				else if (!strcmp(vs, "once")) b->roll = BT_ROLL_ONCE;
				else if (!strcmp(vs, "life")) b->roll = BT_ROLL_LIFE;
				else if (!strcmp(vs, "each")) b->roll = BT_ROLL_EACH;
				else { fail(p, line, "pick: roll is weighed, once or life, or each, not '%s'", vs); return 0; }
				pn->written |= BT_W_ROLL;
				continue;
			}
			if (!tonum(vs, &val) || val < 0) {
				fail(p, line, "pick: '%.*s' needs a number of 0 or more", (int)kn, t[i].s);
				return 0;
			}
			if (kn == 5 && !memcmp(t[i].s, "every", 5)) { b->every = val; pn->written |= BT_W_EVERY; }
			else if (kn == 6 && !memcmp(t[i].s, "sticky", 6)) { b->sticky = val; pn->written |= BT_W_STICKY; }
			else if (kn == 5 && !memcmp(t[i].s, "noise", 5)) {
				if (val > 1) { fail(p, line, "pick: noise must be between 0 and 1"); return 0; }
				b->noise = val;
				pn->written |= BT_W_NOISE;
			} else {
				fail(p, line, "pick: unknown setting '%.*s' (every, sticky, noise, roll)", (int)kn, t[i].s);
				return 0;
			}
		}
		if (b->roll == BT_ROLL_EACH && (pn->written & (BT_W_STICKY | BT_W_NOISE))) {
			at(p, t[1]);
			fail(p, line, "pick: with roll=each the option is drawn by its worth alone: sticky and noise have no meaning (every does)");
			return 0;
		}
		if (ROLE(b) && (pn->written & (BT_W_EVERY | BT_W_STICKY | BT_W_NOISE))) {
			at(p, t[1]);
			fail(p, line, "pick: with roll=%s the choice is drawn once and kept: every, sticky and noise have no meaning",
			     b->roll == BT_ROLL_ONCE ? "once" : "life");
			return 0;
		}
		return 1;
	case K_OPTION: {
		int last = nt;
		const ventry *tr;
		if (nt < 3) { fail(p, line, "option needs a trait and a score: option <trait> <score> [x<factor>]"); return 0; }
		snprintf(nm, sizeof nm, "%.*s", (int)(t[1].n < BT_NAME_MAX ? t[1].n : BT_NAME_MAX - 1), t[1].s);
		tr = t[1].n < BT_NAME_MAX ? vfind(p->v, VK_TRAIT, nm) : NULL;
		at(p, t[1]);
		if (!tr) { fail(p, line, "no trait called %.*s", (int)t[1].n, t[1].s); return 0; }
		b->trait = tr->trait;
		b->trait_name = dups(p, t[1].s, t[1].n);
		snprintf(nm, sizeof nm, "%.*s", (int)(t[2].n < BT_NAME_MAX ? t[2].n : BT_NAME_MAX - 1), t[2].s);
		e = t[2].n < BT_NAME_MAX ? vfind(p->v, VK_SCORE, nm) : NULL;
		at(p, t[2]);
		if (!e) { fail(p, line, "no score called %.*s", (int)t[2].n, t[2].s); return 0; }
		b->score = e->score;
		b->name = dups(p, t[2].s, t[2].n);
		if (last > 3 && t[last - 1].s[0] == 'x') {      /* a trailing x<number> is the factor */
			char *fs = dups(p, t[last - 1].s + 1, t[last - 1].n - 1);
			float fv;
			if (fs && tonum(fs, &fv) && fv >= 0) { b->factor = fv; pn->written |= BT_W_FACTOR; last--; }
		}
		if (last > 3) at(p, t[3]);
		return b->trait_name && b->name && set_args(p, b, e, t, 3, last, line);
	}
	case K_IF: case K_UNLESS: case K_DO:
		if (nt < 2) {
			fail(p, line, "'%s' needs %s name", kw[b->kind], b->kind == K_DO ? "an action" : "a condition");
			return 0;
		}
		snprintf(nm, sizeof nm, "%.*s", (int)(t[1].n < BT_NAME_MAX ? t[1].n : BT_NAME_MAX - 1), t[1].s);
		e = t[1].n < BT_NAME_MAX ? vfind(p->v, b->kind == K_DO ? VK_ACTION : VK_COND, nm) : NULL;
		at(p, t[1]);
		if (!e) {
			fail(p, line, "no %s called %.*s", b->kind == K_DO ? "action" : "condition", (int)t[1].n, t[1].s);
			return 0;
		}
		b->cond = e->cond;
		b->action = e->action;
		b->stop = e->stop;
		b->name = dups(p, t[1].s, t[1].n);
		return b->name && set_args(p, b, e, t, 2, nt, line);
	case K_WAIT: case K_COOLDOWN: case K_LIMIT: {
		char *s;
		if (nt != 2) { fail(p, line, "'%s' takes one number of seconds", kw[b->kind]); return 0; }
		at(p, t[1]);
		s = dups(p, t[1].s, t[1].n);
		if (!s) return 0;
		if (!tonum(s, &b->secs) || b->secs < 0) {
			fail(p, line, "'%s' needs a number of seconds (0 or more), not '%s'", kw[b->kind], s);
			return 0;
		}
		return 1;
	}
	default: /* K_REF */
		if (nt != 2 || t[1].s[t[1].n - 1] == ':') { fail(p, line, "tree reference is 'tree <name>'"); return 0; }
		at(p, t[1]);
		if (!valid_name(t[1])) { fail(p, line, "bad tree name '%.*s'", (int)t[1].n, t[1].s); return 0; }
		pn->refname = dups(p, t[1].s, t[1].n);
		return pn->refname != NULL;
	}
}

/* the arity rules that need the whole subtree, checked when a tree ends */
static void finish_tree(P *p)
{
	ptree *tr;
	size_t j;
	int k;
	if (p->npt == 0 || p->failed) return;
	tr = &p->pt[p->npt - 1];
	for (k = 0; k < p->sp; k++) p->pn[p->stack[k]].n.end = (int32_t)p->npn;
	p->sp = 0;
	p->col = 1;
	if ((size_t)tr->first == p->npn) { SHAPE(p, tr->hline, "tree '%s' is empty", tr->name); return; }
	for (j = (size_t)tr->first; j < p->npn && !p->failed; j++) {
		pnode *pn = &p->pn[j];
		int kind = pn->n.kind;
		p->col = pn->col;
		if (pn->bad || pn->nchild) continue;
		if (kind == K_SEQ || kind == K_SELECT || kind == K_PICK)
			SHAPE(p, pn->n.line, "'%s' needs at least one child", kw[kind]);
		else if (is_decor(kind) || kind == K_OPTION)
			SHAPE(p, pn->n.line, "'%s' needs a child", kw[kind]);
	}
}

/* a comment or an empty line, kept for the node that comes next */
static void keep_above(P *p, const char *s, size_t n)
{
	p->ab = grow(p, p->ab, &p->capab, p->nab + n + 2, 1);
	if (p->failed) return;
	memcpy(p->ab + p->nab, s, n);
	p->nab += n;
	p->ab[p->nab++] = '\n';
	p->ab[p->nab] = 0;
}

/* what was kept, handed to that node (NULL if nothing was) */
static char *take_above(P *p)
{
	char *s = p->nab ? dups(p, p->ab, p->nab) : NULL;
	p->nab = 0;
	return s;
}

static void parse_line(P *p, const char *q, size_t len, int line)
{
	size_t i, nspace = 0, ntab = 0, full = len, hash, tl = 0;
	tok t[TOKENS_MAX];
	int nt = 0, level = 0, rel, parent, header = 0;
	pnode pn;
	ptree *tr;
	char *note = NULL, *above;

	p->lstart = q;
	p->col = 1;
	for (i = 0; i < len; i++) if (q[i] == '#') { len = i; break; }
	hash = len;
	while (full && (q[full - 1] == ' ' || q[full - 1] == '\t' || q[full - 1] == '\r')) full--;
	while (len && (q[len - 1] == ' ' || q[len - 1] == '\t' || q[len - 1] == '\r')) len--;
	for (i = 0; i < len && (q[i] == ' ' || q[i] == '\t'); i++) {
		if (q[i] == ' ') nspace++; else ntab++;
	}
	if (i == len) {                  /* blank or comment */
		keep_above(p, q + hash, full > hash ? full - hash : 0);
		return;
	}

	while (i < len) {
		while (i < len && (q[i] == ' ' || q[i] == '\t')) i++;
		if (i >= len) break;
		if (nt == TOKENS_MAX) { fail(p, line, "too many words on one line"); return; }
		t[nt].s = q + i;
		while (i < len && q[i] != ' ' && q[i] != '\t') i++;
		t[nt].n = (size_t)(q + i - t[nt].s);
		nt++;
	}

	if (hash < full) {               /* the comment on this line */
		size_t a = hash + 1;
		while (a < full && (q[a] == ' ' || q[a] == '\t')) a++;
		if (a < full && !(note = dups(p, q + a, full - a))) return;
	}

	if (ntab && nspace) { fail(p, line, "indentation mixes tabs and spaces"); return; }
	if (ntab) {
		if (p->style == 2) { fail(p, line, "tab indentation in a text indented with spaces"); return; }
		p->style = 1;
		level = (int)ntab;
	} else if (nspace) {
		if (p->style == 1) { fail(p, line, "space indentation in a text indented with tabs"); return; }
		if (!p->style) {
			if (nspace != 2 && nspace != 4) {
				fail(p, line, "indentation must be a tab, two spaces or four spaces, not %d spaces", (int)nspace);
				return;
			}
			p->style = 2;
			p->unit = (int)nspace;
		} else if (nspace % (size_t)p->unit) {
			fail(p, line, "indentation of %d spaces is not a multiple of %d", (int)nspace, p->unit);
			return;
		}
		level = (int)nspace / p->unit;
	}

	at(p, t[0]);
	/* `tree name:` opens a tree; `tree name` is a node */
	if (tokeq(t[0], "tree") && nt >= 2) {
		tok name = t[1];
		at(p, t[1]);
		if (name.s[name.n - 1] == ':' && nt == 2) { name.n--; header = 1; }
		else if (nt == 3 && tokeq(t[2], ":")) header = 1;
		else if (name.s[name.n - 1] == ':') { fail(p, line, "bad tree header"); return; }
		if (header) {
			if (level) { p->col = 1; fail(p, line, "a tree header must not be indented"); return; }
			if (!valid_name(name)) { fail(p, line, "bad tree name '%.*s'", (int)name.n, name.s); return; }
			if (p->implicit) { fail(p, line, "this tree header comes after lines that belong to no tree"); return; }
			finish_tree(p);
			if (p->failed) return;
			at(p, t[1]);
			for (i = 0; i < p->npt; i++)
				if (strlen(p->pt[i].name) == name.n && !memcmp(p->pt[i].name, name.s, name.n)) {
					fail(p, line, "tree '%.*s' is defined twice", (int)name.n, name.s);
					return;
				}
			p->pt = grow(p, p->pt, &p->cappt, p->npt + 1, sizeof *p->pt);
			if (p->failed) return;
			tr = &p->pt[p->npt++];
			memset(tr, 0, sizeof *tr);
			memcpy(tr->name, name.s, name.n);
			tr->first = (int)p->npn;
			tr->hline = line;
			tr->header = 1;
			tr->note = note;
			tr->above = take_above(p);
			return;
		}
		at(p, t[0]);
	}

	if (p->npt == 0) {        /* nodes with no header: the one tree "main" */
		p->pt = grow(p, p->pt, &p->cappt, 1, sizeof *p->pt);
		if (p->failed) return;
		tr = &p->pt[p->npt++];
		memset(tr, 0, sizeof *tr);
		strcpy(tr->name, "main");
		tr->hline = line;
		p->implicit = 1;
	}
	tr = &p->pt[p->npt - 1];

	memset(&pn, 0, sizeof pn);
	if (!fill_node(p, &pn, t, nt, line)) {
		if (p->failed) return;
		pn.bad = 1;             /* more mistakes are wanted: it keeps its place */
		pn.n.line = line;
		pn.ref = pn.parent = -1;
	}
	at(p, t[0]);
	pn.col = p->col;
	pn.note = note;
	for (i = 0; i < (size_t)nt; i++) tl += t[i].n + 1;
	pn.text = dups(p, q, tl);                       /* its words, one space apart */
	if (!pn.text) return;
	for (i = 0, tl = 0; i < (size_t)nt; i++) {
		memcpy(pn.text + tl, t[i].s, t[i].n);
		tl += t[i].n;
		pn.text[tl++] = ' ';
	}
	pn.text[tl - 1] = 0;

	if ((size_t)tr->first == p->npn) {
		tr->base = level;
		rel = 0;
		p->sp = 0;
	} else {
		if (level < tr->base) { SHAPE(p, line, "indented less than the tree's first node"); return; }
		rel = level - tr->base;
		if (rel == 0) { SHAPE(p, line, "a tree has one root node; this is a second (indent it under the first?)"); return; }
	}
	if (rel > p->sp) { SHAPE(p, line, "indented too deep: one level at a time"); return; }
	if (rel >= BT_DEPTH_MAX) { fail(p, line, "nested deeper than %d levels", BT_DEPTH_MAX); return; }
	parent = rel ? p->stack[rel - 1] : -1;
	if (pn.bad || (parent >= 0 && p->pn[parent].bad)) {
		;                       /* what it is is not known: its shape is not judged */
	} else if (parent >= 0) {
		const pnode *pp = &p->pn[parent];
		int pk = pp->n.kind;
		if (is_leaf(pk)) { SHAPE(p, line, "'%s' takes no children", kw[pk]); return; }
		if (pk == K_PICK && pn.n.kind != K_OPTION) { SHAPE(p, line, "a pick has only options"); return; }
		if (pn.n.kind == K_OPTION && pk != K_PICK) { SHAPE(p, line, "an option belongs directly under a pick"); return; }
		if ((is_decor(pk) || pk == K_OPTION) && pp->nchild >= 1) {
			SHAPE(p, line, "'%s' takes exactly one child", kw[pk]);
			return;
		}
	} else if (pn.n.kind == K_OPTION) {
		SHAPE(p, line, "an option belongs directly under a pick");
		return;
	}
	p->pn = grow(p, p->pn, &p->cappn, p->npn + 1, sizeof *p->pn);
	above = take_above(p);
	if (p->failed) return;
	for (i = (size_t)rel; i < (size_t)p->sp; i++) p->pn[p->stack[i]].n.end = (int32_t)p->npn;
	pn.above = above;
	pn.depth = rel;
	pn.parent = parent;
	if (pn.n.kind == K_PICK) {
		/* what a rolling pick's draw is made from, with the bot's identity:
		 * its tree's name and which pick of that tree it is -- so the same
		 * bot draws the same role whatever other trees the text holds */
		uint32_t h = 2166136261u;
		const char *c;
		for (c = tr->name; *c; c++) h = (h ^ (uint8_t)*c) * 16777619u;
		h = (h ^ (uint32_t)tr->npick++) * 16777619u;
		pn.n.trait = (int32_t)h;
	}
	if (parent >= 0) p->pn[parent].nchild++;
	p->stack[rel] = (int)p->npn;
	p->sp = rel + 1;
	p->pn[p->npn++] = pn;
}

/* `via`: the reference that brought this node here, for the root of a
 * tree opened in place; `parent`: its parent in the forest */
static int emit_node(P *p, int i, int depth, int via, int parent)
{
	const pnode *pn = &p->pn[i];
	size_t me;
	int c;
	p->col = pn->col;
	if (pn->n.kind == K_REF) {
		size_t k;
		int t = pn->ref, ok;
		for (k = 0; k < p->tsp; k++)
			if (p->tstack[k] == t) {
				fail(p, pn->n.line, "tree '%s' refers back to itself (a cycle of tree references)", p->pt[t].name);
				return 0;
			}
		p->tstack[p->tsp++] = t;
		ok = emit_node(p, p->pt[t].first, depth, via >= 0 ? via : i, parent);
		p->tsp--;
		return ok;
	}
	if (depth >= BT_DEPTH_MAX) { fail(p, pn->n.line, "nested deeper than %d levels (tree references included)", BT_DEPTH_MAX); return 0; }
	if (p->nem >= NODES_MAX) { fail(p, pn->n.line, "the trees expand to too many nodes"); return 0; }
	p->em = grow(p, p->em, &p->capem, p->nem + 1, sizeof *p->em);
	p->ex = grow(p, p->ex, &p->capex, p->nem + 1, sizeof *p->ex);
	if (p->failed) return 0;
	me = p->nem++;
	p->em[me] = pn->n;
	p->ex[me].src = i;
	p->ex[me].via = via;
	p->ex[me].parent = parent;
	for (c = i + 1; c < pn->n.end; c = p->pn[c].n.end)
		if (!emit_node(p, c, depth + 1, -1, (int)me)) return 0;
	p->em[me].end = (int32_t)p->nem;
	return 1;
}

static size_t sdup(char **arena, const char *s)
{
	size_t n = strlen(s) + 1;
	memcpy(*arena, s, n);
	*arena += n;
	return n;
}

static bt_forest *build(P *p)
{
	size_t i, k, strs = 0, size;
	bt_forest *f;
	char *block, *arena;
	for (i = 0; i < p->nem; i++) {
		const bnode *b = &p->em[i];
		if (b->name) strs += strlen(b->name) + 1;
		if (b->trait_name) strs += strlen(b->trait_name) + 1;
		for (k = 0; k < (size_t)b->args.count; k++) strs += strlen(b->args.text[k]) + 1;
	}
	size = sizeof *f + p->nem * sizeof(bnode) + p->npt * sizeof(ftree) + p->nem * sizeof(fmeta) + strs;
	block = malloc(size);
	if (!block) { fail(p, 0, "out of memory"); return NULL; }
	f = (bt_forest *)block;
	f->n_nodes = p->nem;
	f->n_trees = (int)p->npt;
	f->src = NULL;
	f->nodes = (bnode *)(block + sizeof *f);
	f->trees = (ftree *)(block + sizeof *f + p->nem * sizeof(bnode));
	f->meta = (fmeta *)(block + sizeof *f + p->nem * sizeof(bnode) + p->npt * sizeof(ftree));
	arena = (char *)(f->meta + p->nem);
	if (p->nem) memcpy(f->meta, p->ex, p->nem * sizeof(fmeta));
	for (i = 0; i < p->nem; i++) {
		bnode *b = &f->nodes[i];
		*b = p->em[i];
		if (b->name) { b->name = arena; sdup(&arena, p->em[i].name); }
		if (b->trait_name) { b->trait_name = arena; sdup(&arena, p->em[i].trait_name); }
		for (k = 0; k < (size_t)b->args.count; k++) { b->args.text[k] = arena; sdup(&arena, p->em[i].args.text[k]); }
	}
	return f;
}

static size_t slen(const char *s) { return s ? strlen(s) + 1 : 0; }
static const char *skeep(char **arena, const char *s)
{
	const char *at_ = *arena;
	if (!s) return NULL;
	sdup(arena, s);
	return at_;
}

/* the text as it was read, in one block: what an editor is given */
static bt_source *build_source(P *p)
{
	size_t i, t, strs = 0, size;
	int k;
	bt_source *src;
	char *block, *arena;
	for (i = 0; i < p->npn; i++) {
		const pnode *pn = &p->pn[i];
		strs += slen(pn->text) + slen(pn->note) + slen(pn->above) + slen(pn->n.name) +
		        slen(pn->n.trait_name) + slen(pn->refname);
		for (k = 0; k < pn->n.args.count; k++) strs += slen(pn->n.args.text[k]);
	}
	for (t = 0; t < p->npt; t++) strs += slen(p->pt[t].note) + slen(p->pt[t].above);
	strs += p->nab + 1;
	size = sizeof *src + p->npn * sizeof(snode) + p->npt * sizeof(stree) + strs;
	block = malloc(size);
	if (!block) { fail(p, 0, "out of memory"); return NULL; }
	src = (bt_source *)block;
	src->n_nodes = (int)p->npn;
	src->n_trees = (int)p->npt;
	src->nodes = (snode *)(block + sizeof *src);
	src->trees = (stree *)(block + sizeof *src + p->npn * sizeof(snode));
	arena = (char *)(src->trees + p->npt);
	for (t = 0; t < p->npt; t++) {
		const ptree *pt = &p->pt[t];
		stree *st = &src->trees[t];
		memcpy(st->name, pt->name, sizeof st->name);
		st->first = pt->first;
		st->end = t + 1 < p->npt ? p->pt[t + 1].first : (int32_t)p->npn;
		st->line = pt->hline;
		st->header = pt->header;
		st->note = skeep(&arena, pt->note);
		st->above = skeep(&arena, pt->above);
		for (k = st->first; k < st->end; k++) src->nodes[k].tree = (int32_t)t;
	}
	for (i = 0; i < p->npn; i++) {
		const pnode *pn = &p->pn[i];
		snode *sn = &src->nodes[i];
		sn->kind = pn->n.kind;
		sn->written = (uint8_t)pn->written;
		sn->roll = pn->n.roll;
		sn->end = pn->n.end;
		sn->parent = pn->parent;
		sn->line = pn->n.line;
		sn->col = pn->col;
		sn->depth = pn->depth;
		sn->nchild = pn->nchild;
		sn->text = skeep(&arena, pn->text);
		sn->name = skeep(&arena, pn->n.kind == K_REF ? pn->refname : pn->n.name);
		sn->trait = skeep(&arena, pn->n.trait_name);
		sn->note = skeep(&arena, pn->note);
		sn->above = skeep(&arena, pn->above);
		sn->args = pn->n.args;
		for (k = 0; k < sn->args.count; k++) sn->args.text[k] = skeep(&arena, pn->n.args.text[k]);
		sn->secs = pn->n.secs;
		sn->every = pn->n.every;
		sn->sticky = pn->n.sticky;
		sn->noise = pn->n.noise;
		sn->factor = pn->n.factor;
	}
	src->tail = p->nab ? skeep(&arena, p->ab) : NULL;
	return src;
}

/* the text into p->pn and p->pt: all that bt_parse does, and the first
 * half of bt_compile */
/* the text into p->pn and p->pt: all that bt_parse does, and the first
 * half of bt_compile. Mistakes go to `out`, at most `max` of them. */
static void parse_text(P *p, const bt_vocab *v, const char *text, bt_diag *out, int max)
{
	const char *q;
	int line = 0;

	memset(p, 0, sizeof *p);
	p->v = v;
	p->out = out;
	p->maxd = max;
	if (!v || !text) { fail(p, 1, "no vocabulary or no text"); p->failed = 1; return; }
	for (q = text; *q && !p->failed;) {
		const char *e = strchr(q, '\n');
		size_t len = e ? (size_t)(e - q) : strlen(q), n0 = p->npn, t0 = p->npt;
		int d0 = p->nd;
		parse_line(p, q, len, ++line);
		if (p->npn > n0 || p->npt > t0) p->lost = 0;
		else if (p->nd > d0) p->lost = 1;
		q = e ? e + 1 : q + len;
	}
	if (!p->failed) finish_tree(p);
	p->col = 0;
	if (!p->failed && p->npt == 0 && p->nd == 0) fail(p, 1, "no tree in this text");
}

/* the second half: every reference found its tree, and each tree opened
 * into p->em (only when nothing was wrong so far) */
static void link_text(P *p)
{
	size_t i;
	for (i = 0; i < p->npn && !p->failed; i++) {    /* resolve references, all trees being read */
		size_t t;
		if (p->pn[i].n.kind != K_REF || p->pn[i].bad) continue;
		for (t = 0; t < p->npt; t++)
			if (strcmp(p->pt[t].name, p->pn[i].refname) == 0) { p->pn[i].ref = (int)t; break; }
		p->col = p->pn[i].col;
		if (p->pn[i].ref < 0) fail(p, p->pn[i].n.line, "no tree called %s", p->pn[i].refname);
	}
	if (p->nd) return;
	p->tstack = malloc((p->npt + 1) * sizeof *p->tstack);
	if (!p->tstack) { fail(p, 0, "out of memory"); return; }
	for (i = 0; i < p->npt && !p->failed; i++) {    /* expand each tree, references inlined */
		p->tsp = 0;
		p->tstack[p->tsp++] = (int)i;
		p->pt[i].base = (int)p->nem;               /* base reused: the root's index in the forest */
		emit_node(p, p->pt[i].first, 0, -1, -1);
	}
}

static void parse_done(P *p, bt_diag *diag)
{
	size_t i;
	if (diag) {
		if (p->nd) *diag = p->out[0];
		else memset(diag, 0, sizeof *diag);
	}
	for (i = 0; i < p->npool; i++) free(p->pool[i]);
	free(p->pool); free(p->pn); free(p->pt); free(p->em); free(p->ex); free(p->tstack); free(p->ab);
}

bt_source *bt_parse(const bt_vocab *v, const char *text, bt_diag *diag)
{
	P p;
	bt_diag one;
	bt_source *src = NULL;
	parse_text(&p, v, text, &one, 1);
	if (!p.nd) src = build_source(&p);
	parse_done(&p, diag);
	return src;
}

bt_forest *bt_compile_diag(const bt_vocab *v, const char *text, bt_diag *diag)
{
	P p;
	bt_diag one;
	bt_forest *f = NULL;
	size_t i;

	parse_text(&p, v, text, &one, 1);
	if (!p.nd) link_text(&p);
	if (!p.nd) {
		f = build(&p);
		if (f)
			for (i = 0; i < p.npt; i++) {
				strcpy(f->trees[i].name, p.pt[i].name);
				f->trees[i].root = p.pt[i].base;
			}
		if (f && !(f->src = build_source(&p))) { free(f); f = NULL; }
	}
	parse_done(&p, diag);
	return f;
}

int bt_diagnose(const bt_vocab *v, const char *text, int link, bt_diag *out, int max)
{
	P p;
	bt_diag one;
	int n;
	if (!out || max < 1) { out = &one; max = 1; }
	parse_text(&p, v, text, out, max);
	if (link && !p.failed) link_text(&p);
	n = p.nd;
	parse_done(&p, NULL);
	return n;
}

bt_forest *bt_compile(const bt_vocab *v, const char *text, char *err, size_t err_size)
{
	bt_diag d;
	bt_forest *f = bt_compile_diag(v, text, &d);
	if (err && err_size) {
		err[0] = 0;
		if (!f) snprintf(err, err_size, "line %d: %s", d.line, d.message);
	}
	return f;
}

/* ---- running --------------------------------------------------------- */

typedef struct slot {
	double t;       /* wait, limit: start; cooldown: until; pick: last choice */
	int32_t cur;    /* seq, select, pick: running/chosen child's index + 1 */
	int32_t run;    /* do: RUNNING; wait, limit: started */
} slot;

struct bt_state {
	double now;
	uint32_t n;
	uint32_t trace;     /* bt_state_trace: picks note what they weighed */
	slot s[];
};

/* What a pick notes of an option it weighed, when asked to: kept in the
 * option's own slot, which nothing else uses (a pick ticks the option's
 * child, never the option). `sticky` is never 0 once written. */
typedef struct oslot { float score, weight, luck, sticky; } oslot;
typedef char oslot_fits_[sizeof(oslot) <= sizeof(slot) ? 1 : -1];

size_t bt_state_size(const bt_forest *f) { return sizeof(bt_state) + f->n_nodes * sizeof(slot); }

void bt_state_init(bt_state *s, const bt_forest *f)
{
	memset(s, 0, bt_state_size(f));
	s->n = (uint32_t)f->n_nodes;
}

/* stop every action RUNNING under node i and forget what was remembered
 * there (a cooldown's clock is kept unless `all`) */
static void stop_range(const bt_forest *f, int i, bt_state *s, const bt_ctx *c, int all)
{
	int k;
	for (k = i; k < f->nodes[i].end; k++) {
		const bnode *n = &f->nodes[k];
		slot *sl = &s->s[k];
		if (n->kind == K_DO && sl->run && n->stop) n->stop(c->bot, &n->args);
		if (n->kind == K_PICK && ROLE(n) && !all) { sl->cur = 0; continue; }   /* a role drawn is kept */
		if (all || n->kind != K_COOLDOWN) sl->t = 0;
		sl->cur = 0;
		sl->run = 0;
	}
}

static float draw(const bt_ctx *c) { return c->random ? c->random(c->bot) : 0.5f; }

static float weight_of(const bt_ctx *c, int trait)
{
	if (trait >= 0 && c->weights && trait < c->n_weights) return c->weights[trait];
	return 1.0f;
}

static void note_worth(bt_state *s, int o, float score, float weight, double luck, double sticky)
{
	oslot w;
	w.score = score;
	w.weight = weight;
	w.luck = (float)luck;
	w.sticky = (float)sticky;
	memset(&s->s[o], 0, sizeof s->s[o]);
	memcpy(&s->s[o], &w, sizeof w);
}

static int pick_choose(const bt_forest *f, int i, bt_state *s, const bt_ctx *c)
{
	const bnode *n = &f->nodes[i];
	int o, best = -1;
	double bw = 0;
	for (o = i + 1; o < n->end; o = f->nodes[o].end) {
		const bnode *on = &f->nodes[o];
		float sc = on->score(c->bot, &on->args);
		double w, luck, held = 1.0;
		if (!(sc > 0)) {
			if (s->trace) note_worth(s, o, sc, weight_of(c, on->trait), 0.0, 1.0);
			continue;
		}
		luck = 1.0 + n->noise * (2.0 * draw(c) - 1.0);
		w = (double)sc * weight_of(c, on->trait) * on->factor * luck;
		if (s->s[i].cur == o + 1) { held = 1.0 + n->sticky; w *= held; }
		if (s->trace) note_worth(s, o, sc, weight_of(c, on->trait), luck, held);
		if (best < 0 || w > bw) { best = o; bw = w; }
	}
	return best;
}

/* A draw in [0, 1) that is this bot's for this pick, whenever asked:
 * a mix (splitmix64's) of the bot's identity and the pick's key. */
static double identity_draw(uint64_t identity, int32_t key)
{
	uint64_t z = identity + 0x9E3779B97F4A7C15ull * ((uint64_t)(uint32_t)key + 1u);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
	z ^= z >> 31;
	return (double)(z >> 11) / 9007199254740992.0;
}

/* THE LOTTERY of a pick that rolls: the option the draw `*u` lands on,
 * each having a share of [0, 1) in proportion to its worth -- score x
 * the bot's weight x factor, no luck, nothing for the one held. -1 when
 * no option has a score above 0. A `*u` below 0 is not drawn yet: it is
 * drawn from the bot's dice if there is something to draw from, and
 * written back. */
static int roll_choose(const bt_forest *f, int i, bt_state *s, const bt_ctx *c, double *u)
{
	const bnode *n = &f->nodes[i];
	double sum = 0, acc = 0;
	int o, last = -1;
	for (o = i + 1; o < n->end; o = f->nodes[o].end) {
		const bnode *on = &f->nodes[o];
		float sc = on->score(c->bot, &on->args);
		if (s->trace) note_worth(s, o, sc, weight_of(c, on->trait), *u < 0 ? 0.0 : *u, 1.0);
		if (sc > 0) { sum += (double)sc * weight_of(c, on->trait) * on->factor; last = o; }
	}
	if (last < 0 || !(sum > 0)) return -1;
	if (*u < 0) {
		*u = draw(c);
		if (s->trace)
			for (o = i + 1; o < n->end; o = f->nodes[o].end) {
				oslot w;
				memcpy(&w, &s->s[o], sizeof w);
				w.luck = (float)*u;
				memcpy(&s->s[o], &w, sizeof w);
			}
	}
	/* (the scores are asked a second time: once a choice, and they are facts) */
	for (o = i + 1; o < n->end; o = f->nodes[o].end) {
		const bnode *on = &f->nodes[o];
		float sc = on->score(c->bot, &on->args);
		if (!(sc > 0)) continue;
		acc += (double)sc * weight_of(c, on->trait) * on->factor;
		if (*u * sum < acc) return o;
	}
	return last;
}

static bt_status tick(const bt_forest *f, int i, bt_state *s, const bt_ctx *c)
{
	const bnode *n = &f->nodes[i];
	slot *sl = &s->s[i];
	bt_status r;
	int k;
	switch (n->kind) {
	case K_SEQ: case K_SELECT: {
		int seq = n->kind == K_SEQ;
		for (k = sl->cur ? sl->cur - 1 : i + 1; k < n->end; k = f->nodes[k].end) {
			r = tick(f, k, s, c);
			if (r == BT_RUNNING) { sl->cur = k + 1; return r; }
			if (seq && r != BT_SUCCESS) { sl->cur = 0; return BT_FAILURE; }
			if (!seq && r == BT_SUCCESS) { sl->cur = 0; return BT_SUCCESS; }
		}
		sl->cur = 0;
		return seq ? BT_SUCCESS : BT_FAILURE;
	}
	case K_PICK: {
		if (ROLE(n)) {
			/* a role: drawn at the first tick after a reset, then kept --
			 * the child is ticked again and again, whatever it answers.
			 * sl->run: the option held + 1; sl->t: the draw */
			if (!sl->run) {
				int best;
				double u;
				if (n->roll == BT_ROLL_ONCE && c->identity) sl->t = identity_draw(c->identity, n->trait);
				else if (sl->t >= 0) sl->t = -1.0 - (double)draw(c);   /* drawn once; kept as -(1 + u) */
				u = sl->t < 0 ? -sl->t - 1.0 : sl->t;
				best = roll_choose(f, i, s, c, &u);
				if (best < 0) return BT_FAILURE;                       /* nothing to draw yet: asked again */
				sl->run = best + 1;
			}
			r = tick(f, sl->run, s, c);
			sl->cur = r == BT_RUNNING ? sl->run : 0;
			return r;
		}
		if (sl->cur == 0 || s->now - sl->t >= n->every) {
			int best;
			if (n->roll == BT_ROLL_EACH) {
				double u = -1.0;
				best = roll_choose(f, i, s, c, &u);     /* a draw at every choice, from the bot's dice */
			} else best = pick_choose(f, i, s, c);
			/* (the option's child is stopped, not the option: its slot
			 * holds nothing but what pick_choose noted there) */
			if (best < 0) {
				if (sl->cur) stop_range(f, sl->cur, s, c, 0);
				sl->cur = 0;
				return BT_FAILURE;
			}
			if (sl->cur != best + 1) {
				if (sl->cur) stop_range(f, sl->cur, s, c, 0);
				sl->cur = best + 1;
			}
			sl->t = s->now;
		}
		r = tick(f, sl->cur, s, c);        /* the option's one child is at (option index + 1) */
		if (r != BT_RUNNING) sl->cur = 0;
		return r;
	}
	case K_IF:
		return n->cond(c->bot, &n->args) ? BT_SUCCESS : BT_FAILURE;
	case K_UNLESS:
		return n->cond(c->bot, &n->args) ? BT_FAILURE : BT_SUCCESS;
	case K_DO:
		r = n->action(c->bot, &n->args, c->dt);
		if (r != BT_SUCCESS && r != BT_RUNNING) r = BT_FAILURE;
		sl->run = r == BT_RUNNING;
		return r;
	case K_WAIT:
		if (!sl->run) { sl->run = 1; sl->t = s->now; }
		if (s->now - sl->t >= n->secs) { sl->run = 0; return BT_SUCCESS; }
		return BT_RUNNING;
	case K_INVERT:
		r = tick(f, i + 1, s, c);
		return r == BT_RUNNING ? r : r == BT_SUCCESS ? BT_FAILURE : BT_SUCCESS;
	case K_ALWAYS:
		r = tick(f, i + 1, s, c);
		return r == BT_RUNNING ? r : BT_SUCCESS;
	case K_NEVER:
		r = tick(f, i + 1, s, c);
		return r == BT_RUNNING ? r : BT_FAILURE;
	case K_COOLDOWN:
		if (s->now < sl->t) return BT_FAILURE;
		r = tick(f, i + 1, s, c);
		if (r != BT_RUNNING) sl->t = s->now + n->secs;
		return r;
	case K_LIMIT:
		if (!sl->run) { sl->run = 1; sl->t = s->now; }
		r = tick(f, i + 1, s, c);
		if (r != BT_RUNNING) { sl->run = 0; return r; }
		if (s->now - sl->t >= n->secs) {
			stop_range(f, i + 1, s, c, 0);
			sl->run = 0;
			return BT_FAILURE;
		}
		return BT_RUNNING;
	default:
		return BT_FAILURE;
	}
}

bt_status bt_tick(const bt_forest *f, int tree, bt_state *s, const bt_ctx *c)
{
	if (!f || !s || !c || tree < 0 || tree >= f->n_trees) return BT_FAILURE;
	if (c->dt > 0) s->now += c->dt;
	return tick(f, f->trees[tree].root, s, c);
}

void bt_reset(const bt_forest *f, bt_state *s, const bt_ctx *c)
{
	size_t k;
	uint32_t trace;
	for (k = 0; k < f->n_nodes; k++) {
		const bnode *n = &f->nodes[k];
		if (n->kind == K_DO && s->s[k].run && n->stop) n->stop(c->bot, &n->args);
	}
	trace = s->trace;
	bt_state_init(s, f);
	s->trace = trace;
}

void bt_restart(const bt_forest *f, bt_state *s, const bt_ctx *c)
{
	size_t k;
	for (k = 0; k < f->n_nodes; k++) {
		const bnode *n = &f->nodes[k];
		slot *sl = &s->s[k];
		if (n->kind == K_DO && sl->run && n->stop) n->stop(c->bot, &n->args);
		if (n->kind == K_PICK && ROLE(n)) { sl->cur = 0; continue; }   /* its role is its own still */
		memset(sl, 0, sizeof *sl);
	}
}

typedef struct app { char *out; size_t size, len; int any; } app;

static void append(app *a, const char *s)
{
	if (a->any) {
		static const char sep[] = " > ";
		size_t i;
		for (i = 0; sep[i] && a->len + 1 < a->size; i++) a->out[a->len++] = sep[i];
	}
	a->any = 1;
	while (*s && a->len + 1 < a->size) a->out[a->len++] = *s++;
	a->out[a->len] = 0;
}

size_t bt_describe(const bt_forest *f, const bt_state *s, char *out, size_t out_size)
{
	app a;
	int t;
	a.out = out; a.size = out_size; a.len = 0; a.any = 0;
	if (!out || !out_size) return 0;
	out[0] = 0;
	for (t = 0; t < f->n_trees; t++) {
		int i = f->trees[t].root;
		for (;;) {
			const bnode *n = &f->nodes[i];
			const slot *sl = &s->s[i];
			if (n->kind == K_SEQ || n->kind == K_SELECT) {
				if (!sl->cur) break;
				i = sl->cur - 1;
			} else if (n->kind == K_PICK) {
				char buf[BT_NAME_MAX + 8];
				if (!sl->cur) break;
				snprintf(buf, sizeof buf, "pick:%s", f->nodes[sl->cur - 1].trait_name);
				append(&a, buf);
				i = sl->cur;
			} else if (is_decor(n->kind)) {
				i = i + 1;
			} else {
				if (n->kind == K_DO && sl->run) append(&a, n->name);
				break;
			}
		}
	}
	return a.len;
}

/* ---- looking in: bt.h, "looking into a tree" and "watching a bot think" */

const char *bt_kind_name(int kind)
{
	return kind >= 0 && kind < (int)(sizeof kw / sizeof *kw) ? kw[kind] : NULL;
}

static void node_out(const snode *sn, bt_node *out)
{
	memset(out, 0, sizeof *out);
	out->kind = sn->kind;
	out->line = sn->line;
	out->column = sn->col;
	out->text = sn->text;
	out->name = sn->name;
	out->trait = sn->trait;
	out->args = sn->args;
	out->secs = sn->secs;
	out->every = sn->every;
	out->sticky = sn->sticky;
	out->noise = sn->noise;
	out->factor = sn->factor;
	out->written = sn->written;
	out->roll = sn->roll;
	out->comment = sn->note;
	out->above = sn->above;
	out->via = -1;
}

static void tree_out(const stree *st, bt_tree *out)
{
	out->name = st->name;
	out->root = st->first;
	out->line = st->line;
	out->header = st->header;
	out->comment = st->note;
	out->above = st->above;
}

int bt_source_trees(const bt_source *src) { return src ? src->n_trees : 0; }
int bt_source_nodes(const bt_source *src) { return src ? src->n_nodes : 0; }
const char *bt_source_tail(const bt_source *src) { return src ? src->tail : NULL; }

int bt_source_tree(const bt_source *src, int tree, bt_tree *out)
{
	if (!src || !out || tree < 0 || tree >= src->n_trees) return 0;
	tree_out(&src->trees[tree], out);
	return 1;
}

int bt_source_node(const bt_source *src, int id, bt_node *out)
{
	const snode *sn;
	if (!src || !out || id < 0 || id >= src->n_nodes) return 0;
	sn = &src->nodes[id];
	node_out(sn, out);
	out->id = id;
	out->source = id;
	out->tree = sn->tree;
	out->parent = sn->parent;
	out->first_child = id + 1 < sn->end ? id + 1 : -1;
	out->next_sibling = sn->parent >= 0 && sn->end < src->nodes[sn->parent].end ? sn->end : -1;
	out->n_children = sn->nchild;
	return 1;
}

typedef struct wr { char *out; size_t size, len; } wr;

static void put(wr *w, const char *s, size_t n)
{
	size_t i;
	for (i = 0; i < n; i++, w->len++)
		if (w->out && w->len + 1 < w->size) w->out[w->len] = s[i];
}

/* `above` lines, each behind `depth` tabs (an empty line stays empty) */
static void put_above(wr *w, const char *above, int depth)
{
	int k;
	while (above && *above) {
		const char *e = strchr(above, '\n');
		size_t n = e ? (size_t)(e - above) : strlen(above);
		if (n) for (k = 0; k < depth; k++) put(w, "\t", 1);
		put(w, above, n);
		put(w, "\n", 1);
		above += n + (e ? 1 : 0);
	}
}

/* one line: the words, and the comment at its column */
static void put_line(wr *w, int depth, const char *words, const char *colon, const char *note)
{
	enum { NOTE_COL = 46, TAB = 4 };
	int k, col = depth * TAB + (int)strlen(words) + (int)strlen(colon);
	for (k = 0; k < depth; k++) put(w, "\t", 1);
	put(w, words, strlen(words));
	put(w, colon, strlen(colon));
	if (note) {
		do { put(w, " ", 1); col++; } while (col < NOTE_COL);
		put(w, "# ", 2);
		put(w, note, strlen(note));
	}
	put(w, "\n", 1);
}

size_t bt_source_text(const bt_source *src, char *out, size_t out_size)
{
	wr w;
	int t, i;
	w.out = out_size ? out : NULL; w.size = out_size; w.len = 0;
	if (!src) { if (w.out) w.out[0] = 0; return 0; }
	for (t = 0; t < src->n_trees; t++) {
		const stree *st = &src->trees[t];
		if (st->header) {
			char head[BT_NAME_MAX + 8];
			snprintf(head, sizeof head, "tree %s", st->name);
			put_above(&w, st->above, 0);
			put_line(&w, 0, head, ":", st->note);
		}
		for (i = st->first; i < st->end; i++) {
			const snode *sn = &src->nodes[i];
			put_above(&w, sn->above, sn->depth);
			put_line(&w, sn->depth, sn->text, "", sn->note);
		}
	}
	put_above(&w, src->tail, 0);
	if (w.out) w.out[w.len < w.size ? w.len : w.size - 1] = 0;
	return w.len;
}

const bt_source *bt_forest_source(const bt_forest *f) { return f ? f->src : NULL; }
int bt_forest_trees(const bt_forest *f) { return f ? f->n_trees : 0; }

int bt_forest_tree(const bt_forest *f, int tree, bt_tree *out)
{
	if (!f || !out || tree < 0 || tree >= f->n_trees) return 0;
	tree_out(&f->src->trees[tree], out);
	out->root = f->trees[tree].root;
	return 1;
}

int bt_forest_node(const bt_forest *f, int i, bt_node *out)
{
	const bnode *b;
	const fmeta *m;
	int k;
	if (!f || !out || i < 0 || (size_t)i >= f->n_nodes) return 0;
	b = &f->nodes[i];
	m = &f->meta[i];
	node_out(&f->src->nodes[m->src], out);
	out->id = i;
	out->source = m->src;
	out->via = m->via;
	out->parent = m->parent;
	out->first_child = i + 1 < b->end ? i + 1 : -1;
	out->next_sibling = m->parent >= 0 && b->end < f->nodes[m->parent].end ? b->end : -1;
	for (k = i + 1; k < b->end; k = f->nodes[k].end) out->n_children++;
	for (k = f->n_trees - 1; k > 0 && f->trees[k].root > i; k--) ;
	out->tree = k;
	return 1;
}

void bt_state_trace(bt_state *s, int on) { if (s) s->trace = on ? 1 : 0; }

int bt_state_node(const bt_forest *f, const bt_state *s, int i, bt_node_state *out)
{
	const bnode *n;
	const slot *sl;
	double left = 0, since = 0;
	if (!f || !s || !out || i < 0 || (size_t)i >= f->n_nodes) return 0;
	n = &f->nodes[i];
	sl = &s->s[i];
	memset(out, 0, sizeof *out);
	out->child = -1;
	switch (n->kind) {
	case K_SEQ: case K_SELECT:
		out->running = sl->cur != 0;
		out->child = sl->cur - 1;
		break;
	case K_PICK:
		out->running = sl->cur != 0;
		if (ROLE(n)) { out->child = sl->run ? sl->run - 1 : -1; break; }      /* its role, RUNNING or not */
		out->child = sl->cur ? sl->cur - 1 : -1;
		if (sl->cur) { since = s->now - sl->t; left = n->every - since; }
		break;
	case K_DO:
		out->running = sl->run != 0;
		break;
	case K_WAIT: case K_LIMIT:
		out->running = sl->run != 0;
		if (sl->run) { since = s->now - sl->t; left = n->secs - since; }
		break;
	case K_COOLDOWN:
		left = sl->t - s->now;
		break;
	default:
		break;
	}
	out->elapsed = (float)since;
	out->remaining = left > 0 ? (float)left : 0.0f;
	return 1;
}

int bt_state_running(const bt_forest *f, const bt_state *s, int tree, int *out, int max)
{
	int path[2 * BT_DEPTH_MAX], n = 0, i, k;
	if (!f || !s || tree < 0 || tree >= f->n_trees) return 0;
	for (i = f->trees[tree].root; n < 2 * BT_DEPTH_MAX - 1;) {
		const bnode *b = &f->nodes[i];
		const slot *sl = &s->s[i];
		path[n++] = i;
		if (b->kind == K_SEQ || b->kind == K_SELECT) {
			if (!sl->cur) return 0;
			i = sl->cur - 1;
		} else if (b->kind == K_PICK) {
			if (!sl->cur) return 0;
			path[n++] = sl->cur - 1;
			i = sl->cur;
		} else if (b->kind == K_LIMIT) {
			if (!sl->run) return 0;
			i = i + 1;
		} else if (is_decor(b->kind)) {
			i = i + 1;
		} else {
			if (!sl->run) return 0;
			break;
		}
	}
	for (k = 0; out && k < n && k < max; k++) out[k] = path[k];
	return n;
}

int bt_state_worths(const bt_forest *f, const bt_state *s, int pick, bt_worth *out, int max)
{
	int o, n = 0, roll;
	double sum = 0;
	if (!f || !s || pick < 0 || (size_t)pick >= f->n_nodes || f->nodes[pick].kind != K_PICK) return 0;
	roll = f->nodes[pick].roll;
	for (o = pick + 1; o < f->nodes[pick].end; o = f->nodes[o].end, n++) {
		const bnode *on = &f->nodes[o];
		bt_worth *w;
		oslot rec;
		memcpy(&rec, &s->s[o], sizeof rec);
		if (roll && rec.sticky != 0.0f && rec.score > 0) sum += (double)rec.score * rec.weight * on->factor;
		if (!out || n >= max) continue;
		w = &out[n];
		memset(w, 0, sizeof *w);
		w->option = o;
		w->held = roll == BT_ROLL_ONCE || roll == BT_ROLL_LIFE ? s->s[pick].run == o + 1 : s->s[pick].cur == o + 1;
		w->factor = on->factor;
		if (rec.sticky == 0.0f) continue;
		w->weighed = 1;
		w->score = rec.score;
		w->weight = rec.weight;
		w->luck = roll ? 1.0f : rec.luck;
		w->draw = roll ? rec.luck : 0.0f;
		w->sticky = rec.sticky;
		w->worth = rec.score > 0 ? (float)((double)rec.score * rec.weight * on->factor * w->luck * rec.sticky) : 0.0f;
	}
	for (o = 0; roll && out && o < n && o < max; o++)
		out[o].share = sum > 0 ? (float)((double)out[o].worth / sum) : 0.0f;
	return n;
}
