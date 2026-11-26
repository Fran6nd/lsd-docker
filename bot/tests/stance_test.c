/* stance_test.c -- a bot shooting at a man standing, crouched or wading,
 * on the simulated server of brain_sim.h. The owner (2026-11-26): "check
 * bot aim: do they aim properly on crouched people?"
 *
 * A crouched man's eye (the position the server reports) is 0.9 lower, his
 * feet where they were: the body under his eye is 1.35 tall, not 2.25
 * (lsd/src/demoncore.c: change_crouch, boxclipmove). A spot aimed at as
 * far under his eye as on a standing man is in the ground at his feet.
 * (There is no prone in this game; wading is a man standing in the sea,
 * a voxel lower than the bank.)
 *
 * A bot of level 1, 5 and 10 fights a man who never shoots back, at 10, 30
 * and 60 voxels, kept where it is. Counted over its shots:
 *   on body   the shot's line (the aim, before the gun's spread) passes
 *             through the body the server moves: 0.45 round its axis, from
 *             0.45 over the eye to the feet;
 *   hits      what lib_bot's judge gave (bot shots are judged there,
 *             ray_hits_player; brain_sim.h's bs_ray_hits is the same). */
#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { STAND, CROUCH, WADE, STANCES };
static const char *const STANCE[STANCES] = { "standing", "crouched", "wading" };

/* does the line from `eye` along `d` pass through the server's body of
 * the man at `pos` (crouched or not), before any wall? */
static int on_body(const bs_sim *s, bl_vec3 eye, bl_vec3 d, bl_vec3 pos, int crouched)
{
	float wx = pos.x - eye.x, wy = pos.y - eye.y, h = d.x * d.x + d.y * d.y, t, cz, top, feet;
	bl_vec3 c;

	if (h < 1e-6f) return 0;
	/* the nearest the line comes to his axis, across */
	t = (wx * d.x + wy * d.y) / h;
	if (t <= 0.0f) return 0;
	c.x = eye.x + d.x * t; c.y = eye.y + d.y * t; c.z = eye.z + d.z * t;
	if ((c.x - pos.x) * (c.x - pos.x) + (c.y - pos.y) * (c.y - pos.y) > 0.45f * 0.45f) return 0;
	cz = c.z - pos.z;
	top = -0.45f;
	feet = crouched ? 1.35f : 2.25f;
	if (cz < top || cz > feet) return 0;
	return bc_sight_clear(s->truth, eye, c);
}

typedef struct tally { int shots, on, hits; } tally;

static void duel(int level, int stance, float range, uint32_t seed, tally *out)
{
	/* wading: the ground is a bank a voxel over the sea, the bot on its
	 * edge, the man in the open sea beyond */
	int g = stance == WADE ? 62 : 40, i;
	bs_sim *s = bs_new(g, 4);
	float bx = 200.5f, tx = 200.5f + range;
	int shots0;

	if (stance == WADE)
		bs_box(s, (int)bx + 2, 200, 62, 400, 312, 62, 0);
	s->have_tents = 1;
	s->tent[0].x = 100.5f; s->tent[0].y = 256.5f; s->tent[0].z = (float)g - 2.25f;
	s->tent[1].x = 400.5f; s->tent[1].y = 256.5f; s->tent[1].z = (float)g - 2.25f;
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\ndo fight\n");
	bs_add(s, 0, 1, 1, level, BL_GUN_RIFLE, seed, bx, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, tx, 256.5f, -1, 0);
	shots0 = 0;
	for (i = 0; i < 60 * 30; i++) {
		bs_player *me = &s->p[0], *him = &s->p[1];

		him->hp = 1000;         /* never dies, a head shot or not */
		him->script_keys = stance == CROUCH ? BL_K_CROUCH : 0;
		/* the range is the test's: kept where it stands, whatever its fight
		 * would have it do with its feet */
		me->body.pos.x = bx; me->body.pos.y = 256.5f;
		me->body.vel.x = me->body.vel.y = 0.0f;
		me->mag = 10;
		bs_step(s);
		if (me->shots > shots0) {
			bl_vec3 eye = { me->body.pos.x, me->body.pos.y, me->body.pos.z };
			bl_vec3 at = { him->body.pos.x, him->body.pos.y, him->body.pos.z };

			out->on += on_body(s, eye, me->ori, at, (him->body.keys & BC_K_CROUCH) != 0);
			shots0 = me->shots;
		}
	}
	out->shots += s->p[0].shots;
	out->hits += s->p[0].hits;
	bs_free(s);
}

static void test_stances(void)
{
	static const int levels[3] = { 1, 5, 10 };
	static const float ranges[3] = { 10.0f, 30.0f, 60.0f };
	double share[3][STANCES][2];
	int l, st, r;

	printf("a bot shoots at a man who does not shoot back: its aim on his body, and lib_bot's hits\n");
	for (l = 0; l < 3; l++) {
		for (st = 0; st < STANCES; st++) {
			tally all = { 0, 0, 0 };
			char line[200];
			int n = 0;

			n += snprintf(line + n, sizeof line - (size_t)n, "  level %2d, %-8s", levels[l], STANCE[st]);
			for (r = 0; r < 3; r++) {
				tally t = { 0, 0, 0 };
				int k;

				for (k = 0; k < 4; k++)
					duel(levels[l], st, ranges[r], 900u + (uint32_t)(k * 7 + r * 31 + l * 101), &t);
				n += snprintf(line + n, sizeof line - (size_t)n, "  %2.0f: %3d shots, %3.0f%% on, %3.0f%% hit",
				              ranges[r], t.shots, t.shots ? 100.0 * t.on / t.shots : 0.0,
				              t.shots ? 100.0 * t.hits / t.shots : 0.0);
				all.shots += t.shots; all.on += t.on; all.hits += t.hits;
			}
			printf("%s\n", line);
			share[l][st][0] = all.shots ? (double)all.on / all.shots : 0.0;
			share[l][st][1] = all.shots ? (double)all.hits / all.shots : 0.0;
			CHECK(all.shots > 20);
		}
	}
	for (l = 0; l < 3; l++) {
		/* A smaller man is hit less, as much less as he is smaller: from
		 * 0.45 over his eye to his feet a standing man is 2.7 tall, a
		 * crouched one 1.8, one wading 1.71 over the sea (feet at 64).
		 * The aim is ON him if his share of the standing man's is at
		 * least nine tenths of that. */
		const double crouched = 0.9 * 1.80 / 2.70, wading = 0.9 * 1.71 / 2.70;

		CHECK(share[l][CROUCH][0] >= crouched * share[l][STAND][0]);
		CHECK(share[l][CROUCH][1] >= crouched * share[l][STAND][1]);
		CHECK(share[l][WADE][0] >= wading * share[l][STAND][0]);
		CHECK(share[l][WADE][1] >= wading * share[l][STAND][1]);
		printf("  level %2d: on his body, of the standing man's: crouched %.2f, wading %.2f (at least %.2f, %.2f)\n",
		       levels[l], share[l][CROUCH][0] / share[l][STAND][0], share[l][WADE][0] / share[l][STAND][0],
		       crouched, wading);
	}
	/* the level model is unchanged: a better shot is a better shot */
	for (st = 0; st < STANCES; st++)
		CHECK(share[2][st][0] > share[0][st][0]);
}

int main(void)
{
	test_stances();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
