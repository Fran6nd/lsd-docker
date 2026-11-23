/* aim_test.c -- the aim model, with no server.
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * Properties, not recordings: aosbot's aim uses another RNG, so what is
 * held is what its model implies -- the ordering of the levels, the rough
 * magnitudes from the table, the reaction delay, the turn cap -- measured
 * over many seeds. Prints "N checks, M failed".
 */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "aim.h"
#include "rng.h"

static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; \
	printf("FAIL %s:%d: %s -- ", __FILE__, __LINE__, #c); printf(__VA_ARGS__); \
	printf("\n"); } } while (0)

#define DEG 0.0174532925f
#define DT (1.0f / 60.0f)

static bc_aim_v3 V(float x, float y, float z) { bc_aim_v3 v = { x, y, z }; return v; }
static float len(bc_aim_v3 a) { return sqrtf(a.x * a.x + a.y * a.y + a.z * a.z); }
static float angle_deg(bc_aim_v3 a, bc_aim_v3 b)
{
	float cx = a.y * b.z - a.z * b.y, cy = a.z * b.x - a.x * b.z, cz = a.x * b.y - a.y * b.x;
	return atan2f(sqrtf(cx * cx + cy * cy + cz * cz), a.x * b.x + a.y * b.y + a.z * b.z) / DEG;
}
static bc_aim_v3 dir(float yaw_deg, float pitch_deg)
{
	float y = yaw_deg * DEG, p = pitch_deg * DEG;
	return V(cosf(p) * cosf(y), cosf(p) * sinf(y), sinf(p));
}
static bc_aim_v3 sub(bc_aim_v3 a, bc_aim_v3 b) { return V(a.x - b.x, a.y - b.y, a.z - b.z); }
/* The head's own aim, without tremor/error/flinch: what the control loop did. */
static bc_aim_v3 head(const bc_aim *a)
{
	float cp = cosf(a->pitch);
	return V(cp * cosf(a->yaw), cp * sinf(a->yaw), sinf(a->pitch));
}
static int finite_unit(bc_aim_v3 v)
{
	return isfinite(v.x) && isfinite(v.y) && isfinite(v.z) && fabsf(len(v) - 1.0f) < 1e-3f;
}

static bc_aim_target tgt_at(bc_aim_v3 pos, bc_aim_v3 vel, int id)
{
	bc_aim_target t = { 0 };
	t.pos = pos; t.vel = vel; t.id = id;
	return t;
}

/* --- determinism -------------------------------------------------------- */
static void run_track(uint64_t seed, int level, bc_aim_out *outs, int n)
{
	bc_rng r; bc_rng_seed(&r, seed, 7);
	bc_aim a;
	bc_aim_v3 eye = V(0, 0, 0), ori = V(1, 0, 0);
	bc_aim_init(&a, &r, level, ori);
	for (int i = 0; i < n; i++) {
		float t = (float)i * DT;
		bc_aim_target tg = tgt_at(V(20.0f * cosf(t * 0.4f), 20.0f * sinf(t * 0.4f), 0.2f),
		                          V(-8.0f * sinf(t * 0.4f), 8.0f * cosf(t * 0.4f), 0), (i / 200) % 3);
		bc_aim_events ev = { 0 };
		if (i == 150) { ev.hit = 1; ev.hit_from = V(-30, 5, 0); ev.hit_from_valid = 1; }
		if (i % 400 < 100) bc_aim_step_point(&a, &r, DT, eye, ori, V(0, -9, 1), &ev, 0, &outs[i]);
		else bc_aim_step(&a, &r, DT, eye, ori, i % 7 == 0 ? NULL : &tg, &ev, i % 3 == 0, &outs[i]);
		ori = outs[i].ori;
	}
}

static void test_determinism(void)
{
	static bc_aim_out A[1200], B[1200], C[1200];
	run_track(42, 6, A, 1200);
	run_track(42, 6, B, 1200);
	run_track(43, 6, C, 1200);
	CHECK(memcmp(A, B, sizeof A) == 0, "same seed and inputs must give identical outputs");
	CHECK(memcmp(A, C, sizeof A) != 0, "another seed must be another bot");
}

/* --- reaction and convergence ------------------------------------------ */
typedef struct conv { float t_move, t_3deg, err_late, peak_head; int overshoot; } conv;

/* Look 90 degrees away from where the head is, at a still target 10 blocks
 * off, and time it. t_move: first time the head (control loop) moved. */
static conv converge(uint64_t seed, int level)
{
	bc_rng r; bc_rng_seed(&r, seed, 1);
	bc_aim a;
	bc_aim_v3 eye = V(0, 0, 0), ori = V(1, 0, 0);
	bc_aim_init(&a, &r, level, ori);
	bc_aim_out o;
	/* settle on nothing for a second, so the error scale and wander are in */
	for (int i = 0; i < 60; i++) { bc_aim_step(&a, &r, DT, eye, ori, NULL, NULL, 0, &o); ori = o.ori; }
	bc_aim_target tg = tgt_at(V(0, 10, -1.5f), V(0, 0, 0), 5);
	conv c = { -1, -1, 0, 0, 0 };
	bc_aim_v3 prev = head(&a);
	float err_sum = 0; int err_n = 0;
	for (int i = 0; i < 60 * 8; i++) {
		float t = (float)(i + 1) * DT;
		bc_aim_step(&a, &r, DT, eye, ori, &tg, NULL, 0, &o);
		ori = o.ori;
		bc_aim_v3 h = head(&a);
		float spd = angle_deg(prev, h) / DT;
		if (spd > c.peak_head) c.peak_head = spd;
		prev = h;
		bc_aim_v3 want = sub(o.point, eye);
		float herr = angle_deg(h, want);
		if (c.t_move < 0 && angle_deg(h, V(1, 0, 0)) > 0.05f) c.t_move = t;
		if (c.t_3deg < 0 && herr < 3.0f) c.t_3deg = t;
		if (a.yaw > 90.0f * DEG + 1.5f * DEG && t < 3.0f) c.overshoot = 1;
		if (t > 4.0f) { err_sum += o.off_deg; err_n++; }
	}
	c.err_late = err_sum / (float)err_n;
	return c;
}

static void test_convergence(void)
{
	enum { N = 200 };
	float mv[11] = { 0 }, c3[11] = { 0 }, el[11] = { 0 }, pk[11] = { 0 }, os[11] = { 0 };
	float mvmin[11];
	int levels[3] = { 1, 5, 10 };
	for (int li = 0; li < 3; li++) {
		int L = levels[li];
		mvmin[L] = 1e9f;
		for (int s = 0; s < N; s++) {
			conv c = converge(1000 + (uint64_t)s, L);
			mv[L] += c.t_move; c3[L] += c.t_3deg < 0 ? 8.0f : c.t_3deg;
			el[L] += c.err_late; pk[L] += c.peak_head; os[L] += (float)c.overshoot;
			if (c.t_move < mvmin[L]) mvmin[L] = c.t_move;
			CHECK(c.t_3deg > 0, "level %d seed %d never converged on a still target", L, s);
		}
		mv[L] /= N; c3[L] /= N; el[L] /= N; pk[L] /= N; os[L] /= N;
		printf("  level %2d: first move %.0f ms, within 3 deg %.0f ms, settled error %.2f deg, "
		       "peak %.0f deg/s, overshoot %.0f%%\n", L, mv[L] * 1000, c3[L] * 1000, el[L], pk[L], os[L] * 100);
	}
	/* aosbot's table for a 90 degree turn: L10 within 3 deg in 787 ms, L1
	 * 1345 ms (their sim had no aim error; ours counts the head only). */
	CHECK(c3[10] > 0.45f && c3[10] < 1.1f, "level 10 converges in %.0f ms", c3[10] * 1000);
	CHECK(c3[1] > 0.9f && c3[1] < 2.2f, "level 1 converges in %.0f ms", c3[1] * 1000);
	CHECK(c3[1] > c3[5] && c3[5] > c3[10], "convergence time must fall with level");
	CHECK(c3[1] > 1.25f * c3[10], "level 1 must take measurably longer: %.2f vs %.2f", c3[1], c3[10]);
	/* reaction delay: nothing moves before the level's own delay */
	CHECK(mvmin[10] >= 0.14f - 1e-3f, "level 10 moved at %.3f s, before its 0.14 s reaction", mvmin[10]);
	CHECK(mvmin[1] >= 0.50f - 1e-3f, "level 1 moved at %.3f s, before its 0.50 s reaction", mvmin[1]);
	CHECK(mv[10] < 0.14f + 0.08f + 0.1f, "level 10 first move %.0f ms is late", mv[10] * 1000);
	CHECK(mv[1] > 0.5f && mv[1] < 0.5f + 0.08f + 0.1f, "level 1 first move %.0f ms", mv[1] * 1000);
	/* accuracy: the angular error once on target */
	CHECK(el[1] > 2.0f * el[10], "level 1 must be less accurate: %.2f vs %.2f deg", el[1], el[10]);
	CHECK(el[10] > 0.3f && el[10] < 3.5f, "level 10 error %.2f deg (cone 1.8, scaled)", el[10]);
	CHECK(el[1] > 3.0f && el[1] < 14.0f, "level 1 error %.2f deg (cone 14, scaled)", el[1]);
	CHECK(el[5] > el[10] && el[5] < el[1], "level 5 error between");
	/* flicks: the sloppy hand overshoots, the ace does not (aosbot 16% / 0%) */
	CHECK(os[1] > os[10] && os[1] > 0.04f, "level 1 overshoot %.0f%%, level 10 %.0f%%", os[1] * 100, os[10] * 100);
	CHECK(os[10] < 0.06f, "level 10 overshoot %.0f%%", os[10] * 100);
	/* the main sequence: a level-10 turn peaks near its 320 deg/s, level 1 near 90 */
	CHECK(pk[10] > 250.0f && pk[10] < 480.0f, "level 10 peak %.0f deg/s", pk[10]);
	CHECK(pk[1] > 70.0f && pk[1] < 170.0f, "level 1 peak %.0f deg/s", pk[1]);
}

/* --- the turn rate is never exceeded ----------------------------------- */
static void test_turn_rate(void)
{
	/* An ordinary turn runs 0.75x-1.25x the table's rate, a thrown one up to
	 * 1.3-1.6x of that and never past 2x: so 2x is the cap that must hold,
	 * at every level, on every seed, for turns of any size. */
	int levels[4] = { 1, 4, 7, 10 };
	float amps[4] = { 25, 60, 120, 179 };
	int bad = 0, n = 0;
	float worst = 0;
	for (int li = 0; li < 4; li++) {
		bc_aim_tuning tn; bc_aim_set_level(&tn, levels[li]);
		for (int ai = 0; ai < 4; ai++) for (int s = 0; s < 60; s++) {
			bc_rng r; bc_rng_seed(&r, 500 + (uint64_t)s, (uint64_t)li);
			bc_aim a; bc_aim_init(&a, &r, levels[li], V(1, 0, 0));
			bc_aim_out o; bc_aim_v3 ori = V(1, 0, 0), eye = V(0, 0, 0);
			bc_aim_v3 pt = dir(amps[ai], 0);
			pt = V(pt.x * 30, pt.y * 30, pt.z * 30);
			float py = a.yaw;
			for (int i = 0; i < 360; i++) {
				bc_aim_step_point(&a, &r, DT, eye, ori, pt, NULL, 0, &o);
				ori = o.ori;
				float dy = a.yaw - py;
				while (dy > 3.14159265f) dy -= 6.2831853f;
				while (dy < -3.14159265f) dy += 6.2831853f;
				float sp = fabsf(dy) / DT / DEG;
				if (sp > worst) worst = sp;
				if (sp > 2.0f * tn.turn_deg_per_sec * 1.001f) bad++;
				py = a.yaw; n++;
			}
		}
	}
	CHECK(bad == 0, "%d of %d ticks above 2x the turn rate (worst %.0f deg/s)", bad, n, worst);
	/* and it is a rate, not a snap: the first tick after the flick starts is slow */
	bc_rng r; bc_rng_seed(&r, 9, 9);
	bc_aim a; bc_aim_init(&a, &r, 10, V(1, 0, 0));
	bc_aim_out o; bc_aim_v3 ori = V(1, 0, 0);
	float maxstep = 0; bc_aim_v3 prev = V(1, 0, 0);
	for (int i = 0; i < 300; i++) {
		bc_aim_step_point(&a, &r, DT, V(0, 0, 0), ori, V(0, 20, 0), NULL, 0, &o);
		ori = o.ori;
		float st = angle_deg(prev, head(&a)); prev = head(&a);
		if (st > maxstep) maxstep = st;
	}
	CHECK(maxstep < 10.0f, "largest single-tick head step %.2f deg", maxstep);
}

/* --- reaction delay: nothing moves before it --------------------------- */
static void test_reaction(void)
{
	int levels[2] = { 1, 10 };
	for (int li = 0; li < 2; li++) {
		int L = levels[li];
		bc_aim_tuning tn; bc_aim_set_level(&tn, L);
		int early = 0;
		for (int s = 0; s < 100; s++) {
			bc_rng r; bc_rng_seed(&r, 77 + (uint64_t)s, 3);
			bc_aim a; bc_aim_init(&a, &r, L, V(1, 0, 0));
			bc_aim_out o; bc_aim_v3 ori = V(1, 0, 0);
			bc_aim_target far = tgt_at(V(-30, 5, 0), V(0, 0, 0), 2);  /* behind it */
			for (int i = 0; i < 120; i++) {
				float t = (float)(i + 1) * DT;
				bc_aim_step(&a, &r, DT, V(0, 0, 0), ori, &far, NULL, 0, &o);
				ori = o.ori;
				if (t < tn.reaction_sec - 1e-3f && angle_deg(head(&a), V(1, 0, 0)) > 0.01f) early++;
			}
		}
		CHECK(early == 0, "level %d: the head moved toward a far new target before its reaction time (%d ticks)", L, early);
	}
	/* a small change is followed at once, not waited on */
	bc_rng r; bc_rng_seed(&r, 5, 5);
	bc_aim a; bc_aim_init(&a, &r, 1, V(1, 0, 0));
	bc_aim_out o; bc_aim_v3 ori = V(1, 0, 0);
	for (int i = 0; i < 6; i++) { bc_aim_step_point(&a, &r, DT, V(0, 0, 0), ori, dir(8, 0), NULL, 0, &o); ori = o.ori; }
	CHECK(angle_deg(head(&a), V(1, 0, 0)) > 0.3f, "an 8 degree change is pursued without a reaction delay");
}

/* --- a moving target is led, by a belief a moment out of date ---------- */
static void test_lead(void)
{
	enum { N = 50 };
	float lead_off = 0;
	/* track_error 0 on a strafing target: no lead at all, on average. */
	for (int s = 0; s < N; s++) {
		bc_rng r; bc_rng_seed(&r, 300 + (uint64_t)s, 4);
		bc_aim a; bc_aim_init(&a, &r, 5, V(0, 1, 0));
		a.tune.track_error = 0.0f;
		bc_aim_out o; bc_aim_v3 ori = V(0, 1, 0), eye = V(0, 0, 0);
		float x = -50, sum = 0; int n = 0;
		for (int i = 0; i < 60 * 12; i++) {
			bc_aim_target tg = tgt_at(V(x, 20, -1.0f), V(8, 0, 0), 1);
			bc_aim_step(&a, &r, DT, eye, ori, &tg, NULL, 0, &o);
			ori = o.ori;
			if (i > 180) { sum += o.point.x - x; n++; }
			x += 8 * DT;
		}
		lead_off += sum / (float)n;
	}
	lead_off /= N;
	/* One-way run: steady motion, then a reversal. */
	float lead_steady = 0, stale_after = 0;
	for (int s = 0; s < N; s++) {
		bc_rng r; bc_rng_seed(&r, 900 + (uint64_t)s, 4);
		bc_aim a; bc_aim_init(&a, &r, 5, V(0, 1, 0));
		bc_aim_out o; bc_aim_v3 ori = V(0, 1, 0), eye = V(0, 0, 0);
		float x = -50;
		float sum = 0; int n = 0;
		for (int i = 0; i < 60 * 4; i++) {
			bc_aim_target tg = tgt_at(V(x, 20, -1.0f), V(8, 0, 0), 1);
			bc_aim_step(&a, &r, DT, eye, ori, &tg, NULL, 0, &o);
			ori = o.ori;
			if (i > 120) { sum += o.point.x - x; n++; }
			x += 8 * DT;
		}
		lead_steady += sum / (float)n;
		/* reverse: the belief still points the old way a few ticks on */
		for (int i = 0; i < 3; i++) {
			bc_aim_target tg = tgt_at(V(x, 20, -1.0f), V(-8, 0, 0), 1);
			bc_aim_step(&a, &r, DT, eye, ori, &tg, NULL, 0, &o);
			ori = o.ori;
			x -= 8 * DT;
		}
		stale_after += a.track_vel.x;
	}
	lead_steady /= N; stale_after /= N;
	printf("  lead: steady %.2f blocks ahead; belief 3 ticks after a reversal %.2f of -8\n", lead_steady, stale_after);
	CHECK(lead_steady > 0.15f && lead_steady < 1.2f, "steady lead %.2f blocks (8 b/s x 0.03-0.12 s x ~1)", lead_steady);
	CHECK(fabsf(lead_off) < 0.1f, "track_error 0 must not lead (%.2f)", lead_off);
	CHECK(stale_after > 4.0f, "after a reversal the belief must still point the old way (%.2f)", stale_after);
	/* an airborne target is not led stale */
	bc_rng r; bc_rng_seed(&r, 1, 1);
	bc_aim a; bc_aim_init(&a, &r, 5, V(0, 1, 0));
	bc_aim_out o;
	bc_aim_target tg = tgt_at(V(0, 20, -1), V(8, 0, 0), 1); tg.airborne = 1;
	bc_aim_step(&a, &r, DT, V(0, 0, 0), V(0, 1, 0), &tg, NULL, 0, &o);
	CHECK(fabsf(a.track_vel.x - 8.0f) < 1e-3f, "airborne: belief is the truth at once");
}

/* --- flinch ------------------------------------------------------------ */
static void test_flinch(void)
{
	enum { N = 100 };
	float kick = 0, off_hit = 0, off_ctl = 0, late = 0;
	for (int s = 0; s < N; s++) {
		bc_aim_out oa, ob;
		bc_rng ra, rb; bc_rng_seed(&ra, 2000 + (uint64_t)s, 2); bc_rng_seed(&rb, 2000 + (uint64_t)s, 2);
		bc_aim a, b; bc_aim_init(&a, &ra, 5, V(1, 0, 0)); bc_aim_init(&b, &rb, 5, V(1, 0, 0));
		bc_aim_v3 oria = V(1, 0, 0), orib = V(1, 0, 0), eye = V(0, 0, 0);
		bc_aim_target tg = tgt_at(V(15, 0, -1.5f), V(0, 0, 0), 1);
		for (int i = 0; i < 60 * 5; i++) {
			bc_aim_events ev = { 0 };
			if (i == 150) { ev.hit = 1; }
			bc_aim_step(&a, &ra, DT, eye, oria, &tg, &ev, 0, &oa); oria = oa.ori;
			bc_aim_step(&b, &rb, DT, eye, orib, &tg, NULL, 0, &ob); orib = ob.ori;
			if (i == 150) { kick += angle_deg(oa.ori, ob.ori); }
			if (i == 152) { off_hit += oa.off_deg; off_ctl += ob.off_deg; }
			if (i == 299) { late += fabsf(oa.off_deg - ob.off_deg); }
		}
	}
	kick /= N; off_hit /= N; off_ctl /= N; late /= N;
	printf("  flinch: kick %.2f deg, off-target %.2f (hit) vs %.2f (not), 1 s later diff %.2f\n", kick, off_hit, off_ctl, late);
	CHECK(kick > 1.0f, "a hit must perturb the aim at once (%.2f deg)", kick);
	CHECK(off_hit > off_ctl + 0.5f, "...and put it off the target (%.2f vs %.2f)", off_hit, off_ctl);
	/* the runs diverge after the hit (it drew from the rng), so compare means */
	CHECK(late < 2.5f, "...and it recovers (still %.2f deg apart 1 s later)", late);

	/* being shot from behind with nothing in view: a good bot turns to it
	 * soon and accurately, a poor one late and by a worse bearing. */
	float t_move[2] = { 0, 0 }, berr[2] = { 0, 0 };
	int levels[2] = { 1, 10 }, early[2] = { 0, 0 };
	for (int li = 0; li < 2; li++) {
		bc_aim_tuning tn; bc_aim_set_level(&tn, levels[li]);
		float react = 0.95f - 0.8f * tn.threat_sense;
		for (int s = 0; s < N; s++) {
			bc_rng r; bc_rng_seed(&r, 4000 + (uint64_t)s, 6);
			bc_aim a; bc_aim_init(&a, &r, levels[li], V(1, 0, 0));
			bc_aim_out o; bc_aim_v3 ori = V(1, 0, 0), eye = V(0, 0, 0);
			float tm = -1;
			for (int i = 0; i < 60 * 6; i++) {
				bc_aim_events ev = { 0 };
				if (i == 10) { ev.hit = 1; ev.hit_from = V(-30, 20, 0); ev.hit_from_valid = 1; }
				bc_aim_step(&a, &r, DT, eye, ori, NULL, &ev, 0, &o); ori = o.ori;
				float t = (float)(i - 10) * DT;
				if (i > 10 && tm < 0 && angle_deg(head(&a), V(1, 0, 0)) > 0.05f) tm = t;
				if (i > 10 && t < react - 0.03f && angle_deg(head(&a), V(1, 0, 0)) > 0.05f) early[li]++;
			}
			t_move[li] += tm < 0 ? 6.0f : tm;
			berr[li] += angle_deg(head(&a), sub(V(-30, 20, 0), eye));
		}
		t_move[li] /= N; berr[li] /= N;
		printf("  shot from behind, level %2d: starts turning after %.0f ms, ends %.1f deg off the source\n",
		       levels[li], t_move[li] * 1000, berr[li]);
	}
	CHECK(early[0] == 0 && early[1] == 0, "the head turned before the reaction to a hit");
	CHECK(t_move[1] < t_move[0] - 0.3f, "an ace reads a hit sooner");
	CHECK(berr[1] < berr[0], "...and from a closer bearing (%.1f vs %.1f)", berr[1], berr[0]);
	CHECK(berr[1] < 12.0f, "level 10 ends %.1f deg off the shooter", berr[1]);
}

/* --- degenerate inputs -------------------------------------------------- */
static void test_degenerate(void)
{
	float nan = nanf(""), inf = INFINITY;
	bc_aim_v3 zero = V(0, 0, 0), up = V(0, 0, -1), down = V(0, 0, 1);
	bc_aim_v3 cases[] = { zero, up, down, V(0, 0, 1e-9f), V(1e-9f, 0, 0), V(nan, 0, 0), V(0, inf, 0), V(1e30f, 1e30f, 1e30f) };
	int bad = 0, n = 0;
	for (int c = 0; c < 8; c++) {
		for (int mode = 0; mode < 4; mode++) {
			bc_rng r; bc_rng_seed(&r, 11 + (uint64_t)c, (uint64_t)mode);
			bc_aim a; bc_aim_init(&a, &r, 3, mode == 3 ? zero : V(1, 0, 0));
			bc_aim_out o; bc_aim_v3 ori = mode == 3 ? zero : V(1, 0, 0);
			for (int i = 0; i < 240; i++) {
				bc_aim_events ev = { 0 };
				if (i % 50 == 5) { ev.hit = 1; ev.hit_from = cases[c]; ev.hit_from_valid = 1; }
				bc_aim_target tg = tgt_at(cases[c], cases[(c + 1) % 8], c);
				float dt = i % 40 == 0 ? 0.0f : (i % 41 == 0 ? 5.0f : (i % 43 == 0 ? -1.0f : DT));
				if (mode == 0) bc_aim_step(&a, &r, dt, zero, ori, &tg, &ev, 1, &o);
				else if (mode == 1) bc_aim_step_point(&a, &r, dt, zero, ori, cases[c], &ev, 0, &o);
				else bc_aim_step(&a, &r, dt, cases[(c + 3) % 8], ori, i % 2 ? &tg : NULL, &ev, 0, &o);
				if (isfinite(len(o.ori)) && isfinite(o.off_deg)) ori = o.ori;
				n++;
				if (!finite_unit(o.ori) || !isfinite(o.off_deg)) bad++;
			}
		}
	}
	CHECK(bad == 0, "%d of %d outputs were not a finite unit vector", bad, n);
	/* straight up and down, target above and below, and at the eye */
	for (int k = 0; k < 3; k++) {
		bc_rng r; bc_rng_seed(&r, 3, 3);
		bc_aim a; bc_aim_init(&a, &r, 8, V(1, 0, 0));
		bc_aim_out o; bc_aim_v3 ori = V(1, 0, 0);
		bc_aim_v3 pos = k == 0 ? V(0, 0, -30) : (k == 1 ? V(0, 0, 30) : V(0, 0, 0));
		for (int i = 0; i < 300; i++) {
			bc_aim_target tg = tgt_at(pos, zero, 1);
			bc_aim_step(&a, &r, DT, zero, ori, &tg, NULL, 0, &o); ori = o.ori;
		}
		CHECK(finite_unit(o.ori), "target %d", k);
		if (k == 0) CHECK(o.ori.z < -0.9f, "looks up at a man overhead (z %.2f)", o.ori.z);
		if (k == 1) CHECK(o.ori.z > 0.9f, "looks down at a man below (z %.2f)", o.ori.z);
		if (k == 2) CHECK(fabsf(a.yaw) < 1e-3f, "a target at the eye must not turn the head");
	}
}

/* --- the cone, the spots, the point mode -------------------------------- */
static void test_misc(void)
{
	CHECK(fabsf(bc_aim_fire_cone(0.0f) - 25.0f * DEG) < 1e-4f, "cone ceiling");
	CHECK(fabsf(bc_aim_fire_cone(1000.0f) - 1.5f * DEG) < 1e-4f, "cone floor");
	CHECK(fabsf(bc_aim_fire_cone(10.0f) - atanf(0.12f)) < 1e-5f, "cone at 10 is atan(1.2/10)");
	CHECK(bc_aim_fire_cone(20.0f) < bc_aim_fire_cone(10.0f), "the cone closes with range");

	/* the spot on the body: 12/33/43/12 */
	int cnt[4] = { 0, 0, 0, 0 };
	bc_rng r; bc_rng_seed(&r, 99, 1);
	bc_aim a; bc_aim_init(&a, &r, 1, V(1, 0, 0));
	a.tune.aim_spot = 1.0f;
	bc_aim_out o;
	enum { N = 4000 };
	for (int i = 0; i < N; i++) {
		bc_aim_target tg = tgt_at(V(10, 0, 0), V(0, 0, 0), i);
		bc_aim_step(&a, &r, DT, V(0, 0, 0), V(1, 0, 0), &tg, NULL, 0, &o);
		float z = a.spot_z;
		cnt[z < 0.5f ? 0 : (z < 1.25f ? 1 : (z < 1.75f ? 2 : 3))]++;
	}
	float e[4] = { 0.12f, 0.33f, 0.43f, 0.12f };
	for (int k = 0; k < 4; k++)
		CHECK(fabsf((float)cnt[k] / N - e[k]) < 0.03f, "spot %d: %.3f, want %.2f", k, (float)cnt[k] / N, e[k]);
	/* and the same target keeps its spot */
	bc_aim_target tg = tgt_at(V(10, 0, 0), V(0, 0, 0), 777);
	bc_aim_step(&a, &r, DT, V(0, 0, 0), V(1, 0, 0), &tg, NULL, 0, &o);
	float z0 = a.spot_z;
	for (int i = 0; i < 100; i++) bc_aim_step(&a, &r, DT, V(0, 0, 0), V(1, 0, 0), &tg, NULL, 0, &o);
	CHECK(a.spot_z == z0, "the spot is per engagement");
	/* aim_spot 0: dead centre */
	a.tune.aim_spot = 0.0f;
	for (int i = 0; i < 20; i++) {
		bc_aim_target t2 = tgt_at(V(10, 0, 0), V(0, 0, 0), 5000 + i);
		bc_aim_step(&a, &r, DT, V(0, 0, 0), V(1, 0, 0), &t2, NULL, 0, &o);
		CHECK(fabsf(a.spot_z - 1.5f) < 1e-6f, "aim_spot 0 is centre mass");
		CHECK(fabsf(o.point.z - (-0.0f + 1.5f)) < 1e-3f, "...and the point is at it");
	}

	/* on_target: an ace on a close still man fires, a rookie at range mostly not */
	float rate[2] = { 0, 0 }; int levels[2] = { 1, 10 }; float dists[2] = { 60.0f, 15.0f };
	for (int li = 0; li < 2; li++) {
		int on = 0, n = 0;
		for (int s = 0; s < 40; s++) {
			bc_rng rr; bc_rng_seed(&rr, 600 + (uint64_t)s, 8);
			bc_aim b; bc_aim_init(&b, &rr, levels[li], V(1, 0, 0));
			bc_aim_v3 ori = V(1, 0, 0);
			bc_aim_target t3 = tgt_at(V(dists[li], 0, 0), V(0, 0, 0), 1);
			for (int i = 0; i < 60 * 6; i++) {
				bc_aim_step(&b, &rr, DT, V(0, 0, 0), ori, &t3, NULL, 0, &o); ori = o.ori;
				if (i > 60 * 3) { n++; on += o.on_target; }
			}
		}
		rate[li] = (float)on / (float)n;
	}
	printf("  on target: level 1 at 60 blocks %.0f%%, level 10 at 15 blocks %.0f%%\n", rate[0] * 100, rate[1] * 100);
	CHECK(rate[1] > 0.5f, "an ace on a close still man is on target %.0f%% of the time", rate[1] * 100);
	CHECK(rate[0] < rate[1] * 0.5f, "a rookie at range is rarely on target");
	/* a burst in progress has twice the cone */
	{
		bc_rng rr; bc_rng_seed(&rr, 1, 1);
		bc_aim b; bc_aim_init(&b, &rr, 10, V(1, 0, 0));
		b.tune.aim_error_deg = 0; b.tune.tremor_deg = 0;
		bc_aim_v3 ori = V(1, 0, 0);
		float cone = bc_aim_fire_cone(20.0f) / DEG;
		bc_aim_v3 p = dir(1.5f * cone, 0); p = V(p.x * 20, p.y * 20, p.z * 20);
		bc_aim_out o1, o2;
		bc_aim_step_point(&b, &rr, 0.0f, V(0, 0, 0), ori, p, NULL, 0, &o1);
		bc_aim_step_point(&b, &rr, 0.0f, V(0, 0, 0), ori, p, NULL, 1, &o2);
		CHECK(!o1.on_target && o2.on_target, "slack: 1.5 cones off is no trigger, but keeps a burst (%.2f deg, cone %.2f)", o1.off_deg, cone);
	}

	/* snap: no reaction, no turn */
	bc_rng r2; bc_rng_seed(&r2, 4, 4);
	bc_aim b; bc_aim_init(&b, &r2, 1, V(1, 0, 0));
	bc_aim_snap(&b, V(-1, 0, 0));
	bc_aim_step_point(&b, &r2, DT, V(0, 0, 0), V(-1, 0, 0), V(-20, 0, 0), NULL, 0, &o);
	CHECK(angle_deg(o.ori, V(-1, 0, 0)) < 3.0f, "a snapped head faces its heading at once (%.2f)", angle_deg(o.ori, V(-1, 0, 0)));
	/* resync: the body was moved far from the head */
	bc_aim_step_point(&b, &r2, DT, V(0, 0, 0), V(0, 1, 0), V(0, 20, 0), NULL, 0, &o);
	CHECK(angle_deg(o.ori, V(0, 1, 0)) < 3.0f, "a head finding its body elsewhere follows it");

	/* looking at a point: the quiet error scale makes it steadier than a target */
	float err_pt = 0, err_tg = 0;
	for (int s = 0; s < 40; s++) {
		bc_rng rr; bc_rng_seed(&rr, 800 + (uint64_t)s, 5);
		bc_aim p1, p2; bc_aim_init(&p1, &rr, 3, V(1, 0, 0)); bc_aim_init(&p2, &rr, 3, V(1, 0, 0));
		p2.tune.aim_spot = 0.0f; p2.spot_z = 1.5f;
		bc_aim_v3 o1 = V(1, 0, 0), o2 = V(1, 0, 0);
		for (int i = 0; i < 60 * 8; i++) {
			bc_aim_out a1, a2;
			bc_aim_step_point(&p1, &rr, DT, V(0, 0, 0), o1, V(10, 0, 1.5f), NULL, 0, &a1); o1 = a1.ori;
			bc_aim_target t4 = tgt_at(V(10, 0, 0), V(0, 0, 0), 1);
			bc_aim_step(&p2, &rr, DT, V(0, 0, 0), o2, &t4, NULL, 0, &a2); o2 = a2.ori;
			if (i > 60 * 4) { err_pt += a1.off_deg; err_tg += a2.off_deg; }
		}
	}
	CHECK(err_pt < err_tg * 0.7f, "a looked-at point is steadier than a target (%.2f vs %.2f)", err_pt / (40 * 240), err_tg / (40 * 240));
}

int main(void)
{
	test_determinism();
	test_convergence();
	test_turn_rate();
	test_reaction();
	test_lead();
	test_flinch();
	test_degenerate();
	test_misc();
	printf("%d checks, %d failed\n", checks, failed);
	return failed ? 1 : 0;
}
