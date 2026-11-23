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
 * Memory. bt_compile builds the forest in one block (temporary working
 * memory is freed before it returns). bt_tick and bt_describe allocate
 * nothing; bt_tick recurses at most BT_DEPTH_MAX deep.
 */
#include "bt.h"
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
} ventry;

struct bt_vocab { int n; ventry e[VOCAB_MAX]; };

bt_vocab *bt_vocab_new(void) { return calloc(1, sizeof(bt_vocab)); }
void bt_vocab_free(bt_vocab *v) { free(v); }

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

/* ---- the compiled forest -------------------------------------------- */

typedef struct bnode {
	uint8_t kind;
	int32_t end;            /* index one past this node's subtree */
	int32_t trait;          /* option: index into the weights */
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

struct bt_forest {
	size_t n_nodes;
	int n_trees;
	bnode *nodes;
	ftree *trees;
};

void bt_forest_free(bt_forest *f) { free(f); }
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
} pnode;

typedef struct ptree {
	char name[BT_NAME_MAX];
	int first, hline, base;
} ptree;

typedef struct tok { const char *s; size_t n; } tok;

typedef struct P {
	const bt_vocab *v;
	char *err;
	size_t errsz;
	int failed;
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
	int n;
	va_list ap;
	if (p->failed) return;
	p->failed = 1;
	if (!p->err || !p->errsz) return;
	n = snprintf(p->err, p->errsz, "line %d: ", line);
	if (n < 0 || (size_t)n >= p->errsz) return;
	va_start(ap, fmt);
	vsnprintf(p->err + n, p->errsz - (size_t)n, fmt, ap);
	va_end(ap);
}

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

static int set_args(P *p, bnode *b, const tok *t, int from, int to, int line)
{
	int i;
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
			if (!eq || kn == 0) { fail(p, line, "pick: expected key=value, got '%.*s'", (int)t[i].n, t[i].s); return 0; }
			vs = dups(p, eq + 1, t[i].n - kn - 1);
			if (!vs) return 0;
			if (!tonum(vs, &val) || val < 0) {
				fail(p, line, "pick: '%.*s' needs a number of 0 or more", (int)kn, t[i].s);
				return 0;
			}
			if (kn == 5 && !memcmp(t[i].s, "every", 5)) b->every = val;
			else if (kn == 6 && !memcmp(t[i].s, "sticky", 6)) b->sticky = val;
			else if (kn == 5 && !memcmp(t[i].s, "noise", 5)) {
				if (val > 1) { fail(p, line, "pick: noise must be between 0 and 1"); return 0; }
				b->noise = val;
			} else {
				fail(p, line, "pick: unknown setting '%.*s' (every, sticky, noise)", (int)kn, t[i].s);
				return 0;
			}
		}
		return 1;
	case K_OPTION: {
		int last = nt;
		const ventry *tr;
		if (nt < 3) { fail(p, line, "option needs a trait and a score: option <trait> <score> [x<factor>]"); return 0; }
		snprintf(nm, sizeof nm, "%.*s", (int)(t[1].n < BT_NAME_MAX ? t[1].n : BT_NAME_MAX - 1), t[1].s);
		tr = t[1].n < BT_NAME_MAX ? vfind(p->v, VK_TRAIT, nm) : NULL;
		if (!tr) { fail(p, line, "no trait called %.*s", (int)t[1].n, t[1].s); return 0; }
		b->trait = tr->trait;
		b->trait_name = dups(p, t[1].s, t[1].n);
		snprintf(nm, sizeof nm, "%.*s", (int)(t[2].n < BT_NAME_MAX ? t[2].n : BT_NAME_MAX - 1), t[2].s);
		e = t[2].n < BT_NAME_MAX ? vfind(p->v, VK_SCORE, nm) : NULL;
		if (!e) { fail(p, line, "no score called %.*s", (int)t[2].n, t[2].s); return 0; }
		b->score = e->score;
		b->name = dups(p, t[2].s, t[2].n);
		if (last > 3 && t[last - 1].s[0] == 'x') {      /* a trailing x<number> is the factor */
			char *fs = dups(p, t[last - 1].s + 1, t[last - 1].n - 1);
			float fv;
			if (fs && tonum(fs, &fv) && fv >= 0) { b->factor = fv; last--; }
		}
		return b->trait_name && b->name && set_args(p, b, t, 3, last, line);
	}
	case K_IF: case K_UNLESS: case K_DO:
		if (nt < 2) {
			fail(p, line, "'%s' needs %s name", kw[b->kind], b->kind == K_DO ? "an action" : "a condition");
			return 0;
		}
		snprintf(nm, sizeof nm, "%.*s", (int)(t[1].n < BT_NAME_MAX ? t[1].n : BT_NAME_MAX - 1), t[1].s);
		e = t[1].n < BT_NAME_MAX ? vfind(p->v, b->kind == K_DO ? VK_ACTION : VK_COND, nm) : NULL;
		if (!e) {
			fail(p, line, "no %s called %.*s", b->kind == K_DO ? "action" : "condition", (int)t[1].n, t[1].s);
			return 0;
		}
		b->cond = e->cond;
		b->action = e->action;
		b->stop = e->stop;
		b->name = dups(p, t[1].s, t[1].n);
		return b->name && set_args(p, b, t, 2, nt, line);
	case K_WAIT: case K_COOLDOWN: case K_LIMIT: {
		char *s;
		if (nt != 2) { fail(p, line, "'%s' takes one number of seconds", kw[b->kind]); return 0; }
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
	if ((size_t)tr->first == p->npn) { fail(p, tr->hline, "tree '%s' is empty", tr->name); return; }
	for (j = (size_t)tr->first; j < p->npn; j++) {
		pnode *pn = &p->pn[j];
		int kind = pn->n.kind;
		if (pn->nchild == 0 && (kind == K_SEQ || kind == K_SELECT || kind == K_PICK)) {
			fail(p, pn->n.line, "'%s' needs at least one child", kw[kind]);
			return;
		}
		if (pn->nchild == 0 && (is_decor(kind) || kind == K_OPTION)) {
			fail(p, pn->n.line, "'%s' needs a child", kw[kind]);
			return;
		}
	}
}

static void parse_line(P *p, const char *q, size_t len, int line)
{
	size_t i, nspace = 0, ntab = 0;
	tok t[TOKENS_MAX];
	int nt = 0, level = 0, rel, parent, header = 0;
	pnode pn;
	ptree *tr;

	for (i = 0; i < len; i++) if (q[i] == '#') { len = i; break; }
	while (len && (q[len - 1] == ' ' || q[len - 1] == '\t' || q[len - 1] == '\r')) len--;
	for (i = 0; i < len && (q[i] == ' ' || q[i] == '\t'); i++) {
		if (q[i] == ' ') nspace++; else ntab++;
	}
	if (i == len) return;            /* blank or comment */

	while (i < len) {
		while (i < len && (q[i] == ' ' || q[i] == '\t')) i++;
		if (i >= len) break;
		if (nt == TOKENS_MAX) { fail(p, line, "too many words on one line"); return; }
		t[nt].s = q + i;
		while (i < len && q[i] != ' ' && q[i] != '\t') i++;
		t[nt].n = (size_t)(q + i - t[nt].s);
		nt++;
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

	/* `tree name:` opens a tree; `tree name` is a node */
	if (tokeq(t[0], "tree") && nt >= 2) {
		tok name = t[1];
		if (name.s[name.n - 1] == ':' && nt == 2) { name.n--; header = 1; }
		else if (nt == 3 && tokeq(t[2], ":")) header = 1;
		else if (name.s[name.n - 1] == ':') { fail(p, line, "bad tree header"); return; }
		if (header) {
			if (level) { fail(p, line, "a tree header must not be indented"); return; }
			if (!valid_name(name)) { fail(p, line, "bad tree name '%.*s'", (int)name.n, name.s); return; }
			if (p->implicit) { fail(p, line, "this tree header comes after lines that belong to no tree"); return; }
			finish_tree(p);
			if (p->failed) return;
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
			return;
		}
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
	if (!fill_node(p, &pn, t, nt, line)) return;

	if ((size_t)tr->first == p->npn) {
		tr->base = level;
		rel = 0;
		p->sp = 0;
	} else {
		if (level < tr->base) { fail(p, line, "indented less than the tree's first node"); return; }
		rel = level - tr->base;
		if (rel == 0) { fail(p, line, "a tree has one root node; this is a second (indent it under the first?)"); return; }
	}
	if (rel > p->sp) { fail(p, line, "indented too deep: one level at a time"); return; }
	if (rel >= BT_DEPTH_MAX) { fail(p, line, "nested deeper than %d levels", BT_DEPTH_MAX); return; }
	parent = rel ? p->stack[rel - 1] : -1;
	if (parent >= 0) {
		const pnode *pp = &p->pn[parent];
		int pk = pp->n.kind;
		if (is_leaf(pk)) { fail(p, line, "'%s' takes no children", kw[pk]); return; }
		if (pk == K_PICK && pn.n.kind != K_OPTION) { fail(p, line, "a pick has only options"); return; }
		if (pn.n.kind == K_OPTION && pk != K_PICK) { fail(p, line, "an option belongs directly under a pick"); return; }
		if ((is_decor(pk) || pk == K_OPTION) && pp->nchild >= 1) {
			fail(p, line, "'%s' takes exactly one child", kw[pk]);
			return;
		}
	} else if (pn.n.kind == K_OPTION) {
		fail(p, line, "an option belongs directly under a pick");
		return;
	}
	p->pn = grow(p, p->pn, &p->cappn, p->npn + 1, sizeof *p->pn);
	if (p->failed) return;
	for (i = (size_t)rel; i < (size_t)p->sp; i++) p->pn[p->stack[i]].n.end = (int32_t)p->npn;
	pn.parent = parent;
	if (parent >= 0) p->pn[parent].nchild++;
	p->stack[rel] = (int)p->npn;
	p->sp = rel + 1;
	p->pn[p->npn++] = pn;
}

static int emit_node(P *p, int i, int depth)
{
	const pnode *pn = &p->pn[i];
	size_t me;
	int c;
	if (pn->n.kind == K_REF) {
		size_t k;
		int t = pn->ref, ok;
		for (k = 0; k < p->tsp; k++)
			if (p->tstack[k] == t) {
				fail(p, pn->n.line, "tree '%s' refers back to itself (a cycle of tree references)", p->pt[t].name);
				return 0;
			}
		p->tstack[p->tsp++] = t;
		ok = emit_node(p, p->pt[t].first, depth);
		p->tsp--;
		return ok;
	}
	if (depth >= BT_DEPTH_MAX) { fail(p, pn->n.line, "nested deeper than %d levels (tree references included)", BT_DEPTH_MAX); return 0; }
	if (p->nem >= NODES_MAX) { fail(p, pn->n.line, "the trees expand to too many nodes"); return 0; }
	p->em = grow(p, p->em, &p->capem, p->nem + 1, sizeof *p->em);
	if (p->failed) return 0;
	me = p->nem++;
	p->em[me] = pn->n;
	for (c = i + 1; c < pn->n.end; c = p->pn[c].n.end)
		if (!emit_node(p, c, depth + 1)) return 0;
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
	size = sizeof *f + p->nem * sizeof(bnode) + p->npt * sizeof(ftree) + strs;
	block = malloc(size);
	if (!block) { fail(p, 0, "out of memory"); return NULL; }
	f = (bt_forest *)block;
	f->n_nodes = p->nem;
	f->n_trees = (int)p->npt;
	f->nodes = (bnode *)(block + sizeof *f);
	f->trees = (ftree *)(block + sizeof *f + p->nem * sizeof(bnode));
	arena = block + sizeof *f + p->nem * sizeof(bnode) + p->npt * sizeof(ftree);
	for (i = 0; i < p->nem; i++) {
		bnode *b = &f->nodes[i];
		*b = p->em[i];
		if (b->name) { b->name = arena; sdup(&arena, p->em[i].name); }
		if (b->trait_name) { b->trait_name = arena; sdup(&arena, p->em[i].trait_name); }
		for (k = 0; k < (size_t)b->args.count; k++) { b->args.text[k] = arena; sdup(&arena, p->em[i].args.text[k]); }
	}
	return f;
}

bt_forest *bt_compile(const bt_vocab *v, const char *text, char *err, size_t err_size)
{
	P p;
	bt_forest *f = NULL;
	const char *q;
	int line = 0;
	size_t i;

	memset(&p, 0, sizeof p);
	p.v = v;
	p.err = err;
	p.errsz = err_size;
	if (err && err_size) err[0] = 0;
	if (!v || !text) { fail(&p, 1, "no vocabulary or no text"); goto done; }

	for (q = text; *q && !p.failed;) {
		const char *e = strchr(q, '\n');
		size_t len = e ? (size_t)(e - q) : strlen(q);
		parse_line(&p, q, len, ++line);
		q = e ? e + 1 : q + len;
	}
	if (!p.failed) finish_tree(&p);
	if (!p.failed && p.npt == 0) fail(&p, 1, "no tree in this text");

	for (i = 0; i < p.npn && !p.failed; i++) {      /* resolve references, all trees being read */
		size_t t;
		if (p.pn[i].n.kind != K_REF) continue;
		for (t = 0; t < p.npt; t++)
			if (strcmp(p.pt[t].name, p.pn[i].refname) == 0) { p.pn[i].ref = (int)t; break; }
		if (p.pn[i].ref < 0) fail(&p, p.pn[i].n.line, "no tree called %s", p.pn[i].refname);
	}

	if (!p.failed) {
		p.tstack = malloc((p.npt + 1) * sizeof *p.tstack);
		if (!p.tstack) fail(&p, 0, "out of memory");
	}
	for (i = 0; i < p.npt && !p.failed; i++) {      /* expand each tree, references inlined */
		p.tsp = 0;
		p.tstack[p.tsp++] = (int)i;
		p.pt[i].base = (int)p.nem;                 /* base reused: the root's index in the forest */
		emit_node(&p, p.pt[i].first, 0);
	}
	if (!p.failed) {
		f = build(&p);
		if (f)
			for (i = 0; i < p.npt; i++) {
				strcpy(f->trees[i].name, p.pt[i].name);
				f->trees[i].root = p.pt[i].base;
			}
	}
done:
	for (i = 0; i < p.npool; i++) free(p.pool[i]);
	free(p.pool); free(p.pn); free(p.pt); free(p.em); free(p.tstack);
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
	uint32_t pad_;
	slot s[];
};

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

static int pick_choose(const bt_forest *f, int i, const bt_state *s, const bt_ctx *c)
{
	const bnode *n = &f->nodes[i];
	int o, best = -1;
	double bw = 0;
	for (o = i + 1; o < n->end; o = f->nodes[o].end) {
		const bnode *on = &f->nodes[o];
		float sc = on->score(c->bot, &on->args);
		double w;
		if (!(sc > 0)) continue;
		w = (double)sc * weight_of(c, on->trait) * on->factor * (1.0 + n->noise * (2.0 * draw(c) - 1.0));
		if (s->s[i].cur == o + 1) w *= 1.0 + n->sticky;
		if (best < 0 || w > bw) { best = o; bw = w; }
	}
	return best;
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
		if (sl->cur == 0 || s->now - sl->t >= n->every) {
			int best = pick_choose(f, i, s, c);
			if (best < 0) {
				if (sl->cur) stop_range(f, sl->cur - 1, s, c, 0);
				sl->cur = 0;
				return BT_FAILURE;
			}
			if (sl->cur != best + 1) {
				if (sl->cur) stop_range(f, sl->cur - 1, s, c, 0);
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
	for (k = 0; k < f->n_nodes; k++) {
		const bnode *n = &f->nodes[k];
		if (n->kind == K_DO && s->s[k].run && n->stop) n->stop(c->bot, &n->args);
	}
	bt_state_init(s, f);
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
