/* senses_test.c -- what one bot knows: sight, night, hearing, memory, the board */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "senses.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static bc_map *m;
static bl_world w;
static bc_sense_cfg cfg;
static bc_senses s, s2;

enum { GROUND = 40 };
static const float EYE = (float)GROUND - 2.25f;

/* player `pid` of `team` at (x, y), standing, facing (fx, fy) */
static void put(int pid, int team, float x, float y, float fx, float fy)
{
	bl_player *p = &w.players[pid];

	memset(p, 0, sizeof *p);
	p->state = BL_ALIVE;
	p->team = (uint8_t)team;
	p->hp = 100;
	p->pos.x = x; p->pos.y = y; p->pos.z = EYE;
	p->ori.x = fx; p->ori.y = fy;
}

static void fresh(void)
{
	memset(&w, 0, sizeof w);
	bc_senses_reset(&s);
	bc_senses_reset(&s2);
	bc_sense_cfg_default(&cfg);
	cfg.night_sight = 1;        /* as a server with a night script sets it */
	bc_map_fill_flat(m, GROUND);
	put(0, 1, 100.5f, 100.5f, 1.0f, 0.0f);     /* the bot: faces east */
}

static int sees(int pid, int nv, double now)
{
	bc_senses_see(&s, &cfg, m, &w, 0, nv, now, NULL);
	return s.k[pid].visible;
}

static void test_day(void)
{
	int x, z;

	printf("sight by day\n");
	fresh();
	put(1, 2, 130.5f, 100.5f, -1.0f, 0.0f);
	CHECK(sees(1, 0, 0.0));                     /* ahead, 30 away */
	CHECK(s.n_visible == 1 && s.nearest == 1);
	CHECK(s.alert == BC_ALERT_ENGAGED);

	fresh();
	put(1, 2, 70.5f, 100.5f, 1.0f, 0.0f);
	CHECK(!sees(1, 0, 0.0));                    /* behind, 30 away */
	put(1, 2, 100.5f, 130.5f, 1.0f, 0.0f);
	CHECK(sees(1, 0, 0.0));                     /* exactly abeam: the edge of 180 */
	fresh();
	put(1, 2, 99.5f, 130.5f, 1.0f, 0.0f);
	CHECK(!sees(1, 0, 0.0));                    /* a little behind abeam */

	/* close: heard whatever the facing -- if he makes a noise */
	fresh();
	put(1, 2, 94.5f, 100.5f, 1.0f, 0.0f);       /* 6 behind */
	w.players[1].vel.x = 0.2f;                  /* 6.4 voxels/s: walking */
	CHECK(sees(1, 0, 0.0));
	fresh();
	put(1, 2, 94.5f, 100.5f, 1.0f, 0.0f);       /* 6 behind, standing still */
	CHECK(!sees(1, 0, 0.0));
	put(1, 2, 97.5f, 100.5f, 1.0f, 0.0f);       /* 3 behind, still: half the radius */
	CHECK(sees(1, 0, 0.0));
	fresh();
	put(1, 2, 94.5f, 100.5f, 1.0f, 0.0f);
	w.players[1].vel.x = 0.2f;
	w.players[1].flags |= BL_F_CROUCH;          /* crouched: quiet */
	CHECK(!sees(1, 0, 0.0));

	/* range: the fog */
	fresh();
	put(1, 2, 100.5f + 120.0f, 100.5f, -1.0f, 0.0f);
	CHECK(sees(1, 0, 0.0));
	put(1, 2, 100.5f + 135.0f, 100.5f, -1.0f, 0.0f);
	CHECK(!sees(1, 0, 1.0));
	cfg.sight = 60.0f;                          /* a setting */
	put(1, 2, 100.5f + 80.0f, 100.5f, -1.0f, 0.0f);
	CHECK(!sees(1, 0, 20.0));

	/* line of sight: a wall four high hides him, a kerb does not */
	fresh();
	put(1, 2, 130.5f, 100.5f, -1.0f, 0.0f);
	for (z = GROUND - 4; z < GROUND; z++)
		for (x = 90; x <= 110; x++)
			bc_map_set(m, 115, x, z, 1);
	CHECK(!sees(1, 0, 0.0));
	CHECK(s.alert == BC_ALERT_CALM);
	fresh();
	put(1, 2, 130.5f, 100.5f, -1.0f, 0.0f);
	for (x = 90; x <= 110; x++)
		bc_map_set(m, 115, x, GROUND - 1, 1);   /* one voxel: his head shows */
	CHECK(sees(1, 0, 0.0));
	/* a team-mate is never an "enemy seen"; a dead man neither */
	fresh();
	put(1, 1, 130.5f, 100.5f, -1.0f, 0.0f);
	CHECK(!sees(1, 0, 0.0));
	put(1, 2, 130.5f, 100.5f, -1.0f, 0.0f);
	w.players[1].state = BL_DEAD;
	CHECK(!sees(1, 0, 0.0));
	CHECK(bc_sight_clear(m, w.players[0].pos, w.players[1].pos));
}

static void test_memory(void)
{
	bl_vec3 p;
	int what;

	printf("memory\n");
	fresh();
	put(1, 2, 130.5f, 100.5f, -1.0f, 0.0f);
	w.players[1].vel.y = 0.25f;                 /* going south at 8/s */
	CHECK(sees(1, 0, 10.0));
	CHECK(bc_senses_confidence(&s, &cfg, 1, 10.0) == 1.0f);
	/* he steps behind the bot: still "noticed" for 6 s, so still seen */
	put(1, 2, 70.5f, 100.5f, 1.0f, 0.0f);
	CHECK(sees(1, 0, 11.0));
	/* gone behind a wall (here: out of range) */
	put(1, 2, 400.5f, 100.5f, 1.0f, 0.0f);
	CHECK(!sees(1, 0, 12.0));
	CHECK(s.k[1].pos.x == 70.5f);               /* where he was last seen */
	CHECK(s.nearest_known == 1);
	CHECK(s.lost.valid && s.lost.by == 1);
	CHECK(s.alert == BC_ALERT_ENGAGED);         /* 1.5 s of grace */
	CHECK(!sees(1, 0, 13.0));
	CHECK(s.alert == BC_ALERT_SUSPICIOUS);
	CHECK(bc_senses_search(&s, &cfg, 13.0, &p, &what) && what == 1);
	{
		float c1 = bc_senses_confidence(&s, &cfg, 1, 13.0), c2 = bc_senses_confidence(&s, &cfg, 1, 18.0);

		CHECK(c1 < 1.0f && c2 < c1 && c2 > 0.0f);       /* it fades */
	}
	CHECK(!sees(1, 0, 12.0 + 12.5));            /* past `memory` */
	CHECK(bc_senses_confidence(&s, &cfg, 1, 24.5) == 0.0f);
	CHECK(s.nearest_known == -1);
	CHECK(s.alert == BC_ALERT_CALM);
	/* a place looked at is forgotten */
	fresh();
	put(1, 2, 130.5f, 100.5f, -1.0f, 0.0f);
	sees(1, 0, 0.0);
	put(1, 2, 400.5f, 100.5f, 1.0f, 0.0f);
	sees(1, 0, 2.0);
	CHECK(bc_senses_search(&s, &cfg, 2.0, &p, &what));
	bc_senses_searched(&s, what);
	CHECK(bc_senses_search(&s, &cfg, 2.0, &p, &what) && what == 4);     /* the man himself, remembered */
	bc_senses_searched(&s, what);
	CHECK(!bc_senses_search(&s, &cfg, 2.0, &p, &what));
}

static void test_night(void)
{
	bl_vec3 shot;
	int x, z, nv;

	printf("night\n");
	/* with no night script (night.sight unset) a night world is seen as day */
	fresh();
	cfg.night_sight = 0;
	w.night = 1;
	put(1, 2, 130.5f, 100.5f, -1.0f, 0.0f);
	put(2, 2, 70.5f, 100.5f, 1.0f, 0.0f);
	bc_senses_see(&s, &cfg, m, &w, 0, 0, 0.0, NULL);
	CHECK(s.k[1].visible && !s.k[2].visible && (s.k[1].how & BC_SEE_VIEW));
	w.players[0].flags |= BL_F_LAMP;
	bc_senses_see(&s, &cfg, m, &w, 0, 1, 1.0, NULL);
	CHECK(s.k[1].visible && !s.k[2].visible);
	/* ROW 3: lamp out, no night vision: nothing, even right in front */
	fresh();
	w.night = 1;
	put(1, 2, 105.5f, 100.5f, -1.0f, 0.0f);
	CHECK(!sees(1, 0, 0.0));
	put(1, 2, 102.5f, 100.5f, -1.0f, 0.0f);
	w.players[1].vel.x = 0.2f;
	CHECK(!sees(1, 0, 0.0));                    /* not even at arm's length, walking */
	w.players[1].flags |= BL_F_LAMP;
	CHECK(!sees(1, 0, 0.0));                    /* nor with HIS lamp lit */
	CHECK(s.n_visible == 0 && s.alert == BC_ALERT_CALM);
	/* ... but it hears: a place to turn to, not a target */
	shot = w.players[1].pos;
	CHECK(bc_senses_hear(&s, &cfg, &w, 0, 5, BL_S_SHOT, shot, 1, 0.5));
	CHECK(s.noise.valid && s.alert == BC_ALERT_SUSPICIOUS && s.n_visible == 0);

	/* ROW 2: lamp lit, no night vision: its own cone and nothing else */
	fresh();
	w.night = 1;
	w.players[0].flags |= BL_F_LAMP;
	put(1, 2, 130.5f, 100.5f, -1.0f, 0.0f);     /* in the cone, 30 away */
	CHECK(sees(1, 0, 0.0));
	CHECK(s.k[1].how & BC_SEE_LAMP);
	fresh();
	w.night = 1;
	w.players[0].flags |= BL_F_LAMP;
	put(1, 2, 100.5f + 15.0f, 100.5f + 26.0f, -1.0f, 0.0f);    /* 30 away, 60 degrees off: beside */
	CHECK(!sees(1, 0, 0.0));
	put(1, 2, 70.5f, 100.5f, 1.0f, 0.0f);       /* 30 away, behind */
	CHECK(!sees(1, 0, 0.0));
	put(1, 2, 97.5f, 100.5f, 1.0f, 0.0f);       /* 3 behind, walking, lamp lit: still no */
	w.players[1].vel.x = 0.2f;
	w.players[1].flags |= BL_F_LAMP;
	CHECK(!sees(1, 0, 0.0));
	put(1, 2, 100.5f + 70.0f, 100.5f, -1.0f, 0.0f);    /* ahead, beyond the lamp's 60 */
	CHECK(!sees(1, 0, 0.0));
	put(1, 2, 100.5f + 55.0f, 100.5f, -1.0f, 0.0f);
	CHECK(sees(1, 0, 0.0));
	cfg.lamp_range = 30.0f;                     /* settings */
	CHECK(!sees(1, 0, 9.0));
	cfg.lamp_range = 60.0f;
	cfg.lamp_cone_deg = 150.0f;
	put(1, 2, 100.5f + 15.0f, 100.5f + 26.0f, -1.0f, 0.0f);
	CHECK(sees(1, 0, 20.0));

	/* ROW 1: night vision: as by day, and a lit lamp from farther */
	fresh();
	w.night = 1;
	put(1, 2, 100.5f + 100.0f, 100.5f, -1.0f, 0.0f);    /* lamp out, day range */
	CHECK(sees(1, 1, 0.0));
	put(1, 2, 100.5f + 160.0f, 100.5f, -1.0f, 0.0f);    /* lamp out, beyond day range */
	CHECK(!sees(1, 1, 10.0));
	w.players[1].flags |= BL_F_LAMP;                    /* lamp lit, beyond day range */
	CHECK(sees(1, 1, 20.0));
	CHECK(s.k[1].how & BC_SEE_LIT);
	put(1, 2, 100.5f + 200.0f, 100.5f, -1.0f, 0.0f);    /* beyond the far range too */
	w.players[1].flags |= BL_F_LAMP;
	CHECK(!sees(1, 1, 40.0));
	fresh();
	w.night = 1;
	put(1, 2, 70.5f, 100.5f, 1.0f, 0.0f);               /* behind: the field of view holds */
	CHECK(!sees(1, 1, 0.0));
	/* neither through a wall */
	for (z = GROUND - 5; z < GROUND; z++)
		for (x = 80; x <= 120; x++)
			bc_map_set(m, 115, x, z, 1);
	put(1, 2, 130.5f, 100.5f, -1.0f, 0.0f);
	put(2, 2, 240.5f, 100.5f, -1.0f, 0.0f);
	w.players[2].flags |= BL_F_LAMP;
	bc_senses_see(&s, &cfg, m, &w, 0, 1, 50.0, NULL);
	CHECK(!s.k[1].visible && !s.k[2].visible);

	/* BY DAY the three bots see alike */
	for (nv = 0; nv < 2; nv++) {
		int lamp;

		for (lamp = 0; lamp < 2; lamp++) {
			fresh();
			if (lamp) w.players[0].flags |= BL_F_LAMP;
			put(1, 2, 100.5f + 100.0f, 100.5f, -1.0f, 0.0f);
			put(2, 2, 100.5f + 15.0f, 100.5f + 26.0f, -1.0f, 0.0f);
			put(3, 2, 70.5f, 100.5f, 1.0f, 0.0f);
			put(4, 2, 100.5f + 160.0f, 100.5f, -1.0f, 0.0f);
			w.players[4].flags |= BL_F_LAMP;
			bc_senses_see(&s, &cfg, m, &w, 0, nv, 0.0, NULL);
			CHECK(s.k[1].visible && s.k[2].visible && !s.k[3].visible && !s.k[4].visible);
		}
	}
}

static void test_hearing(void)
{
	bl_vec3 at;
	int level;

	printf("hearing\n");
	/* aosbot's ranges, by level */
	CHECK(bc_hear_range(BL_S_SHOT, 1) == 14.0f && bc_hear_range(BL_S_SHOT, 10) == 34.0f);
	CHECK(bc_hear_range(BL_S_DIG, 1) == 6.0f && bc_hear_range(BL_S_BUILD, 10) == 14.0f);
	CHECK(bc_hear_range(BL_S_STEP, 10) == 8.0f && bc_hear_range(BL_S_BLAST, 10) == 48.0f);
	for (level = 2; level <= 10; level++)
		CHECK(bc_hear_range(BL_S_SHOT, level) > bc_hear_range(BL_S_SHOT, level - 1));
	/* a spade on a man makes no event; there is no kind for it */
	CHECK(bc_hear_range(0, 10) == 0.0f);

	fresh();
	put(1, 2, 80.5f, 100.5f, 1.0f, 0.0f);       /* 20 behind: not seen */
	at = w.players[1].pos;
	CHECK(!bc_senses_hear(&s, &cfg, &w, 0, 1, BL_S_SHOT, at, 1, 1.0));    /* level 1 hears to 14 */
	CHECK(s.alert == BC_ALERT_CALM);
	CHECK(bc_senses_hear(&s, &cfg, &w, 0, 10, BL_S_SHOT, at, 1, 1.0));    /* level 10 to 34 */
	CHECK(s.noise.valid && s.noise.kind == BL_S_SHOT && s.noise.pos.x == 80.5f);
	CHECK(s.alert == BC_ALERT_SUSPICIOUS);
	/* a dig carries less far */
	bc_senses_reset(&s);
	CHECK(!bc_senses_hear(&s, &cfg, &w, 0, 10, BL_S_DIG, at, 1, 1.0));
	put(1, 2, 90.5f, 100.5f, 1.0f, 0.0f);
	at = w.players[1].pos;
	CHECK(bc_senses_hear(&s, &cfg, &w, 0, 10, BL_S_DIG, at, 1, 1.0));
	CHECK(!bc_senses_hear(&s2, &cfg, &w, 0, 1, BL_S_DIG, at, 1, 1.0));
	/* a nearer noise replaces a fresh one; a farther one does not, until it is stale */
	at.x = 95.5f;
	CHECK(bc_senses_hear(&s, &cfg, &w, 0, 10, BL_S_SHOT, at, 1, 1.5));
	at.x = 85.5f;
	CHECK(!bc_senses_hear(&s, &cfg, &w, 0, 10, BL_S_SHOT, at, 1, 2.0));
	CHECK(bc_senses_hear(&s, &cfg, &w, 0, 10, BL_S_SHOT, at, 1, 3.0));
	/* a team-mate's noise is no news; nor is the bot's own */
	bc_senses_reset(&s);
	put(2, 1, 95.5f, 100.5f, 1.0f, 0.0f);
	CHECK(!bc_senses_hear(&s, &cfg, &w, 0, 10, BL_S_SHOT, w.players[2].pos, 2, 4.0));
	CHECK(!bc_senses_hear(&s, &cfg, &w, 0, 10, BL_S_SHOT, w.players[0].pos, 0, 4.0));
	/* a man in sight is a target, not a noise */
	put(1, 2, 110.5f, 100.5f, -1.0f, 0.0f);
	CHECK(sees(1, 0, 5.0));
	CHECK(!bc_senses_hear(&s, &cfg, &w, 0, 10, BL_S_SHOT, w.players[1].pos, 1, 5.0));
	/* a noise is worth going to for noise_secs, then not */
	fresh();
	put(1, 2, 80.5f, 100.5f, 1.0f, 0.0f);
	bc_senses_hear(&s, &cfg, &w, 0, 10, BL_S_SHOT, w.players[1].pos, 1, 1.0);
	sees(1, 0, 5.0);
	CHECK(s.alert == BC_ALERT_SUSPICIOUS);
	sees(1, 0, 12.0);
	CHECK(s.alert == BC_ALERT_CALM);
}

static void test_hurt(void)
{
	bc_rng rng;
	bl_vec3 from;
	float worst1 = 0.0f, worst10 = 0.0f;
	int i;

	printf("being hurt\n");
	bc_rng_seed(&rng, 5, 5);
	for (i = 0; i < 400; i++) {
		int level = (i & 1) ? 10 : 1;
		float ang;

		fresh();
		put(1, 2, 100.5f, 160.5f, 0.0f, -1.0f);     /* due south, 60 away, unseen */
		from = w.players[1].pos;
		bc_senses_hurt(&s, &rng, &w, 0, level, from, 1, 3.0);
		CHECK(s.threat.valid && s.threat.by == 1 && s.hurt_at == 3.0);
		ang = fabsf(atan2f(s.threat.pos.x - 100.5f, s.threat.pos.y - 100.5f)) * 57.29578f;
		if (level == 1 && ang > worst1) worst1 = ang;
		if (level == 10 && ang > worst10) worst10 = ang;
	}
	printf("  bearing error: level 1 up to %.1f deg, level 10 up to %.1f deg\n", (double)worst1, (double)worst10);
	CHECK(worst1 > 20.0f && worst1 <= 38.0f);       /* 40 - 36 x 0.06 */
	CHECK(worst10 <= 5.5f);
	CHECK(fabsf(s.threat_dist - 60.0f) < 0.01f);
	CHECK(s.alert == BC_ALERT_SUSPICIOUS);
	/* a fall: from its own place, by nobody */
	fresh();
	bc_senses_hurt(&s, &rng, &w, 0, 5, w.players[0].pos, BL_NO_PLAYER, 1.0);
	CHECK(!s.threat.valid && s.hurt_at == 1.0 && s.alert == BC_ALERT_CALM);
}

static void test_board(void)
{
	bc_board *b = malloc(sizeof *b);
	bc_ping *pg;
	bl_vec3 p;
	int what;

	printf("the board\n");
	bc_board_clear(b);
	fresh();
	put(1, 2, 130.5f, 100.5f, -1.0f, 0.0f);     /* the enemy */
	put(2, 1, 100.5f, 300.5f, 1.0f, 0.0f);      /* a team-mate far away, who cannot see him */
	cfg.sight = 60.0f;
	bc_senses_see(&s, &cfg, m, &w, 0, 0, 10.0, b);
	CHECK(s.k[1].visible && s.spotted_new_at == 10.0);
	bc_senses_see(&s2, &cfg, m, &w, 2, 0, 10.0, b);
	CHECK(s2.nearest_known == -1);              /* not told yet */
	bc_senses_see(&s, &cfg, m, &w, 0, 0, 11.0, b);
	CHECK(s.spotted_new_at == 10.0);            /* new once, not every look */
	bc_senses_see(&s2, &cfg, m, &w, 2, 0, 11.0, b);
	CHECK(s2.nearest_known == -1);              /* relay is 1.5 s */
	bc_senses_see(&s, &cfg, m, &w, 0, 0, 12.0, b);
	bc_senses_see(&s2, &cfg, m, &w, 2, 0, 12.0, b);
	CHECK(s2.nearest_known == 1 && !s2.k[1].visible && s2.n_visible == 0);
	CHECK(s2.k[1].pos.x == 130.5f);
	CHECK(bc_senses_search(&s2, &cfg, 12.0, &p, &what) && what == 4);
	CHECK(s2.alert == BC_ALERT_SUSPICIOUS);     /* a place, not a target */
	/* gone to and nothing there: not told the same news again */
	bc_senses_searched(&s2, 4);
	bc_senses_see(&s2, &cfg, m, &w, 2, 0, 12.1, b);
	CHECK(s2.nearest_known == -1);
	/* news goes stale */
	bc_senses_reset(&s2);
	bc_senses_see(&s2, &cfg, m, &w, 2, 0, 12.0 + 11.0, b);
	CHECK(s2.nearest_known == -1);

	/* pings */
	CHECK(bc_ping_kind("Enemy") == BC_PING_ENEMY && bc_ping_kind("Sniper") == BC_PING_ENEMY);
	CHECK(bc_ping_kind("Enemy here!") == BC_PING_ENEMY && bc_ping_kind("enemies spotted") == BC_PING_ENEMY);
	CHECK(bc_ping_kind("Need help") == BC_PING_HELP && bc_ping_kind("Need backup") == BC_PING_HELP);
	CHECK(bc_ping_kind("Go here") == BC_PING_GO && bc_ping_kind("") == BC_PING_GO && bc_ping_kind("Defend") == BC_PING_GO);
	CHECK(bc_ping_kind("Thanks") == BC_PING_NONE && bc_ping_kind("no") == BC_PING_NONE);
	p.x = 50.0f; p.y = 50.0f; p.z = 30.0f;
	pg = bc_board_ping(b, 1, 0, p, BC_PING_ENEMY, 5.0, 15.0);
	CHECK(pg && pg->valid && pg->id != 0);
	CHECK(bc_board_pinged(b, 1, p, BC_PING_ENEMY, 20.0f, 6.0));
	CHECK(!bc_board_pinged(b, 2, p, BC_PING_ENEMY, 20.0f, 6.0));
	CHECK(!bc_board_pinged(b, 1, p, BC_PING_HELP, 20.0f, 6.0));
	CHECK(!bc_board_pinged(b, 1, p, BC_PING_ENEMY, 20.0f, 21.0));       /* it stood 15 s */
	p.x = 200.0f;
	bc_board_ping(b, 1, 0, p, BC_PING_ENEMY, 6.0, 15.0);                /* the same caller: the first is withdrawn */
	p.x = 50.0f;
	CHECK(!bc_board_pinged(b, 1, p, BC_PING_ENEMY, 20.0f, 7.0));
	free(b);
}

int main(void)
{
	float v;

	m = malloc(sizeof *m);
	test_day();
	test_memory();
	test_night();
	test_hearing();
	test_hurt();
	test_board();
	bc_sense_cfg_default(&cfg);
	CHECK(cfg.night_sight == 0);
	CHECK(bc_sense_cfg_set(&cfg, "night.cone", 75.0f) && cfg.lamp_cone_deg == 75.0f);
	CHECK(bc_sense_cfg_set(&cfg, "night.sight", 1.0f) && cfg.night_sight == 1);
	CHECK(bc_sense_cfg_set(&cfg, "night.reach", 50.0f) && cfg.lamp_range == 50.0f);
	CHECK(bc_sense_cfg_set(&cfg, "night.far", 150.0f) && cfg.lit_range == 150.0f);
	bc_sense_cfg_default(&cfg);
	CHECK(!bc_sense_cfg_set(&cfg, "no_such", 1.0f));
	v = cfg.lit_range;
	CHECK(v == 192.0f && cfg.lamp_range == 60.0f);
	free(m);
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
