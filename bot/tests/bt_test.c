/* bt_test.c -- the behaviour tree runtime, with small test vocabularies */
#include "bt.h"
#include "persona.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { N = 8 };
typedef struct Bot {
	int flag[N];
	float sc[N];
	bt_status ret[N];
	int calls[N], stops[N];
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
	bt_vocab_free(vocab);
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
