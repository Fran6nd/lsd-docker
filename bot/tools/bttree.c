/* bttree.c -- Look at a behaviour tree
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 *   bttree [options] FILE.bt...
 *
 *   (no option)       draw every tree of the files, `tree <name>` references
 *                     opened in place
 *   --tree NAME       draw that tree only
 *   --as ARCHETYPE    beside every weighed option, what that kind of bot's
 *                     weight for its trait is (the mean of 400 rolled bots):
 *                     camper, pusher, flanker, support, sapper, scout, soldier
 *   --check           draw nothing: compile with the engine's own compiler and
 *                     vocabulary, say what is wrong and where, exit 1 if so
 *   --words           list the vocabulary a tree may use, and exit
 *   --split [WORD=VALUE]...
 *                     TUNING: who would do what. A situation is given as
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
 *   --plain           no colours, ASCII lines
 *
 * A tree is always compiled first (as --check does), so what is drawn is
 * a tree the engine accepts. The drawing is made from the text, which is
 * the tree: one node a line, children indented (bot/core/bt.h).
 * `tree items` and `tree extras` are filled in at run time -- by the
 * inventory's items and by server scripts -- and are drawn as such.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bt.h"
#include "persona.h"
#include "rng.h"
#include "vocab.h"

enum { MAX_NODES = 4096, MAX_TEXT = 1 << 20, MAX_LINE = 512, MAX_OPEN = 16 };

typedef struct node {
	int depth;                 /* 0 for a tree's root */
	int tree;                  /* index of its tree, for a root: -1 else */
	char text[MAX_LINE];       /* the node, without its comment */
	char note[MAX_LINE];       /* its comment, without the # */
} node;

static node nodes[MAX_NODES];
static int n_nodes;
static struct { char name[BT_NAME_MAX]; int first, count; } trees[256];
static int n_trees;

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
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	char *buf = malloc(MAX_TEXT + 1);
	size_t n = buf ? fread(buf, 1, MAX_TEXT, f) : 0;
	fclose(f);
	if (!buf) return NULL;
	buf[n] = 0;
	*len = n;
	return buf;
}

static void rtrim(char *s)
{
	size_t n = strlen(s);
	while (n && (s[n-1] == ' ' || s[n-1] == '\t' || s[n-1] == '\r' || s[n-1] == '\n')) s[--n] = 0;
}

/* The text into nodes: the same reading of indentation as bt.c (tabs, or
 * the step the first indented line uses), kept simple because the text
 * has compiled already. */
static int read_nodes(const char *text)
{
	int step = 0, base = -1, cur_tree = -1;
	const char *p = text;
	while (*p) {
		char line[MAX_LINE];
		size_t n = 0;
		while (*p && *p != '\n' && n < sizeof line - 1) line[n++] = *p++;
		while (*p && *p != '\n') p++;
		if (*p == '\n') p++;
		line[n] = 0;

		char note[MAX_LINE] = "";
		char *hash = strchr(line, '#');
		if (hash) {
			const char *t = hash + 1;
			while (*t == ' ') t++;
			snprintf(note, sizeof note, "%s", t);
			rtrim(note);
			*hash = 0;
		}
		rtrim(line);
		int ind = 0, tabs = 0;
		const char *s = line;
		while (*s == ' ' || *s == '\t') { if (*s == '\t') tabs++; ind++; s++; }
		if (!*s) continue;

		size_t sl = strlen(s);
		if (ind == 0 && !strncmp(s, "tree ", 5) && s[sl-1] == ':') {
			if (n_trees == 256) return 0;
			snprintf(trees[n_trees].name, BT_NAME_MAX, "%.*s", (int)(sl - 6), s + 5);
			trees[n_trees].first = n_nodes;
			trees[n_trees].count = 0;
			cur_tree = n_trees++;
			base = -1;
			continue;
		}
		if (cur_tree < 0) {                 /* a text with no header: "main" */
			snprintf(trees[0].name, BT_NAME_MAX, "main");
			trees[0].first = 0; trees[0].count = 0;
			cur_tree = 0; n_trees = 1;
		}
		if (!tabs && ind > 0 && !step) step = ind;
		int level = tabs ? ind : (step ? ind / step : 0);
		if (base < 0) base = level;
		if (n_nodes == MAX_NODES) return 0;
		node *nd = &nodes[n_nodes++];
		nd->depth = level - base;
		nd->tree = nd->depth == 0 ? cur_tree : -1;
		snprintf(nd->text, sizeof nd->text, "%s", s);
		snprintf(nd->note, sizeof nd->note, "%s", note);
		trees[cur_tree].count++;
	}
	return 1;
}

static int find_tree(const char *name)
{
	for (int i = 0; i < n_trees; i++)
		if (!strcmp(trees[i].name, name)) return i;
	return -1;
}

static void word(const char *text, int k, char *out, size_t size)
{
	out[0] = 0;
	const char *s = text;
	for (int i = 0; ; i++) {
		while (*s == ' ') s++;
		if (!*s) return;
		const char *e = s;
		while (*e && *e != ' ') e++;
		if (i == k) { snprintf(out, size, "%.*s", (int)(e - s), s); return; }
		s = e;
	}
}

static void draw(int tree, const char *prefix, int *open, int n_open);

/* One node and what is under it; `i` is advanced past its subtree. */
static void draw_node(int *i, int end, const char *prefix, int last, int *open, int n_open)
{
	const node *nd = &nodes[*i];
	char kind[64], arg[64];
	word(nd->text, 0, kind, sizeof kind);
	word(nd->text, 1, arg, sizeof arg);

	const char *tee = plain ? (last ? "`- " : "|- ") : (last ? "└─ " : "├─ ");
	const char *bar = plain ? (last ? "   " : "|  ") : (last ? "   " : "│  ");

	printf("%s%s%s", DIM, prefix, tee);
	printf("%s", OFF);
	if (!strcmp(kind, "do"))
		printf("%sdo%s %s%s%s", ACT, OFF, BOLD, nd->text + 3, OFF);
	else if (!strcmp(kind, "if") || !strcmp(kind, "unless"))
		printf("%s%s%s %s", ASK, kind, OFF, nd->text + strlen(kind) + 1);
	else if (!strcmp(kind, "option")) {
		char score[64];
		word(nd->text, 2, score, sizeof score);
		const char *rest = strstr(nd->text, score);
		rest = rest ? rest + strlen(score) : "";
		printf("%soption%s %s%s%s %s%s", KEY, OFF, BOLD, arg, OFF, score, rest);
		int t = bc_trait_by_name(arg);
		if (as_name && t > 0)
			printf("  %s[%s weighs %s %.2f]%s", DIM, as_name, arg, (double)as_weight[t], OFF);
	} else if (!strcmp(kind, "tree"))
		printf("%stree%s %s", KEY, OFF, arg);
	else
		printf("%s%s%s%s", KEY, kind, OFF, nd->text + strlen(kind));
	if (nd->note[0]) printf("  %s# %s%s", DIM, nd->note, OFF);
	printf("\n");

	char deeper[1024];
	snprintf(deeper, sizeof deeper, "%s%s", prefix, bar);

	if (!strcmp(kind, "tree")) {            /* a reference: open it in place */
		int t = find_tree(arg);
		int seen = 0;
		for (int k = 0; k < n_open; k++) if (open[k] == t) seen = 1;
		if (t < 0)
			printf("%s%s%s(filled in at run time: %s)%s\n", DIM, deeper, plain ? "`- " : "└─ ",
				!strcmp(arg, "items") ? "each inventory item's own rule"
				: !strcmp(arg, "extras") ? "what server scripts bring, e.g. night"
				: "sent by the server", OFF);
		else if (seen || n_open == MAX_OPEN)
			printf("%s%s%s(again: %s)%s\n", DIM, deeper, plain ? "`- " : "└─ ", arg, OFF);
		else {
			open[n_open] = t;
			draw(t, deeper, open, n_open + 1);
		}
	}

	int depth = nd->depth;
	(*i)++;
	while (*i < end && nodes[*i].depth > depth) {
		/* is this child the last at its level? */
		int j = *i + 1, is_last = 1;
		while (j < end && nodes[j].depth > depth + 1) j++;
		if (j < end && nodes[j].depth == depth + 1) is_last = 0;
		draw_node(i, end, deeper, is_last, open, n_open);
	}
}

static void draw(int tree, const char *prefix, int *open, int n_open)
{
	int i = trees[tree].first, end = i + trees[tree].count;
	while (i < end) {
		int j = i + 1, is_last = 1;
		while (j < end && nodes[j].depth > 0) j++;
		if (j < end) is_last = 0;
		draw_node(&i, end, prefix, is_last, open, n_open);
	}
}

/* ---- --split: the tree ticked for a crowd, in a situation that is given */

enum { MAX_WORDS = 160, MAX_SET = 128, MAX_OUT = 64 };

static struct { char kind; char name[BT_NAME_MAX]; } words_[3 * MAX_WORDS];
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
 * given. The names come from the engine's own list (bc_vocab_dump). */
static bt_vocab *split_vocab(void)
{
	size_t need = bc_vocab_dump(NULL, 0);
	char *buf = malloc(need + 1);
	bt_vocab *v = bt_vocab_new();
	if (!buf || !v) return NULL;
	bc_vocab_dump(buf, need + 1);
	for (char *line = strtok(buf, "\n"); line; line = strtok(NULL, "\n")) {
		char kind[16], name[BT_NAME_MAX];
		if (sscanf(line, "%15s %31s", kind, name) != 2) continue;
		int k = !strcmp(kind, "cond") ? 0 : !strcmp(kind, "score") ? 1 : !strcmp(kind, "action") ? 2 : -1;
		if (k < 0 || n_words[k] == MAX_WORDS) continue;
		int i = n_words[k]++;
		snprintf(words_[k * MAX_WORDS + i].name, BT_NAME_MAX, "%s", name);
		if (k == 0) bt_vocab_cond(v, name, leaf[i].c);
		else if (k == 1) bt_vocab_score(v, name, leaf[i].s);
		else bt_vocab_action(v, name, leaf[i].a, NULL);
	}
	free(buf);
	for (int t = 0; t < BC_T_COUNT; t++) bt_vocab_trait(v, bc_trait_name(t), t);
	return v;
}

static int split(const char *text, const char *only, int n, const char *mix, int level)
{
	static char full[MAX_TEXT + 256];
	/* what the engine writes at run time: empty here unless the text has them */
	snprintf(full, sizeof full, "%s%s%s", text,
		strstr(text, "\ntree items:") ? "" : "\ntree items:\nnever\n\tif enemy_visible\n",
		strstr(text, "\ntree extras:") ? "" : "\ntree extras:\nnever\n\tif enemy_visible\n");
	bt_vocab *v = split_vocab();
	char err[256] = "";
	bt_forest *f = v ? bt_compile(v, full, err, sizeof err) : NULL;
	if (!f) { fprintf(stderr, "bttree: %s\n", err[0] ? err : "no vocabulary"); return 1; }
	int tree = only ? bt_forest_find(f, only) : 0;
	if (tree < 0) { fprintf(stderr, "bttree: no tree called %s\n", only); return 1; }

	float mixw[BC_A_COUNT];
	if (!bc_archetype_weights(mix ? mix : "", mixw)) { fprintf(stderr, "bttree: --mix %s?\n", mix); return 1; }

	static struct { char what[256]; int by[BC_A_COUNT]; int all; } out[MAX_OUT];
	int n_out = 0, crowd[BC_A_COUNT] = {0};
	bt_state *st = malloc(bt_state_size(f));
	if (!st) return 1;
	for (int k = 0; k < n; k++) {
		bc_rng r; bc_persona p;
		bc_rng_seed(&r, 4242 + (uint64_t)k, 11);
		bc_persona_roll(&p, &r, mixw, level);
		bt_ctx ctx = {&r, p.trait, BC_T_COUNT, 0.1f, split_random};
		bt_state_init(st, f);
		bt_status res = bt_tick(f, tree, st, &ctx);
		char what[256];
		if (res == BT_RUNNING) bt_describe(f, st, what, sizeof what);
		else snprintf(what, sizeof what, res == BT_SUCCESS ? "(done at once)" : "(nothing: the tree failed)");
		int o = 0;
		while (o < n_out && strcmp(out[o].what, what)) o++;
		if (o == MAX_OUT) o = MAX_OUT - 1;
		else if (o == n_out) { snprintf(out[o].what, sizeof out[o].what, "%s", what); n_out++; }
		out[o].all++; out[o].by[p.archetype]++; crowd[p.archetype]++;
		bt_reset(f, st, &ctx);
	}
	/* most chosen first */
	for (int i = 0; i < n_out; i++)
		for (int j = i + 1; j < n_out; j++)
			if (out[j].all > out[i].all) { __typeof__(out[0]) t = out[i]; out[i] = out[j]; out[j] = t; }

	printf("%s%d bots, level %d, tree %s%s\n", BOLD, n, level, only ? only : "(the first)", OFF);
	printf("%6s", "all");
	for (int a = 0; a < BC_A_COUNT; a++) if (crowd[a]) printf(" %7.7s", bc_archetype_name(a));
	printf("\n");
	for (int o = 0; o < n_out; o++) {
		printf("%5.1f%%", 100.0 * out[o].all / n);
		for (int a = 0; a < BC_A_COUNT; a++) if (crowd[a]) printf(" %6.0f%%", 100.0 * out[o].by[a] / crowd[a]);
		printf("  %s%s%s\n", BOLD, out[o].what, OFF);
	}
	int head = 0;
	for (int i = 0; i < n_asked; i++) {
		if (!strcmp(asked[i], "always")) continue;
		printf("%s%s%s", head++ ? ", " : "asked and not given (so 0): ", DIM, asked[i]);
		printf("%s", OFF);
	}
	if (head) printf("\n");
	for (int i = 0; i < n_set; i++)
		if (!set_[i].used) printf("given but never asked: %s\n", set_[i].key);
	free(st); bt_forest_free(f); bt_vocab_free(v);
	return 0;
}

static int usage(void)
{
	fprintf(stderr, "usage: bttree [--tree NAME] [--as ARCHETYPE] [--check] [--words] [--plain] FILE.bt...\n"
		"       bttree --split [--tree NAME] [--n 700] [--mix camper:2,pusher] [--level 5] FILE.bt... [WORD=VALUE]...\n");
	return 2;
}

int main(int argc, char **argv)
{
	const char *only = NULL, *files[64];
	int n_files = 0, check = 0, words = 0, do_split = 0, crowd = 700, level = 5;
	const char *mix = NULL;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--tree") && i + 1 < argc) only = argv[++i];
		else if (!strcmp(argv[i], "--as") && i + 1 < argc) as_name = argv[++i];
		else if (!strcmp(argv[i], "--check")) check = 1;
		else if (!strcmp(argv[i], "--words")) words = 1;
		else if (!strcmp(argv[i], "--plain")) plain = 1;
		else if (!strcmp(argv[i], "--split")) do_split = 1;
		else if (!strcmp(argv[i], "--n") && i + 1 < argc) crowd = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--level") && i + 1 < argc) level = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--mix") && i + 1 < argc) mix = argv[++i];
		else if (do_split && strchr(argv[i], '=') && argv[i][0] != '-') {
			char *eq = strchr(argv[i], '=');
			if (n_set < MAX_SET) {
				snprintf(set_[n_set].key, sizeof set_[0].key, "%.*s", (int)(eq - argv[i]), argv[i]);
				snprintf(set_[n_set].val, sizeof set_[0].val, "%s", eq + 1);
				n_set++;
			}
		}
		else if (argv[i][0] == '-') return usage();
		else if (n_files < 64) files[n_files++] = argv[i];
	}
	colour = !plain && isatty(1);

	if (words) {
		size_t need = bc_vocab_dump(NULL, 0);
		char *buf = malloc(need + 1);
		if (!buf) return 1;
		bc_vocab_dump(buf, need + 1);
		fputs(buf, stdout);
		free(buf);
		return 0;
	}
	if (!n_files) return usage();

	bt_vocab *v = bt_vocab_new();
	if (!v || !bc_vocab_register(v)) { fprintf(stderr, "bttree: no vocabulary\n"); return 1; }

	/* each file alone first, so a mistake is told with its own line */
	static char all[MAX_TEXT + 1];
	size_t used = 0;
	int bad = 0;
	for (int i = 0; i < n_files; i++) {
		size_t len;
		char *text = slurp(files[i], &len);
		if (!text) { fprintf(stderr, "bttree: cannot read %s\n", files[i]); return 1; }
		char err[256] = "";
		bt_forest *f = bt_compile(v, text, err, sizeof err);
		if (!f) {
			/* a file that only fails for a tree defined in another one
			 * is tried again with the rest, below */
			if (!strstr(err, "no tree")) {
				fprintf(stderr, "%s: %s\n", files[i], err);
				bad = 1;
			}
		} else
			bt_forest_free(f);
		if (used + len + 2 < sizeof all) {
			memcpy(all + used, text, len);
			used += len;
			all[used++] = '\n';
		}
		free(text);
	}
	all[used] = 0;
	if (!bad) {
		char err[256] = "";
		bt_forest *f = bt_compile(v, all, err, sizeof err);
		if (!f) {
			/* items and extras exist only at run time: not a mistake */
			if (!strstr(err, "items") && !strstr(err, "extras")) {
				fprintf(stderr, "%s%s\n", n_files > 1 ? "together: " : "", err);
				bad = 1;
			}
		} else
			bt_forest_free(f);
	}
	bt_vocab_free(v);
	if (bad) return 1;
	if (check) { printf("ok: %d file(s)\n", n_files); return 0; }
	if (do_split) {
		if (crowd < 1) crowd = 1;
		if (level < 1) level = 1;
		if (level > 10) level = 10;
		return split(all, only, crowd, mix, level);
	}

	if (as_name) {
		int a = bc_archetype_by_name(as_name);
		if (a < 0) { fprintf(stderr, "bttree: no archetype called %s\n", as_name); return 1; }
		float w[BC_A_COUNT] = {0};
		w[a] = 1;
		for (int k = 0; k < 400; k++) {
			bc_rng r; bc_persona p;
			bc_rng_seed(&r, 1000 + (uint64_t)k, 7);
			bc_persona_roll(&p, &r, w, 5);
			for (int t = 0; t < BC_T_COUNT; t++) as_weight[t] += p.trait[t] / 400.0f;
		}
	}

	if (!read_nodes(all)) { fprintf(stderr, "bttree: too large to draw\n"); return 1; }
	int open[MAX_OPEN];
	int drawn = 0;
	for (int t = 0; t < n_trees; t++) {
		if (only && strcmp(only, trees[t].name)) continue;
		if (drawn++) printf("\n");
		printf("%s%s%s\n", BOLD, trees[t].name, OFF);
		open[0] = t;
		draw(t, "", open, 1);
	}
	if (only && !drawn) { fprintf(stderr, "bttree: no tree called %s\n", only); return 1; }
	return 0;
}
