/* pool.c -- pool.h: botd's threads
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * One batch at a time. The batch (fn, ctx, n) is written under the mutex
 * before the workers are woken and read by them under it, and each worker
 * says it is done under it: whatever a job wrote is seen by the caller
 * when botd_pool_run returns. Jobs are taken by an atomic counter, the
 * only thing the threads share while they work.
 */
#include "pool.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>

struct botd_pool {
	int threads;
	pthread_t *tid;
	pthread_mutex_t mu;
	pthread_cond_t go, done;
	unsigned long gen;          /* batches handed out */
	int stop;
	int busy;                   /* workers still in the batch */
	void (*fn)(void *ctx, int i);
	void *ctx;
	int n;
	atomic_int next;
};

static void take(botd_pool *p)
{
	for (;;) {
		int i = atomic_fetch_add_explicit(&p->next, 1, memory_order_relaxed);

		if (i >= p->n)
			return;
		p->fn(p->ctx, i);
	}
}

static void *worker(void *arg)
{
	botd_pool *p = arg;
	unsigned long seen = 0;

	pthread_mutex_lock(&p->mu);
	for (;;) {
		while (!p->stop && p->gen == seen)
			pthread_cond_wait(&p->go, &p->mu);
		if (p->stop)
			break;
		seen = p->gen;
		pthread_mutex_unlock(&p->mu);
		take(p);
		pthread_mutex_lock(&p->mu);
		if (--p->busy == 0)
			pthread_cond_signal(&p->done);
	}
	pthread_mutex_unlock(&p->mu);
	return NULL;
}

botd_pool *botd_pool_new(int threads)
{
	botd_pool *p = calloc(1, sizeof *p);
	int i;

	if (!p)
		return NULL;
	if (threads < 1)
		threads = 1;
	p->threads = 1;
	atomic_init(&p->next, 0);
	pthread_mutex_init(&p->mu, NULL);
	pthread_cond_init(&p->go, NULL);
	pthread_cond_init(&p->done, NULL);
	p->tid = calloc((size_t)threads, sizeof *p->tid);
	if (!p->tid) {
		botd_pool_free(p);
		return NULL;
	}
	for (i = 1; i < threads; i++) {
		if (pthread_create(&p->tid[i - 1], NULL, worker, p) != 0) {
			botd_pool_free(p);
			return NULL;
		}
		p->threads++;
	}
	return p;
}

void botd_pool_free(botd_pool *p)
{
	int i;

	if (!p)
		return;
	pthread_mutex_lock(&p->mu);
	p->stop = 1;
	pthread_cond_broadcast(&p->go);
	pthread_mutex_unlock(&p->mu);
	for (i = 0; i < p->threads - 1; i++)
		pthread_join(p->tid[i], NULL);
	pthread_cond_destroy(&p->go);
	pthread_cond_destroy(&p->done);
	pthread_mutex_destroy(&p->mu);
	free(p->tid);
	free(p);
}

int botd_pool_threads(const botd_pool *p)
{
	return p ? p->threads : 1;
}

void botd_pool_run(botd_pool *p, void (*fn)(void *ctx, int i), void *ctx, int n)
{
	int i;

	if (!p || p->threads <= 1 || n <= 1) {
		for (i = 0; i < n; i++)
			fn(ctx, i);
		return;
	}
	pthread_mutex_lock(&p->mu);
	p->fn = fn;
	p->ctx = ctx;
	p->n = n;
	atomic_store_explicit(&p->next, 0, memory_order_relaxed);
	p->busy = p->threads - 1;
	p->gen++;
	pthread_cond_broadcast(&p->go);
	pthread_mutex_unlock(&p->mu);
	take(p);
	pthread_mutex_lock(&p->mu);
	while (p->busy > 0)
		pthread_cond_wait(&p->done, &p->mu);
	pthread_mutex_unlock(&p->mu);
}
