/* bench.c -- the numbers a change is judged by, one line a metric
 *
 *   make -C bot build/tests/bench
 *   bot/build/tests/bench                 every built-in scene
 *   bot/build/tests/bench arena40 sea40   those scenes
 *   bot/build/tests/bench map:/path/to/prisonbreakv1.vxl [secs]
 *   bot/build/tests/bench ctf:10          ctf, 10 a side
 *   bot/build/tests/bench > before.txt ; (change) ; bench > after.txt ; diff before.txt after.txt
 *
 * Not a test: nothing is asserted, and it is not part of `make test`. It
 * is the simulated server of brain_sim.h, the trees of trees/, and a
 * stable output:   <scene> <metric> <value> <unit>
 * Everything but the two think_* lines is the same on every machine and
 * every run (the bots' dice are their seeds).
 *
 * SCENES
 *   arena12 arena32 arena40   a flat field with walls, tdm, respawning, 60 s
 *   fight6 fight20            6 / 20 a side to the last man, tdm
 *   sea40                     two islands in a sea, both bases in the water, 40 bots, 60 s
 *   ctf:<n>                   ctf, n a side, a town of walls, four games of 300 s
 *   ctfnear:<n>               the same with each intel right beside its base
 *   map:<file.vxl> [secs]     40 bots, tdm, on a real map, bases at 1/4 and 3/4 of it (120 s)
 *
 * METRICS
 *   think_mean_us, think_worst_us   bc_engine_think, a call (the host calls twice a world)
 *   no_key_pct       living bot-time with no movement key and no trigger
 *   waiting_pct      ... of which standing waiting for a route
 *   longest_idle_s   the longest one bot went so
 *   wading_pct       living bot-time in the water
 *   plans, plans_capped, plans_no_way, expansions_per_plan
 *   kills, stuck (one cell, keys down, over 3 s), goals_dropped (the net)
 *   head_on_heading_pct  of the time a bot travels (over 3 voxels/s, on the
 *                    ground, nobody in its sight, not shot at for 3 s): the head within 30
 *                    degrees of the way it goes
 *   head_away_spells over a second at a stretch travelling so with the head
 *                    more than 60 degrees off
 *   result_s         seconds to the last man of a team (fight*), -1: none
 *   captures_in_4_games, games_with_a_capture, first_capture_mean_s, pickups, drops (ctf)
 */
#include "brain_sim.h"

enum { G = 40 };
static const float EYE = (float)G - 2.25f;

typedef struct tally {
	long alive, idle, waiting, wet;
	int spell[BL_MAX_PLAYERS], longest;
	/* the head while travelling with nobody in its sight */
	long travel, on_heading;
	int away[BL_MAX_PLAYERS], away_spells;
} tally;

static void out(const char *scene, const char *metric, double v, const char *unit)
{
	if (v == floor(v) && fabs(v) < 1e9) printf("%s %s %.0f %s\n", scene, metric, v, unit);
	else printf("%s %s %.1f %s\n", scene, metric, v, unit);
}

static void watch(bs_sim *s, tally *t)
{
	int i;

	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		const bc_bot *b;

		if (!s->p[i].used || !s->p[i].bot || !s->p[i].alive) { t->spell[i] = t->away[i] = 0; continue; }
		b = bc_engine_bot(s->e, i);
		t->alive++;
		t->wet += s->p[i].body.wade != 0;
		{
			/* travelling: moving over 3 voxels a second on the ground, with
			 * nobody in its sight and no round at it for 3 s. On the heading: the head within 30
			 * degrees of the way the body goes. Away: over 60 degrees off
			 * for more than a second at a stretch */
			float vx = s->p[i].body.vel.x, vy = s->p[i].body.vel.y, v = sqrtf(vx * vx + vy * vy);
			float ox = s->p[i].ori.x, oy = s->p[i].ori.y, o = sqrtf(ox * ox + oy * oy), c;

			if (b && b->senses.n_visible == 0 && s->e->now - b->senses.shot_at > 3.0 && !s->p[i].body.airborne &&
			    v * 32.0f > 3.0f && o > 0.1f) {
				c = (vx * ox + vy * oy) / (v * o);
				t->travel++;
				t->on_heading += c >= 0.866f;
				if (c < 0.5f) { if (++t->away[i] == 60) t->away_spells++; }
				else t->away[i] = 0;
			} else {
				t->away[i] = 0;
			}
		}
		if ((s->intents[i].keys & 15) || s->intents[i].mouse) { t->spell[i] = 0; continue; }
		t->idle++;
		if (b && b->mv.state == BC_MV_PLANNING && b->wish.move == BC_MOVE_GOTO) t->waiting++;
		if (++t->spell[i] > t->longest) t->longest = t->spell[i];
	}
}

static void report(const char *scene, bs_sim *s, const tally *t)
{
	const bc_engine_stats *st = bc_engine_stats_get(s->e);
	int i, stuck = 0;

	for (i = 0; i < BL_MAX_PLAYERS; i++)
		if (s->p[i].used) stuck += s->p[i].stuck_events;
	out(scene, "think_mean_us", s->think_us / (double)(s->thinks ? s->thinks : 1), "us");
	out(scene, "think_worst_us", s->think_max_us, "us");
	if (t->alive) {
		out(scene, "no_key_pct", 100.0 * (double)t->idle / (double)t->alive, "%");
		out(scene, "waiting_pct", 100.0 * (double)t->waiting / (double)t->alive, "%");
		out(scene, "longest_idle_s", t->longest / 60.0, "s");
		out(scene, "wading_pct", 100.0 * (double)t->wet / (double)t->alive, "%");
	}
	if (t->travel) {
		out(scene, "head_on_heading_pct", 100.0 * (double)t->on_heading / (double)t->travel, "%");
		out(scene, "head_away_spells", t->away_spells, "");
	}
	out(scene, "plans", st->plans, "");
	out(scene, "plans_capped", st->plan_caps, "");
	out(scene, "plans_no_way", st->plan_fails, "");
	out(scene, "expansions_per_plan", st->plans ? (double)st->expansions / (double)st->plans : 0.0, "");
	out(scene, "kills", s->kills[1] + s->kills[2], "");
	out(scene, "stuck", stuck, "");
	out(scene, "goals_dropped", st->stuck_resets, "");
}

static bs_sim *arena(int max_bots)
{
	bs_sim *s = bs_new(G, max_bots);
	int i;

	s->have_tents = 1;
	s->tent[0].x = 205.5f; s->tent[0].y = 256.5f; s->tent[0].z = EYE;
	s->tent[1].x = 295.5f; s->tent[1].y = 256.5f; s->tent[1].z = EYE;
	for (i = 0; i < 6; i++) {
		int x = 225 + i * 10, y = 236 + ((i * 17) % 40);

		bs_box(s, x, y, G - 4, x + 1, y + 6, G - 1, 1);
	}
	bs_box(s, 248, 250, G - 1, 252, 262, G - 1, 1);
	return s;
}

static void teams(bs_sim *s, int per, float x1, float x2, uint32_t seed, const char *tree)
{
	char set[64];
	int i;

	for (i = 0; i < per; i++) {
		float y = 256.5f - 2.5f * (float)per + 5.0f * (float)i;

		if (y < 180.0f) y = 180.0f + (float)(i % 30) * 5.0f;
		bs_add(s, i, 1, 1, 3 + (i * 3) % 7, i % 3, seed + (uint32_t)i * 7919u, x1 + (float)(i % 3) * 2.0f, y, 1, 0);
		bs_add(s, 100 + i, 1, 2, 3 + (i * 5) % 7, (i + 1) % 3, seed + 500u + (uint32_t)i * 104729u, x2 - (float)(i % 3) * 2.0f, y, -1, 0);
	}
	snprintf(set, sizeof set, "tree=%s", tree);
	bs_set(s, BL_NO_PLAYER, set);
}

static void scene_arena(int per)
{
	char name[32];
	bs_sim *s = arena(per * 2);
	tally t;
	int k;

	memset(&t, 0, sizeof t);
	snprintf(name, sizeof name, "arena%d", per * 2);
	bs_start(s);
	s->respawn = 3.0;
	teams(s, per, 207.5f, 293.5f, 4242, "tdm");
	for (k = 0; k < 60 * 60; k++) { bs_step(s); watch(s, &t); }
	report(name, s, &t);
	bs_free(s);
}

static void scene_fight(int per)
{
	char name[32];
	bs_sim *s = bs_new(G, per * 2);
	tally t;
	int i, k, a1 = per, a2 = per;

	memset(&t, 0, sizeof t);
	snprintf(name, sizeof name, "fight%d", per);
	s->have_tents = 1;
	s->tent[0].x = 190.5f; s->tent[0].y = 256.5f; s->tent[0].z = EYE;
	s->tent[1].x = 320.5f; s->tent[1].y = 256.5f; s->tent[1].z = EYE;
	for (i = 0; i < 40; i++) {
		int x = 206 + (i % 8) * 13 + (i * 5) % 7, y = 206 + (i / 8) * 21 + (i * 11) % 9;

		if (i % 2) bs_box(s, x, y, G - 4, x, y + 6, G - 1, 1);
		else bs_box(s, x, y, G - 4, x + 6, y, G - 1, 1);
	}
	bs_start(s);
	for (i = 0; i < per; i++) {
		bs_add(s, i, 1, 1, 3 + (i * 3) % 7, i % 3, 2026u + (uint32_t)i * 7919u, 192.5f + (float)(i % 4) * 2.5f, 232.5f + 2.5f * (float)i, 1, 0);
		bs_add(s, 100 + i, 1, 2, 3 + (i * 5) % 7, (i + 1) % 3, 2526u + (uint32_t)i * 104729u, 318.5f - (float)(i % 4) * 2.5f, 232.5f + 2.5f * (float)i, -1, 0);
	}
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	for (k = 0; k < 60 * 600 && a1 > 0 && a2 > 0; k++) {
		bs_step(s);
		watch(s, &t);
		a1 = a2 = 0;
		for (i = 0; i < BL_MAX_PLAYERS; i++)
			if (s->p[i].used && s->p[i].alive) { if (s->p[i].team == 1) a1++; else a2++; }
	}
	out(name, "result_s", a1 == 0 || a2 == 0 ? k / 60.0 : -1.0, "s");
	report(name, s, &t);
	bs_free(s);
}

static void scene_sea(void)
{
	bs_sim *s = bs_new(62, 40);
	tally t;
	int x, y, i, k;

	memset(&t, 0, sizeof t);
	for (y = 0; y < 512; y++)
		for (x = 0; x < 512; x++)
			if (!((x >= 140 && x <= 260 && y >= 190 && y <= 320) || (x >= 300 && x <= 380 && y >= 200 && y <= 300)))
				bc_map_set(s->truth, x, y, 62, 0);
	s->have_tents = 1;
	s->tent[0].x = 100.5f; s->tent[0].y = 256.5f; s->tent[0].z = 61.75f;
	s->tent[1].x = 440.5f; s->tent[1].y = 256.5f; s->tent[1].z = 61.75f;
	bs_start(s);
	s->respawn = 4.0;
	for (i = 0; i < 20; i++) {
		bs_add(s, i, 1, 1, 3 + (i * 3) % 7, i % 3, 61u + (uint32_t)i * 7919u, 120.5f + (float)(i % 5) * 9.0f, 215.5f + (float)(i / 5) * 24.0f, 1, 0);
		bs_add(s, 100 + i, 1, 2, 3 + (i * 5) % 7, (i + 1) % 3, 561u + (uint32_t)i * 104729u, 400.5f - (float)(i % 5) * 9.0f, 215.5f + (float)(i / 5) * 22.0f, -1, 0);
	}
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	for (k = 0; k < 60 * 60; k++) { bs_step(s); watch(s, &t); }
	report("sea40", s, &t);
	bs_free(s);
}

/* four games (four sets of characters); `near`: each intel right beside
 * its base (within 8), not 5 to 40 voxels out toward the middle as the
 * server's random placing has it */
static void scene_ctf(int per, int near)
{
	char name[32];
	tally t;
	int g, caps = 0, games = 0, first_sum = 0, pickups = 0, drops = 0, kills = 0, stuck = 0;
	double think = 0.0, worst = 0.0;
	long thinks = 0;

	memset(&t, 0, sizeof t);
	snprintf(name, sizeof name, near ? "ctf%dnear" : "ctf%d", per);
	for (g = 0; g < 4; g++) {
		bs_sim *s = bs_new(G, per * 2);
		int i, k, first = -1;

		s->have_tents = 1;
		s->tent[0].x = 180.5f; s->tent[0].y = 256.5f; s->tent[0].z = EYE;
		s->tent[1].x = 330.5f; s->tent[1].y = 256.5f; s->tent[1].z = EYE;
		for (i = 0; i < 11 * 13; i++) {
			int gx = i % 11, gy = i / 11, h = (gx * 7 + gy * 13 + gx * gy) % 5;
			int x = 192 + gx * 13 + h, y = 176 + gy * 13 + (h * 3) % 5;

			if ((gx + gy) % 2) bs_box(s, x, y, G - 4, x, y + 7, G - 1, 1);
			else bs_box(s, x, y, G - 4, x + 7, y, G - 1, 1);
		}
		if (near) bs_ctf(s, 172, 262, 178, 268, 332, 244, 338, 250);
		else bs_ctf(s, 185, 236, 215, 276, 295, 236, 325, 276);
		bs_start(s);
		s->respawn = 6.0;
		teams(s, per, 182.5f, 328.5f, 3131u + (uint32_t)g * 977u, "ctf");
		for (k = 0; k < 60 * 300; k++) {
			bs_step(s);
			watch(s, &t);
			if (first < 0 && s->caps[1] + s->caps[2] > 0) first = k;
		}
		caps += s->caps[1] + s->caps[2];
		if (first >= 0) { games++; first_sum += first / 60; }
		pickups += s->pickups[1] + s->pickups[2];
		drops += s->drops;
		kills += s->kills[1] + s->kills[2];
		for (i = 0; i < BL_MAX_PLAYERS; i++)
			if (s->p[i].used) stuck += s->p[i].stuck_events;
		think += s->think_us;
		thinks += s->thinks;
		if (s->think_max_us > worst) worst = s->think_max_us;
		bs_free(s);
	}
	out(name, "captures_in_4_games", caps, "");
	out(name, "games_with_a_capture", games, "of 4");
	out(name, "first_capture_mean_s", games ? (double)first_sum / (double)games : -1.0, "s");
	out(name, "pickups", pickups, "");
	out(name, "drops", drops, "");
	out(name, "kills", kills, "");
	out(name, "stuck", stuck, "");
	out(name, "think_mean_us", think / (double)(thinks ? thinks : 1), "us");
	out(name, "think_worst_us", worst, "us");
	if (t.alive) {
		out(name, "no_key_pct", 100.0 * (double)t.idle / (double)t.alive, "%");
		out(name, "waiting_pct", 100.0 * (double)t.waiting / (double)t.alive, "%");
	}
	if (t.travel) {
		out(name, "head_on_heading_pct", 100.0 * (double)t.on_heading / (double)t.travel, "%");
		out(name, "head_away_spells", t.away_spells, "");
	}
}

static void scene_map(const char *path, double secs)
{
	static unsigned char buf[40 << 20];
	const char *base = strrchr(path, '/');
	char name[64];
	bs_sim *s;
	FILE *f = fopen(path, "rb");
	size_t n;
	tally t;
	bc_nav_node a, b;
	int i, k;

	if (!f) { fprintf(stderr, "bench: cannot read %s\n", path); return; }
	n = fread(buf, 1, sizeof buf, f);
	fclose(f);
	memset(&t, 0, sizeof t);
	snprintf(name, sizeof name, "map:%s", base ? base + 1 : path);
	if (strchr(name, '.')) *strchr(name, '.') = 0;
	s = bs_new(G, 40);
	if (!bc_map_load_vxl(s->truth, buf, n) || !bc_engine_map(s->e, buf, n, 1) ||
	    !bc_nav_snap_dry(s->truth, 128, 256, 40, 120, &a) || !bc_nav_snap_dry(s->truth, 384, 256, 40, 120, &b)) {
		fprintf(stderr, "bench: %s is not a usable map\n", path);
		bs_free(s);
		return;
	}
	s->have_tents = 1;
	s->tent[0].x = (float)a.x + 0.5f; s->tent[0].y = (float)a.y + 0.5f; s->tent[0].z = (float)a.z - 2.25f;
	s->tent[1].x = (float)b.x + 0.5f; s->tent[1].y = (float)b.y + 0.5f; s->tent[1].z = (float)b.z - 2.25f;
	s->respawn = 5.0;
	for (i = 0; i < 20; i++) {
		int tm;

		for (tm = 0; tm < 2; tm++) {
			const bc_nav_node *c = tm ? &b : &a;
			bc_nav_node p;
			int pid = tm * 100 + i;

			/* round its base, in the water or out of it as the map has it */
			if (!bc_nav_snap(s->truth, c->x + (i % 5) * 4 - 8, c->y + (i / 5) * 4 - 8, c->z, 6, &p)) p = *c;
			bs_add(s, pid, 1, tm + 1, 3 + (i * (tm ? 5 : 3)) % 7, (i + tm) % 3, 31u + (uint32_t)pid * 7919u, (float)p.x + 0.5f,
			       (float)p.y + 0.5f, tm ? -1.0f : 1.0f, 0);
			bc_body_place(&s->p[pid].body, s->truth, (float)p.x + 0.5f, (float)p.y + 0.5f, p.z, 0);
		}
	}
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	for (k = 0; k < (int)(secs * 60.0); k++) { bs_step(s); watch(s, &t); }
	report(name, s, &t);
	bs_free(s);
}

int main(int argc, char **argv)
{
	static const char *const all[] = { "arena12", "arena32", "arena40", "fight6", "fight20", "sea40", "ctf:10" };
	int i, n = argc > 1 ? argc - 1 : (int)(sizeof all / sizeof all[0]);

	for (i = 0; i < n; i++) {
		const char *sc = argc > 1 ? argv[i + 1] : all[i];

		if (!strncmp(sc, "arena", 5)) scene_arena(atoi(sc + 5) / 2 > 0 ? atoi(sc + 5) / 2 : 6);
		else if (!strncmp(sc, "fight", 5)) scene_fight(atoi(sc + 5) > 0 ? atoi(sc + 5) : 6);
		else if (!strcmp(sc, "sea40")) scene_sea();
		else if (!strncmp(sc, "ctfnear:", 8)) scene_ctf(atoi(sc + 8) > 0 ? atoi(sc + 8) : 10, 1);
		else if (!strncmp(sc, "ctf:", 4)) scene_ctf(atoi(sc + 4) > 0 ? atoi(sc + 4) : 10, 0);
		else if (!strncmp(sc, "map:", 4)) {
			double secs = 120.0;

			if (i + 1 < n && argc > 1 && atof(argv[i + 2]) > 0.0) secs = atof(argv[++i + 1]);
			scene_map(sc + 4, secs);
		} else {
			fprintf(stderr, "bench: no scene called %s (arena<N>, fight<N>, sea40, ctf:<N>, ctfnear:<N>, map:<file> [secs])\n", sc);
			return 2;
		}
		fflush(stdout);
	}
	return 0;
}
