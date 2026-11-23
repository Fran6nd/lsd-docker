/* link_test.c -- botlink: layout, file, world seqlock, rings.
 * `link_test --sizes` prints "name size" lines for link_ffi_test.lua. */
#include "botlink.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; \
	printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static double now(void)
{
	struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static char tmp[256];
static const char *tmppath(const char *name)
{
	const char *d = getenv("TMPDIR");
	snprintf(tmp, sizeof tmp, "%s/botlink_test_%d_%s", d ? d : "/tmp", (int)getpid(), name);
	return tmp;
}

/* ---- layout and the file ---- */

static void test_file(void)
{
	CHECK(bl_layout_ok() == 1);
	char path[256];
	snprintf(path, sizeof path, "%s", tmppath("file"));
	bl_file *s = bl_create(path);
	CHECK(s != NULL);
	if (!s) return;
	CHECK(s->header.magic == BL_MAGIC && s->header.version == BL_VERSION);
	CHECK(s->header.size == sizeof(bl_file));
	bl_file *e = bl_attach(path);
	CHECK(e != NULL);
	if (e) {
		CHECK(e != s);
		s->world.tick = 1234;
		CHECK(e->world.tick == 1234);
		e->intents[7].keys = 0x55;
		CHECK(s->intents[7].keys == 0x55);
		uint32_t last = 0;
		bl_beat_server(s);
		CHECK(bl_alive(e->header.server_beat, &last) == 1);
		CHECK(bl_alive(e->header.server_beat, &last) == 0);
		bl_beat_server(s);
		CHECK(bl_alive(e->header.server_beat, &last) == 1);
		bl_beat_engine(e);
		CHECK(s->header.engine_beat == 1);
		bl_close(e);
	}
	/* wrong magic, version, size */
	s->header.magic = 0;
	CHECK(bl_attach(path) == NULL);
	s->header.magic = BL_MAGIC;
	s->header.version = BL_VERSION + 1;
	CHECK(bl_attach(path) == NULL);
	s->header.version = BL_VERSION;
	s->header.size = 5;
	CHECK(bl_attach(path) == NULL);
	s->header.size = sizeof(bl_file);
	CHECK((e = bl_attach(path)) != NULL);
	bl_close(e);
	bl_close(s);
	/* wrong file size */
	int fd = open(path, O_RDWR);
	CHECK(fd >= 0 && ftruncate(fd, 1000) == 0);
	close(fd);
	CHECK(bl_attach(path) == NULL);
	unlink(path);
	CHECK(bl_attach(path) == NULL);   /* no file */
	/* create truncates what a dead server left */
	s = bl_create(path);
	CHECK(s != NULL);
	bl_close(s);
	unlink(path);
}

/* ---- world seqlock ---- */

static bl_file *W;
static atomic_int stop;

static void fill(bl_world *w, uint32_t n)
{
	w->tick = n;
	w->time = (double)n;
	w->map_seq = n;
	w->score[0] = (uint16_t)n; w->score[1] = (uint16_t)n;
	w->max_score = (uint16_t)n;
	for (int i = 0; i < 2; i++) { w->intel[i].pos.x = (float)(n & 0xFFFF); w->tent[i].pos.z = (float)(n & 0xFFFF); }
	for (int i = 0; i < BL_MAX_PLAYERS; i++) {
		w->players[i].life = n;
		w->players[i].pos.x = (float)(n & 0xFFFF);
		w->players[i].vel.z = (float)(n & 0xFFFF);
		w->players[i].hp = (uint8_t)n;
	}
}

static int consistent(const bl_world *w)
{
	uint32_t n = w->tick;
	if (w->time != (double)n || w->map_seq != n) return 0;
	if (w->score[0] != (uint16_t)n || w->score[1] != (uint16_t)n || w->max_score != (uint16_t)n) return 0;
	for (int i = 0; i < 2; i++)
		if (w->intel[i].pos.x != (float)(n & 0xFFFF) || w->tent[i].pos.z != (float)(n & 0xFFFF)) return 0;
	for (int i = 0; i < BL_MAX_PLAYERS; i++)
		if (w->players[i].life != n || w->players[i].pos.x != (float)(n & 0xFFFF)
		    || w->players[i].vel.z != (float)(n & 0xFFFF) || w->players[i].hp != (uint8_t)n) return 0;
	return 1;
}

static void *world_writer(void *arg)
{
	(void)arg;
	for (uint32_t n = 1; !atomic_load(&stop); n++) {
		bl_world_begin(W);
		fill(&W->world, n);
		bl_world_end(W);
		struct timespec d = { 0, 20000 };   /* the server writes once a tick, not flat out */
		nanosleep(&d, NULL);
	}
	return NULL;
}

static void test_world(void)
{
	char path[256];
	snprintf(path, sizeof path, "%s", tmppath("world"));
	W = bl_create(path);
	CHECK(W != NULL);
	if (!W) return;
	bl_world w;
	CHECK(bl_world_read(W, &w, 3) == 1);   /* quiescent: seq 0 */
	bl_world_begin(W);
	CHECK(bl_world_read(W, &w, 5) == 0);   /* odd all through */
	bl_world_end(W);
	CHECK(bl_world_read(W, &w, 1) == 1 && w.seq == 2);

	atomic_store(&stop, 0);
	pthread_t t;
	CHECK(pthread_create(&t, NULL, world_writer, NULL) == 0);
	long good = 0, bad = 0, gaveup = 0;
	uint32_t lastn = 0;
	int backwards = 0;
	double end = now() + 0.25;
	while (now() < end) {
		for (int k = 0; k < 200; k++) {
			if (bl_world_read(W, &w, 1000)) {
				if (consistent(&w)) good++; else bad++;
				if (w.tick < lastn) backwards = 1;
				lastn = w.tick;
			} else gaveup++;
		}
	}
	atomic_store(&stop, 1);
	pthread_join(t, NULL);
	printf("   world: %ld good reads, %ld mixed, %ld gave up, last tick %u\n", good, bad, gaveup, lastn);
	CHECK(bad == 0);
	CHECK(good > 1000);
	CHECK(!backwards);
	CHECK(lastn > 500);
	bl_close(W);
	unlink(path);
}

/* ---- rings ---- */

static bl_ring *new_ring(void)
{
	bl_ring *r = calloc(1, sizeof *r);
	if (!r) { puts("out of memory"); exit(2); }
	return r;
}

static void test_ring_basic(void)
{
	bl_ring *r = new_ring();
	uint8_t buf[BL_RECORD_MAX];
	CHECK(bl_pop(r, buf) == 0);
	uint8_t pl[100];
	for (int i = 0; i < 100; i++) pl[i] = (uint8_t)(i * 7 + 1);
	CHECK(bl_push(r, 9, 3, pl, 100) == 1);
	CHECK(bl_push(r, 10, BL_NO_PLAYER, NULL, 0) == 1);
	CHECK(bl_push(r, 11, 1, pl, 1) == 1);
	uint32_t n = bl_pop(r, buf);
	CHECK(n == 104);
	bl_record h; memcpy(&h, buf, 4);
	CHECK(h.size == 104 && h.type == 9 && h.pid == 3);
	CHECK(memcmp(buf + 4, pl, 100) == 0);
	n = bl_pop(r, buf); memcpy(&h, buf, 4);
	CHECK(n == 4 && h.type == 10 && h.pid == BL_NO_PLAYER);
	n = bl_pop(r, buf); memcpy(&h, buf, 4);
	CHECK(n == 5 && h.type == 11 && buf[4] == pl[0]);
	CHECK(bl_pop(r, buf) == 0);

	/* limits */
	uint8_t big[BL_RECORD_MAX];
	memset(big, 0xAB, sizeof big);
	CHECK(bl_push(r, 1, 0, big, BL_RECORD_MAX - 3) == 0);
	CHECK(r->dropped == 0);                       /* refused, not a drop */
	CHECK(bl_push(r, 1, 0, big, BL_RECORD_MAX - 4) == 1);
	CHECK(bl_pop(r, buf) == BL_RECORD_MAX);
	CHECK(memcmp(buf + 4, big, BL_RECORD_MAX - 4) == 0);
	free(r);
}

/* Push one record of `bytes` filled with a pattern; check pop. */
static int push_pat(bl_ring *r, uint32_t bytes, uint8_t seed)
{
	uint8_t p[BL_RECORD_MAX];
	for (uint32_t i = 0; i < bytes; i++) p[i] = (uint8_t)(seed + i);
	return bl_push(r, seed, seed, p, bytes);
}
static int pop_pat(bl_ring *r, uint32_t bytes, uint8_t seed)
{
	uint8_t b[BL_RECORD_MAX];
	if (bl_pop(r, b) != 4 + bytes) return 0;
	if (b[2] != seed || b[3] != seed) return 0;
	for (uint32_t i = 0; i < bytes; i++) if (b[4 + i] != (uint8_t)(seed + i)) return 0;
	return 1;
}

/* Start the counters at `start` (both ends agree), then push/pop records
 * of odd sizes so that the end of the ring is crossed many times. */
static void ring_wrap_run(uint32_t start, int rounds)
{
	bl_ring *r = new_ring();
	r->head = r->tail = start;
	int ok = 1;
	for (int i = 0; i < rounds && ok; i++) {
		uint32_t bytes = (uint32_t)((i * 37) % (BL_RECORD_MAX - 3));
		uint8_t seed = (uint8_t)i;
		ok = push_pat(r, bytes, seed) && pop_pat(r, bytes, seed);
	}
	CHECK(ok);
	CHECK(r->head == r->tail);
	CHECK(r->dropped == 0);
	free(r);
}

static void test_ring_wrap(void)
{
	/* the end of the ring: a pad of >= 4 bytes */
	bl_ring *r = new_ring();
	r->head = r->tail = BL_RING_BYTES - 100;
	CHECK(push_pat(r, 36, 1));      /* 40 bytes: 60 left */
	CHECK(push_pat(r, 64, 2));      /* 68 bytes: does not fit in 60 -> pad 60, record at 0 */
	CHECK(r->head == (uint32_t)(BL_RING_BYTES - 100 + 40 + 60 + 68));
	CHECK(pop_pat(r, 36, 1));
	CHECK(pop_pat(r, 64, 2));
	CHECK(r->head == r->tail);
	free(r);

	/* the end of the ring: fewer than 4 bytes left, no header written */
	r = new_ring();
	r->head = r->tail = BL_RING_BYTES - 3;
	memset(r->data + BL_RING_BYTES - 3, 0xEE, 3);
	CHECK(push_pat(r, 6, 5));       /* 10 bytes, 3 left: pad 3 */
	CHECK(r->head == (uint32_t)(BL_RING_BYTES - 3 + 3 + 10));
	CHECK(pop_pat(r, 6, 5));
	CHECK(r->head == r->tail);
	free(r);

	/* exactly at the end: pos 0 after the push, no pad */
	r = new_ring();
	r->head = r->tail = BL_RING_BYTES - 40;
	CHECK(push_pat(r, 36, 3));
	CHECK(r->head == 0u + BL_RING_BYTES);
	CHECK(pop_pat(r, 36, 3));
	free(r);

	/* counters wrapping past UINT32_MAX */
	ring_wrap_run(0, 5000);
	ring_wrap_run(0xFFFFFFFFu - 5000, 5000);
	ring_wrap_run(0xFFFFFFFFu - 3, 3000);
	ring_wrap_run(0xFFFFFFFFu - 1, 100);
	ring_wrap_run(0u - (uint32_t)BL_RING_BYTES, 2000);

	/* full ring across the counters' wrap */
	r = new_ring();
	r->head = r->tail = 0xFFFFFFFFu - 100;
	int pushed = 0;
	while (push_pat(r, 60, (uint8_t)pushed)) pushed++;
	CHECK(pushed > 1000);
	CHECK(r->dropped == 1);
	CHECK(r->head - r->tail <= (uint32_t)BL_RING_BYTES);
	CHECK(r->head < r->tail);       /* head has wrapped, tail has not */
	int popped = 0, okp = 1;
	for (;;) {
		uint8_t b[BL_RECORD_MAX];
		uint32_t n = bl_pop(r, b);
		if (!n) break;
		okp = okp && n == 64 && b[2] == (uint8_t)popped;
		popped++;
	}
	CHECK(okp && popped == pushed);
	free(r);
}

static void test_ring_full(void)
{
	bl_ring *r = new_ring();
	int pushed = 0;
	while (push_pat(r, 28, (uint8_t)pushed)) pushed++;   /* 32-byte records */
	CHECK(pushed == BL_RING_BYTES / 32);
	CHECK(r->dropped == 1);
	CHECK(push_pat(r, 28, 0) == 0);
	CHECK(r->dropped == 2);
	for (int i = 0; i < pushed; i++) if (!pop_pat(r, 28, (uint8_t)i)) { CHECK(0); break; }
	CHECK(bl_pop(r, r->data) == 0);
	CHECK(push_pat(r, 28, 7) == 1);   /* room again */
	CHECK(r->dropped == 2);           /* the count is kept */
	free(r);
}

static void test_ring_corrupt(void)
{
	uint8_t b[BL_RECORD_MAX];
	uint16_t bad[] = { 1, 2, 3, 1025, 5000, 0xFFFF };
	for (unsigned i = 0; i < sizeof bad / sizeof *bad; i++) {
		bl_ring *r = new_ring();
		CHECK(push_pat(r, 20, 1) && push_pat(r, 20, 2));
		memcpy(r->data, &bad[i], 2);
		CHECK(bl_pop(r, b) == 0);
		CHECK(r->tail == r->head);            /* resynchronised */
		CHECK(push_pat(r, 10, 9) && pop_pat(r, 10, 9));
		free(r);
	}
	/* a size that runs past the end of the ring */
	bl_ring *r = new_ring();
	r->head = r->tail = BL_RING_BYTES - 16;
	uint16_t sz = 40;
	memcpy(r->data + BL_RING_BYTES - 16, &sz, 2);
	r->head += 100;
	CHECK(bl_pop(r, b) == 0 && r->tail == r->head);
	/* a size larger than what has been written */
	r->head = r->tail = 0;
	sz = 200; memcpy(r->data, &sz, 2);
	r->head = 50;
	CHECK(bl_pop(r, b) == 0 && r->tail == r->head);
	/* a head that claims more than the ring holds */
	r->head = r->tail + BL_RING_BYTES + 5;
	CHECK(bl_pop(r, b) == 0 && r->tail == r->head);
	/* random garbage never crashes and always ends */
	srand(1);
	for (int k = 0; k < 200; k++) {
		for (size_t i = 0; i < BL_RING_BYTES; i++) r->data[i] = (uint8_t)rand();
		r->tail = (uint32_t)rand() * 7u; r->head = r->tail + (uint32_t)(rand() % (2 * BL_RING_BYTES));
		int n = 0;
		while (bl_pop(r, b) && n < 1000000) n++;
		CHECK(n < 1000000);
	}
	free(r);
}

/* ---- two-thread stress ---- */

static bl_ring *SR;
#define STRESS_N 400000

static uint32_t mix(uint32_t x) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x; }

static void *producer(void *arg)
{
	(void)arg;
	uint32_t st = 12345;
	uint8_t p[BL_RECORD_MAX - 4];
	for (uint32_t i = 0; i < STRESS_N; ) {
		st = mix(st);
		uint32_t len = 5 + st % (BL_RECORD_MAX - 4 - 5 + 1);   /* 5 .. max payload */
		uint32_t g = st;
		for (uint32_t k = 4; k < len; k++) { g = mix(g); p[k] = (uint8_t)g; }
		memcpy(p, &i, 4);                     /* the index first, a checksum last */
		uint32_t sum = 0;
		for (uint32_t k = 0; k + 1 < len; k++) sum += p[k];
		p[len - 1] = (uint8_t)sum;
		if (bl_push(SR, 1, (uint8_t)i, p, len)) i++;   /* full: try again */
	}
	return NULL;
}

static void *consumer(void *arg)
{
	long *bad = arg;
	uint8_t b[BL_RECORD_MAX];
	for (uint32_t i = 0; i < STRESS_N; ) {
		uint32_t n = bl_pop(SR, b);
		if (!n) continue;
		uint32_t len = n - 4, idx;
		memcpy(&idx, b + 4, 4);
		uint32_t sum = 0;
		for (uint32_t k = 0; k + 1 < len; k++) sum += b[4 + k];
		if (idx != i || b[3] != (uint8_t)i || b[4 + len - 1] != (uint8_t)sum) (*bad)++;
		i++;
	}
	return NULL;
}

static void test_ring_stress(void)
{
	SR = new_ring();
	SR->head = SR->tail = 0xFFFFFFFFu - 50000;    /* the counters wrap mid-run */
	pthread_t p, c;
	long bad = 0;
	double t0 = now();
	CHECK(pthread_create(&c, NULL, consumer, &bad) == 0);
	CHECK(pthread_create(&p, NULL, producer, NULL) == 0);
	pthread_join(p, NULL);
	pthread_join(c, NULL);
	printf("   stress: %d records in %.0f ms, %ld bad, %u drops (retried)\n",
	       STRESS_N, (now() - t0) * 1000, bad, SR->dropped);
	CHECK(bad == 0);
	CHECK(SR->head == SR->tail);
	free(SR);
}

static void print_sizes(void)
{
#define S(t) printf("%s %zu\n", #t, sizeof(t))
	S(bl_vec3); S(bl_player); S(bl_object); S(bl_world); S(bl_intent);
	S(bl_record); S(bl_ring); S(bl_header); S(bl_file);
	S(bl_ev_map); S(bl_ev_block); S(bl_ev_line); S(bl_ev_kill); S(bl_ev_hurt);
	S(bl_ev_sound); S(bl_ev_grenade); S(bl_ev_ping); S(bl_ev_bot); S(bl_ev_order);
	S(bl_ac_block); S(bl_ac_line); S(bl_ac_grenade); S(bl_ac_ping);
}

int main(int argc, char **argv)
{
	if (argc > 1 && !strcmp(argv[1], "--sizes")) { print_sizes(); return 0; }
	test_file();
	test_world();
	test_ring_basic();
	test_ring_wrap();
	test_ring_full();
	test_ring_corrupt();
	test_ring_stress();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
