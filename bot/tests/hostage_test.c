/* hostage_test.c -- a gamemode gives one bot a tree of its own: the
 * hostage of catalog/gamemodes/hostage/hostage.lua, as the engine plays it
 * (THE ENGINE'S MIND there), on the simulated server of brain_sim.h. The
 * tree is the script's own text, read out of the script; what the script
 * tells it (an order to follow its leader, `fact rescue`, `fact home`,
 * `fact lost`) is told here by hand, as steer() would.
 *
 *   held     nobody leads it: it waits at its post
 *   freed    a man of its side leads it: it keeps to him across the field
 *   exit     its man in its tent: it runs the last steps, and says so
 *   alone    its rescuer dies on the way: it stays down where it is, and
 *            cowers when shot at -- and, unarmed, never aims at anybody */
#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40, HOSTAGE = 0, RESCUER = 1, CAPTOR = 2 };
static const float EYE = (float)G - 2.25f;
static const float HOME_X = 150.5f, POST_X = 330.5f;

/* the script's tree, as the script sends it */
static char *captive_tree(void)
{
	char *src = bs_slurp("../catalog/gamemodes/hostage/hostage.lua"), *from, *to, *out, *o;
	const char *i;

	if (!src) return NULL;
	from = strstr(src, "tree hostage_captive:");
	to = from ? strstr(from, "]]") : NULL;
	if (!to) { free(src); return NULL; }
	*to = 0;
	out = malloc(strlen(from) + 16);
	strcpy(out, "tree=");
	for (i = from, o = out + 5; *i; i++) {
		*o++ = *i;
	}
	*o = 0;
	free(src);
	return out;
}

static bs_sim *field(const char *tree)
{
	bs_sim *s = bs_new(G, 4);

	s->have_tents = 1;
	s->tent[0].x = HOME_X; s->tent[0].y = 256.5f; s->tent[0].z = EYE;
	s->tent[1].x = POST_X + 2.0f; s->tent[1].y = 256.5f; s->tent[1].z = EYE;
	bs_start(s);
	bs_add(s, HOSTAGE, 1, 1, 1, BL_GUN_RIFLE, 4242u, POST_X, 256.5f, -1, 0);
	bs_set(s, HOSTAGE, tree);
	bs_add(s, RESCUER, 0, 1, 5, BL_GUN_RIFLE, 1, POST_X + 3.0f, 258.5f, -1, 0);
	bs_add(s, CAPTOR, 0, 2, 5, BL_GUN_RIFLE, 2, POST_X + 30.0f, 270.5f, -1, 0);
	return s;
}

/* a tick, the hostage kept unarmed (the server's doing, as steer() does) */
static void step(bs_sim *s, int *aimed)
{
	const bc_bot *b;

	s->p[HOSTAGE].mag = s->p[HOSTAGE].reserve = 0;
	bs_step(s);
	b = bc_engine_bot(s->e, HOSTAGE);
	if (aimed && b && b->wish.fire_pid >= 0) (*aimed)++;
}

static bl_vec3 at_of(const bs_sim *s, int pid)
{
	bl_vec3 p;

	p.x = s->p[pid].body.pos.x; p.y = s->p[pid].body.pos.y; p.z = s->p[pid].body.pos.z;
	return p;
}

static float hx(const bs_sim *s) { return s->p[HOSTAGE].body.pos.x; }

static float apart(const bs_sim *s, int a, int b)
{
	float dx = s->p[a].body.pos.x - s->p[b].body.pos.x, dy = s->p[a].body.pos.y - s->p[b].body.pos.y;

	return sqrtf(dx * dx + dy * dy);
}

static void test_held_freed_home(const char *tree)
{
	bs_sim *s = field(tree);
	float worst = 0.0f, x0;
	int i, aimed = 0, home_at = -1, told_home = 0;

	printf("held, freed, led home\n");
	/* held: nobody leads it, the captor in sight */
	for (i = 0; i < 60 * 5; i++) step(s, &aimed);
	printf("  held 5 s: %.1f from its post\n", fabsf(hx(s) - POST_X));
	CHECK(fabsf(hx(s) - POST_X) < 2.0f);

	/* freed: its man is by it and leads it off, west, at a walk */
	bs_order(s, HOSTAGE, BL_O_FOLLOW, 0, 0, 0, RESCUER, 0);
	bs_set(s, HOSTAGE, "fact.rescue=1");
	x0 = hx(s);
	s->p[RESCUER].ori.x = -1; s->p[RESCUER].ori.y = 0;
	for (i = 0; i < 60 * 90 && home_at < 0; i++) {
		if (s->p[RESCUER].body.pos.x > HOME_X)
			s->p[RESCUER].script_keys = BL_K_FORWARD;
		else
			s->p[RESCUER].script_keys = 0;            /* he is in the tent: there he waits */
		/* the script: its man stands in its tent (hostage_tent_radius 4) */
		if (!told_home && fabsf(s->p[RESCUER].body.pos.x - HOME_X) < 4.0f &&
		    fabsf(s->p[RESCUER].body.pos.y - 256.5f) < 4.0f) {
			bs_set(s, HOSTAGE, "fact.home=1");
			told_home = 1;
		}
		step(s, &aimed);
		if (s->p[RESCUER].body.pos.x > HOME_X + 12.0f && apart(s, HOSTAGE, RESCUER) > worst)
			worst = apart(s, HOSTAGE, RESCUER);
		if (s->p[HOSTAGE].tells && !strcmp(s->p[HOSTAGE].last_tell, "hostage_home"))
			home_at = i;
	}
	printf("  led %.0f voxels across the field: at most %.1f from its man; home and said so after %.1f s, %.1f from the tent\n",
	       x0 - hx(s), worst, home_at / 60.0, fabsf(hx(s) - HOME_X));
	CHECK(worst < 10.0f);                      /* it keeps to him: within hostage_lose_dist (10), past which the script lets it go */
	CHECK(home_at > 0);                        /* the last steps alone, and the tell */
	CHECK(fabsf(hx(s) - HOME_X) < 3.0f);       /* in the tent (hostage_home_radius 3) */
	CHECK(aimed == 0 && s->p[HOSTAGE].shots == 0);
	bs_free(s);
}

static void test_rescuer_dies(const char *tree)
{
	bs_sim *s = field(tree);
	int i, aimed = 0, crouched = 0, ticks = 0;
	float x_dead;
	bl_vec3 from;

	printf("its rescuer dies on the way\n");
	bs_order(s, HOSTAGE, BL_O_FOLLOW, 0, 0, 0, RESCUER, 0);
	bs_set(s, HOSTAGE, "fact.rescue=1");
	s->p[RESCUER].ori.x = -1; s->p[RESCUER].ori.y = 0;
	for (i = 0; i < 60 * 15; i++) {
		s->p[RESCUER].script_keys = BL_K_FORWARD;
		step(s, &aimed);
	}
	from = at_of(s, CAPTOR);
	bs_hurt(s, RESCUER, 200, CAPTOR, from, 0);
	/* the script: nobody leads it, loose in the open */
	bs_order(s, HOSTAGE, BL_O_NONE, 0, 0, 0, 0, 0);
	bs_set(s, HOSTAGE, "fact.rescue=0");
	bs_set(s, HOSTAGE, "fact.lost=1");
	for (i = 0; i < 30; i++) step(s, &aimed);
	x_dead = hx(s);
	for (i = 0; i < 60 * 8; i++) {
		step(s, &aimed);
		ticks++;
		if (s->p[HOSTAGE].body.keys & BC_K_CROUCH) crouched++;
	}
	printf("  loose, nobody: moved %.1f in 8 s, down %.0f%% of it\n", fabsf(hx(s) - x_dead), 100.0 * crouched / ticks);
	CHECK(fabsf(hx(s) - x_dead) < 2.0f);
	CHECK(crouched > ticks * 3 / 4);

	/* shot at, the order and the facts as they were: still down, and no aim */
	s->p[HOSTAGE].hp = 100;
	crouched = ticks = 0;
	bs_set(s, HOSTAGE, "fact.lost=0");
	for (i = 0; i < 60 * 4; i++) {
		if (i % 30 == 0) bs_hurt(s, HOSTAGE, 5, CAPTOR, at_of(s, CAPTOR), 0);
		step(s, &aimed);
		ticks++;
		if (s->p[HOSTAGE].body.keys & BC_K_CROUCH) crouched++;
	}
	printf("  shot at: down %.0f%% of 4 s; aimed at anybody on %d ticks\n", 100.0 * crouched / ticks, aimed);
	CHECK(crouched > ticks / 2);
	CHECK(aimed == 0 && s->p[HOSTAGE].shots == 0);
	bs_free(s);
}

int main(void)
{
	char *tree = captive_tree();

	CHECK(tree != NULL);
	if (tree) {
		test_held_freed_home(tree);
		test_rescuer_dies(tree);
		free(tree);
	}
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
