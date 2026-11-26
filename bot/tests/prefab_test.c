/* prefab_test.c -- structures a leader orders built (bot/structures/ kv6 files,
 * blueprint.h), and the people who lead: on the simulated server of
 * brain_sim.h */
#include "brain_sim.h"

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { G = 40 };

static uint8_t *read_file(const char *path, size_t *n)
{
	FILE *f = fopen(path, "rb");
	uint8_t *buf;
	long len;

	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	len = ftell(f);
	fseek(f, 0, SEEK_SET);
	buf = malloc((size_t)(len > 0 ? len : 1));
	*n = buf ? fread(buf, 1, (size_t)len, f) : 0;
	fclose(f);
	return buf;
}

static int load(bs_sim *s, const char *name)
{
	char path[64], err[128];
	size_t n = 0;
	uint8_t *b;
	int ok;

	snprintf(path, sizeof path, "structures/%s.kv6", name);
	if (!(b = read_file(path, &n))) return 0;
	ok = bc_engine_structure(s->e, name, b, n, err, sizeof err);
	if (!ok) printf("  %s: %s\n", path, err);
	free(b);
	return ok;
}

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

/* A MODEL SET ON THE MAP: every voxel of it, in its colours, the bottom
 * layer on the ground's top, its front turned by the quarter. */
static void test_place(void)
{
	bs_sim *s = bs_new(G, 2);
	const bc_kv6 *m;
	bc_bp_cell *c;
	int q, n[4], low = 99, high = -1, coloured = 0, i;
	int front_y[4] = { 0 };

	printf("a structure set on the map: its voxels, its colours, turned\n");
	bs_start(s);
	CHECK(load(s, "mirador") && load(s, "bunker"));
	m = bc_structure_get(s->e->structures, "bunker");
	CHECK(m != NULL);
	if (!m) { bs_free(s); return; }
	c = malloc((size_t)m->n * sizeof *c);
	for (q = 0; q < 4; q++) {
		int sx = 0, sy = 0;

		n[q] = bc_structure_cells(m, 250, 250, G, q, c, m->n);
		for (i = 0; i < n[q]; i++) {
			if (q == 0) {
				if (c[i].z < low) low = c[i].z;
				if (c[i].z > high) high = c[i].z;
				coloured += (c[i].rgb & BC_BP_RGB) != 0;
			}
			sx += c[i].x - 250; sy += c[i].y - 250;
		}
		/* the door is a gap in the front wall: the voxels lean away from it */
		front_y[q] = abs(sx) > abs(sy) ? (sx > 0 ? -1 : 1) * 10 : (sy > 0 ? -1 : 1);
	}
	printf("  bunker: %d voxels (the model's %d), layers %d to %d over the ground at %d, %d coloured; the door's side by quarter: %d %d %d %d\n",
	       n[0], m->n, low, high, G, coloured, front_y[0], front_y[1], front_y[2], front_y[3]);
	CHECK(n[0] == m->n && n[1] == m->n && n[2] == m->n && n[3] == m->n);
	CHECK(high == G - 1 && low == G - m->zs);
	CHECK(coloured == m->n);
	/* +y, -x, -y, +x: each quarter turns the door a quarter on */
	CHECK(front_y[0] == 1 && front_y[1] == -10 && front_y[2] == -1 && front_y[3] == 10);
	free(c);
	bs_free(s);
}

static uint32_t want_rgb[512 * 64];
static int want_n, wrong_colour;
static const bc_blueprint *watched;

static void on_build(bs_sim *s, int pid, int x, int y, int z, uint32_t color)
{
	int i;

	(void)s; (void)pid;
	for (i = 0; i < want_n; i++)
		if (watched->cells[i].x == x && watched->cells[i].y == y && watched->cells[i].z == z &&
		    (want_rgb[i] & 0xFFFFFFu) != color)
			wrong_colour++;
}

/* A PERSON LEADS. He joins: he is a leader, and the bots close to him
 * fall in. His build ping: his squad builds the mirador there, in its
 * colours, nothing refused for sight, and none of it where his team may
 * not build. A bot that leads nobody pings the same: nothing. */
static void test_person_orders(void)
{
	bs_sim *s = bs_new(G, 8);
	bc_bp_cell cells[512];
	int i, k, with = 0, made = 0, n = 0, in_zone = 0, done_at = -1;
	uint32_t seed = 300;
	char name[16];
	bc_blueprint *bp;

	printf("a person leads: close bots fall in; his build ping is built by them\n");
	s->have_tents = 1;
	s->tent[0].x = 160.5f; s->tent[0].y = 256.5f; s->tent[0].z = (float)G - 2.25f;
	s->tent[1].x = 400.5f; s->tent[1].y = 256.5f; s->tent[1].z = (float)G - 2.25f;
	bs_start(s);
	CHECK(load(s, "mirador"));
	bs_set(s, BL_NO_PLAYER, "edit=all");
	/* a strip his team may not build on, across a corner of the footprint */
	bs_set(s, BL_NO_PLAYER, "zone=246 256 246 270 nobuild team 1");
	bs_add(s, 9, 0, 1, 5, BL_GUN_RIFLE, 1, 236.5f, 258.5f, 1, 0);
	for (i = 0; i < 4; i++) {
		seed = seed_with(BC_T_TEAMWORK, 1.0f, 3.0f, seed + 1);
		bs_add(s, i, 1, 1, 6, BL_GUN_RIFLE, seed, 230.5f, 252.5f + 3.0f * (float)i, 1, 0);
	}
	bs_add(s, 5, 1, 1, 6, BL_GUN_RIFLE, seed_with(BC_T_TEAMWORK, 0.0f, 0.5f, 900), 200.5f, 262.5f, 1, 0);   /* a loner */
	bs_set(s, BL_NO_PLAYER, "tree=tdm");
	bs_run(s, 4.0);
	for (i = 0; i < 4; i++)
		with += bc_engine_bot(s->e, i)->squad.leader == 9;
	printf("  joined: a leader %d; %d of 4 close bots follow him\n", bc_is_leader(s->e, 9), with);
	CHECK(bc_is_leader(s->e, 9));
	CHECK(with >= 3);

	/* the loner, no leader, pings a build: nothing */
	bs_ping(s, 5, 250.5f, 262.5f, (float)G, "Build bunker here");
	bs_run(s, 0.5);
	snprintf(name, sizeof name, "order%d", 5);
	CHECK(bc_blueprint_get(s->e->blueprints, name) == NULL);

	/* he looks east and pings ahead: the mirador, its first step his way */
	s->p[9].ori.x = 1.0f; s->p[9].ori.y = 0.0f; s->p[9].ori.z = 0.0f;
	bs_ping(s, 9, 248.5f, 262.5f, (float)G, "Build mirador here");
	bs_run(s, 0.5);
	bp = bc_blueprint_get(s->e->blueprints, "order9");
	CHECK(bp != NULL);
	if (!bp) { bs_free(s); return; }
	n = bp->n < 512 ? bp->n : 512;
	memcpy(cells, bp->cells, (size_t)n * sizeof cells[0]);
	for (i = 0; i < n; i++) {
		want_rgb[i] = cells[i].rgb;
		in_zone += cells[i].x == 246 && cells[i].y >= 256 && cells[i].y <= 270;
	}
	want_n = n;
	watched = bp;
	s->on_build = on_build;
	for (k = 0; k < 60 * 240 && done_at < 0; k++) {
		for (i = 0; i < 4; i++) s->p[i].blocks = 50;
		bs_step(s);
		if (!bc_blueprint_get(s->e->blueprints, "order9")) done_at = k;
		else watched = bc_blueprint_get(s->e->blueprints, "order9");
	}
	for (i = 0; i < n; i++)
		made += bc_map_solid(s->truth, cells[i].x, cells[i].y, cells[i].z);
	printf("  the mirador: %d voxels ordered (%d in the zone), %d built in %.0f s; wrong colour %d; refused for sight %d\n",
	       n, in_zone, made, (done_at < 0 ? k : done_at) / 60.0, wrong_colour, s->vis_refused);
	CHECK(in_zone == 0);
	CHECK(done_at >= 0 && done_at < 60 * 180);
	CHECK(made >= n * 9 / 10);
	CHECK(wrong_colour == 0);
	CHECK(s->vis_refused == 0);
	{
		int y, z, built_in_zone = 0;

		for (y = 256; y <= 270; y++)
			for (z = 0; z < G; z++)
				built_in_zone += bc_map_solid(s->truth, 246, y, z);
		CHECK(built_in_zone == 0);
	}
	bs_free(s);
}

int main(void)
{
	test_place();
	test_person_orders();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
