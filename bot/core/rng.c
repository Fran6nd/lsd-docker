/* rng.c -- PCG32 (pcg-random.org, the minimal C reference algorithm).
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE. */
#include "rng.h"
#include <math.h>

void bc_rng_seed(bc_rng *r, uint64_t seed, uint64_t stream)
{
	r->state = 0u;
	r->inc = (stream << 1u) | 1u;
	bc_rng_u32(r);
	r->state += seed;
	bc_rng_u32(r);
}

uint32_t bc_rng_u32(bc_rng *r)
{
	uint64_t old = r->state;
	uint32_t xorshifted, rot;
	r->state = old * 6364136223846793005ULL + r->inc;
	xorshifted = (uint32_t)(((old >> 18u) ^ old) >> 27u);
	rot = (uint32_t)(old >> 59u);
	return (xorshifted >> rot) | (xorshifted << ((0u - rot) & 31u));
}

float bc_rng_float(bc_rng *r)
{
	return (float)(bc_rng_u32(r) >> 8) * (1.0f / 16777216.0f);
}

float bc_rng_range(bc_rng *r, float lo, float hi)
{
	float v = lo + (hi - lo) * bc_rng_float(r);
	if (v >= hi) v = nextafterf(hi, lo);   /* rounding can land on hi */
	return v;
}

float bc_rng_normal(bc_rng *r)
{
	/* Box-Muller, the cosine half only: two draws a call, nothing kept */
	double u1 = ((double)bc_rng_u32(r) + 1.0) / 4294967296.0;   /* (0, 1] */
	double u2 = (double)bc_rng_u32(r) / 4294967296.0;            /* [0, 1) */
	return (float)(sqrt(-2.0 * log(u1)) * cos(6.283185307179586 * u2));
}

uint32_t bc_rng_below(bc_rng *r, uint32_t n)
{
	uint32_t threshold, x;
	if (n == 0) return 0;
	threshold = (0u - n) % n;   /* 2^32 mod n: the biased low end is thrown away */
	for (;;) {
		x = bc_rng_u32(r);
		if (x >= threshold) return x % n;
	}
}
