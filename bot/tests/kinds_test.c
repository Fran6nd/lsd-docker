/* kinds_test.c -- the kinds of player as data (persona.h, trees/
 * archetypes.txt): the file is the built-in table, number for number; an
 * operator's file replaces a kind and adds one, which the mix may then
 * name; the engine draws its bots from the table it was given, by file
 * (bc_engine_kinds, what botd does) and by setting (archetype_table, what
 * a script does); a text with a fault changes nothing. */
#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static int same(const bc_kinds *a, const bc_kinds *b)
{
	int k, t;

	if (a->n != b->n) return 0;
	for (k = 0; k < a->n; k++) {
		if (strcmp(a->k[k].name, b->k[k].name) || strcmp(a->k[k].doc, b->k[k].doc)) return 0;
		for (t = 0; t < BC_T_COUNT; t++)
			if (a->k[k].centre[t] != b->k[k].centre[t] || a->k[k].spread[t] != b->k[k].spread[t]) return 0;
	}
	return 1;
}

static const char OPERATOR[] =
	"# an operator's kinds\n"
	"camper caution=2.5/0.30 marksman=2.0/0.40\n"
	"medic  aggression=0.4/0.20 teamwork=2.6/0.30 caution=1.4/0.30 -- stays with the others and keeps them up\n";

static void test_file(void)
{
	bc_kinds built, file, back;
	char *text = bs_slurp("trees/archetypes.txt"), err[200], out[8192];

	printf("trees/archetypes.txt is the built-in table\n");
	bc_kinds_builtin(&built);
	memset(&file, 0, sizeof file);
	CHECK(text != NULL);
	CHECK(text && bc_kinds_parse(&file, text, err, sizeof err));
	printf("  %d kinds in the file, %d built in; the same, number for number: %s\n", file.n, built.n,
	       same(&file, &built) ? "yes" : "no");
	CHECK(same(&file, &built));
	/* and what the table writes, read back, is the table */
	bc_kinds_write(&built, out, sizeof out);
	memset(&back, 0, sizeof back);
	CHECK(bc_kinds_parse(&back, out, err, sizeof err) && same(&back, &built));
	free(text);
}

static void test_operator(void)
{
	bc_kinds t, before;
	float w[BC_KINDS_MAX], mean = 0.0f;
	int medic, camper, k;
	char err[200];

	printf("an operator's file: a kind replaced, one added\n");
	bc_kinds_builtin(&t);
	CHECK(bc_kinds_parse(&t, OPERATOR, err, sizeof err));
	medic = bc_kinds_by_name(&t, "medic");
	camper = bc_kinds_by_name(&t, "camper");
	CHECK(t.n == BC_A_COUNT + 1 && medic == BC_A_COUNT);
	CHECK(camper == BC_A_CAMPER && t.k[camper].centre[BC_T_CAUTION] == 2.5f);
	CHECK(t.k[camper].centre[BC_T_AGGRESSION] == 1.0f);         /* a trait not said: round 1 */
	CHECK(!strcmp(t.k[camper].doc, "careful and a marksman: holds an angle, keeps its distance, seldom goes in"));   /* its line kept */
	CHECK(bc_kinds_weights(&t, "medic:1", w) && w[medic] == 1.0f && w[camper] == 0.0f);
	for (k = 0; k < 400; k++) {
		bc_rng r;
		bc_persona p;

		bc_rng_seed(&r, 9000u + (uint64_t)k, 3);
		bc_kinds_roll(&t, &p, &r, w, 5);
		CHECK(p.archetype == medic);
		mean += p.trait[BC_T_TEAMWORK] / 400.0f;
	}
	printf("  400 medics: teamwork %.2f on average (its centre 2.6)\n", (double)mean);
	CHECK(fabsf(mean - 2.6f) < 0.1f);
	/* faults: the table as it was, and the line said */
	before = t;
	CHECK(!bc_kinds_parse(&t, "ghost stealth=9/0.3\n", err, sizeof err) && same(&t, &before));
	printf("  a centre out of bounds: \"%s\"\n", err);
	CHECK(!bc_kinds_parse(&t, "ok\nghost sneaky=1/0.3\n", err, sizeof err) && same(&t, &before) && strstr(err, "line 2"));
	printf("  no such trait: \"%s\"\n", err);
	CHECK(!bc_kinds_weights(&t, "ghost:1", w));
}

static void test_engine(void)
{
	bs_sim *s = bs_new(40, 4);
	const bc_bot *b;
	char err[200];
	bc_persona p;
	bc_rng r;

	printf("the engine draws its bots from the table it was given\n");
	bs_start(s);
	bs_add(s, 0, 1, 1, 5, BL_GUN_RIFLE, 77, 200.5f, 200.5f, 1, 0);
	bs_step(s);
	b = bc_engine_bot(s->e, 0);
	/* the built-in table: as ever (the same draw as bc_persona_roll) */
	bc_rng_seed(&r, 77, 0x70657273);
	bc_persona_roll(&p, &r, NULL, 5);
	CHECK(b && b->persona.archetype == p.archetype && b->persona.trait[BC_T_CAUTION] == p.trait[BC_T_CAUTION]);
	/* botd's files: the operator's medic, and a mix that names it */
	CHECK(bc_engine_kinds(s->e, OPERATOR, err, sizeof err));
	bs_set(s, BL_NO_PLAYER, "archetypes=medic:1");
	bs_step(s);
	printf("  given the medic and archetypes=medic:1: the bot is a %s\n", bc_engine_kind_name(s->e, b->persona.archetype));
	CHECK(!strcmp(bc_engine_kind_name(s->e, b->persona.archetype), "medic"));
	/* files with no medic while the mix names it: refused, the kinds as they were */
	CHECK(!bc_engine_kinds(s->e, "scout curiosity=2.0/0.3\n", err, sizeof err));
	CHECK(bc_kinds_by_name(&s->e->kinds, "medic") >= 0);
	CHECK(!bc_engine_kinds(s->e, "medic flank=0/1\n", err, sizeof err));     /* a fault: as it was */
	CHECK(!strcmp(bc_engine_kind_name(s->e, b->persona.archetype), "medic"));
	/* a script's table over the files': a scout of its own, and the mix to it */
	bs_set(s, BL_NO_PLAYER, "archetype_table=lookout curiosity=2.8/0.2 stealth=2.0/0.3 -- a script's own");
	bs_set(s, BL_NO_PLAYER, "archetypes=lookout:1");
	bs_step(s);
	printf("  a script's table and archetypes=lookout:1: a %s, curiosity %.2f\n",
	       bc_engine_kind_name(s->e, b->persona.archetype), (double)b->persona.trait[BC_T_CURIOSITY]);
	CHECK(!strcmp(bc_engine_kind_name(s->e, b->persona.archetype), "lookout"));
	CHECK(s->e->kinds.n == BC_A_COUNT + 2);                             /* the files' medic is still there */
	bs_free(s);
}

int main(void)
{
	test_file();
	test_operator();
	test_engine();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
