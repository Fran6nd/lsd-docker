/* brain_sim.h -- a server to test the brain against, with no server
 *
 * nav_sim.h's idea, grown to a whole game: players with bodies moved by
 * body.h from the bots' intents, the map the "server" has, and the rest
 * of what lib_botlink.lua does with an intent and an action:
 *   - a held trigger with the gun fires lib_bot's hit test (a ray along
 *     the facing with the gun's spread, a body 0.45 round from 1.35 above
 *     the eye to 2.25 below, a wall in the way stops it), at the gun's
 *     interval, a round off the magazine; with the spade it swings (reach
 *     3) and digs what the swing meets when it meets no man
 *   - BL_AC_BLOCK / LINE with its checks (tool, reach 5, rates, pouch, a
 *     neighbour to build on), GRENADE, PING (echoed, one a second),
 *     COMMAND (recorded; `on_command` may answer)
 *   - events as the server pushes them: BLOCK and LINE, SOUND for shots,
 *     digs, builds and blasts, HURT with where from, KILL, GRENADE, PING
 *   - the world written every `world_every` ticks (2: the 30 a second of
 *     botlink_world_hz), the engine thought every tick
 *
 *   - with `ctf` set, lsd/scripts/ctf.lua's rules for the two intels: an
 *     intel on the ground goes to the first living player of the OTHER
 *     team within 3 across of it (eye 4 above to 1 below), unless a drop
 *     was under 2 s ago; a carrier within the same cylinder of his OWN
 *     tent captures (his team scores, the intel goes back to a random
 *     place in its zone); a carrier who dies drops it on the floor where
 *     he stood. Nobody can touch his own team's intel.
 *
 * NOT the server: no recoil climb (bots here shoot a little straighter
 * than on LSd), a spade hit is a flat 50, a grenade is flown by the
 * engine's own bc_grenade_fly, and nobody respawns unless asked.
 */
#ifndef BRAIN_SIM_H
#define BRAIN_SIM_H

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "brain.h"
#include "lsd_core.h"
#include "vocab.h"

enum { BS_EV_BYTES = 1 << 16, BS_AC_MAX = 256, BS_NADES = 16 };

typedef struct bs_player {
	int used, bot, team, gun, level, alive, hp, mag, reserve, blocks, grenades, tool, lamp;
	uint32_t life, seed;
	bc_body body;
	bl_vec3 ori, spawn;
	double fire_at, swing_at, reload_at, respawn_at, block_at, ping_at;
	int firing, kills, deaths, shots, hits;
	uint8_t script_keys;        /* a player with no bot behind it */
	int script_fire;
	/* how long it has held one cell with movement keys down */
	int cx, cy, cz;
	double hold, worst_hold;
	int stuck_events;
	char last_cmd[96];
	int cmds;
	char last_tell[96];         /* `do tell ...`, as the server would be handed it */
	int tells;
} bs_player;

typedef struct bs_action { uint8_t type, pid; uint32_t bytes; uint8_t data[96]; } bs_action;

typedef struct bs_nade { int live, by, team; bl_vec3 burst; double at; } bs_nade;

typedef struct bs_sim {
	bc_engine *e;
	bc_map *truth;
	bc_cull *cull;
	bl_world w;
	bl_intent intents[BL_MAX_PLAYERS];
	bs_player p[BL_MAX_PLAYERS];
	bc_rng rng;                 /* the server's dice (spread) */
	uint32_t tick;
	double time;
	int night, world_every, budget;
	double respawn;             /* seconds; < 0: the dead stay dead */
	double water_dps;           /* health a second a wading body loses */
	double wet[BL_MAX_PLAYERS];
	int drowned;
	int have_tents;
	bl_vec3 tent[2];
	/* lsd/scripts/ctf.lua */
	int ctf, intel_holder[2], caps[3], pickups[3], drops;
	bl_vec3 intel[2];           /* [team - 1]: that team's own, where it lies */
	int intel_zone[2][4];       /* x0 y0 x1 y1: where it is put back */
	double drop_timeout;
	/* a box where the server refuses digs, and says nothing */
	int prot, px0, py0, px1, py1;

	uint8_t ev[BS_EV_BYTES];
	size_t ev_len;
	bs_action ac[BS_AC_MAX];
	int ac_n;
	bs_nade nade[BS_NADES];

	int pings, ping_by[BL_MAX_PLAYERS], refused, edits, lines, kills[3], nades_thrown;
	char last_ping[64];
	char log2[400];             /* the last level-2 line */
	int log2_n, log1_n;
	void (*on_command)(struct bs_sim *s, int pid, const char *text);

	/* think cost */
	double think_us, think_max_us;
	long thinks;
	uint32_t exp_max;

	/* recording, for the replay test */
	int rec_on, rec_n, rec_cap;
	bl_world *rec_w;
	uint8_t *rec_ev;
	size_t rec_ev_len, rec_ev_cap;
	size_t *rec_ev_end;
	bl_intent *rec_out;         /* rec_cap x rec_pids */
	int rec_pids;
} bs_sim;

static inline double bs_now_us(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1e6 + (double)ts.tv_nsec * 1e-3;
}

/* --- the host's two callbacks ------------------------------------------ */

static inline void bs_log(void *ctx, int level, const char *line)
{
	bs_sim *s = ctx;

	if (level == 2) {
		snprintf(s->log2, sizeof s->log2, "%s", line);
		s->log2_n++;
	} else if (level == 1) {
		s->log1_n++;
	}
	if (getenv("BS_VERBOSE") && (level > 0 || atoi(getenv("BS_VERBOSE")) > 1))
		printf("    [%d] %s\n", level, line);
}

static inline void bs_action_cb(void *ctx, uint8_t type, uint8_t pid, const void *payload, uint32_t bytes)
{
	bs_sim *s = ctx;
	bs_action *a;

	if (s->ac_n >= BS_AC_MAX)
		return;
	a = &s->ac[s->ac_n++];
	a->type = type;
	a->pid = pid;
	a->bytes = bytes > sizeof a->data ? (uint32_t)sizeof a->data : bytes;
	memset(a->data, 0, sizeof a->data);
	if (payload)
		memcpy(a->data, payload, a->bytes);
}

/* --- events ------------------------------------------------------------- */

static inline void bs_push(bs_sim *s, int type, int pid, const void *payload, size_t bytes)
{
	bl_record r;

	if (s->ev_len + sizeof r + bytes > BS_EV_BYTES)
		return;
	r.size = (uint16_t)(sizeof r + bytes);
	r.type = (uint8_t)type;
	r.pid = (uint8_t)pid;
	memcpy(s->ev + s->ev_len, &r, sizeof r);
	if (bytes)
		memcpy(s->ev + s->ev_len + sizeof r, payload, bytes);
	s->ev_len += sizeof r + ((bytes + 3) & ~(size_t)3);
}

static inline void bs_sound(bs_sim *s, int pid, bl_vec3 pos, int kind)
{
	bl_ev_sound e;

	memset(&e, 0, sizeof e);
	e.pos = pos;
	e.kind = (uint8_t)kind;
	bs_push(s, BL_EV_SOUND, pid, &e, sizeof e);
}

static inline void bs_set(bs_sim *s, int pid, const char *text)
{
	bs_push(s, BL_EV_SET, pid, text, strlen(text) + 1);
}

static inline void bs_order(bs_sim *s, int pid, int order, float x, float y, float z, int target, float secs)
{
	bl_ev_order e;

	memset(&e, 0, sizeof e);
	e.pos.x = x; e.pos.y = y; e.pos.z = z;
	e.order = (uint8_t)order;
	e.target = (uint8_t)target;
	e.secs = secs;
	bs_push(s, BL_EV_ORDER, pid, &e, sizeof e);
}

static inline void bs_ping(bs_sim *s, int by, float x, float y, float z, const char *reason)
{
	bl_ev_ping e;

	memset(&e, 0, sizeof e);
	e.pos.x = x; e.pos.y = y; e.pos.z = z;
	snprintf(e.reason, sizeof e.reason, "%s", reason);
	bs_push(s, BL_EV_PING, by, &e, sizeof e);
}

/* a block action on the server's map, announced */
static inline void bs_block(bs_sim *s, int by, int x, int y, int z, int action)
{
	bl_ev_block e;
	bl_vec3 at;

	bc_map_apply(s->truth, s->cull, action, x, y, z, NULL);
	memset(&e, 0, sizeof e);
	e.x = (int16_t)x; e.y = (int16_t)y; e.z = (int16_t)z;
	e.action = (uint8_t)action;
	e.by = (uint8_t)by;
	bs_push(s, BL_EV_BLOCK, by, &e, sizeof e);
	at.x = (float)x + 0.5f; at.y = (float)y + 0.5f; at.z = (float)z + 0.5f;
	if (by != BL_NO_PLAYER || action == BL_B_GRENADE)
		bs_sound(s, by, at, action == BL_B_BUILD ? BL_S_BUILD : action == BL_B_GRENADE ? BL_S_BLAST : BL_S_DIG);
}

/* --- making a game ------------------------------------------------------ */

static inline size_t bs_write_vxl(const bc_map *src, unsigned char *out)
{
	size_t n = 0;
	long xy;

	for (xy = 0; xy < BC_MAP_XY; xy++) {
		uint64_t c = src->col[xy];
		int z = 0, air_start = 0;

		for (;;) {
			int a, b, k;

			while (z < 64 && !((c >> z) & 1)) z++;
			a = z;
			while (z < 64 && ((c >> z) & 1)) z++;
			b = z - 1;
			if (b == 63) {
				out[n++] = 0; out[n++] = (unsigned char)a; out[n++] = (unsigned char)a;
				out[n++] = (unsigned char)air_start;
				out[n++] = 1; out[n++] = 2; out[n++] = 3; out[n++] = 0x7f;
				break;
			}
			out[n++] = (unsigned char)(1 + (b - a + 1));
			out[n++] = (unsigned char)a; out[n++] = (unsigned char)b;
			out[n++] = (unsigned char)air_start;
			for (k = a; k <= b; k++) {
				out[n++] = 1; out[n++] = 2; out[n++] = 3; out[n++] = 0x7f;
			}
			air_start = b + 1;
		}
	}
	return n;
}

static inline char *bs_slurp(const char *path)
{
	FILE *f = fopen(path, "rb");
	char *buf;
	long n;

	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	fseek(f, 0, SEEK_SET);
	buf = malloc((size_t)n + 2);
	if (fread(buf, 1, (size_t)n, f) != (size_t)n) n = 0;
	buf[n] = '\n';
	buf[n + 1] = 0;
	fclose(f);
	return buf;
}

/* trees/default.bt and trees/tdm.bt as one text (BC_TREES names the
 * directory; else ./trees, then ../trees) */
static inline char *bs_trees(void)
{
	const char *dirs[3];
	char path[512];
	int d;

	dirs[0] = getenv("BC_TREES"); dirs[1] = "trees"; dirs[2] = "../trees";
	for (d = 0; d < 3; d++) {
		char *a, *b, *all;

		if (!dirs[d]) continue;
		snprintf(path, sizeof path, "%s/default.bt", dirs[d]);
		a = bs_slurp(path);
		snprintf(path, sizeof path, "%s/tdm.bt", dirs[d]);
		b = bs_slurp(path);
		if (a && b) {
			char *c;

			snprintf(path, sizeof path, "%s/ctf.bt", dirs[d]);
			c = bs_slurp(path);
			all = malloc(strlen(a) + strlen(b) + (c ? strlen(c) : 0) + 1);
			strcpy(all, a);
			strcat(all, b);
			if (c) strcat(all, c);
			free(a); free(b); free(c);
			return all;
		}
		free(a); free(b);
	}
	return NULL;
}

/* A flat world with its ground at `ground_z`, an engine, the trees. The
 * map is the test's to shape until bs_start. */
static inline bs_sim *bs_new(int ground_z, int max_bots)
{
	bs_sim *s = calloc(1, sizeof *s);
	bc_engine_host host;
	char err[200];
	char *trees;

	s->truth = malloc(sizeof *s->truth);
	s->cull = malloc(sizeof *s->cull);
	bc_map_fill_flat(s->truth, ground_z);
	bc_cull_init(s->cull);
	bc_rng_seed(&s->rng, 99, 7);
	s->world_every = 2;
	s->budget = 3000;
	s->respawn = -1.0;
	host.ctx = s;
	host.log = bs_log;
	host.action = bs_action_cb;
	s->e = bc_engine_new(&host, max_bots);
	trees = bs_trees();
	if (!trees || !bc_engine_trees(s->e, trees, err, sizeof err))
		printf("    trees: %s\n", trees ? err : "not found (run from bot/, or set BC_TREES)");
	free(trees);
	return s;
}

static inline void bs_free(bs_sim *s)
{
	bc_engine_free(s->e);
	free(s->truth);
	free(s->cull);
	free(s->rec_w); free(s->rec_ev); free(s->rec_ev_end); free(s->rec_out);
	free(s);
}

/* The map is as the test wants it: hand it to the engine. */
static inline void bs_start(bs_sim *s)
{
	unsigned char *buf = malloc((size_t)BC_MAP_XY * 40);
	size_t n = bs_write_vxl(s->truth, buf);

	if (!bc_engine_map(s->e, buf, n, 1))
		printf("    the engine refused the map\n");
	free(buf);
}

static inline void bs_spawn(bs_sim *s, int pid)
{
	static const int mags[3] = { 10, 30, 6 }, res[3] = { 50, 120, 48 };
	bs_player *p = &s->p[pid];
	int fz = bc_map_floor_at_or_below(s->truth, (int)p->spawn.x, (int)p->spawn.y, 0);

	bc_body_place(&p->body, s->truth, p->spawn.x, p->spawn.y, fz, 0);
	p->alive = 1;
	p->hp = 100;
	p->mag = mags[p->gun];
	p->reserve = res[p->gun];
	p->blocks = 50;
	p->grenades = 3;
	p->tool = BL_TOOL_GUN;
	p->life++;
	p->reload_at = 0.0;
	p->firing = 0;
	p->hold = 0.0;
	if (p->ori.x == 0.0f && p->ori.y == 0.0f) p->ori.x = 1.0f;
}

static inline void bs_add(bs_sim *s, int pid, int bot, int team, int level, int gun, uint32_t seed,
                   float x, float y, float face_x, float face_y)
{
	bs_player *p = &s->p[pid];

	memset(p, 0, sizeof *p);
	p->used = 1;
	p->bot = bot;
	p->team = team;
	p->level = level;
	p->gun = gun;
	p->seed = seed;
	p->spawn.x = x; p->spawn.y = y;
	p->ori.x = face_x; p->ori.y = face_y;
	p->ping_at = -1e9;
	bs_spawn(s, pid);
	if (bot) {
		bl_ev_bot e;

		memset(&e, 0, sizeof e);
		e.level = (uint8_t)level;
		e.gun = (uint8_t)gun;
		e.seed = seed;
		bs_push(s, BL_EV_BOT, pid, &e, sizeof e);
	}
}

/* --- what the server does with a trigger -------------------------------- */

static inline void bs_hurt(bs_sim *s, int pid, int dmg, int by, bl_vec3 from, int kind)
{
	bs_player *p = &s->p[pid];
	bl_ev_hurt h;

	if (!p->alive) return;
	p->hp -= dmg;
	memset(&h, 0, sizeof h);
	h.from = from;
	h.by = (uint8_t)by;
	h.hp = (uint8_t)(p->hp < 0 ? 0 : p->hp);
	bs_push(s, BL_EV_HURT, pid, &h, sizeof h);
	if (p->hp <= 0) {
		bl_ev_kill k;
		int t;

		/* ctf.lua after_player_destroy: try_drop */
		for (t = 0; t < 2; t++)
			if (s->ctf && s->intel_holder[t] == pid) {
				s->intel_holder[t] = -1;
				s->intel[t].x = floorf(p->body.pos.x) + 0.5f;
				s->intel[t].y = floorf(p->body.pos.y) + 0.5f;
				s->intel[t].z = (float)bc_map_floor_at_or_below(s->truth, (int)p->body.pos.x, (int)p->body.pos.y,
				                                                (int)ceilf(p->body.pos.z));
				s->drop_timeout = s->time + 2.0;
				s->drops++;
			}

		memset(&k, 0, sizeof k);
		k.killer = (uint8_t)by;
		k.kind = (uint8_t)kind;
		p->alive = 0;
		p->deaths++;
		p->respawn_at = s->time + s->respawn;
		if (by != BL_NO_PLAYER && by != pid) {
			s->p[by].kills++;
			s->kills[s->p[by].team]++;
		}
		bs_push(s, BL_EV_KILL, pid, &k, sizeof k);
	}
}

/* lib_bot ray_hits_player: 0 none, 1 head, 2 torso, 3 limb */
static inline int bs_ray_hits(bs_sim *s, bl_vec3 start, bl_vec3 dir, int tgt, float range)
{
	const bs_player *t = &s->p[tgt];
	bl_vec3 p, c;
	float wx, wy, wz, tt, hd, zrel;

	p.x = t->body.pos.x; p.y = t->body.pos.y; p.z = t->body.pos.z;
	wx = p.x - start.x; wy = p.y - start.y; wz = p.z - start.z;
	tt = wx * dir.x + wy * dir.y + wz * dir.z;
	if (tt <= 0.0f || tt > range) return 0;
	c.x = start.x + dir.x * tt; c.y = start.y + dir.y * tt; c.z = start.z + dir.z * tt;
	hd = sqrtf((c.x - p.x) * (c.x - p.x) + (c.y - p.y) * (c.y - p.y));
	if (hd > 0.45f) return 0;
	zrel = c.z - p.z;
	if (zrel < -1.35f || zrel > 2.25f) return 0;
	if (!bc_sight_clear(s->truth, start, c)) return 0;
	return zrel <= -0.7f ? 1 : zrel >= 1.2f ? 3 : 2;
}

static inline void bs_shoot(bs_sim *s, int pid)
{
	static const float fire[3] = { 0.5f, 0.1f, 1.0f }, spread[3] = { 0.006f, 0.012f, 0.024f };
	static const int pellets[3] = { 1, 1, 8 };
	static const int dmg[3][4] = { { 0, 100, 49, 33 }, { 0, 75, 29, 18 }, { 0, 37, 27, 16 } };
	bs_player *p = &s->p[pid];
	bl_vec3 start;
	float sp;
	int k, i;

	if (s->time - p->fire_at < (double)fire[p->gun] - 1e-9) return;
	p->fire_at = s->time;
	p->mag--;
	p->shots++;
	start.x = p->body.pos.x; start.y = p->body.pos.y; start.z = p->body.pos.z;
	sp = spread[p->gun] * (bc_body_speed(&p->body) > 0.64f ? 2.0f : 1.0f);
	for (k = 0; k < pellets[p->gun]; k++) {
		bl_vec3 d = p->ori;
		float l, bestd = 1e30f;
		int best = -1, part = 0;

		d.x += bc_rng_range(&s->rng, -1.0f, 1.0f) * sp;
		d.y += bc_rng_range(&s->rng, -1.0f, 1.0f) * sp;
		d.z += bc_rng_range(&s->rng, -1.0f, 1.0f) * sp;
		l = sqrtf(d.x * d.x + d.y * d.y + d.z * d.z);
		d.x /= l; d.y /= l; d.z /= l;
		for (i = 0; i < BL_MAX_PLAYERS; i++) {
			const bs_player *t = &s->p[i];
			int h;

			if (i == pid || !t->used || !t->alive || t->team == p->team) continue;
			h = bs_ray_hits(s, start, d, i, 128.0f);
			if (h) {
				float dx = t->body.pos.x - start.x, dy = t->body.pos.y - start.y, dz = t->body.pos.z - start.z;
				float dd = dx * dx + dy * dy + dz * dz;

				if (dd < bestd) { bestd = dd; best = i; part = h; }
			}
		}
		if (best >= 0) {
			p->hits++;
			bs_hurt(s, best, dmg[p->gun][part], pid, start, part == 1);
		}
	}
	bs_sound(s, pid, start, BL_S_SHOT);
}

static inline void bs_swing(bs_sim *s, int pid)
{
	bs_player *p = &s->p[pid];
	bl_vec3 start;
	int i, best = -1;
	float bestd = 1e30f;

	if (s->time - p->swing_at < 0.25 - 1e-9) return;
	p->swing_at = s->time;
	start.x = p->body.pos.x; start.y = p->body.pos.y; start.z = p->body.pos.z;
	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		const bs_player *t = &s->p[i];

		if (i == pid || !t->used || !t->alive || t->team == p->team) continue;
		if (bs_ray_hits(s, start, p->ori, i, 3.0f)) {
			float dx = t->body.pos.x - start.x, dy = t->body.pos.y - start.y;

			if (dx * dx + dy * dy < bestd) { bestd = dx * dx + dy * dy; best = i; }
		}
	}
	if (best >= 0) {
		bs_hurt(s, best, 50, pid, start, 2);    /* silent: no sound event */
	} else {
		float a[3], b[3];
		int hit[3];

		a[0] = start.x; a[1] = start.y; a[2] = start.z;
		b[0] = start.x + p->ori.x * 3.5f; b[1] = start.y + p->ori.y * 3.5f; b[2] = start.z + p->ori.z * 3.5f;
		if (bc_lsd_cast_ray(s->truth, a, b, hit) && hit[2] < 62 && bc_map_in(hit[0], hit[1], hit[2])) {
			bs_block(s, pid, hit[0], hit[1], hit[2], BL_B_DESTROY);
			if (p->blocks < 50) p->blocks++;
		}
	}
}

static inline void bs_apply_intent(bs_sim *s, int pid)
{
	static const int mags[3] = { 10, 30, 6 };
	bs_player *p = &s->p[pid];
	const bl_intent *it = &s->intents[pid];
	float l2;

	p->firing = 0;
	if (!(it->flags & BL_I_VALID) || it->life != p->life) {
		p->script_keys = 0;
		return;
	}
	p->script_keys = it->keys;
	l2 = it->ori.x * it->ori.x + it->ori.y * it->ori.y + it->ori.z * it->ori.z;
	if (l2 > 0.25f && l2 < 4.0f) p->ori = it->ori;
	if (it->tool <= 3 && it->tool != p->tool) {
		p->tool = it->tool;
		p->reload_at = 0.0;         /* a tool change cancels a reload */
	}
	p->lamp = (it->flags & BL_I_LAMP) != 0;
	if ((it->flags & BL_I_RELOAD) && p->tool == BL_TOOL_GUN && p->reload_at == 0.0 &&
	    p->reserve > 0 && p->mag < mags[p->gun])
		p->reload_at = s->time + 2.5;
	if (it->mouse & BL_M_PRIMARY) {
		p->firing = 1;
		if (p->tool == BL_TOOL_GUN) {
			if (p->reload_at == 0.0 && p->mag > 0) bs_shoot(s, pid);
		} else if (p->tool == BL_TOOL_SPADE) {
			bs_swing(s, pid);
		}
	}
}

/* --- actions ------------------------------------------------------------ */

static inline int bs_neigh(const bc_map *m, int x, int y, int z)
{
	return bc_map_solid(m, x - 1, y, z) || bc_map_solid(m, x + 1, y, z) || bc_map_solid(m, x, y - 1, z) ||
	       bc_map_solid(m, x, y + 1, z) || (z > 0 && bc_map_solid(m, x, y, z - 1)) || bc_map_solid(m, x, y, z + 1);
}

static inline int bs_reach(const bs_player *p, int x, int y, int z)
{
	float dx = p->body.pos.x - ((float)x + 0.5f), dy = p->body.pos.y - ((float)y + 0.5f),
	      dz = p->body.pos.z - ((float)z + 0.5f);

	return dx * dx + dy * dy + dz * dz <= 25.0f;
}

static inline int bs_in(int x, int y, int z) { return x >= 0 && x < 512 && y >= 0 && y < 512 && z >= 0 && z < 62; }

static inline int bs_do_action(bs_sim *s, const bs_action *a)
{
	bs_player *p = &s->p[a->pid];

	if (!p->used || !p->bot || !p->alive) return 0;
	switch (a->type) {
	case BL_AC_BLOCK: {
		bl_ac_block b;

		memcpy(&b, a->data, sizeof b);
		if (!bs_in(b.x, b.y, b.z) || b.action > 2 || s->time < p->block_at || !bs_reach(p, b.x, b.y, b.z))
			return 0;
		if (b.action == BL_B_BUILD) {
			if (p->tool != BL_TOOL_BLOCK || p->blocks <= 0 || bc_map_solid(s->truth, b.x, b.y, b.z) ||
			    !bs_neigh(s->truth, b.x, b.y, b.z))
				return 0;
			p->block_at = s->time + 0.1;
			p->blocks--;
		} else {
			if (p->tool != BL_TOOL_SPADE || !bc_map_solid(s->truth, b.x, b.y, b.z)) return 0;
			if (s->prot && b.x >= s->px0 && b.x <= s->px1 && b.y >= s->py0 && b.y <= s->py1) return 0;
			p->block_at = s->time + (b.action == BL_B_DESTROY ? 0.25 : 1.0);
			if (b.action == BL_B_DESTROY && p->blocks < 50) p->blocks++;
		}
		bs_block(s, a->pid, b.x, b.y, b.z, b.action);
		s->edits++;
		return 1;
	}
	case BL_AC_LINE: {
		bl_ac_line l;
		bl_ev_line e;
		bl_vec3 at;
		int n;

		memcpy(&l, a->data, sizeof l);
		if (!bs_in(l.x1, l.y1, l.z1) || !bs_in(l.x2, l.y2, l.z2) || s->time < p->block_at ||
		    p->tool != BL_TOOL_BLOCK)
			return 0;
		n = 1 + abs(l.x2 - l.x1) + abs(l.y2 - l.y1) + abs(l.z2 - l.z1);
		if (n > p->blocks || !bs_reach(p, l.x1, l.y1, l.z1) || !bs_neigh(s->truth, l.x1, l.y1, l.z1) ||
		    bc_map_solid(s->truth, l.x2, l.y2, l.z2) || !bs_neigh(s->truth, l.x2, l.y2, l.z2))
			return 0;
		p->block_at = s->time + 0.5;
		p->blocks -= n;
		bc_map_line(s->truth, l.x1, l.y1, l.z1, l.x2, l.y2, l.z2, NULL);
		memset(&e, 0, sizeof e);
		e.x1 = l.x1; e.y1 = l.y1; e.z1 = l.z1; e.x2 = l.x2; e.y2 = l.y2; e.z2 = l.z2;
		e.by = a->pid;
		bs_push(s, BL_EV_LINE, a->pid, &e, sizeof e);
		at.x = (float)l.x2 + 0.5f; at.y = (float)l.y2 + 0.5f; at.z = (float)l.z2 + 0.5f;
		bs_sound(s, a->pid, at, BL_S_BUILD);
		s->edits++;
		s->lines++;
		return 1;
	}
	case BL_AC_GRENADE: {
		bl_ac_grenade g;
		bl_ev_grenade e;
		int i;

		memcpy(&g, a->data, sizeof g);
		if (p->grenades <= 0 || !(g.fuse >= 0.0f && g.fuse <= 3.0f)) return 0;
		p->grenades--;
		s->nades_thrown++;
		memset(&e, 0, sizeof e);
		e.pos.x = p->body.pos.x; e.pos.y = p->body.pos.y; e.pos.z = p->body.pos.z;
		e.vel = g.vel;
		e.fuse = g.fuse;
		bs_push(s, BL_EV_GRENADE, a->pid, &e, sizeof e);
		for (i = 0; i < BS_NADES; i++)
			if (!s->nade[i].live) {
				s->nade[i].live = 1;
				s->nade[i].by = a->pid;
				s->nade[i].team = p->team;
				s->nade[i].burst = bc_grenade_fly(s->truth, e.pos, g.vel, g.fuse);
				s->nade[i].at = s->time + (double)g.fuse;
				break;
			}
		return 1;
	}
	case BL_AC_PING: {
		bl_ac_ping g;

		memcpy(&g, a->data, sizeof g);
		if (s->time - p->ping_at < 1.0) return 0;
		p->ping_at = s->time;
		s->pings++;
		s->ping_by[a->pid]++;
		memcpy(s->last_ping, g.reason, 64);
		s->last_ping[63] = 0;
		bs_ping(s, a->pid, g.pos.x, g.pos.y, g.pos.z, g.reason);
		return 1;
	}
	case BL_AC_TELL:
		snprintf(p->last_tell, sizeof p->last_tell, "%s", (const char *)a->data);
		p->tells++;
		return 1;
	case BL_AC_COMMAND:
		snprintf(p->last_cmd, sizeof p->last_cmd, "%s", (const char *)a->data);
		p->cmds++;
		if (s->on_command) s->on_command(s, a->pid, (const char *)a->data);
		return 1;
	default:
		return 1;
	}
}

static inline void bs_bursts(bs_sim *s)
{
	int i, k;

	for (i = 0; i < BS_NADES; i++) {
		bs_nade *n = &s->nade[i];

		if (!n->live || s->time < n->at) continue;
		n->live = 0;
		for (k = 0; k < BL_MAX_PLAYERS; k++) {
			bs_player *t = &s->p[k];
			bl_vec3 body;
			float d;

			if (!t->used || !t->alive || (t->team == n->team && k != n->by)) continue;
			body.x = t->body.pos.x; body.y = t->body.pos.y; body.z = t->body.pos.z;
			d = bc_grenade_damage(s->truth, n->burst, body);
			if (d >= 1.0f) bs_hurt(s, k, (int)d, n->by, n->burst, 3);
		}
		bs_block(s, n->by, (int)floorf(n->burst.x), (int)floorf(n->burst.y), (int)floorf(n->burst.z), BL_B_GRENADE);
	}
}

/* --- the world, and a tick ---------------------------------------------- */

static inline void bs_write_world(bs_sim *s)
{
	bl_world *w = &s->w;
	int i;

	memset(w, 0, sizeof *w);
	w->tick = s->tick;
	w->time = s->time;
	w->map_seq = 1;
	w->night = (uint8_t)s->night;
	w->score[0] = (uint16_t)(s->ctf ? s->caps[1] : s->kills[1]);
	w->score[1] = (uint16_t)(s->ctf ? s->caps[2] : s->kills[2]);
	for (i = 0; i < 2; i++) {
		w->intel[i].holder = w->tent[i].holder = BL_NO_PLAYER;
		if (s->ctf) {
			/* lib_botlink fill_object: a held one is where its holder is */
			w->intel[i].present = 1;
			w->intel[i].pos = s->intel[i];
			if (s->intel_holder[i] >= 0) {
				const bc_body *hb = &s->p[s->intel_holder[i]].body;

				w->intel[i].holder = (uint8_t)s->intel_holder[i];
				w->intel[i].pos.x = hb->pos.x; w->intel[i].pos.y = hb->pos.y; w->intel[i].pos.z = hb->pos.z;
			}
		}
		if (s->have_tents) {
			w->tent[i].pos = s->tent[i];
			w->tent[i].present = 1;
		}
	}
	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		const bs_player *p = &s->p[i];
		bl_player *o = &w->players[i];
		uint8_t fl = 0;

		if (!p->used) continue;
		o->team = (uint8_t)p->team;
		o->life = p->life;
		if (p->bot) fl |= BL_F_BOT;
		if (!p->alive) {
			o->state = BL_DEAD;
			o->flags = fl;
			continue;
		}
		o->state = BL_ALIVE;
		o->tool = (uint8_t)p->tool;
		o->gun = (uint8_t)p->gun;
		o->hp = (uint8_t)p->hp;
		o->mag = (uint8_t)p->mag;
		o->reserve = (uint8_t)p->reserve;
		o->blocks = (uint8_t)p->blocks;
		o->grenades = (uint8_t)p->grenades;
		o->keys = p->body.keys;
		if (p->body.keys & BC_K_CROUCH) fl |= BL_F_CROUCH;
		if (p->body.keys & BC_K_SPRINT) fl |= BL_F_SPRINT;
		if (p->body.airborne) fl |= BL_F_AIRBORNE;
		if (p->body.wade) fl |= BL_F_WADING;
		if (p->lamp) fl |= BL_F_LAMP;
		if (p->firing) fl |= BL_F_FIRING;
		o->flags = fl;
		o->pos.x = p->body.pos.x; o->pos.y = p->body.pos.y; o->pos.z = p->body.pos.z;
		o->ori = p->ori;
		o->vel.x = p->body.vel.x; o->vel.y = p->body.vel.y; o->vel.z = p->body.vel.z;
	}
}

static inline void bs_record(bs_sim *s)
{
	int i, k = 0;

	if (!s->rec_on || s->rec_n >= s->rec_cap) return;
	s->rec_w[s->rec_n] = s->w;
	if (s->rec_ev_len + s->ev_len <= s->rec_ev_cap) {
		memcpy(s->rec_ev + s->rec_ev_len, s->ev, s->ev_len);
		s->rec_ev_len += s->ev_len;
	}
	s->rec_ev_end[s->rec_n] = s->rec_ev_len;
	for (i = 0; i < BL_MAX_PLAYERS && k < s->rec_pids; i++)
		if (s->p[i].used && s->p[i].bot)
			s->rec_out[(size_t)s->rec_n * (size_t)s->rec_pids + (size_t)k++] = s->intents[i];
	s->rec_n++;
}

static inline void bs_rec_start(bs_sim *s, int thinks, int pids)
{
	s->rec_on = 1;
	s->rec_cap = thinks;
	s->rec_pids = pids;
	s->rec_w = malloc(sizeof(bl_world) * (size_t)thinks);
	s->rec_ev_cap = (size_t)thinks * 512;
	s->rec_ev = malloc(s->rec_ev_cap);
	s->rec_ev_end = malloc(sizeof(size_t) * (size_t)thinks);
	s->rec_out = calloc((size_t)thinks * (size_t)pids, sizeof(bl_intent));
}

/* lib_ctf within_cylinder: 3 across, the eye 4 above to 1 below */
static inline int bs_in_cylinder(const bc_body *b, bl_vec3 at)
{
	float dx = b->pos.x - at.x, dy = b->pos.y - at.y, dz = b->pos.z - at.z;

	return sqrtf(dx * dx + dy * dy) <= 3.0f && dz >= -4.0f && dz <= 1.0f;
}

static inline void bs_intel_home(bs_sim *s, int t)
{
	const int *z = s->intel_zone[t];
	int x = z[0] + (int)bc_rng_below(&s->rng, (uint32_t)(z[2] - z[0] + 1));
	int y = z[1] + (int)bc_rng_below(&s->rng, (uint32_t)(z[3] - z[1] + 1));

	s->intel_holder[t] = -1;
	s->intel[t].x = (float)x + 0.5f;
	s->intel[t].y = (float)y + 0.5f;
	s->intel[t].z = (float)bc_map_floor_at_or_below(s->truth, x, y, 0);
}

/* A game of ctf: tents as they are, each intel put in its zone. */
static inline void bs_ctf(bs_sim *s, int ax0, int ay0, int ax1, int ay1, int bx0, int by0, int bx1, int by1)
{
	s->ctf = 1;
	s->intel_zone[0][0] = ax0; s->intel_zone[0][1] = ay0; s->intel_zone[0][2] = ax1; s->intel_zone[0][3] = ay1;
	s->intel_zone[1][0] = bx0; s->intel_zone[1][1] = by0; s->intel_zone[1][2] = bx1; s->intel_zone[1][3] = by1;
	bs_intel_home(s, 0);
	bs_intel_home(s, 1);
}

/* ctf.lua after.tick */
static inline void bs_ctf_tick(bs_sim *s)
{
	int t, i;

	for (t = 0; t < 2; t++) {
		int h = s->intel_holder[t];

		if (h >= 0) {
			int team = s->p[h].team;

			if (s->have_tents && bs_in_cylinder(&s->p[h].body, s->tent[team - 1])) {
				s->caps[team]++;
				bs_intel_home(s, t);
			}
		} else if (s->time >= s->drop_timeout) {
			for (i = 0; i < BL_MAX_PLAYERS; i++)
				if (s->p[i].used && s->p[i].alive && s->p[i].team != t + 1 && bs_in_cylinder(&s->p[i].body, s->intel[t])) {
					s->intel_holder[t] = i;
					s->pickups[s->p[i].team]++;
					break;
				}
		}
	}
}

/* Feed queued events to an engine and think once. */
static inline void bs_think(bs_sim *s)
{
	size_t at = 0;
	double t0;
	uint32_t ex;

	while (at < s->ev_len) {
		const bl_record *r = (const bl_record *)(const void *)(s->ev + at);

		bc_engine_event(s->e, r);
		at += (r->size + 3u) & ~3u;
	}
	t0 = bs_now_us();
	{
		/* BS_WATCH=1 in the environment: every bot watched (engine.h), for
		 * measuring what watching costs and that it changes nothing */
		static int watch_all = -1;

		if (watch_all < 0) watch_all = getenv("BS_WATCH") != NULL;
		if (watch_all) {
			int k;

			for (k = 0; k < BL_MAX_PLAYERS; k++) bc_engine_watch(s->e, k, 1);
		}
	}
	bc_engine_think(s->e, &s->w, s->intents, 1.0f / 60.0f, s->budget);
	t0 = bs_now_us() - t0;
	s->think_us += t0;
	if (t0 > s->think_max_us) s->think_max_us = t0;
	s->thinks++;
	ex = bc_engine_stats_get(s->e)->last_expansions;
	if (ex > s->exp_max) s->exp_max = ex;
	if (s->rec_on) {
		/* the events must be recorded before they are dropped */
		bs_record(s);
	}
	s->ev_len = 0;
}

static inline void bs_step(bs_sim *s)
{
	static const int mags[3] = { 10, 30, 6 };
	int i;

	/* before.tick: intents, then actions */
	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		bs_player *p = &s->p[i];

		if (!p->used || !p->alive) continue;
		if (p->bot) bs_apply_intent(s, i);
		else if (p->script_fire && p->tool == BL_TOOL_GUN && p->mag > 0) { p->firing = 1; bs_shoot(s, i); }
		if (p->reload_at != 0.0 && s->time >= p->reload_at) {
			int need = mags[p->gun] - p->mag;

			if (need > p->reserve) need = p->reserve;
			p->mag += need;
			p->reserve -= need;
			p->reload_at = 0.0;
		}
	}
	for (i = 0; i < s->ac_n; i++)
		if (!bs_do_action(s, &s->ac[i])) s->refused++;
	s->ac_n = 0;
	bs_bursts(s);

	/* the tick: physics */
	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		bs_player *p = &s->p[i];
		bc_v3 o;
		int cx, cy, cz;
		int32_t dmg;

		if (!p->used) continue;
		if (!p->alive) {
			if (s->respawn >= 0.0 && s->time >= p->respawn_at) bs_spawn(s, i);
			continue;
		}
		o.x = p->ori.x; o.y = p->ori.y; o.z = p->ori.z;
		dmg = bc_body_step(&p->body, s->truth, p->script_keys, o, BC_BODY_DT);
		if (dmg > 0) {
			bl_vec3 at;

			at.x = p->body.pos.x; at.y = p->body.pos.y; at.z = p->body.pos.z;
			bs_hurt(s, i, dmg, BL_NO_PLAYER, at, 4);
		}
		if (s->water_dps > 0.0 && p->body.wade) {
			/* lib_ctf / tdm water damage: a point at a time */
			s->wet[i] += s->water_dps / 60.0;
			if (s->wet[i] >= 1.0) {
				bl_vec3 at;
				int was = p->alive;

				at.x = p->body.pos.x; at.y = p->body.pos.y; at.z = p->body.pos.z;
				s->wet[i] -= 1.0;
				bs_hurt(s, i, 1, BL_NO_PLAYER, at, 4);
				if (was && !p->alive) s->drowned++;
			}
		}
		cx = (int)floorf(p->body.pos.x); cy = (int)floorf(p->body.pos.y); cz = (int)floorf(p->body.pos.z);
		if (cx == p->cx && cy == p->cy && cz == p->cz && (p->script_keys & 15)) {
			p->hold += 1.0 / 60.0;
			if (p->hold > p->worst_hold) p->worst_hold = p->hold;
			if (p->hold > 3.0 && p->hold - 1.0 / 60.0 <= 3.0) p->stuck_events++;
		} else {
			p->hold = 0.0;
			p->cx = cx; p->cy = cy; p->cz = cz;
		}
	}
	if (s->ctf)
		bs_ctf_tick(s);
	s->tick++;
	s->time += 1.0 / 60.0;
	if (s->tick % (uint32_t)s->world_every == 0 || s->tick == 1)
		bs_write_world(s);
	bs_think(s);
}

static inline void bs_run(bs_sim *s, double secs)
{
	int n = (int)(secs * 60.0 + 0.5);

	while (n-- > 0)
		bs_step(s);
}

/* a wall of solid voxels on the test's map (before bs_start), or after
 * it through the server (announced) */
static inline void bs_box(bs_sim *s, int x0, int y0, int z0, int x1, int y1, int z1, int solid)
{
	int x, y, z;

	for (z = z0; z <= z1; z++)
		for (y = y0; y <= y1; y++)
			for (x = x0; x <= x1; x++)
				bc_map_set(s->truth, x, y, z, solid);
}

static inline float bs_dist(const bs_sim *s, int a, int b)
{
	float dx = s->p[a].body.pos.x - s->p[b].body.pos.x, dy = s->p[a].body.pos.y - s->p[b].body.pos.y;

	return sqrtf(dx * dx + dy * dy);
}

#endif /* BRAIN_SIM_H */
