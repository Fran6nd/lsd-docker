/* build_test.c -- building as the purpose: `build_at` and `dig_at`, and
 * the way a script lays a structure out for them (a stair to a platform
 * in the sky, as babel_plus does), on the simulated server of brain_sim.h */
#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40, PZ = 1, SY = 240, SX0 = 205 };

/* the platform: a slab at PZ, x 206..230, y 236..250 */
static void platform(bs_sim *s)
{
	bs_box(s, SX0 + 1, 236, PZ, 230, 250, PZ, 1);
}

/* step k of the stair: the block at (SX0 - k, SY, PZ + 1 + k); built from
 * the ground (the highest k that is not in the ground) up to k = 0, which
 * is a voxel under the platform's level, a step up from it */
static int step_z(int k) { return PZ + 1 + k; }

static int base_k(void)
{
	int k;

	for (k = 0; step_z(k) < G - 1; k++) ;
	return k;      /* step_z(base) is G - 1: on the ground, the first built */
}

/* what the script does each half second: the next missing step, from the
 * bottom; -1 when the stair is whole */
static int next_step(const bs_sim *s)
{
	int k;

	for (k = base_k(); k >= 0; k--)
		if (!bc_map_solid(s->truth, SX0 - k, SY, step_z(k)))
			return k;
	return -1;
}

static void say_place(bs_sim *s, const char *name, float x, float y, float z)
{
	char t[96];

	snprintf(t, sizeof t, "place.%s=%.1f %.1f %.1f", name, (double)x, (double)y, (double)z);
	bs_set(s, BL_NO_PLAYER, t);
}

static void test_stair(void)
{
	bs_sim *s = bs_new(G, 8);
	int i, k, built0 = 0, built = 0, top = 0, at = -1, pid;
	double done_at = -1.0;

	printf("a stair to a platform in the sky, a step at a time\n");
	s->have_tents = 1;
	s->tent[0].x = 160.5f; s->tent[0].y = 240.5f; s->tent[0].z = (float)G - 2.25f;
	s->tent[1].x = 320.5f; s->tent[1].y = 240.5f; s->tent[1].z = (float)G - 2.25f;
	platform(s);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "edit=all");
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tseq\n\t\tif fact stair_done\n\t\tdo go_to @top 2\n\tdo build_at @stair\n\twait 1\n");
	say_place(s, "top", 218.5f, 243.5f, (float)PZ - 2.25f);
	for (pid = 0; pid < 4; pid++)
		bs_add(s, pid, 1, 1, 6, BL_GUN_RIFLE, 300u + (uint32_t)pid * 17u, 170.5f + (float)pid * 2.0f, 244.5f, 1, 0);
	for (k = 0; k <= base_k(); k++)
		built0 += bc_map_solid(s->truth, SX0 - k, SY, step_z(k));
	for (i = 0; i < 60 * 180; i++) {
		if (i % 30 == 0) {
			k = next_step(s);
			if (k >= 0) {
				say_place(s, "stair", (float)(SX0 - k) + 0.5f, (float)SY + 0.5f, (float)step_z(k) - 2.25f);
			} else if (done_at < 0.0) {
				done_at = i / 60.0;
				bs_set(s, BL_NO_PLAYER, "fact.stair_done=1");
			}
		}
		bs_step(s);
		for (pid = 0; pid < 4 && at < 0; pid++)
			if (s->p[pid].body.pos.x > (float)SX0 + 1.0f && bc_body_feet(&s->p[pid].body) < (float)PZ + 0.5f &&
			    !s->p[pid].body.airborne)
				at = i;
		if (at >= 0 && done_at >= 0.0)
			break;
	}
	for (k = 0; k <= base_k(); k++)
		built += bc_map_solid(s->truth, SX0 - k, SY, step_z(k));
	for (pid = 0; pid < 4; pid++)
		top += bc_body_feet(&s->p[pid].body) < (float)PZ + 0.5f;
	printf("  %d steps to build (%d up); four bots, edit=all: %d built, the stair whole after %.0f s; one on the platform after %.0f s (%d there at the end); %u edits, %u plans\n",
	       base_k() + 1, G - 1 - PZ, built - built0, done_at, at / 60.0, top, (unsigned)bc_engine_stats_get(s->e)->edits,
	       (unsigned)bc_engine_stats_get(s->e)->plans);
	printf("  edits the server refused for not being in the bot's sight: %d\n", s->vis_refused);
	CHECK(done_at > 0.0 && done_at < 150.0);
	CHECK(s->vis_refused == 0);
	CHECK(at > 0);
	bs_free(s);
}

static void test_dig_at(void)
{
	bs_sim *s = bs_new(G, 4);
	int i;

	printf("dig_at: a block a script names, taken away\n");
	s->have_tents = 1;
	s->tent[0].x = 160.5f; s->tent[0].y = 240.5f; s->tent[0].z = (float)G - 2.25f;
	s->tent[1].x = 320.5f; s->tent[1].y = 240.5f; s->tent[1].z = (float)G - 2.25f;
	bs_box(s, 200, 240, G - 3, 200, 240, G - 1, 1);         /* a post three high */
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "edit=dig");
	bs_set(s, BL_NO_PLAYER, "place.post=200.5 240.5 38.5");
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo dig_at @post\n\twait 60\n");
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 5, 180.5f, 240.5f, 1, 0);
	for (i = 0; i < 60 * 15 && bc_map_solid(s->truth, 200, 240, 38); i++)
		bs_step(s);
	printf("  the post's middle block gone after %.1f s\n", i / 60.0);
	CHECK(!bc_map_solid(s->truth, 200, 240, 38));
	bs_free(s);
}

/* A bot up where it cannot get down makes its height a vantage: a level
 * walkway toward the enemy's base, a block a step as a player bridges,
 * until it sees the base within its gun's reach; then it camps there and
 * shoots what comes into view. (The owner, of keidoro's sky slab: "bots
 * stuck here should at least try to bridge to camp other enemies' spawn") */
static void test_perch(void)
{
	static const char *const edits[2] = { "edit=all", "edit=none" };
	int k;

	printf("build_perch: a walkway off a slab in the sky, toward their base\n");
	for (k = 0; k < 2; k++) {
		bs_sim *s = bs_new(G, 4);
		int i, from_x = 239, shots;
		float far_x = 0.0f;

		s->have_tents = 1;
		s->tent[0].x = 160.5f; s->tent[0].y = 256.5f; s->tent[0].z = (float)G - 2.25f;
		s->tent[1].x = 340.5f; s->tent[1].y = 256.5f; s->tent[1].z = (float)G - 2.25f;
		bs_box(s, 230, 250, 0, from_x, 262, 0, 1);         /* a slab at the map's top */
		bs_start(s);
		bs_set(s, BL_NO_PLAYER, edits[k]);
		bs_set(s, BL_NO_PLAYER, "leaders.per=0");
		bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tseq\n\t\tif enemy_visible\n\t\tdo fight\n\tseq\n\t\tdo build_perch enemy_base\n\t\tdo camp 120\n\tdo hold self 10\n");
		bs_add(s, 0, 1, 1, 8, BL_GUN_RIFLE, 41, 235.5f, 256.5f, 1, 0);
		bc_body_place(&s->p[0].body, s->truth, 235.5f, 256.5f, 0, 0);
		for (i = 0; i < 60 * 90; i++) {
			if (i == 60 * 60)           /* a man walks out of their base */
				bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 330.5f, 256.5f, -1, 0);
			if (i > 60 * 60) s->p[1].hp = 100;
			bs_step(s);
			if (s->p[0].body.pos.x > far_x) far_x = s->p[0].body.pos.x;
		}
		shots = s->p[0].shots;
		printf("  %s: %d blocks used (of 50), out to x %.1f (the slab ends at %d, their base at 340), still at the top: %s, "
		       "a man near their base from 60 s: %d rounds at him, %d hits; refused for not in sight: %d\n",
		       edits[k], 50 - s->p[0].blocks, (double)far_x, from_x, bc_body_feet(&s->p[0].body) < 0.5f ? "yes" : "NO",
		       shots, s->p[0].hits, s->vis_refused);
		CHECK(bc_body_feet(&s->p[0].body) < 0.5f);
		CHECK(s->vis_refused == 0);
		if (k == 0) {
			CHECK(far_x > (float)from_x + 5.0f && 50 - s->p[0].blocks > 5);
			CHECK(shots > 0);
		} else {
			CHECK(far_x < (float)from_x + 1.0f && s->p[0].blocks == 50);
		}
		bs_free(s);
	}
}

/* ---------------------------------------------------------------------- */
/* TOWER WORK: the stair as bots build it -- a band two voxels deep, each   */
/* column's step and the voxel under it (its riser), face to face with the  */
/* next -- one row wide. Dug anywhere, what is above falls (the cull).       */

static void band_cells(int k, int cell, int *x, int *z)
{
	*x = SX0 - k;
	*z = step_z(k) + cell;          /* cell 0: the step; 1: under it */
}

static void lay_band(bs_sim *s, int y)
{
	int k, c, x, z;

	for (k = 0; k <= base_k(); k++)
		for (c = 0; c < 2; c++) {
			band_cells(k, c, &x, &z);
			if (z < G)
				bs_box(s, x, y, z, x, y, z, 1);
		}
}

static int band_solid(const bs_sim *s, int y)
{
	int k, c, x, z, n = 0;

	for (k = 0; k <= base_k(); k++)
		for (c = 0; c < 2; c++) {
			band_cells(k, c, &x, &z);
			n += z < G && bc_map_solid(s->truth, x, y, z);
		}
	return n;
}

static bs_sim *tower_field(void)
{
	bs_sim *s = bs_new(G, 8);

	s->have_tents = 1;
	s->tent[0].x = 160.5f; s->tent[0].y = 240.5f; s->tent[0].z = (float)G - 2.25f;
	s->tent[1].x = 320.5f; s->tent[1].y = 240.5f; s->tent[1].z = (float)G - 2.25f;
	platform(s);
	return s;
}

/* The other team's stair, propped by a pillar from the ground under its
 * middle: its foot no longer brings it down. The raider is told only
 * where the stair is; it digs where the most falls -- found by the
 * server's own collapse, run on its map -- and the most falls. */
static void test_dig_weakest(void)
{
	bs_sim *s = tower_field();
	int P = base_k() / 2, px = SX0 - P, i, k, c, x, z, best = 0, foot, before, after, pz = step_z(P) + 2;
	char t[96];

	printf("dig_weakest: their stair, propped in the middle, broken where most of it falls\n");
	lay_band(s, SY);
	bs_box(s, px, SY, pz, px, SY, G - 1, 1);           /* the pillar */
	/* what a cut of one block would drop, each step of the stair round the
	 * place: its top face is what a player on the stair sees (a riser's
	 * faces -- its sides on a stair one row wide, its bottom high over the
	 * ground -- are seen from nowhere one can stand) */
	for (k = 0; k <= base_k(); k++)
		for (c = 0; c < 1; c++) {
			band_cells(k, c, &x, &z);
			if (z < G && (x - px) * (x - px) + (z - pz) * (z - pz) <= 36) {
				int n = bc_cull_would_drop(s->truth, s->cull, x, SY, z, -1, -1, -1);

				if (n > best) best = n;
			}
		}
	band_cells(base_k(), 0, &x, &z);          /* the lowest step, on the ground */
	foot = bc_cull_would_drop(s->truth, s->cull, x, SY, z, -1, -1, -1);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "edit=dig");
	snprintf(t, sizeof t, "place.breach=%d.5 %d.5 %d.5", px, SY, pz);
	bs_set(s, BL_NO_PLAYER, t);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo dig_weakest @breach\n\twait 60\n");
	bs_add(s, 0, 1, 2, 6, BL_GUN_RIFLE, 41, (float)px - 6.5f, (float)SY + 3.5f, 1, 0);
	before = band_solid(s, SY);
	for (i = 0; i < 60 * 40 && band_solid(s, SY) == before; i++)
		bs_step(s);
	after = band_solid(s, SY);
	printf("  a cut at its foot would drop %d; the most a step round the place drops is %d; it dug, and %d fell (after %.1f s); refused for sight: %d\n",
	       foot, best, before - after - 1, i / 60.0, s->vis_refused);
	CHECK(foot == 0);                          /* the pillar holds it: the foot is no weak point */
	CHECK(best > 10);
	CHECK(before - after - 1 == best);         /* it found the weakest block, and the server dropped the rest */
	CHECK(s->vis_refused == 0);
	bs_free(s);
}

/* Their stair one row wide: dug at the foot, it all falls. Widened -- a
 * second band beside it, put a block at a time as a player puts them
 * (put_at) -- the same dig takes one block, and the stair stands. */
static void test_widen(void)
{
	bs_sim *s = tower_field();
	int i, k, c, x, z, pid, alone, widened, before, foot_x = 0, foot_z = 0, total = 0, made;
	char t[96];

	printf("put_at: a stair widened by a second row, a block at a time; then dug at its foot\n");
	lay_band(s, SY);
	/* its weak point: the block a cut at which drops the most (low down,
	 * where the band leaves the ground) */
	alone = 0;
	for (k = 0; k <= base_k(); k++)
		for (c = 0; c < 2; c++) {
			int n;

			band_cells(k, c, &x, &z);
			if (z < G && (n = bc_cull_would_drop(s->truth, s->cull, x, SY, z, -1, -1, -1)) > alone) {
				alone = n; foot_x = x; foot_z = z;
			}
		}
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "edit=all");
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo put_at @widen\n\twait 1\n");
	for (pid = 0; pid < 3; pid++)
		bs_add(s, pid, 1, 1, 6, BL_GUN_RIFLE, 500u + (uint32_t)pid * 13u, (float)(SX0 - base_k()) - 4.5f + (float)pid,
		       (float)SY + 4.5f, 1, 0);
	for (k = 0; k <= base_k(); k++)
		for (c = 0; c < 2; c++) {
			band_cells(k, c, &x, &z);
			total += z < G;
		}
	for (i = 0; i < 60 * 300; i++) {
		if (i % 30 == 0) {
			/* the script: the lowest cell of the second band not yet there */
			int nx = -1, nz = -1;

			for (k = base_k(); k >= 0 && nx < 0; k--)
				for (c = 1; c >= 0 && nx < 0; c--) {
					band_cells(k, c, &x, &z);
					if (z < G && !bc_map_solid(s->truth, x, SY + 1, z)) { nx = x; nz = z; }
				}
			if (nx < 0)
				break;
			snprintf(t, sizeof t, "place.widen=%d.5 %d.5 %d.5", nx, SY + 1, nz);
			bs_set(s, BL_NO_PLAYER, t);
		}
		bs_step(s);
	}
	made = band_solid(s, SY + 1);
	widened = bc_cull_would_drop(s->truth, s->cull, foot_x, SY, foot_z, -1, -1, -1);
	printf("  the second row: %d of %d blocks after %.0f s, refused for sight: %d\n", made, total, i / 60.0, s->vis_refused);
	printf("  a dig at the first row's weak point would drop %d one row wide, %d widened\n", alone, widened);
	CHECK(made == total);
	CHECK(s->vis_refused == 0);
	CHECK(alone > 2 * base_k() - 4);           /* all of it */
	CHECK(widened == 0);
	/* and dug: one block goes, the stair stands */
	before = band_solid(s, SY);
	bs_block(s, 100, foot_x, SY, foot_z, BL_B_DESTROY);
	CHECK(band_solid(s, SY) == before - 1);
	bs_free(s);
}

/* Ours propped: a pillar from the ground beside its middle step, up to
 * the step's own level, where it meets the stair face to face -- built as
 * a player builds a pillar, standing on it as it rises (build_at on the
 * next block up). A cut at the weak point low down no longer drops what
 * is above the pillar. */
static void test_pillar(void)
{
	bs_sim *s = tower_field();
	int P = base_k() / 2, px = SX0 - P, top = step_z(P), py = SY - 1, i, z, pid, before_drop, after_drop, made = 0, fx = 0, fz = 0, n, k;
	char t[96];

	printf("a pillar from the ground beside the stair's middle step, up to it\n");
	lay_band(s, SY);
	before_drop = 0;
	for (k = 0; k <= base_k(); k++) {
		int x;

		band_cells(k, 0, &x, &z);
		if (z < G && (n = bc_cull_would_drop(s->truth, s->cull, x, SY, z, -1, -1, -1)) > before_drop) {
			before_drop = n; fx = x; fz = z;
		}
	}
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "edit=all");
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo build_at @prop\n\twait 1\n");
	for (pid = 0; pid < 2; pid++)
		bs_add(s, pid, 1, 1, 6, BL_GUN_RIFLE, 900u + (uint32_t)pid * 11u, (float)px - 3.5f + (float)pid, (float)py - 3.5f, 1, 0);
	for (i = 0; i < 60 * 200; i++) {
		if (i % 30 == 0) {
			int nz = -1;

			for (z = G - 1; z >= top && nz < 0; z--)
				if (!bc_map_solid(s->truth, px, py, z)) nz = z;
			if (nz < 0)
				break;
			say_place(s, "prop", (float)px + 0.5f, (float)py + 0.5f, (float)nz - 2.25f);
		}
		bs_step(s);
	}
	for (z = top; z < G; z++)
		made += bc_map_solid(s->truth, px, py, z);
	after_drop = bc_cull_would_drop(s->truth, s->cull, fx, SY, fz, -1, -1, -1);
	printf("  %d of %d blocks of the pillar after %.0f s, refused for sight: %d; a cut at the weak point would drop %d before, %d after\n",
	       made, G - top, i / 60.0, s->vis_refused, before_drop, after_drop);
	(void)t;
	CHECK(made == G - top);
	CHECK(s->vis_refused == 0);
	CHECK(after_drop < before_drop / 2);
	bs_free(s);
}

/* Ours cut in the middle by the other team: what stood above fell. The
 * script names the next missing step from the ground, as babel_plus does,
 * and the builders lay it again. */
static void test_repair(void)
{
	bs_sim *s = tower_field();
	int i, k, pid, whole, cut, x, z, repaired = -1;

	printf("a stair cut in the middle, built again\n");
	lay_band(s, SY);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "edit=all");
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo build_at @stair\n\twait 1\n");
	for (pid = 0; pid < 3; pid++)
		bs_add(s, pid, 1, 1, 6, BL_GUN_RIFLE, 700u + (uint32_t)pid * 7u, 170.5f + (float)pid * 2.0f, 244.5f, 1, 0);
	whole = band_solid(s, SY);
	band_cells(base_k() / 2, 1, &x, &z);
	bs_block(s, 100, x, SY, z, BL_B_DESTROY);
	cut = band_solid(s, SY);
	for (i = 0; i < 60 * 180 && repaired < 0; i++) {
		if (i % 30 == 0) {
			k = next_step(s);
			if (k < 0) { repaired = i; break; }
			say_place(s, "stair", (float)(SX0 - k) + 0.5f, (float)SY + 0.5f, (float)step_z(k) - 2.25f);
		}
		bs_step(s);
	}
	printf("  %d blocks, %d left after the cut; every step there again after %.0f s; refused for sight: %d\n",
	       whole, cut, repaired / 60.0, s->vis_refused);
	CHECK(cut < whole / 2 + 2);                /* the cull took what was above the cut */
	CHECK(repaired > 0);
	CHECK(s->vis_refused == 0);
	bs_free(s);
}

int main(void)
{
	test_dig_at();
	test_stair();
	test_perch();
	test_dig_weakest();
	test_widen();
	test_pillar();
	test_repair();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
