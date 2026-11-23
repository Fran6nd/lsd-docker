/* nav_moves.c -- Measuring what a body can do
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * See nav.h. Each move is tried in the smallest scene that leaves the
 * body no help: a run-up one column wide, a landing that is a single
 * column, a pit all round. What passes here passes anywhere the swept
 * voxels are free; the reverse is not true (a wider landing is easier),
 * which is the side to err on.
 *
 * Scenes are built in the move's canonical direction -- +x for an axis
 * move, +x +y for a diagonal -- around column (256, 256) with the floor
 * at z = 40 (or 63 for moves that start in water). The plan turns them to
 * the other three quarters.
 */
#include "nav_i.h"

#include <math.h>
#include <string.h>

#define OX 256
#define OY 256
#define ZA 40
#define WIN 28

/* --- scenes ----------------------------------------------------------- */

static void scene_base(bc_map *m, uint64_t base)
{
	int x, y;

	for (y = OY - WIN; y <= OY + WIN; y++)
		for (x = OX - WIN; x <= OX + WIN; x++)
			m->col[y * BC_MAP_X + x] = base;
	m->rev++;
}

#define LAND_BASE ((uint64_t)3 << 62)      /* a pit down to the ground */
#define WATER_BASE ((uint64_t)1 << 63)

/* A column solid from `top` down, at (rx, ry) from the origin. */
static void put(bc_map *m, int rx, int ry, int top)
{
	if (top < 0)
		top = 0;
	m->col[(OY + ry) * BC_MAP_X + (OX + rx)] = top >= 64 ? 0 : (~(uint64_t)0 << top);
}

/* --- the swept volume -------------------------------------------------- */

typedef struct sweep {
	int n, overflow;
	int8_t dx[128], dy[128];
	uint16_t bits[128];
} sweep;

static void sweep_cell(sweep *s, int rx, int ry, int rz)
{
	int i, bit = rz + BC_NAV_MASK_Z0;

	if (bit < 0 || bit > 15 || rx < -100 || rx > 100 || ry < -100 || ry > 100) {
		s->overflow = 1;
		return;
	}
	for (i = 0; i < s->n; i++)
		if (s->dx[i] == rx && s->dy[i] == ry) {
			s->bits[i] |= (uint16_t)(1u << bit);
			return;
		}
	if (s->n >= 128) {
		s->overflow = 1;
		return;
	}
	s->dx[s->n] = (int8_t)rx; s->dy[s->n] = (int8_t)ry;
	s->bits[s->n] = (uint16_t)(1u << bit);
	s->n++;
}

/* Every voxel the body's box is in right now. The box is what the physics
 * tests: 0.45 either side of the eye, from 0.45 above it to the soles. */
static void sweep_body(sweep *s, const bc_body *b, int za)
{
	int z0 = (int)floorf(b->pos.z - 0.45f);
	int z1 = (int)floorf(bc_body_feet(b) - 0.03f);
	int cx, cy, z;

	if (z1 > 62)
		z1 = 62;        /* the sea bed is not a voxel anybody can clear */
	for (cx = 0; cx < 2; cx++)
		for (cy = 0; cy < 2; cy++) {
			int x = (int)floorf(b->pos.x + (cx ? 0.45f : -0.45f)) - OX;
			int y = (int)floorf(b->pos.y + (cy ? 0.45f : -0.45f)) - OY;

			for (z = z0; z <= z1; z++)
				sweep_cell(s, x, y, z - za);
		}
}

static int add_move(bc_nav_moves *t, const bc_nav_move *proto, const sweep *sw)
{
	bc_nav_move *mv;
	int i;

	if (sw->overflow || t->n >= BC_NAV_MOVES_MAX || t->ncols + sw->n > BC_NAV_MASK_POOL)
		return -1;
	mv = &t->mv[t->n];
	*mv = *proto;
	mv->mask_off = (uint16_t)t->ncols;
	mv->mask_n = (uint16_t)sw->n;
	for (i = 0; i < sw->n; i++) {
		t->cols[t->ncols].dx = sw->dx[i];
		t->cols[t->ncols].dy = sw->dy[i];
		t->cols[t->ncols].bits = sw->bits[i];
		t->ncols++;
	}
	return t->n++;
}

/* --- the body itself --------------------------------------------------- */

/* Does a body get three columns in under a ceiling with `cells` voxels of
 * air beneath it? */
static int fits_under(bc_map *m, int cells, int crouched)
{
	bc_body b;
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	uint8_t keys = (uint8_t)(BC_K_FORWARD | (crouched ? BC_K_CROUCH : 0));
	int rx, ry, i;

	scene_base(m, LAND_BASE);
	for (ry = -3; ry <= 3; ry++)
		for (rx = -8; rx <= 8; rx++) {
			put(m, rx, ry, ZA);
			if (rx >= 0)    /* the slab */
				m->col[(OY + ry) * BC_MAP_X + (OX + rx)] |=
					(uint64_t)3 << (ZA - cells - 2);
		}
	bc_body_place(&b, m, OX - 3.5f, OY + 0.5f, ZA, crouched);
	for (i = 0; i < 400; i++)
		bc_body_step(&b, m, keys, ori, BC_BODY_DT);
	return b.pos.x > OX + 3.0f;
}

static float pace(bc_map *m, uint8_t mode, int water)
{
	bc_body b;
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	int rx, ry, i, z = water ? 63 : ZA;

	scene_base(m, water ? WATER_BASE : LAND_BASE);
	for (ry = -3; ry <= 3; ry++)
		for (rx = -WIN; rx <= WIN; rx++)
			put(m, rx, ry, z);
	bc_body_place(&b, m, OX - 20.5f, OY + 0.5f, z, (mode & BC_K_CROUCH) != 0);
	for (i = 0; i < 180; i++)
		bc_body_step(&b, m, (uint8_t)(BC_K_FORWARD | mode), ori, BC_BODY_DT);
	return bc_body_speed(&b);
}

/* --- strides: walking from one column to the next, in stride ----------- */

/* The scene: everything "behind" the far edge of the start column at za,
 * everything beyond at za + dz. For a diagonal the two corner columns
 * are on the near side (nav.h: a diagonal needs its corners). */
static void stride_scene(bc_map *m, int cls, int za, int dz)
{
	int rx, ry;

	scene_base(m, za >= 63 ? WATER_BASE : LAND_BASE);
	for (ry = -WIN; ry <= WIN; ry++)
		for (rx = -WIN; rx <= WIN; rx++) {
			int near = cls == BC_NAV_CLS_AXIS ? rx <= 0 : rx + ry <= 1;

			if (cls == BC_NAV_CLS_AXIS && (ry < -4 || ry > 4))
				continue;
			if (cls == BC_NAV_CLS_DIAG && (rx - ry < -6 || rx - ry > 6))
				continue;
			put(m, rx, ry, near ? za : za + dz);
		}
}

static int measure_stride(bc_nav_moves *t, bc_map *m, int kind, int cls, uint8_t mode,
                          int dz, int za)
{
	bc_body b, prev;
	bc_nav_move mv;
	sweep sw;
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	int ddx = 1, ddy = cls == BC_NAV_CLS_DIAG ? 1 : 0;
	float len = cls == BC_NAV_CLS_DIAG ? 1.41421356f : 1.0f;
	float ux = (float)ddx / len, uy = (float)ddy / len;
	float acx = OX + 0.5f, acy = OY + 0.5f;
	float t0 = -1.0f, t1 = -1.0f, s_prev = -100.0f, rest = nav_rest(za + dz);
	int i, armed = 0;

	stride_scene(m, cls, za, dz);
	memset(&sw, 0, sizeof sw);
	/* far enough back to be at full pace when it gets here */
	bc_body_place(&b, m, acx - 14.0f * ddx, acy - 14.0f * ddy, za, (mode & BC_K_CROUCH) != 0);
	prev = b;

	for (i = 0; i < 1500; i++) {
		uint8_t k;
		float s;

		nav_law_steer(&b, acx + 9.0f * ddx, acy + 9.0f * ddy, mode, 0, &k, &ori);
		prev = b;
		bc_body_step(&b, m, nav_crouch_guard(&b, m, k), ori, BC_BODY_DT);
		s = ((b.pos.x - acx) * ux + (b.pos.y - acy) * uy) / len;
		if (s_prev < 0.0f && s >= 0.0f) {
			t0 = (float)i + (0.0f - s_prev) / (s - s_prev);
			armed = 1;
			sweep_body(&sw, &prev, za);
		}
		if (armed && s <= 1.0f)
			sweep_body(&sw, &b, za);
		if (s_prev < 1.0f && s >= 1.0f && t1 < 0.0f) {
			t1 = (float)i + (1.0f - s_prev) / (s - s_prev);
			sweep_body(&sw, &b, za);
		}
		s_prev = s;
		if (s >= 3.0f)
			break;
	}
	if (t0 < 0.0f || t1 < 0.0f || s_prev < 3.0f)
		return -1;
	/* let it come down, and see that it is where it should be */
	for (i = 0; i < 120; i++)
		bc_body_step(&b, m, 0, ori, BC_BODY_DT);
	if (fabsf(bc_body_feet(&b) - rest) > 0.3f)
		return -1;

	/* A stride's volume is what it sweeps in its OWN columns: the two it
	 * joins, and for a diagonal the two corners. The body's leading edge
	 * is over the column beyond well before its centre arrives, but what
	 * it meets there belongs to the next stride -- on a staircase that
	 * is the next tread, which it will be climbing by then. */
	{
		int k = 0;

		for (i = 0; i < sw.n; i++)
			if (sw.dx[i] >= 0 && sw.dx[i] <= 1 && sw.dy[i] >= 0 && sw.dy[i] <= ddy) {
				sw.dx[k] = sw.dx[i]; sw.dy[k] = sw.dy[i]; sw.bits[k] = sw.bits[i];
				k++;
			}
		sw.n = k;
	}

	memset(&mv, 0, sizeof mv);
	mv.kind = (uint8_t)kind;
	mv.cls = (uint8_t)cls;
	mv.d = 1;
	mv.dz = (int8_t)dz;
	mv.sprint = (mode & BC_K_SPRINT) != 0;
	mv.from_water = za >= 63;
	mv.secs = (t1 - t0) * BC_BODY_DT;
	return add_move(t, &mv, &sw);
}

/* --- shots: jumps and drops -------------------------------------------- */

/* A run-up `runup` columns long and one wide, a take-off column, a single
 * landing column `d` on and `dz` down, nothing else. */
static void shot_scene(bc_map *m, int cls, int d, int dz, int runup)
{
	int ddx = 1, ddy = cls == BC_NAV_CLS_DIAG ? 1 : 0;
	int k;

	scene_base(m, LAND_BASE);
	for (k = 0; k <= runup; k++)
		put(m, -k * ddx, -k * ddy, ZA);
	put(m, d * ddx, d * ddy, ZA + dz);
}

static nav_shot make_shot(int cls, int d, int dz, int za, int sprint, int runup)
{
	nav_shot s;
	int ddx = 1, ddy = cls == BC_NAV_CLS_DIAG ? 1 : 0;

	memset(&s, 0, sizeof s);
	s.from.x = OX; s.from.y = OY; s.from.z = (int16_t)za;
	s.to.x = (int16_t)(OX + d * ddx); s.to.y = (int16_t)(OY + d * ddy);
	s.to.z = (int16_t)(za + dz);
	s.sprint = (uint8_t)sprint;
	s.runup = (uint8_t)runup;
	s.max_damage = 255;
	s.diag = (uint8_t)cls;
	return s;
}

/* The scene must be built. Runs the jump controller from a standing start
 * at the far end of the run-up. */
static int run_jump(bc_nav_moves *t, bc_map *m, int cls, int d, int dz, int za,
                    int sprint, int runup)
{
	nav_shot s = make_shot(cls, d, dz, za, sprint, runup);
	nav_xs xs;
	bc_body b, bb;
	bc_nav_move mv;
	sweep sw;
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	int ddx = 1, ddy = cls == BC_NAV_CLS_DIAG ? 1 : 0;
	float len = cls == BC_NAV_CLS_DIAG ? 1.41421356f : 1.0f;
	float back = runup ? (float)runup : 0.3f / len;
	int i, run = 0, margin = 0, maxdmg = 0, done = 0;

	bc_body_place(&b, m, OX + 0.5f - back * ddx, OY + 0.5f - back * ddy, za, 0);

	/* the window: for how many ticks in a row does pressing jump work */
	bb = b;
	for (i = 0; i < 240 && bc_body_feet(&bb) < nav_rest(za) + 0.3f; i++) {
		uint8_t k;

		if (nav_jump_sim(&s, m, &bb, 0, BC_K_FORWARD) || nav_jump_sim(&s, m, &bb, 0, 0)) {
			if (++run > margin)
				margin = run;
		} else {
			if (margin >= 3)
				break;  /* the first window is the one that counts */
			run = 0;
		}
		nav_jump_run_law(&s, &bb, &k, &ori);
		bc_body_step(&bb, m, k, ori, BC_BODY_DT);
	}
	if (margin < 3)
		return -1;

	memset(&xs, 0, sizeof xs);
	memset(&sw, 0, sizeof sw);
	xs.phase = NAV_XS_RUN;
	for (i = 0; i < 600; i++) {
		uint8_t k = 0;
		int32_t dmg;
		int r = nav_jump_tick(&s, &xs, &b, m, &k, &ori);

		if (r == 1) { done = 1; break; }
		if (r < 0)
			return -1;
		sweep_body(&sw, &b, za);
		dmg = bc_body_step(&b, m, nav_crouch_guard(&b, m, k), ori, BC_BODY_DT);
		if (dmg > maxdmg)
			maxdmg = dmg;
	}
	if (!done)
		return -1;
	sweep_body(&sw, &b, za);

	memset(&mv, 0, sizeof mv);
	mv.kind = (uint8_t)((sprint || runup) ? BC_NAV_RUNJUMP : BC_NAV_JUMP);
	mv.cls = (uint8_t)cls;
	mv.d = (int8_t)d;
	mv.dz = (int8_t)dz;
	mv.runup = (uint8_t)runup;
	mv.sprint = (uint8_t)sprint;
	mv.margin = (uint8_t)(margin > 255 ? 255 : margin);
	mv.damage = (uint8_t)(maxdmg > 255 ? 255 : maxdmg);
	mv.from_water = za >= 63;
	mv.secs = (float)i * BC_BODY_DT;
	return add_move(t, &mv, &sw);
}

/* The variants of a jump, least demanding of the map first. */
static const struct { uint8_t sprint, runup; } variants[] = {
	{0, 0}, {1, 0}, {0, 1}, {1, 1}, {0, 2}, {1, 2}, {1, 3}, {1, 4}, {1, 6}
};
#define NVARIANTS ((int)(sizeof variants / sizeof variants[0]))

static int measure_jump(bc_nav_moves *t, bc_map *m, int cls, int d, int dz)
{
	int pass, v, idx;

	/* A window of three ticks is the least the follower can use; one of
	 * five leaves room for the body not being quite where the measuring
	 * had it. Take the least demanding variant with a comfortable window,
	 * and a tight one only if no variant is comfortable. */
	for (pass = 0; pass < 2; pass++)
		for (v = 0; v < NVARIANTS; v++) {
			int n0 = t->n, c0 = t->ncols;

			shot_scene(m, cls, d, dz, variants[v].runup);
			idx = run_jump(t, m, cls, d, dz, ZA, variants[v].sprint, variants[v].runup);
			if (idx < 0)
				continue;
			if (pass == 1 || t->mv[idx].margin >= 5)
				return idx;
			t->n = n0;
			t->ncols = c0;
		}
	return -1;
}

/* A drop is measured twice: onto a lone column with a pit beyond it (the
 * body must not overshoot) and into a slot with a wall beyond it (a
 * ditch: the body must fit). Both must work; the volume kept is the
 * slot's, which is the two columns and nothing else. */
static int measure_drop_in(bc_nav_moves *t, bc_map *m, int cls, int dz, int walled)
{
	nav_shot s = make_shot(cls, 1, dz, ZA, 0, 0);
	nav_xs xs;
	bc_body b;
	bc_nav_move mv;
	sweep sw;
	bc_v3 ori = {1.0f, 0.0f, 0.0f};
	int i, maxdmg = 0, done = 0;

	shot_scene(m, cls, 1, dz, 0);
	if (walled) {
		int rx, ry;

		for (ry = -2; ry <= 3; ry++)
			for (rx = -2; rx <= 3; rx++) {
				int own = (rx == 0 && ry == 0) || (rx == 1 && ry == (cls ? 1 : 0)) ||
				          (cls && ((rx == 1 && ry == 0) || (rx == 0 && ry == 1)));

				if (!own)
					put(m, rx, ry, ZA - 6);
			}
		if (cls) {      /* a diagonal's corners: floor at the top level */
			put(m, 1, 0, ZA);
			put(m, 0, 1, ZA);
		}
	}
	bc_body_place(&b, m, OX + 0.5f, OY + 0.5f, ZA, 0);
	memset(&xs, 0, sizeof xs);
	memset(&sw, 0, sizeof sw);
	for (i = 0; i < 600; i++) {
		uint8_t k = 0;
		int32_t dmg;
		int r = nav_drop_tick(&s, &xs, &b, m, i, &k, &ori);

		if (r == 1) { done = 1; break; }
		if (r < 0)
			return -1;
		sweep_body(&sw, &b, ZA);
		dmg = bc_body_step(&b, m, nav_crouch_guard(&b, m, k), ori, BC_BODY_DT);
		if (dmg > maxdmg)
			maxdmg = dmg;
	}
	if (!done)
		return -1;
	sweep_body(&sw, &b, ZA);

	memset(&mv, 0, sizeof mv);
	mv.kind = BC_NAV_DROP;
	mv.cls = (uint8_t)cls;
	mv.d = 1;
	mv.dz = (int8_t)dz;
	mv.damage = (uint8_t)(maxdmg > 255 ? 255 : maxdmg);
	mv.secs = (float)i * BC_BODY_DT;
	return add_move(t, &mv, &sw);
}

static int measure_drop(bc_nav_moves *t, bc_map *m, int cls, int dz)
{
	int n0 = t->n, c0 = t->ncols;

	if (measure_drop_in(t, m, cls, dz, 0) < 0)
		return -1;
	t->n = n0;
	t->ncols = c0;
	return measure_drop_in(t, m, cls, dz, 1);
}

/* Out of the water onto a bank `up` voxels above the sea bed's top: by
 * wading into it if the physics lifts the body, else by a jump. */
static int measure_water_out(bc_nav_moves *t, bc_map *m, int cls, int up)
{
	int idx = measure_stride(t, m, BC_NAV_WALK, cls, 0, -up, 63);
	int v;

	if (idx >= 0)
		return idx;
	for (v = 0; v < 2; v++) {
		stride_scene(m, cls, 63, -up);
		idx = run_jump(t, m, cls, 1, -up, 63, variants[v].sprint, 0);
		if (idx >= 0)
			return idx;
	}
	return -1;
}

/* The widest level gap crossed with or without sprint, any run-up. */
static int widest_gap(bc_nav_moves *scratch_t, bc_map *m, int sprint)
{
	int d, r, best = 0;

	for (d = 2; d <= BC_NAV_JUMP_DMAX + 1; d++) {
		int ok = 0;

		for (r = 0; r <= 6 && !ok; r++) {
			scratch_t->n = 0;
			scratch_t->ncols = 0;
			shot_scene(m, BC_NAV_CLS_AXIS, d, 0, r);
			ok = run_jump(scratch_t, m, BC_NAV_CLS_AXIS, d, 0, ZA, sprint, r) >= 0;
		}
		if (!ok)
			break;
		best = d - 1;
	}
	return best;
}

/* --- the whole table --------------------------------------------------- */

int bc_nav_moves_measure(bc_nav_moves *t, bc_map *m)
{
	int cls, dz, d, k, up;

	bc_map_fill_flat(m, 62);

	/* the gaps for the record come first: they borrow the table as scratch */
	memset(t, 0, sizeof *t);
	{
		int gw = widest_gap(t, m, 0), gs = widest_gap(t, m, 1);

		memset(t, 0, sizeof *t);
		t->gap_walk = (uint8_t)gw;
		t->gap_sprint = (uint8_t)gs;
	}

	for (k = 1; k <= 5; k++)
		if (fits_under(m, k, 0)) { t->stand_cells = (uint8_t)k; break; }
	for (k = 1; k <= 5; k++)
		if (fits_under(m, k, 1)) { t->crouch_cells = (uint8_t)k; break; }

	t->walk_speed = pace(m, 0, 0);
	t->sprint_speed = pace(m, BC_K_SPRINT, 0);
	t->crouch_speed = pace(m, BC_K_CROUCH, 0);
	t->sneak_speed = pace(m, BC_K_SNEAK, 0);
	t->wade_speed = pace(m, 0, 1);

	for (cls = 0; cls < 2; cls++) {
		for (dz = -1; dz <= 1; dz++) {
			t->walk[cls][dz + 1] = (int16_t)measure_stride(t, m, BC_NAV_WALK, cls, 0, dz, ZA);
			t->sprint[cls][dz + 1] = (int16_t)measure_stride(t, m, BC_NAV_SPRINT, cls,
			                                                 BC_K_SPRINT, dz, ZA);
			t->crouch[cls][dz + 1] = (int16_t)measure_stride(t, m, BC_NAV_CROUCH, cls,
			                                                 BC_K_CROUCH, dz, ZA);
		}
		for (dz = BC_NAV_DZ_MIN; dz <= BC_NAV_DZ_MAX; dz++)
			t->drop[cls][dz - BC_NAV_DZ_MIN] =
				(int16_t)(dz >= 2 ? measure_drop(t, m, cls, dz) : -1);

		for (d = 0; d <= BC_NAV_JUMP_DMAX; d++)
			for (dz = BC_NAV_DZ_MIN; dz <= BC_NAV_DZ_MAX; dz++)
				t->jump[cls][d][dz - BC_NAV_DZ_MIN] = -1;
		for (d = 1; d <= BC_NAV_JUMP_DMAX; d++) {
			int any = 0;

			for (dz = BC_NAV_DZ_MIN; dz <= BC_NAV_DZ_MAX; dz++) {
				int idx;

				if (d == 1 && dz > -2)
					continue;   /* that is a stride or a drop */
				idx = measure_jump(t, m, cls, d, dz);
				t->jump[cls][d][dz - BC_NAV_DZ_MIN] = (int16_t)idx;
				any |= idx >= 0;
			}
			if (d >= 2 && !any)
				break;          /* further is no easier */
		}

		t->wade[cls] = (int16_t)measure_stride(t, m, BC_NAV_WALK, cls, 0, 0, 63);
		t->water_out[cls][0] = -1;
		for (up = 1; up <= 3; up++)
			t->water_out[cls][up] = (int16_t)measure_water_out(t, m, cls, up);
	}
	return t->n;
}

const char *bc_nav_kind_name(int kind)
{
	static const char *const names[BC_NAV_KINDS] = {
		"NONE", "WALK", "SPRINT", "CROUCH", "DROP", "JUMP", "RUNJUMP",
		"DIG", "BUILD", "PILLAR"
	};

	return kind >= 0 && kind < BC_NAV_KINDS ? names[kind] : "?";
}
