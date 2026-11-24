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

static int usage(void)
{
	fprintf(stderr, "usage: bttree [--tree NAME] [--as ARCHETYPE] [--check] [--words] [--plain] FILE.bt...\n");
	return 2;
}

int main(int argc, char **argv)
{
	const char *only = NULL, *files[64];
	int n_files = 0, check = 0, words = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--tree") && i + 1 < argc) only = argv[++i];
		else if (!strcmp(argv[i], "--as") && i + 1 < argc) as_name = argv[++i];
		else if (!strcmp(argv[i], "--check")) check = 1;
		else if (!strcmp(argv[i], "--words")) words = 1;
		else if (!strcmp(argv[i], "--plain")) plain = 1;
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
