/* rng.h -- A bot's own randomness
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * PCG32. Every bot owns one, seeded from the seed the server gave it
 * (bl_ev_bot.seed), and everything random about it -- its character,
 * its choices, its aim's wobble -- draws from that one stream, in the
 * order it thinks. So a seed and a recording of what the bot was shown
 * replay the same bot exactly, which is how a behaviour is tested and
 * how a bug seen once is seen again.
 */
#ifndef BC_RNG_H
#define BC_RNG_H

#include <stdint.h>

typedef struct bc_rng { uint64_t state, inc; } bc_rng;

void bc_rng_seed(bc_rng *r, uint64_t seed, uint64_t stream);
uint32_t bc_rng_u32(bc_rng *r);
/* [0, 1) */
float bc_rng_float(bc_rng *r);
/* [lo, hi) */
float bc_rng_range(bc_rng *r, float lo, float hi);
/* a normal deviate: mean 0, deviation 1 */
float bc_rng_normal(bc_rng *r);
/* [0, n), unbiased; 0 when n is 0 */
uint32_t bc_rng_below(bc_rng *r, uint32_t n);

#endif
