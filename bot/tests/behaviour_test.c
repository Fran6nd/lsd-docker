/* behaviour_test.c -- the behaviours a watcher sees, one scenario each, on
 * the simulated server of brain_sim.h: the head while travelling, cover,
 * the net under a stuck body, water that hurts, and what a bot does with
 * nothing known. Each scenario would fail without the thing it is for. */
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

/* ---------------------------------------------------------------------- */
/* the head while travelling                                              */

/* A man stands still in the angle of two walls beside the route: he can
 * only be seen from beyond him, looking back over a shoulder. */
static void look_pass(int gaze, int noise, int *saw, int *of, double *off_share, int *glances)
{
	bs_sim *s = field(4, 180.5f, 330.5f);
	int k, ticks = 0, off = 0;

	bs_box(s, 250, 240, G - 4, 250, 252, G - 1, 1);
	bs_box(s, 250, 252, G - 4, 258, 252, G - 1, 1);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\ndo go_to enemy_base\n");
	if (!gaze) bs_set(s, BL_NO_PLAYER, "gaze=0");
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 253.5f, 248.5f, 1, 0);
	*saw = *of = *glances = 0;
	for (k = 0; k < 24; k++) {
		const bc_bot *b;
		int i, seen = 0, said = 0;

		bs_add(s, 0, 1, 1, 3 + k % 7, BL_GUN_RIFLE, 4000u + (uint32_t)k * 31u, 215.5f, 256.5f, 1, 0);
		for (i = 0; i < 60 * 12; i++) {
			float vx, vy, v, ox, oy, o;

			s->p[1].hp = 100;
			bs_step(s);
			b = bc_engine_bot(s->e, 0);
			if (noise && !said && s->p[0].body.pos.x > 268.0f) {
				bs_sound(s, 1, eye_of(s, 1), BL_S_SHOT);    /* a shot, not at them: heard from 14 to 34 */
				said = 1;
			}
			if (b && b->senses.k[1].visible) seen = 1;
			vx = s->p[0].body.vel.x; vy = s->p[0].body.vel.y; v = sqrtf(vx * vx + vy * vy) * 32.0f;
			ox = s->p[0].ori.x; oy = s->p[0].ori.y; o = sqrtf(ox * ox + oy * oy);
			if (v > 3.0f && o > 0.1f && !seen) {
				ticks++;
				if ((vx * ox + vy * oy) * 32.0f / (v * o) < 0.94f) off++;    /* over 20 degrees apart */
			}
		}
		b = bc_engine_bot(s->e, 0);
		*glances += b ? (int)b->gaze.glances : 0;
		*saw += seen;
		(*of)++;
	}
	*off_share = ticks ? (double)off / (double)ticks : 0.0;
	bs_free(s);
}

static void test_look(void)
{
	double share0, share1, share2;
	int saw0, saw1, saw2, of, g0, g1, g2;

	printf("the head while travelling\n");
	look_pass(0, 0, &saw0, &of, &share0, &g0);
	look_pass(1, 0, &saw1, &of, &share1, &g1);
	printf("  a still man in a corner behind the route, 24 bots walk past:\n");
	printf("    head locked to the steering (gaze=0): %d of %d see him; facing off the heading on %.0f%% of ticks\n",
	       saw0, of, 100.0 * share0);
	printf("    head its own: %d of %d see him; facing off the heading on %.0f%% of ticks; %.1f glances a walk\n",
	       saw1, of, 100.0 * share1, (double)g1 / (double)of);
	CHECK(saw0 == 0 && g0 == 0);
	CHECK(saw1 >= of / 4);
	CHECK(share1 > 0.08 && share1 < 0.5);
	CHECK(share0 < 0.03);
	look_pass(1, 1, &saw2, &of, &share2, &g2);
	look_pass(0, 1, &saw0, &of, &share0, &g0);
	printf("    he makes a noise behind them: %d of %d see him (locked head: %d)\n", saw2, of, saw0);
	CHECK(saw2 > saw1 && saw2 >= of / 2);
	CHECK(saw0 == 0);
}

/* in the air over a trench with a man in sight beyond: the head stays on him */
static void test_aim_in_air(void)
{
	bs_sim *s = field(4, 180.5f, 300.5f);
	int i, y, air = 0, on = 0, fell = 0;

	printf("a jump with a man in sight\n");
	for (y = 0; y < 512; y++)
		bs_box(s, 240, y, G, 241, y, G + 5, 0);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\ndo go_to enemy_base\n");
	bs_add(s, 0, 1, 1, 8, BL_GUN_RIFLE, 77, 225.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 268.5f, 246.5f, -1, 0);
	for (i = 0; i < 60 * 8 && s->p[0].body.pos.x < 250.0f; i++) {
		float dx, dy, l;

		s->p[1].hp = 100;
		bs_step(s);
		if (bc_body_feet(&s->p[0].body) > (float)G + 1.5f) fell = 1;
		if (!s->p[0].body.airborne || s->p[0].body.pos.x < 239.0f || s->p[0].body.pos.x > 243.0f) continue;
		dx = s->p[1].body.pos.x - s->p[0].body.pos.x; dy = s->p[1].body.pos.y - s->p[0].body.pos.y;
		l = sqrtf(dx * dx + dy * dy);
		air++;
		if ((dx * s->p[0].ori.x + dy * s->p[0].ori.y) / l > 0.985f) on++;
	}
	printf("  over a two-wide trench: in the air %d ticks, the head within 10 degrees of him on %d; across %s\n",
	       air, on, s->p[0].body.pos.x >= 250.0f ? "yes" : "NO");
	CHECK(s->p[0].body.pos.x >= 250.0f && !fell);
	CHECK(air > 10 && on * 2 >= air);
	bs_free(s);
}

/* ---------------------------------------------------------------------- */
/* cover                                                                  */

static void test_cover(void)
{
	bs_sim *s = field(4, 180.5f, 330.5f);
	int i, hidden_at = -1, crouched_at = -1, k, faced = 0;
	const bc_bot *b;

	printf("shot at in the open\n");
	bs_box(s, 224, 252, G - 4, 224, 260, G - 1, 1);    /* a wall 6 behind it */
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tseq\n\t\tif under_fire 6\n\t\tdo crouch\n\t\tdo take_cover\n\twait 60\n");
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, seed_with(BC_T_CAUTION, 1.3f, 1.6f, 10), 230.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 275.5f, 256.5f, -1, 0);
	bs_run(s, 1.0);
	bs_hurt(s, 0, 30, 1, eye_of(s, 1), 0);
	for (i = 0; i < 60 * 8; i++) {
		s->p[1].hp = 100;
		bs_step(s);
		if (crouched_at < 0 && (s->p[0].body.keys & BC_K_CROUCH)) crouched_at = i;
		if (hidden_at < 0 && !sees(s, 1, 0) && bc_body_speed(&s->p[0].body) < 0.5f) hidden_at = i;
	}
	b = bc_engine_bot(s->e, 0);
	printf("  a wall 6 voxels behind: crouched %.2f s after the hit, at rest out of his sight after %.1f s, at %.1f %.1f; %u cells looked at\n",
	       crouched_at / 60.0, hidden_at / 60.0, (double)s->p[0].body.pos.x, (double)s->p[0].body.pos.y,
	       (unsigned)bc_engine_stats_get(s->e)->cover_cells);
	CHECK(crouched_at >= 0 && crouched_at < 20);
	CHECK(hidden_at >= 0 && hidden_at < 60 * 5);
	CHECK(s->p[0].body.pos.x < 224.0f);
	CHECK(b && bc_engine_stats_get(s->e)->cover_cells < 4000);
	bs_free(s);

	/* nothing to get behind: down where it stands, turned to the shot */
	s = field(4, 180.5f, 330.5f);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tseq\n\t\tif under_fire 6\n\t\tdo crouch\n\t\tdo take_cover\n\twait 60\n");
	bs_set(s, BL_NO_PLAYER, "sight=20");                /* he is not seen: only the hit tells */
	bs_add(s, 0, 1, 1, 9, BL_GUN_RIFLE, seed_with(BC_T_CAUTION, 1.3f, 1.6f, 10), 230.5f, 256.5f, 0, 1);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 275.5f, 256.5f, -1, 0);
	bs_run(s, 1.0);
	bs_hurt(s, 0, 30, 1, eye_of(s, 1), 0);
	crouched_at = -1;
	k = 0;
	for (i = 0; i < 60 * 3; i++) {
		bs_step(s);
		if (crouched_at < 0 && (s->p[0].body.keys & BC_K_CROUCH)) crouched_at = i;
		if (i >= 90) {
			k++;
			faced += s->p[0].ori.x > 0.9f && (s->p[0].body.keys & BC_K_CROUCH);
		}
	}
	printf("  a bare field, facing away: crouched %.2f s after the hit; crouched and turned to the shot on %d of %d ticks from 1.5 s on; moved %.1f\n",
	       crouched_at / 60.0, faced, k, (double)fabsf(s->p[0].body.pos.x - 230.5f));
	CHECK(crouched_at >= 0 && crouched_at < 20);
	CHECK(faced * 10 >= k * 8);
	CHECK(fabsf(s->p[0].body.pos.x - 230.5f) < 2.0f);
	bs_free(s);
}

/* ---------------------------------------------------------------------- */
/* the net under a stuck body                                             */

/* A pool; the land a voxel above its bed all round (a jump out), in the
 * ENGINE's map. On the server's the east bank is a voxel higher than the
 * engine knows: every route out that way is walked into and never made. */
static bs_sim *pool(int max_bots, int bad_bank)
{
	bs_sim *s = bs_new(62, max_bots);
	int x, y;

	for (y = 236; y <= 276; y++)
		for (x = 200; x <= 236; x++)
			bc_map_set(s->truth, x, y, 62, 0);      /* the sea: only 63 is solid */
	s->have_tents = 1;
	s->tent[0].x = 218.5f; s->tent[0].y = 256.5f; s->tent[0].z = 61.75f;
	s->tent[1].x = 300.5f; s->tent[1].y = 256.5f; s->tent[1].z = 59.75f;
	bs_start(s);
	if (bad_bank)
		for (y = 0; y < 512; y++)
			bc_map_set(s->truth, 237, y, 61, 1);    /* ... and the server tells nobody */
	return s;
}

static void test_stuck_in_water(void)
{
	bs_sim *s = pool(8, 1);
	const bc_engine_stats *st;
	double worst = 0.0;
	int i, k, out = 0, events = 0, keys_const = 0, longest_const = 0;
	uint8_t last_keys[8] = { 0 };
	int same[8] = { 0 };

	printf("spawned wading at the foot of a bank the follower cannot climb as planned\n");
	for (i = 0; i < 6; i++)
		bs_add(s, i, 1, 1, 3 + i, i % 3, 700u + (uint32_t)i * 13u, 226.5f + (float)(i % 2) * 3.0f, 246.5f + 4.0f * (float)i, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	for (k = 0; k < 60 * 60; k++) {
		bs_step(s);
		for (i = 0; i < 6; i++) {
			/* the same movement keys, in the same cell */
			if ((s->intents[i].keys & 15) && s->intents[i].keys == last_keys[i] && s->p[i].hold > 0.0) same[i]++;
			else same[i] = 0;
			last_keys[i] = s->intents[i].keys;
			if (same[i] > longest_const) longest_const = same[i];
		}
	}
	st = bc_engine_stats_get(s->e);
	for (i = 0; i < 6; i++) {
		if (s->p[i].worst_hold > worst) worst = s->p[i].worst_hold;
		events += s->p[i].stuck_events;
		out += !bc_map_is_water(s->truth, (int)s->p[i].body.pos.x, (int)s->p[i].body.pos.y);
	}
	(void)keys_const;
	printf("  60 s, 6 bots: longest in one cell with keys down %.1f s (the same keys: %.1f s); the net tried %u times, dropped a goal %u times;\n"
	       "  %u goals refused as known to have no way; %d of 6 are out of the water (by the other banks); %d lines in the log\n",
	       worst, longest_const / 60.0, (unsigned)st->stuck_tries, (unsigned)st->stuck_resets, (unsigned)st->unreach_hits,
	       out, s->log1_n);
	CHECK(worst < 5.0);
	CHECK(events == 0);
	CHECK(st->stuck_resets >= 1);
	CHECK(st->stuck_resets < 80);
	CHECK(out >= 4);
	bs_free(s);
}

static void test_harmful_water(void)
{
	bs_sim *s = pool(8, 0);
	char leaf[64];
	int i, k, first = 0, dry_at = -1, min_hp = 100;

	printf("spawned in water that hurts\n");
	s->water_dps = 10.0;
	bs_set(s, BL_NO_PLAYER, "water=safe");
	bs_set(s, BL_NO_PLAYER, "water.damage=10");
	for (i = 0; i < 6; i++)
		bs_add(s, i, 1, 1, 3 + i, i % 3, 900u + (uint32_t)i * 13u, 212.5f + (float)(i % 3) * 5.0f, 248.5f + 3.0f * (float)i, 1, 0);
	bs_add(s, 100, 0, 2, 5, 0, 1, 262.5f, 256.5f, -1, 0);       /* a man on the bank: he can wait */
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_run(s, 0.5);
	for (i = 0; i < 6; i++) {
		leaf_of(s, i, leaf, sizeof leaf);
		first += !strcmp(leaf, "leave_water");
	}
	for (k = 0; k < 60 * 20; k++) {
		int wet = 0;

		s->p[100].hp = 100;
		bs_step(s);
		for (i = 0; i < 6; i++)
			wet += s->p[i].alive && s->p[i].body.wade;
		if (!wet && dry_at < 0) dry_at = k;
	}
	for (i = 0; i < 6; i++)
		if (s->p[i].hp < min_hp) min_hp = s->p[i].hp;
	printf("  6 bots, 10 health a second: %d of 6 make for dry ground first; all dry after %.1f s; %d died of the water\n",
	       first, dry_at / 60.0, s->drowned);
	CHECK(first == 6);
	CHECK(dry_at >= 0 && dry_at < 60 * 8);
	CHECK(s->drowned == 0);
	bs_free(s);
}

int main(void)
{
	test_look();
	test_aim_in_air();
	test_cover();
	test_stuck_in_water();
	test_harmful_water();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
