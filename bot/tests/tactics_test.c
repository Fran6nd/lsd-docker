/* tactics_test.c -- what a bot does with nothing in sight, and the cover it
 * moves by: flank, hunt_noise, take_high_ground and camp, advance and fall
 * back by cover, the team's memory of what cannot be reached, a bot shut
 * in, the split of a team's choices, and a whole game of 20 a side. On the
 * simulated server of brain_sim.h. */
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

static bs_sim *field(int max_bots, float base0, float base1)
{
	bs_sim *s = bs_new(G, max_bots);

	s->have_tents = 1;
	s->tent[0].x = base0; s->tent[0].y = 256.5f; s->tent[0].z = EYE;
	s->tent[1].x = base1; s->tent[1].y = 256.5f; s->tent[1].z = EYE;
	return s;
}

static bl_vec3 eye_of(const bs_sim *s, int pid)
{
	bl_vec3 p;

	p.x = s->p[pid].body.pos.x; p.y = s->p[pid].body.pos.y; p.z = s->p[pid].body.pos.z;
	return p;
}

static int sees(const bs_sim *s, int who, int whom)
{
	return bc_sight_body(s->truth, eye_of(s, who), eye_of(s, whom), (s->p[whom].body.keys & BC_K_CROUCH) != 0);
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

/* a stepped hill a body can walk up: `h` voxels high, 3 across on top */
static void hill(bs_sim *s, int cx, int cy, int h)
{
	int k;

	for (k = 1; k <= h; k++) {
		int r = 1 + (h - k);

		bs_box(s, cx - r, cy - r, G - k, cx + r, cy + r, G - k, 1);
	}
}

/* ---------------------------------------------------------------------- */

static void test_flank(void)
{
	int side, sides[2] = { 0, 0 }, k, runs = 0, round_n = 0, behind_n = 0;
	double worst_secs = 0.0;
	float least_off = 1e9f;

	printf("flank: the long way round, from behind\n");
	for (k = 0; k < 8; k++) {
		bs_sim *s = field(4, 200.5f, 320.5f);
		float min_mid = 1e9f, last_x = 0.0f;
		int i, done = 0;
		char leaf[64];

		bs_start(s);
		bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo flank\n\twait 60\n");
		bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 300u + (uint32_t)k * 97u, 202.5f, 256.5f, 1, 0);
		for (i = 0; i < 60 * 90 && !done; i++) {
			float x, y, t;

			bs_step(s);
			x = s->p[0].body.pos.x; y = s->p[0].body.pos.y;
			t = (x - 202.5f) / 118.0f;
			if (t > 0.3f && t < 0.7f && fabsf(y - 256.5f) < min_mid) min_mid = fabsf(y - 256.5f);
			leaf_of(s, 0, leaf, sizeof leaf);
			if (i > 60 && strcmp(leaf, "flank")) done = 1;
			if (!done && fabsf(x - 320.5f) + fabsf(y - 256.5f) > 9.0f) last_x = x;
		}
		side = s->p[0].body.pos.y > 256.5f || bc_engine_bot(s->e, 0)->flank.side > 0;
		side = bc_engine_bot(s->e, 0)->flank.side > 0;
		sides[side]++;
		runs++;
		if (bs_dist(s, 0, 0) == 0.0f && fabsf(s->p[0].body.pos.x - 320.5f) < 8.0f && fabsf(s->p[0].body.pos.y - 256.5f) < 8.0f) {
			round_n++;
			if (last_x > 320.5f) behind_n++;
		}
		if (min_mid < least_off) least_off = min_mid;
		if (i / 60.0 > worst_secs) worst_secs = i / 60.0;
		bs_free(s);
	}
	printf("  8 bots, 118 voxels to the enemy's base: %d got there; nearest any came to the direct line on the middle of the way: %.0f voxels;\n"
	       "  %d came onto the base from beyond it; left %d, right %d; the slowest took %.0f s (direct: 12)\n",
	       round_n, (double)least_off, behind_n, sides[0], sides[1], worst_secs);
	CHECK(round_n == runs);
	CHECK(least_off > 20.0f);                   /* outside a corridor 40 wide on the direct line */
	CHECK(behind_n >= runs - 1);
	CHECK(sides[0] >= 1 && sides[1] >= 1);      /* by the bot's own dice */
}

static void test_hunt_noise(void)
{
	bs_sim *s = field(4, 200.5f, 330.5f);
	bl_vec3 at;
	char leaf[64];
	int i, on = 0, near = -1;
	const bc_bot *b;

	printf("hunt_noise: to where the team says they are\n");
	bs_box(s, 240, 200, G - 5, 240, 300, G - 1, 1);    /* a wall: the bot sees nothing of it */
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo hunt_noise\n\twait 1\ntree u:\nwait 60\n");
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 12, 215.5f, 256.5f, 1, 0);
	bs_add(s, 2, 1, 1, 6, BL_GUN_RIFLE, 13, 262.5f, 300.5f, 1, 0);     /* a mate beyond the wall, who sees him */
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 300.5f, 300.5f, -1, 0);
	bs_set(s, 2, "tree=u");
	at.x = 300.5f; at.y = 300.5f; at.z = EYE;
	for (i = 0; i < 60 * 40; i++) {
		s->p[1].hp = 100;
		bs_step(s);
		leaf_of(s, 0, leaf, sizeof leaf);
		on += !strcmp(leaf, "hunt_noise");
		if (near < 0 && bs_dist(s, 0, 1) < 12.0f) near = i;
	}
	b = bc_engine_bot(s->e, 0);
	printf("  a mate sees a man 95 away behind a wall: the bot is on `hunt_noise` %d ticks and within 12 of the place after %.1f s; the rumour after: %.2f\n",
	       on, near / 60.0, (double)bc_rumour((bc_bot *)(uintptr_t)b, NULL));
	(void)at;
	CHECK(on > 120);
	CHECK(near > 0);
	bs_free(s);

	/* nothing heard, nothing told: it cannot be done, and says so */
	s = field(4, 200.5f, 330.5f);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo hunt_noise\n\twait 60\n");
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 12, 215.5f, 256.5f, 1, 0);
	bs_run(s, 2.0);
	leaf_of(s, 0, leaf, sizeof leaf);
	CHECK(strcmp(leaf, "hunt_noise") != 0);
	CHECK(fabsf(s->p[0].body.pos.x - 215.5f) < 1.0f);
	bs_free(s);
}

static void test_high_ground(void)
{
	bs_sim *s = field(8, 200.5f, 330.5f);
	const bc_bot *b0, *b1;
	char leaf[64];
	int i, camp0 = 0, crouched = 0, facing = 0, ticks = 0, perches = 0, hi_shot = 0, hi_rifle = 0;
	uint32_t keen = seed_with(BC_T_MARKSMAN, 1.6f, 3.0f, 1);

	printf("take_high_ground, camp\n");
	hill(s, 245, 240, 5);
	hill(s, 250, 280, 5);
	bs_box(s, 270, 250, G - 6, 271, 251, G - 1, 1);    /* a pillar: high, a view, and no way up */
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tseq\n\t\tdo take_high_ground\n\t\tdo camp 60\n\twait 1\n");
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 21, 205.5f, 250.5f, 1, 0);
	bs_add(s, 2, 1, 1, 6, BL_GUN_RIFLE, 22, 205.5f, 262.5f, 1, 0);
	bs_run(s, 6.0);                             /* the scan of the map: a few seconds */
	for (i = 0; i < BC_PERCH_MAX; i++)
		perches += s->e->vantage[0].p[i].valid;
	for (i = 0; i < 60 * 30; i++) {
		bs_step(s);
		if (i < 60 * 20) continue;
		leaf_of(s, 0, leaf, sizeof leaf);
		ticks++;
		camp0 += !strcmp(leaf, "camp");
		crouched += (s->p[0].body.keys & BC_K_CROUCH) != 0;
		facing += s->p[0].ori.x > 0.5f;
	}
	b0 = bc_engine_bot(s->e, 0);
	b1 = bc_engine_bot(s->e, 2);
	printf("  two hills and a pillar: the team knows %d perches (%u columns looked at); the two rifles are on perches %d and %d, feet %.0f and %.0f above the ground;\n"
	       "  from 20 s on the first is on `camp` %d of %d ticks, crouched %d, facing the enemy's side %d\n",
	       perches, (unsigned)bc_engine_stats_get(s->e)->perch_columns, b0->camp.perch, b1->camp.perch,
	       (double)((float)G - bc_body_feet(&s->p[0].body)), (double)((float)G - bc_body_feet(&s->p[2].body)), camp0, ticks, crouched, facing);
	CHECK(perches == 2);                        /* not the pillar */
	CHECK(b0->camp.perch >= 0 && b1->camp.perch >= 0 && b0->camp.perch != b1->camp.perch);
	CHECK((float)G - bc_body_feet(&s->p[0].body) > 3.5f && (float)G - bc_body_feet(&s->p[2].body) > 3.5f);
	CHECK(camp0 * 10 >= ticks * 9 && crouched * 10 >= ticks * 9 && facing * 10 >= ticks * 8);
	/* a third has no perch left: it does something else */
	bs_add(s, 3, 1, 1, 6, BL_GUN_RIFLE, 23, 205.5f, 256.5f, 1, 0);
	bs_run(s, 3.0);
	leaf_of(s, 3, leaf, sizeof leaf);
	CHECK(bc_engine_bot(s->e, 3)->camp.perch < 0 && strcmp(leaf, "take_high_ground") && strcmp(leaf, "camp"));
	/* shot at: it leaves the perch */
	bs_add(s, 100, 0, 2, 5, BL_GUN_RIFLE, 1, 300.5f, 240.5f, -1, 0);
	bs_hurt(s, 0, 20, 100, eye_of(s, 100), 0);
	bs_run(s, 1.0);
	CHECK(b0->camp.perch < 0);
	bs_free(s);

	/* on the tdm tree: rifles with an eye for it go up, shotguns never */
	s = field(8, 200.5f, 330.5f);
	hill(s, 245, 240, 5);
	hill(s, 250, 280, 5);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_add(s, 9, 0, 1, 6, BL_GUN_RIFLE, 21, 180.5f, 300.5f, 1, 0);
	bs_add(s, 0, 1, 1, 6, BL_GUN_SHOTGUN, 3, 205.5f, 250.5f, 1, 0);    /* somebody, so the map is scanned */
	bs_run(s, 6.0);
	for (i = 0; i < 30; i++) {
		keen = seed_with(BC_T_MARKSMAN, 1.6f, 3.0f, keen + 1);
		bs_add(s, 0, 1, 1, 6, BL_GUN_SHOTGUN, keen, 205.5f, 250.5f, 1, 0);
		bs_run(s, 1.0);
		leaf_of(s, 0, leaf, sizeof leaf);
		hi_shot += !strcmp(leaf, "take_high_ground");
		bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, keen, 205.5f, 250.5f, 1, 0);
		bs_run(s, 1.0);
		leaf_of(s, 0, leaf, sizeof leaf);
		hi_rifle += !strcmp(leaf, "take_high_ground");
	}
	printf("  tdm, 30 marksmen: with a rifle %d go for high ground, with a shotgun %d\n", hi_rifle, hi_shot);
	CHECK(hi_shot == 0 && hi_rifle >= 12);
	bs_free(s);
}

/* a field to cross with a man watching it from one side, walls to go by */
static void cover_pass(const char *tree, int *exposed, int *ticks, double *secs)
{
	bs_sim *s = field(4, 190.5f, 300.5f);
	int i, k;

	for (k = 0; k < 6; k++)
		bs_box(s, 222 + k * 13, 263, G - 4, 229 + k * 13, 263, G - 1, 1);  /* walls south of the way, the man to the north */
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, tree);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, seed_with(BC_T_CAUTION, 0.9f, 1.1f, 40), 212.5f, 258.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 260.5f, 216.5f, 0, 1);
	*exposed = *ticks = 0;
	for (i = 0; i < 60 * 80; i++) {
		s->p[1].hp = 100;
		bs_step(s);
		(*ticks)++;
		*exposed += sees(s, 1, 0);
		if (s->p[0].body.pos.x > 296.0f) break;
	}
	*secs = s->p[0].body.pos.x > 296.0f ? i / 60.0 : -1.0;
	bs_free(s);
}

static void test_bounds(void)
{
	int e0, e1, t0, t1, i, hidden = -1;
	double s0, s1;
	bs_sim *s;
	float d0;

	printf("advance_by_cover, fall_back_by_cover\n");
	cover_pass("tree=tree t:\nselect\n\tdo go_to enemy_base\n\twait 60\n", &e0, &t0, &s0);
	cover_pass("tree=tree t:\nselect\n\tdo advance_by_cover enemy_base\n\twait 60\n", &e1, &t1, &s1);
	printf("  84 voxels across a field a man watches from the side: straight %.1f s, in his sight %.1f s; by cover %.1f s, in his sight %.1f s\n",
	       s0, e0 / 60.0, s1, e1 / 60.0);
	CHECK(s0 > 0.0 && s1 > 0.0);
	CHECK(e1 * 10 < e0 * 6);                    /* markedly less: under 60% */
	CHECK(s1 < s0 * 3.0);

	s = field(4, 190.5f, 330.5f);
	bs_box(s, 222, 250, G - 4, 222, 262, G - 1, 1);
	bs_box(s, 208, 244, G - 4, 208, 256, G - 1, 1);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo fall_back_by_cover\n\twait 60\n");
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 44, 236.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 270.5f, 256.5f, -1, 0);
	bs_run(s, 0.5);
	d0 = bs_dist(s, 0, 1);
	bs_hurt(s, 0, 30, 1, eye_of(s, 1), 0);
	for (i = 0; i < 60 * 15; i++) {
		s->p[1].hp = 100;
		bs_step(s);
		if (hidden < 0 && !sees(s, 1, 0)) hidden = i;
	}
	printf("  falling back from a man 34 away: out of his sight after %.1f s; after 15 s %s, %.0f from him, %d rounds fired\n",
	       hidden / 60.0, sees(s, 1, 0) ? "IN his sight" : "out of it", (double)bs_dist(s, 0, 1), s->p[0].shots);
	CHECK(hidden > 0 && hidden < 60 * 6);
	CHECK(!sees(s, 1, 0));
	CHECK(bs_dist(s, 0, 1) > d0 + 8.0f);
	CHECK(s->p[0].shots == 0);
	bs_free(s);
}

static void test_unreachable(void)
{
	bs_sim *s = field(8, 200.5f, 300.5f);
	const bc_engine_stats *st;
	unsigned first, all;
	int i;

	printf("a goal with no way to it is found out once, not once a bot\n");
	bs_box(s, 292, 248, G - 5, 308, 248, G - 1, 1);    /* the enemy's base, walled in */
	bs_box(s, 292, 264, G - 5, 308, 264, G - 1, 1);
	bs_box(s, 292, 248, G - 5, 292, 264, G - 1, 1);
	bs_box(s, 308, 248, G - 5, 308, 264, G - 1, 1);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	bs_set(s, BL_NO_PLAYER, "plan.cap=0");              /* searches to the end: what the memory saves */
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo go_to enemy_base\n\twait 4\n");
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 51, 262.5f, 256.5f, 1, 0);
	bs_run(s, 12.0);
	st = bc_engine_stats_get(s->e);
	first = st->plans;
	for (i = 1; i < 6; i++)
		bs_add(s, i, 1, 1, 6, BL_GUN_RIFLE, 51u + (uint32_t)i, 262.5f, 248.5f + 3.0f * (float)i, 1, 0);
	bs_run(s, 12.0);
	all = st->plans;
	printf("  one bot: %u searches in 12 s; five more join it for 12 s: %u searches more, %u goals refused from memory, %u expansions in all\n",
	       first, all - first, (unsigned)st->unreach_hits, (unsigned)st->expansions);
	CHECK(first >= 1 && first <= 6);
	CHECK(all - first <= 4);                    /* not five times the first one's */
	CHECK(st->unreach_hits >= 5);
	bs_free(s);
}

static void shut_pass(const char *edit, unsigned *plans, int *idle_max, int *out, unsigned *shut)
{
	bs_sim *s = field(4, 200.5f, 300.5f);
	int i, idle = 0;
	float lx = 0, ly = 0, lz = 0;

	bs_box(s, 226, 252, G - 5, 236, 252, G - 1, 1);    /* a box 9 across, no door */
	bs_box(s, 226, 262, G - 5, 236, 262, G - 1, 1);
	bs_box(s, 226, 252, G - 5, 226, 262, G - 1, 1);
	bs_box(s, 236, 252, G - 5, 236, 262, G - 1, 1);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_set(s, BL_NO_PLAYER, edit);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 77, 231.5f, 257.5f, 1, 0);
	*idle_max = 0;
	for (i = 0; i < 60 * 60; i++) {
		float dx, dy, dz;

		bs_step(s);
		/* idle: no key, no fire, and the head not turning */
		dx = s->p[0].ori.x - lx; dy = s->p[0].ori.y - ly; dz = s->p[0].ori.z - lz;
		if ((s->intents[0].keys & 15) || s->intents[0].mouse || dx * dx + dy * dy + dz * dz > 0.0004f) {
			idle = 0;
			lx = s->p[0].ori.x; ly = s->p[0].ori.y; lz = s->p[0].ori.z;
		} else if (++idle > *idle_max) {
			*idle_max = idle;
		}
	}
	*plans = bc_engine_stats_get(s->e)->plans;
	*shut = bc_engine_stats_get(s->e)->shut_in;
	*out = s->p[0].body.pos.x < 225.0f || s->p[0].body.pos.x > 237.0f || s->p[0].body.pos.y < 251.0f || s->p[0].body.pos.y > 263.0f;
	bs_free(s);
}

static void test_shut_in(void)
{
	unsigned plans, shut, plans2, shut2;
	int idle, out, idle2, out2;

	printf("a bot shut in a box with no door\n");
	shut_pass("edit=none", &plans, &idle, &out, &shut);
	shut_pass("edit=dig", &plans2, &idle2, &out2, &shut2);
	printf("  60 s: %u searches for a route (found shut in %u times); the longest it did nothing at all (no key, no round, head still): %.1f s\n"
	       "  with digging allowed: %s, %u searches\n", plans, shut, idle / 60.0, out2 ? "it dug its way out" : "STILL INSIDE", plans2);
	CHECK(!out);
	CHECK(plans <= 20);
	CHECK(shut >= 1);
	CHECK(idle < 60 * 4);
	CHECK(out2);
}

/* ON A ROOF WITH NO WAY DOWN (the owner's live case, 2026-11-25): a hollow
 * tower 14 high, nothing inside to land on, the bot on its roof. With no
 * edits it must not pace the edge or keep asking for routes: it holds and
 * watches, and shoots what comes into sight. With edits it gets down. */
static void roof_pass(const char *edit, int enemy, unsigned *plans, int *on_roof, int *keys_ticks,
                      int *hold_ticks, int *shots, double *down_at, int *hp)
{
	bs_sim *s = field(4, 200.5f, 300.5f);
	char leaf[64];
	int i;

	bs_box(s, 226, 254, G - 14, 230, 258, G - 1, 1);
	bs_box(s, 227, 255, G - 13, 229, 257, G - 1, 0);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	bs_set(s, BL_NO_PLAYER, edit);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 77, 228.5f, 256.5f, 1, 0);
	bc_body_place(&s->p[0].body, s->truth, 228.5f, 256.5f, G - 14, 0);
	*keys_ticks = *hold_ticks = 0;
	*down_at = -1.0;
	for (i = 0; i < 60 * 60; i++) {
		if (enemy && i == 60 * 40)
			bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 250.5f, 256.5f, -1, 0);
		if (enemy && i > 60 * 40) s->p[1].hp = 100;
		bs_step(s);
		if (*down_at < 0.0 && bc_body_feet(&s->p[0].body) > (float)G - 0.5f) *down_at = i / 60.0;
		if (i >= 60 * 10 && i < 60 * 40) {
			*keys_ticks += (s->intents[0].keys & 15) != 0;
			leaf_of(s, 0, leaf, sizeof leaf);
			*hold_ticks += !strcmp(leaf, "hold");
		}
	}
	*plans = bc_engine_stats_get(s->e)->plans;
	*on_roof = bc_body_feet(&s->p[0].body) < (float)G - 13.0f;
	*shots = s->p[0].shots;
	*hp = s->p[0].hp;
	bs_free(s);
}

static void test_roof(void)
{
	unsigned plans, plans2;
	int on, on2, keys, keys2, hold, hold2, shots, shots2, hp, hp2;
	double down, down2;

	printf("a bot on a roof with no way down\n");
	roof_pass("edit=none", 1, &plans, &on, &keys, &hold, &shots, &down, &hp);
	printf("  no edits, 60 s: %u searches for a route; still on the roof: %s; from 10 to 40 s a movement key down on %d of 1800 ticks, `hold` on %d;\n"
	       "  a man in sight from 40 s: %d rounds fired at him\n", plans, on ? "yes" : "NO", keys, hold, shots);
	CHECK(on && hp == 100);
	CHECK(plans <= 12);
	CHECK(keys < 1800 / 10);
	CHECK(hold > 1800 * 8 / 10);
	CHECK(shots > 0);
	roof_pass("edit=all", 0, &plans2, &on2, &keys2, &hold2, &shots2, &down2, &hp2);
	printf("  digging and building allowed: on the ground after %.1f s, health %d, %u searches\n", down2, hp2, plans2);
	CHECK(down2 > 0.0 && down2 < 30.0 && hp2 == 100);
}

/* 200 characters, nothing in sight: what each sets out to do */
static void test_split(void)
{
	static const char *const what[5] = { "flank", "hunt_noise", "take_high_ground", "follow", "seek" };
	static const char *const gun[3] = { "rifle", "smg", "shotgun" };
	bs_sim *s = field(8, 200.5f, 330.5f);
	int n[3][5], arch[BC_A_COUNT][5], arch_n[BC_A_COUNT], k, g, w, other = 0, total[5] = { 0 };
	char leaf[64];

	printf("200 characters with nothing in sight (a perch free, a rumour, a leader about)\n");
	memset(n, 0, sizeof n);
	memset(arch, 0, sizeof arch);
	memset(arch_n, 0, sizeof arch_n);
	hill(s, 245, 240, 5);
	hill(s, 250, 280, 5);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_add(s, 8, 0, 1, 5, 0, 1, 204.5f, 262.5f, 1, 0);      /* two team-mates: one of them leads */
	bs_add(s, 9, 0, 1, 5, 0, 1, 206.5f, 250.5f, 1, 0);
	bs_add(s, 0, 1, 1, 5, 0, 3, 205.5f, 256.5f, 1, 0);
	bs_run(s, 6.0);                             /* the perches are found */
	for (k = 0; k < 200; k++) {
		const bc_bot *b;

		bs_add(s, 0, 1, 1, 5, k % 3, 7000u + (uint32_t)k, 205.5f, 256.5f, 1, 0);
		bs_run(s, 0.1);
		s->e->hot[0].x = 300.5f; s->e->hot[0].y = 290.5f; s->e->hot[0].z = EYE;     /* the team met them there, 20 s ago */
		s->e->hot_at[0] = s->e->now - 20.0;
		bs_run(s, 1.2);
		b = bc_engine_bot(s->e, 0);
		leaf_of(s, 0, leaf, sizeof leaf);
		for (w = 0; w < 5 && strcmp(leaf, what[w]); w++)
			;
		arch_n[b->persona.archetype]++;
		if (w == 5) { other++; continue; }
		n[k % 3][w]++;
		arch[b->persona.archetype][w]++;
		total[w]++;
	}
	for (g = 0; g < 3; g++)
		printf("  %-8s flank %2d  hunt_noise %2d  take_high_ground %2d  follow %2d  seek %2d\n", gun[g], n[g][0], n[g][1],
		       n[g][2], n[g][3], n[g][4]);
	printf("  all      flank %2d  hunt_noise %2d  take_high_ground %2d  follow %2d  seek %2d  (something else: %d)\n", total[0],
	       total[1], total[2], total[3], total[4], other);
	printf("  flankers: %d of %d flank; campers: %d of %d go high; pushers: %d of %d seek; supports: %d of %d follow; scouts: %d of %d hunt\n",
	       arch[BC_A_FLANKER][0], arch_n[BC_A_FLANKER], arch[BC_A_CAMPER][2], arch_n[BC_A_CAMPER], arch[BC_A_PUSHER][4],
	       arch_n[BC_A_PUSHER], arch[BC_A_SUPPORT][3], arch_n[BC_A_SUPPORT], arch[BC_A_SCOUT][1], arch_n[BC_A_SCOUT]);
	for (w = 0; w < 5; w++) {
		CHECK(total[w] >= (w == 2 ? 8 : 14));   /* each by 7% or more (high ground, which a third cannot take: 4%) */
		CHECK(total[w] <= 90);                  /* none by nearly half */
	}
	CHECK(n[2][2] == 0);                        /* a shotgun does not go high */
	CHECK(n[0][2] > n[1][2]);                   /* a rifle more than an smg */
	CHECK(arch[BC_A_FLANKER][0] * 2 > arch_n[BC_A_FLANKER]);
	CHECK(arch[BC_A_PUSHER][4] * 2 > arch_n[BC_A_PUSHER]);
	bs_free(s);
}

/* twenty a side on a field of walls: to a result, nobody stuck, nobody
 * standing about */
static void test_twenty(void)
{
	bs_sim *s = bs_new(G, 40);
	static const char *const waits[] = { "take_cover", "camp", "hold", "guard", "crouch", "follow", "look_around",
		"investigate", "throw_grenade", NULL };
	int i, k, stuck = 0, idle[256] = { 0 }, idle_max = 0, idle_who = -1, a1 = 20, a2 = 20;
	float lx[256], ly[256];
	double worst = 0.0, t;
	char leaf[64], idle_leaf[64] = "";
	const bc_engine_stats *st;

	printf("twenty against twenty\n");
	memset(lx, 0, sizeof lx);
	memset(ly, 0, sizeof ly);
	s->have_tents = 1;
	s->tent[0].x = 190.5f; s->tent[0].y = 256.5f; s->tent[0].z = EYE;
	s->tent[1].x = 320.5f; s->tent[1].y = 256.5f; s->tent[1].z = EYE;
	for (i = 0; i < 40; i++) {
		int x = 206 + (i % 8) * 13 + (i * 5) % 7, y = 206 + (i / 8) * 21 + (i * 11) % 9;

		if (i % 2) bs_box(s, x, y, G - 4, x, y + 6, G - 1, 1);
		else bs_box(s, x, y, G - 4, x + 6, y, G - 1, 1);
	}
	bs_start(s);
	for (i = 0; i < 20; i++) {
		bs_add(s, i, 1, 1, 3 + (i * 3) % 7, i % 3, 2026u + (uint32_t)i * 7919u, 192.5f + (float)(i % 4) * 2.5f, 232.5f + 2.5f * (float)i, 1, 0);
		bs_add(s, 100 + i, 1, 2, 3 + (i * 5) % 7, (i + 1) % 3, 2526u + (uint32_t)i * 104729u, 318.5f - (float)(i % 4) * 2.5f, 232.5f + 2.5f * (float)i, -1, 0);
	}
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	for (k = 0; k < 60 * 600 && a1 > 0 && a2 > 0; k++) {
		bs_step(s);
		a1 = a2 = 0;
		for (i = 0; i < BL_MAX_PLAYERS; i++) {
			float dx, dy;
			int w;

			if (!s->p[i].used || !s->p[i].alive) { idle[i] = 0; continue; }
			if (s->p[i].team == 1) a1++; else a2++;
			dx = s->p[i].ori.x - lx[i]; dy = s->p[i].ori.y - ly[i];
			if ((s->intents[i].keys & 15) || s->intents[i].mouse || dx * dx + dy * dy > 0.0004f) {
				idle[i] = 0;
				lx[i] = s->p[i].ori.x; ly[i] = s->p[i].ori.y;
				continue;
			}
			if (++idle[i] < 120 || idle[i] % 30) continue;
			/* two seconds of nothing: is it waiting on purpose? */
			leaf_of(s, i, leaf, sizeof leaf);
			for (w = 0; waits[w] && strcmp(leaf, waits[w]); w++)
				;
			if (waits[w]) continue;
			if (idle[i] > idle_max) { idle_max = idle[i]; idle_who = i; snprintf(idle_leaf, sizeof idle_leaf, "%s", leaf); }
		}
	}
	t = k / 60.0;
	for (i = 0; i < BL_MAX_PLAYERS; i++)
		if (s->p[i].used) {
			stuck += s->p[i].stuck_events;
			if (s->p[i].worst_hold > worst) worst = s->p[i].worst_hold;
		}
	st = bc_engine_stats_get(s->e);
	printf("  over after %.0f s: %d and %d left, kills %d-%d; stuck %d, longest in one cell with keys down %.1f s; goals dropped %u;\n"
	       "  the longest any bot did nothing (no key, no round, head still, and not in cover, camping or holding): %.1f s%s%s;\n"
	       "  think %.0f us a call, worst %.0f us; %u plans, %u stopped at the cap, %u found no way\n",
	       t, a1, a2, s->kills[1], s->kills[2], stuck, worst, (unsigned)st->stuck_resets, idle_max / 60.0,
	       idle_who >= 0 ? " on " : "", idle_leaf, s->think_us / (double)s->thinks, s->think_max_us, (unsigned)st->plans,
	       (unsigned)st->plan_caps, (unsigned)st->plan_fails);
	CHECK(a1 == 0 || a2 == 0);
	CHECK(stuck == 0);
	CHECK(idle_max < 60 * 5);
	bs_free(s);
}

/* A ROLE THAT LASTS (tdm.bt, `pick roll=once`): forty bots, five minutes,
 * everybody dying and coming back. A bot is a camper or it is not, in its
 * first life and in its last; no shotgun is one; and a camper with
 * nothing else on its hands is on a perch or on its way to one. */
static void test_roles(void)
{
	enum { PER = 20, SECS = 300 };
	bs_sim *s = field(2 * PER, 120.5f, 400.5f);     /* far apart: there is time between fights */
	int pid[2 * PER], role[2 * PER], roles_seen[2 * PER], changed = 0, campers = 0, shot_campers = 0, by_gun[3] = {0, 0, 0};
	int camper_gun[3] = {0, 0, 0}, i, k, t, idle = 0, idle_perch = 0, lives = 0, camped_first[2 * PER], camped_last[2 * PER];
	uint32_t life[2 * PER];

	printf("roles that last: 40 bots, 5 minutes, respawning\n");
	for (k = 0; k < 8; k++) {                   /* hills all along the field, either side of the way */
		hill(s, 150 + k * 32, 226 + (k % 2) * 10, 5);
		hill(s, 156 + k * 32, 288 - (k % 2) * 10, 5);
	}
	bs_start(s);
	s->respawn = 3.0;
	for (i = 0; i < PER; i++) {
		float y = 206.5f + 5.0f * (float)i;

		pid[i] = i; pid[PER + i] = 100 + i;
		bs_add(s, i, 1, 1, 3 + (i * 3) % 7, i % 3, 31000u + (uint32_t)i * 7919u, 122.5f + (float)(i % 3) * 2.0f, y, 1, 0);
		bs_add(s, 100 + i, 1, 2, 3 + (i * 5) % 7, (i + 1) % 3, 47000u + (uint32_t)i * 104729u, 398.5f - (float)(i % 3) * 2.0f, y, -1, 0);
	}
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	for (i = 0; i < 2 * PER; i++) { role[i] = -1; roles_seen[i] = 0; camped_first[i] = camped_last[i] = -1; life[i] = 0; }
	for (t = 0; t < SECS * 2; t++) {
		bs_run(s, 0.5);
		for (i = 0; i < 2 * PER; i++) {
			const bc_bot *b = bc_engine_bot(s->e, pid[i]);
			bt_tree tr;
			bt_node n, opt;
			bt_node_state ns;
			char leaf[64];
			int j, top = -1, roll = -1, now, on_duty = 0, camping;

			if (s->w.players[pid[i]].life != life[i]) { life[i] = s->w.players[pid[i]].life; lives++; }
			if (!b || !b->alive || !b->forest || !bt_forest_tree(b->forest, b->tree, &tr)) continue;
			/* the tree's first pick is the list of reactions; its first pick that rolls, the role */
			for (j = tr.root; bt_forest_node(b->forest, j, &n) && n.tree == b->tree && roll < 0; j++) {
				if (n.kind != BT_K_PICK) continue;
				if (top < 0) top = j;
				if (n.roll) roll = j;
			}
			if (roll < 0 || top < 0) continue;
			bt_state_node(b->forest, b->bt, top, &ns);
			if (ns.child >= 0 && bt_forest_node(b->forest, ns.child, &opt)) on_duty = !strcmp(opt.name, "always");
			bt_state_node(b->forest, b->bt, roll, &ns);
			if (ns.child < 0) continue;                 /* not drawn in this life yet */
			bt_forest_node(b->forest, ns.child, &opt);
			now = !strcmp(opt.name, "gun_is");          /* 1: a camper */
			if (role[i] >= 0 && role[i] != now) changed++;
			role[i] = now;
			roles_seen[i]++;
			if (camped_first[i] < 0) camped_first[i] = now;
			camped_last[i] = now;
			leaf_of(s, pid[i], leaf, sizeof leaf);
			camping = !strcmp(leaf, "take_high_ground") || !strcmp(leaf, "camp");
			if (camping && !now) changed += 1000;       /* nobody camps who is not a camper */
			if (now && on_duty) { idle++; idle_perch += camping; }
		}
	}
	for (i = 0; i < 2 * PER; i++) {
		int gun = s->p[pid[i]].gun;

		by_gun[gun]++;
		CHECK(roles_seen[i] > 20);
		CHECK(camped_first[i] == camped_last[i] && camped_first[i] >= 0);
		if (role[i] == 1) { campers++; camper_gun[gun]++; shot_campers += gun == BL_GUN_SHOTGUN; }
	}
	printf("  %d lives lived (%d kills); campers: %d of 40 -- %d of %d rifles, %d of %d smgs, %d of %d shotguns; a role changed %d times;\n"
	       "  a camper with nothing else on its hands was on a perch or going to one %d%% of the time (%d of %d half-seconds)\n",
	       lives, s->kills[1] + s->kills[2], campers, camper_gun[0], by_gun[0], camper_gun[1], by_gun[1], camper_gun[2], by_gun[2],
	       changed, idle ? 100 * idle_perch / idle : 0, idle_perch, idle);
	CHECK(lives > 100);                         /* everybody died, more than once */
	CHECK(changed == 0);
	CHECK(shot_campers == 0 && camper_gun[2] == 0);
	CHECK(campers >= 3 && campers <= 14);       /* about one in six of forty */
	CHECK(idle > 60 && idle_perch * 2 > idle);  /* most of its idle time */
	bs_free(s);
}

int main(void)
{
	test_flank();
	test_hunt_noise();
	test_high_ground();
	test_bounds();
	test_unreachable();
	test_shut_in();
	test_roof();
	test_split();
	test_twenty();
	test_roles();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
