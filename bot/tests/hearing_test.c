/* hearing_test.c -- what a bot turns to when it hears something, on the
 * simulated server of brain_sim.h. The owner (2026-11-26): "bots turn when
 * they hear noise, even of their teammates. It should not be the case."
 *
 * A man BEHIND a bot (out of its sight) makes noises -- shots, digging,
 * building, his feet as he runs about -- and the bot's head is watched:
 * how much of the time it is turned to him. Once he is a team-mate, once an
 * enemy (who must draw the look: the test would pass on a deaf bot
 * otherwise), once nobody (the bot's own glances over a shoulder). Two
 * bots: one walking a route, one holding where it stands. */
#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40 };
static const float EYE = (float)G - 2.25f;

enum { NOBODY, MATE, ENEMY };
enum { SHOTS, DIGS, FEET, COLLAPSE, KINDS };
static const char *const KIND[KINDS] = { "shots", "digging and building", "feet", "what his digging drops" };

/* The share of ticks, from the first noise on, the bot's head is within 45
 * degrees of the man (behind it, 14 voxels back -- 5 for his feet and his
 * digging: his feet are only heard that near, a dig 6 to 14 by level), over
 * `n` bots of every level. `walk`: the bot walks a route away from him
 * (and he keeps his distance); else it holds where it stands. */
static double turned_to(int who, int kind, int walk, int n)
{
	int k, on = 0, ticks = 0;

	for (k = 0; k < n; k++) {
		bs_sim *s = bs_new(G, 4);
		float back = kind == FEET || kind == DIGS ? 5.0f : 14.0f;
		int i, team = who == ENEMY ? 2 : 1;

		s->have_tents = 1;
		s->tent[0].x = 150.5f; s->tent[0].y = 256.5f; s->tent[0].z = EYE;
		s->tent[1].x = 450.5f; s->tent[1].y = 256.5f; s->tent[1].z = EYE;
		bs_start(s);
		bs_set(s, BL_NO_PLAYER, "edit=all");
		bs_set(s, BL_NO_PLAYER, walk ? "tree=tree t:\ndo go_to enemy_base\n" : "tree=tree t:\ndo hold self 60\n");
		bs_add(s, 0, 1, 1, 1 + k % 10, BL_GUN_RIFLE, 3100u + (uint32_t)k * 41u, 250.5f, 256.5f, 1, 0);
		/* the man: a person, not a bot (nothing of his own to think) */
		bs_add(s, 1, 0, team, 5, BL_GUN_RIFLE, 1, 250.5f - back, 256.5f, 1, 0);
		if (who == NOBODY) s->p[1].used = 0;
		for (i = 0; i < 60 * 20; i++) {
			bs_player *me = &s->p[0], *him = &s->p[1];
			float dx, dy, l;

			/* he keeps behind it, at his distance */
			if (walk && who != NOBODY) {
				him->body.pos.x = me->body.pos.x - back;
				him->body.pos.y = me->body.pos.y;
			}
			/* (nobody: the noises are not made, the head is still watched
			 * toward where he would be) */
			if (who != NOBODY && i >= 60 * 2) {
				bl_vec3 at = { him->body.pos.x, him->body.pos.y, him->body.pos.z };
				int bx = (int)floorf(him->body.pos.x) - 1, by = (int)floorf(him->body.pos.y);

				if (kind == SHOTS && i % 60 == 0)
					bs_sound(s, 1, at, BL_S_SHOT);           /* fired, at nobody in particular */
				if (kind == DIGS && i % 45 == 0) {
					/* a block put beside him and dug out again */
					bs_block(s, 1, bx, by, G - 1, (i / 45) % 2 ? BL_B_BUILD : BL_B_DESTROY);
				}
				if (kind == COLLAPSE && i % 180 == 0) {
					/* a slab on a post beside him, put up (by him)... */
					int x, y, z;

					for (z = G - 1; z >= G - 3; z--)
						bs_block(s, 1, bx - 2, by + 3, z, BL_B_BUILD);
					for (y = by + 2; y <= by + 4; y++)
						for (x = bx - 3; x <= bx - 1; x++)
							bs_block(s, 1, x, y, G - 4, BL_B_BUILD);
				}
				if (kind == COLLAPSE && i % 180 == 90)
					bs_block(s, 1, bx - 2, by + 3, G - 3, BL_B_DESTROY);   /* ...and its post cut: the slab falls */
				if (kind == FEET) {
					/* running round in a circle behind it */
					float a = (float)i * 0.05f;

					him->script_keys = (uint8_t)(BL_K_FORWARD | BL_K_SPRINT);
					him->ori.x = -sinf(a); him->ori.y = cosf(a); him->ori.z = 0.0f;
				}
			}
			s->p[1].hp = 100;
			bs_step(s);
			if (i < 60 * 2) continue;
			dx = him->body.pos.x - me->body.pos.x; dy = him->body.pos.y - me->body.pos.y;
			if (who == NOBODY) { dx = -back; dy = 0.0f; }
			l = sqrtf(dx * dx + dy * dy);
			if (l < 1.0f || !me->alive) continue;
			ticks++;
			if ((dx * me->ori.x + dy * me->ori.y) / (l * sqrtf(me->ori.x * me->ori.x + me->ori.y * me->ori.y) + 1e-6f) > 0.707f)
				on++;
		}
		bs_free(s);
	}
	return ticks ? (double)on / (double)ticks : 0.0;
}

static void test_mates_noise(void)
{
	int walk, kind;

	printf("a man behind a bot makes a noise: how much of the time its head is on him\n");
	for (walk = 0; walk <= 1; walk++) {
		double none = turned_to(NOBODY, SHOTS, walk, 10);

		printf("  %s; nobody there: %.0f%% of the time anyway\n", walk ? "walking a route" : "holding", 100.0 * none);
		for (kind = 0; kind < KINDS; kind++) {
			double mate = turned_to(MATE, kind, walk, 10), enemy = turned_to(ENEMY, kind, walk, 10);

			printf("    %-21s a team-mate's: %3.0f%%   an enemy's: %3.0f%%\n", KIND[kind], 100.0 * mate, 100.0 * enemy);
			/* a team-mate's noise is no news: no more looks than with
			 * nobody there (a glance over a shoulder may still fall on
			 * him) */
			CHECK(mate <= none + 0.05);
			/* an enemy's is: the test is not passed by a deaf bot */
			CHECK(enemy >= mate + 0.15);
		}
	}
}

int main(void)
{
	test_mates_noise();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
