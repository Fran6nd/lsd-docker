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
	int hz;                 /* rounds a second (default 60) */
	int budget;             /* planner expansions a think may spend (default 3000) */
	int max_bots;           /* bots the engine is sized for (default 64) */
	int once;               /* 1: do not wait for a file, exit 1 if there is none */
	int poll_ms;            /* wait between attach tries (default 1000) */
	int stale_ms;           /* server beat unmoved this long: it is gone (default 5000) */
	int health_s;           /* seconds between health lines (default 60) */
} botd_opts;

void botd_opts_default(botd_opts *o);

/* Runs until the server goes, closes the link, or SIGTERM/SIGINT (which
 * it installs handlers for). 0 for a clean stop; 1 when --once found no
 * file. */
int botd_run(const botd_opts *o);

/* Ask botd_run to stop, from a signal handler or another thread. */
void botd_stop(void);

#endif
