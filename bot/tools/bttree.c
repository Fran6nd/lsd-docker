/* bttree.c -- Look at a behaviour tree, check it, tune it, hand it to an editor
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 *   bttree [options] FILE.bt...
 *
 * LOOKING
 *   (no option)       draw every tree of the files, `tree <name>` references
 *                     opened in place
 *   --tree NAME       that tree only (drawing, --split, --trace)
 *   --as ARCHETYPE    beside every weighed option, what that kind of bot's
 *                     weight for its trait is (the mean of 400 rolled bots):
 *                     camper, pusher, flanker, support, sapper, scout, soldier
 *   --plain           no colours, ASCII lines
 *   --words           list the vocabulary a tree may use, and exit
 *   --words --md      the same as a Markdown page (bot/VOCAB.md is this:
 *                     `make -C bot doc`)
 *
 * CHECKING
 *   --check           draw nothing: compile with the engine's own compiler and
 *                     vocabulary, say what is wrong and where, exit 1 if so
 *   --check --json    the same, as JSON: {"ok":, "diagnostics":[{"file":,
 *                     "line":, "column":, "message":}]}
 *   --doc FILE.md...  compile every fenced block of a Markdown file that
 *                     opens with ```bt, each as a text of its own (what
 *                     `make -C bot test` does to bot/TREES.md)
 *
 * TUNING
 *   --split [WORD=VALUE]...
 *                     who would do what. A situation is given as
 *                     the worth of the words the tree asks about, a crowd
 *                     of bots is rolled (--n 700, --mix "camper:2,pusher",
 *                     --level 5), the tree is ticked once for each by the
 *                     engine's own bt_tick, and what each ended up doing is
 *                     counted, in all and by kind of bot:
 *                         bttree --split --tree tdm_search trees/tdm.bt \
 *                             rumour=0.6 flank_open=1 "vantage rifle=1"
 *                     A word not given is 0 (a condition false, a score 0;
 *                     `always` is 1). A score takes 0 to 1, a condition
 *                     0 or 1, an action `run` (the default: it is what the
 *                     bot is then doing), `ok` (done at once, the tree goes
 *                     on) or `fail`. "word arg=..." sets it for those
 *                     arguments only. The words asked and not given are
 *                     listed after, so nothing is 0 by oversight.
 *   --split --why     and, for every pick a bot came to, what its options
 *                     were worth to the crowd: the mean score, trait weight
 *                     and worth, and how many chose each
 *   --trace [WORD=VALUE]...
 *                     ONE bot (--as ARCHETYPE, --seed N, --level 5) in that
 *                     situation, ticked for --secs S (default: one tick),
 *                     and its tree drawn as the engine holds it: the nodes
 *                     RUNNING marked, every option with the numbers its
 *                     pick multiplied. What a debugger would show.
 *   --trace --json    the same as JSON (the forest's node ids, each node's
 *                     state, each option's worth)
 *
 * FOR AN EDITOR  (bot/TREES.md, "For tool authors")
 *   --json            the files as a JSON tree: every node with its id,
 *                     kind, words, numbers (those left to their default
 *                     marked), comments, line and column
 *   --json --expanded and the forest the engine would run: every reference
 *                     opened, each node naming the one it was written as
 *   --from-json FILE  such a JSON (FILE, or - for the standard input) back
 *                     to tree text, in the canonical form
 *   --format          the files as canonical text (what --from-json writes
 *                     for --json's output)
 *   --schema          everything a tree may be made of, as JSON: the node
 *                     kinds and their numbers, every condition, score and
 *                     action with its arguments, the traits, the
 *                     archetypes and their mean weights, the places
 *   --roundtrip       check that each file survives text -> JSON -> text
 *                     and compiles to the same forest either way
 *
 * A tree is always compiled first (as --check does), so what is drawn is
 * a tree the engine accepts. Nothing here reads the text but the engine's
 * own parser (bot/core/bt.h, bt_parse): the drawing, the JSON and the
 * canonical text are made from what it read.
 * `tree items` and `tree extras` are filled in at run time -- by the
 * inventory's items and by server scripts -- and are drawn as such.
 */
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bt.h"
#include "persona.h"
#include "rng.h"
#include "vocab.h"

enum { MAX_TEXT = 1 << 20, MAX_FILES = 64, MAX_OPEN = 16 };

static int plain, colour;
static const char *as_name;
static float as_weight[BC_T_COUNT];

static const char *c(const char *code) { return colour ? code : ""; }
#define DIM c("\033[2m")
#define BOLD c("\033[1m")
#define KEY c("\033[36m")
#define ACT c("\033[32m")
#define ASK c("\033[33m")
#define OFF c("\033[0m")

static char *slurp(const char *path, size_t *len)
{
	FILE *f = !strcmp(path, "-") ? stdin : fopen(path, "rb");
	if (!f) return NULL;
	char *buf = malloc(MAX_TEXT + 1);
	size_t n = buf ? fread(buf, 1, MAX_TEXT, f) : 0;
	if (f != stdin) fclose(f);
	if (!buf) return NULL;
	buf[n] = 0;
	if (len) *len = n;
	return buf;
}

static char *vocab_text(void)
{
	size_t need = bc_vocab_dump(NULL, 0);
	char *buf = malloc(need + 1);
	if (buf) bc_vocab_dump(buf, need + 1);
	return buf;
}

/* the shortest writing of a number that reads back as the same float */
static const char *num(double v)
{
	static char buf[8][32];
	static int k;
	char *b = buf[k++ & 7];
	for (int pass = 0; pass < 2; pass++)           /* "100" rather than "1e+02", if it can be */
		for (int p = 1; p <= 9; p++) {
			snprintf(b, 32, "%.*g", p, v);
			if ((float)strtod(b, NULL) == (float)v && (pass || !strchr(b, 'e'))) return b;
		}
	return b;
}

/* ---- the files ---------------------------------------------------------
 * Each is read by the engine's parser alone (a mistake is told with its
 * own line), then all as one text, as botd gives them to the engine. */

typedef struct file {
	const char *path;
	char *text;
	bt_source *src;
	int first_line;            /* its first line's number in the whole text */
	int first_node;            /* and its first node's id in the whole source */
} file;

static file files[MAX_FILES];
static int n_files;
static char *full;                 /* every file, then what the engine would add */
static int stub_line, stub_node;   /* where that begins */
static bt_source *whole;           /* every file as one source, not linked */
static bt_forest *forest;          /* `full`, compiled with the engine's words */

typedef struct diag { const char *file; int line, column; char message[280]; } diag;
enum { MAX_DIAGS = 200, DIAGS_A_FILE = 50 };
static diag diags[MAX_DIAGS];
static int n_diags;

static void add_diag(const char *file, const bt_diag *d, const char *prefix)
{
	diag *g;
	if (n_diags == MAX_DIAGS) return;
	g = &diags[n_diags++];
	g->file = file;
	g->line = d->line;
	g->column = d->column;
	snprintf(g->message, sizeof g->message, "%s%s", prefix, d->message);
}

/* a line of the whole text -> its file and its line there */
static int where_line(int line, int *local)
{
	int i = n_files - 1;
	if (line >= stub_line) { if (local) *local = line - stub_line + 1; return -1; }
	while (i > 0 && files[i].first_line > line) i--;
	if (local) *local = line - files[i].first_line + 1;
	return i;
}

/* a node of the whole source -> its file and its id there */
static int where_node(int id, int *local)
{
	int i = n_files - 1;
	if (id >= stub_node) { if (local) *local = id - stub_node; return -1; }
	while (i > 0 && files[i].first_node > id) i--;
	if (local) *local = id - files[i].first_node;
	return i;
}

static int has_tree(const bt_source *src, const char *name)
{
	bt_tree t;
	for (int i = 0; bt_source_tree(src, i, &t); i++)
		if (!strcmp(t.name, name)) return i;
	return -1;
}

/* What the engine writes at run time (`items`, `extras`), empty here
 * unless the text has them: added to `text`, in its own indentation.
 * A text with no header at all is first made the tree "main"; returns
 * how many lines were put before it. */
static const char *const STUB[2] = { "items", "extras" };

static int add_stubs(char *text, const bt_source *src)
{
	const char *step = "\t";
	bt_tree t;
	int shifted = 0;
	for (const char *q = text; q && *q; q = strchr(q, '\n'), q = q ? q + 1 : NULL) {
		size_t w = strspn(q, " \t");
		if (w && q[w] && q[w] != '#' && q[w] != '\n' && q[w] != '\r') {
			if (q[0] == ' ') step = w == 2 ? "  " : "    ";
			break;
		}
	}
	if (bt_source_tree(src, 0, &t) && !t.header) {
		memmove(text + 11, text, strlen(text) + 1);
		memcpy(text, "tree main:\n", 11);
		shifted = 1;
	}
	for (int k = 0; k < 2; k++)
		if (has_tree(src, STUB[k]) < 0)
			sprintf(text + strlen(text), "\ntree %s:\nnever\n%sif enemy_visible\n", STUB[k], step);
	return shifted;
}

static int load(const bt_vocab *v, char **paths, int n)
{
	size_t used = 0;
	int line = 1, node = 0;
	full = malloc((size_t)n * (MAX_TEXT + 2) + 256);
	if (!full) return 0;
	full[0] = 0;
	for (int i = 0; i < n; i++) {
		file *f = &files[n_files++];
		size_t len;
		bt_diag d, ds[DIAGS_A_FILE];
		f->path = paths[i];
		f->text = slurp(paths[i], &len);
		if (!f->text) {
			memset(&d, 0, sizeof d);
			snprintf(d.message, sizeof d.message, "cannot read it");
			add_diag(f->path, &d, "");
			continue;
		}
		int nd = bt_diagnose(v, f->text, 0, ds, DIAGS_A_FILE);     /* every mistake, not the first */
		for (int k = 0; k < nd; k++) add_diag(f->path, &ds[k], "");
		f->src = nd ? NULL : bt_parse(v, f->text, &d);
		f->first_line = line;
		f->first_node = node;
		memcpy(full + used, f->text, len);
		used += len;
		full[used++] = '\n';
		full[used] = 0;
		for (size_t k = 0; k < len; k++) line += f->text[k] == '\n';
		line++;
		node += bt_source_nodes(f->src);
	}
	stub_line = line;
	stub_node = node;
	if (n_diags) return 0;

	/* together: a tree defined twice, one named and nowhere, a circle */
	bt_diag d;
	whole = bt_parse(v, full, &d);
	int shifted = 0;
	if (whole) {
		shifted = add_stubs(full, whole);
		for (int i = 0; i < n_files; i++) files[i].first_line += shifted;
		stub_line += shifted;
		forest = bt_compile_diag(v, full, &d);
	}
	if (!forest) {
		bt_diag ds[DIAGS_A_FILE];
		int nd = whole ? bt_diagnose(v, full, 1, ds, DIAGS_A_FILE) : 0;
		if (!nd) { ds[0] = d; nd = 1; }
		for (int k = 0; k < nd; k++) {
			int local, i = where_line(ds[k].line, &local);
			ds[k].line = local;
			add_diag(i >= 0 ? files[i].path : "(bttree)", &ds[k], n > 1 ? "with the other files: " : "");
		}
		return 0;
	}
	return 1;
}

/* ---- JSON, written ------------------------------------------------------ */

static void jstrn(FILE *o, const char *s, size_t n)
{
	fputc('"', o);
	for (; s && n && *s; s++, n--) {
		unsigned char ch = (unsigned char)*s;
		if (ch == '"' || ch == '\\') fprintf(o, "\\%c", ch);
		else if (ch == '\n') fputs("\\n", o);
		else if (ch == '\t') fputs("\\t", o);
		else if (ch == '\r') fputs("\\r", o);
		else if (ch < 0x20) fprintf(o, "\\u%04x", ch);
		else fputc(ch, o);
	}
	fputc('"', o);
}

static void jstr(FILE *o, const char *s) { jstrn(o, s, s ? strlen(s) : 0); }

static void jkey(FILE *o, const char *k) { jstr(o, k); fputs(": ", o); }
static void jkv(FILE *o, const char *k, const char *v) { jkey(o, k); jstr(o, v); }
static void jpad(FILE *o, int n) { fputc('\n', o); while (n-- > 0) fputs("  ", o); }

/* `above` (lines, each ended by a newline) as an array of lines */
static void jlines(FILE *o, const char *above)
{
	fputc('[', o);
	for (int n = 0; above && *above; n++) {
		const char *e = strchr(above, '\n');
		size_t len = e ? (size_t)(e - above) : strlen(above);
		if (n) fputs(", ", o);
		jstrn(o, above, len);
		above += len + (e ? 1 : 0);
	}
	fputc(']', o);
}

/* ---- JSON, read: a small one, for --from-json --------------------------- */

typedef struct jv {
	char type;                 /* n(ull) t f # (number) s a o */
	double number;
	char *text;                /* s: the string; a member's value: its key */
	char *key;
	struct jv *kids, *next;
} jv;

typedef struct jr { const char *s; int bad; } jr;

static void jskip(jr *r) { while (*r->s == ' ' || *r->s == '\n' || *r->s == '\t' || *r->s == '\r') r->s++; }

static char *jread_str(jr *r)
{
	const char *q = r->s + 1;
	char *out = malloc(strlen(q) + 1), *w = out;
	while (out && *q && *q != '"') {
		if (*q != '\\') { *w++ = *q++; continue; }
		q++;
		switch (*q) {
		case 'n': *w++ = '\n'; break;
		case 't': *w++ = '\t'; break;
		case 'r': *w++ = '\r'; break;
		case 'b': *w++ = '\b'; break;
		case 'f': *w++ = '\f'; break;
		case 'u': {
			unsigned u = 0;
			for (int k = 1; k <= 4 && isxdigit((unsigned char)q[k]); k++) {
				u = u * 16 + (unsigned)(isdigit((unsigned char)q[k]) ? q[k] - '0' : tolower((unsigned char)q[k]) - 'a' + 10);
				if (k == 4) q += 4;
			}
			if (u < 0x80) *w++ = (char)u;
			else if (u < 0x800) { *w++ = (char)(0xC0 | (u >> 6)); *w++ = (char)(0x80 | (u & 0x3F)); }
			else { *w++ = (char)(0xE0 | (u >> 12)); *w++ = (char)(0x80 | ((u >> 6) & 0x3F)); *w++ = (char)(0x80 | (u & 0x3F)); }
			break;
		}
		case 0: continue;
		default: *w++ = *q;
		}
		q++;
	}
	if (!out || *q != '"') { r->bad = 1; free(out); return NULL; }
	*w = 0;
	r->s = q + 1;
	return out;
}

static jv *jread(jr *r, int depth)
{
	jv *v = calloc(1, sizeof *v), **tail;
	if (!v || depth > 200) { r->bad = 1; return v; }
	jskip(r);
	tail = &v->kids;
	if (*r->s == '{' || *r->s == '[') {
		char close = *r->s == '{' ? '}' : ']';
		v->type = *r->s == '{' ? 'o' : 'a';
		r->s++;
		jskip(r);
		while (!r->bad && *r->s != close) {
			char *key = NULL;
			if (v->type == 'o') {
				if (*r->s != '"') { r->bad = 1; break; }
				key = jread_str(r);
				jskip(r);
				if (r->bad || *r->s != ':') { r->bad = 1; free(key); break; }
				r->s++;
			}
			*tail = jread(r, depth + 1);
			if (*tail) { (*tail)->key = key; tail = &(*tail)->next; }
			jskip(r);
			if (*r->s == ',') { r->s++; jskip(r); }
			else if (*r->s != close) r->bad = 1;
		}
		if (!r->bad) r->s++;
	} else if (*r->s == '"') {
		v->type = 's';
		v->text = jread_str(r);
	} else if (!strncmp(r->s, "null", 4)) { v->type = 'n'; r->s += 4; }
	else if (!strncmp(r->s, "true", 4)) { v->type = 't'; r->s += 4; }
	else if (!strncmp(r->s, "false", 5)) { v->type = 'f'; r->s += 5; }
	else {
		char *end;
		v->type = '#';
		v->number = strtod(r->s, &end);
		if (end == r->s) r->bad = 1;
		r->s = end;
	}
	return v;
}

static const jv *jget(const jv *o, const char *key)
{
	for (const jv *k = o && o->type == 'o' ? o->kids : NULL; k; k = k->next)
		if (k->key && !strcmp(k->key, key)) return k;
	return NULL;
}

static const char *jtext(const jv *o, const char *key)
{
	const jv *v = jget(o, key);
	return v && v->type == 's' ? v->text : NULL;
}

/* ---- the vocabulary, as data --------------------------------------------
 * Nothing of it is kept here: the words and their arguments are vocab.c's
 * table (bc_vocab_word), the places skill_misc.c's (bc_place_at), the
 * traits and archetypes persona.c's. */


/* an argument's type as the schema says it */
static const char *arg_type(const bt_arg_spec *a)
{
	if (a->type == BT_ARG_NUMBER) return "number";
	if (a->type == BT_ARG_TEXT) return "text";
	return a->set && !a->values ? a->set : "enum";
}

/* the mean trait weights of 400 bots of one archetype */
static void archetype_means(int a, float *mean)
{
	float w[BC_A_COUNT] = {0};
	w[a] = 1;
	memset(mean, 0, BC_T_COUNT * sizeof *mean);
	for (int k = 0; k < 400; k++) {
		bc_rng r; bc_persona p;
		bc_rng_seed(&r, 1000 + (uint64_t)k, 7);
		bc_persona_roll(&p, &r, w, 5);
		for (int t = 0; t < BC_T_COUNT; t++) mean[t] += p.trait[t] / 400.0f;
	}
}

/* The node kinds. `children`: none, one, many, or options (a pick's). */
typedef struct kparam { const char *name, *type, *form; int required; double def, min, max; const char *doc; } kparam;
typedef struct kindspec { const char *name, *children, *answers, *doc; kparam p[3]; } kindspec;
#define NOMAX 1e30
static const kindspec KINDS[BT_K_COUNT] = {
	{ "seq", "many", "FAILURE at the first child that fails, RUNNING while one is, SUCCESS when all have succeeded",
	  "its children in order; resumes at the child that was RUNNING", {{0}} },
	{ "select", "many", "the answer of the first child that does not fail; FAILURE when all fail",
	  "its children in order, the first that does not fail: a priority list; resumes at the child that was RUNNING", {{0}} },
	{ "pick", "options", "the answer of the option chosen; FAILURE when no option has a score above 0",
	  "a weighed choice among its options: the one worth most to this bot (score x trait weight x factor x luck) is ticked",
	  { { "every", "number", "every=<secs>", 0, 2, 0, NOMAX, "seconds between two choices; it also chooses again whenever the option chosen ends" },
	    { "sticky", "number", "sticky=<x>", 0, 0.25, 0, NOMAX, "the option being done is worth this much more, as a fraction of its own worth" },
	    { "noise", "number", "noise=<x>", 0, 0.1, 0, 1, "luck: each option's worth is multiplied by a draw within 1 +- this" } } },
	{ "option", "one", "its child's",
	  "one choice of a pick: `option <trait> <score> [score's arguments] [x<factor>]`, only directly under a pick",
	  { { "trait", "trait", "<trait>", 1, 0, 0, 0, "whose character weighs it: the bot's weight for this trait multiplies the score" },
	    { "score", "score", "<score> [args]", 1, 0, 0, 0, "what bears on it: a score of the vocabulary, 0 to 1; at 0 the option cannot be chosen" },
	    { "factor", "number", "x<factor>", 0, 1, 0, NOMAX, "the designer's thumb on the scale" } } },
	{ "if", "none", "SUCCESS if the condition holds, else FAILURE", "a condition of the vocabulary, with its arguments",
	  { { "cond", "cond", "<cond> [args]", 1, 0, 0, 0, "the condition" } } },
	{ "unless", "none", "FAILURE if the condition holds, else SUCCESS", "a condition, the other way round",
	  { { "cond", "cond", "<cond> [args]", 1, 0, 0, 0, "the condition" } } },
	{ "do", "none", "the action's: RUNNING while it goes on, SUCCESS or FAILURE when it ends",
	  "an action of the vocabulary, with its arguments; stopped (told once) if its branch is abandoned while it is RUNNING",
	  { { "action", "action", "<action> [args]", 1, 0, 0, 0, "the action" } } },
	{ "wait", "none", "RUNNING for that long, then SUCCESS", "let time pass",
	  { { "seconds", "number", "<secs>", 1, 0, 0, NOMAX, "how long, from the first tick that reaches it" } } },
	{ "invert", "one", "its child's turned: SUCCESS for FAILURE, FAILURE for SUCCESS; RUNNING stays", "turn the child's answer round", {{0}} },
	{ "always", "one", "SUCCESS whatever the child answers; RUNNING stays", "do the child and go on whatever came of it", {{0}} },
	{ "never", "one", "FAILURE whatever the child answers; RUNNING stays", "do the child and fail whatever came of it", {{0}} },
	{ "cooldown", "one", "its child's; then FAILURE, without asking the child, for that long after the child ended",
	  "not more often than this",
	  { { "seconds", "number", "<secs>", 1, 0, 0, NOMAX, "how long after the child answers SUCCESS or FAILURE" } } },
	{ "limit", "one", "its child's; FAILURE if the child is still RUNNING after that long (the child is stopped)",
	  "not longer than this",
	  { { "seconds", "number", "<secs>", 1, 0, 0, NOMAX, "how long the child may stay RUNNING" } } },
	{ "tree", "none", "the answer of the tree named", "another tree by name, as if written here; `items` and `extras` are written by the engine",
	  { { "ref", "tree", "<name>", 1, 0, 0, 0, "the tree's name" } } },
};

static void json_list(FILE *o, const char *list)
{
	fputc('[', o);
	for (int n = 0; list && *list; n++) {
		size_t len = strcspn(list, "|");
		if (n) fputs(", ", o);
		jstrn(o, list, len);
		list += len + (list[len] == '|');
	}
	fputc(']', o);
}

static void schema_args(FILE *o, const bc_word *w, int pad)
{
	fputs("[", o);
	for (int i = 0; i < w->n_args; i++) {
		const bt_arg_spec *a = &w->args[i];
		if (i) fputc(',', o);
		jpad(o, pad);
		fputs("{", o);
		jkv(o, "name", a->name);
		fprintf(o, ", \"required\": %s, ", a->required ? "true" : "false");
		jkv(o, "type", arg_type(a));
		if (a->values) { fputs(", \"values\": ", o); json_list(o, a->values); }
		if (a->values && a->set) { fputs(", \"or\": ", o); jstr(o, a->set); }
		if (a->repeat) fputs(", \"repeat\": true", o);
		if (a->has_min) fprintf(o, ", \"min\": %s", num(a->min));
		if (a->has_max) fprintf(o, ", \"max\": %s", num(a->max));
		if (a->has_default) fprintf(o, ", \"default\": %s", num(a->def));
		if (a->def_text) { fputs(", \"default\": ", o); jstr(o, a->def_text); }
		if (a->def_note) { fputs(", ", o); jkv(o, "default_note", a->def_note); }
		fputs("}", o);
	}
	if (w->n_args) jpad(o, pad - 1);
	fputs("]", o);
}

static void schema_words(FILE *o, const char *key, int kind)
{
	bc_word w;
	jpad(o, 1); jkey(o, key); fputs("[", o);
	for (int i = 0, n = 0; bc_vocab_word(i, &w); i++) {
		char usage[128];
		if (w.kind != kind) continue;
		bc_vocab_usage(i, usage, sizeof usage);
		if (n++) fputc(',', o);
		jpad(o, 2); fputs("{", o);
		jkv(o, "name", w.name); fputs(", ", o);
		jkv(o, "usage", usage); fputs(",", o);
		jpad(o, 3); jkey(o, "args"); schema_args(o, &w, 5); fputs(",", o);
		jpad(o, 3); jkv(o, "doc", w.doc);
		jpad(o, 2); fputs("}", o);
	}
	jpad(o, 1); fputs("]", o);
}

static int schema(FILE *o)
{
	float lo, hi;
	bc_trait_range(&lo, &hi);
	fputs("{", o);
	jpad(o, 1); fputs("\"format\": \"lsd-bt-schema\", \"version\": 2,", o);
	jpad(o, 1); fprintf(o, "\"limits\": {\"args\": %d, \"name\": %d, \"depth\": %d, \"words_a_line\": 16},", BT_ARGS_MAX, BT_NAME_MAX - 1, BT_DEPTH_MAX);
	jpad(o, 1); fputs("\"answers\": [\"SUCCESS\", \"FAILURE\", \"RUNNING\"],", o);
	jpad(o, 1); fputs("\"kinds\": [", o);
	for (int k = 0; k < BT_K_COUNT; k++) {
		const kindspec *s = &KINDS[k];
		if (k) fputc(',', o);
		jpad(o, 2); fputs("{", o);
		jkv(o, "name", s->name); fputs(", ", o);
		jkv(o, "children", s->children);
		if (k == BT_K_OPTION) fputs(", \"parent\": \"pick\"", o);
		fputs(",", o);
		jpad(o, 3); jkey(o, "params"); fputs("[", o);
		for (int i = 0; i < 3 && s->p[i].name; i++) {
			const kparam *p = &s->p[i];
			if (i) fputc(',', o);
			jpad(o, 4); fputs("{", o);
			jkv(o, "name", p->name); fputs(", ", o);
			jkv(o, "type", p->type); fputs(", ", o);
			jkv(o, "written", p->form);
			fprintf(o, ", \"required\": %s", p->required ? "true" : "false");
			if (!strcmp(p->type, "number")) {
				if (!p->required) fprintf(o, ", \"default\": %s", num(p->def));
				fprintf(o, ", \"min\": %s", num(p->min));
				if (p->max < NOMAX) fprintf(o, ", \"max\": %s", num(p->max));
			}
			fputs(", ", o); jkv(o, "doc", p->doc);
			fputs("}", o);
		}
		if (s->p[0].name) jpad(o, 3);
		fputs("],", o);
		jpad(o, 3); jkv(o, "answers", s->answers); fputs(",", o);
		jpad(o, 3); jkv(o, "doc", s->doc);
		jpad(o, 2); fputs("}", o);
	}
	jpad(o, 1); fputs("],", o);
	schema_words(o, "conditions", BT_WORD_COND); fputs(",", o);
	schema_words(o, "scores", BT_WORD_SCORE); fputs(",", o);
	schema_words(o, "actions", BT_WORD_ACTION); fputs(",", o);
	jpad(o, 1); fputs("\"traits\": [", o);
	for (int t = 0; t < BC_T_COUNT; t++) {
		if (t) fputc(',', o);
		jpad(o, 2); fputs("{", o); jkv(o, "name", bc_trait_name(t)); fputs(", ", o); jkv(o, "doc", bc_trait_doc(t)); fputs("}", o);
	}
	jpad(o, 1); fputs("],", o);
	jpad(o, 1); fprintf(o, "\"trait_range\": [%s, %s],", num(lo), num(hi));
	jpad(o, 1); fputs("\"archetypes\": [", o);
	for (int a = 0; a < BC_A_COUNT; a++) {
		if (a) fputc(',', o);
		jpad(o, 2); fputs("{", o); jkv(o, "name", bc_archetype_name(a)); fputs(", ", o);
		jkv(o, "doc", bc_archetype_doc(a));
		for (int pass = 0; pass < 2; pass++) {
			jpad(o, 3); fputs(pass ? "\"spread\": {" : "\"weights\": {", o);
			for (int t = 0; t < BC_T_COUNT; t++) {
				float c, sp;
				bc_archetype_trait(a, t, &c, &sp);
				if (t) fputs(", ", o);
				jkey(o, bc_trait_name(t)); fputs(num(pass ? sp : c), o);
			}
			fputs(pass ? "}" : "},", o);
		}
		fputs("}", o);
	}
	jpad(o, 1); fputs("],", o);
	jpad(o, 1); fputs("\"places\": [", o);
	for (int i = 0; i < bc_place_count(); i++) {
		const char *name, *alias, *doc;
		bc_place_at(i, &name, &alias, &doc);
		if (i) fputc(',', o);
		jpad(o, 2); fputs("{", o); jkv(o, "name", name);
		if (alias) { fputs(", ", o); jkv(o, "alias", alias); }
		fputs(", ", o); jkv(o, "doc", doc); fputs("}", o);
	}
	jpad(o, 1); fputs("]", o);
	fputs("\n}\n", o);
	return 0;
}

/* --words --md: the vocabulary as a page (bot/VOCAB.md) */
static int words_md(FILE *o)
{
	static const char *const title[3][2] = {
		{ "Conditions", "For `if` and `unless`: true or false." },
		{ "Scores", "For `option <trait> <score>`: 0 to 1, how much the situation calls for the option. At 0 the option cannot be chosen." },
		{ "Actions", "For `do`. Each says what it answers: RUNNING while it goes on, SUCCESS or FAILURE when it ends." },
	};
	bc_word w;
	float lo, hi;
	bc_trait_range(&lo, &hi);
	fputs("# The words a behaviour tree may use\n\n"
	      "<!-- GENERATED by `make -C bot doc` (bttree --words --md) from the tables of bot/core/vocab.c,\n"
	      "     skill_misc.c (places) and persona.c. Do not edit: `make -C bot test` fails when it is stale. -->\n\n"
	      "How a tree is written, and what it does with these words: [TREES.md](TREES.md).\n\n"
	      "An argument in `<angle brackets>` must be given, one in `[square brackets]` may be;\n"
	      "`a|b|c` is one of those words; `...` is any number more. Under a word that takes\n"
	      "arguments, each is said: what it is, and what leaving it out means. The compiler checks\n"
	      "them: a word where a number goes, a number out of its range, a place or a word that is\n"
	      "not one of those allowed, one argument too many or too few is a mistake, said with its\n"
	      "line and column.\n", o);
	for (int k = 0; k < 3; k++) {
		fprintf(o, "\n## %s\n\n%s\n\n", title[k][0], title[k][1]);
		for (int i = 0; bc_vocab_word(i, &w); i++) {
			char usage[128];
			if (w.kind != k) continue;
			bc_vocab_usage(i, usage, sizeof usage);
			fprintf(o, "- **`%s%s%s`** -- %s\n", w.name, usage[0] ? " " : "", usage, w.doc);
			for (int j = 0; j < w.n_args; j++) {
				const bt_arg_spec *a = &w.args[j];
				fprintf(o, "  - `%s`: ", a->name);
				if (a->type == BT_ARG_NUMBER) fputs("a number", o);
				else if (a->type == BT_ARG_TEXT) fputs("a word", o);
				else if (a->values && a->set) fprintf(o, "`%s`, or a [%s](#%ss)", a->values, a->set, a->set);
				else if (a->set) fprintf(o, "a [%s](#%ss)", a->set, a->set);
				else fprintf(o, "one of `%s`", a->values);
				if (a->has_min && a->has_max) fprintf(o, ", %s to %s", num(a->min), num(a->max));
				if (a->repeat) fputs("; may be given several times", o);
				if (a->required) fputs("; must be given", o);
				else if (a->has_default && a->def_note) fprintf(o, "; left out: %s (%s)", num(a->def), a->def_note);
				else if (a->has_default) fprintf(o, "; left out: %s", num(a->def));
				else if (a->def_text) fprintf(o, "; left out: `%s`", a->def_text);
				else if (a->def_note) fprintf(o, "; left out: %s", a->def_note);
				fputs("\n", o);
			}
		}
	}
	fprintf(o, "\n## Traits\n\nFor `option <trait> ...`: the bot's own weight for the trait multiplies the option's score.\n"
	      "A weight is rolled once a bot, around its archetype's centre, and kept between %s and %s.\n\n", num(lo), num(hi));
	for (int t = 0; t < BC_T_COUNT; t++) fprintf(o, "- **`%s`** -- %s\n", bc_trait_name(t), bc_trait_doc(t));
	fputs("\n## Archetypes\n\nThe kinds of bot a character is drawn from.\n\n", o);
	for (int a = 0; a < BC_A_COUNT; a++) fprintf(o, "- **`%s`** -- %s\n", bc_archetype_name(a), bc_archetype_doc(a));
	fputs("\nThe centre each draws a trait around (`none` is always 1); the draw is a normal one about it,\n"
	      "with the spread in brackets:\n\n| |", o);
	for (int t = 1; t < BC_T_COUNT; t++) fprintf(o, " %s |", bc_trait_name(t));
	fputs("\n|---|", o);
	for (int t = 1; t < BC_T_COUNT; t++) fputs("---|", o);
	fputs("\n", o);
	for (int a = 0; a < BC_A_COUNT; a++) {
		fprintf(o, "| **%s** |", bc_archetype_name(a));
		for (int t = 1; t < BC_T_COUNT; t++) {
			float c, sp;
			bc_archetype_trait(a, t, &c, &sp);
			fprintf(o, " %s (%s) |", num(c), num(sp));
		}
		fputs("\n", o);
	}
	fputs("\n## Places\n\nFor an argument that is a place. A place may not exist just now (no noise heard, no intel\n"
	      "on this map): the word that was given it then says so by its answer.\n\n", o);
	for (int i = 0; i < bc_place_count(); i++) {
		const char *name, *alias, *doc;
		bc_place_at(i, &name, &alias, &doc);
		fprintf(o, "- **`%s`**", name);
		if (alias) fprintf(o, " (or `%s`)", alias);
		fprintf(o, " -- %s\n", doc);
	}
	return 0;
}

/* ---- --json: the source as an editor reads it --------------------------- */

static void json_node(FILE *o, const bt_source *src, int id, int pad)
{
	bt_node n;
	bt_source_node(src, id, &n);
	jpad(o, pad);
	fprintf(o, "{\"id\": %d, ", id);
	jkv(o, "kind", bt_kind_name(n.kind));
	fprintf(o, ", \"line\": %d, \"column\": %d, ", n.line, n.column);
	jkv(o, "text", n.text);
	switch (n.kind) {
	case BT_K_PICK: {
		static const struct { const char *name; unsigned bit; } S[3] = {
			{ "every", BT_W_EVERY }, { "sticky", BT_W_STICKY }, { "noise", BT_W_NOISE } };
		int some = 0;
		fprintf(o, ", \"every\": %s, \"sticky\": %s, \"noise\": %s, \"defaults\": [", num(n.every), num(n.sticky), num(n.noise));
		for (int k = 0; k < 3; k++)
			if (!(n.written & S[k].bit)) { if (some++) fputs(", ", o); jstr(o, S[k].name); }
		fputc(']', o);
		break;
	}
	case BT_K_OPTION:
		fputs(", ", o); jkv(o, "trait", n.trait);
		fputs(", ", o); jkv(o, "score", n.name);
		break;
	case BT_K_IF: case BT_K_UNLESS: fputs(", ", o); jkv(o, "cond", n.name); break;
	case BT_K_DO: fputs(", ", o); jkv(o, "action", n.name); break;
	case BT_K_WAIT: case BT_K_COOLDOWN: case BT_K_LIMIT: fprintf(o, ", \"seconds\": %s", num(n.secs)); break;
	case BT_K_TREE:
		fputs(", ", o); jkv(o, "ref", n.name);
		break;
	default: break;
	}
	if (n.kind == BT_K_OPTION || n.kind == BT_K_IF || n.kind == BT_K_UNLESS || n.kind == BT_K_DO) {
		fputs(", \"args\": [", o);
		for (int k = 0; k < n.args.count; k++) { if (k) fputs(", ", o); jstr(o, n.args.text[k]); }
		fputc(']', o);
	}
	if (n.kind == BT_K_OPTION)
		fprintf(o, ", \"factor\": %s, \"defaults\": [%s]", num(n.factor), n.written & BT_W_FACTOR ? "" : "\"factor\"");
	if (n.comment) { fputs(", ", o); jkv(o, "comment", n.comment); }
	if (n.above) { fputs(", ", o); jkey(o, "above"); jlines(o, n.above); }
	if (n.first_child >= 0) {
		fputs(", \"children\": [", o);
		for (int k = n.first_child; k >= 0;) {
			bt_node ch;
			json_node(o, src, k, pad + 1);
			bt_source_node(src, k, &ch);
			k = ch.next_sibling;
			if (k >= 0) fputc(',', o);
		}
		jpad(o, pad);
		fputc(']', o);
	}
	fputc('}', o);
}

static void json_file(FILE *o, const char *path, const bt_source *src, int pad)
{
	bt_tree t;
	jpad(o, pad); fputs("{", o);
	if (path) { jkv(o, "file", path); fputs(", ", o); }
	fputs("\"trees\": [", o);
	for (int i = 0; bt_source_tree(src, i, &t); i++) {
		if (i) fputc(',', o);
		jpad(o, pad + 1); fputs("{", o);
		jkv(o, "name", t.name);
		fprintf(o, ", \"line\": %d, \"header\": %s", t.line, t.header ? "true" : "false");
		if (t.comment) { fputs(", ", o); jkv(o, "comment", t.comment); }
		if (t.above) { fputs(", ", o); jkey(o, "above"); jlines(o, t.above); }
		fputs(", \"root\":", o);
		json_node(o, src, t.root, pad + 2);
		jpad(o, pad + 1); fputs("}", o);
	}
	jpad(o, pad); fputs("]", o);
	if (bt_source_tail(src)) { fputs(", ", o); jkey(o, "tail"); jlines(o, bt_source_tail(src)); }
	fputs("}", o);
}

/* the forest: what a debugger's node ids are ids of */
static void json_forest(FILE *o)
{
	bt_tree t;
	bt_node n;
	fputs(",\n  \"forest\": {\"trees\": [", o);
	for (int i = 0; bt_forest_tree(forest, i, &t); i++) {
		if (i) fputs(", ", o);
		fputs("{", o); jkv(o, "name", t.name); fprintf(o, ", \"root\": %d}", t.root);
	}
	fputs("],\n    \"nodes\": [", o);
	for (int i = 0; bt_forest_node(forest, i, &n); i++) {
		int local, f = where_node(n.source, &local);
		if (i) fputc(',', o);
		fprintf(o, "\n      {\"id\": %d, \"parent\": %d, \"tree\": %d, \"file\": %d, \"source\": %d", i, n.parent, n.tree, f, local);
		if (n.via >= 0) {
			f = where_node(n.via, &local);
			fprintf(o, ", \"via\": {\"file\": %d, \"source\": %d}", f, local);
		}
		fputs(", ", o); jkv(o, "kind", bt_kind_name(n.kind));
		fputs(", ", o); jkv(o, "text", n.text);
		fputc('}', o);
	}
	fputs("\n    ]}", o);
}

static void json_all(FILE *o, int expanded)
{
	fputs("{\"format\": \"lsd-bt\", \"version\": 1,\n  \"files\": [", o);
	for (int i = 0; i < n_files; i++) {
		if (i) fputc(',', o);
		json_file(o, files[i].path, files[i].src, 2);
	}
	fputs("\n  ]", o);
	if (expanded) json_forest(o);
	fputs("\n}\n", o);
}

/* ---- --from-json: an editor's tree, back to text ------------------------
 * The words of each node are put together from its fields ("text" is not
 * read: it is what the node WAS), one node a line under its parent; then
 * the engine's parser reads that and writes it back, which is what makes
 * it canonical -- and refuses it, with the reason, if it is not a tree. */

typedef struct sb { char *s; size_t n, cap; } sb;

static void sput(sb *b, const char *s)
{
	size_t n = strlen(s);
	if (b->n + n + 1 > b->cap) {
		b->cap = (b->cap + n + 1) * 2;
		b->s = realloc(b->s, b->cap);
		if (!b->s) { fprintf(stderr, "bttree: out of memory\n"); exit(1); }
	}
	memcpy(b->s + b->n, s, n + 1);
	b->n += n;
}

static void sput_above(sb *b, const jv *above, int depth)
{
	for (const jv *l = above && above->type == 'a' ? above->kids : NULL; l; l = l->next) {
		const char *s = l->type == 's' ? l->text : "";
		while (*s == ' ' || *s == '\t') s++;
		if (*s) {
			for (int k = 0; k < depth; k++) sput(b, "\t");
			if (*s != '#') sput(b, "# ");
			for (; *s; s++) { char one[2] = { *s == '\n' ? ' ' : *s, 0 }; sput(b, one); }
		}
		sput(b, "\n");
	}
}

static void sput_comment(sb *b, const jv *o)
{
	const char *cm = jtext(o, "comment");
	if (!cm || !*cm) return;
	sput(b, " # ");
	for (; *cm; cm++) { char one[2] = { *cm == '\n' ? ' ' : *cm, 0 }; sput(b, one); }
}

/* a number a node carries, written unless it is listed as left to its
 * default and still is that */
static int is_default(const jv *node, const char *key, double def)
{
	const jv *v = jget(node, key), *d = jget(node, "defaults");
	if (!v || v->type != '#') return 1;
	for (const jv *k = d && d->type == 'a' ? d->kids : NULL; k; k = k->next)
		if (k->type == 's' && !strcmp(k->text, key)) return (float)v->number == (float)def;
	return 0;
}

static int json_err;

static void sput_node(sb *b, const jv *node, int depth)
{
	const char *kind = jtext(node, "kind");
	const jv *v;
	if (!kind) { fprintf(stderr, "bttree: --from-json: a node without a \"kind\"\n"); json_err = 1; return; }
	sput_above(b, jget(node, "above"), depth);
	for (int k = 0; k < depth; k++) sput(b, "\t");
	sput(b, kind);
	if (!strcmp(kind, "pick")) {
		static const struct { const char *name; double def; } S[3] = { { "every", 2 }, { "sticky", 0.25 }, { "noise", 0.1 } };
		for (int k = 0; k < 3; k++)
			if (!is_default(node, S[k].name, S[k].def)) {
				sput(b, " "); sput(b, S[k].name); sput(b, "="); sput(b, num(jget(node, S[k].name)->number));
			}
	} else if (!strcmp(kind, "option")) {
		sput(b, " "); sput(b, jtext(node, "trait") ? jtext(node, "trait") : "?");
		sput(b, " "); sput(b, jtext(node, "score") ? jtext(node, "score") : "?");
	} else if (!strcmp(kind, "if") || !strcmp(kind, "unless")) {
		sput(b, " "); sput(b, jtext(node, "cond") ? jtext(node, "cond") : "?");
	} else if (!strcmp(kind, "do")) {
		sput(b, " "); sput(b, jtext(node, "action") ? jtext(node, "action") : "?");
	} else if (!strcmp(kind, "wait") || !strcmp(kind, "cooldown") || !strcmp(kind, "limit")) {
		v = jget(node, "seconds");
		sput(b, " "); sput(b, v && v->type == '#' ? num(v->number) : "?");
	} else if (!strcmp(kind, "tree")) {
		sput(b, " "); sput(b, jtext(node, "ref") ? jtext(node, "ref") : "?");
	}
	v = jget(node, "args");
	for (const jv *a = v && v->type == 'a' ? v->kids : NULL; a; a = a->next) {
		sput(b, " ");
		sput(b, a->type == 's' ? a->text : a->type == '#' ? num(a->number) : "?");
	}
	if (!strcmp(kind, "option") && !is_default(node, "factor", 1)) { sput(b, " x"); sput(b, num(jget(node, "factor")->number)); }
	sput_comment(b, node);
	sput(b, "\n");
	v = jget(node, "children");
	for (const jv *ch = v && v->type == 'a' ? v->kids : NULL; ch; ch = ch->next) sput_node(b, ch, depth + 1);
}

/* one file of the JSON -> canonical text on `out`. 0 if it is not a tree. */
static int text_of_json(const bt_vocab *v, const jv *file, FILE *out)
{
	sb b = {0};
	const jv *trees = jget(file, "trees");
	sput(&b, "");
	for (const jv *t = trees && trees->type == 'a' ? trees->kids : NULL; t; t = t->next) {
		const jv *header = jget(t, "header"), *root = jget(t, "root");
		sput_above(&b, jget(t, "above"), 0);
		if (!header || header->type != 'f') {
			sput(&b, "tree "); sput(&b, jtext(t, "name") ? jtext(t, "name") : "?"); sput(&b, ":");
			sput_comment(&b, t);
			sput(&b, "\n");
		}
		if (root && root->type == 'o') sput_node(&b, root, 0);
	}
	sput_above(&b, jget(file, "tail"), 0);
	if (json_err) { free(b.s); return 0; }

	bt_diag d;
	bt_source *src = bt_parse(v, b.s, &d);
	if (!src) {
		const char *l = b.s;
		for (int k = 1; k < d.line && l; k++) { l = strchr(l, '\n'); if (l) l++; }
		fprintf(stderr, "bttree: --from-json: %s\n  in: %.*s\n", d.message, l ? (int)strcspn(l, "\n") : 0, l ? l : "");
		free(b.s);
		return 0;
	}
	size_t n = bt_source_text(src, NULL, 0);
	char *text = malloc(n + 1);
	if (text) { bt_source_text(src, text, n + 1); fputs(text, out); }
	free(text); free(b.s);
	bt_source_free(src);
	return 1;
}

static void jfree(jv *v)
{
	while (v) {
		jv *next = v->next;
		jfree(v->kids);
		free(v->text); free(v->key); free(v);
		v = next;
	}
}

static int from_json_text(const bt_vocab *v, const char *json, FILE *out)
{
	jr r = { json, 0 };
	jv *doc = jread(&r, 0);
	int ok = 1;
	jskip(&r);
	if (r.bad || *r.s || !doc || doc->type != 'o') {
		fprintf(stderr, "bttree: --from-json: not JSON (near character %d)\n", (int)(r.s - json));
		jfree(doc);
		return 0;
	}
	const jv *fl = jget(doc, "files");
	if (fl && fl->type == 'a') {
		for (const jv *f = fl->kids; f && ok; f = f->next) ok = text_of_json(v, f, out);
	} else if (jget(doc, "trees")) {
		ok = text_of_json(v, doc, out);
	} else {
		fprintf(stderr, "bttree: --from-json: neither \"files\" nor \"trees\" in it\n");
		ok = 0;
	}
	jfree(doc);
	return ok;
}

static char *canonical(const bt_source *src)
{
	size_t n = bt_source_text(src, NULL, 0);
	char *text = malloc(n + 1);
	if (text) bt_source_text(src, text, n + 1);
	return text;
}

static char *slurp_tmp(FILE *t)
{
	long n = ftell(t);
	char *s = malloc((size_t)n + 1);
	rewind(t);
	if (s) s[fread(s, 1, (size_t)n, t)] = 0;
	fclose(t);
	return s;
}

/* text -> JSON -> text, and the forest of what came back */
static int roundtrip(const bt_vocab *v)
{
	int bad = 0, nodes = 0, same_bytes = 0;
	for (int i = 0; i < n_files; i++) {
		char *want = canonical(files[i].src), *json, *got;
		FILE *t = tmpfile(), *u = tmpfile();
		if (!want || !t || !u) { fprintf(stderr, "bttree: no memory or no temporary file\n"); return 1; }
		fputs("{\"files\": [", t);
		json_file(t, files[i].path, files[i].src, 1);
		fputs("]}\n", t);
		json = slurp_tmp(t);
		if (!from_json_text(v, json, u)) { fclose(u); bad = 1; free(want); free(json); continue; }
		got = slurp_tmp(u);
		if (strcmp(want, got)) {
			fprintf(stderr, "%s: comes back from JSON as another text\n", files[i].path);
			bad = 1;
		}
		/* and what was written reads back as the same tree, comments and all */
		bt_source *again = bt_parse(v, got, NULL);
		int same = again && bt_source_nodes(again) == bt_source_nodes(files[i].src);
		for (int k = 0; same && k < bt_source_nodes(again); k++) {
			bt_node a, b;
			bt_source_node(files[i].src, k, &a); bt_source_node(again, k, &b);
			same = a.kind == b.kind && a.parent == b.parent && !strcmp(a.text, b.text) && !a.comment == !b.comment &&
			       (!a.comment || !strcmp(a.comment, b.comment)) && !a.above == !b.above && (!a.above || !strcmp(a.above, b.above));
		}
		if (!same) { fprintf(stderr, "%s: written back, it reads as another tree\n", files[i].path); bad = 1; }
		nodes += bt_source_nodes(files[i].src);
		same_bytes += !strcmp(files[i].text, got);
		bt_source_free(again);
		free(want); free(json); free(got);
	}
	if (!bad)
		printf("ok: %d file(s), %d nodes: text -> JSON -> text gives the canonical text, which reads as the same tree; "
		       "%d already canonical byte for byte\n", n_files, nodes, same_bytes);
	return bad;
}

/* ---- the drawing, from the source --------------------------------------- */

static void node_words(const bt_node *n)
{
	const char *kind = bt_kind_name(n->kind), *rest = n->text + strlen(kind);
	switch (n->kind) {
	case BT_K_DO:
		printf("%sdo%s %s%s%s", ACT, OFF, BOLD, rest + 1, OFF);
		break;
	case BT_K_IF: case BT_K_UNLESS:
		printf("%s%s%s%s", ASK, kind, OFF, rest);
		break;
	case BT_K_OPTION: {
		const char *after = rest + 1 + strlen(n->trait);
		printf("%soption%s %s%s%s%s", KEY, OFF, BOLD, n->trait, OFF, after);
		int t = bc_trait_by_name(n->trait);
		if (as_name && t > 0)
			printf("  %s[%s weighs %s %.2f]%s", DIM, as_name, n->trait, (double)as_weight[t], OFF);
		break;
	}
	default:
		printf("%s%s%s%s", KEY, kind, OFF, rest);
	}
}

static void draw_node(const bt_source *src, int id, const char *prefix, int last, int *open, int n_open)
{
	bt_node n;
	bt_source_node(src, id, &n);
	const char *tee = plain ? (last ? "`- " : "|- ") : (last ? "└─ " : "├─ ");
	const char *bar = plain ? (last ? "   " : "|  ") : (last ? "   " : "│  ");
	const char *end = plain ? "`- " : "└─ ";

	printf("%s%s%s%s", DIM, prefix, tee, OFF);
	node_words(&n);
	if (n.comment) printf("  %s# %s%s", DIM, n.comment, OFF);
	printf("\n");

	char deeper[1024];
	snprintf(deeper, sizeof deeper, "%s%s", prefix, bar);

	if (n.kind == BT_K_TREE) {              /* a reference: open it in place */
		int t = has_tree(src, n.name), seen = 0;
		for (int k = 0; k < n_open; k++) if (open[k] == t) seen = 1;
		if (t < 0)
			printf("%s%s%s(filled in at run time: %s)%s\n", DIM, deeper, end,
				!strcmp(n.name, "items") ? "each inventory item's own rule"
				: !strcmp(n.name, "extras") ? "what server scripts bring, e.g. night"
				: "sent by the server", OFF);
		else if (seen || n_open == MAX_OPEN)
			printf("%s%s%s(again: %s)%s\n", DIM, deeper, end, n.name, OFF);
		else {
			bt_tree tr;
			bt_source_tree(src, t, &tr);
			open[n_open] = t;
			draw_node(src, tr.root, deeper, 1, open, n_open + 1);
		}
	}
	for (int k = n.first_child; k >= 0;) {
		bt_node ch;
		bt_source_node(src, k, &ch);
		draw_node(src, k, deeper, ch.next_sibling < 0, open, n_open);
		k = ch.next_sibling;
	}
}

static int draw_all(const bt_source *src, const char *only)
{
	int open[MAX_OPEN], drawn = 0;
	bt_tree t;
	for (int i = 0; bt_source_tree(src, i, &t); i++) {
		if (only && strcmp(only, t.name)) continue;
		if (drawn++) printf("\n");
		printf("%s%s%s\n", BOLD, t.name, OFF);
		open[0] = i;
		draw_node(src, t.root, "", 1, open, 1);
	}
	if (only && !drawn) { fprintf(stderr, "bttree: no tree called %s\n", only); return 1; }
	return 0;
}

/* ---- --split and --trace: the tree ticked in a situation that is given -- */

enum { MAX_WORDS = 160, MAX_SET = 128, MAX_OUT = 64 };

static struct { char name[BT_NAME_MAX]; } words_[3 * MAX_WORDS];
static int n_words[3];                          /* cond, score, action */
static struct { char key[96]; char val[32]; int used; } set_[MAX_SET];
static int n_set;
static char asked[256][96];
static int n_asked;
static int quiet_ask;                           /* an action is not a question */

static const char *word_name(int kind, int i) { return words_[kind * MAX_WORDS + i].name; }

/* What was given for this word with these arguments: "name a b" first,
 * then "name"; NULL if neither (and it is noted as asked). */
static const char *given(const char *name, const bt_args *args)
{
	char key[96];
	size_t n = (size_t)snprintf(key, sizeof key, "%s", name);
	for (int i = 0; args && i < args->count && n < sizeof key; i++)
		n += (size_t)snprintf(key + n, sizeof key - n, " %s", args->text[i]);
	for (int pass = 0; pass < 2; pass++) {
		const char *k = pass ? name : key;
		for (int i = 0; i < n_set; i++)
			if (!strcmp(set_[i].key, k)) { set_[i].used = 1; return set_[i].val; }
	}
	if (quiet_ask) return NULL;
	for (int i = 0; i < n_asked; i++)
		if (!strcmp(asked[i], key)) return NULL;
	if (n_asked < 256) snprintf(asked[n_asked++], sizeof asked[0], "%s", key);
	return NULL;
}

static float worth(const char *name, const bt_args *args)
{
	const char *v = given(name, args);
	if (!v) return !strcmp(name, "always") ? 1.0f : 0.0f;
	if (!strcmp(v, "yes") || !strcmp(v, "true")) return 1.0f;
	return (float)atof(v);
}

static int split_cond(int i, const bt_args *a) { return worth(word_name(0, i), a) > 0.0f; }
static float split_score(int i, const bt_args *a) { return worth(word_name(1, i), a); }
static bt_status split_action(int i, const bt_args *a)
{
	quiet_ask = 1;
	const char *v = given(word_name(2, i), a);
	quiet_ask = 0;
	if (v && !strcmp(v, "ok")) return BT_SUCCESS;
	if (v && !strcmp(v, "fail")) return BT_FAILURE;
	return BT_RUNNING;
}

/* A leaf is given the bot and its arguments, not its name: so one
 * function a word, MAX_WORDS of each kind, written by the preprocessor. */
#define LEAF(i) \
	static int cf##i(void *b, const bt_args *a) { (void)b; return split_cond(i, a); } \
	static float sf##i(void *b, const bt_args *a) { (void)b; return split_score(i, a); } \
	static bt_status af##i(void *b, const bt_args *a, float dt) { (void)b; (void)dt; return split_action(i, a); }
#define L10(t) LEAF(t##0) LEAF(t##1) LEAF(t##2) LEAF(t##3) LEAF(t##4) LEAF(t##5) LEAF(t##6) LEAF(t##7) LEAF(t##8) LEAF(t##9)
LEAF(0) LEAF(1) LEAF(2) LEAF(3) LEAF(4) LEAF(5) LEAF(6) LEAF(7) LEAF(8) LEAF(9)
L10(1) L10(2) L10(3) L10(4) L10(5) L10(6) L10(7) L10(8) L10(9) L10(10) L10(11) L10(12) L10(13) L10(14) L10(15)
#define P(i) {cf##i, sf##i, af##i},
#define P10(t) P(t##0) P(t##1) P(t##2) P(t##3) P(t##4) P(t##5) P(t##6) P(t##7) P(t##8) P(t##9)
static const struct { bt_cond_fn c; bt_score_fn s; bt_action_fn a; } leaf[MAX_WORDS] = {
	P(0) P(1) P(2) P(3) P(4) P(5) P(6) P(7) P(8) P(9)
	P10(1) P10(2) P10(3) P10(4) P10(5) P10(6) P10(7) P10(8) P10(9) P10(10) P10(11) P10(12) P10(13) P10(14) P10(15)
};

static float split_random(void *bot) { return bc_rng_float((bc_rng *)bot); }

/* The engine's words, each bound to a leaf that answers from what was
 * given. The names come from the engine's own table (bc_vocab_word). */
static bt_vocab *split_vocab(void)
{
	bt_vocab *v = bt_vocab_new();
	bc_word w;
	if (!v) return NULL;
	for (int n = 0; bc_vocab_word(n, &w); n++) {
		int k = w.kind;
		if (n_words[k] == MAX_WORDS) continue;
		int i = n_words[k]++;
		snprintf(words_[k * MAX_WORDS + i].name, BT_NAME_MAX, "%s", w.name);
		if (k == BT_WORD_COND) bt_vocab_cond(v, w.name, leaf[i].c);
		else if (k == BT_WORD_SCORE) bt_vocab_score(v, w.name, leaf[i].s);
		else bt_vocab_action(v, w.name, leaf[i].a, NULL);
	}
	for (int t = 0; t < BC_T_COUNT; t++) bt_vocab_trait(v, bc_trait_name(t), t);
	return v;
}

/* `full` compiled with those words, and the tree asked for */
static bt_forest *split_forest(const char *only, int *tree, bt_vocab **vp)
{
	bt_vocab *v = split_vocab();
	bt_diag d;
	bt_forest *f = v ? bt_compile_diag(v, full, &d) : NULL;
	if (!f) { fprintf(stderr, "bttree: %s\n", v ? d.message : "no vocabulary"); return NULL; }
	*tree = only ? bt_forest_find(f, only) : 0;
	if (*tree < 0) { fprintf(stderr, "bttree: no tree called %s\n", only); return NULL; }
	*vp = v;
	return f;
}

static void say_unasked(void)
{
	int head = 0;
	for (int i = 0; i < n_asked; i++) {
		if (!strcmp(asked[i], "always")) continue;
		printf("%s%s%s", head++ ? ", " : "asked and not given (so 0): ", DIM, asked[i]);
		printf("%s", OFF);
	}
	if (head) printf("\n");
	for (int i = 0; i < n_set; i++)
		if (!set_[i].used) printf("given but never asked: %s\n", set_[i].key);
}

/* "tdm.bt line 12", for a node of the forest */
static const char *where_text(const bt_node *n)
{
	static char buf[300];
	int local, f = where_line(n->line, &local);
	const char *base = f >= 0 ? strrchr(files[f].path, '/') : NULL;
	snprintf(buf, sizeof buf, "%s line %d", f < 0 ? "(the engine's)" : base ? base + 1 : files[f].path, local);
	return buf;
}

typedef struct outcome { char what[256]; int by[BC_A_COUNT]; int all; } outcome;
typedef struct why { int bots, chosen; double score, weight, worth; } why;

static int by_count(const void *a, const void *b) { return ((const outcome *)b)->all - ((const outcome *)a)->all; }

static int split(const char *only, int n, const char *mix, int level, int with_why)
{
	int tree;
	bt_vocab *v;
	bt_forest *f = split_forest(only, &tree, &v);
	if (!f) return 1;

	float mixw[BC_A_COUNT];
	if (!bc_archetype_weights(mix ? mix : "", mixw)) { fprintf(stderr, "bttree: --mix %s?\n", mix); return 1; }

	static outcome out[MAX_OUT];
	int n_out = 0, crowd[BC_A_COUNT] = {0}, nodes = (int)bt_forest_nodes(f);
	bt_state *st = malloc(bt_state_size(f));
	why *ws = calloc((size_t)nodes, sizeof *ws);
	if (!st || !ws) return 1;
	for (int k = 0; k < n; k++) {
		bc_rng r; bc_persona p;
		bc_rng_seed(&r, 4242 + (uint64_t)k, 11);
		bc_persona_roll(&p, &r, mixw, level);
		bt_ctx ctx = {&r, p.trait, BC_T_COUNT, 0.1f, split_random};
		bt_state_init(st, f);
		bt_state_trace(st, with_why);
		bt_status res = bt_tick(f, tree, st, &ctx);
		char what[256];
		if (res == BT_RUNNING) bt_describe(f, st, what, sizeof what);
		else snprintf(what, sizeof what, res == BT_SUCCESS ? "(done at once)" : "(nothing: the tree failed)");
		int o = 0;
		while (o < n_out && strcmp(out[o].what, what)) o++;
		if (o == MAX_OUT) o = MAX_OUT - 1;
		else if (o == n_out) { snprintf(out[o].what, sizeof out[o].what, "%s", what); n_out++; }
		out[o].all++; out[o].by[p.archetype]++; crowd[p.archetype]++;
		for (int i = 0; with_why && i < nodes; i++) {       /* every pick that weighed its options */
			bt_worth w[64];
			int m = bt_state_worths(f, st, i, w, 64);
			for (int j = 0; j < m && j < 64; j++) {
				if (!w[j].weighed) continue;
				why *y = &ws[w[j].option];
				y->bots++;
				y->chosen += w[j].held;
				y->score += w[j].score; y->weight += w[j].weight; y->worth += w[j].worth;
			}
		}
		bt_reset(f, st, &ctx);
	}
	qsort(out, (size_t)n_out, sizeof out[0], by_count);       /* most chosen first */

	printf("%s%d bots, level %d, tree %s%s\n", BOLD, n, level, only ? only : "(the first)", OFF);
	printf("%6s", "all");
	for (int a = 0; a < BC_A_COUNT; a++) if (crowd[a]) printf(" %7.7s", bc_archetype_name(a));
	printf("\n");
	for (int o = 0; o < n_out; o++) {
		printf("%5.1f%%", 100.0 * out[o].all / n);
		for (int a = 0; a < BC_A_COUNT; a++) if (crowd[a]) printf(" %6.0f%%", 100.0 * out[o].by[a] / crowd[a]);
		printf("  %s%s%s\n", BOLD, out[o].what, OFF);
	}
	for (int i = 0; with_why && i < nodes; i++) {
		bt_node pk, on, ch;
		bt_forest_node(f, i, &pk);
		if (pk.kind != BT_K_PICK || !ws[pk.first_child].bots) continue;
		printf("\n%swhy: %s%s  %s(%s; %d bots came to it)%s\n", BOLD, pk.text, OFF, DIM, where_text(&pk), ws[pk.first_child].bots, OFF);
		printf("  chose   score  weight  factor   worth\n");
		for (int o = pk.first_child; o >= 0; o = on.next_sibling) {
			const why *y = &ws[o];
			bt_forest_node(f, o, &on);
			bt_forest_node(f, on.first_child, &ch);
			if (!y->bots) continue;
			printf(" %5.1f%%  %6.2f  %6.2f  %6s  %6.2f  %s %s%s  %s-> %s%s\n", 100.0 * y->chosen / y->bots,
				y->score / y->bots, y->weight / y->bots, num(on.factor), y->worth / y->bots,
				on.trait, on.name, y->score > 0 ? "" : " (0: cannot be chosen)", DIM, ch.text, OFF);
		}
	}
	say_unasked();
	free(st); free(ws); bt_forest_free(f); bt_vocab_free(v);
	return 0;
}

/* one bot, and its tree as the engine holds it */
static void trace_node(const bt_forest *f, const bt_state *st, int id, const char *prefix, int last, const int *path, int n_path)
{
	bt_node n;
	bt_node_state ns;
	bt_forest_node(f, id, &n);
	bt_state_node(f, st, id, &ns);
	int on_path = 0;
	for (int k = 0; k < n_path; k++) on_path |= path[k] == id;
	const char *tee = plain ? (last ? "`- " : "|- ") : (last ? "└─ " : "├─ ");
	const char *bar = plain ? (last ? "   " : "|  ") : (last ? "   " : "│  ");
	printf("%s%4d %s%s%s%s%s", DIM, id, OFF, on_path ? (plain ? "> " : "▶ ") : "  ", DIM, prefix, tee);
	printf("%s", OFF);
	if (on_path) printf("%s", BOLD);
	node_words(&n);
	if (n.kind == BT_K_PICK && ns.running)
		printf("  %s[chose %.1f s ago, again in %.1f s]%s", DIM, (double)ns.elapsed, (double)ns.remaining, OFF);
	if ((n.kind == BT_K_WAIT || n.kind == BT_K_LIMIT) && ns.running)
		printf("  %s[%.1f s in, %.1f s left]%s", DIM, (double)ns.elapsed, (double)ns.remaining, OFF);
	if (n.kind == BT_K_COOLDOWN && ns.remaining > 0)
		printf("  %s[cooling: %.1f s left]%s", DIM, (double)ns.remaining, OFF);
	if (n.kind == BT_K_OPTION) {
		bt_worth w[64];
		int m = bt_state_worths(f, st, n.parent, w, 64);
		for (int k = 0; k < m && k < 64; k++)
			if (w[k].option == id && w[k].weighed && !(w[k].score > 0))
				printf("  %sscore 0: not to be chosen%s", DIM, OFF);
			else if (w[k].option == id && w[k].weighed)
				printf("  %s%.2f x %.2f x %s x %.2f x %.2f = %s%.3f%s%s", DIM, (double)w[k].score, (double)w[k].weight,
					num(w[k].factor), (double)w[k].luck, (double)w[k].sticky, OFF, (double)w[k].worth,
					w[k].held ? "  <- held" : "", OFF);
	}
	printf("%s\n", OFF);
	char deeper[1024];
	snprintf(deeper, sizeof deeper, "%s%s", prefix, bar);
	for (int k = n.first_child; k >= 0;) {
		bt_node ch;
		bt_forest_node(f, k, &ch);
		trace_node(f, st, k, deeper, ch.next_sibling < 0, path, n_path);
		k = ch.next_sibling;
	}
}

static int trace(const char *only, int seed, int level, double secs, int as_json)
{
	static const char *const answer[3] = { "FAILURE", "SUCCESS", "RUNNING" };
	int tree;
	bt_vocab *v;
	bt_forest *f = split_forest(only, &tree, &v);
	if (!f) return 1;
	float mixw[BC_A_COUNT] = {0};
	int a = as_name ? bc_archetype_by_name(as_name) : BC_A_SOLDIER;
	if (a < 0) { fprintf(stderr, "bttree: no archetype called %s\n", as_name); return 1; }
	mixw[a] = 1;
	as_name = NULL;                         /* its weights are in the numbers shown */
	bc_rng r; bc_persona p;
	bc_rng_seed(&r, 4242 + (uint64_t)seed, 11);
	bc_persona_roll(&p, &r, mixw, level);
	bt_ctx ctx = {&r, p.trait, BC_T_COUNT, 0.1f, split_random};
	bt_state *st = malloc(bt_state_size(f));
	if (!st) return 1;
	bt_state_init(st, f);
	bt_state_trace(st, 1);
	bt_status res = bt_tick(f, tree, st, &ctx);
	int ticks = 1;
	for (double t = 0.1; t < secs; t += 0.1, ticks++) res = bt_tick(f, tree, st, &ctx);

	int path[BT_DEPTH_MAX], n_path = bt_state_running(f, st, tree, path, BT_DEPTH_MAX);
	bt_tree tr;
	bt_forest_tree(f, tree, &tr);
	int end = (int)bt_forest_nodes(f);
	bt_tree nx;
	if (bt_forest_tree(f, tree + 1, &nx)) end = nx.root;

	if (as_json) {
		FILE *o = stdout;
		fputs("{\"format\": \"lsd-bt-trace\", \"version\": 1, ", o);
		jkv(o, "tree", tr.name); fprintf(o, ", \"root\": %d, \"ticks\": %d, ", tr.root, ticks);
		jkv(o, "answer", answer[res]);
		fputs(",\n  \"bot\": {", o); jkv(o, "archetype", bc_archetype_name(p.archetype));
		fprintf(o, ", \"level\": %d, \"weights\": {", p.level);
		for (int t = 0; t < BC_T_COUNT; t++) { if (t) fputs(", ", o); jkey(o, bc_trait_name(t)); fputs(num(p.trait[t]), o); }
		fputs("}},\n  \"running\": [", o);
		for (int k = 0; k < n_path; k++) fprintf(o, "%s%d", k ? ", " : "", path[k]);
		fputs("],\n  \"nodes\": [", o);
		for (int i = tr.root; i < end; i++) {
			bt_node n;
			bt_node_state ns;
			int local, fi, on_path = 0;
			bt_forest_node(f, i, &n);
			bt_state_node(f, st, i, &ns);
			fi = where_node(n.source, &local);
			for (int k = 0; k < n_path; k++) on_path |= path[k] == i;
			fprintf(o, "%s\n    {\"id\": %d, \"parent\": %d, \"file\": %d, \"source\": %d, ", i > tr.root ? "," : "", i, n.parent, fi, local);
			jkv(o, "kind", bt_kind_name(n.kind)); fputs(", ", o); jkv(o, "text", n.text);
			fprintf(o, ", \"running\": %s", on_path ? "true" : "false");
			if (ns.child >= 0) fprintf(o, ", \"child\": %d", ns.child);
			if (ns.running && (n.kind == BT_K_PICK || n.kind == BT_K_WAIT || n.kind == BT_K_LIMIT))
				fprintf(o, ", \"elapsed\": %s, \"remaining\": %s", num(ns.elapsed), num(ns.remaining));
			if (n.kind == BT_K_COOLDOWN && ns.remaining > 0) fprintf(o, ", \"remaining\": %s", num(ns.remaining));
			if (n.kind == BT_K_OPTION) {
				bt_worth w[64];
				int m = bt_state_worths(f, st, n.parent, w, 64);
				for (int k = 0; k < m && k < 64; k++)
					if (w[k].option == i && w[k].weighed)
						fprintf(o, ", \"worth\": {\"score\": %s, \"weight\": %s, \"factor\": %s, \"luck\": %s, \"sticky\": %s, \"worth\": %s, \"held\": %s}",
							num(w[k].score), num(w[k].weight), num(w[k].factor), num(w[k].luck), num(w[k].sticky),
							num(w[k].worth), w[k].held ? "true" : "false");
			}
			fputc('}', o);
		}
		fputs("\n  ]\n}\n", o);
	} else {
		char what[256] = "";
		bt_describe(f, st, what, sizeof what);
		printf("%s%s%s: a %s, level %d, after %d tick%s (%.1f s): %s%s%s%s%s\n", BOLD, tr.name, OFF,
			bc_archetype_name(p.archetype), p.level, ticks, ticks > 1 ? "s" : "", ticks * 0.1,
			BOLD, answer[res], OFF, what[0] ? "  " : "", what);
		printf("%s  id   an option: score x weight x factor x luck x sticky = worth%s\n", DIM, OFF);
		trace_node(f, st, tr.root, "", 1, path, n_path);
		say_unasked();
	}
	free(st); bt_forest_free(f); bt_vocab_free(v);
	return 0;
}

/* ---- --doc: the trees a Markdown file shows ------------------------------ */

static int check_doc(const bt_vocab *v, const char *path)
{
	char *text = slurp(path, NULL);
	if (!text) { fprintf(stderr, "bttree: cannot read %s\n", path); return 1; }
	int bad = 0, blocks = 0, line = 1;
	for (char *q = text; q && *q;) {
		char *nl = strchr(q, '\n');
		if (!strncmp(q, "```bt", 5) && (q[5] == '\n' || q[5] == '\r' || q[5] == ' ')) {
			char *start = nl ? nl + 1 : q + strlen(q), *end = start;
			int first = ++line;
			while (*end && strncmp(end, "```", 3)) {
				char *e = strchr(end, '\n');
				line++;
				end = e ? e + 1 : end + strlen(end);
			}
			char *block = malloc((size_t)(end - start) + 256);
			if (!block) return 1;
			snprintf(block, (size_t)(end - start) + 1, "%s", start);
			bt_diag d;
			bt_source *src = bt_parse(v, block, &d);
			bt_forest *f = NULL;
			if (src) {
				int shifted = add_stubs(block, src);
				f = bt_compile_diag(v, block, &d);
				if (!f) d.line -= shifted;
			}
			if (!f) {
				fprintf(stderr, "%s:%d: %s\n", path, first + d.line - 1, d.message);
				bad = 1;
			}
			blocks++;
			bt_forest_free(f); bt_source_free(src); free(block);
			q = end;
			nl = strchr(q, '\n');
		}
		line++;
		q = nl ? nl + 1 : NULL;
	}
	if (!blocks) { fprintf(stderr, "%s: no ```bt block in it\n", path); bad = 1; }
	if (!bad) printf("ok: %d tree text(s) in %s\n", blocks, path);
	free(text);
	return bad;
}

/* ---- main ----------------------------------------------------------------- */

static int usage(void)
{
	fprintf(stderr,
		"usage: bttree [--tree NAME] [--as ARCHETYPE] [--plain] FILE.bt...     draw\n"
		"       bttree --check [--json] FILE.bt...                            is it right\n"
		"       bttree --split [--why] [--tree NAME] [--n 700] [--mix camper:2,pusher] [--level 5] FILE.bt... [WORD=VALUE]...\n"
		"       bttree --trace [--json] [--tree NAME] [--as ARCHETYPE] [--seed 0] [--level 5] [--secs 0] FILE.bt... [WORD=VALUE]...\n"
		"       bttree --json [--expanded] FILE.bt... | --from-json FILE | --format FILE.bt... | --roundtrip FILE.bt...\n"
		"       bttree --words [--md] | --schema | --doc FILE.md...\n");
	return 2;
}

int main(int argc, char **argv)
{
	const char *only = NULL, *mix = NULL, *from = NULL;
	char *paths[MAX_FILES];
	int n_paths = 0, check = 0, list = 0, md = 0, do_split = 0, do_trace = 0, with_why = 0, crowd = 700, level = 5, seed = 0;
	int json = 0, expanded = 0, do_schema = 0, do_doc = 0, do_format = 0, do_round = 0;
	double secs = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--tree") && i + 1 < argc) only = argv[++i];
		else if (!strcmp(argv[i], "--as") && i + 1 < argc) as_name = argv[++i];
		else if (!strcmp(argv[i], "--check")) check = 1;
		else if (!strcmp(argv[i], "--words")) list = 1;
		else if (!strcmp(argv[i], "--md")) md = 1;
		else if (!strcmp(argv[i], "--plain")) plain = 1;
		else if (!strcmp(argv[i], "--split")) do_split = 1;
		else if (!strcmp(argv[i], "--why")) with_why = 1;
		else if (!strcmp(argv[i], "--trace")) do_trace = 1;
		else if (!strcmp(argv[i], "--json")) json = 1;
		else if (!strcmp(argv[i], "--expanded")) expanded = 1;
		else if (!strcmp(argv[i], "--schema")) do_schema = 1;
		else if (!strcmp(argv[i], "--doc")) do_doc = 1;
		else if (!strcmp(argv[i], "--format")) do_format = 1;
		else if (!strcmp(argv[i], "--roundtrip")) do_round = 1;
		else if (!strcmp(argv[i], "--from-json") && i + 1 < argc) from = argv[++i];
		else if (!strcmp(argv[i], "--n") && i + 1 < argc) crowd = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--level") && i + 1 < argc) level = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--secs") && i + 1 < argc) secs = atof(argv[++i]);
		else if (!strcmp(argv[i], "--mix") && i + 1 < argc) mix = argv[++i];
		else if ((do_split || do_trace) && strchr(argv[i], '=') && argv[i][0] != '-') {
			char *eq = strchr(argv[i], '=');
			if (n_set < MAX_SET) {
				snprintf(set_[n_set].key, sizeof set_[0].key, "%.*s", (int)(eq - argv[i]), argv[i]);
				snprintf(set_[n_set].val, sizeof set_[0].val, "%s", eq + 1);
				n_set++;
			}
		}
		else if (argv[i][0] == '-' && argv[i][1]) return usage();
		else if (n_paths < MAX_FILES) paths[n_paths++] = argv[i];
	}
	colour = !plain && isatty(1);
	if (crowd < 1) crowd = 1;
	if (level < 1) level = 1;
	if (level > 10) level = 10;

	if (list && md) return words_md(stdout);
	if (list) {
		char *buf = vocab_text();
		if (!buf) return 1;
		fputs(buf, stdout);
		free(buf);
		return 0;
	}
	if (do_schema) return schema(stdout);

	bt_vocab *v = bt_vocab_new();
	if (!v || !bc_vocab_register(v)) { fprintf(stderr, "bttree: no vocabulary\n"); return 1; }

	if (from) {
		char *text = slurp(from, NULL);
		if (!text) { fprintf(stderr, "bttree: cannot read %s\n", from); return 1; }
		return !from_json_text(v, text, stdout);
	}
	if (!n_paths) return usage();
	if (do_doc) {
		int bad = 0;
		for (int i = 0; i < n_paths; i++) bad |= check_doc(v, paths[i]);
		return bad;
	}

	int ok = load(v, paths, n_paths);
	if (check && json) {
		printf("{\"ok\": %s, \"diagnostics\": [", ok ? "true" : "false");
		for (int i = 0; i < n_diags; i++) {
			printf("%s\n  {", i ? "," : "");
			jkv(stdout, "file", diags[i].file);
			printf(", \"line\": %d, \"column\": %d, ", diags[i].line, diags[i].column);
			jkv(stdout, "message", diags[i].message);
			printf("}");
		}
		printf("%s]}\n", n_diags ? "\n" : "");
		return !ok;
	}
	for (int i = 0; i < n_diags; i++) {
		if (diags[i].line > 0) fprintf(stderr, "%s: line %d: %s\n", diags[i].file, diags[i].line, diags[i].message);
		else fprintf(stderr, "%s: %s\n", diags[i].file, diags[i].message);
	}
	if (!ok) return 1;
	if (check) { printf("ok: %d file(s)\n", n_files); return 0; }
	if (do_round) return roundtrip(v);
	if (do_trace) return trace(only, seed, level, secs, json);
	if (json) { json_all(stdout, expanded); return 0; }
	if (do_format) {
		for (int i = 0; i < n_files; i++) {
			char *text = canonical(files[i].src);
			if (text) fputs(text, stdout);
			free(text);
		}
		return 0;
	}
	if (do_split) return split(only, crowd, mix, level, with_why);

	if (as_name) {
		int a = bc_archetype_by_name(as_name);
		if (a < 0) { fprintf(stderr, "bttree: no archetype called %s\n", as_name); return 1; }
		archetype_means(a, as_weight);
	}
	return draw_all(whole, only);
}
