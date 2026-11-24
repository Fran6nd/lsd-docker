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
	CHECK(share1 > 0.03 && share1 < 0.2);      /* its own head, but on the heading first (2026-11-25: was 0.08 to 0.5) */
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

/* SHOT AT, THE OWNER'S RULE: no turning the back to go looking for cover.
 * Cover it can see as it faces him, reached with the head on him; none in
 * view, it faces him where it is. The shipped trees' branch, written out. */
static const char COVER_FACING[] =
	"tree=tree t:\nselect\n\tseq\n\t\tif under_fire 6\n\t\tdo crouch\n\t\tselect\n\t\t\tseq\n\t\t\t\tif cover_in_view\n"
	"\t\t\t\tdo take_cover in_view\n\t\t\tdo crouch 3\n\twait 60\n";

static float facing_cos(const bs_sim *s, int pid, bl_vec3 at)
{
	float dx = at.x - s->p[pid].body.pos.x, dy = at.y - s->p[pid].body.pos.y, l = sqrtf(dx * dx + dy * dy);
	float ox = s->p[pid].ori.x, oy = s->p[pid].ori.y, o = sqrtf(ox * ox + oy * oy);

	return l > 1e-3f && o > 1e-3f ? (dx * ox + dy * oy) / (l * o) : 1.0f;
}

static void test_cover_in_view(void)
{
	bs_sim *s;
	bl_vec3 th;
	int i, ticks, on, moving, moving_on, hidden_at, turned_at;
	float moved_before_turn = 0.0f, minx;

	printf("shot at: cover in view, facing him\n");

	/* (1) from the front, the only cover behind it */
	s = field(4, 180.5f, 330.5f);
	bs_box(s, 224, 252, G - 4, 224, 260, G - 1, 1);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, COVER_FACING);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, seed_with(BC_T_CAUTION, 1.3f, 1.6f, 10), 230.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 275.5f, 256.5f, -1, 0);
	bs_run(s, 1.0);
	th = eye_of(s, 1);
	bs_hurt(s, 0, 30, 1, th, 0);
	ticks = on = 0;
	minx = 1e9f;
	for (i = 0; i < 60 * 4; i++) {
		s->p[1].hp = 100;
		bs_step(s);
		if (s->p[0].body.pos.x < minx) minx = s->p[0].body.pos.x;
		if (i < 30) continue;
		ticks++;
		on += facing_cos(s, 0, th) > 0.707f;
	}
	printf("  from the front, cover only behind: head within 45 degrees of him on %d of %d ticks; it went back to x %.1f (the wall is at 224)\n",
	       on, ticks, (double)minx);
	CHECK(on * 10 >= ticks * 9);
	CHECK(minx > 227.0f);
	bs_free(s);

	/* (2) cover in view, to the side ahead */
	s = field(4, 180.5f, 330.5f);
	bs_box(s, 240, 258, G - 4, 240, 266, G - 1, 1);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, COVER_FACING);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, seed_with(BC_T_CAUTION, 1.3f, 1.6f, 10), 230.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 275.5f, 256.5f, -1, 0);
	bs_run(s, 1.0);
	th = eye_of(s, 1);
	bs_hurt(s, 0, 30, 1, th, 0);
	moving = moving_on = 0;
	hidden_at = -1;
	for (i = 0; i < 60 * 6; i++) {
		s->p[1].hp = 100;
		bs_step(s);
		if (bc_body_speed(&s->p[0].body) > 1.0f) {
			moving++;
			moving_on += facing_cos(s, 0, th) > 0.707f;
		}
		if (hidden_at < 0 && !sees(s, 1, 0) && bc_body_speed(&s->p[0].body) < 0.5f) hidden_at = i;
	}
	printf("  cover ahead to the side: out of his sight and at rest after %.1f s, at %.1f %.1f; moving %d ticks, the head within 45 degrees of him on %d\n",
	       hidden_at / 60.0, (double)s->p[0].body.pos.x, (double)s->p[0].body.pos.y, moving, moving_on);
	CHECK(hidden_at >= 0 && hidden_at < 60 * 5);
	CHECK(s->p[0].body.pos.x > 230.5f && s->p[0].body.pos.x < 240.0f && s->p[0].body.pos.y > 258.0f);     /* ahead and across, not back */
	CHECK(moving > 10 && moving_on * 10 >= moving * 8);
	bs_free(s);

	/* (3) hit from behind by a man it never saw: it turns to him first */
	s = field(4, 180.5f, 330.5f);
	bs_box(s, 221, 258, G - 4, 221, 266, G - 1, 1);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, COVER_FACING);
	bs_set(s, BL_NO_PLAYER, "sight=20");
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, seed_with(BC_T_CAUTION, 1.3f, 1.6f, 10), 230.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 185.5f, 256.5f, 1, 0);
	bs_run(s, 1.0);
	th = eye_of(s, 1);
	bs_hurt(s, 0, 30, 1, th, 0);
	turned_at = hidden_at = -1;
	for (i = 0; i < 60 * 6; i++) {
		float dx, dy;

		bs_step(s);
		dx = s->p[0].body.pos.x - 230.5f; dy = s->p[0].body.pos.y - 256.5f;
		if (turned_at < 0) {
			moved_before_turn = sqrtf(dx * dx + dy * dy);
			if (facing_cos(s, 0, th) > 0.707f) turned_at = i;
		}
		if (hidden_at < 0 && !sees(s, 1, 0) && bc_body_speed(&s->p[0].body) < 0.5f) hidden_at = i;
	}
	printf("  hit from behind, unseen: turned to him after %.2f s, having moved %.1f; in cover in view after %.1f s, at %.1f %.1f\n",
	       turned_at / 60.0, (double)moved_before_turn, hidden_at / 60.0, (double)s->p[0].body.pos.x, (double)s->p[0].body.pos.y);
	CHECK(turned_at >= 0 && turned_at < 90);       /* a turn round: reaction and the turn */
	CHECK(moved_before_turn < 1.0f);
	CHECK(hidden_at >= 0 && s->p[0].body.pos.x < 230.0f && s->p[0].body.pos.x > 221.0f);
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
	CHECK(out >= 2);                            /* some find the banks that can be climbed */
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

/* ---------------------------------------------------------------------- */
/* waiting for the planner                                                */

/* Two islands in a sea, both bases out in the water (as on prisonbreakv1,
 * where forty bots stood "frozen" after the map loaded: 80% of all
 * bot-time with no key down, 96% of it waiting for a route). `old` plans
 * as before: exact searches run to their end. */
static void sea_pass(int old, double *idle_share, double *wait_share, double *longest_wait, int *keys7, double *exp_plan,
                     unsigned *plans, int *stuck)
{
	bs_sim *s = bs_new(62, 40);
	const bc_engine_stats *st;
	long alive = 0, idle = 0, waiting = 0;
	int x, y, i, k, spell[256] = { 0 }, worst = 0;

	for (y = 0; y < 512; y++)
		for (x = 0; x < 512; x++)
			if (!((x >= 140 && x <= 260 && y >= 190 && y <= 320) || (x >= 300 && x <= 380 && y >= 200 && y <= 300)))
				bc_map_set(s->truth, x, y, 62, 0);
	for (i = 0; i < 30; i++) {
		/* things to walk round on the islands */
		int wx = 150 + (i * 37) % 100 + (i % 2) * 150 % 220, wy = 200 + (i * 53) % 90;

		if (wx > 262 && wx < 300) wx += 40;
		if (wx < 372) bs_box(s, wx, wy, 58, wx + (i % 2 ? 0 : 6), wy + (i % 2 ? 6 : 0), 61, 1);
	}
	s->have_tents = 1;
	s->tent[0].x = 100.5f; s->tent[0].y = 256.5f; s->tent[0].z = 61.75f;
	s->tent[1].x = 440.5f; s->tent[1].y = 256.5f; s->tent[1].z = 61.75f;
	bs_start(s);
	s->respawn = 4.0;
	if (old) {
		bs_set(s, BL_NO_PLAYER, "plan.cap=0");
		bs_set(s, BL_NO_PLAYER, "plan.greed=1");
		bs_set(s, BL_NO_PLAYER, "plan.wait=stand");
	}
	for (i = 0; i < 20; i++) {
		bs_add(s, i, 1, 1, 3 + (i * 3) % 7, i % 3, 61u + (uint32_t)i * 7919u, 120.5f + (float)(i % 5) * 9.0f, 215.5f + (float)(i / 5) * 24.0f, 1, 0);
		bs_add(s, 100 + i, 1, 2, 3 + (i * 5) % 7, (i + 1) % 3, 561u + (uint32_t)i * 104729u, 400.5f - (float)(i % 5) * 9.0f, 215.5f + (float)(i / 5) * 22.0f, -1, 0);
	}
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	*keys7 = 0;
	for (k = 0; k < 60 * 30; k++) {
		bs_step(s);
		for (i = 0; i < BL_MAX_PLAYERS; i++) {
			const bc_bot *b;

			if (!s->p[i].used || !s->p[i].alive) { spell[i] = 0; continue; }
			b = bc_engine_bot(s->e, i);
			alive++;
			if (k == 60 * 7) *keys7 += (s->intents[i].keys & 15) != 0;
			if ((s->intents[i].keys & 15) || s->intents[i].mouse) { spell[i] = 0; continue; }
			idle++;
			if (b && b->mv.state == BC_MV_PLANNING && b->wish.move == BC_MOVE_GOTO) {
				waiting++;
				if (++spell[i] > worst) worst = spell[i];
			} else {
				spell[i] = 0;
			}
		}
	}
	st = bc_engine_stats_get(s->e);
	*idle_share = (double)idle / (double)alive;
	*wait_share = (double)waiting / (double)alive;
	*longest_wait = worst / 60.0;
	*exp_plan = st->plans ? (double)st->expansions / (double)st->plans : 0.0;
	*plans = st->plans;
	*stuck = 0;
	for (i = 0; i < BL_MAX_PLAYERS; i++)
		if (s->p[i].used) *stuck += s->p[i].stuck_events;
	bs_free(s);
}

static void test_waiting_for_routes(void)
{
	double idle, wait, longest, expp;
	unsigned plans;
	int keys7, stuck;

	printf("forty bots on two islands in a sea, the bases out in the water\n");
	sea_pass(1, &idle, &wait, &longest, &keys7, &expp, &plans, &stuck);
	printf("  as it was (plan.cap=0, plan.greed=1, plan.wait=stand): %u plans in 30 s, %.0f expansions each; 7 s after the start %d of 40 hold a key;\n"
	       "    no key down %.0f%% of the time, standing waiting for a route %.1f%% (longest %.1f s)\n",
	       plans, expp, keys7, 100.0 * idle, 100.0 * wait, longest);
	CHECK(wait > 0.3 && keys7 < 20);            /* the scene does freeze bots that plan as before */
	sea_pass(0, &idle, &wait, &longest, &keys7, &expp, &plans, &stuck);
	printf("  as shipped: %u plans in 30 s, %.0f expansions each; 7 s after the start %d of 40 hold a key;\n"
	       "    no key down %.0f%% of the time, standing waiting for a route %.1f%% (longest %.1f s); stuck %d\n",
	       plans, expp, keys7, 100.0 * idle, 100.0 * wait, longest, stuck);
	CHECK(keys7 >= 30);
	CHECK(wait < 0.03);
	CHECK(longest < 3.0);
	CHECK(idle < 0.25);
	CHECK(stuck == 0);
}

/* ---------------------------------------------------------------------- */
/* a search stopped at its cap, in a maze                                 */

static void maze_pass(const char *cap, double *secs, unsigned *caps, unsigned *plans, unsigned *fails, int *stuck)
{
	bs_sim *s = field(4, 180.5f, 260.5f);
	int i, k;

	/* a serpentine: five walls right across a pen 48 wide, a gap at
	 * alternate ends; the pen is walled in */
	bs_box(s, 198, 226, G - 4, 250, 226, G - 1, 1);
	bs_box(s, 198, 286, G - 4, 250, 286, G - 1, 1);
	bs_box(s, 198, 226, G - 4, 198, 286, G - 1, 1);
	bs_box(s, 250, 226, G - 4, 250, 286, G - 1, 1);
	for (i = 0; i < 5; i++) {
		int x = 206 + i * 8;

		if (i % 2) bs_box(s, x, 227, G - 4, x, 281, G - 1, 1);
		else bs_box(s, x, 231, G - 4, x, 285, G - 1, 1);
	}
	s->tent[1].x = 246.5f; s->tent[1].y = 282.5f;       /* the far corner of the pen */
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\ndo go_to enemy_base\n");
	bs_set(s, BL_NO_PLAYER, cap);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 5, 202.5f, 282.5f, 1, 0);
	for (k = 0; k < 60 * 180; k++) {
		float dx, dy;

		bs_step(s);
		dx = s->p[0].body.pos.x - s->tent[1].x; dy = s->p[0].body.pos.y - s->tent[1].y;
		if (dx * dx + dy * dy < 3.0f * 3.0f) break;
	}
	*secs = k < 60 * 180 ? k / 60.0 : -1.0;
	*caps = bc_engine_stats_get(s->e)->plan_caps;
	*plans = bc_engine_stats_get(s->e)->plans;
	*fails = bc_engine_stats_get(s->e)->plan_fails;
	*stuck = s->p[0].stuck_events;
	bs_free(s);
}

static void test_capped_in_a_maze(void)
{
	double exact, capped;
	unsigned caps, plans, fails, c0, p0, f0;
	int stuck, s0;

	printf("a route through a maze, the search stopped at its cap\n");
	maze_pass("plan.cap=0", &exact, &c0, &p0, &f0, &s0);
	maze_pass("plan.cap=400", &capped, &caps, &plans, &fails, &stuck);
	printf("  a serpentine of five walls, 330 voxels of way: there in %.1f s with searches run to their end (%u plans);\n"
	       "  with a cap of 400 expansions in %.1f s: %u plans, %u of them stopped at the cap, %u found no way; stuck %d\n",
	       exact, p0, capped, plans, caps, fails, stuck);
	CHECK(exact > 0.0 && c0 == 0);
	CHECK(capped > 0.0);                        /* it gets there all the same */
	CHECK(caps >= 1);                           /* and the cap did bite */
	CHECK(capped < exact * 2.0 + 10.0);
	CHECK(stuck == 0);
}

/* in a pool with banks too high to climb: with digging allowed the route
 * digs its way out, and the digs are asked for from the water */
static void test_dig_out_of_water(void)
{
	bs_sim *s = bs_new(59, 4);
	int x, y, k, wet_digs = 0, before, out = 0;

	printf("a dig asked for from the water\n");
	for (y = 250; y <= 262; y++)
		for (x = 220; x <= 232; x++) {
			bc_map_set(s->truth, x, y, 59, 0);
			bc_map_set(s->truth, x, y, 60, 0);
			bc_map_set(s->truth, x, y, 61, 0);
			bc_map_set(s->truth, x, y, 62, 0);
		}
	s->have_tents = 1;
	s->tent[0].x = 226.5f; s->tent[0].y = 256.5f; s->tent[0].z = 61.75f;
	s->tent[1].x = 260.5f; s->tent[1].y = 256.5f; s->tent[1].z = 56.75f;
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\ndo go_to enemy_base\n");
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 5, 226.5f, 256.5f, 1, 0);
	bs_run(s, 15.0);
	CHECK(s->p[0].body.wade && s->edits == 0);  /* no way out, and it may not dig */
	bs_set(s, BL_NO_PLAYER, "edit=dig");
	for (k = 0; k < 60 * 90 && !out; k++) {
		before = s->edits;
		bs_step(s);
		if (s->edits != before && bc_map_is_water(s->truth, (int)s->p[0].body.pos.x, (int)s->p[0].body.pos.y)) wet_digs++;
		out = s->p[0].body.pos.x > 240.0f;
	}
	printf("  a pool four deep: out and on its way after %.1f s, %d digs, %d of them made standing in the water, %d refused\n",
	       k / 60.0, s->edits, wet_digs, s->refused);
	CHECK(out);
	CHECK(wet_digs >= 1);
	CHECK(s->p[0].stuck_events == 0);
	bs_free(s);
}

int main(void)
{
	test_look();
	test_aim_in_air();
	test_cover();
	test_cover_in_view();
	test_stuck_in_water();
	test_harmful_water();
	test_waiting_for_routes();
	test_capped_in_a_maze();
	test_dig_out_of_water();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
