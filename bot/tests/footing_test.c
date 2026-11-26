/* footing_test.c -- a body moved by anything but a planned step keeps its
 * feet (core/footing.h, the one rule; engine.c act, FOOTING).
 *
 *   the rule     on a wall one voxel wide: which keys, for which facing,
 *                keep the feet
 *   under fire   a stair one voxel wide and the wall at its top, walked
 *                down and up again for a minute, with a man on the ground
 *                beside it who shoots at it the whole time: no flight the
 *                route did not ask for leaves the stair. (WORK.md item 25
 *                saw babel's carriers fall 26 to 30 voxels off their own
 *                stair under fire; this scene does not make that fall
 *                happen, before the rule or after it -- it holds the
 *                ground.)
 *
 * On the simulated server of brain_sim.h.
 */
#include "brain_sim.h"
#include "footing.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40, Y = 256, X0 = 200, STEPS = 15, WALK = 20, SHOOTER = 1 };

/* A stair one voxel wide up STEPS steps along +x, then a wall one voxel
 * wide and WALK long at its top: nothing either side of it. */
static bs_sim *stair(int shooter, uint32_t seed)
{
	bs_sim *s = bs_new(G, 4);
	char set[96];
	int i;

	for (i = 1; i <= STEPS; i++)
		bs_box(s, X0 + i, Y, G - i, X0 + i, Y, G - 1, 1);
	bs_box(s, X0 + STEPS + 1, Y, G - STEPS, X0 + STEPS + WALK, Y, G - 1, 1);
	bs_start(s);
	bs_set(s, BL_NO_PLAYER, "leaders.per=0");
	snprintf(set, sizeof set, "place.top=%.1f %.1f %.2f", X0 + STEPS + WALK - 0.5, Y + 0.5, G - STEPS - 2.25);
	bs_set(s, BL_NO_PLAYER, set);
	snprintf(set, sizeof set, "place.foot=%.1f %.1f %.2f", X0 - 4 + 0.5, Y + 0.5, G - 2.25);
	bs_set(s, BL_NO_PLAYER, set);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nseq\n\tdo go_to @foot\n\tdo go_to @top\n");
	/* it starts at the top, at the wall's far end */
	bs_add(s, 0, 1, 1, 10, BL_GUN_RIFLE, seed, X0 + STEPS + WALK - 1 + 0.5f, Y + 0.5f, -1, 0);
	if (shooter) {
		/* on the ground, 12 off the walkway's middle, in plain sight */
		bs_add(s, SHOOTER, 0, 2, 10, BL_GUN_RIFLE, 1, X0 + STEPS + WALK / 2 + 0.5f, Y - 12 + 0.5f, 0, 1);
		s->p[SHOOTER].script_fire = 1;
		s->p[SHOOTER].tool = BL_TOOL_GUN;
		s->respawn = 1.0;        /* (and when the bot kills him, he is back) */
	}
	return s;
}

typedef struct { int falls, worst, trips, hits; } fall_count;

/* Is the bot on a step of its route that leaves the ground on purpose? */
static int planned_flight(bs_sim *s)
{
	const bc_bot *b = bc_engine_bot(s->e, 0);
	int k;

	if (!b || !b->mv.has_route || b->mv.follow.step < 0 || b->mv.follow.step >= b->mv.route.n)
		return 0;
	k = b->mv.route.steps[b->mv.follow.step].kind;
	return k == BC_NAV_JUMP || k == BC_NAV_RUNJUMP || k == BC_NAV_DROP;
}

/* A minute of it. A fall: a flight no step of the route asked for (not a
 * jump, not a drop) that comes down off the stair's column, more than two
 * voxels under where it left the ground (a sprint down the stair skims a
 * step or two); its height, from the highest feet of the flight. */
static fall_count run(int shooter, uint32_t seed)
{
	bs_sim *s = stair(shooter, seed);
	bs_player *me = &s->p[0];
	fall_count f = { 0, 0, 0, 0 };
	float high = 0.0f, off = 0.0f;
	int was_air = 0, i, top_was = 0, hits_was = 0, meant = 0;

	for (i = 0; i < 60 * 60; i++) {
		float feet;

		if (shooter) {
			/* he keeps his gun on the bot's legs (a hit, never one that
			 * kills: its health is made whole every tick), and both live */
			bs_player *sh = &s->p[SHOOTER];
			float dx = me->body.pos.x - sh->body.pos.x, dy = me->body.pos.y - sh->body.pos.y,
			      dz = me->body.pos.z + 2.0f - sh->body.pos.z, l = sqrtf(dx * dx + dy * dy + dz * dz);

			sh->ori.x = dx / l; sh->ori.y = dy / l; sh->ori.z = dz / l;
			sh->mag = 10;
			sh->hp = me->hp = 100;
		}
		bs_step(s);
		feet = bc_body_feet(&me->body);
		if (me->body.airborne && !was_air) {
			off = high = feet;
			meant = planned_flight(s);
		}
		if (me->body.airborne && feet < high)
			high = feet;
		if (!me->body.airborne && was_air && !meant && feet > off + 2.0f &&
		    fabsf(me->body.pos.y - (Y + 0.5f)) > 0.5f) {
			f.falls++;
			if ((int)(feet - high) > f.worst) f.worst = (int)(feet - high);
		}
		was_air = me->body.airborne;
		{
			int top = me->body.pos.x > X0 + STEPS + WALK - 3 && feet < G - STEPS + 0.5f;

			if (top && !top_was) f.trips++;
			top_was = top;
		}
		if (shooter && s->p[SHOOTER].hits != hits_was) {
			f.hits += s->p[SHOOTER].hits - hits_was;
			hits_was = s->p[SHOOTER].hits;
		}
	}
	bs_free(s);
	return f;
}

static void test_rule(void)
{
	bs_sim *s = stair(0, 1);
	bc_body b;
	bc_v3 east = { 1.0f, 0.0f, 0.0f }, north = { 0.0f, -1.0f, 0.0f };
	int x = X0 + STEPS + WALK / 2;

	printf("the rule: on the wall one voxel wide\n");
	bc_body_place(&b, s->truth, (float)x + 0.5f, Y + 0.5f, G - STEPS, 0);
	CHECK(bc_footing_keys(s->truth, &b, 0, east));
	CHECK(bc_footing_keys(s->truth, &b, BC_K_FORWARD, east));          /* along it */
	CHECK(bc_footing_keys(s->truth, &b, BC_K_BACK | BC_K_SPRINT, east));
	CHECK(!bc_footing_keys(s->truth, &b, BC_K_LEFT, east));            /* off either side */
	CHECK(!bc_footing_keys(s->truth, &b, BC_K_RIGHT, east));
	CHECK(!bc_footing_keys(s->truth, &b, BC_K_FORWARD | BC_K_LEFT, east));
	CHECK(bc_footing_keys(s->truth, &b, BC_K_JUMP, east));             /* up and down where it is */
	CHECK(!bc_footing_keys(s->truth, &b, BC_K_FORWARD, north));        /* the same key, the head turned */
	CHECK(bc_footing_keys(s->truth, &b, BC_K_LEFT, north));
	b.airborne = 1;
	CHECK(bc_footing_keys(s->truth, &b, BC_K_LEFT, east));             /* in the air: steers nothing */
	bs_free(s);
}

static void test_stair_under_fire(void)
{
	int k, falls = 0, falls_quiet = 0, trips = 0, worst = 0;

	printf("a stair one voxel wide, up and down for a minute, shot at from the ground beside it\n");
	for (k = 0; k < 4; k++) {
		fall_count q = run(0, 900u + (uint32_t)k), f = run(1, 900u + (uint32_t)k);

		printf("  seed %d: under fire (hit %d times) %d falls (worst %d voxels), %d times at the top; "
		       "alone %d falls, %d times\n", k, f.hits, f.falls, f.worst, f.trips, q.falls, q.trips);
		falls += f.falls;
		falls_quiet += q.falls;
		trips += f.trips;
		if (f.worst > worst) worst = f.worst;
		CHECK(q.trips >= 2);
	}
	CHECK(falls_quiet == 0);
	CHECK(falls == 0);
	CHECK(trips >= 4);
}

int main(void)
{
	test_rule();
	test_stair_under_fire();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
