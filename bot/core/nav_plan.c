/* nav_plan.c -- The search: A* over places to stand, edges from the table
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * See nav.h. What is particular to this file:
 *
 * EXPANDING A NODE costs little on ordinary ground and more only where
 * there is something to weigh:
 *   - Each of the eight neighbours is one column word. The floor a body
 *     walking that way would end on is the first standable bit at or
 *     below "one up" -- a shift and a bit scan -- and at most one such
 *     floor can be walked to (a body does not pass through a floor).
 *   - Jumps are only looked for in a direction where the neighbour could
 *     NOT simply be walked to. A jump over ground one could walk on is
 *     never the cheaper way, and this one rule keeps flat ground at eight
 *     edges a node.
 *   - Edits are only looked for when the policy allows them.
 *
 * THE SETS. Nodes live in a pool laid out once in the caller's memory;
 * a hash table (open addressing, twice the pool) finds a node by its
 * packed (x, y, z); the open set is a binary heap of pool indexes with
 * each node knowing its place in it, so a cheaper way to a known node is
 * a sift-up and not a second entry. Nothing is freed during a search and
 * nothing allocated: when the pool is full the search fails, and says
 * where it had got to.
 */
#include "nav_i.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------- */
/* Small things the policy needs                                     */

/* the time an edit move takes besides its edits: a pillar's jump, a dig
 * down's fall of one voxel */
#define PILLAR_SECS 0.75f
#define DIG_FALL_SECS 0.4f

void bc_nav_policy_default(bc_nav_policy *p)
{
	memset(p, 0, sizeof *p);
	p->may_jump = 1;
	p->min_margin = 4;
	p->dig_secs = 0.5f;
	p->build_secs = 0.7f;
	p->water_secs = 0.5f;
	p->fail_secs = 20.0f;
}

void bc_nav_protect_clear(bc_nav_protect *p)
{
	memset(p, 0, sizeof *p);
}

static uint32_t vox_key(int x, int y, int z)
{
	return ((uint32_t)x & 511u) | (((uint32_t)y & 511u) << 9) | (((uint32_t)z & 63u) << 18) |
	       (1u << 24);
}

void bc_nav_protect_add(bc_nav_protect *p, int x, int y, int z)
{
	uint32_t xy;

	if (!bc_map_in(x, y, z) || bc_nav_protect_has(p, x, y, z))
		return;
	xy = (uint32_t)(y * BC_MAP_X + x);
	p->colbits[xy / 64] |= (uint64_t)1 << (xy % 64);
	p->vox[p->n % BC_NAV_PROTECT_MAX] = vox_key(x, y, z);
	p->n++;
}

int bc_nav_protect_has(const bc_nav_protect *p, int x, int y, int z)
{
	uint32_t xy, key, i, n;

	if (!p || !bc_map_in(x, y, z))
		return 0;
	xy = (uint32_t)(y * BC_MAP_X + x);
	if (!((p->colbits[xy / 64] >> (xy % 64)) & 1))
		return 0;
	key = vox_key(x, y, z);
	n = p->n < BC_NAV_PROTECT_MAX ? p->n : BC_NAV_PROTECT_MAX;
	for (i = 0; i < n; i++)
		if (p->vox[i] == key)
			return 1;
	return 0;
}

void bc_nav_fail_clear(bc_nav_fail *f)
{
	memset(f, 0, sizeof *f);
}

static uint32_t fail_slot(uint32_t from, uint32_t to, int kind)
{
	uint32_t h = from * 2654435761u ^ (to * 2246822519u) ^ ((uint32_t)kind * 3266489917u);

	return (h >> 16) % BC_NAV_FAIL_MAX;
}

void bc_nav_fail_note(bc_nav_fail *f, bc_nav_node from, bc_nav_node to, int kind,
                      double now, double ttl)
{
	uint32_t a = nav_pack(from), b = nav_pack(to);
	bc_nav_fail_entry *e = &f->e[fail_slot(a, b, kind)];

	if (e->from == a && e->to == b && e->kind == kind && e->until > now) {
		if (e->count < 8)
			e->count++;
	} else {
		/* one slot a hash: a newer failure replaces whatever was there */
		e->from = a; e->to = b; e->kind = (uint8_t)kind; e->count = 1;
	}
	e->until = now + ttl;
}

int bc_nav_fail_count(const bc_nav_fail *f, bc_nav_node from, bc_nav_node to, int kind,
                      double now)
{
	uint32_t a = nav_pack(from), b = nav_pack(to);
	const bc_nav_fail_entry *e;

	if (!f)
		return 0;
	e = &f->e[fail_slot(a, b, kind)];
	return (e->from == a && e->to == b && e->kind == kind && e->until > now) ? e->count : 0;
}

/* ---------------------------------------------------------------- */
/* Places to stand                                                   */

int nav_node_kind(const bc_map *m, int x, int y, int z)
{
	uint64_t c;

	if (!bc_map_in(x, y, z))
		return 0;
	c = m->col[y * BC_MAP_X + x];
	if ((bc_map_stand_bits(c) >> z) & 1)
		return 1;
	if ((bc_map_crouch_bits(c) >> z) & 1)
		return 2;
	return 0;
}

int bc_nav_node_of_body(const bc_map *m, const bc_body *b, bc_nav_node *out)
{
	static const float ox[5] = {0.0f, -0.45f, 0.45f, -0.45f, 0.45f};
	static const float oy[5] = {0.0f, -0.45f, -0.45f, 0.45f, 0.45f};
	float feet = bc_body_feet(b);
	int z0 = (int)floorf(feet + 0.1f);
	int i, pass;

	/* First what holds it up now -- the column under the centre, then
	 * those under the corners (a body stands with its centre over
	 * nothing) -- then, for a body in the air, what is below it. */
	for (pass = 0; pass < 2; pass++)
		for (i = 0; i < 5; i++) {
			int x = (int)floorf(b->pos.x + ox[i]);
			int y = (int)floorf(b->pos.y + oy[i]);
			int f = bc_map_floor_at_or_below(m, x, y, z0 < 0 ? 0 : z0);

			if (f > BC_MAP_WATER_Z)
				f = BC_MAP_WATER_Z;
			if (pass == 0 && fabsf(nav_rest(f) - feet) > 0.45f)
				continue;
			if (!nav_node_kind(m, x, y, f))
				continue;
			out->x = (int16_t)x; out->y = (int16_t)y; out->z = (int16_t)f;
			return 1;
		}
	return 0;
}

static int snap_col(const bc_map *m, int x, int y, int z, bc_nav_node *out)
{
	uint64_t s;
	int best = -1, bz;

	if (x < 0 || x >= BC_MAP_X || y < 0 || y >= BC_MAP_Y)
		return 0;
	s = bc_map_stand_bits(m->col[y * BC_MAP_X + x]);
	for (; s; s &= s - 1) {
		bz = bc_ctz64(s);
		if (best < 0 || abs(bz - z) < abs(best - z))
			best = bz;
	}
	if (best < 0)
		return 0;
	out->x = (int16_t)x; out->y = (int16_t)y; out->z = (int16_t)best;
	return 1;
}

int bc_nav_snap(const bc_map *m, int x, int y, int z, int radius, bc_nav_node *out)
{
	int r, i;

	if (snap_col(m, x, y, z, out))
		return 1;
	for (r = 1; r <= radius; r++)
		for (i = -r; i <= r; i++) {
			if (snap_col(m, x + i, y - r, z, out) || snap_col(m, x + i, y + r, z, out) ||
			    snap_col(m, x - r, y + i, z, out) || snap_col(m, x + r, y + i, z, out))
				return 1;
		}
	return 0;
}

static int snap_col_dry(const bc_map *m, int x, int y, int z, bc_nav_node *out)
{
	return !bc_map_is_water(m, x, y) && snap_col(m, x, y, z, out) && out->z < BC_MAP_WATER_Z;
}

int bc_nav_snap_dry(const bc_map *m, int x, int y, int z, int radius, bc_nav_node *out)
{
	int r, i;

	if (snap_col_dry(m, x, y, z, out))
		return 1;
	for (r = 1; r <= radius; r++)
		for (i = -r; i <= r; i++) {
			if (snap_col_dry(m, x + i, y - r, z, out) || snap_col_dry(m, x + i, y + r, z, out) ||
			    snap_col_dry(m, x - r, y + i, z, out) || snap_col_dry(m, x + r, y + i, z, out))
				return 1;
		}
	return 0;
}

/* ---------------------------------------------------------------- */
/* Does a measured move fit here                                     */

static void turn(int k, int *x, int *y)
{
	while (k-- > 0) {
		int t = *x;

		*x = -*y;
		*y = t;
	}
}

int nav_move_fits(const bc_nav_moves *t, const bc_map *m, int mvi, bc_nav_node from, int dir)
{
	const bc_nav_move *mv = &t->mv[mvi];
	int k = dir >> 1, dx = bc_nav_dx[dir], dy = bc_nav_dy[dir];
	int tx = from.x + mv->d * dx, ty = from.y + mv->d * dy, tz = from.z + mv->dz;
	int sh = from.z - BC_NAV_MASK_Z0;
	int i, kind;

	kind = nav_node_kind(m, tx, ty, tz);
	if (kind == 0 || (kind == 2 && mv->kind != BC_NAV_CROUCH))
		return 0;

	for (i = 0; i < mv->mask_n; i++) {
		const bc_nav_mcol *c = &t->cols[mv->mask_off + i];
		int cx = c->dx, cy = c->dy;
		uint64_t need = sh >= 0 ? (uint64_t)c->bits << sh : (uint64_t)c->bits >> -sh;

		need &= ~((uint64_t)1 << BC_MAP_WATER_Z);
		if (cx == 0 && cy == 0 && from.z >= 3)
			/* The body is standing at `from`: the room it stands in is
			 * there, whatever the map says. (It may not be there YET:
			 * a node reached by an edit move is a place the plan will
			 * have dug out by the time it leaves it.) */
			need &= ~((uint64_t)7 << (from.z - 3));
		turn(k, &cx, &cy);
		cx += from.x; cy += from.y;
		if (cx < 0 || cx >= BC_MAP_X || cy < 0 || cy >= BC_MAP_Y) {
			if (need)
				return 0;
			continue;
		}
		if (m->col[cy * BC_MAP_X + cx] & need)
			return 0;
	}

	for (i = 1; i <= mv->runup; i++)
		if (nav_node_kind(m, from.x - i * dx, from.y - i * dy, from.z) != 1)
			return 0;

	if (mv->cls == BC_NAV_CLS_DIAG && nav_is_ground_kind(mv->kind)) {
		/* both corner columns must be somewhere to put a foot, about
		 * level: the server moves x then y, and the body is over one
		 * corner or the other on the way */
		int lo = (from.z < tz ? from.z : tz) - 1, hi = (from.z > tz ? from.z : tz) + 1;
		int wet = from.z >= BC_MAP_WATER_Z || tz >= BC_MAP_WATER_Z;
		int c;

		for (c = 0; c < 2; c++) {
			int cx = c ? from.x + dx : from.x, cy = c ? from.y : from.y + dy;
			uint64_t col = bc_map_col(m, cx, cy);
			uint64_t fl = (bc_map_stand_bits(col) | bc_map_crouch_bits(col)) >> (lo < 0 ? 0 : lo);
			int z;

			if (!fl)
				return 0;
			z = (lo < 0 ? 0 : lo) + bc_ctz64(fl);
			if (z > hi || (z >= BC_MAP_WATER_Z && !wet))
				return 0;
		}
	}
	return 1;
}

/* ---------------------------------------------------------------- */
/* Edit moves                                                        */

static int zoned(const bc_nav_policy *pol, int x, int y, int dig)
{
	int i;

	for (i = 0; i < pol->nzones; i++) {
		const bc_nav_zone *z = &pol->zones[i];

		if (x >= z->x0 && x <= z->x1 && y >= z->y0 && y <= z->y1 &&
		    (dig ? z->no_dig : z->no_build))
			return 1;
	}
	return 0;
}

static int may_edit(const bc_nav_policy *pol, int x, int y, int z, int dig)
{
	if (!bc_map_in(x, y, z) || z >= BC_MAP_GROUND_Z)
		return 0;
	if (!pol)
		return 1;
	if (zoned(pol, x, y, dig))
		return 0;
	return !bc_nav_protect_has(pol->protect, x, y, z);
}

/* Is (x, y, z) solid when the step from `from` is made? The map's word,
 * and the floor the body stands on: that one is there by then whatever
 * the map says, for the search reached `from` by building it (the planner
 * otherwise prices later steps against the unedited map, NAV-STATUS (f)8;
 * without this a bridge or a stair could never be planned past its first
 * block in the open). */
static int solid_at(const bc_map *m, bc_nav_node from, int x, int y, int z)
{
	return (x == from.x && y == from.y && z == from.z) || (bc_map_in(x, y, z) && bc_map_solid(m, x, y, z));
}

/* Would a block placed at (x, y, z) have a face to stick to? Below it or
 * beside it -- the floor the builder stands on is beside a bridge's first
 * block, which is what makes a causeway. Not above: that is head room. */
static int has_support(const bc_map *m, bc_nav_node from, int x, int y, int z)
{
	return solid_at(m, from, x, y, z + 1) || solid_at(m, from, x - 1, y, z) || solid_at(m, from, x + 1, y, z) ||
	       solid_at(m, from, x, y - 1, z) || solid_at(m, from, x, y + 1, z);
}

#define ADD_EDIT(X, Y, Z, OP) do { \
		if (n >= 8) return -1; \
		vox[n].x = (int16_t)(X); vox[n].y = (int16_t)(Y); vox[n].z = (int16_t)(Z); \
		op[n] = (OP); n++; \
	} while (0)

static int edits_raw(const bc_nav_moves *t, const bc_map *m, const bc_nav_policy *pol,
                     bc_nav_node from, bc_nav_node to,
                     bc_nav_node vox[8], uint8_t op[8], int *digs, int *builds)
{
	int n = 0, nd = 0, nb = 0, k;
	int bx = to.x, by = to.y, tz = to.z;

	/* (a floor at 0, 1 or 2 has the body's head above the map, which is
	 * air: babel's platform in the sky is at 1, a stair to it ends at 2,
	 * and a bridge off a slab at the map's ceiling is at 0) */
	if (!bc_map_in(bx, by, tz))
		return -1;

	if (to.x == from.x && to.y == from.y) {
		if (tz == from.z - 1) {
			/* PILLAR: room for the head a voxel higher and for the
			 * jump that gets the feet clear, then the block */
			for (k = 5; k >= 4; k--)
				if (from.z - k >= 0 && bc_map_solid(m, bx, by, from.z - k)) {
					if (!may_edit(pol, bx, by, from.z - k, 1))
						return -1;
					ADD_EDIT(bx, by, from.z - k, BC_BLOCK_DESTROY);
					nd++;
				}
			if (!bc_map_solid(m, bx, by, tz)) {
				if (!may_edit(pol, bx, by, tz, 0))
					return -1;
				ADD_EDIT(bx, by, tz, BC_BLOCK_BUILD);
				nb++;
			}
		} else if (tz > from.z && tz - from.z <= BC_NAV_DZ_MAX) {
			/* DIG DOWN: the floor goes, and the body falls onto the floor
			 * under it -- the next voxel, or (a roof, a slab with a room
			 * under it) the first solid one up to a safe drop below, with
			 * nothing between */
			for (k = from.z + 1; k < tz; k++)
				if (bc_map_solid(m, bx, by, k))
					return -1;
			if (!bc_map_solid(m, bx, by, tz))
				return -1;
			if (bc_map_solid(m, bx, by, from.z)) {
				if (!may_edit(pol, bx, by, from.z, 1))
					return -1;
				ADD_EDIT(bx, by, from.z, BC_BLOCK_DESTROY);
				nd++;
			}
		} else {
			return -1;
		}
		goto done;
	}

	if (abs(to.x - from.x) + abs(to.y - from.y) != 1 || abs(tz - from.z) > 1)
		return -1;

	/* What must be air is what the body sweeps walking there -- the
	 * measured stride's volume, not a guess at it: three voxels in the
	 * column entered, a fourth above them when the body arrives a voxel
	 * higher than it will stand (stepping down), a fourth over the
	 * column left when stepping up. Top down, column by column. */
	{
		int mvi = t->walk[BC_NAV_CLS_AXIS][tz - from.z + 1];
		int turns = to.x > from.x ? 0 : to.y > from.y ? 1 : to.x < from.x ? 2 : 3;
		int c, bit;

		/* Out of the sea the motion is not a stride (wading climbs no
		 * bank) but the measured jump onto a bank at 62, and that is the
		 * only place it goes: what is dug is what that jump sweeps. */
		if (from.z >= BC_MAP_WATER_Z)
			mvi = tz == BC_MAP_WATER_Z - 1 ? t->water_out[BC_NAV_CLS_AXIS][1] : -1;
		if (mvi < 0)
			return -1;
		for (c = t->mv[mvi].mask_n - 1; c >= 0; c--) {
			const bc_nav_mcol *mc = &t->cols[t->mv[mvi].mask_off + c];
			int cx = mc->dx, cy = mc->dy;

			turn(turns, &cx, &cy);
			cx += from.x; cy += from.y;
			for (bit = 0; bit < 16; bit++) {
				int z = from.z - BC_NAV_MASK_Z0 + bit;

				if (!((mc->bits >> bit) & 1) || z < 0 || !bc_map_in(cx, cy, z) ||
				    !bc_map_solid(m, cx, cy, z))
					continue;
				if (!may_edit(pol, cx, cy, z, 1))
					return -1;
				ADD_EDIT(cx, cy, z, BC_BLOCK_DESTROY);
				nd++;
			}
		}
	}
	/* and where the body comes to stand: the measured stride down ends
	 * with the body still on the tread above (nav_at's tolerance), so its
	 * mask leaves out the arrival -- a step down under an overhang (out
	 * from under a roof, 2026-11-25) was planned with the roof voxel left
	 * in the head's way */
	for (k = tz - 3; k < tz; k++) {
		int j, have = 0;

		if (k < 0 || !bc_map_solid(m, bx, by, k))
			continue;
		for (j = 0; j < n && !have; j++)
			have = vox[j].x == bx && vox[j].y == by && vox[j].z == k;
		if (have)
			continue;
		if (!may_edit(pol, bx, by, k, 1))
			return -1;
		ADD_EDIT(bx, by, k, BC_BLOCK_DESTROY);
		nd++;
	}
	/* the floor, and under it something for it to stick to */
	if (!bc_map_solid(m, bx, by, tz)) {
		if (!may_edit(pol, bx, by, tz, 0))
			return -1;
		if (!has_support(m, from, bx, by, tz)) {
			if (may_edit(pol, bx, by, tz + 1, 0) && has_support(m, from, bx, by, tz + 1)) {
				ADD_EDIT(bx, by, tz + 1, BC_BLOCK_BUILD);
				nb++;
			} else {
				/* (no stair DOWN into the open: its block would go
				 * against the underside of the floor stood on, which
				 * nobody can aim at -- the owner, 2026-11-25. A stair
				 * down beside a wall is built against the wall) */
				return -1;
			}
		}
		ADD_EDIT(bx, by, tz, BC_BLOCK_BUILD);
		nb++;
	}

done:
	if (digs)
		*digs = nd;
	if (builds)
		*builds = nb;
	return n;
}

/* WHAT A PLAYER COULD DO FROM THERE (the owner's rule, 2026-11-25; the
 * server holds a bot to it: lib_botlink, do_block). A block goes in the
 * air in front of a FACE of a solid voxel that faces the eye and that the
 * eye sees through air; a dig takes a voxel with a face open to the air
 * that faces the eye and is seen. Within the server's reach (5 of the
 * eye, to the middle of the cell). The eye is where the body stands to do
 * the step's edits: over the middle of the floor it starts from, or (a
 * bridge: the far side face of the block under it is seen only so) at its
 * EDGE, 0.75 on toward the step -- the body held up by a corner, looking
 * back down at that face. A PILLAR's block is put in at the top of the
 * jump, over the floor's top face. Each edit of the step is looked at as
 * the map will be by then: earlier digs are air, earlier builds solid,
 * the floor stood on solid. */
static int now_solid(const bc_map *m, bc_nav_node from, const bc_nav_node *vox, const uint8_t *op, int k,
                     int x, int y, int z)
{
	int j, s = (x == from.x && y == from.y && z == from.z) || (bc_map_in(x, y, z) && bc_map_solid(m, x, y, z));

	/* where the body stands is air by then, whatever the unedited map
	 * says (an earlier step of the route dug it) */
	if (x == from.x && y == from.y && z >= from.z - 3 && z < from.z)
		s = 0;
	for (j = 0; j < k; j++)
		if (vox[j].x == x && vox[j].y == y && vox[j].z == z)
			s = op[j] == BC_BLOCK_BUILD;
	return s;
}

static int clear_to(const bc_map *m, bc_nav_node from, const bc_nav_node *vox, const uint8_t *op, int k,
                    const float e[3], const float p[3], int sx, int sy, int sz)
{
	float d[3] = { p[0] - e[0], p[1] - e[1], p[2] - e[2] };
	float len = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
	int n = (int)ceilf(len / 0.1f), i;

	if (n < 1) n = 1;
	for (i = 0; i < n; i++) {
		float t = (float)i / (float)n;
		int x = (int)floorf(e[0] + d[0] * t), y = (int)floorf(e[1] + d[1] * t), z = (int)floorf(e[2] + d[2] * t);

		if (!(x == sx && y == sy && z == sz) && now_solid(m, from, vox, op, k, x, y, z))
			return 0;
	}
	return 1;
}

static int sees_edit(const bc_map *m, bc_nav_node from, const bc_nav_node *vox, const uint8_t *op, int k,
                     const float e[3])
{
	static const int8_t F[6][3] = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } };
	int x = vox[k].x, y = vox[k].y, z = vox[k].z, f, build = op[k] == BC_BLOCK_BUILD;
	float cx = (float)x + 0.5f - e[0], cy = (float)y + 0.5f - e[1], cz = (float)z + 0.5f - e[2];

	if (cx * cx + cy * cy + cz * cz > 5.0f * 5.0f)
		return 0;
	for (f = 0; f < 6; f++) {
		int nb = now_solid(m, from, vox, op, k, x + F[f][0], y + F[f][1], z + F[f][2]);
		float p[3] = { (float)x + 0.5f + 0.5f * (float)F[f][0], (float)y + 0.5f + 0.5f * (float)F[f][1],
		               (float)z + 0.5f + 0.5f * (float)F[f][2] };
		float side = (e[0] - p[0]) * (float)F[f][0] + (e[1] - p[1]) * (float)F[f][1] + (e[2] - p[2]) * (float)F[f][2];

		/* a build: against a solid neighbour's face, the eye on this
		 * cell's side of it; a dig: a face open to the air, the eye
		 * outside it */
		if (build ? (nb && side < 0.0f) : (!nb && side > 0.0f))
			if (clear_to(m, from, vox, op, k, e, p, x, y, z))
				return 1;
	}
	return 0;
}

int bc_nav_sees_edit_from(const bc_map *m, bc_nav_node stand, const float eye[3], int x, int y, int z, int build)
{
	bc_nav_node vox;
	uint8_t op = (uint8_t)(build ? BC_BLOCK_BUILD : BC_BLOCK_DESTROY);

	vox.x = (int16_t)x; vox.y = (int16_t)y; vox.z = (int16_t)z;
	return sees_edit(m, stand, &vox, &op, 0, eye);
}

int bc_nav_sees_edit(const bc_map *m, bc_nav_node stand, int x, int y, int z, int build)
{
	float e[3];

	e[0] = (float)stand.x + 0.5f; e[1] = (float)stand.y + 0.5f; e[2] = (float)stand.z - 2.25f;
	return bc_nav_sees_edit_from(m, stand, e, x, y, z, build);
}

/* What a voxel of height costs by edits where the body stands: the
 * PILLAR move (a jump and a block under the feet) up, the DIG DOWN move
 * (the floor dug, a fall of one) down -- the prices try_edit gives those
 * moves, so the heuristic's guess for a goal far above or below
 * (descent_secs, ascent_secs) is the planner's own price, not a number of
 * the caller's */
float bc_nav_climb_secs(const bc_nav_policy *p)
{
	return p->build_secs + PILLAR_SECS;
}

float bc_nav_dig_down_secs(const bc_nav_policy *p)
{
	return p->dig_secs + DIG_FALL_SECS;
}

int nav_edits(const bc_nav_moves *t, const bc_map *m, const bc_nav_policy *pol,
              bc_nav_node from, bc_nav_node to,
              bc_nav_node vox[8], uint8_t op[8], int *digs, int *builds, int *edge)
{
	int n = edits_raw(t, m, pol, from, to, vox, op, digs, builds), k, tries;

	if (edge)
		*edge = 0;
	if (n <= 0)
		return n;
	for (tries = 0; tries < 2; tries++) {
		float e[3];
		int dx = to.x - from.x, dy = to.y - from.y;

		e[0] = (float)from.x + 0.5f; e[1] = (float)from.y + 0.5f; e[2] = (float)from.z - 2.25f;
		if (dx == 0 && dy == 0 && to.z < from.z)
			e[2] -= 1.3f;               /* a pillar: at the top of the jump */
		if (tries == 1) {
			if (dx == 0 && dy == 0)
				break;
			e[0] += 0.75f * (float)dx; e[1] += 0.75f * (float)dy;
		}
		for (k = 0; k < n; k++)
			if (!(vox[k].x == from.x && vox[k].y == from.y && vox[k].z >= from.z - 3 && vox[k].z < from.z) &&
			    !sees_edit(m, from, vox, op, k, e))
				break;          /* (a dig where the body stands is done by then: an earlier step's) */
		if (k == n) {
			if (edge)
				*edge = tries;
			return n;
		}
	}
	return -1;
}

int bc_nav_step_edits(const bc_nav_route *r, int i, const bc_nav_moves *t, const bc_map *m,
                      bc_nav_node vox[8], uint8_t op[8])
{
	bc_nav_node from;
	int n;

	if (i < 0 || i >= r->n)
		return 0;
	if (r->steps[i].kind != BC_NAV_DIG && r->steps[i].kind != BC_NAV_BUILD &&
	    r->steps[i].kind != BC_NAV_PILLAR)
		return 0;
	from = i ? r->steps[i - 1].to : r->start;
	n = nav_edits(t, m, NULL, from, r->steps[i].to, vox, op, NULL, NULL, NULL);
	return n < 0 ? 0 : n;
}

/* ---------------------------------------------------------------- */
/* The search                                                        */

typedef struct rec {
	uint32_t key;               /* nav_pack of the node */
	uint32_t parent;            /* pool index; self for the start */
	uint32_t hpos;              /* place in the heap; NOWHERE when closed */
	float g, f;
	int16_t move;
	uint8_t kind, dir, runup, digs, builds, flags;
	uint8_t used;               /* blocks spent on the way here */
	uint8_t pad_[3];
} rec;

#define NOWHERE 0xFFFFFFFFu

struct bc_nav_search {
	const bc_nav_moves *t;
	const bc_map *m;
	const bc_nav_policy *pol;
	bc_nav_node start, goal;
	int32_t radius;
	int32_t status;
	uint32_t max_nodes, n_nodes, hash_mask, heap_n, expansions, map_rev;
	uint32_t found, best;
	float best_h, inv_speed;
	rec *recs;
	uint32_t *hash;             /* pool index + 1; 0: empty */
	uint32_t *heap;
	uint64_t *sea;              /* two bit maps of the columns, for
	                               sea_has_exit: water, and reached */
};

enum { ROW_W = BC_MAP_X / 64, SEA_WORDS = 2 * BC_MAP_Y * ROW_W };

static uint32_t hash_size(uint32_t max_nodes)
{
	uint32_t h = 64;

	while (h < max_nodes * 2)
		h <<= 1;
	return h;
}

static size_t align8(size_t v)
{
	return (v + 7) & ~(size_t)7;
}

size_t bc_nav_search_size(uint32_t max_nodes)
{
	return align8(sizeof(bc_nav_search)) + align8((size_t)max_nodes * sizeof(rec)) +
	       (size_t)hash_size(max_nodes) * sizeof(uint32_t) +
	       align8((size_t)max_nodes * sizeof(uint32_t)) +
	       (size_t)SEA_WORDS * sizeof(uint64_t);
}

bc_nav_search *bc_nav_search_init(void *mem, uint32_t max_nodes)
{
	bc_nav_search *s = mem;
	unsigned char *p = mem;

	memset(s, 0, sizeof *s);
	s->max_nodes = max_nodes;
	s->hash_mask = hash_size(max_nodes) - 1;
	p += align8(sizeof *s);
	s->recs = (rec *)(void *)p;
	p += align8((size_t)max_nodes * sizeof(rec));
	s->hash = (uint32_t *)(void *)p;
	p += (size_t)(s->hash_mask + 1) * sizeof(uint32_t);
	s->heap = (uint32_t *)(void *)p;
	p += align8((size_t)max_nodes * sizeof(uint32_t));
	s->sea = (uint64_t *)(void *)p;
	s->status = BC_NAV_FAILED;
	return s;
}

static bc_nav_node unpack(uint32_t key)
{
	bc_nav_node n;

	n.x = (int16_t)(key & 511u);
	n.y = (int16_t)((key >> 9) & 511u);
	n.z = (int16_t)((key >> 18) & 63u);
	return n;
}

static float heur(const bc_nav_search *s, bc_nav_node n)
{
	/* Every move goes along an axis or a diagonal, so the least ground
	 * to cover is the octile distance, and nothing covers ground faster
	 * than a sprint (a jump's flight is slower): admissible, and far
	 * tighter than the straight line on a map of this size. */
	float dx = fabsf((float)(n.x - s->goal.x)) - (float)s->radius;
	float dy = fabsf((float)(n.y - s->goal.y)) - (float)s->radius;
	float lo, hi, down = (float)(s->goal.z - n.z - BC_NAV_DZ_MAX);

	if (dx < 0.0f) dx = 0.0f;
	if (dy < 0.0f) dy = 0.0f;
	lo = dx < dy ? dx : dy;
	hi = dx < dy ? dy : dx;
	/* policy.descent_secs (nav.h): the goal far below, on a search made
	 * for a body that has no way down without edits */
	float up = (float)(n.z - s->goal.z - 2);

	return (hi + 0.41421356f * lo) * s->inv_speed +
	       (down > 0.0f && s->pol->descent_secs > 0.0f ? down * s->pol->descent_secs : 0.0f) +
	       (up > 0.0f && s->pol->ascent_secs > 0.0f ? up * s->pol->ascent_secs : 0.0f);
}

/* Within `radius` of the goal: a distance, as a script means it (ctf
 * counts a carrier in at 3 from the tent, round) -- not a square, whose
 * corners are 1.4 times as far (radius 2 took a carrier to 2.9 from its
 * tent's column, and 3.1 from the tent: no capture, for ever). */
static int is_goal(const bc_nav_search *s, bc_nav_node n)
{
	int dx = n.x - s->goal.x, dy = n.y - s->goal.y;

	return dx * dx + dy * dy <= s->radius * s->radius &&
	       (s->pol->goal_exact_z ? n.z == s->goal.z : abs(n.z - s->goal.z) <= 1);
}

/* --- heap --- */

static int heap_less(const bc_nav_search *s, uint32_t a, uint32_t b)
{
	const rec *ra = &s->recs[a], *rb = &s->recs[b];

	if (ra->f != rb->f)
		return ra->f < rb->f;
	return ra->g > rb->g;       /* of equals, the one further along */
}

static void heap_up(bc_nav_search *s, uint32_t i)
{
	uint32_t v = s->heap[i];

	while (i > 0) {
		uint32_t p = (i - 1) / 2;

		if (!heap_less(s, v, s->heap[p]))
			break;
		s->heap[i] = s->heap[p];
		s->recs[s->heap[i]].hpos = i;
		i = p;
	}
	s->heap[i] = v;
	s->recs[v].hpos = i;
}

static void heap_down(bc_nav_search *s, uint32_t i)
{
	uint32_t v = s->heap[i];

	for (;;) {
		uint32_t c = 2 * i + 1;

		if (c >= s->heap_n)
			break;
		if (c + 1 < s->heap_n && heap_less(s, s->heap[c + 1], s->heap[c]))
			c++;
		if (!heap_less(s, s->heap[c], v))
			break;
		s->heap[i] = s->heap[c];
		s->recs[s->heap[i]].hpos = i;
		i = c;
	}
	s->heap[i] = v;
	s->recs[v].hpos = i;
}

static uint32_t heap_pop(bc_nav_search *s)
{
	uint32_t top = s->heap[0];

	s->heap_n--;
	if (s->heap_n) {
		s->heap[0] = s->heap[s->heap_n];
		heap_down(s, 0);
	}
	s->recs[top].hpos = NOWHERE;
	return top;
}

/* --- nodes --- */

/* The pool index of a node, made if new. NOWHERE when the pool is full. */
static uint32_t node_get(bc_nav_search *s, uint32_t key, int *is_new)
{
	uint32_t h = (key * 2654435761u) & s->hash_mask;

	for (;;) {
		uint32_t v = s->hash[h];

		if (v == 0)
			break;
		if (s->recs[v - 1].key == key) {
			*is_new = 0;
			return v - 1;
		}
		h = (h + 1) & s->hash_mask;
	}
	if (s->n_nodes >= s->max_nodes)
		return NOWHERE;
	s->hash[h] = s->n_nodes + 1;
	s->recs[s->n_nodes].key = key;
	s->recs[s->n_nodes].hpos = NOWHERE;
	*is_new = 1;
	return s->n_nodes++;
}

typedef struct edge {
	bc_nav_node to;
	float secs;
	int16_t move;
	uint8_t kind, dir, runup, digs, builds, flags;
} edge;

/* What the policy adds to an edge's time. Negative: refused. */
static float policy_cost(const bc_nav_search *s, bc_nav_node from, const edge *e)
{
	const bc_nav_policy *pol = s->pol;
	float c = 0.0f;
	int i, fails;

	if (e->to.z >= BC_MAP_WATER_Z) {
		/* lethal water is never entered; a body already in it wades */
		if (pol->water_lethal && from.z < BC_MAP_WATER_Z)
			return -1.0f;
		c += pol->water_secs;
	}
	if (from.z >= BC_MAP_WATER_Z) {
		/* what the time in the water costs in health (nav.h, WATER THAT
		 * HURTS): the step is done wading, whatever it ends on */
		float dmg = pol->water_damage;

		if (pol->water_lethal && dmg < BC_NAV_LETHAL_DAMAGE)
			dmg = BC_NAV_LETHAL_DAMAGE;
		if (dmg > 0.0f)
			c += e->secs * dmg * BC_NAV_HP_SECS;
	}
	for (i = 0; i < pol->ndanger; i++) {
		const bc_nav_danger *d = &pol->danger[i];
		float dx = (float)e->to.x + 0.5f - d->x, dy = (float)e->to.y + 0.5f - d->y;
		float dist = sqrtf(dx * dx + dy * dy);

		if (dist < d->radius)
			c += d->weight * (1.0f - dist / d->radius);
	}
	fails = bc_nav_fail_count(pol->fail, from, e->to, e->kind, pol->now);
	if (fails)
		c += pol->fail_secs * (float)(1 << (fails > 6 ? 6 : fails - 1));
	return c;
}

static void relax(bc_nav_search *s, uint32_t ci, bc_nav_node from, const edge *e)
{
	float extra = policy_cost(s, from, e);
	float g;
	uint32_t ni;
	rec *r;
	int is_new = 0;
	unsigned used = s->recs[ci].used + e->builds;

	if (extra < 0.0f || used > s->pol->blocks)
		return;
	if (s->pol->scope > 0 &&
	    (abs(e->to.x - s->start.x) > s->pol->scope || abs(e->to.y - s->start.y) > s->pol->scope))
		return;                 /* a local search: not out of its scope */
	g = s->recs[ci].g + e->secs + extra;
	ni = node_get(s, nav_pack(e->to), &is_new);
	if (ni == NOWHERE) {
		s->status = BC_NAV_FAILED;      /* out of nodes: seen by the caller */
		return;
	}
	r = &s->recs[ni];
	if (!is_new && r->g <= g)
		return;
	/* (a closed node found a cheaper way to is simply opened again: the
	 * policy's prices need not be consistent with the heuristic) */
	r->g = g;
	r->f = g + heur(s, e->to);
	r->parent = ci;
	r->move = e->move;
	r->kind = e->kind; r->dir = e->dir; r->runup = e->runup;
	r->digs = e->digs; r->builds = e->builds; r->flags = e->flags;
	r->used = (uint8_t)used;
	if (r->hpos == NOWHERE) {
		s->heap[s->heap_n] = ni;
		r->hpos = s->heap_n;
		s->heap_n++;
	}
	heap_up(s, r->hpos);
}

/* What a stride on land takes, coming after whatever brought the body to
 * the node (nav.h, STRIDES IN CONTEXT): the measured time of that stride
 * after a climb, a level run, a step down or a standstill, and the
 * measured price of the turn if the direction changes.
 *
 * This makes an edge's cost depend on the edge before it, which a search
 * over places (and not over places-and-headings, eight times the nodes)
 * can only follow along the one way it currently knows to each node. It is
 * a good estimate and not a proof of the cheapest route: two ways to a
 * node that differ by less than a turn may be ranked wrongly. What it buys
 * is routes that are honest about stairs and do not zigzag, in the same
 * number of nodes. */
static float stride_secs(const bc_nav_search *s, uint32_t ci, const bc_nav_move *mv, int dir)
{
	const bc_nav_moves *t = s->t;
	const rec *p = &s->recs[ci];
	int before = BC_NAV_AFTER_REST;
	float secs;

	if ((mv->kind != BC_NAV_WALK && mv->kind != BC_NAV_SPRINT) || mv->from_water ||
	    (mv->kind == BC_NAV_WALK && mv->dz >= 0))
		return mv->secs;        /* crouched, wading, or walking where a
		                           sprint does not fit: as timed alone */
	if (p->parent != ci && (p->kind == BC_NAV_WALK || p->kind == BC_NAV_SPRINT) &&
	    p->move >= 0 && !t->mv[p->move].from_water) {
		int pdz = t->mv[p->move].dz;

		before = pdz < 0 ? BC_NAV_AFTER_UP : pdz > 0 ? BC_NAV_AFTER_DOWN : BC_NAV_AFTER_LEVEL;
	}
	secs = t->stride_secs[mv->cls][before][mv->dz + 1];
	if (before != BC_NAV_AFTER_REST && p->dir != dir && p->dir < 8) {
		int turn = (dir - p->dir) & 7;

		secs += t->turn_secs[p->dir & 1][turn > 4 ? 8 - turn : turn];
	}
	return secs > 0.0f ? secs : mv->secs;
}

static void edge_from_move(const bc_nav_search *s, uint32_t ci, edge *e, bc_nav_node a, int mvi,
                           int dir)
{
	const bc_nav_move *mv = &s->t->mv[mvi];

	memset(e, 0, sizeof *e);
	e->to.x = (int16_t)(a.x + mv->d * bc_nav_dx[dir]);
	e->to.y = (int16_t)(a.y + mv->d * bc_nav_dy[dir]);
	e->to.z = (int16_t)(a.z + mv->dz);
	e->secs = stride_secs(s, ci, mv, dir);
	e->move = (int16_t)mvi;
	e->kind = mv->kind;
	e->dir = (uint8_t)dir;
	e->runup = mv->runup;
	if (e->to.z >= BC_MAP_WATER_Z)
		e->flags |= BC_NAV_F_WATER;
	if (mv->kind == BC_NAV_JUMP || mv->kind == BC_NAV_RUNJUMP) {
		/* the table timed it from a standing start at the far end of
		 * the run-up; getting there and squaring up is not free */
		float cell = (dir & 1) ? 1.41421356f : 1.0f;

		e->secs += 0.25f + (float)mv->runup * cell / s->t->walk_speed;
	}
}

static void try_move(bc_nav_search *s, uint32_t ci, bc_nav_node a, int mvi, int dir)
{
	edge e;

	if (mvi < 0 || !nav_move_fits(s->t, s->m, mvi, a, dir))
		return;
	/* (a move measured anywhere is the same at the map's top: above it
	 * is air to the physics, demoncore.c phys_solid -- nav_test's
	 * top_of_map_jumps) */
	edge_from_move(s, ci, &e, a, mvi, dir);
	relax(s, ci, a, &e);
}

static void try_edit(bc_nav_search *s, uint32_t ci, bc_nav_node a, bc_nav_node to, int dir)
{
	const bc_nav_policy *pol = s->pol;
	bc_nav_node vox[8];
	uint8_t op[8];
	edge e;
	int digs = 0, builds = 0, n;
	float move_secs;

	/* From a floor the search itself built (a bridge: the map does not have
	 * it), the building goes on STRAIGHT: a
	 * bridge does not fan out into the void in every direction from each
	 * of its blocks. Without this, edits planned across open space made
	 * the soak's exact searches run out of nodes on Parkour2 (98 of 200
	 * pairs, was 41). */
	if (dir != 8 && !bc_map_solid(s->m, a.x, a.y, a.z)) {
		uint32_t k = ci;
		int built = 0;

		/* straight on -- or round a corner where the floor built leans on
		 * something of the map's (a stair down a wall turns along it) */
		if (s->recs[ci].parent == ci)
			return;
		if (dir != s->recs[ci].dir && !(bc_map_solid(s->m, a.x + 1, a.y, a.z) || bc_map_solid(s->m, a.x - 1, a.y, a.z) ||
		                                bc_map_solid(s->m, a.x, a.y + 1, a.z) || bc_map_solid(s->m, a.x, a.y - 1, a.z)))
			return;
		/* and only so far: a bridge of 4 to the next roof, a stair down a
		 * wall 8 steps to where a drop is safe -- not a causeway across
		 * the map, which every edge would then try. A stair UP is built
		 * against something (a cliff), not into the open */
		/* (a body that has no way down without them -- the caller set
		 * descent_secs -- may go on further: off a slab at the top of the
		 * map, a bridge of 16 to what it can drop onto; the search is
		 * greedy downward then, it does not fan out) */
		int far = s->pol->descent_secs > 0.0f;
		int most = to.z > a.z ? (far ? 24 : 8) : (far ? 16 : 4);

		if (to.z < a.z)
			return;
		while (k != NOWHERE && s->recs[k].parent != k) {
			bc_nav_node p = unpack(s->recs[k].key);

			if (bc_map_solid(s->m, p.x, p.y, p.z) || ++built >= most)
				break;
			k = s->recs[k].parent;
		}
		if (built >= most)
			return;
	}
	n = nav_edits(s->t, s->m, pol, a, to, vox, op, &digs, &builds, NULL);
	if (n <= 0)
		return;
	if ((digs && !pol->may_dig) || (builds && !pol->may_build))
		return;
	memset(&e, 0, sizeof e);
	e.to = to;
	e.dir = (uint8_t)dir;
	e.digs = (uint8_t)digs;
	e.builds = (uint8_t)builds;
	e.move = -1;
	/* not up into the top of the map (z under 3: a body's head over the
	 * ceiling) unless that is where it is going: a route over the top of
	 * the map was a way onto sky slabs with no way down (keidoro) */
	if (to.z < 3 && to.z < a.z && s->goal.z >= 3)
		return;
	if (dir == 8) {
		e.kind = (uint8_t)(to.z < a.z ? BC_NAV_PILLAR : BC_NAV_DIG);
		move_secs = to.z < a.z ? PILLAR_SECS : DIG_FALL_SECS + 0.05f * (float)(to.z - a.z - 1);  /* a jump; a fall */
	} else {
		int mvi = s->t->walk[BC_NAV_CLS_AXIS][to.z - a.z + 1];

		if (mvi < 0)
			return;
		e.kind = (uint8_t)(builds ? BC_NAV_BUILD : BC_NAV_DIG);
		e.move = (int16_t)mvi;
		move_secs = s->t->mv[mvi].secs + 0.3f;  /* stopping to work */
	}
	e.secs = (float)digs * pol->dig_secs + (float)builds * pol->build_secs + move_secs;
	relax(s, ci, a, &e);
}

/* THE WAYS OUT OF THE SEA from water node `a` in direction `dir`, whose
 * neighbour column is not water: the measured move onto the bank where the
 * bank is low enough (a jump onto 62; nav.h, WATER), else -- digging
 * allowed, along an axis -- the bank cut down to 62 and the same jump.
 * Returns whether there is one, and with a node (ci) relaxes it. The
 * search's expansion and the flood that asks "is there any way out of this
 * sea" (sea_has_exit) are this one function, so they cannot disagree. */
static int water_exit(bc_nav_search *s, uint32_t ci, bc_nav_node a, int dir)
{
	const bc_nav_moves *t = s->t;
	const bc_map *m = s->m;
	const bc_nav_policy *pol = s->pol;
	int cls = dir & 1, bx = a.x + bc_nav_dx[dir], by = a.y + bc_nav_dy[dir], up, out;
	uint64_t col, sb;
	edge e;

	if (bx < 0 || bx >= BC_MAP_X || by < 0 || by >= BC_MAP_Y)
		return 0;
	col = m->col[by * BC_MAP_X + bx];
	sb = bc_map_stand_bits(col);
	for (up = 1; up <= 3; up++)
		if ((sb >> (BC_MAP_WATER_Z - up)) & 1) {
			int mvi = t->water_out[cls][up];

			if (mvi >= 0 &&
			    (t->mv[mvi].kind == BC_NAV_WALK ||
			     (pol->may_jump && t->mv[mvi].margin >= pol->min_margin)) &&
			    nav_move_fits(t, m, mvi, a, dir)) {
				if (ci != NOWHERE) {
					edge_from_move(s, ci, &e, a, mvi, dir);
					relax(s, ci, a, &e);
				}
				return 1;
			}
			break;
		}
	out = t->water_out[BC_NAV_CLS_AXIS][1];
	if (pol->may_dig && pol->may_jump && cls == BC_NAV_CLS_AXIS && out >= 0 &&
	    t->mv[out].margin >= pol->min_margin && ((col >> (BC_MAP_WATER_Z - 1)) & 1)) {
		bc_nav_node vox[8], to;
		uint8_t op[8];
		int digs = 0, builds = 0, n;

		to.x = (int16_t)bx; to.y = (int16_t)by; to.z = BC_MAP_WATER_Z - 1;
		n = nav_edits(t, m, pol, a, to, vox, op, &digs, &builds, NULL);
		if (n <= 0 || builds)
			return 0;
		if (ci != NOWHERE) {
			memset(&e, 0, sizeof e);
			e.to = to;
			e.dir = (uint8_t)dir;
			e.digs = (uint8_t)digs;
			e.kind = BC_NAV_DIG;
			e.move = (int16_t)out;
			/* the digging, the jump, squaring up for it, stopping to work */
			e.secs = (float)digs * pol->dig_secs + t->mv[out].secs + 0.25f + 0.3f;
			relax(s, ci, a, &e);
		}
		return 1;
	}
	return 0;
}

static void expand(bc_nav_search *s, uint32_t ci)
{
	const bc_nav_moves *t = s->t;
	const bc_map *m = s->m;
	const bc_nav_policy *pol = s->pol;
	bc_nav_node a = unpack(s->recs[ci].key);
	int akind = nav_node_kind(m, a.x, a.y, a.z);
	int edits = pol->may_dig || pol->may_build;
	int dir;

	if (akind == 0)
		akind = 1;      /* the map changed under the search: carry on */

	for (dir = 0; dir < 8; dir++) {
		int cls = dir & 1;
		int bx = a.x + bc_nav_dx[dir], by = a.y + bc_nav_dy[dir];
		uint64_t col, sb, both, w;
		int walked_z = -1;

		if (bx < 0 || bx >= BC_MAP_X || by < 0 || by >= BC_MAP_Y)
			continue;
		col = m->col[by * BC_MAP_X + bx];
		sb = bc_map_stand_bits(col);
		both = sb | bc_map_crouch_bits(col);

		if (a.z >= BC_MAP_WATER_Z) {
			/* in the sea: wade, or get out where the bank allows */
			if ((sb >> BC_MAP_WATER_Z) & 1)
				try_move(s, ci, a, t->wade[cls], dir);
			else
				water_exit(s, ci, a, dir);
			continue;
		}

		/* the floor a body walking that way would come to */
		w = both >> (a.z > 0 ? a.z - 1 : 0);
		if (w) {
			int zb = (a.z > 0 ? a.z - 1 : 0) + bc_ctz64(w), dz = zb - a.z;
			int stand = (int)((sb >> zb) & 1);

			if (dz <= 1) {
				int mvi;

				if (!stand || akind == 2) {
					mvi = t->crouch[cls][dz + 1];
				} else {
					mvi = dz >= 0 ? t->sprint[cls][dz + 1] : -1;
					if (mvi < 0 || !nav_move_fits(t, m, mvi, a, dir))
						mvi = t->walk[cls][dz + 1];
				}
				if (mvi >= 0 && nav_move_fits(t, m, mvi, a, dir)) {
					edge e;

					edge_from_move(s, ci, &e, a, mvi, dir);
					relax(s, ci, a, &e);
					walked_z = zb;
				}
			} else if (dz <= BC_NAV_DZ_MAX && cls == BC_NAV_CLS_AXIS && akind == 1 && stand) {
				int mvi = t->drop[cls][dz - BC_NAV_DZ_MIN];
				/* Into water the feet go a voxel further than the node
				 * says (nav.h: a water node has z = 63 and the feet at
				 * 64), and water breaks no fall here: what the landing
				 * costs is what the drop one deeper costs. The deepest
				 * drop measured has none deeper to ask, and is refused
				 * -- the follower, which simulates the real thing,
				 * would refuse it at the edge every time. */
				int hurt = zb >= BC_MAP_WATER_Z ?
				           (dz < BC_NAV_DZ_MAX ? t->drop[cls][dz + 1 - BC_NAV_DZ_MIN] : -1) : mvi;

				if (mvi >= 0 && hurt >= 0 && t->mv[hurt].damage <= pol->max_fall_damage)
					try_move(s, ci, a, mvi, dir);
			}
		}

		if (pol->may_jump && walked_z < 0 && akind == 1) {
			int d;

			for (d = 1; d <= BC_NAV_JUMP_DMAX; d++) {
				int tx = a.x + d * bc_nav_dx[dir], ty = a.y + d * bc_nav_dy[dir];
				int zlo = a.z + BC_NAV_DZ_MIN;
				uint64_t bits;

				if (tx < 0 || tx >= BC_MAP_X || ty < 0 || ty >= BC_MAP_Y)
					break;
				if (zlo < 0)
					zlo = 0;
				bits = bc_map_stand_bits(m->col[ty * BC_MAP_X + tx]) >> zlo;
				for (; bits; bits &= bits - 1) {
					int zt = zlo + bc_ctz64(bits), dz = zt - a.z, mvi;

					if (dz > BC_NAV_DZ_MAX || zt >= BC_MAP_WATER_Z)
						break;
					if (d == 1 && dz > -2)
						continue;
					mvi = t->jump[cls][d][dz - BC_NAV_DZ_MIN];
					if (mvi < 0 || t->mv[mvi].margin < pol->min_margin ||
					    t->mv[mvi].damage > pol->max_fall_damage)
						continue;
					try_move(s, ci, a, mvi, dir);
				}
			}
		}

		if (edits && cls == BC_NAV_CLS_AXIS && akind == 1) {
			static const int lvl[3] = {0, 1, -1};
			int i;

			for (i = 0; i < 3; i++) {
				bc_nav_node to;

				to.x = (int16_t)bx; to.y = (int16_t)by; to.z = (int16_t)(a.z + lvl[i]);
				if (to.z == walked_z || to.z > BC_MAP_GROUND_Z)
					continue;
				try_edit(s, ci, a, to, dir);
			}
		}
	}

	if (edits && akind == 1 && a.z < BC_MAP_WATER_Z) {
		bc_nav_node to = a;

		to.z = (int16_t)(a.z - 1);
		if (pol->may_build)
			try_edit(s, ci, a, to, 8);
		to.z = (int16_t)(a.z + 1);
		if (pol->may_dig) {
			/* the floor under this one, through the air between: a fall
			 * that does not hurt (dig down onto the next voxel, or drop
			 * through a dug roof onto what is under it) */
			uint64_t col = m->col[a.y * BC_MAP_X + a.x] >> (a.z + 1);
			int zb = col ? a.z + 1 + bc_ctz64(col) : 64;

			if (zb > a.z + 1 && zb - a.z <= BC_NAV_DZ_MAX && zb < BC_MAP_WATER_Z &&
			    t->drop[BC_NAV_CLS_AXIS][zb - a.z - BC_NAV_DZ_MIN] >= 0 &&
			    t->mv[t->drop[BC_NAV_CLS_AXIS][zb - a.z - BC_NAV_DZ_MIN]].damage <= pol->max_fall_damage)
				to.z = (int16_t)zb;
			try_edit(s, ci, a, to, 8);
		}
	}
}

/* ---------------------------------------------------------------- */
/* Is there a way out of this sea                                    */

/* A row of the map is 512 bits in eight words, bit x of the row. */
static void row_shl(uint64_t *d, const uint64_t *src, int k)
{
	int w = k >> 6, b = k & 63, i;

	for (i = ROW_W - 1; i >= 0; i--) {
		uint64_t v = i - w >= 0 ? src[i - w] << b : 0;

		if (b && i - w - 1 >= 0)
			v |= src[i - w - 1] >> (64 - b);
		d[i] = v;
	}
}

static void row_shr(uint64_t *d, const uint64_t *src, int k)
{
	int w = k >> 6, b = k & 63, i;

	for (i = 0; i < ROW_W; i++) {
		uint64_t v = i + w < ROW_W ? src[i + w] >> b : 0;

		if (b && i + w + 1 < ROW_W)
			v |= src[i + w + 1] << (64 - b);
		d[i] = v;
	}
}

/* Spread the bits of `r` along the row through the runs of `w` they are
 * in, both ways: doubling shifts, nine each way, whatever the run's length. */
static void row_fill(uint64_t *r, const uint64_t *w)
{
	uint64_t p[ROW_W], tmp[ROW_W];
	int dirn, k, i;

	for (dirn = 0; dirn < 2; dirn++) {
		memcpy(p, w, sizeof p);
		for (k = 1; k < BC_MAP_X; k <<= 1) {
			if (dirn) row_shr(tmp, r, k); else row_shl(tmp, r, k);
			for (i = 0; i < ROW_W; i++)
				r[i] |= tmp[i] & p[i];
			if (dirn) row_shr(tmp, p, k); else row_shl(tmp, p, k);
			for (i = 0; i < ROW_W; i++)
				p[i] &= tmp[i];
		}
	}
}

/* nav.h, WATER: from water node `start`, can the body leave the sea it is
 * in at all, under this search's policy? The sea is flooded as bit rows --
 * every water column joined to the start's by sides or corners, which is
 * all a body could wade to and a little more (a diagonal between two rocks
 * that the search would refuse) -- and each of its columns with a
 * neighbour that is not water is asked for a way out, by the function the
 * search itself expands with. "No" is therefore never said of a sea the
 * search could leave. */
static int sea_has_exit(bc_nav_search *s, bc_nav_node start)
{
	const bc_map *m = s->m;
	uint64_t *water = s->sea, *reach = s->sea + BC_MAP_Y * ROW_W;
	uint64_t n[ROW_W], l[ROW_W], r[ROW_W];
	int x, y, i, changed, pass;

	for (y = 0; y < BC_MAP_Y; y++)
		for (i = 0; i < ROW_W; i++) {
			const uint64_t *c = &m->col[y * BC_MAP_X + i * 64];
			uint64_t bits = 0;

			for (x = 0; x < 64; x++)
				bits |= (uint64_t)(c[x] == (uint64_t)1 << BC_MAP_WATER_Z) << x;
			water[y * ROW_W + i] = bits;
		}
	memset(reach, 0, (size_t)BC_MAP_Y * ROW_W * sizeof(uint64_t));
	reach[start.y * ROW_W + (start.x >> 6)] = (uint64_t)1 << (start.x & 63);
	row_fill(&reach[start.y * ROW_W], &water[start.y * ROW_W]);

	/* down the map and up it again until nothing is added */
	for (pass = 0, changed = 1; changed; pass++) {
		changed = 0;
		for (y = (pass & 1) ? BC_MAP_Y - 1 : 0; y >= 0 && y < BC_MAP_Y; y += (pass & 1) ? -1 : 1) {
			uint64_t *row = &reach[y * ROW_W], add = 0;

			for (i = 0; i < ROW_W; i++)
				n[i] = (y > 0 ? row[i - ROW_W] : 0) | (y < BC_MAP_Y - 1 ? row[i + ROW_W] : 0);
			row_shl(l, n, 1);
			row_shr(r, n, 1);
			for (i = 0; i < ROW_W; i++) {
				n[i] = (n[i] | l[i] | r[i]) & water[y * ROW_W + i];
				add |= n[i] & ~row[i];
			}
			if (!add)
				continue;
			for (i = 0; i < ROW_W; i++)
				row[i] |= n[i];
			row_fill(row, &water[y * ROW_W]);
			changed = 1;
		}
	}

	/* the shore: reached columns with a neighbour that is not water */
	for (y = 0; y < BC_MAP_Y; y++) {
		for (i = 0; i < ROW_W; i++) {
			n[i] = water[y * ROW_W + i];
			if (y > 0) n[i] &= water[(y - 1) * ROW_W + i];
			if (y < BC_MAP_Y - 1) n[i] &= water[(y + 1) * ROW_W + i];
		}
		row_shl(l, n, 1);
		row_shr(r, n, 1);
		for (i = 0; i < ROW_W; i++) {
			uint64_t shore = reach[y * ROW_W + i] & ~(n[i] & l[i] & r[i]);

			for (; shore; shore &= shore - 1) {
				bc_nav_node a;
				int dir;

				a.x = (int16_t)(i * 64 + bc_ctz64(shore));
				a.y = (int16_t)y;
				a.z = BC_MAP_WATER_Z;
				for (dir = 0; dir < 8; dir++)
					if (water_exit(s, NOWHERE, a, dir))
						return 1;
			}
		}
	}
	return 0;
}

int bc_nav_plan_begin(bc_nav_search *s, const bc_nav_moves *t, const bc_map *m,
                      const bc_nav_policy *pol, bc_nav_node start, bc_nav_node goal,
                      int goal_radius)
{
	int is_new = 0;
	uint32_t si;

	s->t = t; s->m = m; s->pol = pol;
	s->start = start; s->goal = goal;
	s->radius = goal_radius < 0 ? 0 : goal_radius;
	s->n_nodes = 0; s->heap_n = 0; s->expansions = 0;
	s->map_rev = m->rev;
	s->found = NOWHERE; s->best = NOWHERE; s->best_h = 1e30f;
	s->inv_speed = 1.0f / (t->sprint_speed > 0.0f ? t->sprint_speed : 10.4f);
	if (pol && pol->h_weight > 1.0f)
		s->inv_speed *= pol->h_weight;      /* a greedier search: nav.h, h_weight */
	memset(s->hash, 0, (size_t)(s->hash_mask + 1) * sizeof(uint32_t));
	s->status = BC_NAV_FAILED;
	if (!nav_node_kind(m, start.x, start.y, start.z))
		return 0;
	/* in a sea with no way out, for a goal that is not in the water: no
	 * (nav.h, WATER). A goal at 62 may be met by a water node beside it. */
	if (start.z >= BC_MAP_WATER_Z && goal.z < BC_MAP_WATER_Z - 1 && !sea_has_exit(s, start))
		return 1;
	si = node_get(s, nav_pack(start), &is_new);
	if (si == NOWHERE)
		return 0;
	memset(&s->recs[si], 0, sizeof(rec));
	s->recs[si].key = nav_pack(start);
	s->recs[si].parent = si;
	s->recs[si].move = -1;
	s->recs[si].g = 0.0f;
	s->recs[si].f = heur(s, start);
	s->heap[0] = si;
	s->recs[si].hpos = 0;
	s->heap_n = 1;
	s->status = BC_NAV_MORE;
	return 1;
}

int bc_nav_plan_step(bc_nav_search *s, int budget)
{
	if (s->status != BC_NAV_MORE)
		return s->status;
	while (budget-- > 0) {
		uint32_t ci;
		bc_nav_node n;
		float h;

		if (s->heap_n == 0) {
			s->status = BC_NAV_FAILED;
			break;
		}
		ci = heap_pop(s);
		n = unpack(s->recs[ci].key);
		if (is_goal(s, n)) {
			s->found = ci;
			s->status = BC_NAV_DONE;
			break;
		}
		h = s->recs[ci].f - s->recs[ci].g;
		if (h < s->best_h) {
			s->best_h = h;
			s->best = ci;
		}
		s->expansions++;
		expand(s, ci);
		if (s->status != BC_NAV_MORE)
			break;
	}
	return s->status;
}

int bc_nav_plan_route(const bc_nav_search *s, bc_nav_route *out)
{
	uint32_t end = s->status == BC_NAV_DONE ? s->found : s->best;
	uint32_t i;
	int n = 0, skip, k;

	memset(out, 0, offsetof(bc_nav_route, steps));
	out->start = s->start;
	out->goal = s->goal;
	out->map_rev = s->map_rev;
	out->partial = s->status != BC_NAV_DONE;
	if (end == NOWHERE)
		return 0;
	for (i = end; s->recs[i].parent != i; i = s->recs[i].parent)
		n++;
	skip = n > BC_NAV_ROUTE_MAX ? n - BC_NAV_ROUTE_MAX : 0;
	if (skip)
		out->partial = 1;
	out->n = n - skip;
	/* the chain runs goal to start: fill from the back, dropping the
	 * steps nearest the goal if there are too many */
	k = n;
	for (i = end; s->recs[i].parent != i; i = s->recs[i].parent) {
		const rec *r = &s->recs[i];

		k--;
		if (k < out->n) {
			bc_nav_step *st = &out->steps[k];

			st->to = unpack(r->key);
			st->kind = r->kind; st->dir = r->dir; st->runup = r->runup;
			st->digs = r->digs; st->builds = r->builds; st->flags = r->flags;
			st->move = r->move;
			st->secs = r->g - s->recs[r->parent].g;
			out->secs += st->secs;
		}
	}
	return out->n;
}

uint32_t bc_nav_plan_expansions(const bc_nav_search *s)
{
	return s->expansions;
}

uint32_t bc_nav_plan_nodes(const bc_nav_search *s)
{
	return s->n_nodes;
}
