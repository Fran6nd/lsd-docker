/* kv6_test.c -- the voxel model reader (core/kv6.h): the structures that
 * ship (the .kv6 files of bot/structures, written by tools/mkstructures.py) read
 * whole and stand on the ground; a hollow box comes back full; and what
 * is not a KV6 file is refused with the reason. */
#include "kv6.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

/* ------------------------------------------------------------------ */
/* Writing one, as the format has it                                  */

/* the header and a block, in bytes; and the most a test file is read to
 * (the structures are a few hundred bytes) */
enum { HEAD = 32, BLOCK = 8, MAX_BYTES = 1 << 16 };

static void put32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }
static void put16(uint8_t *p, unsigned v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }

typedef struct cell { int x, y, z; uint32_t rgb; } cell;

/* The file of `n` voxels, given x major, then y, z rising -- the order the
 * format lists them in. Returns its length. */
static size_t write_kv6(uint8_t *out, int xs, int ys, int zs, const cell *c, int n)
{
	size_t blocks = HEAD, xoff = blocks + (size_t)n * BLOCK, xy = xoff + (size_t)xs * 4;
	int i;

	memset(out, 0, xy + (size_t)xs * ys * 2);
	memcpy(out, "Kvxl", 4);
	put32(out + 4, (uint32_t)xs);
	put32(out + 8, (uint32_t)ys);
	put32(out + 12, (uint32_t)zs);
	{
		float pv[3] = { xs / 2.0f, ys / 2.0f, (float)zs };
		uint32_t u;
		for (i = 0; i < 3; i++) { memcpy(&u, &pv[i], 4); put32(out + 16 + 4 * i, u); }
	}
	put32(out + 28, (uint32_t)n);
	for (i = 0; i < n; i++) {
		uint8_t *b = out + blocks + (size_t)i * BLOCK;
		size_t col = xy + 2 * ((size_t)c[i].x * ys + (size_t)c[i].y);

		b[0] = (uint8_t)c[i].rgb;               /* B, G, R, 128 */
		b[1] = (uint8_t)(c[i].rgb >> 8);
		b[2] = (uint8_t)(c[i].rgb >> 16);
		b[3] = 128;
		put16(b + 4, (unsigned)c[i].z);
		b[6] = 0x3f;
		put16(out + col, (unsigned)(out[col] | out[col + 1] << 8) + 1);
	}
	for (i = 0; i < xs; i++) {
		int k, in_slice = 0;
		for (k = 0; k < n; k++) in_slice += c[k].x == i;
		put32(out + xoff + 4 * (size_t)i, (uint32_t)in_slice);
	}
	return xy + (size_t)xs * ys * 2;
}

/* ------------------------------------------------------------------ */
/* Looking at one                                                     */

static int at(const bc_kv6 *m, int x, int y, int z, uint32_t *rgb)
{
	int i;

	for (i = 0; i < m->n; i++)
		if (m->v[i].x == x && m->v[i].y == y && m->v[i].z == z) {
			if (rgb) *rgb = m->v[i].rgb;
			return 1;
		}
	return 0;
}

/* z falling, then y, then x rising: each voxel after the one before */
static int ordered(const bc_kv6 *m)
{
	int i;

	for (i = 1; i < m->n; i++) {
		const bc_kv6_voxel *a = &m->v[i - 1], *b = &m->v[i];
		if (a->z != b->z) { if (a->z < b->z) return 0; }
		else if (a->y != b->y) { if (a->y > b->y) return 0; }
		else if (a->x >= b->x) return 0;
	}
	return 1;
}

/* How many voxels a flood from the bottom layer, face to face, reaches. */
static int on_the_ground(const bc_kv6 *m)
{
	size_t cells = (size_t)m->xs * m->ys * m->zs;
	uint8_t *solid = calloc(cells, 1), *held = calloc(cells, 1);
	int *stack = malloc(cells * sizeof *stack), top = 0, reached = 0, i;
	static const int d[6][3] = { { -1, 0, 0 }, { 1, 0, 0 }, { 0, -1, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, { 0, 0, 1 } };

#define IDX(x, y, z) ((x) + m->xs * ((y) + m->ys * (z)))
	for (i = 0; i < m->n; i++)
		solid[IDX(m->v[i].x, m->v[i].y, m->v[i].z)] = 1;
	for (i = 0; i < m->n; i++)
		if (m->v[i].z == m->zs - 1) {
			int k = IDX(m->v[i].x, m->v[i].y, m->v[i].z);
			held[k] = 1;
			stack[top++] = k;
		}
	while (top > 0) {
		int k = stack[--top], x = k % m->xs, y = k / m->xs % m->ys, z = k / m->xs / m->ys, j;

		reached++;
		for (j = 0; j < 6; j++) {
			int nx = x + d[j][0], ny = y + d[j][1], nz = z + d[j][2], q;
			if (nx < 0 || ny < 0 || nz < 0 || nx >= m->xs || ny >= m->ys || nz >= m->zs) continue;
			q = IDX(nx, ny, nz);
			if (solid[q] && !held[q]) { held[q] = 1; stack[top++] = q; }
		}
	}
#undef IDX
	free(solid); free(held); free(stack);
	return reached;
}

static int only_colours(const bc_kv6 *m, const uint32_t *rgb, int k)
{
	int i, j;

	for (i = 0; i < m->n; i++) {
		for (j = 0; j < k && m->v[i].rgb != rgb[j]; j++) ;
		if (j == k) return 0;
	}
	return 1;
}

static uint8_t *read_file(const char *name, size_t *n)
{
	static const char *const dirs[] = { "structures", "bot/structures" };
	char path[256];
	size_t d;

	for (d = 0; d < sizeof dirs / sizeof dirs[0]; d++) {
		FILE *f;
		uint8_t *buf;

		snprintf(path, sizeof path, "%s/%s", dirs[d], name);
		if (!(f = fopen(path, "rb"))) continue;
		buf = malloc(MAX_BYTES);
		*n = fread(buf, 1, MAX_BYTES, f);
		fclose(f);
		return buf;
	}
	return NULL;
}

/* ------------------------------------------------------------------ */
/* The structures that ship                                           */

/* what tools/mkstructures.py says it wrote */
static void test_shipped(const char *file, int xs, int ys, int zs, int voxels, const uint32_t *rgb, int colours)
{
	size_t n = 0;
	uint8_t *bytes = read_file(file, &n);
	bc_kv6 m;
	char err[160] = "";

	printf("%s\n", file);
	CHECK(bytes != NULL);
	if (!bytes) return;
	CHECK(bc_kv6_parse(bytes, n, &m, err, sizeof err));
	if (err[0]) printf("  %s\n", err);
	CHECK(m.xs == xs && m.ys == ys && m.zs == zs);
	CHECK(m.n == voxels);
	/* the pivot: the footprint's bottom centre, the ground under it */
	CHECK(m.px == xs / 2.0f && m.py == ys / 2.0f && m.pz == (float)zs);
	CHECK(only_colours(&m, rgb, colours));
	CHECK(ordered(&m));
	CHECK(m.n > 0 && m.v[0].z == zs - 1);               /* the bottom layer first */
	CHECK(on_the_ground(&m) == m.n);
	bc_kv6_free(&m);
	CHECK(m.v == NULL && m.n == 0);
	free(bytes);
}

static void test_bunker_shape(void)
{
	size_t n = 0;
	uint8_t *bytes = read_file("bunker.kv6", &n);
	bc_kv6 m;
	char err[160];
	uint32_t rgb = 0;
	int h;

	printf("the bunker: a door at the front (+y), slits at eye height, a roof\n");
	if (!bytes || !bc_kv6_parse(bytes, n, &m, err, sizeof err)) { CHECK(0); free(bytes); return; }
	for (h = 0; h < 3; h++)
		CHECK(!at(&m, 3, 6, 3 - h, NULL));             /* the door, floor to roof */
	CHECK(at(&m, 3, 0, 3, NULL) && at(&m, 3, 0, 2, NULL));
	CHECK(!at(&m, 3, 0, 1, NULL));                      /* the back's slit, the walls' top layer */
	CHECK(at(&m, 3, 6, 0, &rgb) && rgb == 0x55613F);    /* the roof over the door */
	CHECK(!at(&m, 3, 3, 3, NULL));                      /* inside, air */
	bc_kv6_free(&m);
	free(bytes);
}

/* ------------------------------------------------------------------ */
/* The closed inside, and what is refused                             */

enum { SHELL_SIDE = 3, SHELL_TOP = 0x112233, SHELL_REST = 0xA0B0C0 };

static int hollow_box(cell *c)
{
	int x, y, z, n = 0;

	for (x = 0; x < SHELL_SIDE; x++)
		for (y = 0; y < SHELL_SIDE; y++)
			for (z = 0; z < SHELL_SIDE; z++) {
				if (x == 1 && y == 1 && z == 1) continue;   /* the inside, not listed */
				c[n].x = x; c[n].y = y; c[n].z = z;
				c[n].rgb = z == 0 ? SHELL_TOP : SHELL_REST;
				n++;
			}
	return n;
}

static void test_hollow(void)
{
	cell c[27];
	uint8_t buf[1024], shifted[1025];
	int n = hollow_box(c);
	size_t len = write_kv6(buf, SHELL_SIDE, SHELL_SIDE, SHELL_SIDE, c, n);
	bc_kv6 m;
	char err[160] = "";
	uint32_t rgb = 0;

	printf("a hollow box: 26 listed, 27 solid, the inside as the voxel above it\n");
	CHECK(n == 26);
	CHECK(bc_kv6_parse(buf, len, &m, err, sizeof err));
	CHECK(m.n == 27);
	CHECK(at(&m, 1, 1, 1, &rgb) && rgb == SHELL_TOP);
	CHECK(at(&m, 0, 0, 2, &rgb) && rgb == SHELL_REST);
	CHECK(ordered(&m));
	bc_kv6_free(&m);

	/* the bytes at an odd address, and with something after them (SLAB6's
	 * palette) */
	memcpy(shifted + 1, buf, len);
	CHECK(bc_kv6_parse(shifted + 1, len, &m, err, sizeof err) && m.n == 27);
	bc_kv6_free(&m);
	memset(buf + len, 0xEE, 16);
	CHECK(bc_kv6_parse(buf, len + 16, &m, err, sizeof err) && m.n == 27);
	bc_kv6_free(&m);

	/* a box open on one side is not filled: the air gets in */
	{
		cell open[27];
		int k = 0, i;
		for (i = 0; i < n; i++)
			if (!(c[i].x == 1 && c[i].y == 1 && c[i].z == 0)) open[k++] = c[i];
		len = write_kv6(buf, SHELL_SIDE, SHELL_SIDE, SHELL_SIDE, open, k);
		CHECK(bc_kv6_parse(buf, len, &m, err, sizeof err) && m.n == 25);
		CHECK(!at(&m, 1, 1, 1, NULL));
		bc_kv6_free(&m);
	}
}

static void refused(const char *what, const uint8_t *b, size_t n)
{
	bc_kv6 m;
	char err[160] = "";

	CHECK(!bc_kv6_parse(b, n, &m, err, sizeof err));
	CHECK(err[0] != '\0');
	CHECK(m.v == NULL && m.n == 0);
	printf("  %s: %s\n", what, err);
}

static void test_refused(void)
{
	cell c[27];
	uint8_t good[1024], b[1024];
	int n = hollow_box(c);
	size_t len = write_kv6(good, SHELL_SIDE, SHELL_SIDE, SHELL_SIDE, c, n);
	/* the box's blocks start at HEAD; the column (0, 0) holds z 0, 1, 2 */
	size_t xy = HEAD + (size_t)n * BLOCK + SHELL_SIDE * 4;

	printf("refused, with the reason\n");
	memcpy(b, good, len); b[0] = 'X';
	refused("bad magic", b, len);
	refused("truncated", good, len - 1);
	refused("shorter than a header", good, HEAD - 1);
	memcpy(b, good, len); put16(b + xy, 2);
	refused("the columns' sum is not blklen", b, len);
	memcpy(b, good, len); put16(b + HEAD + 4, 1); put16(b + HEAD + BLOCK + 4, 0);
	refused("z not sorted", b, len);
	memcpy(b, good, len); put16(b + HEAD + BLOCK + 4, 0);
	refused("a voxel twice", b, len);
	memcpy(b, good, len); put16(b + HEAD + 2 * BLOCK + 4, SHELL_SIDE);
	refused("z outside the model", b, len);
	memcpy(b, good, len); put32(b + 4, 0);
	refused("a side of 0", b, len);
	memcpy(b, good, len); put32(b + 12, BC_KV6_SIDE_MAX + 1);
	refused("a side over the most", b, len);
	memcpy(b, good, len); put32(b + 16, 0x7fc00000u);
	refused("a pivot that is not a number", b, len);
	{
		size_t e = write_kv6(b, 1, 1, 1, c, 0);
		refused("nothing in it", b, e);
	}
}

int main(void)
{
	static const uint32_t bunker[] = { 0x7D7A68, 0x55613F };
	static const uint32_t mirador[] = { 0x4E3826, 0x8A6A44, 0x6B4F31, 0x9C7B50 };

	test_shipped("bunker.kv6", 7, 7, 4, 107, bunker, 2);
	test_shipped("mirador.kv6", 5, 5, 9, 100, mirador, 4);
	test_bunker_shape();
	test_hollow();
	test_refused();
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
