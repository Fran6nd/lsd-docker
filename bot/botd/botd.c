/* botd.c -- the host: the file, the clock, the logs
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * The only place in the engine with a clock, files or logs (README.md).
 *
 * A SESSION is one attach to one link file: wait for the file, attach,
 * make an engine, then rounds at --hz until the server is closing, has
 * gone silent, the file was replaced, or we were told to stop. After a
 * session that ended because the file was replaced, the next session
 * attaches to the new one. Anything else ends the process, and the
 * container's entrypoint starts it again if the server is still up.
 *
 * ONE ROUND, in this order (engine.h):
 *   beat; every queued event (a map is read from its file here); the
 *   world, whole; think; the intents out; the actions went out during
 *   think, through the host callback.
 *
 * INTENTS ARE NOT TORN. The core writes an intent field by field, and the
 * server (LuaJIT, another process, another core) may read the file at any
 * instant: it could see the new keys with the old aim. So the core is
 * given a private array (`mine`), and after the think each intent that
 * changed is stored into the file as five 32-bit atomic stores, aim and
 * life first, the word with the keys and BL_I_VALID last behind a release
 * fence. A reader can still see a new aim with the old keys for one read
 * (the struct is 20 bytes, no atomic that wide), but never a half-written
 * float or a valid flag in front of its data. One read of a mixed intent
 * is one 1/30 s frame of a bot looking slightly differently than it
 * walks, which no player can tell from lag.
 *
 * THE FILE CAN BE REPLACED UNDER US. The server's bl_create truncates the
 * file it finds, so a botd that kept its mapping of a dead server's file
 * could take SIGBUS the instant the server remakes it, or read a file
 * that is somebody else's now. Three guards: the path's inode is
 * compared every 250 ms; the header must still say magic and our own
 * pid in engine_pid (a remade file says 0); and SIGBUS itself is caught
 * and turned into a re-attach.
 *
 * SPLITTING THE THINK LATER. think_all() is the only place that calls
 * bc_engine_think. To spread it over workers by team or by bot range:
 * give each worker its own bc_engine (the events are fanned out to all of
 * them by dispatch_event(), the map handed to all by load_map()), have
 * each think the same copy of the world into the same `mine` array for
 * its own pids (the arrays do not overlap), and join the workers here
 * before flush_intents(). Nothing in core/ changes: it is only told
 * which pids are its own.
 */
#include "botd.h"
#include "engine.h"

#include <dirent.h>
#include <errno.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define U32(p) ((_Atomic uint32_t *)(p))

enum { NAP_NS = 1000000, INODE_EVERY_MS = 250, MAX_MAP_BYTES = 64 << 20 };

/* ------------------------------------------------------------------ */
/* Small things                                                       */

static volatile sig_atomic_t stop_flag;
static sigjmp_buf bus_jmp;
static volatile sig_atomic_t bus_armed;

void botd_stop(void) { stop_flag = 1; }

static void on_term(int sig) { (void)sig; stop_flag = 1; }

static void on_bus(int sig)
{
	(void)sig;
	if (bus_armed) siglongjmp(bus_jmp, 1);
	_exit(70);
}

static double now_s(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static void nap(long ns)
{
	struct timespec t = { 0, ns };
	nanosleep(&t, NULL);
}

static void say(const char *fmt, ...)
{
	char line[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	fprintf(stderr, "botd: %s\n", line);
}

void botd_opts_default(botd_opts *o)
{
	memset(o, 0, sizeof *o);
	o->file = "/dev/shm/lsd-botlink";
	o->hz = 60;
	o->budget = 3000;
	o->max_bots = 64;
	o->poll_ms = 1000;
	o->stale_ms = 5000;
	o->health_s = 60;
}

/* ------------------------------------------------------------------ */
/* One session's state                                                */

typedef struct session {
	const botd_opts *o;
	bl_file *f;
	bc_engine *e;
	dev_t dev;
	ino_t ino;
	uint32_t pid;
	/* what the core writes, and what the file has */
	bl_intent mine[BL_MAX_PLAYERS];
	bl_intent sent[BL_MAX_PLAYERS];
	bl_world world;
	/* health window */
	uint64_t rounds, events, actions, drops, world_misses;
	double sum_round, worst_round;
	uint32_t ring_dropped_seen;
	int bots;
} session;

static session S;       /* static: survives the longjmp of a SIGBUS */

/* ------------------------------------------------------------------ */
/* The engine's host callbacks                                        */

static void host_log(void *ctx, int level, const char *line)
{
	(void)ctx;
	if (level >= 2) say("engine: trouble: %s", line);
	else if (level == 1) say("engine: %s", line);
}

static void host_action(void *ctx, uint8_t type, uint8_t pid, const void *payload, uint32_t bytes)
{
	session *s = ctx;
	if (bl_push(&s->f->actions, type, pid, payload, bytes)) s->actions++;
	else s->drops++;
}

/* ------------------------------------------------------------------ */
/* Trees                                                              */

static int is_bt(const char *n)
{
	size_t l = strlen(n);
	return l > 3 && !strcmp(n + l - 3, ".bt");
}

static int by_name(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

static char *slurp(const char *path, size_t *n, size_t max)
{
	FILE *fh = fopen(path, "rb");
	if (!fh) return NULL;
	size_t cap = 1 << 16, len = 0;
	char *buf = malloc(cap + 1);
	while (buf) {
		size_t got = fread(buf + len, 1, cap - len, fh);
		len += got;
		if (len < cap) break;
		if (cap >= max) { free(buf); buf = NULL; break; }
		cap *= 2;
		char *nb = realloc(buf, cap + 1);
		if (!nb) { free(buf); buf = NULL; }
		else buf = nb;
	}
	if (buf && ferror(fh)) { free(buf); buf = NULL; }
	fclose(fh);
	if (buf) { buf[len] = '\0'; *n = len; }
	return buf;
}

/* Every *.bt of the directory, each tried alone first (so an error's line
 * is the file's own), then all the good ones as one text. */
static void load_trees(bc_engine *e, const char *dir_opt)
{
	const char *dir = dir_opt;
	if (!dir) {
		struct stat st;
		dir = "/opt/botd/trees";
		if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) dir = "./trees";
	}
	DIR *d = opendir(dir);
	if (!d) { say("no trees directory (%s): the engine runs on its own", dir); return; }
	char *names[512];
	int n = 0;
	for (struct dirent *de; n < 512 && (de = readdir(d)) != NULL;)
		if (is_bt(de->d_name)) names[n++] = strdup(de->d_name);
	closedir(d);
	qsort(names, (size_t)n, sizeof names[0], by_name);

	char err[512];
	char *all = calloc(1, 1);
	size_t alen = 0;
	int good = 0;
	for (int i = 0; i < n && all; i++) {
		char path[1024];
		size_t len;
		snprintf(path, sizeof path, "%s/%s", dir, names[i]);
		char *text = slurp(path, &len, 1 << 20);
		if (!text) { say("tree error: %s: cannot read it", path); continue; }
		err[0] = '\0';
		if (!bc_engine_trees(e, text, err, sizeof err)) {
			say("tree error: %s: %s (skipped)", path, err);
		} else {
			char *grown = realloc(all, alen + len + 2);
			if (grown) {
				all = grown;
				memcpy(all + alen, text, len);
				all[alen + len] = '\n';
				alen += len + 1;
				all[alen] = '\0';
				good++;
			}
		}
		free(text);
	}
	if (good) {
		err[0] = '\0';
		if (!bc_engine_trees(e, all, err, sizeof err))
			say("tree error: %s: %s (none loaded)", dir, err);
		else
			say("trees loaded: %d file%s from %s", good, good == 1 ? "" : "s", dir);
	} else {
		say("no trees in %s", dir);
	}
	free(all);
	for (int i = 0; i < n; i++) free(names[i]);
}

/* ------------------------------------------------------------------ */
/* The round                                                          */

static void load_map(session *s, const bl_ev_map *m)
{
	char path[BL_PATH_MAX + 1];
	memcpy(path, m->path, BL_PATH_MAX);
	path[BL_PATH_MAX] = '\0';
	const char *name = strrchr(path, '/');
	name = name ? name + 1 : path;
	double t0 = now_s();
	size_t n = 0;
	char *bytes = slurp(path, &n, MAX_MAP_BYTES);
	if (!bytes) { say("map %s: cannot read %s", name, path); return; }
	int ok = bc_engine_map(s->e, (const uint8_t *)bytes, n, m->map_seq);
	free(bytes);
	if (ok) say("map loaded: %s, %zu bytes, %.0f ms", name, n, (now_s() - t0) * 1e3);
	else say("map %s: not a map (%zu bytes)", name, n);
}

/* The one fan-out point for events (see SPLITTING THE THINK). */
static void dispatch_event(session *s, const bl_record *r)
{
	if (r->type == BL_EV_MAP) {
		if (r->size >= 4 + sizeof(bl_ev_map)) {
			bl_ev_map m;
			memcpy(&m, (const uint8_t *)r + 4, sizeof m);
			load_map(s, &m);
		}
	} else {
		bc_engine_event(s->e, r);
	}
	s->events++;
}

static void think_all(session *s, float dt)
{
	bc_engine_think(s->e, &s->world, s->mine, dt, s->o->budget);
}

static void store_intent(bl_intent *dst, const bl_intent *src)
{
	uint32_t w[5];
	memcpy(w, src, sizeof w);   /* life, keys|mouse|tool|flags, ori x y z */
	_Atomic uint32_t *d = U32(dst);
	atomic_store_explicit(&d[0], w[0], memory_order_relaxed);
	atomic_store_explicit(&d[2], w[2], memory_order_relaxed);
	atomic_store_explicit(&d[3], w[3], memory_order_relaxed);
	atomic_store_explicit(&d[4], w[4], memory_order_relaxed);
	atomic_thread_fence(memory_order_release);
	atomic_store_explicit(&d[1], w[1], memory_order_relaxed);
}

static void flush_intents(session *s)
{
	for (int i = 0; i < BL_MAX_PLAYERS; i++) {
		if (memcmp(&s->mine[i], &s->sent[i], sizeof(bl_intent)) == 0) continue;
		store_intent(&s->f->intents[i], &s->mine[i]);
		s->sent[i] = s->mine[i];
	}
}

/* ------------------------------------------------------------------ */
/* Attaching and watching the file                                    */

static bl_file *try_attach(const char *path, dev_t *dev, ino_t *ino)
{
	struct stat a, b;
	if (stat(path, &a) != 0) return NULL;
	bl_file *f = bl_attach(path);
	if (!f) return NULL;
	/* it must be the file we statted, and a live one */
	if (stat(path, &b) != 0 || a.st_ino != b.st_ino || a.st_dev != b.st_dev || bl_closing(f)) {
		bl_close(f);
		return NULL;
	}
	*dev = b.st_dev;
	*ino = b.st_ino;
	return f;
}

static int still_the_file(const session *s)
{
	struct stat st;
	if (stat(s->o->file, &st) != 0) return 0;
	return st.st_ino == s->ino && st.st_dev == s->dev;
}

static void health(session *s, double window)
{
	double r = s->rounds ? (double)s->rounds : 1;
	say("health: %.0f rounds/s, round mean %.2f ms worst %.2f ms, events %llu, actions %llu, "
	    "drops %llu, no-world %llu, bots %d",
	    (double)s->rounds / window, s->sum_round / r * 1e3, s->worst_round * 1e3,
	    (unsigned long long)s->events, (unsigned long long)s->actions,
	    (unsigned long long)s->drops, (unsigned long long)s->world_misses, s->bots);
	s->rounds = s->events = s->actions = s->drops = s->world_misses = 0;
	s->sum_round = s->worst_round = 0;
}

enum { END_STOP, END_CLOSED, END_GONE, END_REPLACED };

static int run_session(session *s)
{
	const botd_opts *o = s->o;
	const double period = 1.0 / o->hz;
	bl_file *f = s->f;
	uint8_t rec[BL_RECORD_MAX];
	int why;

	atomic_store_explicit(U32(&f->header.engine_pid), s->pid, memory_order_release);
	uint32_t beat_seen = f->header.server_beat;
	double t = now_s(), last_beat_move = t, last_stat = t, last_health = t, last_think = t;
	double deadline = t;
	int bots_was = 0;
	say("attached to %s (server beat %u)", o->file, (unsigned)beat_seen);

	for (;;) {
		if (stop_flag) { why = END_STOP; break; }
		double start = now_s();
		if (bl_closing(f)) { why = END_CLOSED; break; }
		if (atomic_load_explicit(U32(&f->header.magic), memory_order_acquire) != (uint32_t)BL_MAGIC
		    || atomic_load_explicit(U32(&f->header.engine_pid), memory_order_acquire) != s->pid) {
			why = END_REPLACED; break;
		}
		if (start - last_stat >= INODE_EVERY_MS / 1000.0) {
			last_stat = start;
			if (!still_the_file(s)) { why = END_REPLACED; break; }
		}
		if (bl_alive(f->header.server_beat, &beat_seen)) {
			last_beat_move = start;
		} else if (start - last_beat_move >= o->stale_ms / 1000.0) {
			say("the server's beat has not moved for %.1f s: it is gone", start - last_beat_move);
			why = END_GONE; break;
		}
		bl_beat_engine(f);

		for (uint32_t n; (n = bl_pop(&f->events, rec)) != 0;)
			dispatch_event(s, (const bl_record *)rec);
		uint32_t dr = atomic_load_explicit(U32(&f->events.dropped), memory_order_relaxed);
		if (dr != s->ring_dropped_seen) {
			say("the server's event queue dropped %u record%s", (unsigned)(dr - s->ring_dropped_seen),
			    dr - s->ring_dropped_seen == 1 ? "" : "s");
			s->drops += dr - s->ring_dropped_seen;
			s->ring_dropped_seen = dr;
		}
		if (bl_closing(f)) { why = END_CLOSED; break; }   /* write no intent once told */

		if (bl_world_read(f, &s->world, 8)) {
			float dt = (float)(start - last_think);
			if (dt > 0.25f) dt = 0.25f;
			last_think = start;
			think_all(s, dt);
			if (bl_closing(f) || stop_flag) { why = stop_flag ? END_STOP : END_CLOSED; break; }
			flush_intents(s);
		} else {
			s->world_misses++;
		}
		int bots = bc_engine_bots(s->e);
		if (bots != bots_was) {
			say("bots: %d -> %d", bots_was, bots);
			bots_was = s->bots = bots;
		}

		double end = now_s(), took = end - start;
		s->rounds++;
		s->sum_round += took;
		if (took > s->worst_round) s->worst_round = took;
		if (took > 3 * period) say("stall: a round took %.1f ms (period %.1f ms)", took * 1e3, period * 1e3);
		if (end - last_health >= o->health_s) { health(s, end - last_health); last_health = end; }

		/* the clock: absolute deadlines, naps of at most 1 ms */
		deadline += period;
		if (end - deadline > 3 * period) {
			if (took <= 3 * period)
				say("stall: woke %.1f ms late", (end - deadline) * 1e3);
			deadline = end;
		}
		for (;;) {
			double left = deadline - now_s();
			if (left <= 0 || stop_flag) break;
			nap(left * 1e9 < NAP_NS ? (long)(left * 1e9) : NAP_NS);
		}
	}

	if (why != END_REPLACED && s->f) {
		/* a file that is not ours any more is not ours to write */
		if (atomic_load_explicit(U32(&s->f->header.engine_pid), memory_order_acquire) == s->pid)
			atomic_store_explicit(U32(&s->f->header.engine_pid), 0, memory_order_release);
	}
	return why;
}

/* One attach, from the mapping to the unmapping. */
static int session_main(session *s)
{
	int why = END_GONE;
	bus_armed = 1;
	if (sigsetjmp(bus_jmp, 1)) {
		bus_armed = 0;
		say("the file was cut under us (SIGBUS): attaching again");
		return END_REPLACED;
	}
	bc_engine_host host = { s, host_log, host_action };
	s->e = bc_engine_new(&host, s->o->max_bots);
	if (!s->e) {
		say("cannot make the engine");
		bus_armed = 0;
		return END_GONE;
	}
	load_trees(s->e, s->o->trees);
	why = run_session(s);
	bus_armed = 0;
	return why;
}

int botd_run(const botd_opts *o)
{
	setvbuf(stderr, NULL, _IOLBF, 0);
	stop_flag = 0;
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sigemptyset(&sa.sa_mask);
	sa.sa_handler = on_term;            /* no SA_RESTART: a nap ends at once */
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sa.sa_handler = on_bus;
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGSEGV, &sa, NULL);

	if (!bl_layout_ok()) { say("this build lays the link out differently from botlink.h"); return 1; }
	int hz = o->hz > 0 ? o->hz : 60;
	botd_opts opts = *o;
	opts.hz = hz;

	int said_waiting = 0;
	for (;;) {
		dev_t dev = 0;
		ino_t ino = 0;
		bl_file *f = NULL;
		while (!stop_flag && !(f = try_attach(o->file, &dev, &ino))) {
			if (o->once) { say("no link file at %s", o->file); return 1; }
			if (!said_waiting) { say("waiting for %s", o->file); said_waiting = 1; }
			for (int ms = 0; ms < o->poll_ms && !stop_flag; ms += 50) nap(50 * 1000000L);
		}
		if (stop_flag) { say("stopped while waiting"); return 0; }
		said_waiting = 0;

		memset(&S, 0, sizeof S);
		S.o = &opts;
		S.f = f;
		S.dev = dev;
		S.ino = ino;
		S.pid = (uint32_t)getpid();
		S.ring_dropped_seen = f->events.dropped;
		int why = session_main(&S);

		if (S.e) bc_engine_free(S.e);
		bl_close(f);
		S.e = NULL;
		S.f = NULL;
		switch (why) {
		case END_STOP: say("stopping (signal)"); return 0;
		case END_CLOSED: say("the server closed the link: bye"); return 0;
		case END_GONE: say("the server is gone: bye"); return 0;
		default:
			say("the file was replaced: attaching to the new one");
			if (o->once) return 0;
			break;
		}
	}
}
