/* bt_test.c -- the behaviour tree runtime, with small test vocabularies */
#include "bt.h"
#include "persona.h"
#include "vocab.h"
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { N = 8 };
typedef struct Bot {
	int flag[N];
	float sc[N];
	bt_status ret[N];
	int calls[N], stops[N];
	double val[N];          /* the value `v <i>`, */
	int unknown[N];         /* or none now */
	bc_rng rng;
} Bot;

static int c_flag(void *b, const bt_args *a) { return ((Bot *)b)->flag[(int)a->num[0]]; }
static float s_sc(void *b, const bt_args *a) { return ((Bot *)b)->sc[(int)a->num[0]]; }
static bt_status a_act(void *b, const bt_args *a, float dt)
{
	Bot *bot = b;
	int i = (int)a->num[0];
	(void)dt;
	bot->calls[i]++;
	return bot->ret[i];
}
static void a_stop(void *b, const bt_args *a) { ((Bot *)b)->stops[(int)a->num[0]]++; }
static int v_val(void *b, const bt_args *a, double *out)
{
	Bot *bot = b;
	int i = (int)a->num[0];
	if (bot->unknown[i]) return 0;
	*out = bot->val[i];
	return 1;
}
static float rnd(void *b) { return bc_rng_float(&((Bot *)b)->rng); }

static bt_vocab *vocab;

typedef struct Rig { bt_forest *f; bt_state *s; Bot *bot; bt_ctx ctx; float w[BC_T_COUNT]; } Rig;

static int rig_open(Rig *r, const char *text, Bot *bot)
{
	char err[200];
	int i;
	memset(r, 0, sizeof *r);
	r->f = bt_compile(vocab, text, err, sizeof err);
	if (!r->f) { printf("compile failed: %s\n  in: %s\n", err, text); checks++; failed++; return 0; }
	r->s = malloc(bt_state_size(r->f));
	bt_state_init(r->s, r->f);
	r->bot = bot;
	for (i = 0; i < BC_T_COUNT; i++) r->w[i] = 1;
	r->ctx.bot = bot;
	r->ctx.weights = r->w;
	r->ctx.n_weights = BC_T_COUNT;
	r->ctx.random = rnd;
	return 1;
}
static void rig_close(Rig *r) { bt_forest_free(r->f); free(r->s); }
static bt_status rig_tick(Rig *r, float dt) { r->ctx.dt = dt; return bt_tick(r->f, 0, r->s, &r->ctx); }
static void bot_init(Bot *b, uint64_t seed)
{
	int i;
	memset(b, 0, sizeof *b);
	for (i = 0; i < N; i++) b->ret[i] = BT_SUCCESS;
	bc_rng_seed(&b->rng, seed, 1);
}

/* compile `text` and expect the error to start with "line <line>:" and contain `what` */
static void bad(const char *text, int line, const char *what)
{
	char err[200], want[32];
	bt_forest *f = bt_compile(vocab, text, err, sizeof err);
	snprintf(want, sizeof want, "line %d:", line);
	CHECK(f == NULL);
	if (f) { bt_forest_free(f); return; }
	if (strncmp(err, want, strlen(want)) != 0 || (what && !strstr(err, what))) {
		checks++; failed++;
		printf("FAIL error for {%s}: got \"%s\", wanted %s ... %s\n", text, err, want, what ? what : "");
	}
}

static const bt_status ST[3] = { BT_FAILURE, BT_SUCCESS, BT_RUNNING };

static void test_truth_tables(void)
{
	int x, y;
	Rig r;
	Bot b;
	for (x = 0; x < 3; x++)
		for (y = 0; y < 3; y++) {
			bt_status exp_seq, exp_sel;
			bot_init(&b, 1);
			b.ret[0] = ST[x]; b.ret[1] = ST[y];
			/* seq */
			exp_seq = ST[x] != BT_SUCCESS ? (ST[x] == BT_RUNNING ? BT_RUNNING : BT_FAILURE) : ST[y];
			exp_sel = ST[x] != BT_FAILURE ? ST[x] : ST[y];
			if (rig_open(&r, "seq\n\tdo act 0\n\tdo act 1\n", &b)) {
				CHECK(rig_tick(&r, 0.1f) == exp_seq);
				CHECK(b.calls[0] == 1);
				CHECK(b.calls[1] == (ST[x] == BT_SUCCESS ? 1 : 0));
				rig_close(&r);
			}
			bot_init(&b, 1);
			b.ret[0] = ST[x]; b.ret[1] = ST[y];
			if (rig_open(&r, "select\n\tdo act 0\n\tdo act 1\n", &b)) {
				CHECK(rig_tick(&r, 0.1f) == exp_sel);
				CHECK(b.calls[0] == 1);
				CHECK(b.calls[1] == (ST[x] == BT_FAILURE ? 1 : 0));
				rig_close(&r);
			}
		}
	for (x = 0; x < 3; x++) {
		bt_status inv = ST[x] == BT_RUNNING ? BT_RUNNING : ST[x] == BT_SUCCESS ? BT_FAILURE : BT_SUCCESS;
		bt_status alw = ST[x] == BT_RUNNING ? BT_RUNNING : BT_SUCCESS;
		bt_status nev = ST[x] == BT_RUNNING ? BT_RUNNING : BT_FAILURE;
		bot_init(&b, 1); b.ret[0] = ST[x];
		if (rig_open(&r, "invert\n\tdo act 0\n", &b)) { CHECK(rig_tick(&r, 0.1f) == inv); rig_close(&r); }
		if (rig_open(&r, "always\n\tdo act 0\n", &b)) { CHECK(rig_tick(&r, 0.1f) == alw); rig_close(&r); }
		if (rig_open(&r, "never\n\tdo act 0\n", &b)) { CHECK(rig_tick(&r, 0.1f) == nev); rig_close(&r); }
	}
	bot_init(&b, 1);
	if (rig_open(&r, "if flag 2\n", &b)) {
		CHECK(rig_tick(&r, 0.1f) == BT_FAILURE);
		b.flag[2] = 1;
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS);
		rig_close(&r);
	}
	if (rig_open(&r, "unless flag 2\n", &b)) {
		CHECK(rig_tick(&r, 0.1f) == BT_FAILURE);
		b.flag[2] = 0;
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS);
		rig_close(&r);
	}
	/* an action's answer other than the three is a failure */
	b.ret[0] = (bt_status)7;
	if (rig_open(&r, "do act 0\n", &b)) { CHECK(rig_tick(&r, 0.1f) == BT_FAILURE); rig_close(&r); }
}

static void test_resume(void)
{
	Rig r;
	Bot b;
	int k;
	bot_init(&b, 1);
	b.ret[1] = BT_RUNNING;
	if (rig_open(&r, "seq\n\tdo act 0\n\tdo act 1\n\tdo act 2\n", &b)) {
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING);
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING);
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING);
		CHECK(b.calls[0] == 1 && b.calls[1] == 3 && b.calls[2] == 0);
		b.ret[1] = BT_SUCCESS;
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS);
		CHECK(b.calls[0] == 1 && b.calls[1] == 4 && b.calls[2] == 1);
		CHECK(b.stops[1] == 0);               /* it finished: nothing to stop */
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS);   /* starts over */
		CHECK(b.calls[0] == 2);
		rig_close(&r);
	}
	bot_init(&b, 1);
	b.ret[0] = BT_FAILURE; b.ret[1] = BT_RUNNING;
	if (rig_open(&r, "select\n\tdo act 0\n\tdo act 1\n\tdo act 2\n", &b)) {
		for (k = 0; k < 3; k++) CHECK(rig_tick(&r, 0.1f) == BT_RUNNING);
		CHECK(b.calls[0] == 1 && b.calls[1] == 3);
		b.ret[1] = BT_FAILURE; b.ret[2] = BT_SUCCESS;
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS);
		CHECK(b.calls[0] == 1 && b.calls[2] == 1);
		rig_close(&r);
	}
	/* nested: the resume point survives through a decorator and an inner seq */
	bot_init(&b, 1);
	b.ret[1] = BT_RUNNING;
	if (rig_open(&r, "seq\n\tdo act 0\n\talways\n\t\tseq\n\t\t\tdo act 1\n\t\t\tdo act 2\n", &b)) {
		rig_tick(&r, 0.1f); rig_tick(&r, 0.1f);
		CHECK(b.calls[0] == 1 && b.calls[1] == 2);
		rig_close(&r);
	}
}

static void test_stops(void)
{
	Rig r;
	Bot b;
	char d[100];
	const char *pick =
		"pick every=1 sticky=0 noise=0\n"
		"\toption a sc 0\n\t\tseq\n\t\t\tdo act 0\n\t\t\tdo act 1\n"
		"\toption b sc 1\n\t\tdo act 2\n";

	/* pick changes its choice: the running action under the old option, once */
	bot_init(&b, 1);
	b.ret[0] = BT_SUCCESS; b.ret[1] = BT_RUNNING; b.ret[2] = BT_RUNNING;
	b.sc[0] = 1; b.sc[1] = 0.5f;
	if (rig_open(&r, pick, &b)) {
		CHECK(rig_tick(&r, 0.5f) == BT_RUNNING);
		CHECK(b.calls[1] == 1);
		bt_describe(r.f, r.s, d, sizeof d);
		CHECK(strcmp(d, "pick:a > act") == 0);
		b.sc[0] = 0.2f; b.sc[1] = 0.9f;
		rig_tick(&r, 0.5f);                      /* every=1 not yet up: stays */
		CHECK(b.stops[1] == 0 && b.calls[2] == 0);
		rig_tick(&r, 0.5f);                      /* up: flips */
		CHECK(b.stops[1] == 1 && b.stops[0] == 0 && b.calls[2] == 1);
		bt_describe(r.f, r.s, d, sizeof d);
		CHECK(strcmp(d, "pick:b > act") == 0);
		rig_tick(&r, 1.0f); rig_tick(&r, 1.0f);
		CHECK(b.stops[1] == 1);                  /* never twice */
		/* back again: option b's action is stopped once */
		b.sc[0] = 1; b.sc[1] = 0.1f;
		rig_tick(&r, 1.0f);
		CHECK(b.stops[2] == 1 && b.stops[1] == 1);
		/* reset: the running action stopped once, the state clean */
		bt_reset(r.f, r.s, &r.ctx);
		CHECK(b.stops[1] == 2 && b.stops[2] == 1);
		bt_reset(r.f, r.s, &r.ctx);
		CHECK(b.stops[1] == 2);
		bt_describe(r.f, r.s, d, sizeof d);
		CHECK(d[0] == 0);
		rig_close(&r);
	}
	/* pick finding nothing to choose: FAILURE, and the old one let go */
	bot_init(&b, 1);
	b.ret[2] = BT_RUNNING; b.sc[1] = 1; b.sc[0] = 0;
	if (rig_open(&r, pick, &b)) {
		CHECK(rig_tick(&r, 1.0f) == BT_RUNNING);
		b.sc[1] = 0;
		CHECK(rig_tick(&r, 1.0f) == BT_FAILURE);
		CHECK(b.stops[2] == 1);
		CHECK(rig_tick(&r, 1.0f) == BT_FAILURE);
		CHECK(b.stops[2] == 1);
		rig_close(&r);
	}
	/* limit fires */
	bot_init(&b, 1);
	b.ret[0] = BT_RUNNING;
	if (rig_open(&r, "limit 1\n\tseq\n\t\tdo act 1\n\t\tdo act 0\n", &b)) {
		CHECK(rig_tick(&r, 0.5f) == BT_RUNNING);
		CHECK(rig_tick(&r, 0.5f) == BT_RUNNING);
		CHECK(rig_tick(&r, 0.5f) == BT_FAILURE);
		CHECK(b.stops[0] == 1 && b.stops[1] == 0);
		CHECK(rig_tick(&r, 0.5f) == BT_RUNNING);   /* a fresh start */
		CHECK(b.calls[1] == 2);                    /* the seq began again from its first */
		CHECK(b.stops[0] == 1);
		rig_close(&r);
	}
	/* an option that ends: not stopped; pick returns its answer */
	bot_init(&b, 1);
	b.ret[2] = BT_SUCCESS; b.sc[1] = 1;
	if (rig_open(&r, pick, &b)) {
		CHECK(rig_tick(&r, 1.0f) == BT_SUCCESS);
		CHECK(b.stops[2] == 0);
		rig_close(&r);
	}
	/* a NULL stop is fine */
	bot_init(&b, 1);
	if (rig_open(&r, "do act 0\n", &b)) { b.ret[0] = BT_RUNNING; rig_tick(&r, 1); bt_reset(r.f, r.s, &r.ctx); rig_close(&r); }
}

static void test_timers(void)
{
	Rig r;
	Bot b;
	int i;
	bt_status w[4];
	bot_init(&b, 1);
	if (rig_open(&r, "wait 1\n", &b)) {
		for (i = 0; i < 4; i++) w[i] = rig_tick(&r, 0.5f);
		CHECK(w[0] == BT_RUNNING && w[1] == BT_RUNNING && w[2] == BT_SUCCESS && w[3] == BT_RUNNING);
		rig_close(&r);
	}
	if (rig_open(&r, "wait 0\n", &b)) { CHECK(rig_tick(&r, 0.5f) == BT_SUCCESS); rig_close(&r); }

	/* cooldown: SUCCESS once, then FAILURE for 2 s without asking */
	bot_init(&b, 1);
	if (rig_open(&r, "cooldown 2\n\tdo act 0\n", &b)) {
		CHECK(rig_tick(&r, 0.5f) == BT_SUCCESS);
		for (i = 0; i < 3; i++) CHECK(rig_tick(&r, 0.5f) == BT_FAILURE);   /* t=1.0 1.5 2.0 */
		CHECK(b.calls[0] == 1);
		CHECK(rig_tick(&r, 0.5f) == BT_SUCCESS);                           /* t=2.5 */
		CHECK(b.calls[0] == 2);
		CHECK(rig_tick(&r, 0.5f) == BT_FAILURE);
		rig_close(&r);
	}
	/* cooldown after a failure too; not while RUNNING */
	bot_init(&b, 1);
	b.ret[0] = BT_RUNNING;
	if (rig_open(&r, "cooldown 2\n\tdo act 0\n", &b)) {
		for (i = 0; i < 5; i++) CHECK(rig_tick(&r, 0.5f) == BT_RUNNING);
		b.ret[0] = BT_FAILURE;
		CHECK(rig_tick(&r, 0.5f) == BT_FAILURE);
		CHECK(rig_tick(&r, 0.5f) == BT_FAILURE);
		CHECK(b.calls[0] == 6);
		rig_close(&r);
	}
	/* limit: RUNNING within the limit, FAILURE past it, SUCCESS passes through */
	bot_init(&b, 1);
	b.ret[0] = BT_RUNNING;
	if (rig_open(&r, "limit 1\n\tdo act 0\n", &b)) {
		CHECK(rig_tick(&r, 0.5f) == BT_RUNNING);
		CHECK(rig_tick(&r, 0.5f) == BT_RUNNING);
		b.ret[0] = BT_SUCCESS;
		CHECK(rig_tick(&r, 0.25f) == BT_SUCCESS);
		b.ret[0] = BT_RUNNING;
		for (i = 0; i < 2; i++) CHECK(rig_tick(&r, 0.5f) == BT_RUNNING);   /* new run: 0, 0.5 */
		CHECK(rig_tick(&r, 0.5f) == BT_FAILURE);                           /* 1.0 */
		rig_close(&r);
	}
	/* a timer is right in a branch not ticked meanwhile: a cooldown inside a pick option */
	bot_init(&b, 1);
	b.sc[0] = 1;
	if (rig_open(&r, "pick every=0 noise=0\n\toption a sc 0\n\t\tcooldown 3\n\t\t\tdo act 0\n", &b)) {
		CHECK(rig_tick(&r, 1.0f) == BT_SUCCESS);
		CHECK(rig_tick(&r, 1.0f) == BT_FAILURE);
		b.sc[0] = 0;
		for (i = 0; i < 3; i++) CHECK(rig_tick(&r, 1.0f) == BT_FAILURE);   /* nothing chosen, time passes */
		b.sc[0] = 1;
		CHECK(rig_tick(&r, 1.0f) == BT_SUCCESS);
		rig_close(&r);
	}
}

static void test_trees(void)
{
	Rig r;
	Bot b;
	bt_forest *f;
	char err[200];
	const char *txt =
		"# two trees, the first using the second before it is written\n"
		"tree main:\n"
		"\tseq\n"
		"\t\ttree greet\n"
		"\t\ttree greet\n"
		"\n"
		"tree greet:\n"
		"\tselect   # a comment\n"
		"\t\tif flag 0\n"
		"\t\tdo act 1\n";
	bot_init(&b, 1);
	f = bt_compile(vocab, txt, err, sizeof err);
	CHECK(f != NULL);
	if (f) {
		CHECK(bt_forest_find(f, "main") == 0 && bt_forest_find(f, "greet") == 1 && bt_forest_find(f, "x") == -1);
		CHECK(bt_forest_nodes(f) == 10);   /* 7 for main (references inlined) + 3 */
		bt_forest_free(f);
	}
	/* mixed spaces/tabs and 4 spaces: the whole-text style is fixed by its first indent */
	if (rig_open(&r, txt, &b)) {
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS);
		CHECK(b.calls[1] == 2);                       /* each reference has its own state, both ran */
		b.flag[0] = 1;
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS);
		CHECK(b.calls[1] == 2);
		CHECK(bt_tick(r.f, 1, r.s, &r.ctx) == BT_SUCCESS);   /* the other tree on its own */
		CHECK(bt_tick(r.f, 5, r.s, &r.ctx) == BT_FAILURE);   /* no such tree */
		CHECK(bt_tick(r.f, -1, r.s, &r.ctx) == BT_FAILURE);
		rig_close(&r);
	}
	/* two-space and four-space texts compile too */
	bot_init(&b, 1);
	if (rig_open(&r, "select\n  seq\n    if flag 0\n    do act 0\n  do act 1\n", &b)) { CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS && b.calls[1] == 1); rig_close(&r); }
	if (rig_open(&r, "select\n    seq\n        if flag 0\n        do act 0\n    do act 1\n", &b)) { CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS); rig_close(&r); }
	/* the same tree twice under one running sequence keeps separate places */
	bot_init(&b, 1);
	b.ret[1] = BT_RUNNING;
	if (rig_open(&r, "tree main:\nseq\n\ttree a\n\ttree a\ntree a:\nseq\n\tdo act 0\n\tdo act 1\n", &b)) {
		rig_tick(&r, 0.1f); rig_tick(&r, 0.1f);
		CHECK(b.calls[0] == 1 && b.calls[1] == 2);
		b.ret[1] = BT_SUCCESS;
		rig_tick(&r, 0.1f);
		CHECK(b.calls[0] == 2);
		rig_close(&r);
	}
	/* errors */
	bad("tree a:\nselect\n\ttree zzz\n", 3, "zzz");
	bad("tree a:\nselect\n\ttree a\n", 3, "itself");
	bad("tree a:\nselect\n\ttree b\ntree b:\nseq\n\ttree c\ntree c:\nseq\n\ttree a\n", 9, "itself");
	bad("tree main:\nseq\n\ttree main\n", 3, "itself");
	bad("tree a:\ntree b\ntree b:\ntree a\n", 4, "itself");
}

static void test_malformed(void)
{
	bad("select\n\tdo nosuch\n", 2, "no action called nosuch");
	bad("select\n\tif nosuch 1\n", 2, "no condition called nosuch");
	bad("seq\n", 1, "at least one child");
	bad("select\n\tseq\n\tdo act 0\n", 2, "at least one child");
	bad("invert\n\tdo act 0\n\tdo act 1\n", 3, "exactly one child");
	bad("invert\n", 1, "needs a child");
	bad("do act 0\n\tdo act 1\n", 2, "no children");
	bad("pick\n\tdo act 0\n", 2, "only options");
	bad("pick\n", 1, "at least one child");
	bad("option a sc 0\n\tdo act 0\n", 1, "under a pick");
	bad("select\n\toption a sc 0\n\t\tdo act 0\n", 2, "under a pick");
	bad("pick\n\toption a sc 0\n", 2, "needs a child");
	bad("pick\n\toption a sc 0\n\t\tdo act 0\n\t\tdo act 1\n", 4, "exactly one child");
	bad("pick\n\toption zzz sc 0\n\t\tdo act 0\n", 2, "no trait called zzz");
	bad("pick\n\toption a nosuch\n\t\tdo act 0\n", 2, "no score called nosuch");
	bad("pick\n\toption a\n\t\tdo act 0\n", 2, "option needs");
	bad("pick bogus=3\n\toption a sc 0\n\t\tdo act 0\n", 1, "unknown setting");
	bad("pick every=abc\n\toption a sc 0\n\t\tdo act 0\n", 1, "number");
	bad("pick noise=2\n\toption a sc 0\n\t\tdo act 0\n", 1, "noise");
	bad("select\n  do act 0\n\tdo act 1\n", 3, "tab");
	bad("select\n\tdo act 0\n  do act 1\n", 3, "space indentation");
	bad("select\n \t do act 0\n", 2, "mixes tabs and spaces");
	bad("select\n   do act 0\n", 2, "two spaces or four");
	bad("select\n    seq\n     do act 0\n", 3, "multiple of 4");
	bad("select\n\t\tdo act 0\n", 2, "too deep");
	bad("select\n\tdo act 0\nselect\n", 3, "second");
	bad("select\n\tdo act 0\n\tdo act 1\n\n# c\nfoo\n", 6, "unknown node 'foo'");
	bad("wait abc\n", 1, "seconds");
	bad("wait\n", 1, "one number");
	bad("wait -1\n", 1, "0 or more");
	bad("limit 1 2\n\tdo act 0\n", 1, "one number");
	bad("if\n", 1, "condition name");
	bad("do\n", 1, "action name");
	bad("do act 1 2 3 4 5\n", 1, "at most 4");
	bad("seq extra\n\tdo act 0\n", 1, "no arguments");
	bad("tree x:\nseq\n\tdo act 0\ntree y:\nselect\n\tdo act 0\ntree x:\nseq\n\tdo act 0\n", 7, "twice");
	bad("tree x:\ntree y:\nseq\n\tdo act 0\n", 1, "empty");
	bad("seq\n\tdo act 0\ntree y:\nseq\n\tdo act 0\n", 3, "no tree");
	bad("\tdo act 0\n\tdo act 1\n", 2, "second");
	bad("select\n\tdo act 0\n\t\tdo act 1\n", 3, "no children");
	bad("tree x:\n\ttree y:\n", 2, "indented");
	bad("", 1, "no tree");
	bad("# only a comment\n\n", 1, "no tree");
	bad("select\n\tdo nosuch", 2, "nosuch");     /* no final newline, CRLF below */
	bad("select\r\n\tdo nosuch\r\n", 2, "nosuch");
	{
		char err[8];
		bt_forest *f = bt_compile(vocab, "bogus\n", err, sizeof err);   /* a tiny error buffer is fine */
		CHECK(f == NULL && strlen(err) < 8);
		f = bt_compile(vocab, "bogus\n", NULL, 0);
		CHECK(f == NULL);
	}
	/* numeric args are parsed; every text is kept; CRLF and comments are fine */
	{
		char err[100];
		bt_forest *f = bt_compile(vocab, "do act 3 foo 2.5 # note\r\n", err, sizeof err);
		CHECK(f != NULL);
		bt_forest_free(f);
	}
}

typedef struct ArgBot { float num[4]; char text[4][16]; int count; } ArgBot;
static bt_status a_args(void *b, const bt_args *a, float dt)
{
	ArgBot *ab = b;
	int i;
	(void)dt;
	ab->count = a->count;
	for (i = 0; i < a->count; i++) { ab->num[i] = a->num[i]; snprintf(ab->text[i], 16, "%s", a->text[i]); }
	return BT_SUCCESS;
}

static void test_args(void)
{
	bt_vocab *v = bt_vocab_new();
	bt_forest *f;
	bt_state *s;
	bt_ctx c;
	ArgBot ab;
	char err[100];
	memset(&ab, 0, sizeof ab);
	memset(&c, 0, sizeof c);
	CHECK(bt_vocab_action(v, "args", a_args, NULL));
	CHECK(!bt_vocab_action(v, "args", a_args, NULL));      /* taken */
	CHECK(!bt_vocab_action(v, "", a_args, NULL));
	CHECK(!bt_vocab_action(v, "x", NULL, NULL));
	CHECK(!bt_vocab_cond(v, "averyveryveryverylongnamethatdoesnotfit", c_flag));
	CHECK(bt_vocab_cond(v, "args", c_flag));               /* names are per kind */
	f = bt_compile(v, "do args 3 foo 2.5 -1e1", err, sizeof err);
	CHECK(f != NULL);
	if (f) {
		s = malloc(bt_state_size(f));
		bt_state_init(s, f);
		c.bot = &ab; c.dt = 0.1f;
		CHECK(bt_tick(f, 0, s, &c) == BT_SUCCESS);
		CHECK(ab.count == 4);
		CHECK(ab.num[0] == 3 && ab.num[1] == 0 && ab.num[2] == 2.5f && ab.num[3] == -10);
		CHECK(!strcmp(ab.text[0], "3") && !strcmp(ab.text[1], "foo") && !strcmp(ab.text[2], "2.5") && !strcmp(ab.text[3], "-1e1"));
		free(s);
		bt_forest_free(f);
	}
	bt_vocab_free(v);
}

static void test_pick(void)
{
	Rig r;
	Bot b;
	const char *two =
		"pick every=1 sticky=0.25 noise=0\n"
		"\toption a sc 0\n\t\tdo act 0\n"
		"\toption b sc 1\n\t\tdo act 1\n";
	int i;

	/* weight decides when scores are equal; ties go to the first */
	bot_init(&b, 1);
	b.ret[0] = b.ret[1] = BT_RUNNING;
	b.sc[0] = b.sc[1] = 0.5f;
	if (rig_open(&r, two, &b)) {
		rig_tick(&r, 1.0f);
		CHECK(b.calls[0] == 1 && b.calls[1] == 0);
		rig_close(&r);
	}
	if (rig_open(&r, two, &b)) {
		r.w[BC_T_AGGRESSION] = 1; r.w[BC_T_CAUTION] = 1;
		CHECK(bc_trait_by_name("aggression") == 1);
		memset(b.calls, 0, sizeof b.calls);
		r.w[1] = 2.0f; r.w[2] = 1.0f;
		rig_tick(&r, 1.0f);
		CHECK(b.calls[0] == 1 && b.calls[1] == 0);
		rig_close(&r);
	}
	if (rig_open(&r, two, &b)) {
		memset(b.calls, 0, sizeof b.calls);
		r.w[1] = 1.0f; r.w[2] = 2.0f;
		rig_tick(&r, 1.0f);
		CHECK(b.calls[0] == 0 && b.calls[1] == 1);
		rig_close(&r);
	}
	/* raising the other's score flips it */
	if (rig_open(&r, two, &b)) {
		memset(b.calls, 0, sizeof b.calls);
		r.w[1] = 2.0f; r.w[2] = 1.0f;
		b.sc[0] = 0.5f; b.sc[1] = 0.5f;
		rig_tick(&r, 1.0f);
		CHECK(b.calls[0] == 1);
		rig_close(&r);
		bot_init(&b, 1); b.ret[0] = b.ret[1] = BT_RUNNING;
		b.sc[0] = 0.5f; b.sc[1] = 1.2f;
		rig_open(&r, two, &b);
		r.w[1] = 2.0f; r.w[2] = 1.0f;
		rig_tick(&r, 1.0f);
		CHECK(b.calls[0] == 0 && b.calls[1] == 1);
		rig_close(&r);
	}
	/* a missing or out-of-range trait weighs 1 */
	bot_init(&b, 1); b.ret[0] = b.ret[1] = BT_RUNNING;
	b.sc[0] = 0.4f; b.sc[1] = 0.5f;
	if (rig_open(&r, two, &b)) {
		r.ctx.weights = NULL; r.ctx.n_weights = 0;
		rig_tick(&r, 1.0f);
		CHECK(b.calls[1] == 1);
		rig_close(&r);
	}
	if (rig_open(&r, two, &b)) {
		r.ctx.n_weights = 2;   /* trait 2 is out of range: 1; trait 1 is 3 */
		r.w[1] = 3.0f; r.w[2] = 100.0f;
		memset(b.calls, 0, sizeof b.calls);
		rig_tick(&r, 1.0f);
		CHECK(b.calls[0] == 1);
		rig_close(&r);
	}
	/* a factor multiplies */
	if (rig_open(&r, "pick noise=0\n\toption a sc 0 x4\n\t\tdo act 0\n\toption b sc 1\n\t\tdo act 1\n", &b)) {
		memset(b.calls, 0, sizeof b.calls);
		b.sc[0] = 0.3f; b.sc[1] = 1.0f;
		rig_tick(&r, 1.0f);
		CHECK(b.calls[0] == 1);
		rig_close(&r);
	}
	/* score 0 is never chosen, even alone with a big weight; all 0 fails */
	bot_init(&b, 1); b.ret[0] = b.ret[1] = BT_RUNNING;
	if (rig_open(&r, two, &b)) {
		b.sc[0] = 0; b.sc[1] = 0;
		CHECK(rig_tick(&r, 1.0f) == BT_FAILURE);
		b.sc[1] = 0.01f;
		CHECK(rig_tick(&r, 1.0f) == BT_RUNNING);
		CHECK(b.calls[0] == 0 && b.calls[1] == 1);
		rig_close(&r);
	}
	/* sticky holds a choice against a slightly better rival, not a much better one */
	bot_init(&b, 1); b.ret[0] = b.ret[1] = BT_RUNNING;
	b.sc[0] = 0.5f; b.sc[1] = 0.4f;
	if (rig_open(&r, two, &b)) {
		rig_tick(&r, 1.0f);                       /* chose a */
		CHECK(b.calls[0] == 1);
		b.sc[1] = 0.55f;                          /* 0.55 < 0.5 * 1.25 */
		for (i = 0; i < 4; i++) rig_tick(&r, 1.0f);
		CHECK(b.calls[1] == 0 && b.stops[0] == 0);
		b.sc[1] = 0.7f;                           /* 0.7 > 0.625 */
		rig_tick(&r, 1.0f);
		CHECK(b.calls[1] == 1 && b.stops[0] == 1);
		rig_close(&r);
	}
	/* without sticky the slightly better rival wins */
	bot_init(&b, 1); b.ret[0] = b.ret[1] = BT_RUNNING;
	b.sc[0] = 0.5f; b.sc[1] = 0.4f;
	if (rig_open(&r, "pick every=1 sticky=0 noise=0\n\toption a sc 0\n\t\tdo act 0\n\toption b sc 1\n\t\tdo act 1\n", &b)) {
		rig_tick(&r, 1.0f);
		b.sc[1] = 0.55f;
		rig_tick(&r, 1.0f);
		CHECK(b.calls[1] == 1);
		rig_close(&r);
	}
	/* an option that ends makes the pick choose again next tick, with no stickiness for it */
	bot_init(&b, 1); b.ret[0] = BT_SUCCESS; b.ret[1] = BT_RUNNING;
	b.sc[0] = 0.5f; b.sc[1] = 0.45f;
	if (rig_open(&r, "pick every=100 noise=0\n\toption a sc 0\n\t\tdo act 0\n\toption b sc 1\n\t\tdo act 1\n", &b)) {
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS);   /* a ended */
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS);   /* chosen anew, a again */
		b.sc[0] = 0.1f;
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING);   /* a ended again, so b now */
		rig_close(&r);
	}
}

/* ---- the feature: the same tree, the same situation, different bots ---- */

typedef struct Pop { Bot bot; bc_persona p; } Pop;

static void test_population(void)
{
	const char *txt =
		"pick every=2 noise=0.1\n"
		"\toption aggression sc 0\n\t\tdo act 0\n"
		"\toption caution sc 1\n\t\tdo act 1\n";
	enum { BOTS = 500 };
	int took[2] = {0, 0}, pushers = 0, pusher_agg = 0, campers = 0, camper_cau = 0, i, seen_a[BC_A_COUNT] = {0};
	Rig r;
	Bot b;

	for (i = 0; i < BOTS; i++) {
		bc_persona p;
		int t;
		bot_init(&b, 5000 + (uint64_t)i);
		bc_persona_roll(&p, &b.rng, NULL, 5);
		b.ret[0] = b.ret[1] = BT_RUNNING;
		b.sc[0] = b.sc[1] = 0.6f;
		if (!rig_open(&r, txt, &b)) return;
		for (t = 0; t < BC_T_COUNT; t++) r.w[t] = p.trait[t];
		rig_tick(&r, 0.1f);
		took[b.calls[0] ? 0 : 1]++;
		seen_a[p.archetype]++;
		if (p.archetype == BC_A_PUSHER) { pushers++; pusher_agg += b.calls[0]; }
		if (p.archetype == BC_A_CAMPER) { campers++; camper_cau += b.calls[1]; }
		rig_close(&r);
	}
	printf("  population: %d took aggression, %d caution; %d/%d pushers aggressive, %d/%d campers cautious\n",
	       took[0], took[1], pusher_agg, pushers, camper_cau, campers);
	CHECK(took[0] > BOTS * 25 / 100 && took[0] < BOTS * 75 / 100);
	CHECK(took[1] > BOTS * 25 / 100 && took[1] < BOTS * 75 / 100);
	CHECK(pushers > 30 && pusher_agg >= pushers * 9 / 10);
	CHECK(campers > 30 && camper_cau >= campers * 9 / 10);

	/* the same bot seed replays the same choices, through a long changing situation */
	{
		int run, t, k;
		int log[2][120];
		for (run = 0; run < 2; run++) {
			bc_persona p;
			bot_init(&b, 4242);
			bc_persona_roll(&p, &b.rng, NULL, 5);
			b.ret[0] = b.ret[1] = BT_RUNNING;
			if (!rig_open(&r, txt, &b)) return;
			for (k = 0; k < BC_T_COUNT; k++) r.w[k] = p.trait[k];
			for (t = 0; t < 120; t++) {
				int before = b.calls[0];
				b.sc[0] = (float)((t * 7) % 10) / 10.0f;
				b.sc[1] = (float)((t * 3) % 10) / 10.0f;
				rig_tick(&r, 0.5f);
				log[run][t] = b.calls[0] > before ? 0 : 1;
			}
			rig_close(&r);
		}
		CHECK(memcmp(log[0], log[1], sizeof log[0]) == 0);
		{
			int ones = 0;
			for (t = 0; t < 120; t++) ones += log[0][t];
			CHECK(ones > 10 && ones < 110);   /* it did change its mind as the situation did */
		}
	}
}

/* ---- the example from bt.h ------------------------------------------- */

typedef struct Ex { int hurt; float enemy, intel, heard; char last[32]; int stops; } Ex;
static int ec_hurt(void *b, const bt_args *a) { return ((Ex *)b)->hurt && a->num[0] == 30; }
static float es_enemy(void *b, const bt_args *a) { (void)a; return ((Ex *)b)->enemy; }
static float es_intel(void *b, const bt_args *a) { (void)a; return ((Ex *)b)->intel; }
static float es_heard(void *b, const bt_args *a) { (void)a; return ((Ex *)b)->heard; }
#define EACT(n) static bt_status ea_##n(void *b, const bt_args *a, float dt) { (void)a; (void)dt; strcpy(((Ex *)b)->last, #n); return BT_RUNNING; }
EACT(retreat) EACT(fight) EACT(fetch_intel) EACT(investigate) EACT(roam)
static void ex_stop(void *b, const bt_args *a) { (void)a; ((Ex *)b)->stops++; }
static float ex_rnd(void *b) { (void)b; return 0.5f; }

static void test_example(void)
{
	const char *txt =
		"tree main:\n"
		"select\n"
		"    seq                          # hurt and out of the fight: get well\n"
		"        if health_below 30\n"
		"        do retreat\n"
		"    pick every=3\n"
		"        option aggression enemy_near\n"
		"            do fight\n"
		"        option objective intel_free x1.5\n"
		"            do fetch_intel\n"
		"        option curiosity heard_something\n"
		"            do investigate\n"
		"    do roam                      # nothing else to do\n";
	bt_vocab *v = bt_vocab_new();
	bt_forest *f;
	bt_state *s;
	bt_ctx c;
	Ex ex;
	float w[BC_T_COUNT];
	char err[200], d[100];
	int i;
	memset(&ex, 0, sizeof ex);
	for (i = 0; i < BC_T_COUNT; i++) w[i] = 1;
	bt_vocab_cond(v, "health_below", ec_hurt);
	bt_vocab_score(v, "enemy_near", es_enemy);
	bt_vocab_score(v, "intel_free", es_intel);
	bt_vocab_score(v, "heard_something", es_heard);
	bt_vocab_action(v, "retreat", ea_retreat, ex_stop);
	bt_vocab_action(v, "fight", ea_fight, ex_stop);
	bt_vocab_action(v, "fetch_intel", ea_fetch_intel, ex_stop);
	bt_vocab_action(v, "investigate", ea_investigate, ex_stop);
	bt_vocab_action(v, "roam", ea_roam, ex_stop);
	for (i = 1; i < BC_T_COUNT; i++) bt_vocab_trait(v, bc_trait_name(i), i);
	f = bt_compile(v, txt, err, sizeof err);
	if (!f) { printf("example: %s\n", err); checks++; failed++; bt_vocab_free(v); return; }
	CHECK(bt_forest_find(f, "main") == 0);
	CHECK(bt_forest_nodes(f) == 12);
	s = malloc(bt_state_size(f));
	bt_state_init(s, f);
	memset(&c, 0, sizeof c);
	c.bot = &ex; c.weights = w; c.n_weights = BC_T_COUNT; c.dt = 0.5f; c.random = ex_rnd;

	bt_tick(f, 0, s, &c);
	CHECK(strcmp(ex.last, "roam") == 0);                 /* nothing scores */
	ex.enemy = 0.5f; ex.intel = 0.4f;                    /* 0.5 vs 0.4*1.5 = 0.6: the intel */
	bt_tick(f, 0, s, &c);
	CHECK(strcmp(ex.last, "roam") == 0);                 /* the select is still on roam (it has memory) */
	bt_reset(f, s, &c);
	CHECK(ex.stops == 1);
	bt_tick(f, 0, s, &c);
	CHECK(strcmp(ex.last, "fetch_intel") == 0);
	bt_describe(f, s, d, sizeof d);
	CHECK(strcmp(d, "pick:objective > fetch_intel") == 0);
	w[BC_T_OBJECTIVE] = 0.5f;                            /* a different character, same moment */
	bt_reset(f, s, &c);
	bt_tick(f, 0, s, &c);
	CHECK(strcmp(ex.last, "fight") == 0);
	bt_describe(f, s, d, 8);                             /* truncation is safe */
	CHECK(strlen(d) == 7);
	CHECK(bt_describe(f, s, d, 0) == 0);
	ex.hurt = 1;
	bt_reset(f, s, &c);
	bt_tick(f, 0, s, &c);
	CHECK(strcmp(ex.last, "retreat") == 0);
	bt_describe(f, s, d, sizeof d);
	CHECK(strcmp(d, "retreat") == 0);

	free(s);
	bt_forest_free(f);
	bt_vocab_free(v);
}

/* ---- looking in: the source, the text written back, the forest walked,
 * mistakes as data, a bot watched ------------------------------------- */

static int same(const char *a, const char *b) { return (!a && !b) || (a && b && !strcmp(a, b)); }

static const char SRC[] =
	"# a file's first words\n"
	"\n"
	"# what main is for\n"
	"tree main:   # the one run\n"
	"select\n"
	"    # hurt: get well\n"
	"    seq                # twice a line\n"
	"        if flag 0\n"
	"        do act 1 far 2.5\n"
	"\n"
	"    #unspaced\n"
	"    pick every=3 noise=0\n"
	"        option a sc 0 x1.5   #first\n"
	"            do act 2\n"
	"        option b sc 1 near\n"
	"            tree other\n"
	"    limit 4\n"
	"        tree later\n"
	"tree other :\n"
	"cooldown 2.5\n"
	"    wait 1\n"
	"# the end\n";

static void test_source(void)
{
	bt_diag d;
	bt_source *src = bt_parse(vocab, SRC, &d);
	bt_tree t;
	bt_node n;
	CHECK(src != NULL);
	if (!src) { printf("  %d:%d %s\n", d.line, d.column, d.message); return; }
	CHECK(d.line == 0 && d.message[0] == 0);
	CHECK(bt_source_trees(src) == 2 && bt_source_nodes(src) == 13);
	CHECK(bt_source_tree(src, 0, &t) && !strcmp(t.name, "main") && t.root == 0 && t.line == 4 && t.header == 1);
	CHECK(same(t.comment, "the one run") && same(t.above, "# a file's first words\n\n# what main is for\n"));
	CHECK(bt_source_tree(src, 1, &t) && !strcmp(t.name, "other") && t.root == 11 && t.line == 19 && !t.comment && !t.above);
	CHECK(!bt_source_tree(src, 2, &t) && !bt_source_tree(src, -1, &t));
	CHECK(same(bt_source_tail(src), "# the end\n"));

	CHECK(bt_source_node(src, 0, &n) && n.kind == BT_K_SELECT && n.id == 0 && n.source == 0 && n.parent == -1);
	CHECK(n.first_child == 1 && n.next_sibling == -1 && n.n_children == 3 && n.tree == 0 && n.line == 5 && n.column == 1);
	CHECK(same(n.text, "select") && !n.name && !n.trait && !n.comment && !n.above && n.via == -1);
	CHECK(bt_source_node(src, 1, &n) && n.kind == BT_K_SEQ && n.parent == 0 && n.first_child == 2 && n.next_sibling == 4);
	CHECK(n.column == 5 && same(n.comment, "twice a line") && same(n.above, "# hurt: get well\n") && n.n_children == 2);
	CHECK(bt_source_node(src, 2, &n) && n.kind == BT_K_IF && same(n.name, "flag") && n.args.count == 1 && n.column == 9);
	CHECK(n.first_child == -1 && n.next_sibling == 3 && n.n_children == 0);
	CHECK(bt_source_node(src, 3, &n) && n.kind == BT_K_DO && same(n.name, "act") && n.args.count == 3);
	CHECK(same(n.args.text[1], "far") && n.args.num[2] == 2.5f && same(n.text, "do act 1 far 2.5") && n.next_sibling == -1);
	/* a pick: what was written, and what is the default */
	CHECK(bt_source_node(src, 4, &n) && n.kind == BT_K_PICK && n.every == 3.0f && n.noise == 0.0f && n.sticky == 0.25f);
	CHECK(n.written == (BT_W_EVERY | BT_W_NOISE) && same(n.above, "\n#unspaced\n") && n.n_children == 2 && n.next_sibling == 9);
	CHECK(bt_source_node(src, 5, &n) && n.kind == BT_K_OPTION && same(n.trait, "a") && same(n.name, "sc"));
	CHECK(n.factor == 1.5f && n.written == BT_W_FACTOR && n.args.count == 1 && same(n.comment, "first") && n.parent == 4);
	CHECK(bt_source_node(src, 7, &n) && n.kind == BT_K_OPTION && n.factor == 1.0f && n.written == 0 && n.args.count == 2);
	/* a reference is a node, and may name a tree the text has not */
	CHECK(bt_source_node(src, 8, &n) && n.kind == BT_K_TREE && same(n.name, "other") && n.n_children == 0);
	CHECK(bt_source_node(src, 9, &n) && n.kind == BT_K_LIMIT && n.secs == 4.0f && n.n_children == 1);
	CHECK(bt_source_node(src, 10, &n) && n.kind == BT_K_TREE && same(n.name, "later") && n.line == 18);
	CHECK(bt_source_node(src, 11, &n) && n.kind == BT_K_COOLDOWN && n.secs == 2.5f && n.tree == 1 && n.parent == -1 && n.line == 20);
	CHECK(!bt_source_node(src, 13, &n) && !bt_source_node(src, -1, &n));
	CHECK(same(bt_kind_name(BT_K_SEQ), "seq") && same(bt_kind_name(BT_K_TREE), "tree") && !bt_kind_name(BT_K_COUNT) && !bt_kind_name(-1));
	bt_source_free(src);

	/* no header: the tree "main", and its comments on its first node */
	src = bt_parse(vocab, "# top\ndo act 0\n", NULL);
	CHECK(src != NULL);
	if (src) {
		CHECK(bt_source_tree(src, 0, &t) && !strcmp(t.name, "main") && t.header == 0 && t.line == 2 && !t.above);
		CHECK(bt_source_node(src, 0, &n) && same(n.above, "# top\n"));
		bt_source_free(src);
	}
	/* what bt_compile refuses in a line, bt_parse refuses the same */
	CHECK(bt_parse(vocab, "do nothing\n", &d) == NULL && d.line == 1 && strstr(d.message, "no action"));
	CHECK(bt_parse(vocab, "seq\n", &d) == NULL && strstr(d.message, "at least one child"));
	CHECK(bt_parse(NULL, "seq\n", &d) == NULL);
}

/* the two forests have the same nodes: kinds, words, numbers, shape */
static int same_forest(const bt_forest *a, const bt_forest *b)
{
	int i, k, n = (int)bt_forest_nodes(a);
	bt_tree ta, tb;
	if (bt_forest_nodes(b) != (size_t)n || bt_forest_trees(a) != bt_forest_trees(b)) return 0;
	for (i = 0; i < bt_forest_trees(a); i++) {
		bt_forest_tree(a, i, &ta); bt_forest_tree(b, i, &tb);
		if (strcmp(ta.name, tb.name) || ta.root != tb.root || !same(ta.comment, tb.comment)) return 0;
	}
	for (i = 0; i < n; i++) {
		bt_node x, y;
		bt_forest_node(a, i, &x); bt_forest_node(b, i, &y);
		if (x.kind != y.kind || x.parent != y.parent || x.n_children != y.n_children || x.tree != y.tree ||
		    x.source != y.source || x.via != y.via || x.written != y.written || x.args.count != y.args.count ||
		    x.secs != y.secs || x.every != y.every || x.sticky != y.sticky || x.noise != y.noise || x.factor != y.factor ||
		    x.op != y.op || x.number != y.number ||
		    !same(x.name, y.name) || !same(x.trait, y.trait) || !same(x.text, y.text) || !same(x.comment, y.comment))
			return 0;
		for (k = 0; k < x.args.count; k++) if (!same(x.args.text[k], y.args.text[k])) return 0;
	}
	return 1;
}

/* how many comments a source holds: lines above, on a line, at the end */
static int count_comments(const bt_source *src)
{
	int i, n = 0;
	const char *q;
	bt_tree t;
	bt_node nd;
	for (i = 0; bt_source_tree(src, i, &t); i++) {
		if (t.comment) n++;
		for (q = t.above; q && *q; q++) if (*q == '#' && (q == t.above || q[-1] == '\n')) n++;
	}
	for (i = 0; bt_source_node(src, i, &nd); i++) {
		if (nd.comment) n++;
		for (q = nd.above; q && *q; q++) if (*q == '#' && (q == nd.above || q[-1] == '\n')) n++;
	}
	for (q = bt_source_tail(src); q && *q; q++) if (*q == '#' && (q == bt_source_tail(src) || q[-1] == '\n')) n++;
	return n;
}

/* text -> source -> text: the canonical text, or NULL (and a CHECK failed) */
static char *canonical(const bt_vocab *v, const char *text, int *comments)
{
	bt_diag d;
	bt_source *src = bt_parse(v, text, &d);
	size_t n;
	char *out;
	CHECK(src != NULL);
	if (!src) { printf("  %d:%d %s\n", d.line, d.column, d.message); return NULL; }
	n = bt_source_text(src, NULL, 0);
	out = malloc(n + 1);
	CHECK(bt_source_text(src, out, n + 1) == n && strlen(out) == n);
	if (comments) *comments = count_comments(src);
	bt_source_free(src);
	return out;
}

static void test_text(void)
{
	static const char WANT[] =
		"# a file's first words\n"
		"\n"
		"# what main is for\n"
		"tree main:                                    # the one run\n"
		"select\n"
		"\t# hurt: get well\n"
		"\tseq                                       # twice a line\n"
		"\t\tif flag 0\n"
		"\t\tdo act 1 far 2.5\n"
		"\n"
		"\t#unspaced\n"
		"\tpick every=3 noise=0\n"
		"\t\toption a sc 0 x1.5                    # first\n"
		"\t\t\tdo act 2\n"
		"\t\toption b sc 1 near\n"
		"\t\t\ttree other\n"
		"\tlimit 4\n"
		"\t\ttree later\n"
		"tree other:\n"
		"cooldown 2.5\n"
		"\twait 1\n"
		"# the end\n";
	int c1 = 0, c2 = 0;
	char *one = canonical(vocab, SRC, &c1), *two, small[8], err[200];
	bt_source *src;
	CHECK(one && !strcmp(one, WANT));
	if (one && strcmp(one, WANT)) printf("--- got\n%s--- wanted\n%s", one, WANT);
	if (!one) return;
	/* written again from what it wrote: the same text, no comment lost */
	two = canonical(vocab, one, &c2);
	CHECK(two && !strcmp(one, two));
	CHECK(c1 == 8 && c2 == c1);
	free(two);
	/* a buffer too small: the length in full, what fits, a 0 */
	src = bt_parse(vocab, SRC, NULL);
	CHECK(bt_source_text(src, small, sizeof small) == strlen(WANT) && !strcmp(small, "# a fil"));
	CHECK(bt_source_text(src, NULL, 0) == strlen(WANT));
	bt_source_free(src);
	free(one);

	/* and it compiles to the same forest: a text with every kind of node */
	{
		static const char ALL[] =
			"tree main:\n"
			"  select\n"
			"    seq\n"
			"      if flag 0\n"
			"      unless flag 1\n"
			"      invert\n"
			"        never\n"
			"          always\n"
			"            do act 0\n"
			"    pick every=1.5 sticky=0 noise=0.35  # all three\n"
			"      option a sc 0 3 x0.25\n"
			"        limit 2\n"
			"          tree part\n"
			"      option none sc 1\n"
			"        cooldown 0.5\n"
			"          wait 1e1\n"
			"    tree part # twice\n"
			"tree part:\n"
			"  seq\n"
			"    do act 3 x2\n";
		bt_forest *a = bt_compile(vocab, ALL, err, sizeof err), *b;
		char *txt = canonical(vocab, ALL, NULL);
		CHECK(a != NULL && txt != NULL);
		b = txt ? bt_compile(vocab, txt, err, sizeof err) : NULL;
		CHECK(b != NULL);
		if (a && b) {
			CHECK(same_forest(a, b));
			CHECK(same_forest(a, a));
		}
		if (a && b) {                       /* and same_forest does tell two apart */
			bt_forest *c = bt_compile(vocab, "tree main:\nselect\n\tdo act 0\n", err, sizeof err);
			CHECK(c && !same_forest(a, c));
			bt_forest_free(c);
		}
		bt_forest_free(a); bt_forest_free(b); free(txt);
	}
	/* a headerless text stays headerless */
	one = canonical(vocab, "select   \n    do act 0   # go\r\n", NULL);
	CHECK(one && !strcmp(one, "select\n\tdo act 0                                  # go\n"));
	free(one);
	/* a comment after a long line: one space */
	one = canonical(vocab, "do act 0 a_very_long_argument_indeed and_another_one_as_long #c\n", NULL);
	CHECK(one && !strcmp(one, "do act 0 a_very_long_argument_indeed and_another_one_as_long # c\n"));
	free(one);
}

static void test_forest_walk(void)
{
	char err[200];
	static const char T[] =
		"tree main:\n"            /* source ids        forest ids */
		"seq\n"                   /* 0                 0 */
		"\ttree greet\n"          /* 1                 1 select, 2 if, 3 do */
		"\tinvert\n"              /* 2                 4 */
		"\t\ttree alias\n"        /* 3                 5 select, 6 if, 7 do */
		"tree greet:\n"
		"select   # hello\n"      /* 4                 8 */
		"\tif flag 0\n"           /* 5                 9 */
		"\tdo act 1\n"            /* 6                 10 */
		"tree alias:\n"
		"tree greet\n";           /* 7                 11 select, 12, 13 */
	bt_forest *f = bt_compile(vocab, T, err, sizeof err);
	const bt_source *src;
	bt_tree t;
	bt_node n;
	int i;
	CHECK(f != NULL);
	if (!f) return;
	src = bt_forest_source(f);
	CHECK(src && bt_source_nodes(src) == 8 && bt_source_trees(src) == 3);
	CHECK(bt_forest_nodes(f) == 14 && bt_forest_trees(f) == 3);
	CHECK(bt_forest_tree(f, 0, &t) && !strcmp(t.name, "main") && t.root == 0);
	CHECK(bt_forest_tree(f, 1, &t) && !strcmp(t.name, "greet") && t.root == 8);
	CHECK(bt_forest_tree(f, 2, &t) && !strcmp(t.name, "alias") && t.root == 11 && !bt_forest_tree(f, 3, &t));
	CHECK(bt_source_tree(src, 1, &t) && t.root == 4);

	CHECK(bt_forest_node(f, 0, &n) && n.kind == BT_K_SEQ && n.source == 0 && n.via == -1 && n.parent == -1 && n.n_children == 2);
	CHECK(n.first_child == 1 && n.next_sibling == -1 && n.tree == 0);
	/* a tree opened in place: its root says which reference brought it */
	CHECK(bt_forest_node(f, 1, &n) && n.kind == BT_K_SELECT && n.source == 4 && n.via == 1 && n.parent == 0);
	CHECK(n.next_sibling == 4 && n.n_children == 2 && same(n.comment, "hello") && n.line == 7 && n.tree == 0);
	CHECK(bt_forest_node(f, 2, &n) && n.kind == BT_K_IF && n.source == 5 && n.via == -1 && n.parent == 1 && n.next_sibling == 3);
	CHECK(bt_forest_node(f, 3, &n) && n.kind == BT_K_DO && same(n.name, "act") && n.next_sibling == -1 && n.first_child == -1);
	CHECK(bt_forest_node(f, 4, &n) && n.kind == BT_K_INVERT && n.source == 2 && n.first_child == 5 && n.next_sibling == -1);
	/* through two references: the outermost is named */
	CHECK(bt_forest_node(f, 5, &n) && n.kind == BT_K_SELECT && n.source == 4 && n.via == 3 && n.parent == 4);
	CHECK(bt_forest_node(f, 8, &n) && n.source == 4 && n.via == -1 && n.parent == -1 && n.tree == 1);
	CHECK(bt_forest_node(f, 11, &n) && n.source == 4 && n.via == 7 && n.parent == -1 && n.tree == 2);
	CHECK(bt_forest_node(f, 13, &n) && n.tree == 2 && n.parent == 11);
	CHECK(!bt_forest_node(f, 14, &n) && !bt_forest_node(f, -1, &n));
	/* no reference is left in a forest, and every node knows its source */
	for (i = 0; bt_forest_node(f, i, &n); i++) {
		bt_node s;
		CHECK(n.kind != BT_K_TREE && n.id == i);
		CHECK(bt_source_node(src, n.source, &s) && s.kind == n.kind && s.line == n.line);
	}
	CHECK(i == 14);
	bt_forest_free(f);
}

static void diag_is(const char *text, int line, int column, const char *what)
{
	bt_diag d;
	char err[300], want[300];
	bt_forest *f = bt_compile_diag(vocab, text, &d);
	CHECK(f == NULL);
	if (f) { bt_forest_free(f); return; }
	if (d.line != line || d.column != column || !strstr(d.message, what)) {
		checks++; failed++;
		printf("FAIL diag for {%s}: got %d:%d \"%s\", wanted %d:%d ... %s\n", text, d.line, d.column, d.message, line, column, what);
	}
	/* the string form is the same mistake */
	CHECK(bt_compile(vocab, text, err, sizeof err) == NULL);
	snprintf(want, sizeof want, "line %d: %s", d.line, d.message);
	CHECK(!strcmp(err, want));
}

static void test_diag(void)
{
	bt_diag d;
	bt_forest *f;
	diag_is("select\n\tdo figth\n", 2, 5, "no action called figth");
	diag_is("select\n    if  nope 3\n", 2, 9, "no condition called nope");
	diag_is("pick\n\toption zz sc 0\n\t\tdo act 0\n", 2, 9, "no trait called zz");
	diag_is("pick\n\toption a zz 0\n\t\tdo act 0\n", 2, 11, "no score called zz");
	diag_is("pick every=2 colour=3\n\toption a sc 0\n\t\tdo act 0\n", 1, 14, "unknown setting");
	diag_is("pick noise=2\n\toption a sc 0\n\t\tdo act 0\n", 1, 6, "noise");
	diag_is("seq\n\twait soon\n", 2, 7, "number of seconds");
	diag_is("seq\n\tfrobnicate\n", 2, 2, "unknown node");
	diag_is("seq\n\tdo act 0\n\t\tdo act 1\n", 3, 3, "takes no children");
	diag_is("tree a:\nseq\n\ttree zzz\n", 3, 2, "no tree called zzz");
	diag_is("tree a:\nselect\n\ttree a\n", 3, 2, "itself");
	diag_is("tree a:\nseq\n\tselect\n", 3, 2, "at least one child");
	diag_is("tree a:\ntree b:\ndo act 0\n", 1, 1, "empty");
	diag_is("tree a:\ndo act 0\ntree a:\ndo act 0\n", 3, 6, "twice");
	diag_is("seq\n \tdo act 0\n", 2, 1, "mixes");
	diag_is("", 1, 0, "no tree");
	/* a text that compiles leaves the diag clean */
	memset(&d, 1, sizeof d);
	f = bt_compile_diag(vocab, "do act 0\n", &d);
	CHECK(f != NULL && d.line == 0 && d.column == 0 && d.message[0] == 0);
	bt_forest_free(f);
	f = bt_compile_diag(vocab, "do act 0\n", NULL);
	CHECK(f != NULL);
	bt_forest_free(f);
	CHECK(bt_compile_diag(vocab, "do nothing\n", NULL) == NULL);
}

static int near(float a, float b) { return a > b - 1e-4f && a < b + 1e-4f; }

static void test_watch(void)
{
	static const char T[] =
		"select\n"                        /* 0 */
		"\tpick every=2 sticky=0.5 noise=0.2\n"  /* 1 */
		"\t\toption a sc 0 x2\n"          /* 2 */
		"\t\t\tdo act 0\n"                /* 3 */
		"\t\toption b sc 1\n"             /* 4 */
		"\t\t\tlimit 5\n"                 /* 5 */
		"\t\t\t\tseq\n"                   /* 6 */
		"\t\t\t\t\twait 1\n"              /* 7 */
		"\t\t\t\t\talways\n"              /* 8 */
		"\t\t\t\t\t\tdo act 1\n"          /* 9 */
		"\t\toption a sc 2\n"             /* 10 */
		"\t\t\tdo act 2\n"                /* 11 */
		"\tcooldown 3\n"                  /* 12 */
		"\t\tdo act 3\n";                 /* 13 */
	Rig r;
	Bot b;
	bt_node_state ns;
	bt_worth w[4];
	int path[BT_DEPTH_MAX], n, k;
	bot_init(&b, 5);
	b.ret[0] = b.ret[1] = b.ret[2] = BT_RUNNING;
	b.sc[0] = 0.2f; b.sc[1] = 1.0f; b.sc[2] = 0.0f;
	if (!rig_open(&r, T, &b)) return;
	r.w[1] = 1.5f; r.w[2] = 0.8f;

	/* before any tick: nothing runs */
	CHECK(bt_state_running(r.f, r.s, 0, path, BT_DEPTH_MAX) == 0);
	CHECK(bt_state_node(r.f, r.s, 1, &ns) && !ns.running && ns.child == -1);
	/* not traced: the options say they were not weighed */
	CHECK(rig_tick(&r, 0.5f) == BT_RUNNING);
	CHECK(bt_state_worths(r.f, r.s, 1, w, 4) == 3 && !w[0].weighed && !w[1].weighed && w[1].held && w[0].factor == 2.0f);
	CHECK(bt_state_worths(r.f, r.s, 0, w, 4) == 0 && bt_state_worths(r.f, r.s, 99, w, 4) == 0);

	/* the path: select > pick > option b > limit > seq > wait */
	n = bt_state_running(r.f, r.s, 0, path, BT_DEPTH_MAX);
	CHECK(n == 6 && path[0] == 0 && path[1] == 1 && path[2] == 4 && path[3] == 5 && path[4] == 6 && path[5] == 7);
	CHECK(bt_state_running(r.f, r.s, 0, path, 2) == 6);         /* the count in full, two written */
	CHECK(bt_state_running(r.f, r.s, 0, NULL, 0) == 6 && bt_state_running(r.f, r.s, 3, path, 4) == 0);
	CHECK(bt_state_node(r.f, r.s, 0, &ns) && ns.running && ns.child == 1);
	CHECK(bt_state_node(r.f, r.s, 1, &ns) && ns.running && ns.child == 4 && near(ns.elapsed, 0) && near(ns.remaining, 2));
	CHECK(bt_state_node(r.f, r.s, 7, &ns) && ns.running && near(ns.elapsed, 0) && near(ns.remaining, 1));
	CHECK(bt_state_node(r.f, r.s, 3, &ns) && !ns.running);
	rig_tick(&r, 0.5f);
	CHECK(bt_state_node(r.f, r.s, 1, &ns) && near(ns.elapsed, 0.5f) && near(ns.remaining, 1.5f));
	CHECK(bt_state_node(r.f, r.s, 5, &ns) && ns.running && near(ns.elapsed, 0.5f) && near(ns.remaining, 4.5f));
	rig_tick(&r, 0.5f);                                       /* the wait is over: on to the action */
	n = bt_state_running(r.f, r.s, 0, path, BT_DEPTH_MAX);
	CHECK(n == 7 && path[5] == 8 && path[6] == 9);
	CHECK(bt_state_node(r.f, r.s, 9, &ns) && ns.running && bt_state_node(r.f, r.s, 7, &ns) && !ns.running);
	CHECK(bt_state_node(r.f, r.s, 6, &ns) && ns.running && ns.child == 8);
	CHECK(!bt_state_node(r.f, r.s, 14, &ns));

	/* traced: at the next choice each option's numbers are there, and
	 * multiply to its worth; the best is the one held */
	bt_state_trace(r.s, 1);
	rig_tick(&r, 1.0f);                                       /* 2 s since the choice: chosen again */
	CHECK(bt_state_worths(r.f, r.s, 1, w, 4) == 3);
	CHECK(w[0].option == 2 && w[1].option == 4 && w[2].option == 10);
	CHECK(w[0].weighed && near(w[0].score, 0.2f) && near(w[0].weight, 1.5f) && w[0].factor == 2.0f && w[0].sticky == 1.0f);
	CHECK(w[0].luck >= 0.8f && w[0].luck <= 1.2f && near(w[0].worth, 0.2f * 1.5f * 2.0f * w[0].luck) && !w[0].held);
	CHECK(w[1].weighed && near(w[1].score, 1) && near(w[1].weight, 0.8f) && near(w[1].sticky, 1.5f) && w[1].held);
	CHECK(w[1].luck >= 0.8f && w[1].luck <= 1.2f && near(w[1].worth, 0.8f * w[1].luck * 1.5f));
	CHECK(w[1].worth > w[0].worth);
	/* a score of 0: weighed, no draw, worth nothing */
	CHECK(w[2].weighed && w[2].score == 0.0f && w[2].luck == 0.0f && w[2].worth == 0.0f && near(w[2].weight, 1.5f));
	CHECK(bt_state_worths(r.f, r.s, 1, w, 1) == 3 && bt_state_worths(r.f, r.s, 1, NULL, 0) == 3);
	/* the choice changes: the one left keeps what was noted of it */
	b.sc[0] = 1.0f; b.sc[1] = 0.01f;
	rig_tick(&r, 2.0f);
	CHECK(b.stops[1] == 1);
	CHECK(bt_state_worths(r.f, r.s, 1, w, 4) == 3 && w[0].held && !w[1].held && w[1].weighed && near(w[1].sticky, 1.5f));
	CHECK(w[0].worth > w[1].worth);
	n = bt_state_running(r.f, r.s, 0, path, BT_DEPTH_MAX);
	CHECK(n == 4 && path[2] == 2 && path[3] == 3);
	/* bt_reset forgets the notes and keeps the tracing; bt_state_init ends it */
	bt_reset(r.f, r.s, &r.ctx);
	CHECK(bt_state_worths(r.f, r.s, 1, w, 4) == 3 && !w[0].weighed && !w[0].held);
	CHECK(bt_state_running(r.f, r.s, 0, path, BT_DEPTH_MAX) == 0);
	rig_tick(&r, 0.1f);
	CHECK(bt_state_worths(r.f, r.s, 1, w, 4) == 3 && w[0].weighed);
	bt_state_init(r.s, r.f);
	rig_tick(&r, 0.1f);
	CHECK(bt_state_worths(r.f, r.s, 1, w, 4) == 3 && !w[0].weighed);

	/* nothing to choose: the cooldown's child runs once, then it cools */
	bt_state_init(r.s, r.f);
	b.sc[0] = b.sc[1] = 0; b.ret[3] = BT_FAILURE;
	CHECK(rig_tick(&r, 0.5f) == BT_FAILURE && b.calls[3] == 1);
	CHECK(bt_state_node(r.f, r.s, 12, &ns) && !ns.running && near(ns.remaining, 3));
	rig_tick(&r, 1.0f);
	CHECK(bt_state_node(r.f, r.s, 12, &ns) && near(ns.remaining, 2) && b.calls[3] == 1);
	rig_close(&r);

	/* watching changes nothing: 300 bots choose the same, traced or not */
	for (k = 0; k < 300; k++) {
		Rig p, q;
		Bot b1, b2;
		int j, i;
		bot_init(&b1, 100 + (uint64_t)k); bot_init(&b2, 100 + (uint64_t)k);
		for (j = 0; j < 3; j++) { b1.ret[j] = b2.ret[j] = BT_RUNNING; b1.sc[j] = b2.sc[j] = 0.5f + 0.1f * (float)j; }
		if (!rig_open(&p, T, &b1)) return;
		if (!rig_open(&q, T, &b2)) { rig_close(&p); return; }
		p.w[1] = q.w[1] = 0.6f + 0.01f * (float)k;
		bt_state_trace(q.s, 1);
		for (i = 0; i < 12; i++) {
			int pa[BT_DEPTH_MAX], pb[BT_DEPTH_MAX], na, nb;
			if (i == 6) { b1.sc[0] = b2.sc[0] = 0.9f; }
			CHECK(rig_tick(&p, 0.7f) == rig_tick(&q, 0.7f));
			na = bt_state_running(p.f, p.s, 0, pa, BT_DEPTH_MAX);
			nb = bt_state_running(q.f, q.s, 0, pb, BT_DEPTH_MAX);
			CHECK(na == nb && !memcmp(pa, pb, (size_t)na * sizeof pa[0]));
		}
		for (j = 0; j < 3; j++) CHECK(b1.calls[j] == b2.calls[j] && b1.stops[j] == b2.stops[j]);
		rig_close(&p); rig_close(&q);
	}
}

static char *read_file(const char *path)
{
	FILE *fp = fopen(path, "rb");
	char *buf;
	long n;
	if (!fp) return NULL;
	fseek(fp, 0, SEEK_END);
	n = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	buf = malloc((size_t)n + 1);
	n = (long)fread(buf, 1, (size_t)n, fp);
	buf[n] = 0;
	fclose(fp);
	return buf;
}

/* Every tree that ships (trees/, from where `make test` runs), with the
 * engine's own words: read, written back, read again -- the same text,
 * no comment lost -- and all of them compiled both ways to one forest. */
static void test_shipped(void)
{
	static const char STUBS[] = "tree items:\nnever\n\tif enemy_visible\ntree extras:\nnever\n\tif enemy_visible\n";
	DIR *dir = opendir("trees");
	struct dirent *de;
	bt_vocab *v = bt_vocab_new();
	char *all[2], err[300];
	size_t len[2] = {0, 0};
	int files = 0, same_bytes = 0, k;
	bt_forest *f[2];
	if (!dir) { printf("  shipped trees: no trees/ here, skipped\n"); bt_vocab_free(v); return; }
	CHECK(bc_vocab_register(v));
	all[0] = calloc(1, 1); all[1] = calloc(1, 1);
	while ((de = readdir(dir)) != NULL) {
		char path[512], *text[2];
		size_t n = strlen(de->d_name);
		int c1 = 0, c2 = 0;
		if (n < 4 || strcmp(de->d_name + n - 3, ".bt")) continue;
		snprintf(path, sizeof path, "trees/%s", de->d_name);
		text[0] = read_file(path);
		CHECK(text[0] != NULL);
		if (!text[0]) continue;
		text[1] = canonical(v, text[0], &c1);
		if (text[1]) {
			char *again = canonical(v, text[1], &c2);
			CHECK(again && !strcmp(again, text[1]));
			CHECK(c1 == c2 && c1 > 0);
			free(again);
			same_bytes += !strcmp(text[0], text[1]);
			files++;
			for (k = 0; k < 2; k++) {
				size_t m = strlen(text[k]);
				all[k] = realloc(all[k], len[k] + m + 2);
				memcpy(all[k] + len[k], text[k], m);
				len[k] += m;
				all[k][len[k]++] = '\n';
				all[k][len[k]] = 0;
			}
		} else
			printf("  in %s\n", path);
		free(text[0]); free(text[1]);
	}
	closedir(dir);
	CHECK(files > 0);
	for (k = 0; k < 2; k++) {
		all[k] = realloc(all[k], len[k] + sizeof STUBS);
		strcpy(all[k] + len[k], STUBS);
		f[k] = bt_compile(v, all[k], err, sizeof err);
		CHECK(f[k] != NULL);
		if (!f[k]) printf("  shipped trees, %s: %s\n", k ? "written back" : "as shipped", err);
	}
	if (f[0] && f[1]) {
		CHECK(same_forest(f[0], f[1]));
		printf("  shipped trees: %d files, %d nodes in the forest, the same read back from the text written; %d of them written back byte for byte\n",
		       files, (int)bt_forest_nodes(f[0]), same_bytes);
	}
	bt_forest_free(f[0]); bt_forest_free(f[1]);
	free(all[0]); free(all[1]);
	bt_vocab_free(v);
}

/* ---- a word's arguments, said by the host and checked by the compiler;
 * every mistake of a text at once ------------------------------------- */

static const bt_arg_spec SPEC_GO[2] = {
	{ "where", BT_ARG_ONE_OF, 1, 0, 0, 0, 0, NULL, "spot", 0, 0, 0, NULL, NULL },
	{ "radius", BT_ARG_NUMBER, 0, 0, 1, 1, 1, NULL, NULL, 2, 0, 50, NULL, NULL },
};
static const bt_arg_spec SPEC_MODE[1] = {
	{ "mode", BT_ARG_ONE_OF, 1, 0, 0, 0, 0, "on|off", NULL, 0, 0, 0, NULL, NULL },
};
static const bt_arg_spec SPEC_SAY[2] = {
	{ "whom", BT_ARG_ONE_OF, 0, 0, 0, 0, 0, "all", "spot", 0, 0, 0, "all", NULL },
	{ "word", BT_ARG_TEXT, 0, 1, 0, 0, 0, NULL, NULL, 0, 0, 0, NULL, NULL },
};
static const bt_arg_spec SPEC_OVER[1] = {
	{ "level", BT_ARG_NUMBER, 1, 0, 0, 1, 0, NULL, NULL, 0, 0, 0, NULL, NULL },
};

static bt_vocab *spec_vocab(void)
{
	bt_vocab *v = bt_vocab_new();
	bt_vocab_cond(v, "flag", c_flag);
	bt_vocab_cond(v, "over", c_flag);
	bt_vocab_cond(v, "plain", c_flag);
	bt_vocab_score(v, "sc", s_sc);
	bt_vocab_score(v, "over", s_sc);
	bt_vocab_action(v, "go", a_act, a_stop);
	bt_vocab_action(v, "lamp", a_act, NULL);
	bt_vocab_action(v, "say", a_act, NULL);
	bt_vocab_action(v, "stop", a_act, NULL);
	bt_vocab_action(v, "act", a_act, a_stop);
	bt_vocab_trait(v, "none", 0);
	CHECK(bt_vocab_set(v, "spot", "home|away"));
	CHECK(bt_vocab_args(v, BT_WORD_ACTION, "go", SPEC_GO, 2));
	CHECK(bt_vocab_args(v, BT_WORD_ACTION, "lamp", SPEC_MODE, 1));
	CHECK(bt_vocab_args(v, BT_WORD_ACTION, "say", SPEC_SAY, 2));
	CHECK(bt_vocab_args(v, BT_WORD_ACTION, "stop", NULL, 0));
	CHECK(bt_vocab_args(v, BT_WORD_COND, "over", SPEC_OVER, 1));
	CHECK(bt_vocab_args(v, BT_WORD_SCORE, "over", SPEC_OVER, 1));
	return v;
}

static void spec_is(const bt_vocab *v, const char *text, int line, int column, const char *what)
{
	bt_diag d;
	bt_forest *f = bt_compile_diag(v, text, &d);
	if (!what) {
		CHECK(f != NULL);
		if (!f) printf("  {%s}: %d:%d %s\n", text, d.line, d.column, d.message);
		bt_forest_free(f);
		return;
	}
	CHECK(f == NULL);
	if (f) { printf("  {%s} compiled\n", text); bt_forest_free(f); return; }
	if (d.line != line || d.column != column || !strstr(d.message, what)) {
		checks++; failed++;
		printf("FAIL spec for {%s}: got %d:%d \"%s\", wanted %d:%d ... %s\n", text, d.line, d.column, d.message, line, column, what);
	}
}

static void test_arg_specs(void)
{
	bt_vocab *v = spec_vocab();
	bt_forest *f;
	char err[200];
	/* what is right */
	spec_is(v, "do go home\n", 0, 0, NULL);
	spec_is(v, "do go away 12.5\n", 0, 0, NULL);
	spec_is(v, "do lamp off\n", 0, 0, NULL);
	spec_is(v, "do stop\n", 0, 0, NULL);
	spec_is(v, "do say\n", 0, 0, NULL);
	spec_is(v, "do say all\n", 0, 0, NULL);
	spec_is(v, "do say home a b\n", 0, 0, NULL);               /* the last may repeat */
	spec_is(v, "if over 3\n", 0, 0, NULL);
	spec_is(v, "pick\n\toption none over 0.5 x2\n\t\tdo stop\n", 0, 0, NULL);   /* a score's argument, then the factor */
	/* a word nobody described takes anything, as before */
	spec_is(v, "seq\n\tif plain whatever 3 x\n\tdo act 1 far 2.5\n", 0, 0, NULL);
	/* what is wrong: how many */
	spec_is(v, "do go\n", 1, 4, "go: <where> is missing");
	spec_is(v, "seq\n\tdo go home 3 4\n", 2, 15, "go takes 2 arguments at most");
	spec_is(v, "do stop now\n", 1, 9, "stop takes no argument");
	spec_is(v, "do lamp on off\n", 1, 12, "lamp takes 1 argument at most");
	spec_is(v, "unless over\n", 1, 8, "over: <level> is missing");
	spec_is(v, "pick\n\toption none over\n\t\tdo stop\n", 2, 14, "over: <level> is missing");
	/* a number where a number goes, and within its range */
	spec_is(v, "do go home far\n", 1, 12, "go: <radius> is a number, not 'far'");
	spec_is(v, "do go home 51\n", 1, 12, "go: <radius> must be between 0 and 50");
	spec_is(v, "do go home -1\n", 1, 12, "between 0 and 50");
	spec_is(v, "if over -2\n", 1, 9, "over: <level> must be 0 or more");
	spec_is(v, "pick\n\toption none over much\n\t\tdo stop\n", 2, 19, "<level> is a number, not 'much'");
	/* a word of the list, or of the named list, or of either */
	spec_is(v, "do lamp dim\n", 1, 9, "lamp: 'dim' is not one of on|off");
	spec_is(v, "do go nowhere\n", 1, 7, "go: no spot called nowhere");
	spec_is(v, "do say nobody\n", 1, 8, "say: 'nobody' is neither all nor a spot");
	/* the string form says the same */
	f = bt_compile(v, "seq\n\tdo lamp dim\n", err, sizeof err);
	CHECK(f == NULL && !strcmp(err, "line 2: lamp: 'dim' is not one of on|off"));
	/* the lists and what cannot be said */
	CHECK(!strcmp(bt_vocab_set_values(v, "spot"), "home|away") && !bt_vocab_set_values(v, "none"));
	CHECK(bt_vocab_set(v, "spot", "home|away|far"));            /* said again: replaced */
	spec_is(v, "do go far\n", 0, 0, NULL);
	CHECK(!bt_vocab_args(v, BT_WORD_ACTION, "nothing", SPEC_GO, 2));
	CHECK(!bt_vocab_args(v, BT_WORD_COND, "go", SPEC_GO, 2));    /* go is an action */
	CHECK(!bt_vocab_args(v, BT_WORD_ACTION, "go", SPEC_GO, BT_ARGS_MAX + 1));
	CHECK(!bt_vocab_args(v, 7, "go", SPEC_GO, 2) && !bt_vocab_set(v, "", "a") && !bt_vocab_set(v, "x", NULL));
	bt_vocab_free(v);
}

static void test_diagnose(void)
{
	static const char MANY[] =
		"tree a:\n"                          /* 1 */
		"select\n"                           /* 2 */
		"\tseq\n"                            /* 3 */
		"\t\tif over much\n"                 /* 4: a word for a number */
		"\t\tdo go nowhere 3\n"              /* 5: no such spot */
		"\t\tdo figth\n"                     /* 6: no such action -- it keeps its place... */
		"\t\t\tdo stop\n"                    /* 7: ...so this child is not a second mistake */
		"\tpick colour=2\n"                  /* 8 */
		"\t\toption zz sc 0\n"               /* 9: no such trait */
		"\t\t\tdo lamp\n"                    /* 10: missing */
		"\twait\n"                           /* 11 */
		"  do stop\n"                        /* 12: spaces in a text of tabs: the line is dropped... */
		"\t\t\t\tdo stop\n"                  /* 13: ...and what hangs from nothing is not said */
		"\ttree nowhere\n"                   /* 14: no such tree (when linked) */
		"\tinvert\n"                         /* 15: needs a child */
		"tree a:\n"                          /* 16: twice */
		"do stop\n";
	static const int lines[10] = { 4, 5, 6, 8, 9, 10, 11, 12, 15, 16 };
	bt_vocab *v = spec_vocab();
	bt_diag d[20], one;
	int n, i;
	n = bt_diagnose(v, MANY, 0, d, 20);
	CHECK(n == 10);
	for (i = 0; i < n && i < 10; i++) {
		CHECK(d[i].line == lines[i]);
		if (d[i].line != lines[i]) printf("  %d: line %d:%d %s\n", i, d[i].line, d[i].column, d[i].message);
	}
	CHECK(n > 5 && strstr(d[0].message, "is a number") && d[0].column == 11 && strstr(d[2].message, "no action called figth"));
	CHECK(n > 5 && strstr(d[5].message, "<mode> is missing") && strstr(d[4].message, "no trait"));
	/* the first is the one the compiler stops at */
	CHECK(bt_compile_diag(v, MANY, &one) == NULL && one.line == d[0].line && !strcmp(one.message, d[0].message));
	CHECK(bt_parse(v, MANY, &one) == NULL && one.line == 4);
	/* no more than asked for; none asked: only the count of the first */
	CHECK(bt_diagnose(v, MANY, 0, d, 3) == 3 && d[2].line == 6);
	CHECK(bt_diagnose(v, MANY, 0, NULL, 0) == 1);
	/* linked: the references too, each once */
	n = bt_diagnose(v, "tree a:\nseq\n\ttree zzz\n\ttree b\n\ttree yyy\ntree b:\ntree a\n", 1, d, 20);
	CHECK(n == 2 && d[0].line == 3 && strstr(d[0].message, "zzz") && d[1].line == 5 && strstr(d[1].message, "yyy"));
	CHECK(bt_diagnose(v, "tree a:\nseq\n\ttree zzz\n", 0, d, 20) == 0);
	n = bt_diagnose(v, "tree a:\nseq\n\ttree b\ntree b:\ntree a\n", 1, d, 20);
	CHECK(n >= 1 && strstr(d[0].message, "itself"));
	/* a text that is right has none, linked or not */
	CHECK(bt_diagnose(v, "tree a:\nseq\n\tdo go home\n\ttree b\ntree b:\ndo stop\n", 1, d, 20) == 0);
	CHECK(bt_diagnose(v, "", 0, d, 20) == 1 && strstr(d[0].message, "no tree"));
	CHECK(bt_diagnose(NULL, "do stop\n", 0, d, 20) == 1);
	bt_vocab_free(v);
}

/* ---- pick roll=: a role drawn by lot, and kept ------------------------- */

/* which of act 0..3 the tree is in after one tick (-1: none) */
static int role_of(Rig *r)
{
	int before[N], i, got = -1;
	memcpy(before, r->bot->calls, sizeof before);
	rig_tick(r, 0.1f);
	for (i = 0; i < N; i++) if (r->bot->calls[i] > before[i]) got = i;
	return got;
}

static const char ROLES[] =
	"tree main:\n"
	"pick roll=once\n"
	"\toption a sc 0\n"
	"\t\tdo act 0\n"
	"\toption a sc 1 x10\n"
	"\t\tdo act 1\n"
	"\toption a sc 2\n"
	"\t\tdo act 2\n";

static void test_roll(void)
{
	Rig r;
	Bot b;
	bt_node n;
	bt_worth w[4];
	char err[200];
	int count[4] = {0, 0, 0, 0}, i, k, role;
	bot_init(&b, 3);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }

	/* THE SHARES: x1, x10, x1 over 12,000 bots is 1000, 10000, 1000 */
	if (!rig_open(&r, ROLES, &b)) return;
	for (i = 1; i <= 12000; i++) {
		r.ctx.identity = (uint64_t)i * 7919u;
		bt_reset(r.f, r.s, &r.ctx);
		role = role_of(&r);
		CHECK(role >= 0 && role <= 2);
		if (role >= 0) count[role]++;
	}
	printf("  roll=once, options x1 x10 x1, 12000 bots: %d, %d, %d\n", count[0], count[1], count[2]);
	CHECK(count[0] > 880 && count[0] < 1120 && count[2] > 880 && count[2] < 1120 && count[1] > 9800 && count[1] < 10200);

	/* THE SAME BOT, THE SAME ROLE: tick after tick, life after life, startled or not */
	for (i = 1; i <= 300; i++) {
		r.ctx.identity = 1000u + (uint64_t)i;
		bt_reset(r.f, r.s, &r.ctx);
		role = role_of(&r);
		CHECK(role_of(&r) == role);
		bt_restart(r.f, r.s, &r.ctx);
		CHECK(role_of(&r) == role);
		bt_reset(r.f, r.s, &r.ctx);
		CHECK(role_of(&r) == role);
		count[3] = role;                /* kept for below: bot 1300's */
	}
	/* a bot's weights are in it: with a weight of 3 for the trait of the
	 * first option only... all three here are trait a, so nothing moves */
	rig_close(&r);

	/* the trees compiled again, with other trees round it, and through a
	 * reference: the same role for the same bot -- its draw is made of its
	 * identity, the tree's name and which pick of that tree it is */
	{
		static const char MORE[] =
			"tree other:\npick every=1\n\toption a sc 3\n\t\tdo act 3\n"
			"tree outer:\nselect\n\ttree main\n"
			"tree main:\npick roll=once\n\toption a sc 0\n\t\tdo act 0\n\toption a sc 1 x10\n\t\tdo act 1\n\toption a sc 2\n\t\tdo act 2\n"
			"tree last:\npick roll=once\n\toption a sc 0\n\t\tdo act 0\n\toption a sc 1\n\t\tdo act 1\n";
		Rig a, m;
		int same = 0, same_ref = 0, other_pick_same = 0;
		if (!rig_open(&a, ROLES, &b)) return;
		if (!rig_open(&m, MORE, &b)) { rig_close(&a); return; }
		for (i = 1; i <= 400; i++) {
			int r0, r1, r2, before[N];
			a.ctx.identity = m.ctx.identity = 50000u + (uint64_t)i * 13u;
			bt_reset(a.f, a.s, &a.ctx); bt_reset(m.f, m.s, &m.ctx);
			r0 = role_of(&a);
			memcpy(before, b.calls, sizeof before);
			m.ctx.dt = 0.1f;
			bt_tick(m.f, bt_forest_find(m.f, "main"), m.s, &m.ctx);
			for (k = 0, r1 = -1; k < 3; k++) if (b.calls[k] > before[k]) r1 = k;
			memcpy(before, b.calls, sizeof before);
			bt_tick(m.f, bt_forest_find(m.f, "outer"), m.s, &m.ctx);
			for (k = 0, r2 = -1; k < 3; k++) if (b.calls[k] > before[k]) r2 = k;
			memcpy(before, b.calls, sizeof before);
			bt_tick(m.f, bt_forest_find(m.f, "last"), m.s, &m.ctx);
			same += r0 == r1;
			same_ref += r0 == r2;
			other_pick_same += (r0 == 1) == (b.calls[1] > before[1]);
		}
		CHECK(same == 400 && same_ref == 400);
		/* another tree's pick is another draw: it agrees no more than chance has it */
		printf("  the same role in another text and through a reference: %d and %d of 400; another tree's pick agrees %d times\n",
		       same, same_ref, other_pick_same);
		CHECK(other_pick_same > 150 && other_pick_same < 290);
		rig_close(&a); rig_close(&m);
	}

	/* TWO PICKS OF ONE TREE draw each for itself: four combinations, a quarter each */
	bot_init(&b, 4);
	for (i = 0; i < N; i++) { b.ret[i] = BT_SUCCESS; b.sc[i] = 1.0f; }
	if (rig_open(&r, "seq\n\tpick roll=once\n\t\toption a sc 0\n\t\t\tdo act 0\n\t\toption a sc 1\n\t\t\tdo act 1\n"
	                 "\tpick roll=once\n\t\toption a sc 2\n\t\t\tdo act 2\n\t\toption a sc 3\n\t\t\tdo act 3\n", &b)) {
		int joint[4] = {0, 0, 0, 0};
		for (i = 1; i <= 4000; i++) {
			int before[N];
			r.ctx.identity = 99u + (uint64_t)i * 31u;
			bt_reset(r.f, r.s, &r.ctx);
			memcpy(before, b.calls, sizeof before);
			CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS);            /* each child ended: the pick answers as it did */
			joint[(b.calls[1] > before[1]) * 2 + (b.calls[3] > before[3])]++;
		}
		printf("  two picks of one tree, 4000 bots: %d %d %d %d\n", joint[0], joint[1], joint[2], joint[3]);
		for (k = 0; k < 4; k++) CHECK(joint[k] > 880 && joint[k] < 1120);
		/* THE ROLE DOES NOT MOVE when its child ends: the same child, ticked again */
		r.ctx.identity = 5;
		bt_reset(r.f, r.s, &r.ctx);
		{
			int c0[N], c1[N];
			memcpy(c0, b.calls, sizeof c0);
			for (k = 0; k < 10; k++) rig_tick(&r, 0.1f);
			memcpy(c1, b.calls, sizeof c1);
			CHECK((c1[0] - c0[0] == 10 && c1[1] == c0[1]) || (c1[1] - c0[1] == 10 && c1[0] == c0[0]));
			b.ret[0] = b.ret[1] = BT_FAILURE;                    /* and its failure is the pick's */
			CHECK(rig_tick(&r, 0.1f) == BT_FAILURE);
			CHECK(b.calls[0] + b.calls[1] == c1[0] + c1[1] + 1);
		}
		rig_close(&r);
	}

	/* the trait weights are in the lottery: a weight of 3 against 1 is 3 in 4 */
	bot_init(&b, 5);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }
	if (rig_open(&r, "pick roll=once\n\toption a sc 0\n\t\tdo act 0\n\toption b sc 1\n\t\tdo act 1\n", &b)) {
		int first = 0;
		r.w[1] = 3.0f; r.w[2] = 1.0f;
		for (i = 1; i <= 4000; i++) {
			r.ctx.identity = 77u + (uint64_t)i * 101u;
			bt_reset(r.f, r.s, &r.ctx);
			first += role_of(&r) == 0;
		}
		printf("  a trait weight of 3 against 1: %d of 4000 took the first\n", first);
		CHECK(first > 2880 && first < 3120);
		/* a score of 0 is never drawn; with none above 0 the pick fails and
		 * asks again; and the draw falls where the worths then put it */
		b.sc[0] = 0.0f;
		for (i = 1; i <= 500; i++) {
			r.ctx.identity = 9000u + (uint64_t)i;
			bt_reset(r.f, r.s, &r.ctx);
			CHECK(role_of(&r) == 1);
		}
		b.sc[1] = 0.0f;
		bt_reset(r.f, r.s, &r.ctx);
		CHECK(rig_tick(&r, 0.1f) == BT_FAILURE && rig_tick(&r, 0.1f) == BT_FAILURE);
		b.sc[0] = 1.0f;
		CHECK(role_of(&r) == 0);
		b.sc[1] = 1.0f;                                 /* drawn: it is not asked again in this life */
		CHECK(role_of(&r) == 0 && role_of(&r) == 0);

		/* what the lottery was, for whoever watches: each share, the draw, the role */
		r.ctx.identity = 4242;
		bt_reset(r.f, r.s, &r.ctx);
		bt_state_trace(r.s, 1);
		role = role_of(&r);
		CHECK(bt_state_worths(r.f, r.s, 0, w, 4) == 2 && w[0].weighed && w[1].weighed);
		CHECK(near(w[0].share, 0.75f) && near(w[1].share, 0.25f) && w[0].draw == w[1].draw && w[0].draw >= 0.0f && w[0].draw < 1.0f);
		CHECK(w[0].luck == 1.0f && w[0].sticky == 1.0f && near(w[0].worth, 3.0f) && near(w[1].worth, 1.0f));
		CHECK(w[role].held && !w[1 - role].held && (w[0].draw < 0.75f) == (role == 0));
		{
			bt_node_state ns;
			CHECK(bt_state_node(r.f, r.s, 0, &ns) && ns.running && ns.child == (role ? 3 : 1));
			b.ret[0] = b.ret[1] = BT_SUCCESS;
			rig_tick(&r, 0.1f);                                  /* not RUNNING now: its role is known all the same */
			CHECK(bt_state_node(r.f, r.s, 0, &ns) && !ns.running && ns.child == (role ? 3 : 1));
			CHECK(bt_state_worths(r.f, r.s, 0, w, 4) == 2 && w[role].held);
			b.ret[0] = b.ret[1] = BT_RUNNING;
		}
		rig_close(&r);
	}

	/* ROLL=LIFE: kept within a life -- startled (bt_restart), or the branch
	 * above it left and come back to -- and drawn anew at each bt_reset */
	bot_init(&b, 6);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }
	if (rig_open(&r, "pick every=0 noise=0\n\toption a sc 3 x5\n\t\tdo act 3\n\toption a sc 2\n"
	                 "\t\tpick roll=life\n\t\t\toption a sc 0\n\t\t\t\tdo act 0\n\t\t\toption a sc 1\n\t\t\t\tdo act 1\n", &b)) {
		int seen[2] = {0, 0}, changed = 0, last = -1;
		r.ctx.identity = 77;                            /* an identity changes nothing for roll=life */
		b.sc[3] = 0.0f;
		for (i = 0; i < 300; i++) {
			bt_reset(r.f, r.s, &r.ctx);
			role = role_of(&r);
			CHECK(role == 0 || role == 1);
			if (role < 0) break;
			seen[role]++;
			changed += last >= 0 && role != last;
			last = role;
			CHECK(role_of(&r) == role);
			bt_restart(r.f, r.s, &r.ctx);
			CHECK(role_of(&r) == role);
			b.sc[3] = 1.0f;                             /* the pick above takes its other option... */
			CHECK(role_of(&r) == 3 && b.stops[role] > 0);
			b.sc[3] = 0.0f;                             /* ...and comes back: the same role */
			CHECK(role_of(&r) == role);
		}
		printf("  roll=life over 300 lives: %d and %d, changed %d times\n", seen[0], seen[1], changed);
		CHECK(seen[0] > 110 && seen[1] > 110 && changed > 100);
		rig_close(&r);
	}
	/* with no identity (0), roll=once is drawn as roll=life is: once a reset, from the bot's dice */
	if (rig_open(&r, "pick roll=once\n\toption a sc 0\n\t\tdo act 0\n\toption a sc 1\n\t\tdo act 1\n", &b)) {
		int seen[2] = {0, 0};
		r.ctx.identity = 0;
		for (i = 0; i < 300; i++) {
			bt_reset(r.f, r.s, &r.ctx);
			role = role_of(&r);
			if (role == 0 || role == 1) seen[role]++;
			CHECK(role_of(&r) == role);
			bt_restart(r.f, r.s, &r.ctx);
			CHECK(role_of(&r) == role);
		}
		CHECK(seen[0] > 110 && seen[1] > 110 && seen[0] + seen[1] == 300);
		rig_close(&r);
	}

	/* as data, and in the text written back */
	{
		bt_source *src = bt_parse(vocab, "select\n  pick   roll=once   # roles\n    option a sc 0\n      do act 0\n  pick roll=weighed every=3\n    option a sc 0\n      do act 0\n  pick\n    option a sc 0\n      do act 0\n", NULL);
		char *text;
		CHECK(src != NULL);
		if (src) {
			CHECK(bt_source_node(src, 1, &n) && n.kind == BT_K_PICK && n.roll == BT_ROLL_ONCE && n.written == BT_W_ROLL);
			CHECK(bt_source_node(src, 4, &n) && n.roll == BT_ROLL_WEIGHED && n.written == (BT_W_ROLL | BT_W_EVERY));
			CHECK(bt_source_node(src, 7, &n) && n.roll == BT_ROLL_WEIGHED && n.written == 0);
			bt_source_free(src);
		}
		text = canonical(vocab, "pick roll=life\n  option a sc 0\n    do act 0\n", NULL);
		CHECK(text && !strncmp(text, "pick roll=life\n", 15));
		free(text);
	}
	/* what may not be written */
	bad("pick roll=once every=2\n\toption a sc 0\n\t\tdo act 0\n", 1, "every, sticky and noise have no meaning");
	bad("pick sticky=1 roll=life\n\toption a sc 0\n\t\tdo act 0\n", 1, "roll=life");
	bad("pick noise=0 roll=once\n\toption a sc 0\n\t\tdo act 0\n", 1, "no meaning");
	bad("pick roll=twice\n\toption a sc 0\n\t\tdo act 0\n", 1, "weighed, once or life");
	bad("pick roll=\n\toption a sc 0\n\t\tdo act 0\n", 1, "weighed, once or life");
	(void)err; (void)count;
}

/* ---- pick roll=each: a lottery drawn again at every choice ------------- */

static int draws;
static float rnd_counted(void *b) { draws++; return rnd(b); }

static void test_roll_each(void)
{
	Rig r, r2;
	Bot b, b2;
	bt_worth w[4];
	bt_node n;
	int i, role, count[4], last, switches, stops;
	static const char X1_10_1[] =
		"pick roll=each every=0\n\toption a sc 0\n\t\tdo act 0\n\toption a sc 1 x10\n\t\tdo act 1\n\toption a sc 2\n\t\tdo act 2\n";
	bot_init(&b, 21);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }

	/* THE SHARES, over the choices of ONE bot (an identity is no part of it) */
	if (rig_open(&r, X1_10_1, &b)) {
		memset(count, 0, sizeof count);
		r.ctx.identity = 99;
		for (i = 0; i < 6000; i++) { role = role_of(&r); CHECK(role >= 0 && role <= 2); if (role >= 0) count[role]++; }
		printf("  roll=each, options x1 x10 x1, 6000 choices of one bot: %d, %d, %d\n", count[0], count[1], count[2]);
		CHECK(count[0] > 400 && count[0] < 600 && count[2] > 400 && count[2] < 600 && count[1] > 4900 && count[1] < 5100);
		rig_close(&r);
	}

	/* the 0.9 / 0.9 / 1.2 of the doc: 30%, 30%, 40% */
	bot_init(&b, 22);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }
	b.sc[0] = 0.9f; b.sc[1] = 0.9f; b.sc[2] = 1.2f;
	if (rig_open(&r, "pick roll=each every=0\n\toption a sc 0\n\t\tdo act 0\n\toption a sc 1\n\t\tdo act 1\n\toption a sc 2\n\t\tdo act 2\n", &b)) {
		memset(count, 0, sizeof count);
		for (i = 0; i < 6000; i++) { role = role_of(&r); if (role >= 0) count[role]++; }
		printf("  roll=each, worths 0.9 0.9 1.2, 6000 choices: %d, %d, %d\n", count[0], count[1], count[2]);
		CHECK(count[0] > 1650 && count[0] < 1950 && count[1] > 1650 && count[1] < 1950 && count[2] > 2250 && count[2] < 2550);
		rig_close(&r);
	}

	/* the trait weight is in it: 3 against 1 is 3 in 4; a score of 0 is never drawn */
	bot_init(&b, 23);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }
	if (rig_open(&r, "pick roll=each every=0\n\toption a sc 0\n\t\tdo act 0\n\toption b sc 1\n\t\tdo act 1\n", &b)) {
		int first = 0;
		r.w[1] = 3.0f; r.w[2] = 1.0f;
		for (i = 0; i < 4000; i++) first += role_of(&r) == 0;
		printf("  roll=each, a trait weight of 3 against 1: %d of 4000 took the first\n", first);
		CHECK(first > 2880 && first < 3120);
		b.sc[0] = 0.0f;
		for (i = 0; i < 500; i++) CHECK(role_of(&r) == 1);
		/* all 0: the pick fails, draws nothing, and asks again at the next tick */
		b.sc[1] = 0.0f;
		draws = 0;
		r.ctx.random = rnd_counted;
		CHECK(rig_tick(&r, 0.1f) == BT_FAILURE && rig_tick(&r, 0.1f) == BT_FAILURE && draws == 0);
		b.sc[1] = 0.5f;
		CHECK(role_of(&r) == 1 && draws == 1);
		rig_close(&r);
	}

	/* `every` is respected, and a child that ends is a choice: draws counted */
	bot_init(&b, 24);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }
	if (rig_open(&r, "pick roll=each every=1\n\toption a sc 0\n\t\tdo act 0\n\toption a sc 1\n\t\tdo act 1\n", &b)) {
		bt_node_state ns;
		draws = 0;
		r.ctx.random = rnd_counted;
		for (i = 0; i < 4; i++) { rig_tick(&r, 0.1f); CHECK(draws == 1); }     /* held between choices */
		CHECK(bt_state_node(r.f, r.s, 0, &ns) && ns.running && ns.child >= 0);
		for (i = 4; i < 100; i++) rig_tick(&r, 0.1f);
		printf("  roll=each every=1, 100 ticks of 0.1 s: %d draws\n", draws);
		CHECK(draws >= 9 && draws <= 11);
		draws = 0;
		b.ret[0] = b.ret[1] = BT_SUCCESS;                /* the child ends at once: a draw at each tick */
		for (i = 0; i < 20; i++) rig_tick(&r, 0.1f);
		CHECK(draws == 20);
		rig_close(&r);
	}
	/* the default `every` is a plain pick's (2 s) */
	bot_init(&b, 25);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }
	if (rig_open(&r, "pick roll=each\n\toption a sc 0\n\t\tdo act 0\n\toption a sc 1\n\t\tdo act 1\n", &b)) {
		r.ctx.random = rnd_counted;
		draws = 0;
		for (i = 0; i < 100; i++) rig_tick(&r, 0.1f);       /* 10 s */
		CHECK(draws >= 4 && draws <= 6);
		rig_close(&r);
	}

	/* THE HELD OPTION DRAWN AGAIN GOES ON: it is stopped only when left, and once */
	bot_init(&b, 26);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }
	if (rig_open(&r, "pick roll=each every=0\n\toption a sc 0\n\t\tdo act 0\n\toption a sc 1\n\t\tdo act 1\n", &b)) {
		last = -1; switches = 0;
		for (i = 0; i < 400; i++) {
			role = role_of(&r);
			if (last >= 0 && role != last) switches++;
			last = role;
		}
		stops = b.stops[0] + b.stops[1];
		printf("  roll=each, 400 choices of two: %d switches, %d stops\n", switches, stops);
		CHECK(switches > 100 && switches < 300 && stops == switches);
		CHECK(b.calls[0] + b.calls[1] == 400);
		rig_close(&r);
	}
	/* one option alone: drawn every tick, never stopped */
	bot_init(&b, 27);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }
	if (rig_open(&r, "pick roll=each every=0\n\toption a sc 0\n\t\tdo act 0\n", &b)) {
		for (i = 0; i < 50; i++) CHECK(role_of(&r) == 0);
		CHECK(b.stops[0] == 0 && b.calls[0] == 50);
		rig_close(&r);
	}

	/* A JOLT: as a plain pick, it chooses at once and stops what it did (once); bt_reset likewise */
	bot_init(&b, 28);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }
	if (rig_open(&r, "pick roll=each every=100\n\toption a sc 0\n\t\tdo act 0\n\toption a sc 1\n\t\tdo act 1\n", &b)) {
		r.ctx.random = rnd_counted;
		draws = 0;
		for (i = 0; i < 10; i++) rig_tick(&r, 0.1f);
		CHECK(draws == 1);
		bt_restart(r.f, r.s, &r.ctx);
		CHECK(b.stops[0] + b.stops[1] == 1);
		rig_tick(&r, 0.1f);
		CHECK(draws == 2);
		for (i = 0; i < 10; i++) rig_tick(&r, 0.1f);
		CHECK(draws == 2);
		bt_reset(r.f, r.s, &r.ctx);
		CHECK(b.stops[0] + b.stops[1] == 2);
		rig_tick(&r, 0.1f);
		CHECK(draws == 3);
		rig_close(&r);
	}

	/* REPLAY: the same random stream, the same sequence of options */
	bot_init(&b, 31); bot_init(&b2, 31);
	for (i = 0; i < N; i++) { b.ret[i] = b2.ret[i] = BT_RUNNING; b.sc[i] = b2.sc[i] = 1.0f; }
	if (rig_open(&r, X1_10_1, &b) && rig_open(&r2, X1_10_1, &b2)) {
		int same = 0;
		r.ctx.identity = 5; r2.ctx.identity = 6;           /* the identity is not what it draws from */
		for (i = 0; i < 500; i++) same += role_of(&r) == role_of(&r2);
		CHECK(same == 500);
		rig_close(&r); rig_close(&r2);
	}

	/* what it shows: the shares, the last draw, the option held */
	bot_init(&b, 32);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }
	if (rig_open(&r, "pick roll=each\n\toption a sc 0\n\t\tdo act 0\n\toption b sc 1\n\t\tdo act 1\n", &b)) {
		r.w[1] = 3.0f; r.w[2] = 1.0f;
		bt_state_trace(r.s, 1);
		role = role_of(&r);
		CHECK(bt_state_worths(r.f, r.s, 0, w, 4) == 2 && w[0].weighed && w[1].weighed);
		CHECK(near(w[0].share, 0.75f) && near(w[1].share, 0.25f) && w[0].draw == w[1].draw && w[0].draw >= 0.0f && w[0].draw < 1.0f);
		CHECK(w[0].luck == 1.0f && w[0].sticky == 1.0f && near(w[0].worth, 3.0f));
		CHECK(w[role].held && !w[1 - role].held && (w[0].draw < 0.75f) == (role == 0));
		rig_close(&r);
	}

	/* as data, in the text written back, and what may not be written */
	{
		bt_source *src = bt_parse(vocab, "pick roll=each every=3\n  option a sc 0\n    do act 0\n", NULL);
		char *text;
		CHECK(src != NULL);
		if (src) {
			CHECK(bt_source_node(src, 0, &n) && n.kind == BT_K_PICK && n.roll == BT_ROLL_EACH && n.written == (BT_W_ROLL | BT_W_EVERY));
			CHECK(n.every == 3.0f);
			bt_source_free(src);
		}
		text = canonical(vocab, "pick   roll=each   every=3\n  option a sc 0\n    do act 0\n", NULL);
		CHECK(text && !strncmp(text, "pick roll=each every=3\n", 23));
		free(text);
	}
	bad("pick roll=each sticky=1\n\toption a sc 0\n\t\tdo act 0\n", 1, "sticky and noise have no meaning");
	bad("pick noise=0 roll=each\n\toption a sc 0\n\t\tdo act 0\n", 1, "roll=each");
	bad("pick roll=each every=2 noise=0.1\n\toption a sc 0\n\t\tdo act 0\n", 1, "no meaning");
}

/* a plain pick's tick, timed: the cost of choosing must not have grown */
static void bench_plain_pick(void)
{
	Rig r;
	Bot b;
	int i;
	clock_t t0;
	bot_init(&b, 41);
	for (i = 0; i < N; i++) { b.ret[i] = BT_RUNNING; b.sc[i] = 1.0f; }
	if (!rig_open(&r, "pick every=0\n\toption a sc 0\n\t\tdo act 0\n\toption a sc 1\n\t\tdo act 1\n\toption a sc 2\n\t\tdo act 2\n", &b)) return;
	t0 = clock();
	for (i = 0; i < 2000000; i++) rig_tick(&r, 0.1f);
	printf("  a plain pick of three, every=0: %.1f ns a tick\n", 1e9 * (double)(clock() - t0) / CLOCKS_PER_SEC / 2000000.0);
	rig_close(&r);
}


/* ---- conditions on numbers: a value, compared ------------------------ */

/* `v <i>`: the test's value, 0 to 100; `v_below <i> [n]` is short for
 * `v <i> < n` (n 50 if left out), `v_far <i> <n>` for `unless v <i> <=
 * n`, and the score `v_high <i> <n>` for `v <i> >= n` */
static const bt_arg_spec SPEC_V_IDX[1] = { { "i", BT_ARG_NUMBER, 1, 0, 0, 1, 1, NULL, NULL, 0, 0, N - 1, NULL, NULL } };
static const bt_arg_spec SPEC_V_RANGE = { "units", BT_ARG_NUMBER, 1, 0, 0, 1, 1, NULL, NULL, 0, 0, 100, NULL, NULL };
static const bt_arg_spec SPEC_V_BELOW[2] = {
	{ "i", BT_ARG_NUMBER, 1, 0, 0, 1, 1, NULL, NULL, 0, 0, N - 1, NULL, NULL },
	{ "n", BT_ARG_NUMBER, 0, 0, 1, 1, 1, NULL, NULL, 50, 0, 100, NULL, NULL },
};
static const bt_arg_spec SPEC_V_N[2] = {
	{ "i", BT_ARG_NUMBER, 1, 0, 0, 1, 1, NULL, NULL, 0, 0, N - 1, NULL, NULL },
	{ "n", BT_ARG_NUMBER, 1, 0, 0, 1, 1, NULL, NULL, 0, 0, 100, NULL, NULL },
};

static bt_status tick_once(const char *text, Bot *b)
{
	Rig r;
	bt_status st = BT_FAILURE;
	if (rig_open(&r, text, b)) { st = rig_tick(&r, 0.1f); rig_close(&r); }
	return st;
}

static void test_compare(void)
{
	static const char *const OPS[4] = { "<", "<=", ">", ">=" };
	static const double AT[3] = { 4.999, 5.0, 5.001 };
	char text[100];
	int o, k, neg;
	Bot b;
	bot_init(&b, 1);
	/* every operator on both sides of its edge, as if and as unless */
	for (o = 0; o < 4; o++)
		for (k = 0; k < 3; k++)
			for (neg = 0; neg < 2; neg++) {
				double v = AT[k];
				int want = o == 0 ? v < 5 : o == 1 ? v <= 5 : o == 2 ? v > 5 : v >= 5;
				b.val[3] = v;
				b.unknown[3] = 0;
				snprintf(text, sizeof text, "%s v 3 %s 5\n", neg ? "unless" : "if", OPS[o]);
				CHECK(tick_once(text, &b) == ((want ^ neg) ? BT_SUCCESS : BT_FAILURE));
				/* unknown: the comparison is false whatever it says, so unless is true */
				b.unknown[3] = 1;
				CHECK(tick_once(text, &b) == (neg ? BT_SUCCESS : BT_FAILURE));
			}
	b.unknown[3] = 0;
	/* the number may be any way a number is written; the source has it */
	b.val[1] = 0.25;
	CHECK(tick_once("if v 1 >= 2.5e-1\n", &b) == BT_SUCCESS);
	CHECK(tick_once("if v 1 < .3\n", &b) == BT_SUCCESS);
	{
		bt_source *src = bt_parse(vocab, "if v 1 <= 7.5 # a comment\n", NULL);
		bt_node n;
		CHECK(src && bt_source_node(src, 0, &n));
		if (src) {
			CHECK(n.kind == BT_K_IF && n.op == BT_OP_LE && n.number == 7.5f && !strcmp(n.name, "v") && n.args.count == 1 &&
			      !strcmp(n.args.text[0], "1") && !strcmp(n.text, "if v 1 <= 7.5") && !strcmp(n.comment, "a comment"));
			CHECK(!strcmp(bt_op_name(n.op), "<=") && bt_op_name(BT_OP_NONE) == NULL && bt_op_name(BT_OP_COUNT) == NULL);
		}
		bt_source_free(src);
	}
	/* a word short for a comparison: the same answer as the comparison
	 * written out, over a sweep; the source keeps the word as written */
	for (k = 0; k <= 100; k++) {
		char a[100], c[100];
		b.val[2] = k * 0.5 + (k % 3 == 0 ? 0.0 : 0.25);
		b.unknown[2] = k % 17 == 0;
		snprintf(a, sizeof a, "if v_below 2 %d\n", 20 + k % 13);
		snprintf(c, sizeof c, "if v 2 < %d\n", 20 + k % 13);
		CHECK(tick_once(a, &b) == tick_once(c, &b));
		CHECK(tick_once("unless v_below 2\n", &b) == tick_once("unless v 2 < 50\n", &b));     /* its default */
		snprintf(a, sizeof a, "if v_far 2 %d\n", 20 + k % 13);
		snprintf(c, sizeof c, "unless v 2 <= %d\n", 20 + k % 13);
		CHECK(tick_once(a, &b) == tick_once(c, &b));
		snprintf(a, sizeof a, "unless v_far 2 %d\n", 20 + k % 13);
		snprintf(c, sizeof c, "if v 2 <= %d\n", 20 + k % 13);
		CHECK(tick_once(a, &b) == tick_once(c, &b));
	}
	{
		bt_source *src = bt_parse(vocab, "if v_below 2\n", NULL);
		bt_node n;
		CHECK(src && bt_source_node(src, 0, &n) && n.op == BT_OP_NONE && !strcmp(n.name, "v_below") &&
		      n.args.count == 1 && !strcmp(n.text, "if v_below 2"));
		bt_source_free(src);
	}
	/* its own arguments are checked as any word's */
	bad("if v_below\n", 1, "<i> is missing");
	bad("if v_below 2 300\n", 1, "between 0 and 100");
	bad("if v_far 2\n", 1, "<n> is missing");
}

static void test_compare_errors(void)
{
	diag_is("select\n\tif v 1 <\n", 2, 9, "a number must follow the operator");
	diag_is("select\n\tif w 1 < 3\n", 2, 5, "no value called w");
	diag_is("select\n\tif flag 1 < 3\n", 2, 5, "flag is a condition");
	diag_is("select\n\tif v 1\n", 2, 5, "v is a value: compare it");
	diag_is("select\n\tif v 1 < 500\n", 2, 11, "between 0 and 100");
	diag_is("select\n\tif v 1 >= -1\n", 2, 12, "between 0 and 100");
	diag_is("select\n\tif v 1 == 3\n", 2, 9, "not an operator");
	diag_is("select\n\tif v 1 != 3\n", 2, 9, "not an operator");
	diag_is("select\n\tif v 1 = 3\n", 2, 9, "not an operator");
	diag_is("select\n\tif v 1 < lots\n", 2, 11, "'lots' is not a number");
	diag_is("select\n\tif v 1 < 3 4\n", 2, 13, "nothing may follow the number");
	diag_is("select\n\tif v<3\n", 2, 5, "spaces round its operator");
	diag_is("select\n\tif v 9 < 3\n", 2, 7, "<i> must be between 0 and 7");
	diag_is("select\n\tif v < 3\n", 2, 5, "<i> is missing");
	diag_is("pick\n\toption a v 1 < 500 x2\n\t\tdo act 0\n", 2, 17, "between 0 and 100");
	diag_is("pick\n\toption a sc 0 < 5\n\t\tdo act 0\n", 2, 11, "sc is a score");
	diag_is("pick\n\toption a v 1\n\t\tdo act 0\n", 2, 11, "v is a value");
}

/* the score form: 1 when it holds, 0 when not -- never chosen at 0 */
static void test_compare_score(void)
{
	Rig r;
	Bot b;
	int i, n[2] = {0, 0};
	bot_init(&b, 3);
	b.sc[0] = 0.5f;
	b.val[0] = 10;
	if (rig_open(&r, "pick noise=0\n\toption a v 0 < 20 x2\n\t\tdo act 0\n\toption b sc 0\n\t\tdo act 1\n", &b)) {
		b.ret[0] = b.ret[1] = BT_RUNNING;
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING && b.calls[0] == 1);              /* 1 x 2 against 0.5 */
		b.val[0] = 30;                                                          /* it no longer holds: 0 */
		for (i = 0; i < 30; i++) rig_tick(&r, 0.1f);
		CHECK(b.calls[1] > 0 && b.stops[0] == 1);
		b.unknown[0] = 1;                                                       /* unknown: 0 too */
		bt_reset(r.f, r.s, &r.ctx);
		memset(b.calls, 0, sizeof b.calls);
		for (i = 0; i < 30; i++) rig_tick(&r, 0.1f);
		CHECK(b.calls[0] == 0 && b.calls[1] > 0);
		rig_close(&r);
	}
	/* drawn in proportion to its worth in a lottery: x3 against x1 */
	bot_init(&b, 4);
	b.val[0] = 10;
	b.sc[0] = 1;
	if (rig_open(&r, "pick roll=each every=0\n\toption none v 0 >= 10 x3\n\t\tdo act 0\n\toption none sc 0\n\t\tdo act 1\n", &b)) {
		for (i = 0; i < 4000; i++) rig_tick(&r, 0.1f);
		n[0] = b.calls[0]; n[1] = b.calls[1];
		CHECK(n[0] + n[1] == 4000 && n[0] > 2850 && n[0] < 3150);                /* 3 in 4 */
		b.val[0] = 9.99;                                                        /* 0: never drawn */
		memset(b.calls, 0, sizeof b.calls);
		for (i = 0; i < 500; i++) rig_tick(&r, 0.1f);
		CHECK(b.calls[0] == 0 && b.calls[1] == 500);
		rig_close(&r);
	}
	/* a score short for a comparison is that comparison, as a score */
	bot_init(&b, 5);
	b.val[4] = 60;
	b.sc[0] = 0.5f;
	if (rig_open(&r, "pick noise=0\n\toption a v_high 4 50\n\t\tdo act 0\n\toption b sc 0\n\t\tdo act 1\n", &b)) {
		bt_worth w[2];
		bt_state_trace(r.s, 1);
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS && b.calls[0] == 1);
		CHECK(bt_state_worths(r.f, r.s, 0, w, 2) == 2 && w[0].score == 1.0f && w[1].score == 0.5f);
		b.val[4] = 49;
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS && b.calls[1] == 1);
		CHECK(bt_state_worths(r.f, r.s, 0, w, 2) == 2 && w[0].score == 0.0f);
		rig_close(&r);
	}
}

/* ---- if as a block ---------------------------------------------------- */

static void test_block(void)
{
	static const char IFELSE[] = "if flag 0\n\tdo act 0\n\tdo act 1\nelse\n\tdo act 2\n";
	Rig r;
	Bot b;
	int x, y, z;
	char d[200];
	/* the condition is asked when it is entered, and the branch kept */
	bot_init(&b, 1);
	b.flag[0] = 1;
	b.ret[0] = BT_RUNNING;
	if (rig_open(&r, IFELSE, &b)) {
		bt_node_state ns;
		int path[BT_DEPTH_MAX];
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING && b.calls[0] == 1);
		CHECK(bt_state_node(r.f, r.s, 0, &ns) && ns.running && ns.child == 1);
		CHECK(bt_state_running(r.f, r.s, 0, path, BT_DEPTH_MAX) == 2 && path[0] == 0 && path[1] == 1);
		CHECK(bt_describe(r.f, r.s, d, sizeof d) && !strcmp(d, "act"));
		b.flag[0] = 0;                                  /* it changes: the branch goes on */
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING && b.calls[0] == 2 && b.calls[2] == 0);
		b.ret[0] = BT_SUCCESS;                          /* the branch goes on in order, as a seq */
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS && b.calls[0] == 3 && b.calls[1] == 1 && b.calls[2] == 0);
		CHECK(bt_state_node(r.f, r.s, 0, &ns) && !ns.running && ns.child == -1);
		/* it ended: entered again, it asks again -- now the else */
		b.ret[2] = BT_RUNNING;
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING && b.calls[2] == 1 && b.calls[0] == 3);
		CHECK(bt_state_node(r.f, r.s, 0, &ns) && ns.running && ns.child == 4);
		/* the path goes from the if to the else's child, not through the else */
		CHECK(bt_state_running(r.f, r.s, 0, path, BT_DEPTH_MAX) == 2 && path[0] == 0 && path[1] == 4);
		b.flag[0] = 1;
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING && b.calls[2] == 2 && b.calls[0] == 3);
		/* a reset stops it, once, and forgets the branch */
		bt_reset(r.f, r.s, &r.ctx);
		CHECK(b.stops[2] == 1);
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS && b.calls[0] == 4 && b.calls[1] == 2);
		/* and a restart the same */
		b.flag[0] = 0;
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING && b.calls[2] == 3);
		bt_restart(r.f, r.s, &r.ctx);
		CHECK(b.stops[2] == 2);
		b.flag[0] = 1;
		CHECK(rig_tick(&r, 0.1f) == BT_SUCCESS && b.calls[0] == 5);
		/* a branch that fails: the block fails, the rest of it not ticked */
		b.ret[0] = BT_FAILURE;
		CHECK(rig_tick(&r, 0.1f) == BT_FAILURE && b.calls[0] == 6 && b.calls[1] == 3);
		rig_close(&r);
	}
	/* no else, the condition false: FAILURE, nothing ticked; unless turned */
	bot_init(&b, 1);
	CHECK(tick_once("if flag 0\n\tdo act 0\n", &b) == BT_FAILURE && b.calls[0] == 0);
	CHECK(tick_once("unless flag 0\n\tdo act 0\n", &b) == BT_SUCCESS && b.calls[0] == 1);
	CHECK(tick_once("unless flag 0\n\tdo act 0\nelse\n\tdo act 1\n", &b) == BT_SUCCESS && b.calls[0] == 2 && b.calls[1] == 0);
	b.flag[0] = 1;
	CHECK(tick_once("unless flag 0\n\tdo act 0\nelse\n\tdo act 1\n", &b) == BT_SUCCESS && b.calls[1] == 1 && b.calls[0] == 2);
	CHECK(tick_once("unless flag 0\n\tdo act 0\n", &b) == BT_FAILURE && b.calls[0] == 2);
	/* a comparison as the block's condition */
	b.val[0] = 4;
	CHECK(tick_once("if v 0 < 5\n\tdo act 0\nelse\n\tdo act 1\n", &b) == BT_SUCCESS && b.calls[0] == 3);
	b.unknown[0] = 1;
	CHECK(tick_once("if v 0 < 5\n\tdo act 0\nelse\n\tdo act 1\n", &b) == BT_SUCCESS && b.calls[1] == 2);
	/* the RUNNING action in the branch is stopped when its parent leaves
	 * it: a pick choosing another option */
	bot_init(&b, 1);
	b.flag[0] = 1;
	b.ret[0] = BT_RUNNING;
	b.sc[0] = 1; b.sc[1] = 0.5f;
	if (rig_open(&r, "pick every=1 noise=0 sticky=0\n\toption a sc 0\n\t\tif flag 0\n\t\t\tdo act 0\n\t\telse\n\t\t\tdo act 1\n"
	                 "\toption b sc 1\n\t\tdo act 2\n", &b)) {
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING && b.calls[0] == 1);
		CHECK(bt_describe(r.f, r.s, d, sizeof d) && !strcmp(d, "pick:a > act"));
		b.sc[1] = 2;
		rig_tick(&r, 1.0f);
		CHECK(b.stops[0] == 1 && b.calls[2] == 1);
		/* chosen again: the block is entered afresh and asks again */
		b.sc[1] = 0.1f;
		b.flag[0] = 0;
		b.ret[1] = BT_RUNNING;
		rig_tick(&r, 1.0f);
		CHECK(b.calls[1] == 1 && b.calls[0] == 1);
		rig_close(&r);
	}
	/* "keep checking": under a limit, the block is entered again when it
	 * runs out, and the condition asked again */
	bot_init(&b, 1);
	b.flag[0] = 1;
	b.ret[0] = b.ret[1] = BT_RUNNING;
	if (rig_open(&r, "select\n\tlimit 1\n\t\tif flag 0\n\t\t\tdo act 0\n\t\telse\n\t\t\tdo act 1\n\tdo act 2\n", &b)) {
		int i;
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING && b.calls[0] == 1);
		b.flag[0] = 0;
		for (i = 0; i < 9; i++) rig_tick(&r, 0.1f);
		CHECK(b.calls[0] == 10 && b.calls[1] == 0);                     /* within the limit: the branch kept */
		rig_tick(&r, 0.1f);
		CHECK(b.stops[0] == 1 && b.calls[2] == 1);                      /* run out: stopped, the select goes on */
		rig_tick(&r, 0.1f);                                             /* entered afresh: asked again */
		CHECK(b.calls[1] == 1 && b.calls[0] == 11 && b.calls[2] == 1);   /* (the limit asks its child first) */
		rig_close(&r);
	}
	/* nesting three deep, an else at each: every case to its own leaf */
	for (x = 0; x < 2; x++)
		for (y = 0; y < 2; y++)
			for (z = 0; z < 2; z++) {
				static const char T[] =
					"if flag 0\n"
					"\tif flag 1\n"
					"\t\tif flag 2\n"
					"\t\t\tdo act 0\n"
					"\t\telse\n"
					"\t\t\tdo act 1\n"
					"\telse\n"
					"\t\tunless flag 2\n"
					"\t\t\tdo act 2\n"
					"\t\telse\n"
					"\t\t\tdo act 3\n"
					"else\n"
					"\tif flag 1\n"
					"\t\tdo act 4\n"
					"\telse\n"
					"\t\tdo act 5\n";
				int want = x ? (y ? (z ? 0 : 1) : (z ? 3 : 2)) : (y ? 4 : 5), k, others = 0;
				bot_init(&b, 1);
				b.flag[0] = x; b.flag[1] = y; b.flag[2] = z;
				CHECK(tick_once(T, &b) == BT_SUCCESS);
				for (k = 0; k < 6; k++) others += k != want && b.calls[k];
				CHECK(b.calls[want] == 1 && others == 0);
			}
	/* around a pick, and the pick's own choice inside the branch */
	bot_init(&b, 1);
	b.flag[0] = 1;
	b.sc[0] = 0.2f; b.sc[1] = 0.9f;
	b.ret[1] = BT_RUNNING;
	if (rig_open(&r, "if flag 0\n\tpick noise=0\n\t\toption a sc 0\n\t\t\tdo act 0\n\t\toption b sc 1\n\t\t\tdo act 1\nelse\n\tdo act 2\n", &b)) {
		CHECK(rig_tick(&r, 0.1f) == BT_RUNNING && b.calls[1] == 1);
		CHECK(bt_describe(r.f, r.s, d, sizeof d) && !strcmp(d, "pick:b > act"));
		rig_close(&r);
	}
}

static void test_block_errors(void)
{
	diag_is("select\n\telse\n\t\tdo act 0\n", 2, 2, "no if before it");
	diag_is("else\n\tdo act 0\n", 1, 1, "no if before it");
	diag_is("select\n\tif flag 0\n\telse\n\t\tdo act 1\n", 3, 2, "an if with no children");
	diag_is("select\n\tdo act 0\n\telse\n\t\tdo act 1\n", 3, 2, "right after an if or unless");
	diag_is("if flag 0\n\tdo act 0\nelse\n\tdo act 1\nelse\n\tdo act 2\n", 5, 1, "this is a second");
	diag_is("select\n\tif flag 0\n\t\tdo act 0\n\telse flag 1\n\t\tdo act 1\n", 4, 7, "takes no words");
	diag_is("select\n\tif flag 0\n\t\tdo act 0\n\telse\n", 4, 2, "'else' needs at least one child");
	diag_is("select\n\tif flag 0\n\t\tdo act 0\n\t\telse\n\t\t\tdo act 1\n", 4, 3, "right after an if or unless");
	diag_is("select\n\tif flag 0\n\t\tdo act 0\n\tdo act 2\n\telse\n\t\tdo act 1\n", 5, 2, "right after an if or unless");
	diag_is("pick\n\toption a sc 0\n\t\tdo act 0\n\telse\n\t\tdo act 1\n", 4, 2, "right after an if or unless");
	/* a block may not hold an option; a leaf below a leaf is still refused */
	diag_is("if flag 0\n\toption a sc 0\n\t\tdo act 0\n", 2, 2, "under a pick");
	diag_is("if flag 0\n\tdo act 0\n\t\tdo act 1\n", 3, 3, "takes no children");
	/* every mistake at once, the lines under a dropped else not said */
	{
		bt_diag ds[8];
		int n = bt_diagnose(vocab, "select\n\telse\n\t\tdo act 0\n\tif v 0 < 500\n\t\tdo act 1\n\telse\n\t\tdo act 2\n", 0, ds, 8);
		CHECK(n == 2 && ds[0].line == 2 && ds[1].line == 4 && ds[1].column == 11);
	}
}

/* the text of every form, comments on every line, written canonical
 * and read back the same: source, forest, comments */
static void test_block_text(void)
{
	static const char IN[] =
		"# decisions\n"
		"tree main:\n"
		"select  # the top\n"
		"    if v 0 < 5      # near\n"
		"        do act 0\n"
		"    # otherwise:\n"
		"    else    # far\n"
		"        unless v_below 1 20\n"
		"            do act 1\n"
		"        else\n"
		"            pick roll=each\n"
		"                option a v 2 >= 7.5 x2   # a comparison scored\n"
		"                    do act 2\n"
		"                option b v_high 3 40\n"
		"                    do act 3\n"
		"    do act 4\n";
	static const char WANT[] =
		"# decisions\n"
		"tree main:\n"
		"select                                        # the top\n"
		"\tif v 0 < 5                                # near\n"
		"\t\tdo act 0\n"
		"\t# otherwise:\n"
		"\telse                                      # far\n"
		"\t\tunless v_below 1 20\n"
		"\t\t\tdo act 1\n"
		"\t\telse\n"
		"\t\t\tpick roll=each\n"
		"\t\t\t\toption a v 2 >= 7.5 x2        # a comparison scored\n"
		"\t\t\t\t\tdo act 2\n"
		"\t\t\t\toption b v_high 3 40\n"
		"\t\t\t\t\tdo act 3\n"
		"\tdo act 4\n";
	int c1 = 0, c2 = 0;
	char *one = canonical(vocab, IN, &c1), *two, err[200];
	bt_forest *a, *b;
	bt_source *src;
	bt_node n;
	CHECK(one && !strcmp(one, WANT));
	if (one && strcmp(one, WANT)) printf("--- got\n%s--- wanted\n%s", one, WANT);
	if (!one) return;
	two = canonical(vocab, one, &c2);
	CHECK(two && !strcmp(one, two) && c1 == 6 && c2 == c1);
	a = bt_compile(vocab, IN, err, sizeof err);
	b = bt_compile(vocab, one, err, sizeof err);
	CHECK(a && b && same_forest(a, b));
	/* the else: a child of its if, at its column, its comments its own */
	src = bt_parse(vocab, one, NULL);
	CHECK(src && bt_source_node(src, 3, &n));
	if (src) {
		CHECK(n.kind == BT_K_ELSE && n.parent == 1 && n.column == 2 && n.line == 7 && !strcmp(n.comment, "far") &&
		      !strcmp(n.above, "# otherwise:\n") && n.next_sibling == -1 && n.n_children == 1);
		CHECK(bt_source_node(src, 1, &n) && n.n_children == 2 && n.first_child == 2 && n.op == BT_OP_LT);
		CHECK(bt_source_node(src, 2, &n) && n.next_sibling == 3);
		CHECK(bt_source_node(src, 4, &n) && n.parent == 3 && n.kind == BT_K_UNLESS && n.op == BT_OP_NONE &&
		      !strcmp(n.name, "v_below") && n.args.count == 2);
		CHECK(bt_source_node(src, 8, &n) && n.kind == BT_K_OPTION && n.op == BT_OP_GE && n.number == 7.5f && n.factor == 2.0f &&
		      !strcmp(n.name, "v") && !strcmp(n.trait, "a"));
		CHECK(!strcmp(bt_kind_name(BT_K_ELSE), "else"));
	}
	bt_source_free(src);
	bt_forest_free(a); bt_forest_free(b);
	free(one); free(two);
}

int main(void)
{
	int i;
	vocab = bt_vocab_new();
	bt_vocab_cond(vocab, "flag", c_flag);
	bt_vocab_score(vocab, "sc", s_sc);
	bt_vocab_action(vocab, "act", a_act, a_stop);
	for (i = 0; i < BC_T_COUNT; i++) bt_vocab_trait(vocab, bc_trait_name(i), i);
	bt_vocab_trait(vocab, "a", 1);
	bt_vocab_trait(vocab, "b", 2);
	bt_vocab_value(vocab, "v", v_val, &SPEC_V_RANGE);
	bt_vocab_args(vocab, BT_WORD_VALUE, "v", SPEC_V_IDX, 1);
	bt_vocab_short(vocab, BT_WORD_COND, "v_below", "v $1 < $2");
	bt_vocab_args(vocab, BT_WORD_COND, "v_below", SPEC_V_BELOW, 2);
	bt_vocab_short(vocab, BT_WORD_COND, "v_far", "unless v $1 <= $2");
	bt_vocab_args(vocab, BT_WORD_COND, "v_far", SPEC_V_N, 2);
	bt_vocab_short(vocab, BT_WORD_SCORE, "v_high", "v $1 >= $2");
	bt_vocab_args(vocab, BT_WORD_SCORE, "v_high", SPEC_V_N, 2);

	test_truth_tables();
	test_resume();
	test_stops();
	test_timers();
	test_trees();
	test_malformed();
	test_args();
	test_pick();
	test_population();
	test_example();
	test_source();
	test_text();
	test_forest_walk();
	test_diag();
	test_watch();
	test_shipped();
	test_arg_specs();
	test_diagnose();
	test_roll();
	test_roll_each();
	test_compare();
	test_compare_errors();
	test_compare_score();
	test_block();
	test_block_errors();
	test_block_text();
	bench_plain_pick();
	bt_vocab_free(vocab);
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
