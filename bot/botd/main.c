/* main.c -- botd's command line */
#include "botd.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void usage(FILE *f)
{
	fputs("usage: botd [--file PATH] [--trees DIR] [--user-trees DIR] [--hz N] [--budget N] [--plan-rate N]\n"
	      "            [--plan-ms N] [--bots N] [--threads N] [--once]\n"
	      "  --file PATH   the server's link file (default /dev/shm/lsd-botlink)\n"
	      "  --trees DIR   behaviour trees, *.bt (default /opt/botd/trees, then ./trees)\n"
	      "  --user-trees DIR  the operator's own *.bt, read after those and again at each\n"
	      "                map: a tree of a built-in's name replaces it (default $LSD_DATA/trees,\n"
	      "                LSD_DATA defaulting to /data)\n"
	      "  --debug-dir DIR  where a viewer asks what the bots think and is answered in\n"
	      "                files (bttree --watch; default $LSD_DATA/rw/botdebug; `none`: nowhere)\n"
	      "  --hz N        rounds a second (default 60)\n"
	      "  --budget N    planner expansions one think may always spend (default 3000)\n"
	      "  --plan-rate N and each bot's share: expansions a second (default 4500, 75 a\n"
	      "                think at 60; a think spends the larger of the two)\n"
	      "  --plan-ms N   the most of a round the planner may take, ms (default 8; 0: no\n"
	      "                bound): what does not fit waits for the next round\n"
	      "  --bots N      bots the engine is sized for (default 255: every seat)\n"
	      "  --threads N   threads sight and the route planner run on, botd's own included (default 1;\n"
	      "                0: half the cores, at most 4 -- a think plans at most 4 routes at\n"
	      "                once). The bots do the same whatever the number\n"
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
		else if (!strcmp(a, "--user-trees") && more) o.user_trees = argv[++i];
		else if (!strcmp(a, "--debug-dir") && more) o.debug_dir = argv[++i];
		else if (!strcmp(a, "--hz") && more) o.hz = number(argv[++i], 1, 1000, "--hz");
		else if (!strcmp(a, "--budget") && more) o.budget = number(argv[++i], 0, 1000000, "--budget");
		else if (!strcmp(a, "--plan-rate") && more) o.plan_rate = number(argv[++i], 0, 10000000, "--plan-rate");
		else if (!strcmp(a, "--plan-ms") && more) o.plan_ms = number(argv[++i], 0, 1000, "--plan-ms");
		else if (!strcmp(a, "--bots") && more) o.max_bots = number(argv[++i], 1, 256, "--bots");
		else if (!strcmp(a, "--threads") && more) o.threads = number(argv[++i], 0, 64, "--threads");
		else { usage(stderr); return 2; }
	}
	return botd_run(&o);
}
