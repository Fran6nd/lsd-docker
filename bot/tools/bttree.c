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
 *                     0 or 1, a value its number (`enemy_distance=4`; not
 *                     given, or `none`, it is unknown), an action `run`
 *                     (the default: it is what the
 *                     bot is then doing), `ok` (done at once, the tree goes
 *                     on) or `fail`. "word arg=..." sets it for those
 *                     arguments only. The words asked and not given are
 *                     listed after, so nothing is 0 by oversight.
 *   --split --why     and, for every pick a bot came to, what its options
 *                     were worth to the crowd: the mean score, trait weight
 *                     and worth, and how many chose each
 *   --split --json    all of that as one JSON document ("lsd-bt-split"):
 *                     the outcomes with their shares in all and by kind,
 *                     every pick a bot came to (its file and source id, as
 *                     --json gives them) with its options, the words
 *                     asked and not given, and each value's unit and range
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
 *                     kinds and their numbers, every condition, score,
 *                     action and value with its arguments, the operators,
 *                     the traits, the archetypes and their mean weights,
 *                     the places
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
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
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

/* the trees the engine writes, which a text may refer to and never holds:
 * how the drawing says them, and what they are (--schema) */
static const struct { const char *name, *drawn, *doc; } ENGINE_TREES[] = {
	{ "items", "each inventory item's own rule", "written by the engine at run time: one rule for each inventory item, brought by whoever defined the item "
	  "(a medkit when hurt, a missile at an enemy under open sky), as a select of seqs each beginning `if has_item <name>`; "
	  "it fails at once for a bot with nothing to use" },
	{ "extras", "what server scripts bring, e.g. night", "written by the engine at run time: what the server's scripts add to every bot that is not an item "
	  "(night and flashlights first of all), each part ticked at every decision whatever the others answer" },
};

/* What the engine writes at run time (`items`, `extras`), empty here
 * unless the text has them: added to `text`, in its own indentation.
 * A text with no header at all is first made the tree "main"; returns
 * how many lines were put before it. */
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
	for (size_t k = 0; k < sizeof ENGINE_TREES / sizeof *ENGINE_TREES; k++)
		if (has_tree(src, ENGINE_TREES[k].name) < 0)
			sprintf(text + strlen(text), "\ntree %s:\nnever\n%sif enemy_visible\n", ENGINE_TREES[k].name, step);
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

/* THE KINDS OF PLAYER it draws bots from: the built-in ones, and what
 * archetypes.txt files say over them (--archetypes FILE, as often as
 * wanted, in order; else the archetypes.txt beside the trees given) --
 * the table botd gives the engine */
static bc_kinds K;

static int read_kinds(const char *path, int must)
{
	FILE *fh = fopen(path, "rb");
	char *text, err[200];
	long n;
	int ok;

	if (!fh) {
		if (must) fprintf(stderr, "bttree: cannot read %s\n", path);
		return !must;
	}
	fseek(fh, 0, SEEK_END);
	n = ftell(fh);
	fseek(fh, 0, SEEK_SET);
	text = malloc((size_t)n + 1);
	if (!text || fread(text, 1, (size_t)n, fh) != (size_t)n) { fclose(fh); free(text); return 0; }
	text[n] = 0;
	fclose(fh);
	ok = bc_kinds_parse(&K, text, err, sizeof err);
	if (!ok) fprintf(stderr, "bttree: %s: %s\n", path, err);
	free(text);
	return ok;
}

/* the mean trait weights of 400 bots of one archetype */
static void archetype_means(int a, float *mean)
{
	float w[BC_KINDS_MAX] = {0};
	w[a] = 1;
	memset(mean, 0, BC_T_COUNT * sizeof *mean);
	for (int k = 0; k < 400; k++) {
		bc_rng r; bc_persona p;
		bc_rng_seed(&r, 1000 + (uint64_t)k, 7);
		bc_kinds_roll(&K, &p, &r, w, 5);
		for (int t = 0; t < BC_T_COUNT; t++) mean[t] += p.trait[t] / 400.0f;
	}
}

/* The node kinds. `children`: none, one, many, or options (a pick's).
 * `tries`: how a kind with several children tries them -- "all" in order
 * while each succeeds (seq; the branch of an if block, an else), "first"
 * until one does not fail (select). */
typedef struct kparam { const char *name, *type, *form; int required; double def, min, max; const char *doc; } kparam;
typedef struct kindspec { const char *name, *children, *tries, *answers, *doc; kparam p[4]; } kindspec;
#define NOMAX 1e30
static const kindspec KINDS[BT_K_COUNT] = {
	{ "seq", "many", "all", "FAILURE at the first child that fails, RUNNING while one is, SUCCESS when all have succeeded",
	  "its children in order; resumes at the child that was RUNNING", {{0}} },
	{ "select", "many", "first", "the answer of the first child that does not fail; FAILURE when all fail",
	  "its children in order, the first that does not fail: a priority list; resumes at the child that was RUNNING", {{0}} },
	{ "pick", "options", NULL, "the answer of the option chosen; FAILURE when no option has a score above 0",
	  "a weighed choice among its options: the one worth most to this bot (score x trait weight x factor x luck) is ticked",
	  { { "roll", "enum", "roll=<weighed|once|life|each>", 0, 0, 0, 0, "weighed (the default): the option worth most, chosen again and again. once: an option DRAWN, each with a chance in proportion to its worth, the same for this bot for good -- a role. life: drawn anew each life. each: a lottery drawn again at every choice (every is kept; sticky and noise are not written). With once or life, every, sticky and noise are not written" },
	    { "every", "number", "every=<secs>", 0, 2, 0, NOMAX, "seconds between two choices; it also chooses again whenever the option chosen ends" },
	    { "sticky", "number", "sticky=<x>", 0, 0.25, 0, NOMAX, "the option being done is worth this much more, as a fraction of its own worth" },
	    { "noise", "number", "noise=<x>", 0, 0.1, 0, 1, "luck: each option's worth is multiplied by a draw within 1 +- this" } } },
	{ "option", "one", NULL, "its child's",
	  "one choice of a pick: `option <trait> <score> [score's arguments] [x<factor>]`, or `option <trait> <value> [args] <op> <number> [x<factor>]`, only directly under a pick",
	  { { "trait", "trait", "<trait>", 1, 0, 0, 0, "whose character weighs it: the bot's weight for this trait multiplies the score" },
	    { "score", "score", "<score> [args]", 1, 0, 0, 0, "what bears on it: a score of the vocabulary, 0 to 1, or a comparison, 1 when it holds and 0 when not; at 0 the option cannot be chosen" },
	    { "factor", "number", "x<factor>", 0, 1, 0, NOMAX, "the designer's thumb on the scale" } } },
	{ "if", "none", NULL, "a leaf: SUCCESS if the condition holds, else FAILURE. A block: the answer of the branch chosen when it was entered (the children when the condition holds, the else's when not); FAILURE when it does not hold and there is no else",
	  "a condition of the vocabulary with its arguments, or a comparison; with children, a decision (`else` for the other branch)",
	  { { "cond", "cond", "<cond> [args]", 1, 0, 0, 0, "the condition" } } },
	{ "unless", "none", NULL, "as if, the condition turned: a leaf answers FAILURE if it holds, else SUCCESS; a block takes its children when it does NOT hold, the else's when it does",
	  "a condition or a comparison, the other way round; with children, a decision",
	  { { "cond", "cond", "<cond> [args]", 1, 0, 0, 0, "the condition" } } },
	{ "do", "none", NULL, "the action's: RUNNING while it goes on, SUCCESS or FAILURE when it ends",
	  "an action of the vocabulary, with its arguments; stopped (told once) if its branch is abandoned while it is RUNNING",
	  { { "action", "action", "<action> [args]", 1, 0, 0, 0, "the action" } } },
	{ "wait", "none", NULL, "RUNNING for that long, then SUCCESS", "let time pass",
	  { { "seconds", "number", "<secs>", 1, 0, 0, NOMAX, "how long, from the first tick that reaches it" } } },
	{ "invert", "one", NULL, "its child's turned: SUCCESS for FAILURE, FAILURE for SUCCESS; RUNNING stays", "turn the child's answer round", {{0}} },
	{ "always", "one", NULL, "SUCCESS whatever the child answers; RUNNING stays", "do the child and go on whatever came of it", {{0}} },
	{ "never", "one", NULL, "FAILURE whatever the child answers; RUNNING stays", "do the child and fail whatever came of it", {{0}} },
	{ "cooldown", "one", NULL, "its child's; then FAILURE, without asking the child, for that long after the child ended",
	  "not more often than this",
	  { { "seconds", "number", "<secs>", 1, 0, 0, NOMAX, "how long after the child answers SUCCESS or FAILURE" } } },
	{ "limit", "one", NULL, "its child's; FAILURE if the child is still RUNNING after that long (the child is stopped)",
	  "not longer than this",
	  { { "seconds", "number", "<secs>", 1, 0, 0, NOMAX, "how long the child may stay RUNNING" } } },
	{ "tree", "none", NULL, "the answer of the tree named", "another tree by name, as if written here; `items` and `extras` are written by the engine",
	  { { "ref", "tree", "<name>", 1, 0, 0, 0, "the tree's name" } } },
	{ "else", "many", "all", "the answer of its children, as a seq's",
	  "the other branch of an if or unless block: its last child, written at its indent; taken when the if's condition does not hold (the unless's does)", {{0}} },
};

/* which of a pick's settings a roll leaves out: they may not be written
 * with it (bt.c, fill_node) */
static const struct { const char *roll, *gone[3]; } LEAVES_OUT[] = {
	{ "once", { "every", "sticky", "noise" } }, { "life", { "every", "sticky", "noise" } }, { "each", { "sticky", "noise" } },
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

static void schema_args(FILE *o, const bt_arg_spec *args, int n_args, int pad)
{
	fputs("[", o);
	for (int i = 0; i < n_args; i++) {
		const bt_arg_spec *a = &args[i];
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
	if (n_args) jpad(o, pad - 1);
	fputs("]", o);
}

static void schema_words(FILE *o, const char *key, int kind)
{
	bc_word w;
	jpad(o, 1); jkey(o, key); fputs("[", o);
	for (int i = 0, n = 0; bc_vocab_word(i, &w); i++) {
		char usage[128], short_for[128];
		if (w.kind != kind) continue;
		bc_vocab_usage(i, usage, sizeof usage);
		bc_vocab_short_for(i, short_for, sizeof short_for);
		if (n++) fputc(',', o);
		jpad(o, 2); fputs("{", o);
		jkv(o, "name", w.name); fputs(", ", o);
		jkv(o, "usage", usage); fputs(",", o);
		if (short_for[0]) { jpad(o, 3); jkv(o, "short_for", short_for); fputs(",", o); }
		jpad(o, 3); jkey(o, "args"); schema_args(o, w.args, w.n_args, 5); fputs(",", o);
		jpad(o, 3); jkv(o, "doc", w.doc);
		jpad(o, 2); fputs("}", o);
	}
	jpad(o, 1); fputs("]", o);
}

/* the comparison a guard's condition or an option's score may be
 * instead: what its three parts are (bt.h, CONDITIONS ON NUMBERS) */
static void schema_comparison(FILE *o, int pad)
{
	fputs(", \"or\": {\"form\": \"comparison\", \"written\": \"<value> [args] <op> <number>\", \"params\": [", o);
	jpad(o, pad); fputs("{\"name\": \"value\", \"type\": \"value\", \"written\": \"<value> [args]\", \"required\": true, "
	                    "\"doc\": \"a value of the vocabulary (`values`), with its own arguments in `args`\"},", o);
	jpad(o, pad); fputs("{\"name\": \"op\", \"type\": \"enum\", \"written\": \"<op>\", \"required\": true, \"values\": [", o);
	for (int k = BT_OP_NONE + 1; k < BT_OP_COUNT; k++) { if (k > 1) fputs(", ", o); jstr(o, bt_op_name(k)); }
	fputs("], \"doc\": \"the operator (`operators`)\"},", o);
	jpad(o, pad); fputs("{\"name\": \"number\", \"type\": \"number\", \"written\": \"<number>\", \"required\": true, "
	                    "\"doc\": \"what the value is compared with; within the value's `min` and `max`\"}]}", o);
}

static int schema(FILE *o)
{
	float lo, hi;
	bc_trait_range(&lo, &hi);
	fputs("{", o);
	jpad(o, 1); fputs("\"format\": \"lsd-bt-schema\", \"version\": 3,", o);
	jpad(o, 1); fprintf(o, "\"limits\": {\"args\": %d, \"name\": %d, \"depth\": %d, \"words_a_line\": 16},", BT_ARGS_MAX, BT_NAME_MAX - 1, BT_DEPTH_MAX);
	jpad(o, 1); fputs("\"answers\": [\"SUCCESS\", \"FAILURE\", \"RUNNING\"],", o);
	jpad(o, 1); fputs("\"kinds\": [", o);
	for (int k = 0; k < BT_K_COUNT; k++) {
		const kindspec *s = &KINDS[k];
		int guard = k == BT_K_IF || k == BT_K_UNLESS;
		if (k) fputc(',', o);
		jpad(o, 2); fputs("{", o);
		jkv(o, "name", s->name); fputs(", ", o);
		jkv(o, "children", s->children);
		if (s->tries) { fputs(", ", o); jkv(o, "tries", s->tries); }
		if (k == BT_K_OPTION) fputs(", \"parent\": \"pick\", \"parents\": [\"pick\"]", o);
		if (k == BT_K_ELSE) fputs(", \"parent\": \"if\", \"parents\": [\"if\", \"unless\"], \"position\": \"last\", \"indent\": \"parent\"", o);
		if (guard) {
			fprintf(o, ",");
			jpad(o, 3);
			fprintf(o, "\"guard\": {\"negates\": %s},", k == BT_K_UNLESS ? "true" : "false");
			jpad(o, 3);
			fprintf(o, "\"block\": {\"children\": \"many\", \"tries\": \"all\", \"roles\": ["
			        "{\"role\": \"then\", \"children\": \"many\", \"doc\": \"its children before the else: taken when the condition %s\"}, "
			        "{\"role\": \"otherwise\", \"kind\": \"else\", \"optional\": true, \"doc\": \"an else, its last child: its children taken when %s\"}]}",
			        k == BT_K_IF ? "holds" : "does not hold", k == BT_K_IF ? "it does not" : "it does");
		}
		fputs(",", o);
		jpad(o, 3); jkey(o, "params"); fputs("[", o);
		for (int i = 0; i < 4 && s->p[i].name; i++) {
			const kparam *p = &s->p[i];
			if (i) fputc(',', o);
			jpad(o, 4); fputs("{", o);
			jkv(o, "name", p->name); fputs(", ", o);
			jkv(o, "type", p->type); fputs(", ", o);
			jkv(o, "written", p->form);
			fprintf(o, ", \"required\": %s", p->required ? "true" : "false");
			if (!strcmp(p->name, "roll")) {
				fputs(", \"values\": [\"weighed\", \"once\", \"life\", \"each\"], \"default\": \"weighed\", \"leaves_out\": {", o);
				for (size_t r = 0; r < sizeof LEAVES_OUT / sizeof *LEAVES_OUT; r++) {
					if (r) fputs(", ", o);
					jkey(o, LEAVES_OUT[r].roll); fputc('[', o);
					for (int g = 0; g < 3 && LEAVES_OUT[r].gone[g]; g++) { if (g) fputs(", ", o); jstr(o, LEAVES_OUT[r].gone[g]); }
					fputc(']', o);
				}
				fputc('}', o);
			}
			if (!strcmp(p->type, "number")) {
				if (!p->required) fprintf(o, ", \"default\": %s", num(p->def));
				fprintf(o, ", \"min\": %s", num(p->min));
				if (p->max < NOMAX) fprintf(o, ", \"max\": %s", num(p->max));
			}
			if (!strcmp(p->type, "cond") || !strcmp(p->type, "score")) schema_comparison(o, 5);
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
	jpad(o, 1); fputs("\"operators\": [{\"op\": \"<\", \"doc\": \"less than\"}, {\"op\": \"<=\", \"doc\": \"less than or equal to\"}, "
	                  "{\"op\": \">\", \"doc\": \"more than\"}, {\"op\": \">=\", \"doc\": \"more than or equal to\"}],", o);
	jpad(o, 1); fputs("\"comparison\": {\"written\": \"<value> [args] <op> <number>\", "
	                  "\"unknown\": \"a comparison of a value that is unknown now is false (so unless of it is true)\", "
	                  "\"as_score\": \"an option's comparison is worth 1 when it holds, 0 when not\", "
	                  "\"no_equal\": \"there is no == or !=: two measured numbers are never exactly equal; for a count, >= 2 with < 3 says exactly 2\"},", o);
	schema_words(o, "conditions", BT_WORD_COND); fputs(",", o);
	schema_words(o, "scores", BT_WORD_SCORE); fputs(",", o);
	schema_words(o, "actions", BT_WORD_ACTION); fputs(",", o);
	jpad(o, 1); fputs("\"values\": [", o);
	for (int i = 0; i < bc_value_count(); i++) {
		bc_value x;
		char usage[128];
		bc_value_at(i, &x);
		bc_value_usage(i, usage, sizeof usage);
		if (i) fputc(',', o);
		jpad(o, 2); fputs("{", o);
		jkv(o, "name", x.name); fputs(", ", o);
		jkv(o, "usage", usage); fputs(", ", o);
		jkv(o, "unit", x.number->name);
		if (x.number->has_min) fprintf(o, ", \"min\": %s", num(x.number->min));
		if (x.number->has_max) fprintf(o, ", \"max\": %s", num(x.number->max));
		fputs(",", o);
		jpad(o, 3); jkey(o, "args"); schema_args(o, x.args, x.n_args, 5); fputs(",", o);
		jpad(o, 3); jkv(o, "doc", x.doc);
		jpad(o, 2); fputs("}", o);
	}
	jpad(o, 1); fputs("],", o);
	jpad(o, 1); fputs("\"traits\": [", o);
	for (int t = 0; t < BC_T_COUNT; t++) {
		if (t) fputc(',', o);
		jpad(o, 2); fputs("{", o); jkv(o, "name", bc_trait_name(t)); fputs(", ", o); jkv(o, "doc", bc_trait_doc(t)); fputs("}", o);
	}
	jpad(o, 1); fputs("],", o);
	jpad(o, 1); fprintf(o, "\"trait_range\": [%s, %s],", num(lo), num(hi));
	jpad(o, 1); fputs("\"archetypes\": [", o);
	for (int a = 0; a < K.n; a++) {
		if (a) fputc(',', o);
		jpad(o, 2); fputs("{", o); jkv(o, "name", K.k[a].name); fputs(", ", o);
		jkv(o, "doc", K.k[a].doc);
		fputs(",", o);
		for (int pass = 0; pass < 2; pass++) {
			jpad(o, 3); fputs(pass ? "\"spread\": {" : "\"weights\": {", o);
			for (int t = 0; t < BC_T_COUNT; t++) {
				float c = K.k[a].centre[t], sp = K.k[a].spread[t];
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
	jpad(o, 1); fputs("],", o);
	jpad(o, 1); fputs("\"types\": {\"place\": {\"list\": \"places\", \"script\": {\"prefix\": \"@\", "
	                  "\"doc\": \"a place a server script named (botlink_set(\\\"place.<name>\\\", ...)), written @<name> wherever a place goes: "
	                  "letters, digits and _ after the @; it compiles before the script has said where it is\"}}},", o);
	jpad(o, 1); fputs("\"engine_trees\": [", o);
	for (size_t i = 0; i < sizeof ENGINE_TREES / sizeof *ENGINE_TREES; i++) {
		if (i) fputc(',', o);
		jpad(o, 2); fputs("{", o); jkv(o, "name", ENGINE_TREES[i].name); fputs(", ", o); jkv(o, "doc", ENGINE_TREES[i].doc); fputs("}", o);
	}
	jpad(o, 1); fputs("],", o);
	jpad(o, 1); fputs("\"companion\": {\"suffix\": \"_also\", \"doc\": \"a tree named <name>_also beside the tree <name> a bot runs is ticked "
	                  "just before it at every decision: where things done beside go (a lamp, a ping, an item); keep it to actions "
	                  "that end at once\"}", o);
	fputs("\n}\n", o);
	return 0;
}

/* a word's arguments, one a line under it */
static void md_args(FILE *o, const bt_arg_spec *args, int n_args)
{
	for (int j = 0; j < n_args; j++) {
		const bt_arg_spec *a = &args[j];
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

/* --words --md: the vocabulary as a page (bot/VOCAB.md) */
static int words_md(FILE *o)
{
	static const char *const title[3][2] = {
		{ "Conditions", "For `if` and `unless`: true or false. One marked *short for* a comparison of a [value](#values) is "
		  "that comparison, compiled as it: the same answer, always." },
		{ "Scores", "For `option <trait> <score>`: 0 to 1, how much the situation calls for the option. At 0 the option cannot be chosen. "
		  "One marked *short for* a comparison is 1 when it holds and 0 when not." },
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
			char usage[128], short_for[128];
			if (w.kind != k) continue;
			bc_vocab_usage(i, usage, sizeof usage);
			bc_vocab_short_for(i, short_for, sizeof short_for);
			fprintf(o, "- **`%s%s%s`** -- %s", w.name, usage[0] ? " " : "", usage, w.doc);
			if (short_for[0]) fprintf(o, ". *Short for* `%s`", short_for);
			fputs("\n", o);
			md_args(o, w.args, w.n_args);
		}
	}
	fputs("\n## Values\n\nFor a comparison, wherever a condition goes (`if <value> [arguments] <op> <number>`, `unless ...`) "
	      "and as an option's score (`option <trait> <value> [arguments] <op> <number>`: 1 when it holds, 0 when not). "
	      "The operators are `<`, `<=`, `>` and `>=`. A value may be **unknown** now (no enemy in sight has no distance): "
	      "a comparison of it is then false, so `unless` of it is true. The number compared must lie within the value's "
	      "range, given here with its unit.\n\n", o);
	for (int i = 0; i < bc_value_count(); i++) {
		bc_value x;
		char usage[128];
		bc_value_at(i, &x);
		bc_value_usage(i, usage, sizeof usage);
		fprintf(o, "- **`%s%s%s`** -- %s. In %s", x.name, usage[0] ? " " : "", usage, x.doc, x.number->name);
		if (x.number->has_min && x.number->has_max) fprintf(o, ", %s to %s", num(x.number->min), num(x.number->max));
		else if (x.number->has_min) fprintf(o, ", %s or more", num(x.number->min));
		else if (x.number->has_max) fprintf(o, ", %s or less", num(x.number->max));
		fputs("\n", o);
		md_args(o, x.args, x.n_args);
	}
	fprintf(o, "\n## Traits\n\nFor `option <trait> ...`: the bot's own weight for the trait multiplies the option's score.\n"
	      "A weight is rolled once a bot, around its archetype's centre, and kept between %s and %s.\n\n", num(lo), num(hi));
	for (int t = 0; t < BC_T_COUNT; t++) fprintf(o, "- **`%s`** -- %s\n", bc_trait_name(t), bc_trait_doc(t));
	fputs("\n## Archetypes\n\nThe kinds of bot a character is drawn from.\n\n", o);
	for (int a = 0; a < K.n; a++) fprintf(o, "- **`%s`** -- %s\n", K.k[a].name, K.k[a].doc);
	fputs("\nThe centre each draws a trait around (`none` is always 1); the draw is a normal one about it,\n"
	      "with the spread in brackets:\n\n| |", o);
	for (int t = 1; t < BC_T_COUNT; t++) fprintf(o, " %s |", bc_trait_name(t));
	fputs("\n|---|", o);
	for (int t = 1; t < BC_T_COUNT; t++) fputs("---|", o);
	fputs("\n", o);
	for (int a = 0; a < K.n; a++) {
		fprintf(o, "| **%s** |", K.k[a].name);
		for (int t = 1; t < BC_T_COUNT; t++) {
			float c = K.k[a].centre[t], sp = K.k[a].spread[t];
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
		fprintf(o, ", \"roll\": \"%s\", \"every\": %s, \"sticky\": %s, \"noise\": %s, \"defaults\": [",
			n.roll == BT_ROLL_ONCE ? "once" : n.roll == BT_ROLL_LIFE ? "life" : n.roll == BT_ROLL_EACH ? "each" : "weighed", num(n.every), num(n.sticky), num(n.noise));
		if (!(n.written & BT_W_ROLL)) { some++; jstr(o, "roll"); }
		for (int k = 0; k < 3; k++)
			if (!(n.written & S[k].bit)) { if (some++) fputs(", ", o); jstr(o, S[k].name); }
		fputc(']', o);
		break;
	}
	case BT_K_OPTION:
		fputs(", ", o); jkv(o, "trait", n.trait);
		fputs(", ", o); jkv(o, n.op ? "value" : "score", n.name);
		break;
	case BT_K_IF: case BT_K_UNLESS: fputs(", ", o); jkv(o, n.op ? "value" : "cond", n.name); break;
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
	if (n.op) { fputs(", ", o); jkv(o, "op", bt_op_name(n.op)); fprintf(o, ", \"number\": %s", num(n.number)); }
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

static const char *json_only;       /* --json --tree NAME: that tree alone */

static void json_file(FILE *o, const char *path, const bt_source *src, int pad)
{
	bt_tree t;
	int some = 0;
	jpad(o, pad); fputs("{", o);
	if (path) { jkv(o, "file", path); fputs(", ", o); }
	fputs("\"trees\": [", o);
	for (int i = 0; bt_source_tree(src, i, &t); i++) {
		if (json_only && strcmp(json_only, t.name)) continue;
		if (some++) fputc(',', o);
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
	if (bt_source_tail(src) && !json_only) { fputs(", ", o); jkey(o, "tail"); jlines(o, bt_source_tail(src)); }
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
	int compared = kind && (!strcmp(kind, "if") || !strcmp(kind, "unless") || !strcmp(kind, "option")) &&
	               jtext(node, "value") != NULL;      /* a comparison: value, args, op, number */
	if (!kind) { fprintf(stderr, "bttree: --from-json: a node without a \"kind\"\n"); json_err = 1; return; }
	sput_above(b, jget(node, "above"), depth);
	for (int k = 0; k < depth; k++) sput(b, "\t");
	sput(b, kind);
	if (!strcmp(kind, "pick")) {
		static const struct { const char *name; double def; } S[3] = { { "every", 2 }, { "sticky", 0.25 }, { "noise", 0.1 } };
		const char *roll = jtext(node, "roll");
		int rolls = roll && (!strcmp(roll, "once") || !strcmp(roll, "life"));
		if (roll && strcmp(roll, "weighed")) { sput(b, " roll="); sput(b, roll); }
		/* a pick that rolls has no every, sticky or noise: the numbers an
		 * editor still holds for it are not written */
		for (int k = 0; k < 3; k++)
			if (!rolls && !is_default(node, S[k].name, S[k].def)) {
				sput(b, " "); sput(b, S[k].name); sput(b, "="); sput(b, num(jget(node, S[k].name)->number));
			}
	} else if (!strcmp(kind, "option")) {
		sput(b, " "); sput(b, jtext(node, "trait") ? jtext(node, "trait") : "?");
		sput(b, " "); sput(b, jtext(node, compared ? "value" : "score") ? jtext(node, compared ? "value" : "score") : "?");
	} else if (!strcmp(kind, "if") || !strcmp(kind, "unless")) {
		sput(b, " "); sput(b, jtext(node, compared ? "value" : "cond") ? jtext(node, compared ? "value" : "cond") : "?");
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
	if (compared) {                     /* <value> [args] <op> <number> */
		v = jget(node, "number");
		sput(b, " "); sput(b, jtext(node, "op") ? jtext(node, "op") : "?");
		sput(b, " "); sput(b, v && v->type == '#' ? num(v->number) : v && v->type == 's' ? v->text : "?");
	}
	if (!strcmp(kind, "option") && !is_default(node, "factor", 1)) { sput(b, " x"); sput(b, num(jget(node, "factor")->number)); }
	sput_comment(b, node);
	sput(b, "\n");
	/* an else is its if's last child, written at the if's indent */
	v = jget(node, "children");
	for (const jv *ch = v && v->type == 'a' ? v->kids : NULL; ch; ch = ch->next) {
		const char *ck = jtext(ch, "kind");
		int is_else = ck && !strcmp(ck, "else");
		if (is_else && (ch->next || (strcmp(kind, "if") && strcmp(kind, "unless")))) {
			fprintf(stderr, "bttree: --from-json: an else must be the last child of an if or unless\n");
			json_err = 1;
			return;
		}
		sput_node(b, ch, is_else ? depth : depth + 1);
	}
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
		if (t < 0) {
			const char *what = "sent by the server";
			for (size_t k = 0; k < sizeof ENGINE_TREES / sizeof *ENGINE_TREES; k++)
				if (!strcmp(n.name, ENGINE_TREES[k].name)) what = ENGINE_TREES[k].drawn;
			printf("%s%s%s(filled in at run time: %s)%s\n", DIM, deeper, end, what, OFF);
		}
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

static struct { char name[BT_NAME_MAX]; } words_[4 * MAX_WORDS];
static int n_words[4];                          /* cond, score, action, value */
static struct { char key[96]; char val[32]; int used, value; } set_[MAX_SET];   /* value: as asked */
static int n_set;
static char asked[256][96];
static int asked_value[256];                    /* a value's index + 1, or 0 for a word */
static int n_asked;
static int quiet_ask;                           /* an action is not a question */
static int asking_value;                        /* the value being asked, + 1 */

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
			if (!strcmp(set_[i].key, k)) { set_[i].used = 1; set_[i].value = asking_value; return set_[i].val; }
	}
	if (quiet_ask) return NULL;
	for (int i = 0; i < n_asked; i++)
		if (!strcmp(asked[i], key)) return NULL;
	if (n_asked < 256) {
		asked_value[n_asked] = asking_value;
		snprintf(asked[n_asked++], sizeof asked[0], "%s", key);
	}
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
/* a value given is a number; not given (or `none`), it is unknown */
static int split_value(int i, const bt_args *a, double *out)
{
	const char *v;
	int x;
	bc_value info;
	for (x = 0; bc_value_at(x, &info) && strcmp(info.name, word_name(3, i)); x++) ;
	asking_value = x + 1;
	v = given(word_name(3, i), a);
	asking_value = 0;
	if (!v || !strcmp(v, "none") || !strcmp(v, "unknown")) return 0;
	*out = atof(v);
	return 1;
}
static float split_score(int i, const bt_args *a) { return worth(word_name(1, i), a); }
static bt_status split_action(int i, const bt_args *a)
{
	quiet_ask = 1;
	const char *v = given(word_name(2, i), a);
	quiet_ask = 0;
	if (v && !strcmp(v, "ok")) return BT_SUCCESS;
	if (v && !strcmp(v, "fail")) return BT_FAILURE;
	if (!v && !strcmp(word_name(2, i), "tell")) return BT_SUCCESS;   /* a word said: done at once, always */
	return BT_RUNNING;
}

/* A leaf is given the bot and its arguments, not its name: so one
 * function a word, MAX_WORDS of each kind, written by the preprocessor. */
#define LEAF(i) \
	static int cf##i(void *b, const bt_args *a) { (void)b; return split_cond(i, a); } \
	static float sf##i(void *b, const bt_args *a) { (void)b; return split_score(i, a); } \
	static bt_status af##i(void *b, const bt_args *a, float dt) { (void)b; (void)dt; return split_action(i, a); } \
	static int vf##i(void *b, const bt_args *a, double *out) { (void)b; return split_value(i, a, out); }
#define L10(t) LEAF(t##0) LEAF(t##1) LEAF(t##2) LEAF(t##3) LEAF(t##4) LEAF(t##5) LEAF(t##6) LEAF(t##7) LEAF(t##8) LEAF(t##9)
LEAF(0) LEAF(1) LEAF(2) LEAF(3) LEAF(4) LEAF(5) LEAF(6) LEAF(7) LEAF(8) LEAF(9)
L10(1) L10(2) L10(3) L10(4) L10(5) L10(6) L10(7) L10(8) L10(9) L10(10) L10(11) L10(12) L10(13) L10(14) L10(15)
#define P(i) {cf##i, sf##i, af##i, vf##i},
#define P10(t) P(t##0) P(t##1) P(t##2) P(t##3) P(t##4) P(t##5) P(t##6) P(t##7) P(t##8) P(t##9)
static const struct { bt_cond_fn c; bt_score_fn s; bt_action_fn a; bt_value_fn v; } leaf[MAX_WORDS] = {
	P(0) P(1) P(2) P(3) P(4) P(5) P(6) P(7) P(8) P(9)
	P10(1) P10(2) P10(3) P10(4) P10(5) P10(6) P10(7) P10(8) P10(9) P10(10) P10(11) P10(12) P10(13) P10(14) P10(15)
};

static float split_random(void *bot) { return bc_rng_float((bc_rng *)bot); }

/* The engine's words, each bound to a leaf that answers from what was
 * given. The names come from the engine's own table (bc_vocab_word). A
 * word that is short for a comparison is a word here like another (it is
 * given as itself: `health_below 30=1`); a comparison written out asks
 * its value (`enemy_distance=4`; not given, it is unknown). */
static bt_vocab *split_vocab(void)
{
	bt_vocab *v = bt_vocab_new();
	bc_word w;
	bc_value x;
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
	for (int n = 0; bc_value_at(n, &x) && n_words[BT_WORD_VALUE] < MAX_WORDS; n++) {
		int i = n_words[BT_WORD_VALUE]++;
		snprintf(words_[BT_WORD_VALUE * MAX_WORDS + i].name, BT_NAME_MAX, "%s", x.name);
		bt_vocab_value(v, x.name, leaf[i].v, x.number);
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
	for (int pass = 0; pass < 2; pass++) {             /* the words, then the values */
		int head = 0;
		for (int i = 0; i < n_asked; i++) {
			if (!strcmp(asked[i], "always") || !asked_value[i] != !pass) continue;
			printf("%s%s%s", head++ ? ", " : pass ? "asked and not given (so unknown): " : "asked and not given (so 0): ", DIM, asked[i]);
			printf("%s", OFF);
		}
		if (head) printf("\n");
	}
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

typedef struct outcome { char what[256]; int by[BC_KINDS_MAX]; int all; } outcome;
typedef struct why { int bots, chosen; double score, weight, worth; } why;

static int by_count(const void *a, const void *b) { return ((const outcome *)b)->all - ((const outcome *)a)->all; }

static void split_json(const char *only, int n, int level, const bt_forest *f, const outcome *out, int n_out,
                       const int *crowd, const why *ws);

static int split(const char *only, int n, const char *mix, int level, int with_why, int as_json)
{
	int tree;
	bt_vocab *v;
	bt_forest *f = split_forest(only, &tree, &v);
	if (!f) return 1;

	float mixw[BC_KINDS_MAX];
	if (!bc_kinds_weights(&K, mix ? mix : "", mixw)) { fprintf(stderr, "bttree: --mix %s?\n", mix); return 1; }

	static outcome out[MAX_OUT];
	int n_out = 0, crowd[BC_KINDS_MAX] = {0}, nodes = (int)bt_forest_nodes(f);
	bt_state *st = malloc(bt_state_size(f));
	why *ws = calloc((size_t)nodes, sizeof *ws);
	if (!st || !ws) return 1;
	for (int k = 0; k < n; k++) {
		bc_rng r; bc_persona p;
		bc_rng_seed(&r, 4242 + (uint64_t)k, 11);
		bc_kinds_roll(&K, &p, &r, mixw, level);
		bt_ctx ctx = {&r, p.trait, BC_T_COUNT, 0.1f, split_random, 4242u + (uint64_t)k};   /* each its own, as a seed is */
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
	if (as_json) {
		split_json(only, n, level, f, out, n_out, crowd, ws);
		free(st); free(ws); bt_forest_free(f); bt_vocab_free(v);
		return 0;
	}

	printf("%s%d bots, level %d, tree %s%s\n", BOLD, n, level, only ? only : "(the first)", OFF);
	printf("%6s", "all");
	for (int a = 0; a < K.n; a++) if (crowd[a]) printf(" %7.7s", K.k[a].name);
	printf("\n");
	for (int o = 0; o < n_out; o++) {
		printf("%5.1f%%", 100.0 * out[o].all / n);
		for (int a = 0; a < K.n; a++) if (crowd[a]) printf(" %6.0f%%", 100.0 * out[o].by[a] / crowd[a]);
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

/* --split --json: the same numbers, for a tool (an editor's preview) */
static void split_json(const char *only, int n, int level, const bt_forest *f, const outcome *out, int n_out,
                       const int *crowd, const why *ws)
{
	int nodes = (int)bt_forest_nodes(f), first = 1;
	printf("{\"format\": \"lsd-bt-split\", \"version\": 1, ");
	jkey(stdout, "tree");
	if (only) jstr(stdout, only); else fputs("null", stdout);
	printf(", \"n\": %d, \"level\": %d,\n \"crowd\": {", n, level);
	for (int a = 0; a < K.n; a++)
		if (crowd[a]) { printf("%s", first ? "" : ", "); jkey(stdout, K.k[a].name); printf("%d", crowd[a]); first = 0; }
	printf("},\n \"outcomes\": [");
	for (int o = 0; o < n_out; o++) {
		printf("%s\n  {", o ? "," : "");
		jkv(stdout, "what", out[o].what);
		printf(", \"all\": %s, \"by\": {", num((double)out[o].all / n));
		first = 1;
		for (int a = 0; a < K.n; a++)
			if (crowd[a]) { printf("%s", first ? "" : ", "); jkey(stdout, K.k[a].name); printf("%s", num((double)out[o].by[a] / crowd[a])); first = 0; }
		printf("}}");
	}
	printf("],\n \"picks\": [");
	first = 1;
	for (int i = 0; i < nodes; i++) {
		bt_node pk, on;
		int local, fi;
		bt_forest_node(f, i, &pk);
		if (pk.kind != BT_K_PICK || !ws[pk.first_child].bots) continue;
		fi = where_node(pk.source, &local);
		printf("%s\n  {\"id\": %d, \"file\": %d, \"source\": %d, \"bots\": %d, ", first ? "" : ",", i, fi, local, ws[pk.first_child].bots);
		jkv(stdout, "text", pk.text);
		printf(", \"options\": [");
		for (int o = pk.first_child, k = 0; o >= 0; o = on.next_sibling, k++) {
			const why *y = &ws[o];
			bt_forest_node(f, o, &on);
			fi = where_node(on.source, &local);
			printf("%s\n    {\"file\": %d, \"source\": %d, ", k ? "," : "", fi, local);
			jkv(stdout, "text", on.text);
			printf(", \"bots\": %d, \"chosen\": %s", y->bots, num(y->bots ? (double)y->chosen / y->bots : 0));
			printf(", \"score\": %s", num(y->bots ? y->score / y->bots : 0));
			printf(", \"weight\": %s", num(y->bots ? y->weight / y->bots : 0));
			printf(", \"factor\": %s", num(on.factor));
			printf(", \"worth\": %s}", num(y->bots ? y->worth / y->bots : 0));
		}
		printf("]}");
		first = 0;
	}
	printf("],\n \"asked\": [");
	first = 1;
	for (int i = 0; i < n_asked; i++) {
		if (!strcmp(asked[i], "always")) continue;
		printf("%s", first ? "" : ", "); jstr(stdout, asked[i]); first = 0;
	}
	printf("],\n \"values\": {");
	first = 1;
	for (int i = 0; i < n_asked + n_set; i++) {     /* a value asked, given or not: what a slider for it spans */
		bc_value x;
		int which = i < n_asked ? asked_value[i] : set_[i - n_asked].value;
		if (!which || !bc_value_at(which - 1, &x)) continue;
		printf("%s", first ? "" : ", "); jkey(stdout, i < n_asked ? asked[i] : set_[i - n_asked].key);
		printf("{"); jkv(stdout, "unit", x.number->name);
		if (x.number->has_min) printf(", \"min\": %s", num(x.number->min));
		if (x.number->has_max) printf(", \"max\": %s", num(x.number->max));
		printf("}");
		first = 0;
	}
	printf("},\n \"unused\": [");
	first = 1;
	for (int i = 0; i < n_set; i++)
		if (!set_[i].used) { printf("%s", first ? "" : ", "); jstr(stdout, set_[i].key); first = 0; }
	printf("]}\n");
}

/* one bot, and its tree as the engine holds it */
/* is pick `id` one that draws again at every choice */
static int each_parent(const bt_forest *f, int id)
{
	bt_node pk;
	return bt_forest_node(f, id, &pk) && pk.roll == BT_ROLL_EACH;
}

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
	if (n.kind == BT_K_PICK && n.roll == BT_ROLL_EACH)
	{
		if (ns.running)
			printf("  %s[a lottery at every choice: drawn %.1f s ago, again in %.1f s]%s", DIM, (double)ns.elapsed, (double)ns.remaining, OFF);
		else
			printf("  %s[a lottery at every choice]%s", DIM, OFF);
	}
	else if (n.kind == BT_K_PICK && n.roll)
		printf("  %s[a role, drawn %s]%s", DIM, n.roll == BT_ROLL_ONCE ? "once for this bot" : "for this life", OFF);
	else if (n.kind == BT_K_PICK && ns.running)
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
			else if (w[k].option == id && w[k].weighed && w[k].share > 0)       /* a lottery */
				printf("  %s%.2f x %.2f x %s = %.3f: %s%.0f%% of the draw%s%s", DIM, (double)w[k].score, (double)w[k].weight,
					num(w[k].factor), (double)w[k].worth, OFF, 100.0 * (double)w[k].share,
					w[k].held ? (each_parent(f, n.parent) ? "  <- the last draw" : "  <- its role") : "", OFF);
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
	float mixw[BC_KINDS_MAX] = {0};
	int a = as_name ? bc_kinds_by_name(&K, as_name) : BC_A_SOLDIER;
	if (a < 0) { fprintf(stderr, "bttree: no archetype called %s\n", as_name); return 1; }
	mixw[a] = 1;
	as_name = NULL;                         /* its weights are in the numbers shown */
	bc_rng r; bc_persona p;
	bc_rng_seed(&r, 4242 + (uint64_t)seed, 11);
	bc_kinds_roll(&K, &p, &r, mixw, level);
	bt_ctx ctx = {&r, p.trait, BC_T_COUNT, 0.1f, split_random, 4242u + (uint64_t)seed};
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
		fputs(",\n  \"bot\": {", o); jkv(o, "archetype", K.k[p.archetype].name);
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
			K.k[p.archetype].name, p.level, ticks, ticks > 1 ? "s" : "", ticks * 0.1,
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

/* ---- --list: the trees of the files, for whoever chooses one ------------ */

static void count_under(const bt_source *src, int id, int *nodes, FILE *refs, int *n_refs)
{
	bt_node n;
	bt_source_node(src, id, &n);
	(*nodes)++;
	if (n.kind == BT_K_TREE && refs) { if ((*n_refs)++) fputs(", ", refs); jstr(refs, n.name); }
	for (int k = n.first_child; k >= 0;) {
		bt_node ch;
		count_under(src, k, nodes, refs, n_refs);
		bt_source_node(src, k, &ch);
		k = ch.next_sibling;
	}
}

static int list_trees(int as_json)
{
	bt_tree t;
	int some = 0;
	if (as_json) fputs("{\"format\": \"lsd-bt-trees\", \"version\": 1, \"trees\": [", stdout);
	for (int f = 0; f < n_files; f++)
		for (int i = 0; bt_source_tree(files[f].src, i, &t); i++) {
			int nodes = 0, n_refs = 0;
			if (as_json) {
				printf("%s\n  {", some++ ? "," : "");
				jkv(stdout, "name", t.name); fputs(", ", stdout);
				jkv(stdout, "file", files[f].path);
				printf(", \"line\": %d, \"refers\": [", t.line);
				count_under(files[f].src, t.root, &nodes, stdout, &n_refs);
				printf("], \"nodes\": %d", nodes);
				if (t.above || t.comment) {
					/* what its author said of it: the comment lines right above it, or the one on its line */
					char said[600] = "";
					size_t n = 0;
					for (const char *q = t.above; q && *q; q += strcspn(q, "\n"), q += *q == '\n') {
						if (*q != '#') { n = 0; said[0] = 0; continue; }
						const char *w = q + 1 + (q[1] == ' ');
						n += (size_t)snprintf(said + n, n < sizeof said ? sizeof said - n : 0, "%s%.*s", n ? " " : "", (int)strcspn(w, "\n"), w);
						if (n >= sizeof said) n = sizeof said - 1;
					}
					if (t.comment) snprintf(said, sizeof said, "%s", t.comment);
					if (said[0]) { fputs(", ", stdout); jkv(stdout, "about", said); }
				}
				fputs("}", stdout);
			} else {
				count_under(files[f].src, t.root, &nodes, NULL, &n_refs);
				printf("%-24s %4d nodes  %s:%d\n", t.name, nodes, files[f].path, t.line);
			}
		}
	if (as_json) fputs("\n]}\n", stdout);
	return 0;
}

/* one tree's own text, cut from the canonical text of its file */
static int format_tree(const bt_vocab *v, const char *only)
{
	for (int f = 0; f < n_files; f++) {
		int i = has_tree(files[f].src, only);
		if (i < 0) continue;
		char *text = canonical(files[f].src);
		bt_source *c = text ? bt_parse(v, text, NULL) : NULL;
		bt_tree t, next;
		if (!c) return 1;
		bt_source_tree(c, i, &t);
		int from = t.line, to = 1 << 30;
		for (const char *q = t.above; q && *q; q++) from -= *q == '\n';
		if (bt_source_tree(c, i + 1, &next)) {
			to = next.line;
			for (const char *q = next.above; q && *q; q++) to -= *q == '\n';
		}
		int line = 1;
		for (const char *q = text; *q; line++) {
			size_t len = strcspn(q, "\n");
			if (line >= from && line < to && !(line == from && len == 0)) printf("%.*s\n", (int)len, q);
			q += len + (q[len] == '\n');
		}
		free(text);
		bt_source_free(c);
		return 0;
	}
	fprintf(stderr, "bttree: no tree called %s\n", only);
	return 1;
}

/* ---- --watch, --bots: the engine's own bots, live ------------------------
 * botd answers requests left in a directory (bot/botd/watch.c): a file
 * `<name>.req` saying whom to watch, kept alive by being written again.
 * What comes back is the engine's JSON (bot/TREES.md, "the live view"),
 * passed through with --json, or drawn. */

static char watch_dir[600], req_path[700];
static volatile sig_atomic_t watch_stop;

static void on_stop(int sig) { (void)sig; watch_stop = 1; }
static void req_remove(void) { if (req_path[0]) remove(req_path); }

static double mono(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void nap_ms(int ms)
{
	struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
	nanosleep(&ts, NULL);
}

static int request_write(const char *watch, int hz)
{
	char tmp[720];
	snprintf(tmp, sizeof tmp, "%s.tmp", req_path);
	FILE *fh = fopen(tmp, "wb");
	if (!fh) return 0;
	fprintf(fh, "watch=%s\nhz=%d\n", watch, hz);
	fclose(fh);
	return rename(tmp, req_path) == 0;
}

static int watch_begin(const char *dir)
{
	const char *data = getenv("LSD_DATA") && *getenv("LSD_DATA") ? getenv("LSD_DATA") : "/data";
	struct stat st;
	if (dir) snprintf(watch_dir, sizeof watch_dir, "%s", dir);
	else snprintf(watch_dir, sizeof watch_dir, "%s/rw/botdebug", data);
	if (stat(watch_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
		fprintf(stderr, "bttree: no %s: the bot engine (botd) makes it when it runs with bots\n", watch_dir);
		return 0;
	}
	snprintf(req_path, sizeof req_path, "%s/bttree-%d.req", watch_dir, (int)getpid());
	atexit(req_remove);
	signal(SIGINT, on_stop);
	signal(SIGTERM, on_stop);
	return 1;
}

/* <dir>/<name>, whole, if it is there and was written after `since`
 * (0: whenever); the caller frees it */
static char *watch_read(const char *name, time_t since)
{
	char path[720];
	struct stat st;
	snprintf(path, sizeof path, "%s/%s", watch_dir, name);
	if (stat(path, &st) != 0 || (since && st.st_mtime < since)) return NULL;
	return slurp(path, NULL);
}

/* the roster, asked for and waited for (3 s) */
static jv *roster_get(char **raw)
{
	time_t t0 = time(NULL);
	double until = mono() + 3.0;
	if (!request_write("", 4)) { fprintf(stderr, "bttree: cannot write in %s\n", watch_dir); return NULL; }
	while (mono() < until && !watch_stop) {
		char *text = watch_read("bots.json", t0 - 1);
		if (text) {
			jr r = { text, 0 };
			jv *doc = jread(&r, 0);
			if (!r.bad && doc && doc->type == 'o') { if (raw) *raw = text; else free(text); return doc; }
			jfree(doc);
			free(text);
		}
		nap_ms(50);
	}
	fprintf(stderr, "bttree: the bot engine does not answer in %s (is the server running, with engine bots?)\n", watch_dir);
	return NULL;
}

static double jnumber(const jv *o, const char *key, double dflt)
{
	const jv *v = jget(o, key);
	return v && v->type == '#' ? v->number : dflt;
}

static int jtrue(const jv *o, const char *key)
{
	const jv *v = jget(o, key);
	return v && v->type == 't';
}

static int bots_cmd(const char *dir, int as_json)
{
	char *raw = NULL;
	if (!watch_begin(dir)) return 1;
	jv *doc = roster_get(&raw);
	if (!doc) return 1;
	if (as_json) {
		fputs(raw, stdout);
	} else {
		const jv *bots = jget(doc, "bots"), *world = jget(doc, "world");
		printf("%sthe world runs the tree %s%s\n", DIM, jtext(world, "tree") ? jtext(world, "tree") : "?", OFF);
		printf("%s%4s  %-16s %4s  %-8s %5s %6s  %-18s %s%s\n", BOLD, "pid", "name", "team", "kind", "level", "health", "tree", "doing", OFF);
		for (const jv *b = bots && bots->type == 'a' ? bots->kids : NULL; b; b = b->next) {
			char tree[64];
			const char *from = jtext(b, "tree_set");
			snprintf(tree, sizeof tree, "%s%s", jtext(b, "tree") ? jtext(b, "tree") : "", from && !strcmp(from, "bot") ? " (its own)" : "");
			printf("%4d  %-16s %4d  %-8s %5d %6d  %-18s %s\n", (int)jnumber(b, "pid", -1), jtext(b, "name") ? jtext(b, "name") : "",
			       (int)jnumber(b, "team", 0), jtext(b, "archetype") ? jtext(b, "archetype") : "", (int)jnumber(b, "level", 0),
			       (int)jnumber(b, "health", 0), tree, jtext(b, "doing") ? jtext(b, "doing") : "");
		}
	}
	free(raw);
	jfree(doc);
	return 0;
}

/* a snapshot drawn: the nodes are a flat list with each one's parent */
typedef struct vnode { const jv *j; int id, parent, running, shown, hidden; const char *kind, *text; } vnode;

static void view_words(const vnode *n)
{
	const char *sp = strchr(n->text, ' '), *rest = sp ? sp : "";
	if (!strcmp(n->kind, "do")) printf("%sdo%s %s%s%s", ACT, OFF, BOLD, sp ? sp + 1 : "", OFF);
	else if (!strcmp(n->kind, "if") || !strcmp(n->kind, "unless")) printf("%s%s%s%s", ASK, n->kind, OFF, rest);
	else printf("%s%s%s%s", KEY, n->kind, OFF, rest);
}

/* is node `id` a pick that draws again at every choice */
static int view_each(const vnode *v, int n, int id)
{
	for (int k = 0; k < n; k++)
		if (v[k].id == id) return jtext(v[k].j, "roll") && !strcmp(jtext(v[k].j, "roll"), "each");
	return 0;
}

static void view_node(vnode *v, int n, int i, const char *prefix, int last)
{
	const vnode *nd = &v[i];
	const char *tee = plain ? (last ? "`- " : "|- ") : (last ? "└─ " : "├─ ");
	const char *bar = plain ? (last ? "   " : "|  ") : (last ? "   " : "│  ");
	const jv *w = jget(nd->j, "worth");
	printf("%s%4d %s%s%s%s%s%s", DIM, nd->id, OFF, nd->running ? (plain ? "> " : "▶ ") : "  ", DIM, prefix, tee, OFF);
	if (nd->running) printf("%s", BOLD);
	view_words(nd);
	if (!strcmp(nd->kind, "pick") && jget(nd->j, "remaining"))
		printf("  %s[chose %.1f s ago, again in %.1f s]%s", DIM, jnumber(nd->j, "elapsed", 0), jnumber(nd->j, "remaining", 0), OFF);
	else if (!strcmp(nd->kind, "cooldown") && jget(nd->j, "remaining"))
		printf("  %s[cooling: %.1f s left]%s", DIM, jnumber(nd->j, "remaining", 0), OFF);
	else if (jget(nd->j, "remaining"))
		printf("  %s[%.1f s in, %.1f s left]%s", DIM, jnumber(nd->j, "elapsed", 0), jnumber(nd->j, "remaining", 0), OFF);
	if (jtext(nd->j, "roll") && !strcmp(jtext(nd->j, "roll"), "each"))
		printf("  %s[a lottery at every choice]%s", DIM, OFF);
	else if (jtext(nd->j, "roll"))
		printf("  %s[a role, drawn %s]%s", DIM, !strcmp(jtext(nd->j, "roll"), "once") ? "once for this bot" : "for this life", OFF);
	if (w && !(jnumber(w, "score", 0) > 0))
		printf("  %sscore 0%s", DIM, OFF);
	else if (w && jget(w, "share"))
		printf("  %s%.2f x %.2f x %s = %.3f: %s%.0f%% of the draw%s%s", DIM, jnumber(w, "score", 0), jnumber(w, "weight", 0),
		       num(jnumber(w, "factor", 1)), jnumber(w, "worth", 0), OFF, 100.0 * jnumber(w, "share", 0),
		       jtrue(w, "held") ? (view_each(v, n, nd->parent) ? "  <- the last draw" : "  <- its role") : "", OFF);
	else if (w)
		printf("  %s%.2f x %.2f x %s x %.2f x %.2f = %s%.3f%s%s", DIM, jnumber(w, "score", 0), jnumber(w, "weight", 0),
		       num(jnumber(w, "factor", 1)), jnumber(w, "luck", 0), jnumber(w, "sticky", 1), OFF, jnumber(w, "worth", 0),
		       jtrue(w, "held") ? "  <- held" : "", OFF);
	if (nd->hidden) printf("  %s(+%d)%s", DIM, nd->hidden, OFF);
	printf("%s\n", OFF);
	char deeper[1024];
	snprintf(deeper, sizeof deeper, "%s%s", prefix, bar);
	int lastkid = -1;
	for (int k = i + 1; k < n; k++) if (v[k].parent == nd->id && v[k].shown) lastkid = k;
	for (int k = i + 1; k < n; k++) if (v[k].parent == nd->id && v[k].shown) view_node(v, n, k, deeper, k == lastkid);
}

/* `full`: every node; else the RUNNING path, what hangs directly from
 * it (a pick's options, a seq's steps), and a count of the rest */
static void view_snapshot(const jv *doc, int full)
{
	const jv *bot = jget(doc, "bot"), *nodes = jget(doc, "nodes"), *trees = jget(doc, "trees"), *wts = jget(bot, "weights");
	int n = 0, k = 0;
	for (const jv *x = nodes && nodes->type == 'a' ? nodes->kids : NULL; x; x = x->next) n++;
	vnode *v = calloc((size_t)n + 1, sizeof *v);
	if (!v) return;
	for (const jv *x = nodes && nodes->type == 'a' ? nodes->kids : NULL; x; x = x->next, k++) {
		v[k].j = x;
		v[k].id = (int)jnumber(x, "id", -1);
		v[k].parent = (int)jnumber(x, "parent", -1);
		v[k].running = jtrue(x, "running");
		v[k].kind = jtext(x, "kind") ? jtext(x, "kind") : "?";
		v[k].text = jtext(x, "text") ? jtext(x, "text") : "?";
	}
	for (k = 0; k < n; k++) {
		int pr = 0;
		for (int q = 0; q < k; q++) if (v[q].id == v[k].parent) pr = v[q].running && v[q].shown;
		v[k].shown = full || v[k].parent < 0 || v[k].running || pr;
	}
	for (k = n - 1; k >= 0; k--) {              /* what is not shown, counted on the nearest shown one above */
		if (v[k].shown) continue;
		for (int q = k - 1, want = v[k].parent; q >= 0; q--)
			if (v[q].id == want) { if (v[q].shown) { v[q].hidden++; break; } want = v[q].parent; }
	}
	printf("%s%s%s  #%d, team %d: a %s, level %d, health %d, %s%s\n", BOLD, jtext(bot, "name") && *jtext(bot, "name") ? jtext(bot, "name") : "bot", OFF,
	       (int)jnumber(bot, "pid", -1), (int)jnumber(bot, "team", 0), jtext(bot, "archetype") ? jtext(bot, "archetype") : "?",
	       (int)jnumber(bot, "level", 0), (int)jnumber(bot, "health", 0), jtrue(bot, "alive") ? "alive" : "DEAD", OFF);
	printf("%s%s; sees %d, %s%s%s\n", DIM, jtext(bot, "route") ? jtext(bot, "route") : "", (int)jnumber(bot, "sees", 0),
	       jtext(bot, "alert") ? jtext(bot, "alert") : "", jnumber(bot, "target", -1) >= 0 ? ", fighting #" : "",
	       jnumber(bot, "target", -1) >= 0 ? num(jnumber(bot, "target", -1)) : "");
	fputs("weights:", stdout);
	for (const jv *t = wts && wts->type == 'o' ? wts->kids : NULL; t; t = t->next)
		if (t->key && strcmp(t->key, "none")) printf(" %s %.2f", t->key, t->type == '#' ? t->number : 0.0);
	printf("%s\n", OFF);
	for (const jv *t = trees && trees->type == 'a' ? trees->kids : NULL; t; t = t->next) {
		int root = (int)jnumber(t, "root", -1);
		const char *from = jtext(bot, "tree_from");
		printf("\n%s%s%s %s(%s%s)%s  %s%s%s\n", BOLD, jtext(t, "name") ? jtext(t, "name") : "?", OFF, DIM,
		       jtext(t, "role") && !strcmp(jtext(t, "role"), "also") ? "ticked beside, at every decision" : "its tree",
		       from && !strcmp(from, "own") ? ", its own" : "", OFF, BOLD,
		       jtext(t, "role") && !strcmp(jtext(t, "role"), "main") && jtext(bot, "doing") ? jtext(bot, "doing") : "", OFF);
		for (k = 0; k < n; k++) if (v[k].id == root) view_node(v, n, k, "", 1);
	}
	if (!jtrue(doc, "traced")) printf("%s(not traced yet: the options' numbers come at its next choice)%s\n", DIM, OFF);
	printf("%s  id   an option: score x weight x factor x luck x sticky = worth%s%s\n", DIM, full ? "" : "   (+N): nodes not shown; --full shows all", OFF);
	free(v);
}

static int watch_cmd(const char *dir, const char *who, int hz, int once, int as_json, int full)
{
	if (!watch_begin(dir)) return 1;
	jv *ros = roster_get(NULL);
	if (!ros) return 1;
	const jv *bots = jget(ros, "bots");
	int pid = -1;
	char *end = NULL;
	long asked = who ? strtol(who, &end, 10) : -1;
	for (const jv *b = bots && bots->type == 'a' ? bots->kids : NULL; b && pid < 0; b = b->next) {
		const char *name = jtext(b, "name");
		if (!who ? jtrue(b, "alive") : end && !*end ? (long)jnumber(b, "pid", -1) == asked : name && !strcmp(name, who))
			pid = (int)jnumber(b, "pid", -1);
	}
	if (pid < 0 && !who && bots && bots->kids) pid = (int)jnumber(bots->kids, "pid", -1);
	jfree(ros);
	if (pid < 0) {
		fprintf(stderr, who ? "bttree: no bot called %s (bttree --bots lists them)\n" : "bttree: the engine has no bot%s\n", who ? who : "");
		return 1;
	}
	char list[16], name[32], *prev = NULL;
	snprintf(list, sizeof list, "%d", pid);
	snprintf(name, sizeof name, "bot-%d.json", pid);
	if (hz < 1) hz = 4;
	if (hz > 20) hz = 20;
	time_t t0 = time(NULL);
	double began = mono(), touched = 0, heard = mono();
	int frames = 0, rc = 0;
	while (!watch_stop) {
		double now = mono();
		if (now - touched >= 3.0) { request_write(list, hz); touched = now; }
		char *text = watch_read(name, t0 - 1);
		if (text && (!prev || strcmp(text, prev))) {
			jr r = { text, 0 };
			jv *doc = jread(&r, 0);
			heard = now;
			if (!r.bad && doc && doc->type == 'o') {
				/* one snapshot only: the first where a pick on the RUNNING path has
				 * its numbers (or what there is after 4 s) */
				const jv *nodes = jget(doc, "nodes");
				int ready = !once || now - began > 4.0;
				for (const jv *x = nodes && nodes->type == 'a' ? nodes->kids : NULL; x && !ready; x = x->next)
					ready = jtrue(x, "running") && jget(x, "worth") != NULL;
				if (ready && as_json) { fputs(text, stdout); fflush(stdout); }
				else if (ready) {
					if (!once && colour) fputs("\033[H\033[J", stdout);
					else if (frames) fputs("\n", stdout);
					view_snapshot(doc, full);
					fflush(stdout);
				}
				frames += ready;
			}
			jfree(doc);
			free(prev);
			prev = text;
			if (once && frames) break;
		} else {
			free(text);
			if (now - heard > 5.0) {
				fprintf(stderr, "bttree: nothing more about bot %d (it left, or the engine stopped)\n", pid);
				rc = 1;
				break;
			}
		}
		nap_ms(1000 / hz / 2 > 20 ? 1000 / hz / 2 : 20);
	}
	free(prev);
	return rc;
}

static int usage(void)
{
	fprintf(stderr,
		"usage: bttree [--tree NAME] [--as ARCHETYPE] [--plain] FILE.bt...     draw\n"
		"       bttree --check [--json] FILE.bt...                            is it right\n"
		"       bttree --split [--why] [--tree NAME] [--n 700] [--mix camper:2,pusher] [--level 5] FILE.bt... [WORD=VALUE]...\n"
		"       bttree --trace [--json] [--tree NAME] [--as ARCHETYPE] [--seed 0] [--level 5] [--secs 0] FILE.bt... [WORD=VALUE]...\n"
		"       bttree --json [--expanded] FILE.bt... | --from-json FILE | --format FILE.bt... | --roundtrip FILE.bt...\n"
		"       bttree --words [--md] | --schema | --doc FILE.md... | --list [--json] FILE.bt...\n"
		"       bttree --bots [--json] [--dir DIR]                              the engine's bots, now\n"
		"       bttree --watch [--bot PID|NAME] [--full] [--once] [--json] [--hz 4] [--dir DIR]   one of them, live\n"
		"  --archetypes FILE (as often as wanted): the kinds of player, read over the built-in ones; without it,\n"
		"  the archetypes.txt beside the trees given (--schema, --as, --mix name these kinds)\n");
	return 2;
}

int main(int argc, char **argv)
{
	const char *only = NULL, *mix = NULL, *from = NULL, *dir = NULL, *who = NULL, *view = NULL;
	int do_watch = 0, do_bots = 0, do_list = 0, hz = 4, once = 0, full_view = 0;
	char *paths[MAX_FILES];
	int n_paths = 0, check = 0, list = 0, md = 0, do_split = 0, do_trace = 0, with_why = 0, crowd = 700, level = 5, seed = 0;
	int json = 0, expanded = 0, do_schema = 0, do_doc = 0, do_format = 0, do_round = 0;
	double secs = 0;
	int kinds_said = 0;

	bc_kinds_builtin(&K);
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--tree") && i + 1 < argc) only = argv[++i];
		else if (!strcmp(argv[i], "--as") && i + 1 < argc) as_name = argv[++i];
		else if (!strcmp(argv[i], "--archetypes") && i + 1 < argc) {
			if (!kinds_said) bc_kinds_builtin(&K);
			kinds_said = 1;
			if (!read_kinds(argv[++i], 1)) return 1;
		}
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
		else if (!strcmp(argv[i], "--watch")) do_watch = 1;
		else if (!strcmp(argv[i], "--bots")) do_bots = 1;
		else if (!strcmp(argv[i], "--list")) do_list = 1;
		else if (!strcmp(argv[i], "--once")) once = 1;
		else if (!strcmp(argv[i], "--full")) full_view = 1;
		else if (!strcmp(argv[i], "--bot") && i + 1 < argc) who = argv[++i];
		else if (!strcmp(argv[i], "--view") && i + 1 < argc) view = argv[++i];
		else if (!strcmp(argv[i], "--dir") && i + 1 < argc) dir = argv[++i];
		else if (!strcmp(argv[i], "--hz") && i + 1 < argc) hz = atoi(argv[++i]);
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
	/* no --archetypes: the archetypes.txt beside the trees given, if any
	 * (each directory once, in the order given) */
	for (int i = 0; !kinds_said && i < n_paths; i++) {
		char d[1024], p[1100];
		const char *sl = strrchr(paths[i], '/');
		int seen = 0;

		snprintf(d, sizeof d, "%.*s", sl ? (int)(sl - paths[i]) : 1, sl ? paths[i] : ".");
		for (int j = 0; j < i; j++) {
			const char *sj = strrchr(paths[j], '/');
			char dj[1024];
			snprintf(dj, sizeof dj, "%.*s", sj ? (int)(sj - paths[j]) : 1, sj ? paths[j] : ".");
			if (!strcmp(d, dj)) seen = 1;
		}
		snprintf(p, sizeof p, "%s/archetypes.txt", d);
		if (!seen && !read_kinds(p, 0)) return 1;
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
		for (int i = 0; i < bc_value_count(); i++) {
			bc_value x;
			char usage[128];
			bc_value_at(i, &x);
			bc_value_usage(i, usage, sizeof usage);
			printf("value %s%s%s -- %s (%s)\n", x.name, usage[0] ? " " : "", usage, x.doc, x.number->name);
		}
		return 0;
	}
	if (do_schema) return schema(stdout);
	if (view) {                             /* a snapshot somebody kept, drawn */
		char *text = slurp(view, NULL);
		jr r = { text, 0 };
		jv *doc = text ? jread(&r, 0) : NULL;
		if (!doc || r.bad || doc->type != 'o') { fprintf(stderr, "bttree: %s is not a snapshot\n", view); return 1; }
		view_snapshot(doc, full_view);
		return 0;
	}
	if (do_bots) return bots_cmd(dir, json);
	if (do_watch) return watch_cmd(dir, who, hz, once, json, full_view);

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
	if (do_list) return list_trees(json);
	if (do_split) return split(only, crowd, mix, level, with_why || json, json);
	if (json) {
		if (only && has_tree(whole, only) < 0) { fprintf(stderr, "bttree: no tree called %s\n", only); return 1; }
		json_only = only;
		json_all(stdout, expanded);
		return 0;
	}
	if (do_format && only) return format_tree(v, only);
	if (do_format) {
		for (int i = 0; i < n_files; i++) {
			char *text = canonical(files[i].src);
			if (text) fputs(text, stdout);
			free(text);
		}
		return 0;
	}

	if (as_name) {
		int a = bc_kinds_by_name(&K, as_name);
		if (a < 0) { fprintf(stderr, "bttree: no archetype called %s\n", as_name); return 1; }
		archetype_means(a, as_weight);
	}
	return draw_all(whole, only);
}
