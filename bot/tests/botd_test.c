/* botd_test.c -- botd's host loop against a fake engine and a fake server.
 *
 * The fake engine (the bc_engine_* below) records what it is handed and
 * writes scripted intents and actions; the fake server is a thread that
 * makes the file with bl_create, beats, writes the world and queues
 * events. botd's own files (all but main.c) are linked in; the real core
 * is not.
 */
#include "botd.h"
#include "engine.h"

#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <utime.h>

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; \
	printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static double now_s(void)
{
	struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}
static void sleep_ms(int ms)
{
	struct timespec t = { ms / 1000, (long)(ms % 1000) * 1000000L };
	nanosleep(&t, NULL);
}

/* ---- the fake engine ---- */

enum { LOG_MAX = 64 };
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static struct {
	_Atomic int made, freed, thinks, bots;
	int ev_n, ev_type[LOG_MAX], ev_pid[LOG_MAX];
	int map_n; uint32_t map_seq; size_t map_bytes; uint8_t map_head[16];
	char trees[4096]; int trees_calls;
	char kinds[1024]; int kinds_calls;
	bl_intent *intents_ptr;
	bc_engine_host host;
	float last_dt;
	_Atomic int plan_bound;      /* what botd bounds the planner to (THE PLANNER'S BOUND) */
	uint32_t life_seen;
} fake;

static uint8_t isbot[256];
static _Atomic int watched[256], snaps;

static void fake_reset(void)
{
	pthread_mutex_lock(&mu);
	memset((void *)&fake, 0, sizeof fake);
	memset(isbot, 0, sizeof isbot);
	for (int i = 0; i < 256; i++) atomic_store(&watched[i], 0);
	atomic_store(&snaps, 0);
	pthread_mutex_unlock(&mu);
}

bc_engine *bc_engine_new(const bc_engine_host *host, int max_bots)
{
	(void)max_bots;
	pthread_mutex_lock(&mu);
	fake.host = *host;
	pthread_mutex_unlock(&mu);
	atomic_fetch_add(&fake.made, 1);
	return (bc_engine *)&fake;
}
void bc_engine_free(bc_engine *e) { (void)e; atomic_fetch_add(&fake.freed, 1); }

int bc_engine_trees(bc_engine *e, const char *text, char *err, size_t n)
{
	(void)e;
	pthread_mutex_lock(&mu);
	fake.trees_calls++;
	int bad = strstr(text, "BROKEN") != NULL;
	if (!bad) snprintf(fake.trees, sizeof fake.trees, "%s", text);
	pthread_mutex_unlock(&mu);
	if (bad) { snprintf(err, n, "line 3: broken"); return 0; }
	return 1;
}

int bc_engine_kinds(bc_engine *e, const char *text, char *err, size_t n)
{
	(void)e; (void)err; (void)n;
	pthread_mutex_lock(&mu);
	fake.kinds_calls++;
	snprintf(fake.kinds, sizeof fake.kinds, "%s", text);
	pthread_mutex_unlock(&mu);
	return 1;
}

int bc_engine_map(bc_engine *e, const uint8_t *vxl, size_t bytes, uint32_t seq)
{
	(void)e;
	pthread_mutex_lock(&mu);
	fake.map_n++; fake.map_seq = seq; fake.map_bytes = bytes;
	memcpy(fake.map_head, vxl, bytes < 16 ? bytes : 16);
	pthread_mutex_unlock(&mu);
	return 1;
}

void bc_engine_event(bc_engine *e, const bl_record *rec)
{
	(void)e;
	pthread_mutex_lock(&mu);
	if (fake.ev_n < LOG_MAX) { fake.ev_type[fake.ev_n] = rec->type; fake.ev_pid[fake.ev_n] = rec->pid; }
	fake.ev_n++;
	if (rec->type == BL_EV_BOT && !isbot[rec->pid]) { isbot[rec->pid] = 1; atomic_fetch_add(&fake.bots, 1); }
	if (rec->type == BL_EV_UNBOT && isbot[rec->pid]) { isbot[rec->pid] = 0; atomic_fetch_sub(&fake.bots, 1); }
	pthread_mutex_unlock(&mu);
}

void bc_engine_think(bc_engine *e, const bl_world *w, bl_intent *intents, float dt, int budget)
{
	(void)e; (void)budget;
	int n = atomic_fetch_add(&fake.thinks, 1) + 1;
	fake.intents_ptr = intents;
	fake.last_dt = dt;
	for (int i = 0; i < BL_MAX_PLAYERS; i++) {
		if (!(w->players[i].flags & BL_F_BOT) || atomic_load(&fake.bots) == 0) continue;
		bl_intent in = { w->players[i].life, (uint8_t)(1 + n % 100), BL_M_PRIMARY, BL_TOOL_GUN,
		                 BL_I_VALID, { 0, 1, 0 } };
		intents[i] = in;
		fake.life_seen = w->players[i].life;
		uint32_t payload = (uint32_t)n;
		fake.host.action(fake.host.ctx, BL_AC_LOG, (uint8_t)i, &payload, sizeof payload);
	}
}

void bc_engine_plan_rate(bc_engine *e, int rate, int hz) { (void)e; (void)rate; (void)hz; }
void bc_engine_runner(bc_engine *e, bc_runner run, void *ctx) { (void)e; (void)run; (void)ctx; }
void bc_engine_plan_bound(bc_engine *e, int most) { (void)e; atomic_store(&fake.plan_bound, most); }
uint32_t bc_engine_plan_spent(const bc_engine *e) { (void)e; return 0; }
int bc_engine_bots(const bc_engine *e) { (void)e; return atomic_load(&fake.bots); }
size_t bc_engine_describe(const bc_engine *e, int pid, char *out, size_t n)
{ (void)e; (void)pid; (void)out; (void)n; return 0; }

void bc_engine_watch(bc_engine *e, int pid, int on)
{ (void)e; if (pid >= 0 && pid < 256 && isbot[pid]) atomic_store(&watched[pid], on); }
int bc_engine_watched(const bc_engine *e, int pid)
{ (void)e; return pid >= 0 && pid < 256 && atomic_load(&watched[pid]); }
size_t bc_engine_snapshot(const bc_engine *e, int pid, char *out, size_t n)
{
	(void)e;
	if (pid < 0 || pid >= 256 || !isbot[pid]) return 0;
	return (size_t)snprintf(out, n, "{\"format\": \"lsd-bt-snapshot\", \"pid\": %d, \"n\": %d}\n", pid, atomic_fetch_add(&snaps, 1));
}
size_t bc_engine_roster(const bc_engine *e, char *out, size_t n)
{ (void)e; return (size_t)snprintf(out, n, "{\"format\": \"lsd-bt-bots\", \"bots\": %d}\n", atomic_load(&fake.bots)); }

/* ---- the fake server ---- */

typedef struct server {
	char path[256];
	bl_file *f;
	pthread_t th;
	_Atomic int stop, beating;
	uint32_t map_seq;
} server;

static void *server_loop(void *arg)
{
	server *s = arg;
	while (!atomic_load(&s->stop)) {
		if (atomic_load(&s->beating)) bl_beat_server(s->f);
		bl_world_begin(s->f);
		s->f->world.tick++;
		s->f->world.map_seq = s->map_seq;
		bl_player *p = &s->f->world.players[3];
		p->state = BL_ALIVE; p->flags = BL_F_BOT; p->team = 1; p->life = 7;
		bl_world_end(s->f);
		sleep_ms(2);
	}
	return NULL;
}

static void server_make(server *s, const char *name)
{
	snprintf(s->path, sizeof s->path, "%s/botd_test_%d_%s",
	         getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid(), name);
	s->f = bl_create(s->path);
	atomic_store(&s->stop, 0);
	atomic_store(&s->beating, 1);
}
static void server_start(server *s) { pthread_create(&s->th, NULL, server_loop, s); }
static void server_halt(server *s) { atomic_store(&s->stop, 1); pthread_join(s->th, NULL); }

static void push_ev(server *s, uint8_t type, uint8_t pid, const void *p, uint32_t n)
{
	CHECK(bl_push(&s->f->events, type, pid, p, n));
}

/* ---- botd in a thread ---- */

typedef struct runner { botd_opts o; pthread_t th; int rc; _Atomic int done; } runner;

static void *run_botd(void *arg)
{
	runner *r = arg;
	r->rc = botd_run(&r->o);
	atomic_store(&r->done, 1);
	return NULL;
}
/* the operator's trees for the next runner; by default a directory there is none of */
static const char *user_trees = "/nonexistent/botd_test_user_trees";
/* and where a viewer would ask what the bots think: nowhere, by default */
static const char *debug_dir = "none";

static void runner_start(runner *r, const char *file, const char *trees)
{
	botd_opts_default(&r->o);
	r->o.file = file; r->o.trees = trees; r->o.poll_ms = 50; r->o.stale_ms = 400; r->o.health_s = 1;
	r->o.user_trees = user_trees;
	r->o.debug_dir = debug_dir;
	r->rc = -1; atomic_store(&r->done, 0);
	pthread_create(&r->th, NULL, run_botd, r);
}
/* returns 1 if botd_run returned within `ms` */
static int runner_wait(runner *r, int ms)
{
	double t = now_s();
	while (!atomic_load(&r->done) && now_s() - t < ms / 1000.0) sleep_ms(2);
	int d = atomic_load(&r->done);
	if (d) pthread_join(r->th, NULL);
	return d;
}
static int wait_for(int (*cond)(void *), void *arg, int ms)
{
	double t = now_s();
	while (!cond(arg) && now_s() - t < ms / 1000.0) sleep_ms(2);
	return cond(arg);
}
static int c_attached(void *a) { server *s = a; return s->f->header.engine_pid == (uint32_t)getpid(); }
static int c_made2(void *a) { (void)a; return atomic_load(&fake.made) >= 2; }
static int c_thinks20(void *a) { (void)a; return atomic_load(&fake.thinks) >= 20; }
static int c_events(void *a) { (void)a; pthread_mutex_lock(&mu); int n = fake.ev_n; pthread_mutex_unlock(&mu); return n >= 3; }

static void write_file(const char *path, const void *p, size_t n)
{
	FILE *fh = fopen(path, "wb");
	if (fh) { fwrite(p, 1, n, fh); fclose(fh); }
}

/* ---- the tests ---- */

static char treedir[256];

static void make_trees(void)
{
	snprintf(treedir, sizeof treedir, "%s/botd_test_%d_trees",
	         getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid());
	mkdir(treedir, 0700);
	char p[300];
	snprintf(p, sizeof p, "%s/a.bt", treedir); write_file(p, "tree a:\n", 8);
	snprintf(p, sizeof p, "%s/b.bt", treedir); write_file(p, "BROKEN\n", 7);
	snprintf(p, sizeof p, "%s/c.bt", treedir); write_file(p, "tree c:\n", 8);
	snprintf(p, sizeof p, "%s/notes.txt", treedir); write_file(p, "tree z:\n", 8);
}

static void test_session(void)
{
	fake_reset();
	server s;
	server_make(&s, "a");
	/* the file is there from the start of this one: remove it to test waiting */
	bl_close(s.f);
	unlink(s.path);
	s.f = NULL;

	runner r;
	runner_start(&r, s.path, treedir);
	sleep_ms(300);
	CHECK(atomic_load(&fake.made) == 0);          /* waiting costs nothing: no engine */
	CHECK(!atomic_load(&r.done));

	s.f = bl_create(s.path);
	CHECK(s.f != NULL);
	server_start(&s);
	CHECK(wait_for(c_attached, &s, 2000));        /* wait-then-attach */
	CHECK(atomic_load(&fake.made) == 1);

	/* trees: the broken file skipped, the rest as one text, in name order */
	pthread_mutex_lock(&mu);
	CHECK(strstr(fake.trees, "tree a:") && strstr(fake.trees, "tree c:"));
	CHECK(!strstr(fake.trees, "BROKEN") && !strstr(fake.trees, "tree z:"));
	CHECK(fake.trees_calls == 4);                 /* a, b, c alone, then the good two */
	CHECK(strstr(fake.trees, "tree a:") < strstr(fake.trees, "tree c:"));
	pthread_mutex_unlock(&mu);

	/* events, in order; the map by its file */
	uint8_t vxl[300];
	for (size_t i = 0; i < sizeof vxl; i++) vxl[i] = (uint8_t)(i * 7 + 1);
	char mapfile[300];
	snprintf(mapfile, sizeof mapfile, "%s.map.vxl", s.path);
	write_file(mapfile, vxl, sizeof vxl);
	bl_ev_map em; memset(&em, 0, sizeof em);
	em.map_seq = 5; snprintf(em.path, sizeof em.path, "%s", mapfile);
	bl_ev_bot eb = { 5, BL_GUN_SMG, { 0, 0 }, 99 };
	bl_ev_block blk = { 1, 2, 3, BL_B_BUILD, 3, 0x123456 };
	push_ev(&s, BL_EV_MAP, BL_NO_PLAYER, &em, sizeof em);
	push_ev(&s, BL_EV_BOT, 3, &eb, sizeof eb);
	push_ev(&s, BL_EV_BLOCK, 3, &blk, sizeof blk);
	push_ev(&s, BL_EV_UNBOT, 9, NULL, 0);
	/* the BOT event is what makes the fake think for pid 3 */
	CHECK(wait_for(c_events, NULL, 2000));
	pthread_mutex_lock(&mu);
	CHECK(fake.ev_n == 3);                        /* all but the map */
	CHECK(fake.ev_type[0] == BL_EV_BOT && fake.ev_pid[0] == 3);
	CHECK(fake.ev_type[1] == BL_EV_BLOCK && fake.ev_type[2] == BL_EV_UNBOT && fake.ev_pid[2] == 9);
	CHECK(fake.map_n == 1 && fake.map_seq == 5 && fake.map_bytes == sizeof vxl);
	CHECK(memcmp(fake.map_head, vxl, 16) == 0);
	pthread_mutex_unlock(&mu);

	/* intents reached the file, through a private copy, whole */
	sleep_ms(100);
	bl_intent got = s.f->intents[3];
	CHECK(got.life == 7 && (got.flags & BL_I_VALID) && got.keys >= 1 && got.keys <= 100);
	CHECK(got.ori.y == 1.0f && got.mouse == BL_M_PRIMARY && got.tool == BL_TOOL_GUN);
	CHECK(fake.intents_ptr != NULL && fake.intents_ptr != s.f->intents);
	CHECK(s.f->intents[4].flags == 0);            /* nobody else's touched */

	/* actions reached the ring, in order, from the right bot */
	uint8_t buf[BL_RECORD_MAX];
	uint32_t last = 0; int n = 0, ordered = 1;
	for (uint32_t sz; (sz = bl_pop(&s.f->actions, buf)) != 0; n++) {
		bl_record *h = (bl_record *)buf;
		uint32_t v; memcpy(&v, buf + 4, 4);
		if (h->type != BL_AC_LOG || h->pid != 3 || sz != 8 || v <= last) ordered = 0;
		last = v;
	}
	CHECK(n > 5 && ordered);

	/* the clock: --hz over 2 s */
	int t0 = atomic_load(&fake.thinks);
	double w0 = now_s();
	sleep_ms(2000);
	double dt = now_s() - w0;
	double rate = (atomic_load(&fake.thinks) - t0) / dt;
	printf("   round rate %.1f/s (asked %d)\n", rate, r.o.hz);
	CHECK(rate > r.o.hz * 0.96 && rate < r.o.hz * 1.04);
	CHECK(fake.last_dt > 0.012f && fake.last_dt < 0.03f);
	/* a planner that spends nothing tells no cost: the bound is --plan-ms at
	 * the cost botd assumes (2 us an expansion) */
	CHECK(atomic_load(&fake.plan_bound) == r.o.plan_ms * 500);

	/* closing: botd exits 0, clears its pid, thinks no more */
	bl_shutdown(s.f);
	CHECK(runner_wait(&r, 1000));
	CHECK(r.rc == 0);
	CHECK(s.f->header.engine_pid == 0);
	int th = atomic_load(&fake.thinks);
	bl_intent after = s.f->intents[3];
	sleep_ms(100);
	CHECK(atomic_load(&fake.thinks) == th);
	CHECK(memcmp(&after, &s.f->intents[3], sizeof after) == 0);
	CHECK(atomic_load(&fake.freed) == 1);
	server_halt(&s);
	bl_close(s.f); unlink(s.path); unlink(mapfile);
}

static void test_dead_server(void)
{
	fake_reset();
	server s;
	server_make(&s, "dead");
	server_start(&s);
	runner r;
	runner_start(&r, s.path, treedir);
	CHECK(wait_for(c_attached, &s, 2000));
	atomic_store(&s.beating, 0);                  /* the server dies: no more beats */
	CHECK(runner_wait(&r, 1500));                 /* stale_ms = 400 */
	CHECK(r.rc == 0);
	CHECK(s.f->header.engine_pid == 0);
	server_halt(&s);
	bl_close(s.f); unlink(s.path);
}

static void test_sigterm(void)
{
	fake_reset();
	server s;
	server_make(&s, "term");
	server_start(&s);
	runner r;
	runner_start(&r, s.path, treedir);
	CHECK(wait_for(c_attached, &s, 2000));
	kill(getpid(), SIGTERM);
	CHECK(runner_wait(&r, 1000));
	CHECK(r.rc == 0);
	CHECK(s.f->header.engine_pid == 0);
	/* and while waiting for a file that never comes */
	runner r2;
	char none[300];
	snprintf(none, sizeof none, "%s.none", s.path);
	runner_start(&r2, none, treedir);
	sleep_ms(150);
	kill(getpid(), SIGINT);
	CHECK(runner_wait(&r2, 1000));
	CHECK(r2.rc == 0);
	server_halt(&s);
	bl_close(s.f); unlink(s.path);
}

static void test_once(void)
{
	botd_opts o;
	botd_opts_default(&o);
	o.file = "/nonexistent/botd_test_link";
	o.once = 1;
	CHECK(botd_run(&o) == 1);
}

static void test_reattach(int new_inode)
{
	fake_reset();
	server s;
	server_make(&s, new_inode ? "re_inode" : "re_trunc");
	server_start(&s);
	runner r;
	runner_start(&r, s.path, treedir);
	CHECK(wait_for(c_attached, &s, 2000));
	CHECK(atomic_load(&fake.made) == 1);
	CHECK(wait_for(c_thinks20, NULL, 2000));

	/* the server dies and comes back: bl_create truncates the same inode,
	 * or the file is replaced by a new one */
	server_halt(&s);
	bl_file *old = s.f;
	if (new_inode) unlink(s.path);
	s.f = bl_create(s.path);
	CHECK(s.f != NULL);
	atomic_store(&s.stop, 0);
	server_start(&s);
	CHECK(wait_for(c_made2, NULL, 3000));         /* a second engine: a fresh attach */
	CHECK(wait_for(c_attached, &s, 3000));
	CHECK(atomic_load(&fake.freed) >= 1);
	int t = atomic_load(&fake.thinks);
	sleep_ms(200);
	CHECK(atomic_load(&fake.thinks) > t + 5);     /* and it is running on the new file */

	bl_shutdown(s.f);
	CHECK(runner_wait(&r, 1000));
	CHECK(r.rc == 0);
	server_halt(&s);
	bl_close(old);
	bl_close(s.f); unlink(s.path);
}

static int c_edited(void *a) { int r; (void)a; pthread_mutex_lock(&mu); r = strstr(fake.trees, "EDITED") != NULL; pthread_mutex_unlock(&mu); return r; }

static int count_of(const char *hay, const char *needle)
{
	int n = 0;
	for (const char *p = hay; (p = strstr(p, needle)) != NULL; p += strlen(needle)) n++;
	return n;
}

/* the operator's own trees: over the built-in ones, read again at a map */
static void test_user_trees(void)
{
	char udir[300], p[400];
	fake_reset();
	snprintf(udir, sizeof udir, "%s_user", treedir);
	mkdir(udir, 0700);
	snprintf(p, sizeof p, "%s/a.bt", udir); write_file(p, "tree a:\nUSERS\n", 14);         /* replaces the built-in a */
	snprintf(p, sizeof p, "%s/n.bt", udir); write_file(p, "tree n:\n", 8);                 /* a new one */
	snprintf(p, sizeof p, "%s/x.bt", udir); write_file(p, "tree c:\nBROKEN\n", 15);        /* does not compile: c stays the built-in */
	/* the kinds of player: the built-in file, then his, in that order */
	snprintf(p, sizeof p, "%s/archetypes.txt", treedir); write_file(p, "soldier BUILTIN\n", 16);
	snprintf(p, sizeof p, "%s/archetypes.txt", udir); write_file(p, "medic HIS\n", 10);
	user_trees = udir;

	server s;
	server_make(&s, "u");
	server_start(&s);
	runner r;
	runner_start(&r, s.path, treedir);
	CHECK(wait_for(c_attached, &s, 2000));
	pthread_mutex_lock(&mu);
	CHECK(strstr(fake.trees, "USERS") != NULL);
	CHECK(count_of(fake.trees, "tree a:") == 1);  /* his, not both */
	CHECK(strstr(fake.trees, "tree n:") != NULL && count_of(fake.trees, "tree c:") == 1);
	CHECK(!strstr(fake.trees, "BROKEN"));
	{
		const char *b = strstr(fake.kinds, "BUILTIN"), *h = strstr(fake.kinds, "HIS");

		CHECK(fake.kinds_calls >= 1 && b && h && b < h);   /* both, the built-in first: his read over it */
	}
	pthread_mutex_unlock(&mu);

	/* he edits a file and the map changes: read again, no restart */
	snprintf(p, sizeof p, "%s/n.bt", udir); write_file(p, "tree n:\nEDITED\n", 15);
	uint8_t vxl[64];
	memset(vxl, 7, sizeof vxl);
	char mapfile[300];
	snprintf(mapfile, sizeof mapfile, "%s.map.vxl", s.path);
	write_file(mapfile, vxl, sizeof vxl);
	bl_ev_map em; memset(&em, 0, sizeof em);
	em.map_seq = 6; snprintf(em.path, sizeof em.path, "%s", mapfile);
	push_ev(&s, BL_EV_MAP, BL_NO_PLAYER, &em, sizeof em);
	CHECK(wait_for(c_edited, NULL, 2000));
	pthread_mutex_lock(&mu);
	CHECK(strstr(fake.trees, "USERS") != NULL && count_of(fake.trees, "tree a:") == 1);
	pthread_mutex_unlock(&mu);

	bl_shutdown(s.f);
	CHECK(runner_wait(&r, 1000));
	server_halt(&s);
	bl_close(s.f); unlink(s.path); unlink(mapfile);
	snprintf(p, sizeof p, "%s/a.bt", udir); unlink(p);
	snprintf(p, sizeof p, "%s/n.bt", udir); unlink(p);
	snprintf(p, sizeof p, "%s/x.bt", udir); unlink(p);
	snprintf(p, sizeof p, "%s/archetypes.txt", udir); unlink(p);
	snprintf(p, sizeof p, "%s/archetypes.txt", treedir); unlink(p);
	rmdir(udir);
	user_trees = "/nonexistent/botd_test_user_trees";
}

/* ---- the debug channel: a request file in, snapshots out ---- */

static char dbg[300];
static int has(const char *name)
{
	char p[400];
	struct stat st;
	snprintf(p, sizeof p, "%s/%s", dbg, name);
	return stat(p, &st) == 0;
}
static int holds(const char *name, const char *what)
{
	char p[400], text[400] = "";
	snprintf(p, sizeof p, "%s/%s", dbg, name);
	FILE *fh = fopen(p, "rb");
	if (!fh) return 0;
	size_t n = fread(text, 1, sizeof text - 1, fh);
	text[n] = 0;
	fclose(fh);
	return strstr(text, what) != NULL && text[n ? n - 1 : 0] == '\n';   /* whole: it ends as it was written */
}
static void request(const char *name, const char *text, int age_s)
{
	char p[400];
	snprintf(p, sizeof p, "%s/%s", dbg, name);
	write_file(p, text, strlen(text));
	if (age_s) {
		struct utimbuf t;
		t.actime = t.modtime = time(NULL) - age_s;
		utime(p, &t);
	}
}
static void unrequest(const char *name) { char p[400]; snprintf(p, sizeof p, "%s/%s", dbg, name); unlink(p); }
static int c_snap3(void *a) { (void)a; return has("bot-3.json") && has("bots.json"); }
static int c_no_snap3(void *a) { (void)a; return !has("bot-3.json"); }
static int c_snap3_and_9(void *a) { (void)a; return has("bot-3.json") && has("bot-9.json"); }
static int c_nothing(void *a) { (void)a; return !has("bot-3.json") && !has("bots.json") && !has("bot-9.json"); }
static int c_bots2(void *a) { (void)a; return atomic_load(&fake.bots) >= 2; }
static int c_many_snaps(void *a) { (void)a; return atomic_load(&snaps) >= 12; }

static void test_watch(void)
{
	fake_reset();
	snprintf(dbg, sizeof dbg, "%s/botd_test_%d_debug", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid());
	debug_dir = dbg;

	server s;
	server_make(&s, "w");
	server_start(&s);
	runner r;
	runner_start(&r, s.path, treedir);
	CHECK(wait_for(c_attached, &s, 2000));
	bl_ev_bot eb; memset(&eb, 0, sizeof eb);
	push_ev(&s, BL_EV_BOT, 3, &eb, sizeof eb);
	push_ev(&s, BL_EV_BOT, 9, &eb, sizeof eb);
	CHECK(wait_for(c_bots2, NULL, 2000));

	/* botd made the directory, its own alone; with nobody asking, nothing is written */
	struct stat st;
	CHECK(stat(dbg, &st) == 0 && S_ISDIR(st.st_mode) && (st.st_mode & 0777) == 0700);
	sleep_ms(700);
	CHECK(c_nothing(NULL) && atomic_load(&snaps) == 0 && !atomic_load(&watched[3]));

	/* requests that count for nothing: one gone stale, one too long, one that is a link, one not named .req */
	char big[3000], p[400], q[400];
	memset(big, 'x', sizeof big - 1); big[sizeof big - 1] = 0;
	memcpy(big, "watch=3\n", 8);
	request("old.req", "watch=3\n", 60);
	request("big.req", big, 0);
	request("notes.txt", "watch=3\n", 0);
	snprintf(p, sizeof p, "%s/notes.txt", dbg); snprintf(q, sizeof q, "%s/link.req", dbg);
	CHECK(symlink(p, q) == 0);
	sleep_ms(700);
	CHECK(c_nothing(NULL) && atomic_load(&snaps) == 0 && !atomic_load(&watched[3]));

	/* one that counts: bot 3 watched, its snapshot and the roster written whole */
	request("a.req", "watch=3\nhz=20\n", 0);
	CHECK(wait_for(c_snap3, NULL, 2000));
	CHECK(holds("bot-3.json", "\"lsd-bt-snapshot\", \"pid\": 3") && holds("bots.json", "\"lsd-bt-bots\", \"bots\": 2"));
	CHECK(atomic_load(&watched[3]) == 1 && atomic_load(&watched[9]) == 0 && !has("bot-9.json"));
	CHECK(!has("bot-3.json.new") && !has("bots.json.new"));
	/* at the rate asked: 20 a second (over a tenth and under twice that, on a busy machine) */
	int n0 = atomic_load(&snaps);
	double t0 = now_s();
	CHECK(wait_for(c_many_snaps, NULL, 3000));
	sleep_ms(500);
	double rate = (atomic_load(&snaps) - n0) / (now_s() - t0);
	printf("  snapshots of one bot at hz=20: %.1f a second\n", rate);
	CHECK(rate > 5.0 && rate < 40.0);

	/* a second viewer, another bot; a bot nobody has (77): no file, no harm */
	request("b.req", "watch=9,77\n", 0);
	CHECK(wait_for(c_snap3_and_9, NULL, 2000));
	CHECK(atomic_load(&watched[9]) == 1 && !has("bot-77.json"));
	/* the first changes its mind: 3 is let go, its file removed; 9 stays */
	request("a.req", "watch=\n", 0);
	CHECK(wait_for(c_no_snap3, NULL, 2000));
	CHECK(atomic_load(&watched[3]) == 0 && atomic_load(&watched[9]) == 1 && has("bot-9.json") && has("bots.json"));
	/* `all` */
	request("a.req", "watch=all\n", 0);
	CHECK(wait_for(c_snap3_and_9, NULL, 2000));
	CHECK(atomic_load(&watched[3]) == 1);
	/* the viewers go: nobody is watched, the files are gone */
	unrequest("a.req"); unrequest("b.req");
	CHECK(wait_for(c_nothing, NULL, 2000));
	CHECK(atomic_load(&watched[3]) == 0 && atomic_load(&watched[9]) == 0);
	int n1 = atomic_load(&snaps);
	sleep_ms(600);
	CHECK(atomic_load(&snaps) == n1);

	/* watching when the session ends: left clean */
	request("a.req", "watch=3\n", 0);
	CHECK(wait_for(c_snap3, NULL, 2000));
	bl_shutdown(s.f);
	CHECK(runner_wait(&r, 1000));
	CHECK(c_nothing(NULL));
	server_halt(&s);
	bl_close(s.f); unlink(s.path);
	unrequest("a.req"); unrequest("old.req"); unrequest("big.req"); unrequest("notes.txt"); unrequest("link.req");
	CHECK(rmdir(dbg) == 0);                      /* nothing of botd's left in it */
	debug_dir = "none";
}

int main(void)
{
	make_trees();
	printf("-- wait, attach, events, intents, actions, rate, closing\n");
	test_session();
	printf("-- a dead server\n");
	test_dead_server();
	printf("-- SIGTERM and SIGINT\n");
	test_sigterm();
	printf("-- --once\n");
	test_once();
	printf("-- the file truncated and remade\n");
	test_reattach(0);
	printf("-- the file replaced\n");
	test_reattach(1);
	printf("-- the operator's trees\n");
	test_user_trees();
	printf("-- the debug channel\n");
	test_watch();

	char p[300];
	snprintf(p, sizeof p, "%s/a.bt", treedir); unlink(p);
	snprintf(p, sizeof p, "%s/b.bt", treedir); unlink(p);
	snprintf(p, sizeof p, "%s/c.bt", treedir); unlink(p);
	snprintf(p, sizeof p, "%s/notes.txt", treedir); unlink(p);
	rmdir(treedir);
	printf("botd_test: %d checks, %d failed\n", checks, failed);
	return failed != 0;
}
