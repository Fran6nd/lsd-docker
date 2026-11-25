/* skills_test.c -- one bot (or two) and one skill at a time, on the
 * simulated server of brain_sim.h */
#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40 };                /* the ground's top voxel */

/* a seed whose character has `trait` within [lo, hi] */
static uint32_t seed_with(int trait, float lo, float hi, uint32_t from)
{
	uint32_t seed;

	for (seed = from; seed < from + 5000; seed++) {
		bc_persona p;
		bc_rng r;

		bc_rng_seed(&r, seed, 0x70657273);
		bc_persona_roll(&p, &r, NULL, 5);
		if (p.trait[trait] >= lo && p.trait[trait] <= hi)
			return seed;
	}
	return from;
}

static bs_sim *game(void)
{
	bs_sim *s = bs_new(G, 8);

	s->have_tents = 1;
	s->tent[0].x = 200.5f; s->tent[0].y = 256.5f; s->tent[0].z = (float)G - 2.25f;
	s->tent[1].x = 300.5f; s->tent[1].y = 256.5f; s->tent[1].z = (float)G - 2.25f;
	return s;
}

static int seen_doing(bs_sim *s, int pid, const char *what, double secs)
{
	char d[300];
	int n = (int)(secs * 60.0), hit = 0;

	while (n-- > 0) {
		bs_step(s);
		bc_engine_describe(s->e, pid, d, sizeof d);
		if (strstr(d, what)) hit++;
	}
	return hit;
}

static void test_kill_standing(void)
{
	bs_sim *s = game();
	double t;

	printf("a bot finds and kills a standing enemy across a small map\n");
	bs_box(s, 250, 250, G - 4, 250, 262, G - 1, 1);    /* a wall between them, to walk round */
	bs_start(s);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 1234, 220.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 290.5f, 256.5f, -1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	for (t = 0; t < 60.0 && s->p[1].alive; t += 1.0)
		bs_run(s, 1.0);
	printf("  dead after %.0f s, %d shots, %d hits, %d plans, worst hold %.2f s\n", t, s->p[0].shots,
	       s->p[0].hits, (int)bc_engine_stats_get(s->e)->plans, s->p[0].worst_hold);
	CHECK(!s->p[1].alive);
	CHECK(s->p[0].hits >= 2 && s->p[0].shots < 40);
	CHECK(s->p[0].stuck_events == 0);
	CHECK(s->p[0].alive && s->p[0].hp == 100);
	bs_free(s);
}

static void test_fire_discipline(void)
{
	bs_sim *s = game();
	int i, burst = 0, longest = 0, fired = 0;

	printf("bursts, the reload, the spade\n");
	bs_start(s);
	bs_add(s, 0, 1, 1, 7, BL_GUN_SMG, 77, 220.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 245.5f, 256.5f, -1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	for (i = 0; i < 60 * 6; i++) {
		s->p[1].hp = 100;                       /* he does not die: watch the trigger */
		bs_step(s);
		if (s->p[0].firing) { burst++; fired++; if (burst > longest) longest = burst; }
		else burst = 0;
	}
	printf("  smg: trigger down %d of 360 ticks, longest burst %.2f s, %d rounds, %d hits\n", fired,
	       longest / 60.0, s->p[0].shots, s->p[0].hits);
	CHECK(fired > 30);
	CHECK(longest <= 60);                       /* 0.35-0.8 s bursts: never a held trigger */
	CHECK(s->p[0].hits > 0);
	/* out of the fight with a nearly empty magazine: it reloads */
	s->p[1].alive = 0;
	bs_run(s, 1.0);
	s->p[0].mag = 2;
	bs_run(s, 6.0);
	CHECK(s->p[0].mag == 30);
	bs_free(s);

	/* no rounds at all: the spade, and nobody hears it */
	s = game();
	bs_start(s);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 5, 240.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 258.5f, 256.5f, -1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	s->p[0].mag = 0;
	s->p[0].reserve = 0;
	for (i = 0; i < 60 * 25 && s->p[1].alive; i++)
		bs_step(s);
	printf("  spade: dead after %.1f s, tool %d, rounds fired %d, blocks dug by the swing %d\n", i / 60.0,
	       s->p[0].tool, s->p[0].shots, s->edits);
	CHECK(!s->p[1].alive && s->p[0].shots == 0);
	CHECK(s->p[0].tool == BL_TOOL_SPADE || !s->p[1].alive);
	bs_free(s);
}

static void test_mate_in_line(void)
{
	bs_sim *s = game();
	int i, bad = 0;

	printf("no shot through a team-mate\n");
	bs_start(s);
	bs_add(s, 0, 1, 1, 8, BL_GUN_SMG, 31, 220.5f, 256.5f, 1, 0);
	bs_add(s, 2, 0, 1, 5, BL_GUN_RIFLE, 2, 226.5f, 256.5f, 1, 0);      /* a mate, 6 ahead, in the line */
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 240.5f, 256.5f, -1, 0);
	/* a tree that only stands and shoots: the line stays blocked */
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\npick every=1\n\toption none always\n\t\tdo hold self 60\n");
	for (i = 0; i < 60 * 5; i++) {
		int before = s->p[0].shots;

		s->p[1].hp = 100;
		bs_step(s);
		if (s->p[0].shots != before) bad++;
	}
	printf("  rounds fired with the mate in the line: %d\n", bad);
	CHECK(bad == 0);
	/* he steps aside: now it shoots */
	s->p[2].body.pos.y += 4.0f;
	bs_run(s, 4.0);
	CHECK(s->p[0].shots > 0);
	bs_free(s);
}

static void test_investigate(void)
{
	bs_sim *s = game();
	bl_vec3 at;
	float d0, d1;
	int doing;

	printf("a shot heard is investigated\n");
	bs_box(s, 195, 240, G - 5, 195, 272, G - 1, 1);    /* he is behind a wall, behind the bot */
	bs_start(s);
	bs_add(s, 0, 1, 1, 9, BL_GUN_RIFLE, seed_with(BC_T_CURIOSITY, 1.2f, 3.0f, 100), 220.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 190.5f, 250.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_run(s, 0.3);
	at.x = 190.5f; at.y = 250.5f; at.z = (float)G - 2.25f;
	d0 = bs_dist(s, 0, 1);
	bs_sound(s, 1, at, BL_S_SHOT);              /* level 9 hears to 31.8; he is 30.6 away */
	doing = seen_doing(s, 0, "investigate", 3.0);
	d1 = d0;
	{
		int i;

		for (i = 0; i < 60 * 12; i++) {
			bs_step(s);
			if (bs_dist(s, 0, 1) < d1) d1 = bs_dist(s, 0, 1);
		}
	}
	printf("  %.1f away when heard, as near as %.1f within 15 s (round the wall); 'investigate' on %d of the first 180 ticks\n",
	       (double)d0, (double)d1, doing);
	CHECK(doing > 80);
	CHECK(d1 < 12.0f);
	bs_run(s, 20.0);                            /* and having found him round the wall, fights */
	CHECK(!s->p[1].alive || s->p[1].hp < 100);
	bs_free(s);

	/* a deaf level 1 at the same distance hears nothing and goes on */
	s = game();
	bs_start(s);
	bs_add(s, 0, 1, 1, 1, BL_GUN_RIFLE, 7, 220.5f, 256.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_run(s, 1.0);
	bs_sound(s, BL_NO_PLAYER, at, BL_S_SHOT);
	CHECK(seen_doing(s, 0, "investigate", 2.0) == 0);
	bs_free(s);
}

static void test_orders(void)
{
	bs_sim *s = game();
	bc_bot *b;
	float dx, dy;

	printf("an order is obeyed\n");
	bs_box(s, 250, 200, G - 5, 250, 300, G - 1, 1);    /* a long wall: the hunted man is unseen */
	bs_start(s);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 42, 220.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 262.5f, 256.5f, -1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_run(s, 0.5);
	b = bc_engine_bot(s->e, 0);
	/* GOTO, away from where the game would take it */
	bs_order(s, 0, BL_O_GOTO, 205.5f, 290.5f, (float)G - 2.25f, BL_NO_PLAYER, 0.0f);
	bs_run(s, 1.6);                             /* the tree chooses again within its 1.5 s */
	CHECK(seen_doing(s, 0, "obey", 0.5) == 30);
	{
		float best = 1e9f;
		int i;

		for (i = 0; i < 60 * 10 && b->order.order != BL_O_NONE; i++) {
			bs_step(s);
			dx = s->p[0].body.pos.x - 205.5f; dy = s->p[0].body.pos.y - 290.5f;
			if (dx * dx + dy * dy < best) best = dx * dx + dy * dy;
		}
		printf("  goto: got to %.1f from the place, %.1f s after the order\n", (double)sqrtf(best), 2.1 + i / 60.0);
		CHECK(best < 2.0f * 2.0f);
		CHECK(b->order.order == BL_O_NONE);     /* done on arriving */
	}
	/* HOLD for 8 s: goes back, stays, then is its own again */
	bs_run(s, 2.0);
	bs_order(s, 0, BL_O_HOLD, 205.5f, 290.5f, (float)G - 2.25f, BL_NO_PLAYER, 8.0f);
	bs_run(s, 7.0);
	dx = s->p[0].body.pos.x - 205.5f; dy = s->p[0].body.pos.y - 290.5f;
	CHECK(dx * dx + dy * dy < 3.0f * 3.0f && b->order.order == BL_O_HOLD);
	CHECK((s->intents[0].keys & 15) == 0);      /* standing there */
	bs_run(s, 3.0);
	CHECK(seen_doing(s, 0, "obey", 1.0) == 0);
	/* HUNT: a man it cannot see, and is told of */
	bs_order(s, 0, BL_O_HUNT, 0, 0, 0, 1, 0.0f);
	bs_run(s, 40.0);
	printf("  hunt: the man is %s, %d shots\n", s->p[1].alive ? "alive" : "dead", s->p[0].shots);
	CHECK(!s->p[1].alive);
	bs_free(s);
}

static void test_follow_and_retreat(void)
{
	bs_sim *s = game();
	bl_vec3 e0, me;
	int i, hidden = 0;

	printf("follow, retreat\n");
	bs_start(s);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 9, 220.5f, 256.5f, 1, 0);
	bs_add(s, 2, 0, 1, 5, BL_GUN_RIFLE, 2, 224.5f, 250.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\ndo follow mate\n");
	s->p[2].script_keys = BL_K_FORWARD;         /* the mate walks east for 5 s, then stops */
	bs_run(s, 5.0);
	s->p[2].script_keys = 0;
	bs_run(s, 4.0);
	printf("  follow: mate went %.0f voxels; the bot is %.1f from him\n",
	       (double)(s->p[2].body.pos.x - 224.5f), (double)bs_dist(s, 0, 2));
	CHECK(s->p[2].body.pos.x > 250.0f);
	CHECK(bs_dist(s, 0, 2) < 6.0f);
	CHECK(s->p[0].stuck_events == 0);
	bs_free(s);

	s = game();
	bs_box(s, 214, 250, G - 4, 214, 262, G - 1, 1);    /* cover, behind the bot */
	bs_start(s);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 9, 220.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 250.5f, 256.5f, -1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo retreat\n\tdo hold self 60\n");
	for (i = 0; i < 60 * 8; i++) {
		bs_step(s);
		e0.x = s->p[1].body.pos.x; e0.y = s->p[1].body.pos.y; e0.z = s->p[1].body.pos.z;
		me.x = s->p[0].body.pos.x; me.y = s->p[0].body.pos.y; me.z = s->p[0].body.pos.z;
		hidden = !bc_sight_body(s->truth, e0, me, 0);
		if (hidden && i > 60) break;
	}
	printf("  retreat: out of his sight after %.1f s, at %.1f %.1f, %d shots fired on the way\n", i / 60.0,
	       (double)me.x, (double)me.y, s->p[0].shots);
	CHECK(hidden);
	CHECK(s->p[0].shots == 0);
	bs_free(s);
}

static void test_grenade(void)
{
	bs_sim *s = game();
	bl_vec3 from, to, vel, burst, at;
	float flight;
	int i;

	printf("grenades\n");
	/* the arc, on its own */
	from.x = 100.5f; from.y = 100.5f; from.z = 30.0f;
	to = from; to.x += 20.0f; to.z += 2.0f;
	CHECK(bc_grenade_arc(from, to, 0, &vel, &flight) && flight > 0.5f && flight < 1.0f);
	at = bc_grenade_fly(NULL, from, vel, flight + 1.0f / 60.0f);
	CHECK(fabsf(at.x - to.x) < 1.0f && fabsf(at.z - to.z) < 1.0f);
	CHECK(bc_grenade_arc(from, to, 1, &vel, &flight) && flight > 1.5f);    /* the lob */
	to.x = from.x + 40.0f;
	CHECK(!bc_grenade_arc(from, to, 0, &vel, &flight));                    /* 32 is as far as it goes */
	to.x = from.x + 0.2f;
	CHECK(!bc_grenade_arc(from, to, 0, &vel, &flight));
	/* damage: 4096 / d^2, nothing through a wall */
	to = from; to.x += 8.0f;
	CHECK(fabsf(bc_grenade_damage(NULL, from, to) - 64.0f) < 0.01f);
	to.x = from.x + 20.0f;
	CHECK(bc_grenade_damage(NULL, from, to) == 0.0f);

	bs_start(s);
	bs_add(s, 0, 1, 1, 9, BL_GUN_RIFLE, 3, 220.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 242.5f, 255.5f, -1, 0);
	bs_add(s, 3, 0, 2, 5, BL_GUN_RIFLE, 1, 243.5f, 258.5f, -1, 0);     /* two together, 22 away */
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo throw_grenade\n\tdo hold self 2\n");
	CHECK(bc_grenade_plan(s->truth, s->w.players[0].pos, s->w.players[1].pos, &vel, &flight, &burst) ||
	      s->w.players[0].state != BL_ALIVE);
	for (i = 0; i < 60 * 8 && s->nades_thrown == 0; i++)
		bs_step(s);
	bs_run(s, 3.5);
	printf("  thrown after %.1f s; they have %d and %d left, the thrower %d\n", i / 60.0, s->p[1].hp, s->p[3].hp,
	       s->p[0].hp);
	CHECK(s->nades_thrown >= 1);
	CHECK(s->p[1].hp < 100 || s->p[3].hp < 100);
	CHECK(s->p[0].hp == 100);
	CHECK(s->p[0].grenades == 3 - s->nades_thrown);
	bs_free(s);

	/* one thrown AT a bot is run from */
	s = game();
	bs_start(s);
	bs_add(s, 0, 1, 1, 9, BL_GUN_RIFLE, 3, 220.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 320.5f, 256.5f, -1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_set(s, BL_NO_PLAYER, "sight=40");
	bs_run(s, 1.0);
	{
		bl_ev_grenade g;

		memset(&g, 0, sizeof g);
		g.pos.x = s->p[0].body.pos.x + 1.0f; g.pos.y = s->p[0].body.pos.y; g.pos.z = (float)G - 1.0f;
		g.fuse = 2.5f;
		bs_push(s, BL_EV_GRENADE, 1, &g, sizeof g);
		from = g.pos;
	}
	CHECK(seen_doing(s, 0, "evade", 2.4) > 30);
	{
		float dx = s->p[0].body.pos.x - from.x, dy = s->p[0].body.pos.y - from.y;

		printf("  evade: %.1f from where it lay when it burst\n", (double)sqrtf(dx * dx + dy * dy));
		CHECK(dx * dx + dy * dy > 10.0f * 10.0f);
	}
	bs_free(s);
}

static void test_edits(void)
{
	bs_sim *s = game();
	const bc_engine_stats *st;
	int i, y, min_blocks = 50;

	printf("routes that dig and build\n");
	/* a wall right across the map: no way round */
	bs_box(s, 240, 0, G - 5, 241, 511, G - 1, 1);
	bs_start(s);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 8, 230.5f, 256.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\ndo go_to enemy_base\n");
	s->tent[1].x = 255.5f;
	bs_run(s, 12.0);
	CHECK(s->p[0].body.pos.x < 240.0f && s->edits == 0);   /* editing is off: it does not get through */
	bs_set(s, BL_NO_PLAYER, "edit=dig");
	for (i = 0; i < 60 * 40 && s->p[0].body.pos.x < 250.0f; i++)
		bs_step(s);
	st = bc_engine_stats_get(s->e);
	printf("  dug through a two-thick wall in %.1f s: %d digs done, %d asked, %d refused\n", i / 60.0, s->edits,
	       (int)st->edits, s->refused);
	CHECK(s->p[0].body.pos.x >= 250.0f);
	CHECK(s->edits >= 4 && s->edits <= 12);
	CHECK(s->refused <= s->edits);              /* paced to the server's rate, mostly */
	CHECK(s->vis_refused == 0);                 /* nothing a player could not have dug from there */
	CHECK(s->p[0].tool == BL_TOOL_SPADE || s->p[0].tool == BL_TOOL_GUN);
	bs_free(s);

	/* a trench too wide to jump, right across: bridged */
	s = game();
	for (y = 0; y < 512; y++)
		bs_box(s, 240, y, G, 248, y, G + 5, 0);
	bs_start(s);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 8, 230.5f, 256.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\ndo go_to enemy_base\n");
	bs_set(s, BL_NO_PLAYER, "edit=build");
	s->tent[1].x = 258.5f;
	for (i = 0; i < 60 * 60 && s->p[0].body.pos.x < 252.0f; i++) {
		bs_step(s);
		if (s->p[0].blocks < min_blocks) min_blocks = s->p[0].blocks;
	}
	printf("  bridged a 9-wide trench in %.1f s: %d edits (%d of them lines), %d blocks spent, feet at %.1f (ground %d)\n", i / 60.0,
	       s->edits, s->lines, 50 - min_blocks, (double)bc_body_feet(&s->p[0].body), G);
	CHECK(s->p[0].body.pos.x >= 252.0f);
	CHECK(50 - min_blocks >= 3 && 50 - min_blocks <= 14);    /* the rest of the way it jumps */
	CHECK(bc_body_feet(&s->p[0].body) < (float)G + 0.5f);
	CHECK(s->vis_refused == 0);                 /* each block against a face it saw, from the edge */
	bs_free(s);

	/* the server refuses the digs (and says nothing): the bot learns and stops */
	s = game();
	bs_box(s, 240, 0, G - 5, 241, 511, G - 1, 1);
	s->prot = 1; s->px0 = 240; s->py0 = 0; s->px1 = 241; s->py1 = 511;
	bs_start(s);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 8, 230.5f, 256.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tdo go_to enemy_base\n\tdo roam\n");
	bs_set(s, BL_NO_PLAYER, "edit=dig");
	s->tent[1].x = 255.5f;
	bs_run(s, 30.0);
	st = bc_engine_stats_get(s->e);
	printf("  refused wall: %d digs asked in 30 s, %d voxels learned protected\n", (int)st->edits,
	       (int)s->e->protect.n);
	CHECK(s->e->protect.n >= 1);
	CHECK(st->edits < 40);                      /* not hammering at it for ever */
	bs_free(s);
}

static void test_bridge_shot_out(void)
{
	bs_sim *s = game();
	const bc_engine_stats *st;
	float deepest = 0.0f;
	int i, y, x, shot = 0;
	uint32_t replans_before = 0;

	printf("a route across a bridge that is shot out is planned again\n");
	/* a trench 8 wide and 6 deep across the map, a bridge at y 256 and
	 * another far off at y 300 */
	for (y = 0; y < 512; y++)
		bs_box(s, 240, y, G, 247, y, G + 5, 0);
	for (x = 240; x <= 247; x++) {
		bc_map_set(s->truth, x, 256, G, 1);
		bc_map_set(s->truth, x, 300, G, 1);
		bc_map_set(s->truth, x, 301, G, 1);
	}
	bs_start(s);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 8, 222.5f, 256.5f, 1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tree t:\ndo go_to enemy_base\n");
	s->tent[1].x = 262.5f;
	for (i = 0; i < 60 * 60; i++) {
		bs_step(s);
		if (!shot && s->p[0].body.pos.x > 234.0f) {
			/* both ends shot away: what is left hangs in the air and falls */
			replans_before = bc_engine_stats_get(s->e)->replans;
			bs_block(s, BL_NO_PLAYER, 240, 256, G, BL_B_DESTROY);
			bs_block(s, BL_NO_PLAYER, 247, 256, G, BL_B_DESTROY);
			shot = 1;
		}
		if (bc_body_feet(&s->p[0].body) > deepest) deepest = bc_body_feet(&s->p[0].body);
		if (s->p[0].body.pos.x > 258.0f) break;
	}
	st = bc_engine_stats_get(s->e);
	printf("  across by the other bridge after %.1f s; %d plans again; lowest the feet went %.1f (ground %d)\n",
	       i / 60.0, (int)(st->replans - replans_before), (double)deepest, G);
	CHECK(shot);
	CHECK(!bc_map_solid(s->truth, 243, 256, G));       /* the server's deck is gone ... */
	CHECK(!bc_map_solid(s->e->map, 243, 256, G));      /* ... and the engine's: it ran the collapse */
	CHECK(st->replans > replans_before);
	CHECK(s->p[0].body.pos.x > 258.0f);
	CHECK(deepest < (float)G + 1.0f);                  /* never in the trench */
	CHECK(s->p[0].stuck_events == 0);
	bs_free(s);
}

static void test_ping_once(void)
{
	bs_sim *s = game();
	int i;

	printf("a bot that spots enemies pings once, not every tick\n");
	bs_start(s);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, seed_with(BC_T_TEAMWORK, 2.0f, 3.0f, 1), 220.5f, 256.5f, 1, 0);
	bs_add(s, 2, 1, 1, 6, BL_GUN_RIFLE, seed_with(BC_T_TEAMWORK, 2.0f, 3.0f, 900), 220.5f, 262.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 270.5f, 256.5f, -1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	for (i = 0; i < 60 * 12; i++) {
		s->p[1].hp = 100;
		bs_step(s);
	}
	printf("  two keen bots, one enemy in sight for 12 s: %d ping(s), \"%s\"\n", s->pings, s->last_ping);
	CHECK(s->pings == 1);
	CHECK(!strcmp(s->last_ping, "Enemy"));
	CHECK(s->refused == 0);
	bs_free(s);

	/* one that does not care for the team says nothing */
	s = game();
	bs_start(s);
	bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, seed_with(BC_T_TEAMWORK, 0.2f, 0.35f, 1), 220.5f, 256.5f, 1, 0);
	bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 270.5f, 256.5f, -1, 0);
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	for (i = 0; i < 60 * 3; i++) {
		s->p[1].hp = 100;
		bs_step(s);
	}
	printf("  a loner, the same 3 s: %d ping(s)\n", s->pings);
	CHECK(s->pings == 0);
	bs_free(s);
}

/* A number a word used to hard-code is its argument now, with the same
 * default (bot/DECISIONS.md): the default reads as before, the argument
 * changes the answer. */
static void test_word_args(void)
{
	static const char *const trees[2] = {
		"tree=tree t:\nselect\n\tseq\n\t\tif sniped\n\t\tdo hold self 30\n\tdo look_around\n",
		"tree=tree t:\nselect\n\tseq\n\t\tif sniped 30\n\t\tdo hold self 30\n\tdo look_around\n"
	};
	int k, held[2];

	printf("a word's argument where a number was\n");
	for (k = 0; k < 2; k++) {
		bs_sim *s = game();
		bl_vec3 from;

		bs_start(s);
		bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 9, 220.5f, 256.5f, 1, 0);
		bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 260.5f, 256.5f, -1, 0);
		bs_set(s, BL_NO_PLAYER, trees[k]);
		bs_run(s, 0.5);
		from.x = s->p[1].body.pos.x; from.y = s->p[1].body.pos.y; from.z = s->p[1].body.pos.z;
		bs_hurt(s, 0, 10, 1, from, 0);
		held[k] = seen_doing(s, 0, "hold", 1.0);
		bs_free(s);
	}
	printf("  hit from 40 voxels: `if sniped` held %d of 60 ticks, `if sniped 30` %d\n", held[0], held[1]);
	CHECK(held[0] == 0);
	CHECK(held[1] > 30);

	{
		bs_sim *s = game();
		int i, first = -1, was = -1;
		char d[300];

		bs_start(s);
		bs_add(s, 0, 1, 1, 6, BL_GUN_RIFLE, 9, 220.5f, 256.5f, 1, 0);
		bs_add(s, 1, 0, 2, 5, BL_GUN_RIFLE, 1, 250.5f, 256.5f, -1, 0);
		bs_set(s, BL_NO_PLAYER, "tree=tree t:\nselect\n\tseq\n\t\tdo retreat 2\n\t\tdo hold self 60\n\tdo hold self 60\n");
		for (i = 0; i < 60 * 6 && first < 0; i++) {
			bs_step(s);
			bc_engine_describe(s->e, 0, d, sizeof d);
			if (strstr(d, "retreat")) { if (was < 0) was = i; }
			else if (was >= 0) first = i - was;
		}
		printf("  `retreat 2` in sight of him: done after %.1f s\n", first / 60.0);
		CHECK(first >= 60 * 1 && first < 60 * 3);
		bs_free(s);
	}
}

int main(void)
{
	test_kill_standing();
	test_fire_discipline();
	test_mate_in_line();
	test_investigate();
	test_orders();
	test_follow_and_retreat();
	test_grenade();
	test_edits();
	test_bridge_shot_out();
	test_ping_once();
	test_word_args();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
