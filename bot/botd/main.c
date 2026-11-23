/* main.c -- botd's command line */
#include "botd.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void usage(FILE *f)
{
	fputs("usage: botd [--file PATH] [--trees DIR] [--hz N] [--budget N] [--once]\n"
	      "  --file PATH   the server's link file (default /dev/shm/lsd-botlink)\n"
	      "  --trees DIR   behaviour trees, *.bt (default /opt/botd/trees, then ./trees)\n"
	      "  --hz N        rounds a second (default 60)\n"
	      "  --budget N    planner expansions one think may spend (default 3000)\n"
	      "  --bots N      bots the engine is sized for (default 64)\n"
	      "  --once        do not wait for the file: exit 1 if it is not there now\n"
	      "Waits quietly for the file, serves it until the server closes it or\n"
	      "goes silent, then exits 0.\n", f);
}

static int number(const char *s, int lo, int hi, const char *what)
{
	char *end;
	long v = strtol(s, &end, 10);
	if (*s == '\0' || *end != '\0' || v < lo || v > hi) {
		fprintf(stderr, "botd: %s must be %d to %d\n", what, lo, hi);
		exit(2);
	}
	return (int)v;
}

int main(int argc, char **argv)
{
	botd_opts o;
	botd_opts_default(&o);
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		int more = i + 1 < argc;
		if (!strcmp(a, "--once")) o.once = 1;
		else if (!strcmp(a, "--help") || !strcmp(a, "-h")) { usage(stdout); return 0; }
		else if (!strcmp(a, "--file") && more) o.file = argv[++i];
		else if (!strcmp(a, "--trees") && more) o.trees = argv[++i];
		else if (!strcmp(a, "--hz") && more) o.hz = number(argv[++i], 1, 1000, "--hz");
		else if (!strcmp(a, "--budget") && more) o.budget = number(argv[++i], 0, 1000000, "--budget");
		else if (!strcmp(a, "--bots") && more) o.max_bots = number(argv[++i], 1, 256, "--bots");
		else { usage(stderr); return 2; }
	}
	return botd_run(&o);
}
