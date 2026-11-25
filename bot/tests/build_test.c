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

/* A zone for one team (babel_protect: nobody breaks his own team's tower
 * area): its bots leave the post alone, the other team's dig it. */
static void test_team_zone(void)
{
	int team, i, gone[3] = { 0, 0, 0 };

	printf("a zone for one team: its bots do not dig there, the other's do\n");
	for (team = 1; team <= 2; team++) {
		bs_sim *s = bs_new(G, 4);

		s->have_tents = 1;
		s->tent[0].x = 160.5f; s->tent[0].y = 240.5f; s->tent[0].z = (float)G - 2.25f;
		s->tent[1].x = 320.5f; s->tent[1].y = 240.5f; s->tent[1].z = (float)G - 2.25f;
		bs_box(s, 200, 240, G - 3, 200, 240, G - 1, 1);
		bs_start(s);
		bs_set(s, BL_NO_PLAYER, "edit=dig");
		bs_set(s, BL_NO_PLAYER, "zone=150 230 210 250 nobuild; 190 230 210 250 nodig team 1");
		bs_set(s, BL_NO_PLAYER, "place.post=200.5 240.5 38.5");
		bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo dig_at @post\n\twait 60\n");
		bs_add(s, 0, 1, team, 6, BL_GUN_RIFLE, 5, 180.5f, 240.5f, 1, 0);
		for (i = 0; i < 60 * 15; i++)
			bs_step(s);
		gone[team] = !bc_map_solid(s->truth, 200, 240, 38);
		bs_free(s);
	}
	printf("  team 1 (whose zone it is): %s; team 2: %s\n", gone[1] ? "dug it" : "left it", gone[2] ? "dug it" : "left it");
	CHECK(!gone[1] && gone[2]);
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
	s->p[0].grenades = 0;                       /* nothing to throw: the spade */
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

/* Their stair broken from a distance, never setting foot on it. One row
 * wide, its weak point is low, where it leaves the ground: a grenade's
 * (a hand grenade lands on nothing 17 or more over the thrower: no arc
 * reaches). Propped in the middle, its weak point is high, over the prop:
 * a weapon the tree names (a rocket: the server's "inv rocket x y z", here
 * played as the server plays it, a blast that takes 3x3x3). */
static void ranged_pass(int grenades, const char *item, int propped, float from_x, int *fell, int *climbed, double *secs, int *spade_digs)
{
	bs_sim *s = tower_field();
	int P = base_k() / 2, px = SX0 - P, pz = step_z(P) + 2, i, before, k;
	char t[128];

	lay_band(s, SY);
	if (propped)
		bs_box(s, px, SY, pz, px, SY, G - 1, 1);       /* the pillar */
	else
		px = SX0 - base_k() + 3, pz = G - 3;       /* the breach: low, where it leaves the ground */
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "edit=dig");
	snprintf(t, sizeof t, "place.breach=%d.5 %d.5 %d.5", px, SY, pz);
	bs_set(s, BL_NO_PLAYER, t);
	snprintf(t, sizeof t, "tree=tree t:\nselect\n\tdo dig_weakest @breach 6%s%s\n\twait 60\n", item ? " " : "", item ? item : "");
	bs_set(s, BL_NO_PLAYER, t);
	bs_add(s, 0, 1, 2, 8, BL_GUN_RIFLE, 41, from_x, (float)SY + 6.5f, -1, 0);
	s->p[0].grenades = grenades;
	if (item) {
		snprintf(t, sizeof t, "item.%s=1", item);
		bs_set(s, 0, t);
	}
	before = band_solid(s, SY);
	*climbed = 0;
	*spade_digs = 0;
	k = s->p[0].cmds;
	for (i = 0; i < 60 * 40 && band_solid(s, SY) > before - 3; i++) {
		bs_step(s);
		if (s->p[0].cmds != k) {
			float x, y, z;

			k = s->p[0].cmds;
			if (item && sscanf(s->p[0].last_cmd + strlen("inv ") + strlen(item), " %f %f %f", &x, &y, &z) == 3)
				bs_block(s, BL_NO_PLAYER, (int)floorf(x), (int)floorf(y), (int)floorf(z), BL_B_GRENADE);
		}
		if (fabsf(s->p[0].body.pos.y - (float)SY - 0.5f) < 0.6f && bc_body_feet(&s->p[0].body) < (float)G - 0.5f)
			*climbed = 1;                     /* on their stair */
	}
	*fell = before - band_solid(s, SY);
	*secs = i / 60.0;
	*spade_digs = (int)bc_engine_stats_get(s->e)->edits;
	bs_free(s);
}

static void test_ranged_cut(void)
{
	int fell, climbed, digs, px = SX0 - base_k() / 2;
	double secs;

	printf("dig_weakest from a distance: grenades, a rocket\n");
	ranged_pass(3, NULL, 0, (float)(SX0 - base_k()) - 22.5f, &fell, &climbed, &secs, &digs);
	printf("  one row wide, 3 grenades, 22 off its foot: %d blocks fell after %.1f s; it climbed their stair: %s; spade digs %d\n",
	       fell, secs, climbed ? "yes" : "no", digs);
	CHECK(fell > 10 && !climbed && digs == 0);
	ranged_pass(0, "rocket", 1, (float)px - 40.5f, &fell, &climbed, &secs, &digs);
	printf("  propped, a rocket, 40 off: %d fell after %.1f s; climbed: %s; spade digs %d\n", fell, secs, climbed ? "yes" : "no", digs);
	CHECK(fell > 10 && !climbed && digs == 0);
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

/* A prop holds the stair up only face to face: the server's collapse
 * floods through faces (cull.c), so a pillar beside a step at the same x
 * joins it, one a column over -- touching it by an edge only -- does not
 * (the owner: "pillars must join face to face the stair to consolidate
 * it, otherwise it does not consolidate it"). */
static void test_prop_face(void)
{
	int k, P = base_k() / 2, x0 = SX0 - P, top = step_z(P), held[2], fx = 0, fz = 0;

	printf("a prop holds a stair face to face, not by an edge\n");
	for (k = 0; k < 2; k++) {
		bs_sim *s = tower_field();
		int x = x0 + k, j, n, worst = 0;    /* k 1: a column over, toward the top -- an edge, no face */

		lay_band(s, SY);
		bs_box(s, x, SY - 1, top + k, x, SY - 1, G - 1, 1);   /* its top level with the step (k 1: the step beside is one up) */
		for (j = 0; j <= base_k(); j++) {
			int bx, bz;

			band_cells(j, 0, &bx, &bz);
			if (bz < G && bx < x0 && (n = bc_cull_would_drop(s->truth, s->cull, bx, SY, bz, -1, -1, -1)) > worst) {
				worst = n; fx = bx; fz = bz;
			}
		}
		held[k] = worst;
		bs_free(s);
	}
	(void)fx; (void)fz;
	printf("  the worst cut below the prop drops %d with the prop face to face, %d with it a column over\n", held[0], held[1]);
	CHECK(held[0] == 0);                       /* everything above the cut leans on the prop */
	CHECK(held[1] > 0);                        /* an edge holds nothing */
}

/* BABEL'S PLATFORM MEN (babel.bt, babel_platform): with our stair up, a
 * few -- three of the five here -- go up and hold the platform by the
 * intel's home; the intel home, they take it; put back there after its
 * carrier fell, they take it again at once; a man of theirs coming up
 * onto the platform is shot at. The shipped trees, loaded as botd loads
 * them. */
static void test_platform_men(void)
{
	static const char *const files[] = { "trees/default.bt", "trees/tdm.bt", "trees/ctf.bt", "trees/babel.bt" };
	bs_sim *s = tower_field();
	char *all = calloc(1, 1 << 20), err[256];
	size_t q;
	int i, k, most = 0, up = 0, first = -1, again = -1, reset_at = -1, shots_before, hit_at = -1;

	printf("babel's platform men: a few hold it, take the intel home again, shoot who comes up\n");
	lay_band(s, SY);
	s->ctf = 1; s->one_intel = 1;
	s->intel_zone[0][0] = 218; s->intel_zone[0][1] = 243; s->intel_zone[0][2] = 218; s->intel_zone[0][3] = 243;
	bs_intel_home(s, 0);
	s->intel[1].x = 1e6f; s->intel[1].y = 1e6f; s->intel_holder[1] = -1;
	bs_start(s);
	for (q = 0; q < sizeof files / sizeof files[0]; q++) {
		char *t = bs_slurp(files[q]);

		strcat(all, t); strcat(all, "\n"); free(t);
	}
	CHECK(bc_engine_trees(s->e, all, err, sizeof err));
	free(all);
	bs_set(s, BL_NO_PLAYER, "edit=all");
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	bs_set(s, BL_NO_PLAYER, "tree=babel");
	bs_set(s, BL_NO_PLAYER, "fact.stair_done@1=1");
	bs_set(s, BL_NO_PLAYER, "place.intel_home=218.50 243.50 -1.25");
	for (k = 0; k < 5; k++) {
		bs_add(s, k, 1, 1, 7, BL_GUN_RIFLE, 610u + (uint32_t)k * 13u, 170.5f + (float)k * 2.0f, 244.5f, 1, 0);
		bs_set(s, k, "tree=babel_platform");
	}
	for (i = 0; i < 60 * 90; i++) {
		char t[64];

		if (s->intel_holder[0] >= 0) {
			snprintf(t, sizeof t, "place.intel=pid %d", s->intel_holder[0]);
			if (first < 0) first = i;
			if (reset_at >= 0 && again < 0) again = i - reset_at;
		} else {
			snprintf(t, sizeof t, "place.intel=%.2f %.2f %.2f", s->intel[0].x, s->intel[0].y, s->intel[0].z - 2.25);
		}
		if (i % 30 == 0) bs_set(s, BL_NO_PLAYER, t);
		/* the first carrier falls (shot): the intel is put back home */
		if (first >= 0 && reset_at < 0 && i > first + 60) {
			bl_vec3 from;

			from.x = 230.5f; from.y = 243.5f; from.z = -1.0f;
			bs_hurt(s, s->intel_holder[0], 200, BL_NO_PLAYER, from, 0);
			s->intel_holder[0] = -1;
			bs_intel_home(s, 0);
			reset_at = i;
		}
		bs_step(s);
		if (i % 60 == 0 && i > 60 * 40) {
			int n = 0, h = 0;
			const bc_bot *b;

			for (k = 0; k < 5; k++) {
				b = bc_engine_bot(s->e, k);
				n += s->p[k].alive && bc_body_feet(&s->p[k].body) < (float)PZ + 0.5f;
				h += b && !strcmp(b->slot.name, "platform") && s->e->now - b->slot.at <= 2.0;
			}
			if (h > most) most = h;
			if (n > up) up = n;
		}
	}
	/* a man of theirs comes up at the platform's far edge */
	bs_add(s, 100, 0, 2, 5, BL_GUN_RIFLE, 1, 229.5f, 248.5f, -1, 0);
	bc_body_place(&s->p[100].body, s->truth, 229.5f, 248.5f, PZ, 0);
	shots_before = 0;
	for (k = 0; k < 5; k++) shots_before += s->p[k].shots;
	for (i = 0; i < 60 * 8 && hit_at < 0; i++) {
		int shots = 0;

		s->p[100].hp = 100;
		bs_step(s);
		for (k = 0; k < 5; k++) shots += s->p[k].shots;
		if (shots > shots_before) hit_at = i;
	}
	printf("  5 of the role: at most %d hold the platform, %d up there at most; the intel taken after %.1f s; put back, taken again after %.1f s;\n"
	       "  a man of theirs on the platform's edge: shot at after %.1f s\n",
	       most, up, first / 60.0, again / 60.0, hit_at / 60.0);
	CHECK(most >= 2 && most <= 3);
	CHECK(first > 0);
	CHECK(again > 0 && again < 60 * 10);
	CHECK(hit_at >= 0);
	bs_free(s);
}

/* A BLUEPRINT, built by several: the second row of a stair (the band, from
 * the ground up), said as a blueprint; N builders on `build_part`. No two
 * ever hold the same part; more finish sooner than one. */
static void blueprint_pass(int builders, double *secs, int *made, int *total, int *twice, int *refused)
{
	bs_sim *s = tower_field();
	int i, k, c, x, z, pid, len = 0;
	char *text = calloc(1, 1 << 16), *msg;

	lay_band(s, SY);
	*total = 0;
	for (k = base_k(); k >= 0; k--)
		for (c = 1; c >= 0; c--) {
			band_cells(k, c, &x, &z);
			if (z >= G) continue;
			len += snprintf(text + len, (1 << 16) - (size_t)len, "%s%d %d %d", *total ? "; " : "", x, SY + 1, z);
			(*total)++;
		}
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "edit=all");
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	msg = malloc((size_t)len + 32);
	sprintf(msg, "blueprint.row2@1=%s", text);
	bs_set(s, BL_NO_PLAYER, msg);
	free(msg); free(text);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo build_part row2\n\twait 1\n");
	for (pid = 0; pid < builders; pid++)
		bs_add(s, pid, 1, 1, 6, BL_GUN_RIFLE, 500u + (uint32_t)pid * 13u, (float)(SX0 - base_k()) - 4.5f + (float)pid,
		       (float)SY + 4.5f, 1, 0);
	*twice = 0;
	for (i = 0; i < 60 * 300 && band_solid(s, SY + 1) < *total; i++) {
		for (pid = 0; pid < builders; pid++)
			s->p[pid].blocks = 50;          /* refilled, as babel's infinite blocks do */
		bs_step(s);
		for (pid = 0; pid < builders; pid++) {
			const bc_bot *a = bc_engine_bot(s->e, pid);

			if (!a || !a->slot.name[0] || s->e->now - a->slot.at > 2.0) continue;
			for (k = pid + 1; k < builders; k++) {
				const bc_bot *o = bc_engine_bot(s->e, k);

				if (o && !strcmp(o->slot.name, a->slot.name) && s->e->now - o->slot.at <= 2.0)
					(*twice)++;
			}
		}
	}
	*made = band_solid(s, SY + 1);
	*secs = i / 60.0;
	*refused = s->vis_refused;
	bs_free(s);
}

static void test_blueprint(void)
{
	double one, six;
	int made1, made6, total, twice1, twice6, ref1, ref6;

	printf("a blueprint built by the team, a part each\n");
	blueprint_pass(1, &one, &made1, &total, &twice1, &ref1);
	blueprint_pass(6, &six, &made6, &total, &twice6, &ref6);
	printf("  %d blocks: one builder %d in %.0f s; six %d in %.0f s; a part held by two at once: %d; refused for sight: %d\n",
	       total, made1, one, made6, six, twice6, ref1 + ref6);
	CHECK(made1 == total && made6 == total);
	CHECK(twice6 == 0);
	CHECK(six < one);
	CHECK(ref1 + ref6 == 0);
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
	printf("  %d blocks, %d left after the cut; every step there again after %.0f s; refused for sight: %d "
	       "(and %d where a team-mate's edit came between)\n", whole, cut, repaired / 60.0, s->vis_refused, s->vis_raced);
	CHECK(cut < whole / 2 + 2);                /* the cull took what was above the cut */
	CHECK(repaired > 0);
	CHECK(s->vis_refused == 0);
	bs_free(s);
}

int main(void)
{
	test_dig_at();
	test_team_zone();
	test_stair();
	test_perch();
	test_dig_weakest();
	test_ranged_cut();
	test_widen();
	test_pillar();
	test_prop_face();
	test_platform_men();
	test_blueprint();
	test_repair();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
