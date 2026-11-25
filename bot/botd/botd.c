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
 * THREADS. The core has none; what it offers is its planner's work cut
 * into units that may run at once (engine.h, THE PLANNER'S WORK AS
 * UNITS), and botd runs them on a pool of --threads (pool.h), the round's
 * own thread among them. Everything else of a think stays on the round's
 * thread. The core applies what the units found in its own order, so the
 * bots do the same whatever the number of threads (tests/parallel_test.c).
 * Measured (BRAIN-STATUS.md (c3)): the planner is about half of a think
 * at 230 bots on a real map once routes are shared, and four threads take
 * a think's planning time down by about 40% in the bench; live, at 100 and
 * 200 bots, a round's p99 is not the planner's and stayed where it was --
 * so one thread is the default, more an operator's choice.
 */
#include "botd.h"
#include "engine.h"
#include "pool.h"

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
/* the health line's spread of round times: tenths of a millisecond, the
 * last bucket all from 200 ms up */
enum { ROUND_BUCKETS = 2001 };

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
	o->plan_rate = BC_PLAN_RATE;
	o->max_bots = 255;
	o->threads = 1;     /* BRAIN-STATUS.md (c3): live, more bought nothing yet */
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
	uint32_t round_hist[ROUND_BUCKETS];
	uint32_t ring_dropped_seen;
	int bots;
	int user_trees;         /* the operator's directory had trees at the last look */
	int maps;
	botd_watch watch;       /* the debug channel (watch.c) */
	int watchers;
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

/* The planner's units, on the pool (THREADS, above). */
static void unit_job(void *ctx, int i)
{
	bc_plan_unit_run(&((bc_plan_unit *)ctx)[i]);
}

static void run_units(void *pool, bc_plan_unit *units, int n)
{
	botd_pool_run(pool, unit_job, units, n);
}

int botd_threads_auto(void)
{
	/* (not a POSIX name: Linux's libcs have it, a strict POSIX build on
	 * another system takes two cores) */
#ifdef _SC_NPROCESSORS_ONLN
	long cores = sysconf(_SC_NPROCESSORS_ONLN);
#else
	long cores = 2;
#endif
	int n = cores > 1 ? (int)(cores / 2) : 1;

	return n < 4 ? n : 4;
}

static botd_pool *pool;     /* the process's: made once, in botd_run */

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

/* The names of the trees a text defines ("tree <name>:" at no indent), a
 * space before and after each: " tdm tdm_answer ". */
static char *tree_names(const char *text)
{
	size_t cap = strlen(text) + 4, len = 0;
	char *out = malloc(cap);
	if (!out) return NULL;
	out[len++] = ' ';
	for (const char *p = text; p && *p;) {
		const char *eol = strchr(p, '\n');
		if (!strncmp(p, "tree ", 5)) {
			const char *q = p + 5;
			size_t n = strcspn(q, ":\n\r #");
			if (n > 0 && q[n] == ':') {
				memcpy(out + len, q, n);
				len += n;
				out[len++] = ' ';
			}
		}
		p = eol ? eol + 1 : NULL;
	}
	out[len] = '\0';
	return out;
}

/* `text` without the trees whose names are in `drop` (" a b "). */
static char *without_trees(const char *text, const char *drop)
{
	char *out = malloc(strlen(text) + 2);
	size_t len = 0;
	int keep = 1;
	if (!out) return NULL;
	for (const char *p = text; p && *p;) {
		const char *eol = strchr(p, '\n');
		size_t n = eol ? (size_t)(eol - p) + 1 : strlen(p);
		if (!strncmp(p, "tree ", 5)) {
			const char *q = p + 5;
			size_t k = strcspn(q, ":\n\r #");
			if (k > 0 && q[k] == ':') {
				char name[130];
				snprintf(name, sizeof name, " %.*s ", (int)(k < 120 ? k : 120), q);
				keep = strstr(drop, name) == NULL;
			}
		}
		if (keep) { memcpy(out + len, p, n); len += n; }
		p = eol ? eol + 1 : NULL;
	}
	out[len] = '\0';
	return out;
}

/* The *.bt files of a directory, in name order. Returns how many. */
static int list_bt(const char *dir, char **names, int max)
{
	DIR *d = opendir(dir);
	int n = 0;
	if (!d) return -1;
	for (struct dirent *de; n < max && (de = readdir(d)) != NULL;)
		if (is_bt(de->d_name)) names[n++] = strdup(de->d_name);
	closedir(d);
	qsort(names, (size_t)n, sizeof names[0], by_name);
	return n;
}

static void append(char **all, size_t *alen, const char *text)
{
	size_t len = strlen(text);
	char *grown = realloc(*all, *alen + len + 2);
	if (!grown) return;
	*all = grown;
	memcpy(*all + *alen, text, len);
	(*all)[*alen + len] = '\n';
	*alen += len + 1;
	(*all)[*alen] = '\0';
}

/* THE TREES. First every *.bt of the built-in directory, each tried alone
 * (so an error's line is the file's own), the good ones as one text.
 * Then THE OPERATOR'S: every *.bt of a second, optional directory
 * ($LSD_DATA/trees, or --user-trees). A tree there with the name of a
 * built-in one REPLACES it (an operator's own tdm); other names are added
 * (a tree to name with the setting tree=). Each of his files is tried
 * with the built-in trees it does not replace, his text first so that an
 * error's line is the line in his file; one that does not compile is
 * said ("tree error: file: line N: ...") and skipped, and the built-in
 * stays. Returns 1 if the operator's directory had any *.bt (it is then
 * read again at each map: he edits a file and changes the map, no
 * restart). */
/* THE KINDS OF PLAYER (persona.h): archetypes.txt beside the built-in
 * trees, then the operator's in his trees directory, read in that order
 * over the built-in kinds -- his replaces a kind of the same name and adds
 * the ones he names anew. Read with the trees, so again at each map. */
static void load_kinds(bc_engine *e, const char *dir, const char *userdir)
{
	char path[1200], err[200];
	char *all = NULL;
	size_t alen = 0, n;
	int files = 0, k;

	for (k = 0; k < 2; k++) {
		char *text;

		snprintf(path, sizeof path, "%s/archetypes.txt", k ? userdir : dir);
		text = slurp(path, &n, 1 << 20);
		if (!text) continue;
		append(&all, &alen, text);
		append(&all, &alen, "\n");
		free(text);
		files++;
	}
	if (!files) return;
	err[0] = '\0';
	if (!bc_engine_kinds(e, all, err, sizeof err))
		say("archetypes: %s (the built-in kinds stay)", err);
	else
		say("archetypes: %d file%s read", files, files == 1 ? "" : "s");
	free(all);
}

static int load_trees(bc_engine *e, const char *dir_opt, const char *user_opt)
{
	const char *dir = dir_opt;
	char userdir[1024];
	if (!dir) {
		struct stat st;
		dir = "/opt/botd/trees";
		if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) dir = "./trees";
	}
	if (user_opt) snprintf(userdir, sizeof userdir, "%s", user_opt);
	else snprintf(userdir, sizeof userdir, "%s/trees", getenv("LSD_DATA") && *getenv("LSD_DATA") ? getenv("LSD_DATA") : "/data");

	char *names[512];
	int n = list_bt(dir, names, 512);
	char err[512];
	char *all = calloc(1, 1);
	size_t alen = 0;
	int good = 0;
	if (n < 0) { say("no trees directory (%s): the engine runs on its own", dir); n = 0; }
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
			append(&all, &alen, text);
			good++;
		}
		free(text);
	}
	for (int i = 0; i < n; i++) free(names[i]);

	/* the operator's */
	char *unames[512];
	int un = list_bt(userdir, unames, 512), ugood = 0;
	char *user = calloc(1, 1), loaded[600] = "";
	size_t ulen = 0;
	for (int i = 0; i < un && all && user; i++) {
		char path[1300];
		size_t len;
		snprintf(path, sizeof path, "%s/%s", userdir, unames[i]);
		char *text = slurp(path, &len, 1 << 20);
		if (!text) { say("tree error: %s: cannot read it", path); continue; }
		/* his file, what of his is already in, and the built-in trees
		 * that neither replaces */
		char *mine = tree_names(text), *sofar = tree_names(user);
		char *rest = mine && sofar ? without_trees(all, mine) : NULL;
		char *rest2 = rest ? without_trees(rest, sofar) : NULL;
		char *older = mine ? without_trees(user, mine) : NULL;
		char *trial = calloc(1, 1);
		size_t tlen = 0;
		if (rest2 && older && trial) {
			append(&trial, &tlen, text);
			append(&trial, &tlen, older);
			append(&trial, &tlen, rest2);
			err[0] = '\0';
			if (!bc_engine_trees(e, trial, err, sizeof err)) {
				say("tree error: %s: %s (skipped)", path, err);
			} else {
				/* a later file of his with a tree of the same name wins */
				char *keep = calloc(1, 1);
				size_t klen = 0;
				append(&keep, &klen, older);
				append(&keep, &klen, text);
				free(user);
				user = keep;
				ulen = klen;
				ugood++;
				if (strlen(loaded) + strlen(unames[i]) + strlen(mine) + 8 < sizeof loaded)
					snprintf(loaded + strlen(loaded), sizeof loaded - strlen(loaded), "%s%s (%.*s)", loaded[0] ? ", " : "",
					         unames[i], (int)(strlen(mine) > 2 ? strlen(mine) - 2 : 0), mine + 1);
			}
		}
		free(trial); free(older); free(rest2); free(rest); free(mine); free(sofar); free(text);
	}
	for (int i = 0; i < un; i++) free(unames[i]);
	(void)ulen;

	if (good || ugood) {
		char *mine = user ? tree_names(user) : NULL;
		char *rest = mine ? without_trees(all, mine) : NULL;
		char *final = calloc(1, 1);
		size_t flen = 0;
		if (ugood && rest && final) {
			append(&final, &flen, user);
			append(&final, &flen, rest);
		} else if (final) {
			append(&final, &flen, all);
		}
		err[0] = '\0';
		if (!final || !bc_engine_trees(e, final, err, sizeof err))
			say("tree error: %s: %s (none loaded)", dir, err);
		else {
			say("trees loaded: %d file%s from %s", good, good == 1 ? "" : "s", dir);
			if (ugood) say("user trees loaded from %s: %s", userdir, loaded);
		}
		free(final); free(rest); free(mine);
	} else {
		say("no trees in %s", dir);
	}
	free(all);
	free(user);
	load_kinds(e, dir, userdir);
	return un > 0;
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
	/* the operator's trees are read again at each map: he edits a file
	 * and changes the map, and his bots have the new tree */
	if (s->user_trees || s->maps > 0) {
		struct stat st;
		char userdir[1024];
		if (s->o->user_trees) snprintf(userdir, sizeof userdir, "%s", s->o->user_trees);
		else snprintf(userdir, sizeof userdir, "%s/trees", getenv("LSD_DATA") && *getenv("LSD_DATA") ? getenv("LSD_DATA") : "/data");
		if (s->user_trees || (stat(userdir, &st) == 0 && S_ISDIR(st.st_mode)))
			s->user_trees = load_trees(s->e, s->o->trees, s->o->user_trees);
	}
	s->maps++;
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

/* The round time below which a share `q` of the window's rounds fell, ms. */
static double round_q(const session *s, double q)
{
	uint64_t want = (uint64_t)((double)s->rounds * q), seen = 0;
	int i;

	for (i = 0; i < ROUND_BUCKETS; i++) {
		seen += s->round_hist[i];
		if (seen > want)
			return (double)(i + 1) * 0.1;
	}
	return (double)ROUND_BUCKETS * 0.1;
}

static void health(session *s, double window)
{
	double r = s->rounds ? (double)s->rounds : 1;
	say("health: %.0f rounds/s, round mean %.2f p50 %.1f p99 %.1f worst %.2f ms, events %llu, actions %llu, "
	    "drops %llu, no-world %llu, bots %d",
	    (double)s->rounds / window, s->sum_round / r * 1e3, round_q(s, 0.5), round_q(s, 0.99), s->worst_round * 1e3,
	    (unsigned long long)s->events, (unsigned long long)s->actions,
	    (unsigned long long)s->drops, (unsigned long long)s->world_misses, s->bots);
	s->rounds = s->events = s->actions = s->drops = s->world_misses = 0;
	s->sum_round = s->worst_round = 0;
	memset(s->round_hist, 0, sizeof s->round_hist);
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
		{
			/* whoever asks what the bots think is answered here, between thinks */
			int watchers = botd_watch_round(&s->watch, s->e, start);
			if (watchers != s->watchers) {
				if (watchers) say("debug: %d request%s in %s: %s at %d a second", watchers, watchers == 1 ? "" : "s",
				                  s->watch.dir, s->watch.all ? "every bot watched" : "watching what they name", s->watch.hz);
				else say("debug: nobody watches any more");
				s->watchers = watchers;
			}
		}
		int bots = bc_engine_bots(s->e);
		if (bots != bots_was) {
			say("bots: %d -> %d", bots_was, bots);
			bots_was = s->bots = bots;
		}

		double end = now_s(), took = end - start;
		s->rounds++;
		s->sum_round += took;
		s->round_hist[took * 1e4 < ROUND_BUCKETS - 1 ? (int)(took * 1e4) : ROUND_BUCKETS - 1]++;
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
	bc_engine_plan_rate(s->e, s->o->plan_rate, s->o->hz);
	bc_engine_plan_runner(s->e, run_units, pool);
	s->user_trees = load_trees(s->e, s->o->trees, s->o->user_trees);
	{
		char dir[512];
		const char *data = getenv("LSD_DATA") && *getenv("LSD_DATA") ? getenv("LSD_DATA") : "/data";
		if (s->o->debug_dir) snprintf(dir, sizeof dir, "%s", s->o->debug_dir);
		else snprintf(dir, sizeof dir, "%s/rw/botdebug", data);
		botd_watch_init(&s->watch, dir);
		s->watchers = 0;
	}
	why = run_session(s);
	botd_watch_end(&s->watch, s->e);
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
	opts.threads = o->threads > 0 ? o->threads : botd_threads_auto();   /* 0: auto */
	if (!pool) {
		pool = botd_pool_new(opts.threads);
		if (!pool) { say("cannot make %d threads", opts.threads); return 1; }
		say("the planner on %d thread%s", botd_pool_threads(pool), botd_pool_threads(pool) == 1 ? "" : "s");
	}

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
