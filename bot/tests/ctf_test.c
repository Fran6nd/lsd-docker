/* ctf_test.c -- capture the flag on the simulated server: brain_sim.h with
 * lsd/scripts/ctf.lua's rules for the two intels (see its header), the
 * tree trees/ctf.bt. */
#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40 };
static const float EYE = (float)G - 2.25f;

/* a field with walls, a base at each end, each intel beside its base */
static bs_sim *pitch(int max_bots, int walls)
{
	bs_sim *s = bs_new(G, max_bots);
	int i;

	s->have_tents = 1;
	s->tent[0].x = 205.5f; s->tent[0].y = 256.5f; s->tent[0].z = EYE;
	s->tent[1].x = 295.5f; s->tent[1].y = 256.5f; s->tent[1].z = EYE;
	for (i = 0; walls && i < 6; i++) {
		int x = 225 + i * 10, y = 236 + ((i * 17) % 40);

		bs_box(s, x, y, G - 4, x + 1, y + 6, G - 1, 1);
	}
	bs_ctf(s, 198, 264, 204, 270, 296, 242, 302, 248);
	return s;
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

typedef struct tally { char name[16][32]; int n[16], count; } tally;

static void tally_add(tally *t, const char *leaf)
{
	int i;

	for (i = 0; i < t->count && strcmp(t->name[i], leaf); i++)
		;
	if (i == t->count) {
		if (t->count == 16) return;
		snprintf(t->name[t->count++], sizeof t->name[0], "%s", leaf);
	}
	t->n[i]++;
}

static int tally_of(const tally *t, const char *leaf)
{
	int i;

	for (i = 0; i < t->count; i++)
		if (!strcmp(t->name[i], leaf)) return t->n[i];
	return 0;
}

static void tally_print(const tally *t, const char *lead)
{
	char line[500] = "";
	int i;

	for (i = 0; i < t->count; i++)
		snprintf(line + strlen(line), sizeof line - strlen(line), "%s %d  ", t->name[i][0] ? t->name[i] : "(none)", t->n[i]);
	printf("%s%s\n", lead, line);
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
	bs_set(s, BL_NO_PLAYER, "tree=ctf");
}

/* ---------------------------------------------------------------------- */

static void test_lone_capture(void)
{
	bs_sim *s = pitch(4, 1);
	char leaf[64];
	int i, picked = -1, capped = -1, carried_leaf = 0, carried = 0;

	printf("a lone bot fetches the intel and captures\n");
	bs_start(s);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 41, 207.5f, 256.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=ctf");
	for (i = 0; i < 60 * 60 && capped < 0; i++) {
		bs_step(s);
		if (picked < 0 && s->intel_holder[1] == 0) picked = i;
		if (s->intel_holder[1] == 0) {
			leaf_of(s, 0, leaf, sizeof leaf);
			carried++;
			carried_leaf += !strcmp(leaf, "carry_home");
		}
		if (s->caps[1] > 0) capped = i;
	}
	printf("  picked up after %.1f s, captured after %.1f s; 'carry_home' on %d of the %d ticks it carried; score %d-%d\n",
	       picked / 60.0, capped / 60.0, carried_leaf, carried, s->caps[1], s->caps[2]);
	CHECK(picked > 0 && capped > picked);
	CHECK(carried_leaf * 10 >= carried * 9);
	CHECK(s->p[0].stuck_events == 0);
	/* and it goes again: the intel is somewhere else in its zone now */
	bs_run(s, 40.0);
	CHECK(s->caps[1] >= 2);
	bs_free(s);
}

static void test_six_a_side(void)
{
	bs_sim *s = pitch(12, 1);
	tally before, during;
	char leaf[64];
	double worst = 0.0;
	int i, k, stuck = 0, first = -1, went = 0, guarded = 0;

	printf("6 against 6 to a first capture\n");
	memset(&before, 0, sizeof before);
	memset(&during, 0, sizeof during);
	bs_start(s);
	s->respawn = 5.0;
	teams(s, 6, 3131);
	for (k = 0; k < 60 * 240 && first < 0; k++) {
		bs_step(s);
		if (k == 60 * 4)
			for (i = 0; i < 6; i++) {
				leaf_of(s, i, leaf, sizeof leaf);
				tally_add(&before, leaf);
				went += !strcmp(leaf, "fetch") || !strcmp(leaf, "flank");
				guarded += !strcmp(leaf, "guard") || !strcmp(leaf, "camp") || !strcmp(leaf, "take_high_ground");
			}
		if (k % 30 == 0)
			for (i = 0; i < 6; i++) {
				int mine = i, t = 1;

				for (t = 1; t <= 2; t++, mine = 100 + i) {
					int h = s->intel_holder[2 - t];

					/* a team whose man carries: what the others are at */
					if (h < 0 || s->p[h].team != t || h == mine || !s->p[mine].alive) continue;
					leaf_of(s, mine, leaf, sizeof leaf);
					tally_add(&during, leaf);
				}
			}
		if (s->caps[1] + s->caps[2] > 0) first = k;
	}
	for (i = 0; i < BL_MAX_PLAYERS; i++)
		if (s->p[i].used && s->p[i].bot) {
			stuck += s->p[i].stuck_events;
			if (s->p[i].worst_hold > worst) worst = s->p[i].worst_hold;
		}
	tally_print(&before, "  team 1 after 4 s: ");
	tally_print(&during, "  the carrier's team-mates while it is carried (twice a second): ");
	printf("  first capture after %.0f s (%d-%d); pickups %d and %d, drops %d; kills %d-%d; stuck %d, longest hold %.1f s, goals dropped %u\n",
	       first / 60.0, s->caps[1], s->caps[2], s->pickups[1], s->pickups[2], s->drops, s->kills[1], s->kills[2], stuck, worst,
	       (unsigned)bc_engine_stats_get(s->e)->stuck_resets);
	/* NOT YET ASSERTED (checkpoint 2026-11-24): the teams meet in the middle
	 * and fight there; the split and the first capture are the next work */
	if (first <= 0 || went < 2 || guarded < 1 || tally_of(&during, "escort") == 0)
		printf("  NOT YET: no capture / no split (see BRAIN-STATUS.md)\n");
	CHECK(stuck == 0 && worst < 3.0);
	bs_free(s);
}

/* The carrier and a man who does it no harm, off to one side of its way
 * home: it does not stop for him. */
static void test_carrier_runs(void)
{
	double secs[2];
	int shots[2], pass;

	printf("the carrier does not stop to duel\n");
	for (pass = 0; pass < 2; pass++) {
		bs_sim *s = pitch(4, 0);
		int i, capped = -1, from = -1;

		bs_start(s);
		bs_add(s, 0, 1, 1, 6, BL_GUN_SMG, 41, 290.5f, 250.5f, -1, 0);
		if (pass) bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 250.5f, 236.5f, 0, 1);
		bs_set(s, BL_NO_PLAYER, "tree=ctf");
		for (i = 0; i < 60 * 60 && capped < 0; i++) {
			if (pass) s->p[1].hp = 100;
			bs_step(s);
			if (from < 0 && s->intel_holder[1] == 0) from = i;
			if (s->caps[1] > 0) capped = i;
		}
		secs[pass] = from >= 0 && capped >= 0 ? (capped - from) / 60.0 : -1.0;
		shots[pass] = s->p[0].shots;
		bs_free(s);
	}
	printf("  home in %.1f s with nobody about; in %.1f s with a man 20 off its line, %d rounds fired at him\n",
	       secs[0], secs[1], shots[1]);
	CHECK(secs[0] > 0.0 && secs[1] > 0.0);
	CHECK(secs[1] < secs[0] * 1.5 + 1.0);
}

static void test_thief(void)
{
	bs_sim *s = pitch(8, 0);
	char leaf[64];
	bl_vec3 start;
	float nearest_line = 1e9f;
	int i, k, hunters = 0, killed = -1, guards = 0, near_intel = 0, ahead = 0;

	printf("our intel is taken\n");
	bs_start(s);
	for (i = 0; i < 5; i++)
		bs_add(s, i, 1, 1, 5 + i % 3, i % 3, 880u + (uint32_t)i * 17u, 232.5f + 3.0f * (float)i, 236.5f + 2.0f * (float)i, 1, 0);
	/* the thief: a man walking off with it, slowly (he sneaks), for his base */
	s->intel[0].x = 215.5f; s->intel[0].y = 270.5f;
	bs_add(s, 100, 0, 2, 5, BL_GUN_RIFLE, 1, 215.5f, 271.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=ctf");
	bs_run(s, 0.5);
	CHECK(s->intel_holder[0] == 100);
	start.x = s->p[100].body.pos.x; start.y = s->p[100].body.pos.y; start.z = 0.0f;
	{
		float dx = s->tent[1].x - start.x, dy = s->tent[1].y - start.y, l = sqrtf(dx * dx + dy * dy);

		s->p[100].ori.x = dx / l; s->p[100].ori.y = dy / l; s->p[100].ori.z = 0.0f;
	}
	s->p[100].script_keys = BL_K_FORWARD | BL_K_SNEAK;
	for (k = 0; k < 60 * 40 && killed < 0; k++) {
		bs_step(s);
		if (k == 90)
			for (i = 0; i < 5; i++) {
				leaf_of(s, i, leaf, sizeof leaf);
				hunters += !strcmp(leaf, "intercept") || !strcmp(leaf, "fight");
			}
		if (k == 60 * 3)
			for (i = 0; i < 5; i++) {
				/* headed for where he is going: ahead of him on his line */
				float tx = s->p[100].body.pos.x, bx = s->p[i].body.pos.x;
				const bc_bot *b = bc_engine_bot(s->e, i);

				if (b && b->mv.goal_set && (float)b->mv.goal.x > tx + 2.0f && bx < 280.0f) ahead++;
			}
		for (i = 0; i < 5; i++) {
			float d = bs_dist(s, i, 100);

			if (d < nearest_line) nearest_line = d;
		}
		if (!s->p[100].alive) killed = k;
	}
	printf("  1.5 s after he took it %d of 5 are after him (at 3 s, %d of them heading for a place ahead of him); dead after %.1f s, %.0f from his base\n",
	       hunters, ahead, killed / 60.0, (double)(s->tent[1].x - s->p[100].body.pos.x));
	CHECK(hunters >= 2);
	if (ahead < 1) printf("  NOT YET: nobody was heading for a place ahead of him\n");
	CHECK(killed > 0);
	CHECK(s->caps[2] == 0 && s->intel_holder[0] == -1);
	/* it lies where he fell; nobody of ours can pick it up: it is watched */
	bs_run(s, 12.0);
	for (i = 0; i < 5; i++) {
		float dx = s->p[i].body.pos.x - s->intel[0].x, dy = s->p[i].body.pos.y - s->intel[0].y;

		leaf_of(s, i, leaf, sizeof leaf);
		guards += !strcmp(leaf, "guard");
		near_intel += s->p[i].alive && dx * dx + dy * dy < 12.0f * 12.0f;
	}
	printf("  12 s later the intel lies at %.0f %.0f: %d of 5 guard, %d within 12 of it\n", (double)s->intel[0].x,
	       (double)s->intel[0].y, guards, near_intel);
	CHECK(guards >= 1 && near_intel >= 1);
	bs_free(s);
}

static void test_spread(void)
{
	bs_sim *s = pitch(4, 0);
	tally quiet[3], taken;
	char leaf[64];
	int k, g, i, shown = 0, big = 0;

	printf("200 characters, nothing in sight\n");
	memset(quiet, 0, sizeof quiet);
	memset(&taken, 0, sizeof taken);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=ctf");
	bs_add(s, 9, 0, 1, 5, 0, 1, 212.5f, 262.5f, 1, 0);     /* a team-mate */
	for (k = 0; k < 200; k++) {
		bs_add(s, 0, 1, 1, 5, k % 3, 12000u + (uint32_t)k, 210.5f, 256.5f, 1, 0);
		bs_run(s, 1.0);
		leaf_of(s, 0, leaf, sizeof leaf);
		tally_add(&quiet[k % 3], leaf);
	}
	for (g = 0; g < 3; g++) {
		static const char *const gun[3] = { "rifle", "smg", "shotgun" };
		char lead[40];

		snprintf(lead, sizeof lead, "  %-8s", gun[g]);
		tally_print(&quiet[g], lead);
	}
	for (i = 0; i < quiet[0].count; i++) {
		int n = tally_of(&quiet[0], quiet[0].name[i]) + tally_of(&quiet[1], quiet[0].name[i]) +
		        tally_of(&quiet[2], quiet[0].name[i]);

		if (n >= 16) shown++;
		if (n > big) big = n;
	}
	/* NOT YET ASSERTED (checkpoint 2026-11-24): the weights are untuned */
	if (shown < 3 || big >= 150) printf("  NOT YET: the split is not spread (see BRAIN-STATUS.md)\n");
	CHECK(tally_of(&quiet[0], "fetch") + tally_of(&quiet[1], "fetch") + tally_of(&quiet[2], "fetch") >= 40);
	/* ours taken: the split shifts to the thief */
	bs_add(s, 100, 0, 2, 5, 0, 1, 255.5f, 300.5f, 1, 0);
	s->intel_holder[0] = 100;
	for (k = 0; k < 200; k++) {
		bs_add(s, 0, 1, 1, 5, k % 3, 12000u + (uint32_t)k, 210.5f, 256.5f, 1, 0);
		s->p[100].hp = 100;
		bs_run(s, 1.0);
		leaf_of(s, 0, leaf, sizeof leaf);
		tally_add(&taken, leaf);
	}
	tally_print(&taken, "  ours taken: ");
	if (tally_of(&taken, "intercept") < 100) printf("  NOT YET: the split does not shift to the thief\n");
	bs_free(s);
}

static void test_replay(void)
{
	bs_sim *s = pitch(8, 1), *r;
	int i, k, diff = 0;
	size_t at = 0;

	printf("ctf: a seed and a recorded world replay the same intents\n");
	bs_start(s);
	bs_rec_start(s, 60 * 30, 8);
	teams(s, 4, 99);
	bs_run(s, 30.0);
	r = pitch(8, 1);
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
				diff += memcmp(&r->intents[k], &s->rec_out[(size_t)i * 8 + (size_t)n], sizeof(bl_intent)) != 0;
				n++;
			}
	}
	printf("  %d thinks, 8 bots, %d pickups: %d intents differ\n", s->rec_n, s->pickups[1] + s->pickups[2], diff);
	CHECK(diff == 0);
	bs_free(r);
	bs_free(s);
}

int main(void)
{
	test_lone_capture();
	test_six_a_side();
	test_carrier_runs();
	test_thief();
	test_spread();
	test_replay();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
