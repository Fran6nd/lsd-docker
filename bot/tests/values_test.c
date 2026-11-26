/* values_test.c -- the engine's VALUES (vocab.c): each reads what it
 * says, is unknown when it says, and every condition or score that is
 * short for a comparison of one answers as the comparison written out
 * -- and as the word answered when it was a function of its own (the
 * formulas below are those functions, kept here as the reference) --
 * over a sweep of situations, on the simulated server of brain_sim.h */
#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40 };

static bt_vocab *V;

/* "if <text>" for the bot: 1 or 0 */
static int ask(bc_bot *b, const char *text)
{
	char tree[160], err[200];
	bt_forest *f;
	bt_state *s;
	bt_ctx c;
	bt_status r;

	snprintf(tree, sizeof tree, "if %s\n", text);
	f = bt_compile(V, tree, err, sizeof err);
	if (!f) { printf("  {%s}: %s\n", text, err); failed++; return -1; }
	s = malloc(bt_state_size(f));
	bt_state_init(s, f);
	memset(&c, 0, sizeof c);
	c.bot = b;
	r = bt_tick(f, 0, s, &c);
	free(s);
	bt_forest_free(f);
	return r == BT_SUCCESS;
}

/* an option's worth as its pick weighs it: the score a word gives */
static float scored(bc_bot *b, const char *text)
{
	char tree[160], err[200];
	bt_forest *f;
	bt_state *s;
	bt_ctx c;
	bt_worth w;
	float one = 1.0f;

	snprintf(tree, sizeof tree, "pick\n\toption none %s\n\t\twait 1\n", text);
	f = bt_compile(V, tree, err, sizeof err);
	if (!f) { printf("  {%s}: %s\n", text, err); failed++; return -1.0f; }
	s = malloc(bt_state_size(f));
	bt_state_init(s, f);
	bt_state_trace(s, 1);
	memset(&c, 0, sizeof c);
	c.bot = b;
	c.weights = &one;
	c.n_weights = 1;
	bt_tick(f, 0, s, &c);
	w.score = -1.0f;
	bt_state_worths(f, s, 0, &w, 1);
	free(s);
	bt_forest_free(f);
	return w.score;
}

/* the value as a tree reads it: known (1, *v) or not (0) -- found by
 * comparing, as a tree can only do */
static int known(bc_bot *b, const char *value)
{
	char t[100];
	snprintf(t, sizeof t, "%s >= 0", value);
	return ask(b, t) || (snprintf(t, sizeof t, "%s < 0", value), ask(b, t));
}

static float pick(bc_rng *r, const float *v, int n) { return v[(int)(bc_rng_float(r) * (float)n) % n]; }

/* ---- the reference: what each word was, a function of its own -------- */

static float ref_near(const bc_bot *b)
{
	const bl_player *me = bc_me(b);
	const bc_known *k;
	float dx, dy, dz;
	if (b->senses.nearest < 0) return 1e9f;
	k = &b->senses.k[b->senses.nearest];
	dx = k->pos.x - me->pos.x; dy = k->pos.y - me->pos.y; dz = k->pos.z - me->pos.z;
	return sqrtf(dx * dx + dy * dy + dz * dz);
}

static float ref_ammo(const bc_bot *b)
{
	static const float full[3] = { 60.0f, 150.0f, 54.0f };
	const bl_player *me = bc_me(b);
	return ((float)me->mag + (float)me->reserve) / full[me->gun <= 2 ? me->gun : 0];
}

static float ref_base_near(bc_bot *b, const char *name, float r)
{
	const bl_player *me = bc_me(b);
	bl_vec3 p;
	float dx, dy, v;
	if (!bc_place_of(b, name, &p)) return 0.0f;
	dx = p.x - me->pos.x; dy = p.y - me->pos.y;
	v = 1.0f - sqrtf(dx * dx + dy * dy) / r;
	return v < 0.0f ? 0.0f : v > 1.0f ? 1.0f : v;
}

/* word with its arguments -> what it answered (1/0) */
static int reference(bc_bot *b, const char *word, float n, int given)
{
	double now = b->e->now;
	float d;
	if (!strcmp(word, "enemy_within")) return ref_near(b) <= n;
	if (!strcmp(word, "enemy_beyond")) return b->senses.n_visible > 0 && ref_near(b) > n;
	if (!strcmp(word, "health_below")) return (float)bc_me(b)->hp < n;
	if (!strcmp(word, "ammo_below")) return ref_ammo(b) < n;
	if (!strcmp(word, "level_at_least")) return (float)b->level >= n;
	if (!strcmp(word, "hurt_recently")) return now - b->senses.hurt_at < (double)(given ? n : 3.0f);
	if (!strcmp(word, "under_fire")) return now - b->senses.shot_at < (double)(given ? n : 3.0f);
	if (!strcmp(word, "spotted_new")) return now - b->senses.spotted_new_at < (double)(given ? n : 2.0f);
	if (!strcmp(word, "just_spawned")) return now - b->born_at < (double)(given ? n : 4.0f);
	if (!strcmp(word, "mate_within")) return bc_nearest_mate(b, &d) >= 0 && d <= n;
	if (!strcmp(word, "alone")) return bc_nearest_mate(b, &d) < 0 || d > (given ? n : 25.0f);
	if (!strcmp(word, "near_own_base")) return ref_base_near(b, "own_base", given ? n : 20.0f) > 0.0f;
	if (!strcmp(word, "near_their_base")) return ref_base_near(b, "enemy_base", given ? n : 20.0f) > 0.0f;
	if (!strcmp(word, "quiet")) {
		double since = b->senses.last_sight > b->born_at ? b->senses.last_sight : b->born_at;
		return now - since >= (double)(given ? n : 20.0f);
	}
	return -1;
}

static void test_sweep(void)
{
	static const float D[] = { 0.0f, 4.99f, 5.0f, 5.01f, 14.999f, 15.0f, 15.001f, 19.999f, 20.0f, 20.001f, 24.99f, 25.0f,
	                           25.01f, 39.9f, 40.0f, 60.0f, 100.0f };
	static const float AGE[] = { 0.0f, 0.001f, 1.999f, 2.0f, 2.001f, 2.999f, 3.0f, 3.001f, 3.999f, 4.0f, 4.001f, 5.999f,
	                             6.0f, 9.999f, 10.0f, 19.999f, 20.0f, 20.001f, 1e9f };
	static const float HP[] = { 1, 29, 30, 31, 39, 40, 41, 99, 100 };
	/* each word, the numbers it is asked with ("" : left out), and the
	 * comparison it is short for */
	static const struct { const char *word, *args[4], *cmp; int score; } W[] = {
		{ "enemy_within", { "0", "5", "20", "60" }, "enemy_distance <= %s", 0 },
		{ "enemy_beyond", { "0", "5", "20", "60" }, "enemy_distance > %s", 0 },
		{ "health_below", { "0", "30", "40", "100" }, "health < %s", 0 },
		{ "ammo_below", { "0", "0.25", "0.5", "1" }, "ammo < %s", 0 },
		{ "level_at_least", { "1", "5", "5.5", "10" }, "level >= %s", 0 },
		{ "hurt_recently", { "", "0", "3", "6" }, "since_hurt < %s", 0 },
		{ "under_fire", { "", "0", "3", "6" }, "since_shot_at < %s", 0 },
		{ "spotted_new", { "", "2", "5", "0.001" }, "since_spotted_new < %s", 0 },
		{ "just_spawned", { "", "4", "10", "0" }, "since_spawn < %s", 0 },
		{ "mate_within", { "0", "15", "25", "40" }, "mate_distance <= %s", 0 },
		{ "alone", { "", "0", "15", "25" }, "unless mate_distance <= %s", 0 },
		{ "near_own_base", { "", "0", "20", "40" }, "distance own_base < %s", 0 },
		{ "near_their_base", { "", "0", "20", "40" }, "distance enemy_base < %s", 0 },
		{ "just_spawned", { "", "4", "10", "0" }, "since_spawn < %s", 1 },
		{ "quiet", { "", "20", "3", "0" }, "since_enemy_seen >= %s", 1 },
	};
	static const float DEFAULT[] = { 0, 0, 0, 0, 0, 3, 3, 2, 4, 0, 25, 20, 20, 4, 20 };
	bs_sim *s = bs_new(G, 8);
	bc_bot *b;
	bc_rng r;
	int k, i, a, n = 0, bad = 0;

	printf("every word short for a comparison answers as the comparison, and as it did as a function\n");
	s->have_tents = 1;
	s->tent[0].x = 200.5f; s->tent[0].y = 256.5f; s->tent[0].z = (float)G - 2.0f;
	s->tent[1].x = 300.5f; s->tent[1].y = 256.5f; s->tent[1].z = (float)G - 2.0f;
	bs_start(s);
	bs_add(s, 0, 1, 1, 5, BL_GUN_RIFLE, 7, 220.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 1, 5, BL_GUN_RIFLE, 8, 230.5f, 256.5f, 1, 0);
	bs_add(s, 2, 0, 1, 5, BL_GUN_RIFLE, 9, 240.5f, 256.5f, 1, 0);
	bs_add(s, 3, 0, 2, 5, BL_GUN_RIFLE, 10, 250.5f, 256.5f, 1, 0);
	bs_step(s);
	bs_step(s);
	b = bc_engine_bot(s->e, 0);
	CHECK(b != NULL);
	if (!b) { bs_free(s); return; }
	bc_rng_seed(&r, 4242, 3);
	for (k = 0; k < 600; k++) {
		bc_engine *e = b->e;
		bl_player *me = &e->w.players[0], *m1 = &e->w.players[1], *m2 = &e->w.players[2];
		float d;

		/* a situation: every field the words read, at and about their edges */
		e->now = 1000.0 + (double)k;
		me->hp = (uint8_t)pick(&r, HP, 9);
		me->gun = (uint8_t)(k % 3);
		me->mag = (uint8_t)(bc_rng_float(&r) * 11.0f);
		me->reserve = (uint8_t)(bc_rng_float(&r) < 0.2f ? 0 : bc_rng_float(&r) * 60.0f);
		b->level = (uint8_t)(1 + k % 10);
		me->pos.x = 220.5f; me->pos.y = 256.5f; me->pos.z = (float)G - 3.0f;
		d = pick(&r, D, 17);
		if (bc_rng_float(&r) < 0.25f) { b->senses.nearest = -1; b->senses.n_visible = 0; }
		else {
			b->senses.nearest = 3; b->senses.n_visible = 1;
			b->senses.k[3].pos = me->pos;
			b->senses.k[3].pos.x += d * 0.6f; b->senses.k[3].pos.y += d * 0.8f;
		}
		b->senses.hurt_at = e->now - (double)pick(&r, AGE, 19);
		b->senses.shot_at = e->now - (double)pick(&r, AGE, 19);
		b->senses.spotted_new_at = e->now - (double)pick(&r, AGE, 19);
		b->senses.last_sight = e->now - (double)pick(&r, AGE, 19);
		b->born_at = e->now - (double)pick(&r, AGE, 19);
		m1->state = bc_rng_float(&r) < 0.3f ? BL_DEAD : BL_ALIVE;
		m2->state = bc_rng_float(&r) < 0.5f ? BL_DEAD : BL_ALIVE;
		d = pick(&r, D, 17);
		m1->pos = me->pos; m1->pos.x += d;
		d = pick(&r, D, 17);
		m2->pos = me->pos; m2->pos.y -= d;
		d = pick(&r, D, 17);
		if (k % 7 == 0) { me->pos.x = e->w.tent[1].pos.x - d * 0.6f; me->pos.y = e->w.tent[1].pos.y + d * 0.8f; }
		else { me->pos.x = e->w.tent[0].pos.x + d * 0.8f; me->pos.y = e->w.tent[0].pos.y + d * 0.6f; }

		for (i = 0; i < (int)(sizeof W / sizeof W[0]); i++)
			for (a = 0; a < 4; a++) {
				char word[64], cmp[80], num[16];
				int got, as_cmp, want;
				float x = W[i].args[a][0] ? (float)atof(W[i].args[a]) : DEFAULT[i];

				snprintf(word, sizeof word, "%s%s%s", W[i].word, W[i].args[a][0] ? " " : "", W[i].args[a]);
				snprintf(num, sizeof num, "%s", W[i].args[a][0] ? W[i].args[a] : "");
				if (!num[0]) snprintf(num, sizeof num, "%g", (double)DEFAULT[i]);
				snprintf(cmp, sizeof cmp, W[i].cmp, num);
				want = reference(b, W[i].word, x, W[i].args[a][0] != 0);
				if (W[i].score) {
					got = scored(b, word) > 0.5f;
					as_cmp = !strncmp(cmp, "unless ", 7) ? !ask(b, cmp + 7) : ask(b, cmp);
				} else {
					got = ask(b, word);
					as_cmp = !strncmp(cmp, "unless ", 7) ? !ask(b, cmp + 7) : ask(b, cmp);
				}
				n++;
				if (got != as_cmp || got != want) {
					if (bad++ < 10) printf("  situation %d: %s%s answers %d, `%s` %d, as it was %d\n", k,
					                       W[i].score ? "the score " : "", word, got, cmp, as_cmp, want);
				}
			}
	}
	printf("  %d answers, %d differ\n", n, bad);
	CHECK(bad == 0);
	bs_free(s);
}

/* each value: unknown exactly when it says; what it reads */
static void test_unknown(void)
{
	bs_sim *s = bs_new(G, 8);
	bc_bot *b;

	printf("a value is unknown when it says, and a comparison of it is then false\n");
	s->have_tents = 1;
	s->tent[0].x = 200.5f; s->tent[0].y = 256.5f; s->tent[0].z = (float)G - 2.0f;
	s->tent[1].x = 300.5f; s->tent[1].y = 256.5f; s->tent[1].z = (float)G - 2.0f;
	bs_start(s);
	bs_add(s, 0, 1, 1, 7, BL_GUN_SMG, 7, 220.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 1, 5, BL_GUN_RIFLE, 8, 230.5f, 256.5f, 1, 0);
	bs_add(s, 3, 0, 2, 5, BL_GUN_RIFLE, 10, 250.5f, 256.5f, 1, 0);
	bs_step(s);
	bs_step(s);
	b = bc_engine_bot(s->e, 0);
	CHECK(b != NULL);
	if (!b) { bs_free(s); return; }
	/* nobody in sight: no distance; `unless` of it holds (the doc's example) */
	b->senses.nearest = -1;
	b->senses.n_visible = 0;
	CHECK(!known(b, "enemy_distance"));
	CHECK(ask(b, "enemies_in_sight < 1") == 1);
	CHECK(ask(b, "enemy_distance < 5") == 0 && ask(b, "enemy_distance >= 5") == 0);
	{
		char t[] = "unless enemy_distance < 5\n";
		bt_forest *f = bt_compile(V, t, NULL, 0);
		bt_state *st = f ? malloc(bt_state_size(f)) : NULL;
		bt_ctx c;
		memset(&c, 0, sizeof c);
		c.bot = b;
		if (f) { bt_state_init(st, f); CHECK(bt_tick(f, 0, st, &c) == BT_SUCCESS); }
		free(st);
		bt_forest_free(f);
	}
	/* a man in sight 12 away: known, and that */
	b->senses.nearest = 3;
	b->senses.n_visible = 1;
	b->senses.k[3].pos = bc_me(b)->pos;
	b->senses.k[3].pos.x += 12.0f;
	CHECK(known(b, "enemy_distance") && ask(b, "enemy_distance <= 12") && !ask(b, "enemy_distance < 12"));
	CHECK(ask(b, "enemies_in_sight >= 1") && !ask(b, "enemies_in_sight >= 2"));
	/* no team-mate alive: no distance to one, none within any radius */
	s->e->w.players[1].state = BL_DEAD;
	CHECK(!known(b, "mate_distance") && ask(b, "mates_within 100 < 1"));
	s->e->w.players[1].state = BL_ALIVE;
	s->e->w.players[1].pos = bc_me(b)->pos;
	s->e->w.players[1].pos.y += 7.0f;
	s->e->w.players[1].pos.z -= 30.0f;                 /* across the ground: height left out */
	CHECK(ask(b, "mate_distance <= 7") && !ask(b, "mate_distance < 7") && ask(b, "mates_within 7 >= 1"));
	/* a place it does not know of: no distance */
	CHECK(!known(b, "distance @nowhere") && !known(b, "distance noise"));
	CHECK(known(b, "distance own_base") && known(b, "distance self") && ask(b, "distance self < 0.001"));
	/* a fact nobody set: unknown; set, its number, whatever it is */
	CHECK(!known(b, "fact alarm"));
	strcpy(s->e->facts[0].name, "alarm");
	s->e->facts[0].value = -3.5f;
	CHECK(ask(b, "fact alarm < -3") && !ask(b, "fact alarm < -3.5") && ask(b, "fact alarm >= -3.5"));
	/* what it holds, its level, its health, its ammunition */
	s->e->w.players[0].blocks = 17;
	s->e->w.players[0].grenades = 2;
	s->e->w.players[0].hp = 64;
	s->e->w.players[0].mag = 30;
	s->e->w.players[0].reserve = 0;
	CHECK(ask(b, "blocks >= 17") && !ask(b, "blocks > 17") && ask(b, "grenades >= 2") && !ask(b, "grenades >= 3"));
	CHECK(ask(b, "health >= 64") && !ask(b, "health > 64") && ask(b, "level >= 7") && !ask(b, "level > 7"));
	CHECK(ask(b, "ammo <= 0.2") && ask(b, "ammo > 0.19"));                 /* an smg: 30 of 150 */
	/* the ages: seconds since */
	s->e->now = 500.0;
	b->born_at = 490.0;
	b->senses.hurt_at = 499.5;
	b->senses.last_sight = 470.0;                     /* before this life: counted from its spawn */
	CHECK(ask(b, "since_spawn >= 10") && !ask(b, "since_spawn > 10") && ask(b, "since_hurt <= 0.5") && !ask(b, "since_hurt < 0.5"));
	CHECK(ask(b, "since_enemy_seen >= 10") && !ask(b, "since_enemy_seen > 10"));
	bs_free(s);
}

/* every value of the table compiles, in a guard and as a score, with
 * the first number of its range */
static void test_table(void)
{
	char text[400], err[200], usage[64];
	int i, k;

	printf("the table of values\n");
	CHECK(bc_value_count() >= 15);
	for (i = 0; i < bc_value_count(); i++) {
		bc_value x;
		bt_forest *f;
		size_t n = 0;

		CHECK(bc_value_at(i, &x) && x.name && x.doc && x.fn && x.number && x.number->type == BT_ARG_NUMBER && x.number->name);
		bc_value_usage(i, usage, sizeof usage);
		n += (size_t)snprintf(text + n, sizeof text - n, "select\n\tif %s", x.name);
		for (k = 0; k < x.n_args; k++)
			n += (size_t)snprintf(text + n, sizeof text - n, " %s", x.args[k].type == BT_ARG_NUMBER ? "10" : x.args[k].set ? "self" : "x");
		n += (size_t)snprintf(text + n, sizeof text - n, " >= %g\n\t\tdo hold\n\tpick\n\t\toption none %s", (double)x.number->min, x.name);
		for (k = 0; k < x.n_args; k++)
			n += (size_t)snprintf(text + n, sizeof text - n, " %s", x.args[k].type == BT_ARG_NUMBER ? "10" : x.args[k].set ? "self" : "x");
		snprintf(text + n, sizeof text - n, " < %g x2\n\t\t\tdo hold\n", (double)(x.number->has_max ? x.number->max : x.number->min + 1));
		f = bt_compile(V, text, err, sizeof err);
		if (!f) printf("  %s (%s): %s\n", x.name, usage, err);
		CHECK(f != NULL);
		bt_forest_free(f);
	}
	CHECK(!bc_value_at(bc_value_count(), &(bc_value){0}));
	/* a word short for one says so, in words a person reads */
	for (i = 0, k = 0; i < bc_vocab_count(); i++) {
		bc_word w;
		char sf[128];
		bc_vocab_word(i, &w);
		bc_vocab_short_for(i, sf, sizeof sf);
		if (!strcmp(w.name, "enemy_within") && w.kind == BT_WORD_COND) CHECK(!strcmp(sf, "enemy_distance <= <voxels>"));
		if (!strcmp(w.name, "alone") && w.kind == BT_WORD_COND) CHECK(!strcmp(sf, "unless mate_distance <= [voxels]"));
		if (!strcmp(w.name, "near_own_base") && w.kind == BT_WORD_COND) CHECK(!strcmp(sf, "distance own_base < [voxels]"));
		k += w.short_for != NULL;
	}
	CHECK(k == 15);
}

int main(void)
{
	V = bt_vocab_new();
	if (!bc_vocab_register(V)) { printf("the vocabulary does not register\n"); return 1; }
	test_table();
	test_unknown();
	test_sweep();
	bt_vocab_free(V);
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
