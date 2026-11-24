/* engine_test.c -- the whole engine on the simulated server of
 * brain_sim.h: teams, pings, night, items, characters, replay, cost */
#include <dirent.h>

#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40 };
static const float EYE = (float)G - 2.25f;

/* the lamp, as a server's night script sends it (BRAIN-STATUS.md has
 * this text for the server to use) */
static const char NIGHT_EXTRA[] =
	"extra.night.tree=pick noise=0\n"
	"\toption none night_vision x10\n"
	"\t\tdo lamp off\n"
	"\toption none hit_in_dark x10\n"
	"\t\tdo lamp on\n"
	"\toption none quiet 25 x5\n"
	"\t\tdo lamp on\n"
	"\toption stealth night\n"
	"\t\tdo lamp off\n"
	"\toption none night x1.2\n"
	"\t\tdo lamp on\n";

static uint32_t seed_with(int trait, float lo, float hi, uint32_t from)
{
	uint32_t seed;

	for (seed = from; seed < from + 20000; seed++) {
		bc_persona p;
		bc_rng r;

		bc_rng_seed(&r, seed, 0x70657273);
		bc_persona_roll(&p, &r, NULL, 5);
		if (p.trait[trait] >= lo && p.trait[trait] <= hi)
			return seed;
	}
	return from;
}

/* a field with some walls to fight round, a base at each end */
static bs_sim *arena(int max_bots)
{
	bs_sim *s = bs_new(G, max_bots);
	int i;

	s->have_tents = 1;
	s->tent[0].x = 205.5f; s->tent[0].y = 256.5f; s->tent[0].z = EYE;
	s->tent[1].x = 295.5f; s->tent[1].y = 256.5f; s->tent[1].z = EYE;
	for (i = 0; i < 6; i++) {
		int x = 225 + i * 10, y = 236 + ((i * 17) % 40);

		bs_box(s, x, y, G - 4, x + 1, y + 6, G - 1, 1);
	}
	bs_box(s, 248, 250, G - 1, 252, 262, G - 1, 1);    /* a low step in the middle */
	return s;
}

static void teams(bs_sim *s, int per_team, uint32_t seed)
{
	int i;

	for (i = 0; i < per_team; i++) {
		float y = 256.5f - 2.5f * (float)per_team + 5.0f * (float)i;

		bs_add(s, i, 1, 1, 3 + (i * 3) % 7, i % 3, seed + (uint32_t)i * 7919u, 207.5f + (float)(i % 3) * 2.0f, y, 1, 0);
		bs_add(s, 100 + i, 1, 2, 3 + (i * 5) % 7, (i + 1) % 3, seed + 500u + (uint32_t)i * 104729u,
		       293.5f - (float)(i % 3) * 2.0f, y, -1, 0);
	}
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
}

static int alive_of(const bs_sim *s, int team)
{
	int i, n = 0;

	for (i = 0; i < BL_MAX_PLAYERS; i++)
		n += s->p[i].used && s->p[i].team == team && s->p[i].alive;
	return n;
}

static void stuck_of(const bs_sim *s, int *events, double *worst)
{
	int i;

	*events = 0;
	*worst = 0.0;
	for (i = 0; i < BL_MAX_PLAYERS; i++)
		if (s->p[i].used && s->p[i].bot) {
			*events += s->p[i].stuck_events;
			if (s->p[i].worst_hold > *worst) *worst = s->p[i].worst_hold;
		}
}

/* the leaf a bot is on, from bc_engine_describe */
static void leaf_of(bs_sim *s, int pid, char *out, size_t n)
{
	char d[300], *bar, *gt, *end;

	out[0] = 0;
	if (!bc_engine_describe(s->e, pid, d, sizeof d)) return;
	bar = strchr(d, '|');
	if (!bar) return;
	end = strchr(bar + 1, '|');
	if (end) *end = 0;
	gt = strrchr(bar, '>');
	snprintf(out, n, "%s", gt ? gt + 2 : bar + 2);
	while (strlen(out) && out[strlen(out) - 1] == ' ') out[strlen(out) - 1] = 0;
}

/* ---------------------------------------------------------------------- */

static void test_vocab_and_trees(void)
{
	bs_sim *s = bs_new(G, 4);
	static char dump[16384], text[32768], err[200];
	bt_vocab *v = bt_vocab_new();
	bt_forest *f;
	size_t n = bc_vocab_dump(dump, sizeof dump), len = 0;
	char *line, d[300];
	int words = 0;

	printf("the vocabulary, the trees\n");
	CHECK(n > 2000 && n < sizeof dump);
	CHECK(bc_vocab_register(v));
	CHECK(strstr(dump, "action use <item>") && strstr(dump, "cond has_night_vision") &&
	      strstr(dump, "score hurt_in_fight") && strstr(dump, "cond enemies_grouped <count> <radius>"));
	/* every word of the dump is a word a tree can use, with an argument
	 * of the right kind for each it must be given (the compiler checks) */
	len += (size_t)snprintf(text + len, sizeof text - len, "tree all:\nselect\n\tpick\n");
	for (line = strtok(dump, "\n"); line; line = strtok(NULL, "\n")) {
		char kind[16], name[40];

		if (sscanf(line, "%15s %39s", kind, name) != 2) continue;
		words++;
	}
	{
		bc_word w;
		int i, k, pass;

		for (pass = 0; pass < 2; pass++)
			for (i = 0; bc_vocab_word(i, &w); i++) {
				if ((w.kind == BT_WORD_SCORE) != (pass == 0)) continue;
				len += (size_t)snprintf(text + len, sizeof text - len, "%s%s", w.kind == BT_WORD_SCORE ? "\t\toption none "
				                        : w.kind == BT_WORD_COND ? "\tif " : "\tdo ", w.name);
				for (k = 0; k < w.n_args; k++) {
					const bt_arg_spec *a = &w.args[k];
					char first[32];

					snprintf(first, sizeof first, "%.*s", a->values ? (int)strcspn(a->values, "|") : 0, a->values ? a->values : "");
					len += (size_t)snprintf(text + len, sizeof text - len, " %s",
					                        a->type == BT_ARG_NUMBER ? "1" : a->type == BT_ARG_TEXT ? "x" : a->values ? first : "self");
				}
				len += (size_t)snprintf(text + len, sizeof text - len, "%s", w.kind == BT_WORD_SCORE ? "\n\t\t\tdo roam\n" : "\n");
			}
	}
	CHECK(words == bc_vocab_count() && words > 60);
	f = bt_compile(v, text, err, sizeof err);
	if (!f) printf("  %s\n", err);
	CHECK(f != NULL);
	if (f) bt_forest_free(f);
	/* and an argument of the wrong kind is a mistake, said with the word */
	{
		static const struct { const char *text, *what; } bad[] = {
			{ "do go_to nowhere\n", "no place called nowhere" },
			{ "do go_to\n", "<place> is missing" },
			{ "do go_to own_base near\n", "<radius> is a number" },
			{ "do go_to own_base 2 3\n", "2 arguments at most" },
			{ "do fight him\n", "takes no argument" },
			{ "do lamp bright\n", "not one of on|off|auto" },
			{ "if chance 2\n", "between 0 and 1" },
			{ "if enemy_within -3\n", "0 or more" },
			{ "pick\n\toption none vantage rifle bow\n\t\tdo roam\n", "'bow' is not one of" },
			{ "pick\n\toption none unguarded our_intel 15 2 fallen\n\t\tdo roam\n", "not one of dropped" },
		};
		size_t k;

		for (k = 0; k < sizeof bad / sizeof bad[0]; k++) {
			f = bt_compile(v, bad[k].text, err, sizeof err);
			CHECK(f == NULL && strstr(err, bad[k].what));
			if (f || !strstr(err, bad[k].what)) printf("  {%s}: %s\n", bad[k].text, f ? "compiled" : err);
			if (f) bt_forest_free(f);
		}
		/* the other names a place answers to, a repeated argument, a factor after the arguments */
		f = bt_compile(v, "pick\n\toption none unguarded our_intel 15 2 dropped x3\n\t\tdo guard their_intel\n"
		                  "\toption none vantage rifle smg shotgun\n\t\tdo ping enemy_group Need help\n", err, sizeof err);
		if (!f) printf("  %s\n", err);
		CHECK(f != NULL);
		if (f) bt_forest_free(f);
	}
	bt_vocab_free(v);
	printf("  %d words\n", words);

	/* the built-in trees are loaded (bs_new), each compiles alone, and a
	 * broken text leaves the engine as it was */
	bs_start(s);
	bs_add(s, 0, 1, 1, 5, 0, 11, 220.5f, 256.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_run(s, 1.0);
	bc_engine_describe(s->e, 0, d, sizeof d);
	CHECK(strstr(d, "seek") != NULL);             /* (no bases in this world: seek roams) */
	CHECK(!bc_engine_trees(s->e, "tree tdm:\ndo no_such_thing\n", err, sizeof err));
	CHECK(strstr(err, "line 2") != NULL);
	bs_run(s, 1.0);
	bc_engine_describe(s->e, 0, d, sizeof d);
	CHECK(strstr(d, "seek") != NULL);           /* the old tree still runs */
	{
		const char *dirs[2] = { "trees", "../trees" };
		char path[256];
		int k, ok = 0;

		for (k = 0; k < 2 && !ok; k++) {
			char *a, *b;

			snprintf(path, sizeof path, "%s/default.bt", dirs[k]);
			a = bs_slurp(path);
			snprintf(path, sizeof path, "%s/tdm.bt", dirs[k]);
			b = bs_slurp(path);
			if (a && b) {
				bs_sim *t = bs_new(G, 1);

				ok = 1;
				CHECK(bc_engine_trees(t->e, a, err, sizeof err));       /* as botd tries them: alone */
				CHECK(bc_engine_trees(t->e, b, err, sizeof err));
				bs_free(t);
			}
			free(a); free(b);
		}
		CHECK(ok);
	}
	/* a good text replaces all of them: the bot re-enters cleanly */
	CHECK(bc_engine_trees(s->e, "tree tdm:\ndo hold self 99\n", err, sizeof err));
	bs_run(s, 1.0);
	bc_engine_describe(s->e, 0, d, sizeof d);
	CHECK(strstr(d, "hold") != NULL && !strstr(d, "seek"));
	/* a tree nobody has falls back on "default": here none, so the engine's own */
	bs_set(s, BL_NO_PLAYER, "tree=nonesuch");
	bs_run(s, 1.5);
	bc_engine_describe(s->e, 0, d, sizeof d);
	CHECK(strstr(d, "roam") != NULL);
	CHECK(strncmp(d, bc_archetype_name(bc_engine_bot(s->e, 0)->persona.archetype),
	              strlen(bc_archetype_name(bc_engine_bot(s->e, 0)->persona.archetype))) == 0);
	CHECK(strstr(d, " L5 | ") && strstr(d, "| route ") && strstr(d, "| sees 0"));
	CHECK(bc_engine_describe(s->e, 9, d, sizeof d) == 0);
	CHECK(bc_engine_bots(s->e) == 1);
	bs_free(s);
}

static void test_team_fight(int per_team, int night, const char *name)
{
	bs_sim *s = arena(per_team * 2);
	const bc_engine_stats *st;
	double t, worst;
	int stuck, shots = 0, i;

	printf("%s\n", name);
	bs_start(s);
	s->night = night;
	if (night) {
		bs_set(s, BL_NO_PLAYER, "night.sight=1");
		bs_set(s, BL_NO_PLAYER, NIGHT_EXTRA);
	}
	teams(s, per_team, 2026);
	for (t = 0; t < 240.0 && alive_of(s, 1) > 0 && alive_of(s, 2) > 0; t += 1.0)
		bs_run(s, 1.0);
	stuck_of(s, &stuck, &worst);
	st = bc_engine_stats_get(s->e);
	for (i = 0; i < BL_MAX_PLAYERS; i++)
		shots += s->p[i].shots;
	printf("  after %.0f s: team 1 has %d of %d left, team 2 %d; kills %d-%d; %d rounds, %d grenades, %d pings\n",
	       t, alive_of(s, 1), per_team, alive_of(s, 2), s->kills[1], s->kills[2], shots, s->nades_thrown, s->pings);
	printf("  stuck (one cell, keys down, over 3 s): %d; longest hold %.2f s; the engine's own watchdog acted %u times\n",
	       stuck, worst, (unsigned)st->stuck);
	printf("  %u plans (%u failed, %u again), %u expansions; think %.1f us a call, worst %.0f us\n",
	       (unsigned)st->plans, (unsigned)st->plan_fails, (unsigned)st->replans, (unsigned)st->expansions,
	       s->think_us / (double)s->thinks, s->think_max_us);
	if (alive_of(s, 1) && alive_of(s, 2))
		for (i = 0; i < BL_MAX_PLAYERS; i++)
			if (s->p[i].used && s->p[i].alive) {
				char d[300];

				bc_engine_describe(s->e, i, d, sizeof d);
				printf("    #%d team %d at %.0f %.0f hp %d: %s\n", i, s->p[i].team, (double)s->p[i].body.pos.x,
				       (double)s->p[i].body.pos.y, s->p[i].hp, d);
			}
	CHECK(alive_of(s, 1) == 0 || alive_of(s, 2) == 0);         /* fought to a result */
	CHECK(s->kills[1] + s->kills[2] >= per_team);
	CHECK(stuck == 0);
	CHECK(worst < 3.0);
	bs_free(s);
}

static void test_dead_think_nothing(void)
{
	bs_sim *s = arena(4);
	bc_bot *b;
	int i;

	printf("dead bots think nothing; a new life starts clean\n");
	bs_start(s);
	bs_add(s, 0, 1, 1, 5, 0, 5, 220.5f, 264.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, 0, 1, 250.5f, 264.5f, -1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_run(s, 3.0);
	b = bc_engine_bot(s->e, 0);
	CHECK(b && b->alive && b->senses.n_visible == 1 && b->fight.target == 1);
	bs_hurt(s, 0, 200, 1, s->w.players[1].pos, 0);
	bs_run(s, 0.2);
	CHECK(!b->alive);
	for (i = 0; i < 60; i++) {
		bs_step(s);
		CHECK(s->intents[0].keys == 0 && s->intents[0].mouse == 0 && (s->intents[0].flags & BL_I_VALID));
	}
	CHECK(b->fight.target == -1 && !b->mv.has_route);
	s->p[1].alive = 0;
	bs_spawn(s, 0);
	bs_run(s, 0.2);
	CHECK(b->alive && b->life == s->p[0].life && b->senses.n_visible == 0);
	CHECK(s->intents[0].life == s->p[0].life);
	bs_run(s, 2.0);
	CHECK(s->intents[0].keys != 0);             /* and off it goes again */
	/* a bot the server takes back */
	bs_push(s, BL_EV_UNBOT, 0, NULL, 0);
	bs_run(s, 0.1);
	CHECK(bc_engine_bots(s->e) == 0 && bc_engine_bot(s->e, 0) == NULL);
	bs_free(s);
}

static void test_ping_answered(void)
{
	bs_sim *s = arena(8);
	int i, takers = 0, loner_took = 0, far_took = 0, near_keen = 0;
	uint32_t keen = 1, loner;
	float d0[8], d1[8];

	printf("a ping is answered by the nearest teamwork-minded bots, and not all\n");
	bs_start(s);
	/* six of a team in a row away from the ping; #2 does not care for the team */
	for (i = 0; i < 6; i++) {
		keen = seed_with(BC_T_TEAMWORK, 1.0f, 1.15f, keen + 1);
		loner = seed_with(BC_T_TEAMWORK, 0.2f, 0.6f, 50000);
		bs_add(s, i, 1, 1, 5, 0, i == 1 ? loner : keen, 210.5f + 10.0f * (float)i, 250.5f, 1, 0);
	}
	bs_add(s, 9, 0, 1, 5, 0, 1, 205.5f, 262.5f, 1, 0);          /* the caller: a player */
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");        /* nobody goes along with anybody: only the ping moves them */
	bs_run(s, 0.5);
	for (i = 0; i < 6; i++) {
		float dx = s->p[i].body.pos.x - 205.5f, dy = s->p[i].body.pos.y - 265.5f;

		d0[i] = sqrtf(dx * dx + dy * dy);
	}
	bs_ping(s, 9, 205.5f, 265.5f, EYE, "Go here");
	bs_run(s, 0.1);
	for (i = 0; i < 6; i++) {
		bc_bot *b = bc_engine_bot(s->e, i);

		if (b->ping.taken) {
			takers++;
			if (i == 1) loner_took = 1;
			if (i >= 4) far_took = 1;
			if (i == 0 || i == 2) near_keen++;
		}
	}
	for (i = 0; i < 6; i++)
		d1[i] = d0[i];
	{
		int k;

		for (k = 0; k < 60 * 8; k++) {
			bs_step(s);
			for (i = 0; i < 6; i++) {
				float dx = s->p[i].body.pos.x - 205.5f, dy = s->p[i].body.pos.y - 265.5f;
				float d = sqrtf(dx * dx + dy * dy);

				if (d < d1[i]) d1[i] = d;
			}
		}
	}
	printf("  %d of 6 took it; the two nearest keen ones went from %.0f and %.0f voxels to within %.0f and %.0f\n", takers,
	       (double)d0[0], (double)d0[2], (double)d1[0], (double)d1[2]);
	CHECK(takers == 2);
	CHECK(!loner_took && !far_took && near_keen == 2);
	CHECK(d1[0] < 6.0f && d1[2] < 6.0f);
	CHECK(d1[5] > 20.0f && d1[4] > 20.0f);       /* the others went about their business */
	/* a ping that says nothing ("Thanks") is nobody's */
	bs_ping(s, 9, 300.5f, 285.5f, EYE, "Thanks");
	bs_run(s, 0.1);
	CHECK(bc_engine_bot(s->e, 4)->ping.taken == 0);
	/* three answer when the setting says three */
	bs_set(s, BL_NO_PLAYER, "ping_takers=3");
	bs_set(s, BL_NO_PLAYER, "ping_radius=400");
	bs_run(s, 1.0);
	bs_ping(s, 9, 230.5f, 250.5f, EYE, "Enemy");
	bs_run(s, 0.1);
	for (takers = 0, i = 0; i < 6; i++)
		takers += bc_engine_bot(s->e, i)->ping.taken != 0 && bc_engine_bot(s->e, i)->ping.kind == BC_PING_ENEMY;
	CHECK(takers == 3);
	bs_free(s);
}

static void test_cautious_retreat(void)
{
	bs_sim *s = arena(4);
	int kind, n[2] = { 0, 0 }, of[2] = { 0, 0 };
	uint32_t seed[2] = { 1, 1 };

	printf("hurt bots break off (to cover, or back by cover) more often when cautious\n");
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	for (kind = 0; kind < 2; kind++) {
		int k;

		for (k = 0; k < 60; k++) {
			char leaf[64];
			int i, did = 0;

			seed[kind] = seed_with(BC_T_CAUTION, kind ? 1.5f : 0.2f, kind ? 3.0f : 0.7f, seed[kind] + 1);
			bs_add(s, 0, 1, 1, 5, 0, seed[kind], 220.5f, 256.5f, 1, 0);
			bs_add(s, 1, 0, 2, 5, 0, 1, 246.5f, 256.5f, -1, 0);
			bs_run(s, 0.3);
			bs_hurt(s, 0, 55, 1, s->w.players[1].pos, 0);       /* 45 left, and he is right there */
			for (i = 0; i < 150; i++) {
				bs_step(s);
				s->p[1].hp = 100;
				leaf_of(s, 0, leaf, sizeof leaf);
				if (!strcmp(leaf, "take_cover") || !strcmp(leaf, "fall_back_by_cover")) did = 1;
			}
			n[kind] += did;
			of[kind]++;
		}
	}
	printf("  hit down to 45 with the man in sight: %d of %d careless bots break off, %d of %d careful ones\n",
	       n[0], of[0], n[1], of[1]);
	CHECK(n[1] > n[0] + 15);
	CHECK(n[1] > 40);
	bs_free(s);
}

static const char DARK_TREE[] =
	"tree=tree dark:\n"
	"pick every=0.5\n"
	"\toption none enemy_visible x30\n"
	"\t\tdo fight\n"
	"\toption none has_order\n"
	"\t\tdo obey\n"
	"\toption none always x0.01\n"
	"\t\tdo hold self 1\n"
	"tree dark_also:\n"
	"do lamp %s\n";

static void night_pass(const char *lamp, int nv, int *shots, int *seen, float *closest)
{
	bs_sim *s = bs_new(G, 4);
	char text[400];
	int i;

	bs_start(s);
	s->night = 1;
	bs_add(s, 0, 1, 1, 6, 0, 3, 215.5f, 256.5f, 1, 0);
	bs_add(s, 1, 1, 2, 6, 0, 4, 285.5f, 262.5f, -1, 0);
	snprintf(text, sizeof text, DARK_TREE, lamp);
	bs_set(s, BL_NO_PLAYER, text);
	bs_set(s, BL_NO_PLAYER, "night.sight=1");
	if (nv) bs_set(s, 0, "night_vision=1");
	bs_order(s, 0, BL_O_GOTO, 285.5f, 256.5f, EYE, BL_NO_PLAYER, 0.0f);
	bs_order(s, 1, BL_O_GOTO, 215.5f, 262.5f, EYE, BL_NO_PLAYER, 0.0f);
	*seen = 0;
	*closest = 1e9f;
	for (i = 0; i < 60 * 14; i++) {
		bs_step(s);
		*seen += bc_engine_bot(s->e, 0)->senses.n_visible + bc_engine_bot(s->e, 1)->senses.n_visible;
		if (bs_dist(s, 0, 1) < *closest) *closest = bs_dist(s, 0, 1);
	}
	*shots = s->p[0].shots + s->p[1].shots;
	bs_free(s);
}

static void test_night(void)
{
	bs_sim *s;
	bc_bot *b;
	float closest;
	int shots, seen, i;

	printf("night\n");
	night_pass("off", 0, &shots, &seen, &closest);
	printf("  lamps out: they pass %.1f apart; sightings %d, rounds %d\n", (double)closest, seen, shots);
	CHECK(closest < 8.0f && seen == 0 && shots == 0);
	night_pass("on", 0, &shots, &seen, &closest);
	printf("  lamps lit: sightings %d, rounds %d\n", seen, shots);
	CHECK(seen > 0 && shots > 0);
	night_pass("off", 1, &shots, &seen, &closest);
	printf("  lamps out, one with night vision: sightings %d, rounds %d\n", seen, shots);
	CHECK(seen > 0 && shots > 0);

	/* the tree's lamp, by character: on for most, out for the stealthy and
	 * for one who sees anyway; lit when shot at in the dark */
	s = arena(4);
	bs_start(s);
	s->night = 1;
	bs_add(s, 0, 1, 1, 5, 0, seed_with(BC_T_STEALTH, 0.2f, 0.8f, 1), 215.5f, 250.5f, 1, 0);
	bs_add(s, 1, 1, 1, 5, 0, seed_with(BC_T_STEALTH, 1.6f, 3.0f, 1), 215.5f, 256.5f, 1, 0);
	bs_add(s, 2, 1, 1, 5, 0, seed_with(BC_T_STEALTH, 0.2f, 0.8f, 7000), 215.5f, 262.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_set(s, 2, "night_vision=1");
	bs_set(s, BL_NO_PLAYER, "night.sight=1");
	bs_run(s, 2.0);
	CHECK(s->p[0].lamp == 0 && s->p[1].lamp == 0 && s->p[2].lamp == 0);    /* no night script: no lamps */
	bs_set(s, BL_NO_PLAYER, "extra.broken.tree=do light_the_candles");
	bs_set(s, BL_NO_PLAYER, NIGHT_EXTRA);
	bs_run(s, 2.0);
	CHECK(s->log2_n == 1 && strstr(s->log2, "extra broken") && strstr(s->log2, "line 1"));
	printf("  lamps by character: plain %d, stealthy %d, night vision %d\n", s->p[0].lamp, s->p[1].lamp, s->p[2].lamp);
	CHECK(s->p[0].lamp == 1 && s->p[1].lamp == 0 && s->p[2].lamp == 0);
	/* row 3, with the whole engine: a man in the open right in front of
	 * the dark bot is never a target; a shot heard turns it */
	bs_add(s, 100, 0, 2, 5, 0, 1, 240.5f, 256.5f, -1, 0);
	b = bc_engine_bot(s->e, 1);
	for (seen = 0, i = 0; i < 60 * 4; i++) {
		bs_step(s);
		s->p[100].body.pos.x = s->p[1].body.pos.x + 6.0f;      /* keeps right in front of it */
		s->p[100].body.pos.y = s->p[1].body.pos.y;
		seen += b->senses.n_visible + (b->fight.target >= 0) + s->p[1].shots;
	}
	CHECK(seen == 0);
	bs_hurt(s, 1, 30, 100, s->w.players[100].pos, 0);          /* he shoots it */
	bs_run(s, 2.5);
	printf("  the stealthy one, shot in the dark: lamp %d, sees %d, has fired %d\n", s->p[1].lamp,
	       b->senses.n_visible, s->p[1].shots);
	CHECK(s->p[1].lamp == 1);
	bs_run(s, 6.0);
	CHECK(s->p[1].shots > 0 || !s->p[100].alive || !s->p[1].alive);
	bs_free(s);

	/* the night script's part withdrawn: no more lamp decisions, lamps out;
	 * and with it there, by day, nobody lights one */
	s = arena(2);
	bs_start(s);
	s->night = 1;
	bs_add(s, 0, 1, 1, 5, 0, seed_with(BC_T_STEALTH, 0.2f, 0.8f, 1), 215.5f, 250.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_set(s, BL_NO_PLAYER, NIGHT_EXTRA);
	bs_run(s, 2.0);
	CHECK(s->p[0].lamp == 1);
	s->night = 0;
	bs_run(s, 1.0);
	CHECK(s->p[0].lamp == 0);
	s->night = 1;
	bs_run(s, 1.0);
	CHECK(s->p[0].lamp == 1);
	bs_set(s, BL_NO_PLAYER, "extra.night.tree=");
	bs_run(s, 3.0);
	CHECK(s->p[0].lamp == 0);
	bs_free(s);
}

static void test_night_is_day_by_default(void)
{
	bs_sim *a = arena(8), *b = arena(8);
	int i, k, diff = 0, lamps = 0;

	printf("with no night settings a night world is played exactly as day\n");
	bs_start(a);
	bs_start(b);
	b->night = 1;
	teams(a, 4, 555);
	teams(b, 4, 555);
	for (i = 0; i < 60 * 20; i++) {
		bs_step(a);
		bs_step(b);
		for (k = 0; k < BL_MAX_PLAYERS; k++)
			if (a->p[k].used && a->p[k].bot) {
				diff += memcmp(&a->intents[k], &b->intents[k], sizeof(bl_intent)) != 0;
				lamps += b->p[k].lamp;
			}
	}
	printf("  20 s, 8 bots, %d kills by day and %d by night: %d intents differ, %d lamp-ticks\n",
	       a->kills[1] + a->kills[2], b->kills[1] + b->kills[2], diff, lamps);
	CHECK(diff == 0 && lamps == 0);
	CHECK(a->kills[1] + a->kills[2] > 0);
	bs_free(a);
	bs_free(b);
}

static void test_persona_spread(void)
{
	bs_sim *s = arena(4);
	struct { char name[32]; int n; } opt[16];
	int nopt = 0, i, k, big = 0, shown = 0;
	char line[400] = "";

	printf("500 characters on the tdm tree, one situation\n");
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_add(s, 9, 0, 1, 5, 0, 1, 180.5f, 300.5f, 1, 0);         /* a team-mate, far, who calls */
	memset(opt, 0, sizeof opt);
	for (k = 0; k < 500; k++) {
		char leaf[64];

		/* hurt, a man in sight 45 away with a friend beside him, a
		 * team-mate calling, the others far */
		bs_add(s, 0, 1, 1, 5, k % 3, 9000u + (uint32_t)k, 220.5f, 264.5f, 1, 0);
		bs_add(s, 1, 0, 2, 5, 0, 1, 248.5f, 264.5f, -1, 0);
		bs_add(s, 2, 0, 2, 5, 0, 1, 249.5f, 267.5f, -1, 0);
		bs_run(s, 0.1);
		bs_hurt(s, 0, 50, 1, s->w.players[1].pos, 0);
		bs_ping(s, 9, 210.5f, 280.5f, EYE, "Need help");
		for (i = 0; i < 60; i++) {
			bs_step(s);
			s->p[1].hp = s->p[2].hp = 100;
		}
		leaf_of(s, 0, leaf, sizeof leaf);
		for (i = 0; i < nopt && strcmp(opt[i].name, leaf); i++)
			;
		if (i == nopt && nopt < 16) snprintf(opt[nopt++].name, sizeof opt[0].name, "%s", leaf);
		if (i < 16) opt[i].n++;
	}
	for (i = 0; i < nopt; i++) {
		snprintf(line + strlen(line), sizeof line - strlen(line), "%s %d  ", opt[i].name, opt[i].n);
		if (opt[i].n >= 25) shown++;
		if (opt[i].n > big) big = opt[i].n;
	}
	printf("  %s\n", line);
	CHECK(shown >= 3);                          /* at least three things each done by 5% or more */
	CHECK(big < 400);                           /* and nothing done by four in five */
	bs_free(s);
}

static void test_replay(void)
{
	bs_sim *s = arena(8), *r;
	int i, k, diff = 0, first = -1;
	size_t at = 0;

	printf("a seed and a recorded world replay the same intents\n");
	bs_start(s);
	bs_rec_start(s, 60 * 25, 8);
	teams(s, 4, 77);
	bs_run(s, 25.0);
	r = arena(8);
	bs_start(r);
	for (i = 0; i < s->rec_n; i++) {
		int n = 0;

		while (at < s->rec_ev_end[i]) {
			const bl_record *rec = (const bl_record *)(const void *)(s->rec_ev + at);

			bc_engine_event(r->e, rec);
			at += (rec->size + 3u) & ~3u;
		}
		bc_engine_think(r->e, &s->rec_w[i], r->intents, 1.0f / 60.0f, s->budget);
		for (k = 0; k < BL_MAX_PLAYERS && n < 8; k++)
			if (s->p[k].used && s->p[k].bot) {
				if (memcmp(&r->intents[k], &s->rec_out[(size_t)i * 8 + (size_t)n], sizeof(bl_intent))) {
					diff++;
					if (first < 0) first = i;
				}
				n++;
			}
	}
	printf("  %d thinks, 8 bots, %d kills in the recording: %d intents differ%s\n", s->rec_n,
	       s->kills[1] + s->kills[2], diff, diff ? "" : " (none)");
	if (diff) printf("  first difference at think %d\n", first);
	CHECK(s->rec_n == 60 * 25);
	CHECK(diff == 0);
	CHECK(bc_engine_stats_get(r->e)->decisions == bc_engine_stats_get(s->e)->decisions);
	bs_free(r);
	bs_free(s);
}

/* --- items --------------------------------------------------------------- */

static int heal_on_medkit;

static void on_command(bs_sim *s, int pid, const char *text)
{
	if (!strncmp(text, "inv medkit", 10) && heal_on_medkit) {
		s->p[pid].hp = 100;
		bs_set(s, pid, "item.medkit=0");        /* the server says what is left */
	}
}

static void test_items(void)
{
	bs_sim *s = arena(4);
	bc_bot *b;
	float x = 0.0f, y = 0.0f, z = 0.0f;
	int i, on = 0, of = 0, moved;
	uint32_t greedy, frugal;

	printf("items: each brings its own decision\n");
	bs_start(s);
	s->on_command = on_command;
	heal_on_medkit = 1;
	bs_add(s, 0, 1, 1, 5, 0, 21, 215.5f, 250.5f, 1, 0);
	bs_add(s, 1, 1, 1, 5, 0, 22, 215.5f, 262.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	/* the medkit's own rule, as its author wrote it (two spaces a step) */
	bs_set(s, BL_NO_PLAYER, "item.medkit.tree=seq\n  if health_below 40\n  do use medkit");
	/* one that does not compile: said, left out, the rest stands */
	bs_set(s, BL_NO_PLAYER, "item.broken.tree=seq\n  if health_below 40\n  do use_the_force broken");
	bs_set(s, 0, "item.medkit=1");
	bs_set(s, 1, "item.medkit=1");
	bs_set(s, 0, "item.broken=1");
	bs_run(s, 3.0);
	CHECK(s->log2_n == 1 && strstr(s->log2, "item broken") && strstr(s->log2, "line 3"));
	CHECK(s->p[0].cmds == 0 && s->p[1].cmds == 0);             /* both healthy: nobody uses one */
	s->p[0].hp = 30;
	bs_run(s, 3.0);
	printf("  hurt bot: \"%s\" (%d); healthy bot: %d uses; the engine said: %s\n", s->p[0].last_cmd, s->p[0].cmds,
	       s->p[1].cmds, s->log2);
	CHECK(s->p[0].cmds == 1 && !strcmp(s->p[0].last_cmd, "inv medkit"));
	CHECK(s->p[1].cmds == 0);
	b = bc_engine_bot(s->e, 0);
	CHECK(bc_item_count(b, "medkit") == 0 && bc_item_count(bc_engine_bot(s->e, 1), "medkit") == 1);
	/* hurt again with none left: it never tries */
	s->p[0].hp = 20;
	bs_run(s, 8.0);
	CHECK(s->p[0].cmds == 1);
	/* "inf": it keeps using (the server here does not heal it) */
	heal_on_medkit = 0;
	bs_set(s, 0, "item.medkit=inf");
	bs_run(s, 20.0);
	printf("  with \"inf\" and no healing: %d uses in 20 s\n", s->p[0].cmds - 1);
	CHECK(s->p[0].cmds >= 3 && s->p[0].cmds <= 12);            /* again and again, but not every tick */
	/* its tree withdrawn: the behaviour goes */
	bs_set(s, BL_NO_PLAYER, "item.medkit.tree=");
	bs_run(s, 1.0);
	i = s->p[0].cmds;
	bs_run(s, 15.0);
	CHECK(s->p[0].cmds == i);
	CHECK(s->p[0].stuck_events == 0);
	bs_free(s);

	/* a fragment whose words exist but whose ARGUMENT does not: refused
	 * the same way, with its line and what is wrong; and a tree sent for
	 * everybody with one is refused whole, the old one staying */
	s = arena(4);
	bs_start(s);
	bs_add(s, 0, 1, 1, 5, 0, 21, 215.5f, 250.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_set(s, BL_NO_PLAYER, "item.flare.tree=seq\n  if enemy_visible\n  do use flare nowhere");
	bs_set(s, 0, "item.flare=1");
	bs_run(s, 1.0);
	printf("  a bad argument in an item's tree: %s\n", s->log2);
	CHECK(s->log2_n == 1 && strstr(s->log2, "item flare") && strstr(s->log2, "line 3") && strstr(s->log2, "no place called nowhere"));
	bs_set(s, BL_NO_PLAYER, "tree=tree mine:\nselect\n\tdo hold self soon\n");
	bs_run(s, 1.0);
	printf("  and in a tree sent whole: %s\n", s->log2);
	CHECK(s->log2_n == 2 && strstr(s->log2, "line 3") && strstr(s->log2, "<secs> is a number"));
	bs_free(s);

	/* greed: the same thing held, used at different rates */
	s = arena(4);
	bs_start(s);
	greedy = seed_with(BC_T_GREED, 2.0f, 3.0f, 1);
	frugal = seed_with(BC_T_GREED, 0.2f, 0.45f, 1);
	bs_add(s, 0, 1, 1, 5, 0, greedy, 215.5f, 250.5f, 1, 0);
	bs_add(s, 1, 1, 1, 5, 0, frugal, 215.5f, 262.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_set(s, BL_NO_PLAYER, "item.medkit.tree=seq\n\tif health_below 40\n\tdo use medkit");
	bs_set(s, BL_NO_PLAYER, "item.medkit=inf");                /* for everybody */
	bs_run(s, 0.5);
	for (i = 0; i < 60 * 40; i++) {
		s->p[0].hp = s->p[1].hp = 30;
		bs_step(s);
	}
	printf("  40 s hurt with medkits without end: the greedy bot used %d, the frugal one %d\n", s->p[0].cmds, s->p[1].cmds);
	CHECK(s->p[0].cmds > s->p[1].cmds * 2 && s->p[1].cmds >= 1);
	bs_free(s);

	/* a missile: a man in sight and open sky; the aim stays on him */
	s = bs_new(G, 4);
	bs_start(s);
	bs_add(s, 0, 1, 1, 7, 0, 33, 215.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, 0, 1, 262.5f, 256.5f, -1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_set(s, BL_NO_PLAYER, "item.missile.tree=if enemy_visible\nif sky_clear\ndo use missile enemy");
	bs_set(s, BL_NO_PLAYER, "item.missile.guide=4");
	bs_set(s, 0, "item.missile=1");
	s->p[1].script_keys = BL_K_LEFT;            /* he walks across */
	for (i = 0; i < 60 * 3 && s->p[0].cmds == 0; i++) {
		bs_step(s);
		s->p[1].hp = 100;
	}
	CHECK(s->p[0].cmds == 1 && sscanf(s->p[0].last_cmd, "inv missile %f %f %f", &x, &y, &z) == 3);
	CHECK(fabsf(x - s->p[1].body.pos.x) < 4.0f && fabsf(y - s->p[1].body.pos.y) < 4.0f);
	x = s->p[0].body.pos.x; y = s->p[0].body.pos.y;
	b = bc_engine_bot(s->e, 0);
	for (i = 0; i < 60 * 4; i++) {
		float dx, dy, dz, l, dot;

		bs_step(s);
		s->p[1].hp = 100;
		if (i == 150) s->p[1].script_keys = BL_K_RIGHT;        /* and turns back */
		if (i < 45) continue;                   /* the time to bring the head round */
		dx = s->p[1].body.pos.x - s->p[0].body.pos.x; dy = s->p[1].body.pos.y - s->p[0].body.pos.y;
		dz = s->p[1].body.pos.z - s->p[0].body.pos.z;
		l = sqrtf(dx * dx + dy * dy + dz * dz);
		dot = (dx * s->p[0].ori.x + dy * s->p[0].ori.y + dz * s->p[0].ori.z) / l;
		of++;
		if (dot > cosf(12.0f * 3.14159265f / 180.0f)) on++;
	}
	moved = fabsf(s->p[0].body.pos.x - x) + fabsf(s->p[0].body.pos.y - y) > 3.0f;
	printf("  missile: \"%s\"; for the 4 s after, the head within 12 degrees of him on %d of %d ticks; it %s meanwhile\n",
	       s->p[0].last_cmd, on, of, moved ? "kept moving" : "stood");
	CHECK(on * 10 >= of * 8);
	CHECK(moved);
	CHECK(s->p[0].cmds == 1);                   /* it had one */
	bs_free(s);

	/* the same under a roof: it keeps its missile */
	s = bs_new(G, 4);
	bs_add(s, 0, 1, 1, 7, 0, 33, 215.5f, 256.5f, 1, 0);        /* put down first: under it, not on it */
	bs_add(s, 1, 0, 2, 5, 0, 1, 262.5f, 256.5f, -1, 0);
	bs_box(s, 180, 230, G - 7, 300, 282, G - 7, 1);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_set(s, BL_NO_PLAYER, "item.missile.tree=if enemy_visible\nif sky_clear\ndo use missile enemy");
	bs_set(s, 0, "item.missile=1");
	for (i = 0; i < 60 * 5; i++) {
		bs_step(s);
		s->p[1].hp = 100;
	}
	if (s->p[0].cmds) printf("  under the roof: %s at %.1f %.1f %.1f\n", s->p[0].last_cmd, (double)s->p[0].body.pos.x, (double)s->p[0].body.pos.y, (double)s->p[0].body.pos.z);
	CHECK(bc_engine_bot(s->e, 0)->senses.n_visible == 1);
	CHECK(s->p[0].cmds == 0);
	bs_free(s);
}

static void test_settings(void)
{
	bs_sim *s = arena(4);
	bc_bot *b;
	bc_persona before;
	int i, campers = 0;

	printf("settings\n");
	bs_start(s);
	for (i = 0; i < 4; i++)
		bs_add(s, i, 1, 1, 5, 0, 300u + (uint32_t)i, 215.5f, 246.5f + 5.0f * (float)i, 1, 0);
	bs_run(s, 0.2);
	b = bc_engine_bot(s->e, 0);
	before = b->persona;
	/* the mix arrives after the bots (as lib_botlink sends it): characters are drawn again */
	bs_set(s, BL_NO_PLAYER, "archetypes=camper:1");
	bs_set(s, BL_NO_PLAYER, "cull=voxlap");
	bs_set(s, BL_NO_PLAYER, "zone=10 10 20 20 nodig");
	bs_set(s, BL_NO_PLAYER, "protect=5 6 7");
	bs_set(s, BL_NO_PLAYER, "night.cone=75");
	bs_set(s, BL_NO_PLAYER, "intel=fetch");
	bs_set(s, 1, "edit=all");
	bs_run(s, 0.2);
	for (i = 0; i < 4; i++)
		campers += bc_engine_bot(s->e, i)->persona.archetype == BC_A_CAMPER;
	CHECK(campers == 4);
	(void)before;
	CHECK(s->e->map->cull_personality == BC_CULL_VOXLAP);
	CHECK(s->e->nzones == 1 && s->e->zones[0].no_dig == 1 && s->e->zones[0].no_build == 0 && s->e->zones[0].x1 == 20);
	CHECK(bc_nav_protect_has(&s->e->protect, 5, 6, 7));
	CHECK(s->e->sense.lamp_cone_deg == 75.0f);
	CHECK(!strcmp(bc_engine_setting(s->e, "intel"), "fetch") && bc_engine_setting(s->e, "nope") == NULL);
	CHECK(bc_engine_bot(s->e, 1)->edit == 3 && bc_engine_bot(s->e, 0)->edit == -1);
	/* the same seed is the same bot: told again, nothing changes */
	{
		bl_ev_bot e;
		uint32_t life = b->life;

		memset(&e, 0, sizeof e);
		e.level = 5; e.gun = 0; e.seed = 300;
		bs_push(s, BL_EV_BOT, 0, &e, sizeof e);
		bs_run(s, 0.2);
		CHECK(bc_engine_bot(s->e, 0) == b && b->alive && b->life == life);
	}
	/* a world for another map: the bots stand until theirs comes */
	s->w.map_seq = 2;
	bc_engine_think(s->e, &s->w, s->intents, 0.016f, 1000);
	s->w.tick++;
	bc_engine_think(s->e, &s->w, s->intents, 0.016f, 1000);
	CHECK(s->intents[0].keys == 0 && !b->alive);
	bs_free(s);
}

/* --- a bot with a tree of its own (a gamemode's NPC), changed in play --- */

static int stops_seen;

static void test_own_tree(void)
{
	bs_sim *s = arena(4);
	bc_bot *a, *b;
	char d[300];
	int log2_before, i;

	printf("a tree for one bot, replaced in play\n");
	bs_start(s);
	bs_add(s, 0, 1, 1, 5, 0, 31, 215.5f, 250.5f, 1, 0);
	bs_add(s, 1, 1, 1, 5, 0, 32, 215.5f, 262.5f, 1, 0);
	bs_add(s, 2, 1, 1, 5, 0, 33, 215.5f, 256.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");                        /* the world's */
	bs_set(s, BL_NO_PLAYER, "item.medkit.tree=seq\n\tif health_below 40\n\tdo use medkit");
	bs_set(s, 0, "tree=default");                               /* #0: a built-in name */
	bs_set(s, 1, "tree=tree guard_post:\ndo hold self 99\ntree guard_post_also:\nseq\n\talways\n\t\ttree items\n");  /* #1: its own text */
	bs_run(s, 1.0);
	a = bc_engine_bot(s->e, 0);
	b = bc_engine_bot(s->e, 1);
	CHECK(a && b && b->own != NULL && a->own == NULL);
	CHECK(a->forest != b->forest && b->forest == b->own);
	bc_engine_describe(s->e, 1, d, sizeof d);
	CHECK(strstr(d, "hold") != NULL);
	bc_engine_describe(s->e, 2, d, sizeof d);
	CHECK(strstr(d, "pick:") != NULL && !strstr(d, "hold"));    /* the third runs the world's tree */
	CHECK(!strcmp(a->tree_name, "default") && !strcmp(b->tree_name, "guard_post"));
	/* its own "_also" and the items tree work for it */
	s->on_command = on_command;
	heal_on_medkit = 1;
	bs_set(s, 1, "item.medkit=1");
	bs_run(s, 0.5);
	s->p[1].hp = 30;
	bs_run(s, 2.0);
	CHECK(s->p[1].cmds == 1 && !strcmp(s->p[1].last_cmd, "inv medkit"));
	/* replaced while `hold` is RUNNING: text -> a name. The action is told
	 * to stop, once: counted over the two thinks the change takes, with
	 * the other two bots on trees whose only RUNNING action is not left */
	{
		uint32_t before;

		bs_set(s, 0, "tree=tree w0:\ndo hold self 99\n");
		bs_set(s, 2, "tree=tree w2:\ndo hold self 99\n");
		bs_run(s, 0.5);
		before = bc_engine_stats_get(s->e)->action_stops;
		bs_set(s, 1, "tree=tdm");
		bs_step(s);
		bs_step(s);
		printf("  its tree replaced with `hold` RUNNING: the action was told to stop %u time(s)\n",
		       (unsigned)(bc_engine_stats_get(s->e)->action_stops - before));
		CHECK(bc_engine_stats_get(s->e)->action_stops - before == 1);
		bs_set(s, 0, "tree=default");
		bs_set(s, 2, "tree=");
	}
	bs_run(s, 1.0);
	CHECK(b->own == NULL && b->own_text == NULL);
	bc_engine_describe(s->e, 1, d, sizeof d);
	CHECK(!strstr(d, "hold") && strstr(d, "pick:") != NULL);
	/* a name -> another text, twice over (the first is freed) */
	bs_set(s, 1, "tree=tree a1:\ndo hold self 50\n");
	bs_run(s, 0.5);
	bs_set(s, 1, "tree=tree a2:\ndo look_around\n");
	bs_run(s, 0.5);
	CHECK(b->own != NULL && !strcmp(b->tree_name, "a2"));
	bc_engine_describe(s->e, 1, d, sizeof d);
	CHECK(strstr(d, "look_around") != NULL);
	/* a text that does not compile: said with its line, and nothing changes */
	log2_before = s->log2_n;
	bs_set(s, 1, "tree=tree bad:\nseq\n\tdo no_such_thing\n");
	bs_run(s, 0.5);
	CHECK(s->log2_n == log2_before + 1 && strstr(s->log2, "bot #1") && strstr(s->log2, "line 3"));
	CHECK(!strcmp(b->tree_name, "a2"));
	bc_engine_describe(s->e, 1, d, sizeof d);
	CHECK(strstr(d, "look_around") != NULL);
	/* the item fragments change under it: its own text is compiled again, and it goes on */
	bs_set(s, BL_NO_PLAYER, "item.rocket.tree=seq\n\tif enemy_visible\n\tdo use rocket enemy");
	bs_run(s, 0.5);
	CHECK(b->own != NULL && b->forest == b->own);
	bc_engine_describe(s->e, 1, d, sizeof d);
	CHECK(strstr(d, "look_around") != NULL);
	/* a name nobody has: said, and it runs the world's */
	bs_set(s, 1, "tree=nonesuch");
	bs_run(s, 1.0);
	CHECK(b->own == NULL && b->tree_name[0] == 0);
	bc_engine_describe(s->e, 1, d, sizeof d);
	CHECK(strstr(d, "pick:") != NULL);
	/* empty: back to the world's tree; and the others never moved */
	bs_set(s, 1, "tree=tree a3:\ndo hold self 50\n");
	bs_run(s, 0.5);
	bs_set(s, 1, "tree=");
	bs_run(s, 1.0);
	CHECK(b->own == NULL && b->tree_name[0] == 0 && b->forest == bc_engine_bot(s->e, 2)->forest);
	CHECK(!strcmp(a->tree_name, "default"));
	/* many changes in a row, an action RUNNING each time: no crash, and it still thinks */
	for (i = 0; i < 40; i++) {
		char text[96];

		snprintf(text, sizeof text, i % 3 == 2 ? "tree=tdm" : "tree=tree r%d:\ndo hold self 50\n", i);
		bs_set(s, 1, text);
		bs_run(s, 0.1);
	}
	bs_run(s, 1.0);
	CHECK(b->alive && (s->intents[1].flags & BL_I_VALID));
	/* the bot goes: its text goes with it */
	bs_set(s, 1, "tree=tree a4:\ndo hold self 50\n");
	bs_run(s, 0.3);
	bs_push(s, BL_EV_UNBOT, 1, NULL, 0);
	bs_run(s, 0.2);
	CHECK(bc_engine_bot(s->e, 1) == NULL && s->e->bots[1].own == NULL && s->e->bots[1].own_text == NULL);
	(void)stops_seen;
	bs_free(s);
}

static void test_traits(void)
{
	bs_sim *s = arena(4);
	int pass, k, fight[3] = { 0, 0, 0 };
	float sum[3] = { 0, 0, 0 }, one = 0.0f;
	bc_bot *b;

	printf("traits=: the lot leans, each keeps its own\n");
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	for (pass = 0; pass < 3; pass++) {
		bs_set(s, BL_NO_PLAYER, pass == 0 ? "traits=" : pass == 1 ? "traits=aggression:2,caution:0.5,nonsense:3"
		                                              : "traits=aggression:0.5,caution:2");
		for (k = 0; k < 200; k++) {
			char leaf[64];
			int i, did = 0;

			/* hit down to 55 with the man in sight: fight on, or break off */
			bs_add(s, 0, 1, 1, 5, 0, 23000u + (uint32_t)k, 220.5f, 264.5f, 1, 0);
			bs_add(s, 1, 0, 2, 5, 0, 1, 246.5f, 264.5f, -1, 0);
			bs_run(s, 0.3);
			b = bc_engine_bot(s->e, 0);
			sum[pass] += b->persona.trait[BC_T_AGGRESSION];
			bs_hurt(s, 0, 45, 1, s->w.players[1].pos, 0);
			for (i = 0; i < 90; i++) {
				bs_step(s);
				s->p[1].hp = 100;
				leaf_of(s, 0, leaf, sizeof leaf);
				if (!strcmp(leaf, "fight")) did = 1;
			}
			fight[pass] += did;
		}
	}
	printf("  200 bots hit with a man in sight; mean aggression %.2f, %.2f with traits=aggression:2,caution:0.5, %.2f with aggression:0.5,caution:2;\n"
	       "  they fight on: %d, %d, %d of 200; the name nobody knows was said: %s\n", (double)(sum[0] / 200.0f),
	       (double)(sum[1] / 200.0f), (double)(sum[2] / 200.0f), fight[0], fight[1], fight[2], s->log2);
	CHECK(sum[1] > sum[0] * 1.5f && sum[2] < sum[0] * 0.7f);
	CHECK(fight[1] > fight[0] + 20 && fight[2] < fight[0] - 20);
	CHECK(strstr(s->log2, "nonsense") != NULL);
	/* for one bot, on top of everybody's; and cleared */
	bs_set(s, BL_NO_PLAYER, "traits=");
	bs_add(s, 0, 1, 1, 5, 0, 23000u, 220.5f, 256.5f, 1, 0);
	bs_run(s, 0.2);
	b = bc_engine_bot(s->e, 0);
	one = b->persona.trait[BC_T_STEALTH];
	bs_set(s, 0, "traits=stealth:1.5");
	bs_run(s, 0.1);
	CHECK(fabsf(b->persona.trait[BC_T_STEALTH] - (one * 1.5f > 3.0f ? 3.0f : one * 1.5f)) < 1e-4f);
	bs_set(s, BL_NO_PLAYER, "traits=stealth:100");
	bs_run(s, 0.1);
	CHECK(b->persona.trait[BC_T_STEALTH] == 3.0f);              /* persona.h's range holds */
	bs_set(s, 0, "traits=");
	bs_set(s, BL_NO_PLAYER, "traits=");
	bs_run(s, 0.1);
	CHECK(fabsf(b->persona.trait[BC_T_STEALTH] - one) < 1e-5f);
	bs_free(s);
}

static void test_cost(int per_team)
{
	bs_sim *s = arena(per_team * 2);
	const bc_engine_stats *st;
	double worst;
	int stuck;

	bs_start(s);
	s->respawn = 3.0;
	teams(s, per_team, 4242);
	bs_run(s, 60.0);
	st = bc_engine_stats_get(s->e);
	stuck_of(s, &stuck, &worst);
	printf("  %2d bots, 60 s, respawning: %.1f us a think call (a call with a new world: about %.1f), worst %.0f us;\n"
	       "           %u decisions; %u plans, %u expansions in all, at most %u in one think (budget %d); %d kills; stuck %d\n",
	       per_team * 2, s->think_us / (double)s->thinks, 2.0 * s->think_us / (double)s->thinks, s->think_max_us,
	       (unsigned)st->decisions, (unsigned)st->plans, (unsigned)st->expansions, (unsigned)s->exp_max, s->budget,
	       s->kills[1] + s->kills[2], stuck);
	CHECK(s->exp_max <= (uint32_t)s->budget + 64);
	CHECK(s->kills[1] + s->kills[2] > 0);
	CHECK(st->decisions > (uint32_t)(per_team * 2 * 60 * 10));     /* over 10 a second each, counting the dead time */
	bs_free(s);
}

/* Real maps, when there are some (BC_TEST_MAPS=dir): 6 against 6 for 90 s,
 * respawning, from two places 120 apart. Numbers, and one assertion: the
 * budget holds. */
static void test_real_maps(void)
{
	const char *dir = getenv("BC_TEST_MAPS");
	struct dirent *de;
	DIR *d;

	if (!dir || !(d = opendir(dir))) {
		printf("real maps: skipped (set BC_TEST_MAPS to a directory of .vxl files)\n");
		return;
	}
	printf("real maps: 12 bots, 90 s, respawning, routes may not edit\n");
	while ((de = readdir(d)) != NULL) {
		char path[1024];
		size_t l = strlen(de->d_name);
		bs_sim *s;
		FILE *f;
		unsigned char *buf;
		long n;
		const bc_engine_stats *st;
		bc_nav_node a, b;
		double worst;
		int i, stuck, shots = 0;

		if (l < 5 || strcmp(de->d_name + l - 4, ".vxl")) continue;
		snprintf(path, sizeof path, "%s/%s", dir, de->d_name);
		f = fopen(path, "rb");
		if (!f) continue;
		fseek(f, 0, SEEK_END);
		n = ftell(f);
		fseek(f, 0, SEEK_SET);
		buf = malloc((size_t)n);
		if (fread(buf, 1, (size_t)n, f) != (size_t)n) n = 0;
		fclose(f);
		s = bs_new(G, 12);
		if (!bc_map_load_vxl(s->truth, buf, (size_t)n) || !bc_engine_map(s->e, buf, (size_t)n, 1) ||
		    !bc_nav_snap(s->truth, 196, 256, 40, 40, &a) || !bc_nav_snap(s->truth, 316, 256, 40, 40, &b)) {
			printf("  %-22s not usable\n", de->d_name);
			free(buf);
			bs_free(s);
			continue;
		}
		free(buf);
		s->have_tents = 1;
		s->tent[0].x = (float)a.x + 0.5f; s->tent[0].y = (float)a.y + 0.5f; s->tent[0].z = (float)a.z - 2.25f;
		s->tent[1].x = (float)b.x + 0.5f; s->tent[1].y = (float)b.y + 0.5f; s->tent[1].z = (float)b.z - 2.25f;
		s->respawn = 3.0;
		for (i = 0; i < 6; i++) {
			bc_nav_node p, q;

			if (!bc_nav_snap(s->truth, a.x + (i % 3) * 3 - 3, a.y + (i / 3) * 3, a.z, 6, &p)) p = a;
			if (!bc_nav_snap(s->truth, b.x + (i % 3) * 3 - 3, b.y + (i / 3) * 3, b.z, 6, &q)) q = b;
			bs_add(s, i, 1, 1, 3 + (i * 3) % 7, i % 3, 31u + (uint32_t)i * 7919u, (float)p.x + 0.5f, (float)p.y + 0.5f, 1, 0);
			bs_add(s, 100 + i, 1, 2, 3 + (i * 5) % 7, (i + 1) % 3, 977u + (uint32_t)i * 104729u, (float)q.x + 0.5f, (float)q.y + 0.5f, -1, 0);
			/* bs_spawn takes the topmost floor; these maps have roofs */
			bc_body_place(&s->p[i].body, s->truth, (float)p.x + 0.5f, (float)p.y + 0.5f, p.z, 0);
			bc_body_place(&s->p[100 + i].body, s->truth, (float)q.x + 0.5f, (float)q.y + 0.5f, q.z, 0);
		}
		bs_set(s, BL_NO_PLAYER, "tree=tdm");
		bs_run(s, 90.0);
		st = bc_engine_stats_get(s->e);
		stuck_of(s, &stuck, &worst);
		for (i = 0; i < BL_MAX_PLAYERS; i++) shots += s->p[i].shots;
		printf("  %-22s kills %2d, %4d rounds; stuck %d (longest hold %.1f s, watchdog %u); %u plans, %u failed, %u again;\n"
		       "  %22s think %.0f us a call, worst %.0f us; %u expansions, at most %u a think\n",
		       de->d_name, s->kills[1] + s->kills[2], shots, stuck, worst, (unsigned)st->stuck, (unsigned)st->plans,
		       (unsigned)st->plan_fails, (unsigned)st->replans, "", s->think_us / (double)s->thinks, s->think_max_us,
		       (unsigned)st->expansions, (unsigned)s->exp_max);
		CHECK(s->exp_max <= (uint32_t)s->budget + 64);
		bs_free(s);
	}
	closedir(d);
}

int main(void)
{
	test_vocab_and_trees();
	test_team_fight(6, 0, "two teams of 6 fight to a result");
	test_team_fight(6, 1, "the same at night (night.sight=1, the lamp fragment as an extra)");
	test_dead_think_nothing();
	test_ping_answered();
	test_cautious_retreat();
	test_night();
	test_night_is_day_by_default();
	test_persona_spread();
	test_replay();
	test_items();
	test_settings();
	test_own_tree();
	test_traits();
	printf("cost (this machine, -O2; a flat field with walls, NOT a real map)\n");
	test_cost(6);
	test_cost(16);
	test_cost(20);
	test_real_maps();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
