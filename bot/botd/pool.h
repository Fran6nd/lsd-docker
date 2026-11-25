/* pool.h -- botd's threads: a batch of independent jobs, run at once
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * The core has no threads (README.md); the host may, and this is all of
 * them. A POOL is the calling thread and threads - 1 workers. botd_pool_run
 * hands them a batch -- jobs 0 .. n-1 of one function over one context --
 * and returns when every job has run. Which thread runs which job, and in
 * what order, is not said: a batch must be jobs that are independent of
 * each other (each writes only what is its own, reads only what no job
 * writes). The planner's units are such jobs (core/engine.h, THE PLANNER'S
 * WORK AS UNITS), and the core applies their results itself afterwards, in
 * its own order, so the outcome does not depend on the pool at all.
 *
 * The workers sleep between batches (a condition variable, not a spin): a
 * think hands over a batch or two, and 60 thinks a second must not keep
 * cores busy waiting. A pool of 1, or a batch of one job, runs on the
 * calling thread without waking anybody.
 */
#ifndef BOTD_POOL_H
#define BOTD_POOL_H

typedef struct botd_pool botd_pool;

/* `threads` in all, the caller's included (1: no worker). NULL if the
 * threads cannot be made. */
botd_pool *botd_pool_new(int threads);
void botd_pool_free(botd_pool *p);
int botd_pool_threads(const botd_pool *p);

/* fn(ctx, i) for every i in 0 .. n-1; returns when all have returned. */
void botd_pool_run(botd_pool *p, void (*fn)(void *ctx, int i), void *ctx, int n);

#endif
