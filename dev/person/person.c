/*
 * person.c -- a scripted person: the smallest real Ace of Spades 0.75
 * client that can play on an LSd server, for live end-to-end tests.
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * It goes through the whole network path a human's client does -- ENet,
 * the map download, the version handshake, the extension negotiation, the
 * join -- so whatever the server does for a person it does for this. No
 * Lua shortcuts: it is a client.
 *
 *   person --host 127.0.0.1 --port 32887 --name Tester --team 1
 *          [--weapon 0|1|2] [--at X Y Z] [--look X Y Z]
 *          [--say "text"]... [--say-gap SECONDS] [--stay SECONDS]
 *
 * --at X Y Z   stand on the block at (X, Y, Z): X Y is the spot on the
 *              map, Z the voxel the feet stand on (z grows downward, so
 *              the top of babel's platform is --at 250 255 1). The eye --
 *              the position the server holds, what get_position and a
 *              WorldUpdate report -- is then Z - 2.26.
 * --look X Y Z keep the aim on that point, from the eye.
 * --say TEXT   a chat line (a command if it starts with '/'), sent once
 *              the person is alive, where it was asked to be, and the
 *              server reports the aim it was given; lines go in order,
 *              --say-gap seconds apart (default 1.5).
 * --stay N     disconnect and exit after N seconds (default 30).
 *
 * WHERE IT IS. LSd takes the client's PositionData, as 0.75 does, and
 * checks each one against the last it accepted -- not against time
 * (lsd/src/funcs_packetrecv.c, PositionData): at most ~10.7 blocks
 * across, 11.5 up and 32.5 down per packet, inside the map, and not
 * stuck in a block three times running. A packet that fails is answered
 * with a PositionData putting the client back. And fall_damage.lua
 * charges a body for the height it fell from its highest point when it
 * lands: a way through the air, over the hills, kills it on arrival. So
 * the person WALKS ON THE GROUND, as a player does: it keeps the map the
 * server sends (zlib, then the .vxl columns), finds a way over floors from
 * column to column (breadth first, side by side: up to CLIMB up at a step
 * -- LSd allows 11.5 a packet --, down no more than DROP, which costs
 * nothing at landing), and walks it a column a packet, the middle of each,
 * its feet on that column's floor; the last step to the spot itself.
 * Once there it keeps sending its position and aim POS_HZ times a
 * second, as a real client does; LSd's own physics holds it in between,
 * so the spot should be one a body can stand on.
 *
 * --team is the wire's team: 0 or 1 (255 spectator). LSd's Lua counts
 * from 1, so get_team says 1 or 2.
 *
 * WHAT IT CLAIMS. Player Limit (192, packetless: player ids up to 254),
 * which an LSd seating more than 32 requires of a client before it may
 * leave spectator, and Teamplay (48), without which /pingmark does not
 * exist for it. Nothing else: the server sends an extension's packets
 * only to a client that agreed to it, and anything else that turns up is
 * ignored, once noted.
 *
 * Output, one line per event, for a test to read:
 *   INFO  ...                 connection, handshake, join, arrival
 *   STATE id=N team=T alive=A pos=X,Y,Z ori=X,Y,Z   once a second, the
 *                             server's view of this player (WorldUpdate)
 *   CHAT  type=T from=N: text every chat line received
 *   PING  from=N at X,Y,Z: reason   a Teamplay ping relayed to it
 *   SAID  text                a --say line, as it goes out
 *   WARN  ...                 the server put it back, an odd packet...
 */
#define _POSIX_C_SOURCE 200809L
#include <enet/enet.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>

/* ------------------------------------------------------------------ */
/* Protocol                                                            */

enum {
	PKT_POSITION = 0,
	PKT_ORIENTATION = 1,
	PKT_WORLD_UPDATE = 2,
	PKT_EXISTING_PLAYER = 9,
	PKT_CREATE_PLAYER = 12,
	PKT_STATE_DATA = 15,
	PKT_KILL = 16,
	PKT_CHAT = 17,
	PKT_MAP_START = 18,
	PKT_MAP_CHUNK = 19,
	PKT_PLAYER_LEFT = 20,
	PKT_HANDSHAKE_INIT = 31,
	PKT_HANDSHAKE_RETURN = 32,
	PKT_VERSION_GET = 33,
	PKT_VERSION_RESPONSE = 34,
	PKT_EXT_INFO = 60,
	PKT_TEAMPLAY = 112, /* 64 + extension id 48 */
	BASE_PROTOCOL_END = 31 /* ids below are 0.75's own (0-30) */
};

#define PROTOCOL_075 3   /* ENet connect data for 0.75 */

#define EXT_TEAMPLAY 48
#define EXT_PLAYER_LIMIT 192

/* The extensions this client implements, at the versions it speaks.
 * Versions are matched, not negotiated (lib_ext): one the server offers
 * at another version is not claimed. */
static const struct {
	uint8_t id, version;
	const char *title;
} OURS[] = {
	{EXT_TEAMPLAY, 1, "Teamplay"},
	{EXT_PLAYER_LIMIT, 1, "Player Limit"},
};
#define N_OURS (sizeof(OURS) / sizeof(OURS[0]))

/* Who we say we are in the Version Response. 'p' is no client LSd
 * knows, so it applies none of its per-client quirks (funcs_event.c
 * on_version: those are for 'B', 'K' and 'o') and speaks the plain
 * protocol. lib_ext announces extensions to versions above 0.1.3. */
#define CLIENT_ID 'p'
#define CLIENT_MAJOR 1
#define CLIENT_MINOR 0
#define CLIENT_PATCH 0
#define CLIENT_OS "LSd scripted person"

#define TOOL_GUN 2
#define TEAM_SPECTATOR 255

/* A standing body's feet are 2.25 below its eye (demoncore.c
 * boxclipmove: offset 0.9 + half-height 1.35), and rest a hair above
 * the face they stand on: the physics stops a falling body when its
 * feet would enter the block, so bots at rest read G - 2.255 or so. Feet
 * exactly on the face count as inside it, and the server's physics
 * climbs the body out between our packets, a block at a time. */
#define EYE_ABOVE_FEET 2.25f
#define FEET_CLEARANCE 0.01f
/* LSd's spawn sends the eye 2 lower than it is; a client takes it off. */
#define CREATE_PLAYER_Z_OFFSET 2.0f

/* ------------------------------------------------------------------ */
/* Pacing                                                              */

#define STEP 1.0f         /* blocks across per position packet while walking */
#define CLIMB 10          /* the most a step goes up onto a floor */
#define DROP 8            /* the most a step goes down (fall_damage.lua: free) */
#define WALK_HZ 10        /* position packets a second while walking */
#define POS_HZ 4          /* position and aim a second, otherwise */
#define ARRIVED 0.5f      /* within this of the target is there */
#define AIM_COS 0.999f    /* the server's aim is ours */
#define EXT_WAIT 3.0      /* seconds to wait for the ExtInfo before joining */
#define MAX_PUTBACKS 20   /* refused steps before giving up the walk */

typedef struct {
	float x, y, z;
} vec3;

/* ------------------------------------------------------------------ */
/* Options                                                             */

#define MAX_SAY 64

static struct {
	const char *host;
	int port;
	const char *name;
	int team;
	int weapon;
	int has_at;
	vec3 at;        /* the block stood on */
	int has_look;
	vec3 look;
	const char *say[MAX_SAY];
	int n_say;
	double say_gap;
	double stay;
} opt = {
	.host = "127.0.0.1",
	.port = 32887,
	.name = "Tester",
	.team = 1,
	.weapon = 0,
	.say_gap = 1.5,
	.stay = 30,
};

/* ------------------------------------------------------------------ */
/* State                                                               */

static struct {
	ENetHost *host;
	ENetPeer *peer;
	int connected;

	unsigned map_bytes;
	z_stream inflater;  /* the map as it comes */
	int inflating;
	uint8_t *vxl;       /* the map's .vxl, inflated */
	size_t vxl_len, vxl_cap;
	uint64_t *solid;    /* each column's solid voxels, bit z */
	int state_received;
	double state_at;
	int version_sent;
	int ext_offered, ext_replied;
	int joined;

	int me;          /* our player id, -1 until StateData */
	int team;
	int alive;

	vec3 pos;        /* where we hold ourselves to be (the eye) */
	vec3 ori;        /* where we aim */

	int seen;        /* the server has reported us in a WorldUpdate */
	vec3 srv_pos, srv_ori;

	/* The walk: on the ground, a column at a time, to the target. */
	int walking;
	int16_t (*way)[3];   /* the columns of the way and their floors */
	int way_n, way_at;
	int putbacks;
	int arrived;

	int ready;       /* alive, there, aim applied: may speak */
	int said;
	double said_at;

	double last_pos_sent, last_state_print;
	unsigned char unknown_seen[256];
} g = {.me = -1, .team = -1};

static volatile sig_atomic_t stop_requested;

static void on_signal(int sig)
{
	(void)sig;
	stop_requested = 1;
}

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ------------------------------------------------------------------ */
/* Bytes                                                               */

static float get_f32(const uint8_t *p)
{
	uint32_t u = (uint32_t)p[0] | (uint32_t)p[1] << 8 |
		(uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
	float f;
	memcpy(&f, &u, 4);
	return f;
}

static void put_f32(uint8_t *p, float f)
{
	uint32_t u;
	memcpy(&u, &f, 4);
	p[0] = u;
	p[1] = u >> 8;
	p[2] = u >> 16;
	p[3] = u >> 24;
}

static vec3 get_vec3(const uint8_t *p)
{
	vec3 v = {get_f32(p), get_f32(p + 4), get_f32(p + 8)};
	return v;
}

static vec3 vsub(vec3 a, vec3 b)
{
	vec3 v = {a.x - b.x, a.y - b.y, a.z - b.z};
	return v;
}

static float vlen(vec3 v)
{
	return sqrtf(v.x * v.x + v.y * v.y + v.z * v.z);
}

static float vdot(vec3 a, vec3 b)
{
	return a.x * b.x + a.y * b.y + a.z * b.z;
}

/* Text from the server, printable on one line. */
static void print_text(const uint8_t *s, size_t n)
{
	for (size_t i = 0; i < n && s[i] != '\0'; i++)
		putchar(s[i] < 0x20 || s[i] == 0x7f ? '?' : s[i]);
}

/* ------------------------------------------------------------------ */
/* Sending                                                             */

/* Everything goes reliable and in order on the one channel, which is
 * what makes "the aim, then the /pingmark that depends on it" hold on
 * the server's side. */
static void send_raw(const uint8_t *data, size_t len)
{
	ENetPacket *p = enet_packet_create(data, len, ENET_PACKET_FLAG_RELIABLE);
	if (p != NULL && enet_peer_send(g.peer, 0, p) != 0)
		enet_packet_destroy(p);
}

static void send_vec3(uint8_t id, vec3 v)
{
	uint8_t b[13];
	b[0] = id;
	put_f32(b + 1, v.x);
	put_f32(b + 5, v.y);
	put_f32(b + 9, v.z);
	send_raw(b, sizeof b);
}

static void send_version(void)
{
	uint8_t b[5 + sizeof CLIENT_OS - 1];
	b[0] = PKT_VERSION_RESPONSE;
	b[1] = CLIENT_ID;
	b[2] = CLIENT_MAJOR;
	b[3] = CLIENT_MINOR;
	b[4] = CLIENT_PATCH;
	memcpy(b + 5, CLIENT_OS, sizeof CLIENT_OS - 1); /* not terminated */
	send_raw(b, sizeof b);
	g.version_sent = 1;
}

static void send_join(void)
{
	uint8_t b[12 + 16];
	size_t n = strlen(opt.name);
	if (n > 15)
		n = 15;
	b[0] = PKT_EXISTING_PLAYER;
	b[1] = g.me;
	b[2] = opt.team;
	b[3] = opt.weapon;
	b[4] = TOOL_GUN;
	memset(b + 5, 0, 4); /* kills */
	b[9] = b[10] = b[11] = 0; /* colour, ignored */
	memcpy(b + 12, opt.name, n);
	b[12 + n] = '\0';
	send_raw(b, 12 + n + 1);
	g.joined = 1;
	printf("INFO  joining team %d as \"%.*s\" (player id %d)\n",
		opt.team, (int)n, opt.name, g.me);
}

static void send_chat(const char *text)
{
	uint8_t b[3 + 256];
	size_t n = strlen(text);
	if (n > 255)
		n = 255;
	b[0] = PKT_CHAT;
	b[1] = g.me;
	b[2] = 0; /* all */
	memcpy(b + 3, text, n);
	b[3 + n] = '\0';
	send_raw(b, 3 + n + 1);
	printf("SAID  %.*s\n", (int)n, text);
}

/* ------------------------------------------------------------------ */
/* Moving and aiming                                                   */

static vec3 target_eye(void)
{
	vec3 t = {opt.at.x, opt.at.y, opt.at.z - EYE_ABOVE_FEET - FEET_CLEARANCE};
	return t;
}

/* The aim the person wants right now: at --look from the eye, or
 * whatever it was given. Always a unit vector -- LSd refuses any other. */
static vec3 wanted_ori(void)
{
	if (opt.has_look) {
		vec3 d = vsub(opt.look, g.pos);
		float l = vlen(d);
		if (l > 1e-4f) {
			d.x /= l;
			d.y /= l;
			d.z /= l;
			return d;
		}
	}
	return g.ori;
}

/* ------------------------------------------------------------------ */
/* The map                                                             */

/* the inflated bytes, grown as they come */
static void vxl_take(const uint8_t *d, size_t n)
{
	uint8_t out[16384];

	if (!g.inflating) {
		memset(&g.inflater, 0, sizeof g.inflater);
		if (inflateInit(&g.inflater) != Z_OK)
			return;
		g.inflating = 1;
		g.vxl_len = 0;
	}
	g.inflater.next_in = (Bytef *)d;
	g.inflater.avail_in = (uInt)n;
	do {
		int r;
		size_t got;

		g.inflater.next_out = out;
		g.inflater.avail_out = sizeof out;
		r = inflate(&g.inflater, Z_NO_FLUSH);
		if (r != Z_OK && r != Z_STREAM_END && r != Z_BUF_ERROR)
			return;
		got = sizeof out - g.inflater.avail_out;
		if (g.vxl_len + got > g.vxl_cap) {
			size_t cap = g.vxl_cap ? g.vxl_cap * 2 : 1 << 22;
			uint8_t *v;

			while (cap < g.vxl_len + got)
				cap *= 2;
			if (!(v = realloc(g.vxl, cap)))
				return;
			g.vxl = v;
			g.vxl_cap = cap;
		}
		memcpy(g.vxl + g.vxl_len, out, got);
		g.vxl_len += got;
		if (r == Z_STREAM_END)
			break;
	} while (g.inflater.avail_out == 0);
}

/* the .vxl read into solid columns (Ken Silverman's format, as libvxl
 * reads it: each column solid but for the air before each span's top) */
static void vxl_load(void)
{
	const uint8_t *v = g.vxl, *end = g.vxl + g.vxl_len;
	int x, y;

	if (g.inflating) {
		inflateEnd(&g.inflater);
		g.inflating = 0;
	}
	free(g.solid);
	if (!(g.solid = malloc(512 * 512 * sizeof *g.solid)))
		return;
	for (y = 0; y < 512; y++)
		for (x = 0; x < 512; x++) {
			uint64_t col = ~(uint64_t)0;
			int z = 0;

			for (;;) {
				int i;

				if (v + 4 > end) {
					free(g.solid);
					g.solid = NULL;
					printf("WARN  the map ends early: walking blind\n");
					return;
				}
				for (i = z; i < v[1]; i++)
					col &= ~((uint64_t)1 << i);
				if (v[0] == 0) {
					v += 4 * (v[2] - v[1] + 2);
					break;
				}
				/* past this span's colours: the next span's air starts where
				 * this one's floor colours end, its byte 3 */
				v += v[0] * 4;
				if (v + 4 > end)
					break;
				z = v[3];
			}
			g.solid[y * 512 + x] = col;
		}
	printf("INFO  map read (%zu bytes)\n", g.vxl_len);
}

static int solid_at(int x, int y, int z)
{
	if (x < 0 || y < 0 || x > 511 || y > 511 || z > 63)
		return 1;
	if (z < 0 || g.solid == NULL)
		return 0;
	return (int)(g.solid[y * 512 + x] >> z & 1);
}

/* the floor a body at feet height `feet` stands on in column (x, y): of
 * the solid voxels with three of air over them, the nearest to its feet
 * and no more than CLIMB over them; -1 none */
static int floor_near(int x, int y, float feet)
{
	int best = -1, z;
	float bd = 1e9f;

	for (z = 0; z < 64; z++) {
		float d;

		if (!solid_at(x, y, z) || solid_at(x, y, z - 1) || solid_at(x, y, z - 2) || solid_at(x, y, z - 3))
			continue;
		if ((float)z < feet - CLIMB)
			continue;
		d = fabsf((float)z - feet);
		if (d < bd) { bd = d; best = z; }
	}
	return best;
}

/* ------------------------------------------------------------------ */
/* Moving and aiming, continued                                         */

/* the way from where it stands to the target, over floors (breadth
 * first, 4 sides): into g.way; 0 when there is none (then straight) */
static int find_way(void)
{
	enum { NX = 512 };
	vec3 t = target_eye();
	int sx = (int)floorf(g.pos.x), sy = (int)floorf(g.pos.y), tx = (int)floorf(t.x), ty = (int)floorf(t.y);
	int sz = floor_near(sx, sy, g.pos.z + EYE_ABOVE_FEET + FEET_CLEARANCE);
	int32_t *from = NULL, *queue = NULL;
	int8_t *fz = NULL;
	int head = 0, tail = 0, k, n = 0, found = -1;
	static const int S[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};

	g.way_n = g.way_at = 0;
	if (g.solid == NULL || sz < 0 || sx < 0 || sy < 0 || sx > 511 || sy > 511)
		return 0;
	from = malloc(NX * NX * sizeof *from);
	queue = malloc(NX * NX * sizeof *queue);
	fz = malloc(NX * NX);
	if (!from || !queue || !fz)
		goto out;
	for (k = 0; k < NX * NX; k++)
		from[k] = -2;
	from[sy * NX + sx] = -1;
	fz[sy * NX + sx] = (int8_t)sz;
	queue[tail++] = sy * NX + sx;
	while (head < tail) {
		int c = queue[head++], cx = c % NX, cy = c / NX, cz = fz[c], d;

		if (cx == tx && cy == ty) { found = c; break; }
		for (d = 0; d < 4; d++) {
			int nx = cx + S[d][0], ny = cy + S[d][1], nc, nz;

			if (nx < 0 || ny < 0 || nx > 511 || ny > 511 || from[ny * NX + nx] != -2)
				continue;
			nz = floor_near(nx, ny, (float)cz);
			if (nz < 0 || nz < cz - CLIMB || nz > cz + DROP)
				continue;
			nc = ny * NX + nx;
			from[nc] = c;
			fz[nc] = (int8_t)nz;
			queue[tail++] = nc;
		}
	}
	if (found >= 0) {
		for (k = found; k >= 0; k = from[k])
			n++;
		free(g.way);
		if ((g.way = malloc((size_t)n * sizeof *g.way)) != NULL) {
			int i = n;

			for (k = found; k >= 0; k = from[k]) {
				i--;
				g.way[i][0] = (int16_t)(k % NX);
				g.way[i][1] = (int16_t)(k / NX);
				g.way[i][2] = fz[k];
			}
			g.way_n = n;
		}
	}
out:
	free(from);
	free(queue);
	free(fz);
	return g.way_n;
}

static void plan_walk(void)
{
	vec3 t = target_eye();
	int n = find_way();

	g.walking = 1;
	g.arrived = 0;
	printf("INFO  walking from %.2f,%.2f,%.2f to %.2f,%.2f,%.2f"
		" (eye; feet on z=%.2f), %s\n",
		g.pos.x, g.pos.y, g.pos.z, t.x, t.y, t.z, opt.at.z,
		n ? "on the ground" : "no way on the ground: straight");
}

/* One step along the walk: the next column of the way, its middle, the
 * feet on its floor; at the end (or with no way) STEP straight at the
 * target, then the target itself. */
static void walk_step(void)
{
	vec3 t = target_eye(), d;
	float across;

	if (g.way_at < g.way_n) {
		g.pos.x = (float)g.way[g.way_at][0] + 0.5f;
		g.pos.y = (float)g.way[g.way_at][1] + 0.5f;
		g.pos.z = (float)g.way[g.way_at][2] - EYE_ABOVE_FEET - FEET_CLEARANCE;
		g.way_at++;
		return;
	}
	d = vsub(t, g.pos);
	across = sqrtf(d.x * d.x + d.y * d.y);
	if (across <= STEP) {
		g.pos = t;
		g.walking = 0;
		g.arrived = 1;
		printf("INFO  arrived at %.2f,%.2f,%.2f\n", g.pos.x, g.pos.y, g.pos.z);
		return;
	}
	g.pos.x += d.x / across * STEP;
	g.pos.y += d.y / across * STEP;
}

static void send_pose(double t)
{
	if (g.walking)
		walk_step();
	g.ori = wanted_ori();
	send_vec3(PKT_POSITION, g.pos);
	send_vec3(PKT_ORIENTATION, g.ori);
	g.last_pos_sent = t;
}

/* ------------------------------------------------------------------ */
/* Receiving                                                           */

static void on_ext_info(const uint8_t *d, size_t len)
{
	uint8_t reply[2 + 2 * N_OURS];
	size_t n = 0;

	if (len < 2 || len != 2 + 2 * (size_t)d[1]) {
		printf("WARN  malformed ExtInfo (%zu bytes), ignored\n", len);
		return;
	}
	if (g.ext_replied) /* once per connection */
		return;
	g.ext_offered = 1;

	printf("INFO  server offers %u extension(s):", d[1]);
	for (unsigned i = 0; i < d[1]; i++)
		printf(" %u/v%u", d[2 + 2 * i], d[3 + 2 * i]);
	printf("\n");

	for (size_t k = 0; k < N_OURS; k++) {
		for (unsigned i = 0; i < d[1]; i++) {
			if (d[2 + 2 * i] == OURS[k].id && d[3 + 2 * i] == OURS[k].version) {
				reply[2 + 2 * n] = OURS[k].id;
				reply[3 + 2 * n] = OURS[k].version;
				printf("INFO  claiming %s (%u)\n", OURS[k].title, OURS[k].id);
				n++;
				break;
			}
		}
	}
	reply[0] = PKT_EXT_INFO;
	reply[1] = n;
	send_raw(reply, 2 + 2 * n);
	g.ext_replied = 1;
}

static void on_teamplay(const uint8_t *d, size_t len)
{
	if (len < 2)
		return;
	switch (d[1]) {
	case 0: /* Config */
		if (len >= 11)
			printf("INFO  teamplay config: features 0x%02x\n", d[2]);
		break;
	case 1: /* Ping: id, xyz, duration, surfaces, bgr, msgid, reason */
		if (len >= 24) {
			vec3 p = get_vec3(d + 3);
			printf("PING  from=%u at %.2f,%.2f,%.2f: ", d[2], p.x, p.y, p.z);
			print_text(d + 24, len - 24);
			printf("\n");
		}
		break;
	case 2: /* ESP Mark: shown to a human, nothing for us to do */
		break;
	default:
		break;
	}
}

static void on_world_update(const uint8_t *d, size_t len)
{
	size_t n = (len - 1) / 24;
	if (g.me < 0 || (size_t)g.me >= n)
		return;
	const uint8_t *e = d + 1 + 24 * g.me;
	g.srv_pos = get_vec3(e);
	g.srv_ori = get_vec3(e + 12);
	g.seen = 1;
}

static void on_spawn(vec3 eye)
{
	g.alive = 1;
	g.pos = eye;
	/* The aim LSd gives a spawning player (main.c spawn_player), which
	 * it does not send: team 0 faces +x, the other -x. */
	g.ori = (vec3){g.team == 0 ? 1 : -1, 0, 0};
	g.seen = 0;
	g.ready = 0;
	g.putbacks = 0;
	printf("INFO  spawned at %.2f,%.2f,%.2f (team %d)\n",
		eye.x, eye.y, eye.z, g.team);
	if (opt.has_at)
		plan_walk();
	else
		g.arrived = 1;
}

static void on_packet(const uint8_t *d, size_t len)
{
	if (len < 1)
		return;

	switch (d[0]) {
	case PKT_MAP_START:
		/* Its size field is not to be trusted (LSd sends 1): the map
		 * ends where the StateData begins. */
		g.map_bytes = 0;
		if (g.inflating) {
			inflateEnd(&g.inflater);
			g.inflating = 0;
		}
		g.state_received = 0;
		printf("INFO  map coming\n");
		break;
	case PKT_MAP_CHUNK:
		g.map_bytes += len - 1;
		vxl_take(d + 1, len - 1);   /* kept: the walk is on the ground */
		break;
	case PKT_STATE_DATA:
		if (len < 2)
			break;
		g.me = d[1];
		g.state_received = 1;
		vxl_load();
		g.state_at = now();
		printf("INFO  map loaded (%u bytes), player id %d\n", g.map_bytes, g.me);
		break;
	case PKT_HANDSHAKE_INIT:
		if (len == 5) {
			uint8_t b[5];
			b[0] = PKT_HANDSHAKE_RETURN;
			memcpy(b + 1, d + 1, 4);
			send_raw(b, sizeof b);
		}
		break;
	case PKT_VERSION_GET:
		/* The plain request gets the plain answer, which is the route
		 * lib_ext announces on. The request with property ids asks for
		 * the optional extended answer, which tells LSd a locale and a
		 * UTF-8 flag this client has no use for: not answered. */
		if (len == 1 && !g.version_sent)
			send_version();
		break;
	case PKT_EXT_INFO:
		on_ext_info(d, len);
		break;
	case PKT_WORLD_UPDATE:
		on_world_update(d, len);
		break;
	case PKT_CREATE_PLAYER:
		if (len >= 16 && d[1] == g.me) {
			vec3 p = get_vec3(d + 4);
			p.z -= CREATE_PLAYER_Z_OFFSET;
			g.team = d[3];
			on_spawn(p);
		}
		break;
	case PKT_EXISTING_PLAYER:
		if (len >= 3 && d[1] == g.me && g.me >= 0)
			g.team = d[2];
		break;
	case PKT_KILL:
		if (len >= 3 && d[1] == g.me) {
			g.alive = 0;
			g.walking = 0;
			g.ready = 0;
			printf("INFO  killed by %u (type %u)\n", d[2], len >= 4 ? d[3] : 0);
		}
		break;
	case PKT_POSITION:
		/* The server setting us somewhere, or putting us back after a
		 * step it refused. Either way, that is where we are. */
		if (len == 13) {
			g.pos = get_vec3(d + 1);
			printf("WARN  server put us at %.2f,%.2f,%.2f\n",
				g.pos.x, g.pos.y, g.pos.z);
			if (g.walking && ++g.putbacks > MAX_PUTBACKS) {
				g.walking = 0;
				printf("WARN  walk given up after %d refused steps\n",
					g.putbacks);
			} else if (g.walking) {
				plan_walk();
			}
		}
		break;
	case PKT_ORIENTATION:
		if (len == 13)
			g.ori = get_vec3(d + 1);
		break;
	case PKT_CHAT:
		if (len >= 4) {
			printf("CHAT  type=%u from=%u: ", d[2], d[1]);
			print_text(d + 3, len - 3);
			printf("\n");
		}
		break;
	case PKT_TEAMPLAY:
		on_teamplay(d, len);
		break;
	case PKT_PLAYER_LEFT:
		break;
	default:
		/* Not ours to read: the rest of the base protocol (blocks,
		 * grenades, other players, the CTF/TC state) silently, anything
		 * past it noted once. Never fatal. */
		if (d[0] >= BASE_PROTOCOL_END && !g.unknown_seen[d[0]]) {
			g.unknown_seen[d[0]] = 1;
			printf("INFO  ignoring packet id %u\n", d[0]);
		}
		break;
	}
}

/* ------------------------------------------------------------------ */
/* The clock                                                           */

static void print_state(void)
{
	if (g.seen && g.alive)
		printf("STATE id=%d team=%d alive=1 pos=%.2f,%.2f,%.2f ori=%.3f,%.3f,%.3f\n",
			g.me, g.team, g.srv_pos.x, g.srv_pos.y, g.srv_pos.z,
			g.srv_ori.x, g.srv_ori.y, g.srv_ori.z);
	else
		printf("STATE id=%d team=%d alive=%d\n", g.me, g.team, g.alive);
}

/* Alive, where it was asked to be, and aiming where it was asked to, by
 * the server's own report: a /pingmark sent now is judged against the
 * pose the person meant. */
static int pose_applied(void)
{
	if (!g.alive || !g.arrived || !g.seen)
		return 0;
	if (opt.has_at && vlen(vsub(g.srv_pos, target_eye())) > ARRIVED)
		return 0;
	if (vdot(g.srv_ori, g.ori) < AIM_COS * vlen(g.srv_ori))
		return 0;
	return 1;
}

static void tick(double t, double started)
{
	if (g.state_received && !g.joined && g.me >= 0 &&
	    (g.ext_replied || t - g.state_at > EXT_WAIT)) {
		if (!g.ext_replied)
			printf("WARN  no extension offer within %.0f s; joining without\n",
				EXT_WAIT);
		send_join();
	}

	if (g.alive) {
		double period = 1.0 / (g.walking ? WALK_HZ : POS_HZ);
		if (t - g.last_pos_sent >= period)
			send_pose(t);
	}

	if (!g.ready && pose_applied()) {
		g.ready = 1;
		printf("INFO  in place: pos %.2f,%.2f,%.2f ori %.3f,%.3f,%.3f\n",
			g.srv_pos.x, g.srv_pos.y, g.srv_pos.z,
			g.srv_ori.x, g.srv_ori.y, g.srv_ori.z);
		g.said_at = t - opt.say_gap;
	}
	if (g.ready && g.alive && g.said < opt.n_say && t - g.said_at >= opt.say_gap) {
		send_chat(opt.say[g.said++]);
		g.said_at = t;
	}

	if (g.state_received && t - g.last_state_print >= 1.0) {
		print_state();
		g.last_state_print = t;
	}

	if (t - started >= opt.stay)
		stop_requested = 1;
}

/* ------------------------------------------------------------------ */
/* Main                                                                */

static void usage(void)
{
	fprintf(stderr,
		"usage: person [--host H] [--port P] [--name N] [--team 0|1]\n"
		"              [--weapon 0|1|2] [--at X Y Z] [--look X Y Z]\n"
		"              [--say TEXT]... [--say-gap S] [--stay S]\n");
	exit(2);
}

static double num(const char *s)
{
	char *end;
	double v = strtod(s, &end);
	if (*s == '\0' || *end != '\0') {
		fprintf(stderr, "person: not a number: %s\n", s);
		usage();
	}
	return v;
}

static void parse_args(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		int left = argc - i - 1;
#define NEED(k) do { if (left < (k)) usage(); } while (0)
		if (!strcmp(a, "--host")) {
			NEED(1); opt.host = argv[++i];
		} else if (!strcmp(a, "--port")) {
			NEED(1); opt.port = (int)num(argv[++i]);
		} else if (!strcmp(a, "--name")) {
			NEED(1); opt.name = argv[++i];
		} else if (!strcmp(a, "--team")) {
			NEED(1); opt.team = (int)num(argv[++i]);
		} else if (!strcmp(a, "--weapon")) {
			NEED(1); opt.weapon = (int)num(argv[++i]);
		} else if (!strcmp(a, "--at")) {
			NEED(3);
			opt.at = (vec3){num(argv[i + 1]), num(argv[i + 2]), num(argv[i + 3])};
			opt.has_at = 1;
			i += 3;
		} else if (!strcmp(a, "--look")) {
			NEED(3);
			opt.look = (vec3){num(argv[i + 1]), num(argv[i + 2]), num(argv[i + 3])};
			opt.has_look = 1;
			i += 3;
		} else if (!strcmp(a, "--say")) {
			NEED(1);
			if (opt.n_say == MAX_SAY) {
				fprintf(stderr, "person: at most %d --say lines\n", MAX_SAY);
				exit(2);
			}
			opt.say[opt.n_say++] = argv[++i];
		} else if (!strcmp(a, "--say-gap")) {
			NEED(1); opt.say_gap = num(argv[++i]);
		} else if (!strcmp(a, "--stay")) {
			NEED(1); opt.stay = num(argv[++i]);
		} else {
			usage();
		}
#undef NEED
	}
	if (opt.team != 0 && opt.team != 1 && opt.team != TEAM_SPECTATOR) {
		fprintf(stderr, "person: --team is 0, 1 or 255 (spectator)\n");
		exit(2);
	}
	if (opt.weapon < 0 || opt.weapon > 2) {
		fprintf(stderr, "person: --weapon is 0 (rifle), 1 (smg) or 2 (shotgun)\n");
		exit(2);
	}
}

static void disconnect(void)
{
	ENetEvent ev;
	double until = now() + 2;

	enet_peer_disconnect(g.peer, 0);
	while (now() < until && enet_host_service(g.host, &ev, 50) >= 0) {
		if (ev.type == ENET_EVENT_TYPE_RECEIVE)
			enet_packet_destroy(ev.packet);
		else if (ev.type == ENET_EVENT_TYPE_DISCONNECT)
			return;
	}
	enet_peer_reset(g.peer);
}

int main(int argc, char **argv)
{
	ENetAddress addr;
	ENetEvent ev;
	double started;

	setvbuf(stdout, NULL, _IOLBF, 0);
	parse_args(argc, argv);

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	if (enet_initialize() != 0) {
		fprintf(stderr, "person: enet_initialize failed\n");
		return 1;
	}
	atexit(enet_deinitialize);

	g.host = enet_host_create(NULL, 1, 1, 0, 0);
	if (g.host == NULL || enet_host_compress_with_range_coder(g.host) != 0) {
		fprintf(stderr, "person: cannot create the ENet host\n");
		return 1;
	}
	if (enet_address_set_host(&addr, opt.host) != 0) {
		fprintf(stderr, "person: cannot resolve %s\n", opt.host);
		return 1;
	}
	addr.port = opt.port;

	g.peer = enet_host_connect(g.host, &addr, 1, PROTOCOL_075);
	if (g.peer == NULL) {
		fprintf(stderr, "person: cannot start connecting\n");
		return 1;
	}

	started = now();
	if (enet_host_service(g.host, &ev, 5000) <= 0 || ev.type != ENET_EVENT_TYPE_CONNECT) {
		fprintf(stderr, "person: no answer from %s:%d\n", opt.host, opt.port);
		enet_peer_reset(g.peer);
		return 1;
	}
	g.connected = 1;
	printf("INFO  connected to %s:%d\n", opt.host, opt.port);

	/* Wait up to 10 ms for traffic, take everything that came, then act. */
	while (!stop_requested) {
		int r = enet_host_service(g.host, &ev, 10);
		while (r > 0) {
			if (ev.type == ENET_EVENT_TYPE_RECEIVE) {
				on_packet(ev.packet->data, ev.packet->dataLength);
				enet_packet_destroy(ev.packet);
			} else if (ev.type == ENET_EVENT_TYPE_DISCONNECT) {
				printf("INFO  disconnected by the server (reason %u)\n", ev.data);
				return 1;
			}
			r = enet_host_check_events(g.host, &ev);
		}
		if (r < 0) {
			fprintf(stderr, "person: ENet service failed\n");
			return 1;
		}
		tick(now(), started);
	}

	printf("INFO  leaving\n");
	disconnect();
	enet_host_destroy(g.host);
	return 0;
}
