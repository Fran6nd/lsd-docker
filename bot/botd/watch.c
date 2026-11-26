/* watch.c -- the debug channel: what the bots think, in files a viewer reads
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * The core can say what a bot is thinking (engine.h, bc_engine_snapshot);
 * this is how it leaves the process. No socket, no thread: a directory
 * beside the link's other files (botd_opts.debug_dir, by default
 * $LSD_DATA/rw/botdebug), looked at four times a second.
 *
 * A VIEWER ASKS by writing a small file there, any name ending ".req":
 *
 *     watch=3,7        the bots to watch, by pid; or `all`; or nothing
 *     hz=4             snapshots a second for each (1 to 20; default 4)
 *
 * and keeps it alive by touching it: a request whose file is older than
 * 15 seconds counts for nothing (so a viewer that died costs nothing),
 * and is left where it is. Several viewers each write their own; the
 * bots watched are those any of them names, at the highest rate asked.
 *
 * WHILE ANY REQUEST IS ALIVE botd writes, in the same directory:
 *
 *     bots.json        every bot in a line, the trees, the world's tree
 *                      ("lsd-bt-bots"), once a second
 *     bot-<pid>.json   each watched bot's snapshot ("lsd-bt-snapshot")
 *
 * each written whole to "<name>.new" and renamed over, so a reader never
 * sees half a file. When the last request dies the watching is turned
 * off in the engine and those files are removed. The formats are
 * bot/TREES.md's ("the live view"): they are a contract.
 *
 * WHAT IT COSTS. With no request: one stat of the directory every 250 ms,
 * which fails if nobody ever made it. With one: a readdir at that rate,
 * a roster a second, and the snapshots asked for -- some 13 KiB of text
 * for a bot of the tdm tree -- none of it inside a think.
 *
 * WHAT IT TRUSTS. A request is a few numbers. It is read from a regular
 * file of at most 1 KiB, never a link; pids are 0 to 255,
 * the rate is clamped; nothing in it names a path. The directory is
 * made 0700 by botd: who may write there may see what the bots think
 * and make botd write some files a second, and nothing more.
 */
#include "botd.h"
#include "engine.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

enum { LOOK_MS = 250, ALIVE_S = 15, REQ_MAX = 1024, HZ_DEFAULT = 4, HZ_MAX = 20 };

void botd_watch_init(botd_watch *w, const char *dir)
{
	memset(w, 0, sizeof *w);
	if (!dir || !*dir || !strcmp(dir, "none") || strlen(dir) >= sizeof w->dir)
		return;
	strcpy(w->dir, dir);
	/* ours alone; the parent must be there already (the server's rw/) */
	if (mkdir(w->dir, 0700) != 0 && errno != EEXIST)
		w->dir[0] = 0;
}

/* One request's lines into the sum of them all. */
static void take_request(botd_watch *w, char *text)
{
	for (char *line = strtok(text, "\r\n"); line; line = strtok(NULL, "\r\n")) {
		if (!strncmp(line, "hz=", 3)) {
			int hz = atoi(line + 3);
			if (hz > HZ_MAX) hz = HZ_MAX;
			if (hz > w->hz) w->hz = hz;
		} else if (!strncmp(line, "watch=", 6)) {
			const char *q = line + 6;
			if (!strncmp(q, "all", 3)) { w->all = 1; continue; }
			while (*q) {
				char *end;
				long pid = strtol(q, &end, 10);
				if (end == q) break;
				if (pid >= 0 && pid < 256) w->want[pid] = 1;
				q = *end == ',' || *end == ' ' ? end + 1 : end;
				if (q == end) break;
			}
		}
	}
}

/* Every live request of the directory. How many there are. */
static int look(botd_watch *w)
{
	DIR *d = opendir(w->dir);
	time_t now = time(NULL);
	int live = 0;
	memset(w->want, 0, sizeof w->want);
	w->all = 0;
	w->hz = 0;
	if (!d) return 0;
	for (struct dirent *de; (de = readdir(d)) != NULL;) {
		size_t l = strlen(de->d_name);
		char path[800], text[REQ_MAX + 1];
		struct stat st;
		if (l < 5 || strcmp(de->d_name + l - 4, ".req")) continue;
		snprintf(path, sizeof path, "%s/%s", w->dir, de->d_name);
		if (lstat(path, &st) != 0 || !S_ISREG(st.st_mode)) continue;   /* a file, not a link to one */
		int fd = open(path, O_RDONLY);
		if (fd < 0) continue;
		if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size <= REQ_MAX &&
		    now - st.st_mtime <= ALIVE_S && st.st_mtime - now <= ALIVE_S) {
			ssize_t n = read(fd, text, REQ_MAX);
			if (n >= 0) {
				text[n] = 0;
				take_request(w, text);
				live++;
			}
		}
		close(fd);
	}
	closedir(d);
	if (live && w->hz < 1) w->hz = HZ_DEFAULT;
	return live;
}

/* `text` as the whole of <dir>/<name>, or not at all. */
static void put_file(botd_watch *w, const char *name, const char *text, size_t n)
{
	char path[800], tmp[800];
	snprintf(path, sizeof path, "%s/%s", w->dir, name);
	snprintf(tmp, sizeof tmp, "%s/%s.new", w->dir, name);
	FILE *fh = fopen(tmp, "wb");
	if (!fh) return;
	int ok = fwrite(text, 1, n, fh) == n;
	ok = fclose(fh) == 0 && ok;
	if (ok && rename(tmp, path) == 0) w->written++;
	else remove(tmp);
}

static void drop_file(botd_watch *w, const char *name)
{
	char path[800];
	snprintf(path, sizeof path, "%s/%s", w->dir, name);
	remove(path);
}

/* The text the engine has to say, in w->buf (grown until it fits). */
static size_t fill(botd_watch *w, bc_engine *e, int pid)
{
	for (int tries = 0; tries < 2; tries++) {
		size_t n = pid < 0 ? bc_engine_roster(e, w->buf, w->cap) : bc_engine_snapshot(e, pid, w->buf, w->cap);
		if (n == 0 || n < w->cap) return n;
		char *nb = realloc(w->buf, n + 4096);
		if (!nb) return 0;
		w->buf = nb;
		w->cap = n + 4096;
	}
	return 0;
}

static void all_off(botd_watch *w, bc_engine *e)
{
	for (int pid = 0; pid < 256; pid++) {
		if (!w->on[pid]) continue;
		char name[32];
		if (e) bc_engine_watch(e, pid, 0);
		w->on[pid] = 0;
		snprintf(name, sizeof name, "bot-%d.json", pid);
		drop_file(w, name);
	}
}

int botd_watch_round(botd_watch *w, bc_engine *e, double now)
{
	if (!w->dir[0] || !e) return 0;
	if (now >= w->next_look) {
		w->next_look = now + LOOK_MS / 1000.0;
		struct stat st;
		int live = stat(w->dir, &st) == 0 && S_ISDIR(st.st_mode) ? look(w) : 0;
		if (!live && w->live) {             /* the last viewer went */
			all_off(w, e);
			drop_file(w, "bots.json");
		}
		if (live && !w->live) w->next_roster = w->next_snap = 0;       /* at once */
		w->live = live;
	}
	if (!w->live) return 0;
	if (!w->buf) {
		w->cap = 1 << 17;
		w->buf = malloc(w->cap);
		if (!w->buf) { w->cap = 0; return 0; }
	}
	if (now >= w->next_roster) {
		w->next_roster = now + 1.0;
		size_t n = fill(w, e, -1);
		if (n) put_file(w, "bots.json", w->buf, n);
	}
	if (now >= w->next_snap) {
		w->next_snap = now + 1.0 / (double)w->hz;
		for (int pid = 0; pid < 256; pid++) {
			char name[32];
			int want = w->all || w->want[pid];
			snprintf(name, sizeof name, "bot-%d.json", pid);
			if (want != bc_engine_watched(e, pid)) bc_engine_watch(e, pid, want);    /* (a bot made anew is not watched) */
			size_t n = want ? fill(w, e, pid) : 0;
			if (n) {
				put_file(w, name, w->buf, n);
				w->on[pid] = 1;
			} else if (w->on[pid]) {            /* not asked for any more, or gone */
				w->on[pid] = 0;
				drop_file(w, name);
			}
		}
	}
	return w->live;
}

int botd_watch_asked(const botd_watch *w)
{
	int n = 0;

	if (!w->live)
		return 0;
	if (w->all)
		return -1;
	for (int pid = 0; pid < 256; pid++)
		n += w->want[pid] != 0;
	return n;
}

void botd_watch_end(botd_watch *w, bc_engine *e)
{
	if (w->dir[0]) {
		all_off(w, e);
		if (w->live) drop_file(w, "bots.json");
	}
	free(w->buf);
	w->buf = NULL;
	w->cap = 0;
	w->live = 0;
}
