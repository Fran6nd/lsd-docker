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

int main(void)
{
	test_dig_at();
	test_stair();
	test_perch();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
