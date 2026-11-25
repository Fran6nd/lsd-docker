/* botd.h -- the host process of the bot engine
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * botd waits for the server's link file, attaches, and runs the core
 * (engine.h) against it at a fixed rate until the server goes. main.c is
 * only the command line; everything else is botd_run, which the test
 * calls with a fake engine behind it.
 */
#ifndef BOTD_H
#define BOTD_H

typedef struct botd_opts {
	const char *file;       /* the link file (default /dev/shm/lsd-botlink) */
	const char *trees;      /* a directory of *.bt; NULL: /opt/botd/trees, then ./trees */
	const char *user_trees; /* the operator's own *.bt, over those; NULL: $LSD_DATA/trees (LSD_DATA: /data) */
	int hz;                 /* rounds a second (default 60) */
	int budget;             /* planner expansions a think may always spend (default 3000) */
	int plan_rate;          /* and each bot's share, expansions a second (BC_PLAN_RATE) */
	int max_bots;           /* bots the engine is sized for (default 255: every seat) */
	int threads;            /* the planner's threads, botd's own included (pool.h);
	                           1 (the default): botd's own alone; 0: botd_threads_auto() */
	int once;               /* 1: do not wait for a file, exit 1 if there is none */
	int poll_ms;            /* wait between attach tries (default 1000) */
	int stale_ms;           /* server beat unmoved this long: it is gone (default 5000) */
	int health_s;           /* seconds between health lines (default 60) */
	const char *debug_dir;  /* where a viewer asks what the bots think, and is answered (watch.c);
	                           NULL: $LSD_DATA/rw/botdebug (LSD_DATA: /data); "none": nowhere */
} botd_opts;

void botd_opts_default(botd_opts *o);

/* --threads 0 (1 is the default): as many as the planner can use at once (a think plans at
 * most four routes at a time: core/brain.h BC_SEARCH_MAX), but never more
 * than half the cores there are, the server being on the same machine. */
int botd_threads_auto(void);

/* Runs until the server goes, closes the link, or SIGTERM/SIGINT (which
 * it installs handlers for). 0 for a clean stop; 1 when --once found no
 * file. */
int botd_run(const botd_opts *o);

/* Ask botd_run to stop, from a signal handler or another thread. */
void botd_stop(void);

/* The debug channel (watch.c): requests read from a directory, the
 * engine's answers written there. One of these a session. */
struct bc_engine;
typedef struct botd_watch {
	char dir[512];              /* "": there is none */
	double next_look, next_roster, next_snap;
	int live;                   /* requests alive at the last look */
	int hz, all;                /* what they ask, summed */
	unsigned char want[256];
	unsigned char on[256];      /* bots whose snapshot file is there */
	char *buf;
	unsigned long cap, written;
} botd_watch;

void botd_watch_init(botd_watch *w, const char *dir);
/* Once a round, with the host's clock (seconds). Cheap when nobody
 * asks. Returns how many requests are alive. */
int botd_watch_round(botd_watch *w, struct bc_engine *e, double now);
/* The session is over: nobody is watched, the files are gone. */
void botd_watch_end(botd_watch *w, struct bc_engine *e);

#endif
