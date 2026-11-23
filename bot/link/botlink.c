/* botlink.c -- The file the server and the bot engine share
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * Implements botlink.h and nothing else. System calls: open, fstat (the
 * engine's attach only), ftruncate, mmap, munmap, close. No threads, no
 * sockets, no signals.
 *
 * MEMORY ORDER. The file is shared between two processes that may run
 * on a weakly ordered CPU (arm64), so every word one end uses to
 * publish something to the other is accessed with an explicit C11
 * order. The header's fields are plain uint32_t (the ffi must read
 * them), so they are reached through _Atomic uint32_t pointers: this is
 * the portable way to get acquire/release on them with <stdatomic.h>.
 * It relies on _Atomic uint32_t having the size, alignment and
 * representation of uint32_t, true of every compiler we ship with and
 * asserted below; it is also lock-free, which is what makes it valid
 * between processes.
 *   - seqlock (world.seq): the writer makes it odd, fences, writes,
 *     then releases the even value; the reader acquires it, copies,
 *     fences, and reads it again.
 *   - rings: the producer owns head and publishes with a release store
 *     after writing the bytes; the consumer owns tail and publishes it
 *     with a release store after reading the bytes. Each reads the
 *     other's word with acquire.
 */
#include "botlink.h"

#include <stdatomic.h>
#include <stddef.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

_Static_assert(sizeof(_Atomic uint32_t) == sizeof(uint32_t), "atomic u32 size");
_Static_assert(_Alignof(_Atomic uint32_t) == _Alignof(uint32_t), "atomic u32 align");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "atomics must be lock-free to cross processes");

_Static_assert(sizeof(bl_vec3) == 12, "bl_vec3");
_Static_assert(sizeof(bl_player) == 52, "bl_player");
_Static_assert(sizeof(bl_object) == 16, "bl_object");
_Static_assert(sizeof(bl_world) == 13408, "bl_world");
_Static_assert(sizeof(bl_intent) == 20, "bl_intent");
_Static_assert(sizeof(bl_record) == 4, "bl_record");
_Static_assert(sizeof(bl_ring) == 16 + BL_RING_BYTES, "bl_ring");
_Static_assert(sizeof(bl_header) == 32, "bl_header");
_Static_assert(sizeof(bl_file) == 32 + 13408 + 256 * 20 + 2 * (16 + BL_RING_BYTES), "bl_file");
_Static_assert((BL_RING_BYTES & (BL_RING_BYTES - 1)) == 0, "ring is a power of two");
_Static_assert(BL_RECORD_MAX <= 0xFFFF, "record size fits a uint16");

#define U32(p) ((_Atomic uint32_t *)(p))
#define MASK ((uint32_t)BL_RING_BYTES - 1u)

int bl_layout_ok(void)
{
	/* Hand-written expectations: a compiler that pads differently fails here. */
	return sizeof(bl_vec3) == 12
	    && sizeof(bl_player) == 52
	    && offsetof(bl_player, life) == 12
	    && offsetof(bl_player, pos) == 16
	    && offsetof(bl_player, ori) == 28
	    && offsetof(bl_player, vel) == 40
	    && sizeof(bl_object) == 16
	    && offsetof(bl_object, holder) == 12
	    && sizeof(bl_world) == 13408
	    && offsetof(bl_world, tick) == 4
	    && offsetof(bl_world, time) == 8
	    && offsetof(bl_world, map_seq) == 16
	    && offsetof(bl_world, night) == 20
	    && offsetof(bl_world, score) == 24
	    && offsetof(bl_world, max_score) == 28
	    && offsetof(bl_world, intel) == 32
	    && offsetof(bl_world, tent) == 64
	    && offsetof(bl_world, players) == 96
	    && sizeof(bl_intent) == 20
	    && offsetof(bl_intent, ori) == 8
	    && sizeof(bl_record) == 4
	    && offsetof(bl_record, type) == 2
	    && offsetof(bl_record, pid) == 3
	    && sizeof(bl_ring) == 16 + BL_RING_BYTES
	    && offsetof(bl_ring, dropped) == 8
	    && offsetof(bl_ring, data) == 16
	    && sizeof(bl_header) == 32
	    && offsetof(bl_header, engine_pid) == 20
	    && sizeof(bl_ev_map) == 4 + BL_PATH_MAX
	    && sizeof(bl_ev_block) == 12
	    && sizeof(bl_ev_line) == 20
	    && sizeof(bl_ev_kill) == 4
	    && sizeof(bl_ev_hurt) == 16
	    && sizeof(bl_ev_sound) == 16
	    && sizeof(bl_ev_grenade) == 28
	    && sizeof(bl_ev_ping) == 76
	    && sizeof(bl_ev_bot) == 8
	    && sizeof(bl_ev_order) == 20
	    && sizeof(bl_ac_block) == 8
	    && sizeof(bl_ac_line) == 12
	    && sizeof(bl_ac_grenade) == 16
	    && sizeof(bl_ac_ping) == 76
	    && offsetof(bl_ac_ping, reason) == 12
	    && offsetof(bl_file, world) == 32
	    && offsetof(bl_file, intents) == 32 + 13408
	    && offsetof(bl_file, events) == 32 + 13408 + 256 * 20
	    && offsetof(bl_file, actions) == 32 + 13408 + 256 * 20 + 16 + BL_RING_BYTES
	    && sizeof(bl_file) == 32 + 13408 + 256 * 20 + 2 * (16 + BL_RING_BYTES);
}

/* ------------------------------------------------------------------ */
/* The file                                                           */

bl_file *bl_create(const char *path)
{
	if (!bl_layout_ok()) return NULL;
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) return NULL;
	if (ftruncate(fd, (off_t)sizeof(bl_file)) != 0) { close(fd); return NULL; }
	void *m = mmap(NULL, sizeof(bl_file), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	close(fd);
	if (m == MAP_FAILED) return NULL;
	bl_file *f = m;
	memset(f, 0, sizeof *f);
	f->header.version = BL_VERSION;
	f->header.size = (uint32_t)sizeof(bl_file);
	/* The magic goes last, released: an engine that sees it sees the rest. */
	atomic_store_explicit(U32(&f->header.magic), (uint32_t)BL_MAGIC, memory_order_release);
	return f;
}

bl_file *bl_attach(const char *path)
{
	if (!bl_layout_ok()) return NULL;
	int fd = open(path, O_RDWR);
	if (fd < 0) return NULL;
	struct stat st;
	if (fstat(fd, &st) != 0 || st.st_size != (off_t)sizeof(bl_file)) { close(fd); return NULL; }
	void *m = mmap(NULL, sizeof(bl_file), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	close(fd);
	if (m == MAP_FAILED) return NULL;
	bl_file *f = m;
	if (atomic_load_explicit(U32(&f->header.magic), memory_order_acquire) != (uint32_t)BL_MAGIC
	    || f->header.version != BL_VERSION
	    || f->header.size != sizeof(bl_file)) {
		munmap(m, sizeof(bl_file));
		return NULL;
	}
	return f;
}

void bl_close(bl_file *f)
{
	if (f) munmap(f, sizeof(bl_file));
}

/* ------------------------------------------------------------------ */
/* The world's seqlock                                                */

void bl_world_begin(bl_file *f)
{
	uint32_t s = atomic_load_explicit(U32(&f->world.seq), memory_order_relaxed);
	atomic_store_explicit(U32(&f->world.seq), s + 1, memory_order_relaxed);
	/* The odd value must be visible before any byte of the new world. */
	atomic_thread_fence(memory_order_release);
}

void bl_world_end(bl_file *f)
{
	uint32_t s = atomic_load_explicit(U32(&f->world.seq), memory_order_relaxed);
	/* Release: every byte written since begin is visible before the even value. */
	atomic_store_explicit(U32(&f->world.seq), s + 1, memory_order_release);
}

int bl_world_read(const bl_file *f, bl_world *out, int tries)
{
	for (int i = 0; i < tries; i++) {
		uint32_t s1 = atomic_load_explicit(U32(&f->world.seq), memory_order_acquire);
		if (s1 & 1u) continue;
		memcpy(out, &f->world, sizeof *out);
		/* The copy must be done before the second look at seq. */
		atomic_thread_fence(memory_order_acquire);
		uint32_t s2 = atomic_load_explicit(U32(&f->world.seq), memory_order_relaxed);
		if (s1 == s2) { out->seq = s1; return 1; }
	}
	return 0;
}

/* ------------------------------------------------------------------ */
/* The rings                                                          */

int bl_push(bl_ring *r, uint8_t type, uint8_t pid, const void *payload, uint32_t bytes)
{
	if (bytes > (uint32_t)BL_RECORD_MAX - 4 || (bytes && !payload)) return 0;
	uint32_t need = 4 + bytes;
	uint32_t head = atomic_load_explicit(U32(&r->head), memory_order_relaxed);
	uint32_t tail = atomic_load_explicit(U32(&r->tail), memory_order_acquire);
	uint32_t room = (uint32_t)BL_RING_BYTES - (head - tail);
	uint32_t pos = head & MASK;
	uint32_t toend = (uint32_t)BL_RING_BYTES - pos;
	uint32_t pad = toend < need ? toend : 0;  /* a record never straddles the end */

	if (room < pad + need || head - tail > (uint32_t)BL_RING_BYTES) {
		uint32_t d = atomic_load_explicit(U32(&r->dropped), memory_order_relaxed);
		atomic_store_explicit(U32(&r->dropped), d + 1, memory_order_relaxed);
		return 0;
	}
	if (pad) {
		/* Fewer than 4 bytes left: no header fits, the reader skips blind. */
		if (pad >= 4) {
			bl_record p = { 0, 0, 0 };
			memcpy(r->data + pos, &p, sizeof p);
		}
		head += pad;
		pos = 0;
	}
	bl_record h = { (uint16_t)need, type, pid };
	memcpy(r->data + pos, &h, sizeof h);
	if (bytes) memcpy(r->data + pos + 4, payload, bytes);
	atomic_store_explicit(U32(&r->head), head + need, memory_order_release);
	return 1;
}

uint32_t bl_pop(bl_ring *r, void *buf)
{
	uint32_t tail = atomic_load_explicit(U32(&r->tail), memory_order_relaxed);
	uint32_t head = atomic_load_explicit(U32(&r->head), memory_order_acquire);
	for (;;) {
		uint32_t avail = head - tail;
		if (avail == 0) return 0;
		if (avail > (uint32_t)BL_RING_BYTES) goto corrupt;
		uint32_t pos = tail & MASK;
		uint32_t toend = (uint32_t)BL_RING_BYTES - pos;
		if (toend < 4) {            /* too small for a header: the writer skipped it */
			if (avail < toend) goto corrupt;
			tail += toend;
			atomic_store_explicit(U32(&r->tail), tail, memory_order_release);
			continue;
		}
		bl_record h;
		memcpy(&h, r->data + pos, sizeof h);
		if (h.size == 0) {          /* a pad to the end */
			if (avail < toend) goto corrupt;
			tail += toend;
			atomic_store_explicit(U32(&r->tail), tail, memory_order_release);
			continue;
		}
		if (h.size < 4 || h.size > BL_RECORD_MAX || h.size > toend || h.size > avail)
			goto corrupt;
		memcpy(buf, r->data + pos, h.size);
		atomic_store_explicit(U32(&r->tail), tail + h.size, memory_order_release);
		return h.size;
	}
corrupt:
	/* Nothing in here can be trusted: drop it all and start again from head. */
	atomic_store_explicit(U32(&r->tail), head, memory_order_release);
	return 0;
}

/* ------------------------------------------------------------------ */
/* Beats                                                              */

void bl_beat_server(bl_file *f)
{
	uint32_t b = atomic_load_explicit(U32(&f->header.server_beat), memory_order_relaxed);
	atomic_store_explicit(U32(&f->header.server_beat), b + 1, memory_order_relaxed);
}

void bl_beat_engine(bl_file *f)
{
	uint32_t b = atomic_load_explicit(U32(&f->header.engine_beat), memory_order_relaxed);
	atomic_store_explicit(U32(&f->header.engine_beat), b + 1, memory_order_relaxed);
}

int bl_alive(uint32_t beat_now, uint32_t *last)
{
	int moved = beat_now != *last;
	*last = beat_now;
	return moved;
}
