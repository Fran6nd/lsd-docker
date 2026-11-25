/* sniper_test.c -- the sniper's role in the shipped trees (tdm_sniper,
 * ctf_sniper), on the simulated server of brain_sim.h:
 *
 *   rifles only    the role is drawn by marksmen with a rifle, never with
 *                  an smg or a shotgun
 *   heard          a shot somewhere: up to a perch, and it camps there
 *   nothing heard  nearer the enemy's base, from cover to cover
 *   kept           the role is the same in its next life
 *   ctf            near their base with their intel at home, or their
 *                  intel lying where a carrier fell: the keen on the game
 *                  go for it
 *
 * A sniper is told from the others by what it does on an open field with
 * nothing heard: `advance_by_cover` toward their base, which no other role
 * of these trees does. */
#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40 };
static const float EYE = (float)G - 2.25f;

static uint32_t seed_with(int trait, float lo, float hi, int trait2, float lo2, uint32_t from)
{
	uint32_t seed;

	for (seed = from; seed < from + 200000; seed++) {
		bc_persona p;
		bc_rng r;

		bc_rng_seed(&r, seed, 0x70657273);
		bc_persona_roll(&p, &r, NULL, 5);
		if (p.trait[trait] >= lo && p.trait[trait] <= hi && (trait2 < 0 || p.trait[trait2] >= lo2))
			return seed;
	}
	return from;
}

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

static void hill(bs_sim *s, int cx, int cy, int h)
{
	int k;

	for (k = 1; k <= h; k++) {
		int r = 1 + (h - k);

		bs_box(s, cx - r, cy - r, G - k, cx + r, cy + r, G - k, 1);
	}
}

static bs_sim *field(float base0, float base1)
{
	bs_sim *s = bs_new(G, 8);

	s->have_tents = 1;
	s->tent[0].x = base0; s->tent[0].y = 256.5f; s->tent[0].z = EYE;
	s->tent[1].x = base1; s->tent[1].y = 256.5f; s->tent[1].z = EYE;
	return s;
}

/* is the bot of this seed and gun a sniper on `tree`: its leaf after a
 * moment on an open field, nothing heard */
static int is_sniper(const char *tree, uint32_t seed, int gun)
{
	bs_sim *s = field(200.5f, 380.5f);
	char t[64], leaf[64];

	if (!strcmp(tree, "ctf")) bs_ctf(s, 192, 264, 198, 270, 384, 242, 390, 248);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	snprintf(t, sizeof t, "tree=%s", tree);
	bs_set(s, BL_NO_PLAYER, t);
	bs_add(s, 0, 1, 1, 6, gun, seed, 205.5f, 256.5f, 1, 0);
	bs_run(s, 1.5);
	leaf_of(s, 0, leaf, sizeof leaf);
	bs_free(s);
	return !strcmp(leaf, "advance_by_cover");
}

static uint32_t snipers[16];
static int n_snipers;

static void test_rifles_only(void)
{
	static const char *const gun[3] = { "rifle", "smg", "shotgun" };
	static const int guns[3] = { BL_GUN_RIFLE, BL_GUN_SMG, BL_GUN_SHOTGUN };
	uint32_t seed = 1;
	int g, k, n[3] = { 0, 0, 0 };

	printf("the sniper's role: rifles only (tdm, 40 marksmen with each gun)\n");
	for (k = 0; k < 40; k++) {
		seed = seed_with(BC_T_MARKSMAN, 1.5f, 3.0f, -1, 0.0f, seed + 1);
		for (g = 0; g < 3; g++)
			if (is_sniper("tdm", seed, guns[g])) {
				n[g]++;
				if (g == 0 && n_snipers < 16) snipers[n_snipers++] = seed;
			}
	}
	printf("  snipers: %s %d, %s %d, %s %d\n", gun[0], n[0], gun[1], n[1], gun[2], n[2]);
	CHECK(n[0] >= 4);
	CHECK(n[1] == 0 && n[2] == 0);
}

/* nothing heard: on toward their base, and it watches it from 45 off;
 * then a shot within earshot (the sim hears one from 14 to 34): up to a
 * perch, and it camps there */
static void test_heard_or_not(void)
{
	int k, watched = 0, up = 0, camped = 0, of = 0;

	printf("a sniper hears nothing, then a shot (tdm)\n");
	for (k = 0; k < n_snipers && k < 8; k++) {
		bs_sim *s = field(200.5f, 330.5f);
		char leaf[64];
		bl_vec3 at;
		int i, perched = 0, camping = 0, watching = 0, idle = 0;

		hill(s, 245, 240, 5);
		hill(s, 250, 280, 5);
		bs_start(s);
		bs_set(s, BL_NO_PLAYER, "leaders.per=0");
		bs_set(s, BL_NO_PLAYER, "tree=tdm");
		bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, snipers[k], 205.5f, 256.5f, 1, 0);
		/* nothing heard, 40 s: to within 45 of their base, and watching it */
		for (i = 0; i < 60 * 40; i++) {
			bs_step(s);
			leaf_of(s, 0, leaf, sizeof leaf);
			if (i > 60 * 30) {
				watching += !strcmp(leaf, "hold");
				idle += !strcmp(leaf, "") || !strcmp(leaf, "idle");
			}
		}
		of++;
		if (fabsf(s->p[0].body.pos.x - 330.5f) < 47.0f && watching > 60 * 8 && idle == 0) watched++;
		/* a wall put up 10 off it, and beyond it, 22 off, a shot every
		 * 2 s -- heard, not seen: up to a perch within a choice (20 s),
		 * and it waits */
		{
			int wy = (int)s->p[0].body.pos.y + (s->p[0].body.pos.y < 256.0f ? 10 : -10), wx, wz;

			for (wx = (int)s->p[0].body.pos.x - 15; wx <= (int)s->p[0].body.pos.x + 15; wx++)
				for (wz = G - 1; wz >= G - 5; wz--)
					bs_block(s, BL_NO_PLAYER, wx, wy, wz, BL_B_BUILD);
			at.x = s->p[0].body.pos.x;
			at.y = s->p[0].body.pos.y + (s->p[0].body.pos.y < 256.0f ? 22.0f : -22.0f);
			at.z = EYE;
		}
		bs_add(s, 100, 0, 2, 5, BL_GUN_RIFLE, 1, at.x, at.y, -1, 0);
		for (i = 0; i < 60 * 45; i++) {
			if (i % 120 == 0) bs_sound(s, 100, at, BL_S_SHOT);
			s->p[100].hp = 100;
			bs_step(s);
			leaf_of(s, 0, leaf, sizeof leaf);
			if ((float)G - bc_body_feet(&s->p[0].body) > 3.5f) perched = 1;
			if (!strcmp(leaf, "camp")) camping = 1;
		}
		up += perched;
		camped += camping;
		bs_free(s);
	}
	printf("  %d snipers: with nothing heard %d went to within 45 of their base and watched it (never idle);\n"
	       "  a shot heard, %d went up a hill, %d camped there\n", of, watched, up, camped);
	CHECK(of >= 4);
	CHECK(watched * 4 >= of * 3);
	CHECK(up * 4 >= of * 3 && camped * 4 >= of * 3);
}

/* the role in its next life */
static void test_kept(void)
{
	int k, kept = 0, of = 0;

	printf("a sniper dies: the role is the same in its next life (tdm)\n");
	for (k = 0; k < n_snipers && k < 8; k++) {
		bs_sim *s = field(200.5f, 380.5f);
		char leaf[64];
		bl_vec3 from;

		bs_start(s);
		s->respawn = 1.0;
		bs_set(s, BL_NO_PLAYER, "leaders.per=0");
		bs_set(s, BL_NO_PLAYER, "tree=tdm");
		bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, snipers[k], 205.5f, 256.5f, 1, 0);
		bs_run(s, 1.5);
		from.x = 300.5f; from.y = 256.5f; from.z = EYE;
		bs_hurt(s, 0, 200, BL_NO_PLAYER, from, 0);
		bs_run(s, 3.5);
		leaf_of(s, 0, leaf, sizeof leaf);
		of++;
		kept += s->p[0].alive && !strcmp(leaf, "advance_by_cover");
		bs_free(s);
	}
	printf("  %d of %d snipers are snipers again after dying\n", kept, of);
	CHECK(of >= 4 && kept == of);
}

/* ctf: near their base with their intel home, or theirs lying in the
 * field, the keen on the game go for it */
static void test_ctf(void)
{
	uint32_t seed = 1;
	int k, found = 0, home_fetch = 0, dropped_fetch = 0;

	printf("ctf snipers keen on the game: their intel at home near them, or lying where a carrier fell\n");
	for (k = 0; k < 400 && found < 8; k++) {
		bs_sim *s;
		char leaf[64];
		int i;
		bl_vec3 from;

		seed = seed_with(BC_T_MARKSMAN, 1.4f, 3.0f, BC_T_OBJECTIVE, 1.6f, seed + 1);
		if (!is_sniper("ctf", seed, BL_GUN_RIFLE))
			continue;
		found++;
		/* 58 off their base, their intel at home: by cover to within 45,
		 * where being near outweighs (near_their_base 70, x3), and at its
		 * next choice (20 s) it goes for it */
		s = field(200.5f, 380.5f);
		bs_ctf(s, 192, 264, 198, 270, 384, 242, 390, 248);
		bs_start(s);
		bs_set(s, BL_NO_PLAYER, "leaders.per=0");
		bs_set(s, BL_NO_PLAYER, "tree=ctf");
		bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, seed, 322.5f, 250.5f, 1, 0);
		for (i = 0; i < 60 * 45; i++) {
			bs_step(s);
			leaf_of(s, 0, leaf, sizeof leaf);
			if (!strcmp(leaf, "fetch")) { home_fetch++; break; }
		}
		bs_free(s);
		/* far from it, theirs lying in the field where our carrier fell */
		s = field(200.5f, 380.5f);
		bs_ctf(s, 192, 264, 198, 270, 384, 242, 390, 248);
		bs_start(s);
		bs_set(s, BL_NO_PLAYER, "leaders.per=0");
		bs_set(s, BL_NO_PLAYER, "tree=ctf");
		bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, seed, 205.5f, 256.5f, 1, 0);
		bs_add(s, 100, 0, 1, 5, BL_GUN_RIFLE, 1, 290.5f, 256.5f, 1, 0);
		s->intel_holder[1] = 100;                 /* he carries theirs... */
		bs_run(s, 1.5);
		from.x = 300.5f; from.y = 256.5f; from.z = EYE;
		bs_hurt(s, 100, 200, BL_NO_PLAYER, from, 0); /* ...and falls: it lies at 290 */
		for (i = 0; i < 60 * 25; i++) {
			bs_step(s);
			leaf_of(s, 0, leaf, sizeof leaf);
			if (!strcmp(leaf, "fetch")) { dropped_fetch++; break; }
		}
		bs_free(s);
	}
	printf("  %d ctf snipers keen on the game: on toward their base with it home, %d go for it within 45 s; it dropped in the field, %d go for it\n",
	       found, home_fetch, dropped_fetch);
	CHECK(found >= 4);
	CHECK(home_fetch * 2 >= found);
	CHECK(dropped_fetch * 2 >= found);
}

int main(void)
{
	test_rifles_only();
	test_heard_or_not();
	test_kept();
	test_ctf();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
