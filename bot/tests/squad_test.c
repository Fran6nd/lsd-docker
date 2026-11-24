/* squad_test.c -- leaders drawn by lot, and the bots that fall in behind
 * them (core/skill_squad.c), on the simulated server of brain_sim.h */
#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40 };
static const float EYE = (float)G - 2.25f;

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

static bs_sim *field(int max_bots)
{
	bs_sim *s = bs_new(G, max_bots);

	s->have_tents = 1;
	s->tent[0].x = 190.5f; s->tent[0].y = 256.5f; s->tent[0].z = EYE;
	s->tent[1].x = 330.5f; s->tent[1].y = 256.5f; s->tent[1].z = EYE;
	return s;
}

static int following(bs_sim *s, int pid)
{
	const bc_bot *b = bc_engine_bot(s->e, pid);
	char d[300];

	bc_engine_describe(s->e, pid, d, sizeof d);
	return b && b->squad.leader >= 0 && strstr(d, "> follow") != NULL;
}

static void test_draw(void)
{
	bs_sim *s = field(24);
	int i, t, loners = 0, loner_follows = 0, followers = 0, squads[2][BC_LEADERS_MAX], max_squad = 0;
	uint32_t seed = 1;

	printf("ten a team: leaders are drawn, squads form\n");
	memset(squads, 0, sizeof squads);
	bs_start(s);
	for (i = 0; i < 10; i++) {
		/* two of each team do not care for company */
		seed = seed_with(BC_T_TEAMWORK, i < 2 ? 0.2f : 0.9f, i < 2 ? 0.6f : 3.0f, seed + 1);
		bs_add(s, i, 1, 1, 5, i % 3, seed, 195.5f + (float)(i % 5) * 3.0f, 250.5f + (float)(i / 5) * 6.0f, 1, 0);
		bs_add(s, 100 + i, 1, 2, 5, i % 3, seed + 40000u, 325.5f - (float)(i % 5) * 3.0f, 250.5f + (float)(i / 5) * 6.0f, -1, 0);
	}
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_run(s, 3.0);
	for (t = 0; t < 2; t++)
		for (i = 0; i < 10; i++) {
			int pid = t * 100 + i, k;
			const bc_bot *b = bc_engine_bot(s->e, pid);

			if (i < 2 && t == 0) {
				loners++;
				loner_follows += b->squad.leader >= 0;
			}
			if (b->squad.leader < 0) continue;
			followers++;
			for (k = 0; k < s->e->lead[t].n; k++)
				if (s->e->lead[t].pid[k] == b->squad.leader)
					if (++squads[t][k] > max_squad) max_squad = squads[t][k];
		}
	printf("  leaders: team 1 has %d (#%d, #%d), team 2 has %d; %d bots follow one (the largest squad %d); %d of %d loners do\n",
	       s->e->lead[0].n, s->e->lead[0].pid[0], s->e->lead[0].pid[1], s->e->lead[1].n, followers, max_squad,
	       loner_follows, loners);
	CHECK(s->e->lead[0].n == 2 && s->e->lead[1].n == 2);
	CHECK(followers >= 6 && max_squad <= 4);
	CHECK(loner_follows == 0);
	/* off: nobody leads, nobody follows on that account */
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	bs_run(s, 2.0);
	for (followers = 0, i = 0; i < 10; i++)
		followers += following(s, i) + following(s, 100 + i);
	CHECK(s->e->lead[0].n == 0 && s->e->lead[1].n == 0 && followers == 0);
	bs_free(s);
}

/* a person, chosen (he is not told), walks across the map */
static void test_human(void)
{
	bs_sim *s = field(12);
	int i, k, with = 0, in_line = 0, ticks = 0, on_his_man = 0, shots = 0, idle_max = 0, idle[8] = { 0 }, left = 0;
	uint32_t seed = 500;

	printf("a person is a leader: bots fall in behind him\n");
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "leaders.human=1000");
	bs_add(s, 9, 0, 1, 5, BL_GUN_RIFLE, 1, 205.5f, 256.5f, 1, 0);
	for (i = 0; i < 5; i++) {
		seed = seed_with(BC_T_TEAMWORK, 1.0f, 3.0f, seed + 1);
		bs_add(s, i, 1, 1, 5, i % 3, seed, 198.5f, 248.5f + 4.0f * (float)i, 1, 0);
	}
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_run(s, 1.5);
	CHECK(s->e->lead[0].n == 1 && s->e->lead[0].pid[0] == 9);
	s->p[9].script_keys = BL_K_FORWARD;         /* east, 60 voxels */
	for (k = 0; k < 60 * 8; k++) {
		bs_step(s);
		for (i = 0; i < 5; i++) {
			float dx = s->p[i].body.pos.x - s->p[9].body.pos.x, dy = s->p[i].body.pos.y - s->p[9].body.pos.y;

			/* in front of his gun: within 0.8 of the line he looks along, up to 10 ahead */
			if (k > 120) {
				ticks++;
				if (dx > 0.5f && dx < 10.0f && fabsf(dy) < 0.8f) in_line++;
			}
		}
	}
	s->p[9].script_keys = 0;
	for (i = 0; i < 5; i++)
		with += bs_dist(s, i, 9) < 10.0f;
	printf("  he walked %.0f voxels: %d of 5 bots are within 10 of him; in front of his gun on %d of %d bot-ticks\n",
	       (double)(s->p[9].body.pos.x - 205.5f), with, in_line, ticks);
	CHECK(s->p[9].body.pos.x > 255.0f);
	CHECK(with >= 2 && with <= 4);
	CHECK(in_line * 20 < ticks);
	/* he shoots at a man: so do they */
	bs_add(s, 100, 0, 2, 5, BL_GUN_RIFLE, 1, s->p[9].body.pos.x + 30.0f, 262.5f, -1, 0);
	{
		float dx = 30.0f, dy = 262.5f - s->p[9].body.pos.y, l = sqrtf(dx * dx + dy * dy);

		s->p[9].ori.x = dx / l; s->p[9].ori.y = dy / l;
	}
	s->p[9].script_fire = 1;
	s->p[9].mag = 0;                            /* he pulls the trigger; the test wants THEIR rounds */
	{
		int had[5] = { 0 };

		for (k = 0; k < 60 * 4; k++) {
			s->p[100].hp = 10000;                   /* he does not die: watch whom they choose */
			s->p[9].firing = 1;
			bs_step(s);
			for (i = 0; i < 5; i++)
				had[i] |= bc_engine_bot(s->e, i)->fight.target == 100;
		}
		for (i = 0; i < 5; i++) {
			on_his_man += had[i];
			shots += s->p[i].shots;
		}
	}
	printf("  he fires at a man 30 off: %d of 5 have that man for a target, %d rounds from them in 4 s\n", on_his_man, shots);
	CHECK(on_his_man >= 2 && shots > 0);
	s->p[9].script_fire = 0;
	s->p[100].alive = 0;
	/* he is killed: nobody stands waiting for him */
	bs_run(s, 2.0);
	bs_hurt(s, 9, 200, BL_NO_PLAYER, s->w.players[0].pos, 0);
	for (k = 0; k < 60 * 12; k++) {
		bs_step(s);
		for (i = 0; i < 5; i++) {
			if (k < 120) continue;
			if ((s->intents[i].keys & 15) || s->intents[i].mouse) idle[i] = 0;
			else if (++idle[i] > idle_max) idle_max = idle[i];
		}
	}
	for (i = 0; i < 5; i++)
		left += bs_dist(s, i, 9) > 15.0f || bc_engine_bot(s->e, i)->squad.leader >= 0;
	printf("  he is killed: from 2 s on the longest any bot stands with no key down is %.1f s; %d of 5 have gone on or found another\n",
	       idle_max / 60.0, left);
	CHECK(idle_max < 60 * 4);
	CHECK(left >= 4);
	bs_free(s);
}

static void test_still(void)
{
	bs_sim *s = field(12);
	int i, at8 = 0, at50 = 0, away = 0;
	uint32_t seed = 900;

	printf("a leader who stays put is left after a while\n");
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "leaders.human=1000");
	bs_add(s, 9, 0, 1, 5, BL_GUN_RIFLE, 1, 215.5f, 256.5f, 1, 0);
	for (i = 0; i < 4; i++) {
		seed = seed_with(BC_T_TEAMWORK, 1.0f, 1.4f, seed + 1);
		bs_add(s, i, 1, 1, 5, i % 3, seed, 205.5f, 250.5f + 4.0f * (float)i, 1, 0);
	}
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_run(s, 8.0);
	for (i = 0; i < 4; i++)
		at8 += following(s, i) && bs_dist(s, i, 9) < 10.0f;
	bs_run(s, 42.0);
	for (i = 0; i < 4; i++) {
		at50 += following(s, i);
		away += bs_dist(s, i, 9) > 15.0f;
	}
	printf("  after 8 s %d of 4 hold round him; after 50 s %d still do, %d are over 15 away\n", at8, at50, away);
	CHECK(at8 >= 2);
	CHECK(at50 == 0 && away >= 3);
	bs_free(s);
}

int main(void)
{
	test_draw();
	test_human();
	test_still();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
