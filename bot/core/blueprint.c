/* blueprint.c -- Structures to build, as data. See blueprint.h.
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE. */
#include "blueprint.h"

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
		if (b) { free(b->cells); memset(b, 0, sizeof *b); }
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
	b->n = k;
	b->hash = h;
	return 1;
}

void bc_blueprints_free(bc_blueprints *t)
{
	int i;

	for (i = 0; i < BC_BLUEPRINTS_MAX; i++)
		free(t->bp[i].cells);
	memset(t, 0, sizeof *t);
}
