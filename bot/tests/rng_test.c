/* rng_test.c -- PCG32 against its reference, and the helpers' contracts */
#include "rng.h"
#include <math.h>
#include <stdio.h>

static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

int main(void)
{
	bc_rng r, a, b;
	int i, hist[7] = {0};
	double sum = 0, sq = 0;
	static const uint32_t ref[6] = { 0xa15c02b7u, 0x7b47f409u, 0xba1d3330u, 0x83d2f293u, 0xbfa4784bu, 0xcbed606eu };

	/* pcg32-demo: seed 42, sequence 54 */
	bc_rng_seed(&r, 42u, 54u);
	for (i = 0; i < 6; i++) CHECK(bc_rng_u32(&r) == ref[i]);

	bc_rng_seed(&a, 7, 1); bc_rng_seed(&b, 7, 1);
	for (i = 0; i < 100; i++) CHECK(bc_rng_u32(&a) == bc_rng_u32(&b));
	bc_rng_seed(&b, 8, 1);
	bc_rng_seed(&a, 7, 1);
	{ int same = 0; for (i = 0; i < 100; i++) same += bc_rng_u32(&a) == bc_rng_u32(&b); CHECK(same < 3); }
	bc_rng_seed(&b, 7, 2);
	bc_rng_seed(&a, 7, 1);
	{ int same = 0; for (i = 0; i < 100; i++) same += bc_rng_u32(&a) == bc_rng_u32(&b); CHECK(same < 3); }

	bc_rng_seed(&r, 1, 1);
	for (i = 0; i < 100000; i++) {
		float f = bc_rng_float(&r), g = bc_rng_range(&r, -2.0f, 3.0f);
		CHECK(f >= 0.0f && f < 1.0f);
		CHECK(g >= -2.0f && g < 3.0f);
		sum += f;
	}
	CHECK(fabs(sum / 100000 - 0.5) < 0.01);

	CHECK(bc_rng_below(&r, 0) == 0);
	CHECK(bc_rng_below(&r, 1) == 0);
	for (i = 0; i < 70000; i++) {
		uint32_t v = bc_rng_below(&r, 7);
		CHECK(v < 7);
		if (v < 7) hist[v]++;
	}
	for (i = 0; i < 7; i++) CHECK(hist[i] > 9500 && hist[i] < 10500);
	/* a big n, where modulo bias would show: n = 3/4 of 2^32 */
	{
		int low = 0;
		for (i = 0; i < 100000; i++) low += bc_rng_below(&r, 3221225472u) < 1073741824u;
		CHECK(low > 33000 && low < 33700);   /* expect 1/3 */
	}

	sum = 0;
	{
		int within1 = 0, n = 100000;
		for (i = 0; i < n; i++) {
			float z = bc_rng_normal(&r);
			CHECK(isfinite(z));
			sum += z; sq += (double)z * z;
			within1 += fabsf(z) < 1.0f;
		}
		CHECK(fabs(sum / n) < 0.02);
		CHECK(fabs(sq / n - 1.0) < 0.03);
		CHECK(within1 > 67500 && within1 < 69000);   /* 68.3% */
	}

	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
