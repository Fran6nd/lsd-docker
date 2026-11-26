/* blueprint.c -- Structures to build, as data. See blueprint.h.
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE. */
#include "blueprint.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t hash_text(const char *s)
{
	uint32_t h = 2166136261u;

	for (; *s; s++)
		h = (h ^ (uint8_t)*s) * 16777619u;
	return h;
}

bc_blueprint *bc_blueprint_get(bc_blueprints *t, const char *name)
{
	int i;

	for (i = 0; i < BC_BLUEPRINTS_MAX; i++)
		if (t->bp[i].name[0] && !strcmp(t->bp[i].name, name))
			return &t->bp[i];
	return NULL;
}

/* the cells (allocated) in b, or in a free slot */
static int install(bc_blueprints *t, bc_blueprint *b, const char *name, bc_bp_cell *cells, int n, uint32_t h,
                   char *err, size_t err_size)
{
	if (!b) {
		for (b = &t->bp[0]; b < &t->bp[BC_BLUEPRINTS_MAX] && b->name[0]; b++) ;
		if (b == &t->bp[BC_BLUEPRINTS_MAX]) {
			snprintf(err, err_size, "no room for another blueprint (%d at most)", BC_BLUEPRINTS_MAX);
			free(cells);
			return 0;
		}
	}
	free(b->cells);
	snprintf(b->name, sizeof b->name, "%s", name);
	b->cells = cells;
	b->n = n;
	b->hash = h;
	t->version++;
	return 1;
}

int bc_blueprint_set(bc_blueprints *t, const char *name, const char *text, char *err, size_t err_size)
{
	bc_blueprint *b = bc_blueprint_get(t, name);
	const char *q;
	bc_bp_cell *cells;
	int n = 0, k;
	uint32_t h;

	if (strlen(name) == 0 || strlen(name) >= BC_BLUEPRINT_NAME) {
		snprintf(err, err_size, "a name of 1 to %d characters", BC_BLUEPRINT_NAME - 1);
		return 0;
	}
	if (!text[0]) {
		if (b) { free(b->cells); memset(b, 0, sizeof *b); t->version++; }
		return 1;
	}
	h = hash_text(text);
	if (b && b->hash == h)
		return 1;               /* the same again: claims and marks stand */
	for (q = text; *q; q++)
		n += *q == ';';
	n++;
	if (n > BC_BLUEPRINT_CELLS_MAX) {
		snprintf(err, err_size, "%d voxels: %d at most", n, BC_BLUEPRINT_CELLS_MAX);
		return 0;
	}
	cells = calloc((size_t)n, sizeof *cells);
	if (!cells) {
		snprintf(err, err_size, "no memory");
		return 0;
	}
	for (q = text, k = 0; *q && k < n; ) {
		int x, y, z, used = 0;

		while (*q == ' ' || *q == ';') q++;
		if (!*q) break;
		if (sscanf(q, "%d %d %d%n", &x, &y, &z, &used) != 3 || x < 0 || x >= 512 || y < 0 || y >= 512 || z < 0 || z >= 64) {
			snprintf(err, err_size, "voxel %d: not \"x y z\" in the map", k + 1);
			free(cells);
			return 0;
		}
		cells[k].x = (int16_t)x; cells[k].y = (int16_t)y; cells[k].z = (int16_t)z;
		k++;
		q += used;
		while (*q && *q != ';') q++;
	}
	return install(t, b, name, cells, k, h, err, err_size);
}

int bc_blueprint_put(bc_blueprints *t, const char *name, const bc_bp_cell *src, int n, char *err, size_t err_size)
{
	bc_blueprint *b = bc_blueprint_get(t, name);
	bc_bp_cell *cells;
	uint32_t h = 2166136261u;
	int k;

	if (strlen(name) == 0 || strlen(name) >= BC_BLUEPRINT_NAME) {
		snprintf(err, err_size, "a name of 1 to %d characters", BC_BLUEPRINT_NAME - 1);
		return 0;
	}
	if (n <= 0 || n > BC_BLUEPRINT_CELLS_MAX) {
		snprintf(err, err_size, "%d voxels: 1 to %d", n, BC_BLUEPRINT_CELLS_MAX);
		return 0;
	}
	for (k = 0; k < n; k++) {
		uint32_t w[4] = { (uint32_t)src[k].x, (uint32_t)src[k].y, (uint32_t)src[k].z, src[k].rgb };
		int j;

		for (j = 0; j < 4; j++)
			h = (h ^ w[j]) * 16777619u;
	}
	if (b && b->hash == h)
		return 1;               /* the same again: claims and marks stand */
	cells = calloc((size_t)n, sizeof *cells);
	if (!cells) {
		snprintf(err, err_size, "no memory");
		return 0;
	}
	for (k = 0; k < n; k++) {
		cells[k].x = src[k].x; cells[k].y = src[k].y; cells[k].z = src[k].z;
		cells[k].rgb = src[k].rgb;
	}
	return install(t, b, name, cells, n, h, err, err_size);
}

void bc_blueprints_free(bc_blueprints *t)
{
	int i;

	for (i = 0; i < BC_BLUEPRINTS_MAX; i++)
		free(t->bp[i].cells);
	memset(t, 0, sizeof *t);
}

int bc_structure_cells(const bc_kv6 *m, int x, int y, int ground_z, int quarter, bc_bp_cell *out, int max)
{
	int i, n = 0, cx = (int)floorf(m->px), cy = (int)floorf(m->py), cz = (int)floorf(m->pz);

	for (i = 0; i < m->n && n < max; i++) {
		const bc_kv6_voxel *v = &m->v[i];
		int dx = v->x - cx, dy = v->y - cy, wx, wy, wz = ground_z + (v->z - cz);

		switch (quarter & 3) {
		case 0: wx = x + dx; wy = y + dy; break;
		case 1: wx = x - dy; wy = y + dx; break;
		case 2: wx = x - dx; wy = y - dy; break;
		default: wx = x + dy; wy = y - dx; break;
		}
		if (wx < 0 || wx >= 512 || wy < 0 || wy >= 512 || wz < 0 || wz >= 64)
			continue;
		memset(&out[n], 0, sizeof out[n]);
		out[n].x = (int16_t)wx; out[n].y = (int16_t)wy; out[n].z = (int16_t)wz;
		out[n].rgb = BC_BP_RGB | (v->rgb & 0xFFFFFFu);
		n++;
	}
	return n;
}

const bc_kv6 *bc_structure_get(const bc_structures *s, const char *name)
{
	int i;

	for (i = 0; i < BC_STRUCTURES_MAX; i++)
		if (s->name[i][0] && !strcmp(s->name[i], name))
			return &s->model[i];
	return NULL;
}

void bc_structures_free(bc_structures *s)
{
	int i;

	for (i = 0; i < BC_STRUCTURES_MAX; i++)
		bc_kv6_free(&s->model[i]);
	memset(s, 0, sizeof *s);
}
