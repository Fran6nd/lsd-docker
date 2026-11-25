/* engine.h -- All the bots of one server, as the host sees them
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * The one door between the host (botd: the file, the clock, the logs)
 * and the core (everything a bot is). The host hands in what the server
 * said -- the map, the events, the world -- and takes out what the bots
 * want: an intent each, and actions. It knows nothing else about bots,
 * and the core knows nothing about files, time or processes.
 *
 * The data crossing the door is botlink.h's, as it is (bl_world,
 * bl_record, bl_intent): those are plain structs, and translating them
 * into twins would only be a place for the two to disagree.
 *
 * WHAT IS SHARED AND WHAT IS A BOT'S. One engine holds what every bot of
 * a server shares -- the map and its collapse scratch, the measured
 * moves, the memory of moves that failed, the trees, the vocabulary,
 * what the fleet knows (who was seen where, which pings stand) -- once.
 * A bot holds only what is its own: its character, its place in the
 * tree, its senses' memory, its aim, its route.
 *
 * TIME. bc_engine_think is given the time since it was last called; the
 * core never asks a clock. WORK is bounded the same way: `budget` is in
 * planner expansions (nav.h), shared out among the bots that need a
 * route this call, so a think never runs long because thirty bots lost
 * their way at once. What does not fit waits for the next call, and the
 * bot keeps doing what it was doing meanwhile.
 *
 * THE PLANNER'S BUDGET, a think's, is the larger of two:
 *   budget         the call's argument: what one think may always spend,
 *                  so a lone bot's long route (a way down from a roof)
 *                  is found in a few thinks however few bots there are
 *   rate x bots    each bot's share of the planner: BC_PLAN_RATE
 *                  expansions a second (bc_engine_plan_rate), divided
 *                  among the thinks of a second -- so a fleet's routes
 *                  keep coming however many bots there are
 * With the defaults (1500; 2250 a second, 38 a think at 60 thinks a
 * second) the second passes the first at 40 bots. A fixed budget left
 * most of 230 bots waiting for routes (2026-11-25, the bench's map230:
 * 31% of their time; 1.5% with the share). Every think plans (engine.c,
 * THE THINK); until 2026-11-25 only a think with a new world did, so the
 * numbers were twice these (3000; 4500 a second) for the same expansions
 * a second.
 *
 * ORDER, each time round: bc_engine_event for every record the server
 * queued (in order), then bc_engine_think with the newest world.
 */
#ifndef BC_ENGINE_H
#define BC_ENGINE_H

#include <stddef.h>
#include <stdint.h>
#include "botlink.h"

typedef struct bc_engine bc_engine;

/* What the core asks of its host. */
typedef struct bc_engine_host {
	void *ctx;
	/* a line for the log; level 0 debug, 1 note, 2 trouble. The core
	 * keeps what happens all the time at 0 (a bot let go of a wall), what
	 * an operator should see once at 1 (a map loaded, a bot made), and
	 * what is wrong at 2 (a tree that does not compile, no room). */
	void (*log)(void *ctx, int level, const char *line);
	/* an action for the server (bl_action), as bl_push takes it */
	void (*action)(void *ctx, uint8_t type, uint8_t pid, const void *payload, uint32_t bytes);
} bc_engine_host;

/* One engine: allocates all it will ever need for `max_bots` bots
 * (nothing is allocated per think). NULL if it cannot. */
bc_engine *bc_engine_new(const bc_engine_host *host, int max_bots);
void bc_engine_free(bc_engine *e);

/* The built-in trees: one text holding every `tree <name>:` (bt.h). The
 * tree a bot runs is the one named by the setting `tree` (default
 * "default"). 0 on a mistake, said in err.
 *
 * A call that FAILS leaves the engine exactly as it was: the trees it
 * had stay, and the bots stay in them. A call that succeeds REPLACES
 * every tree given before (it does not add to them); bots already
 * running leave their old tree cleanly (every action RUNNING is told to
 * stop) and enter the new one at its root. So a host may try each file
 * alone for its own error line and then give the good ones as one text.
 * With no trees given at all the engine runs a small one of its own.
 * `tree items` may always be named: the engine writes that tree itself
 * (engine.c, THE ITEMS TREE). */
int bc_engine_trees(bc_engine *e, const char *text, char *err, size_t err_size);

/* The kinds of player as data (trees/archetypes.txt: persona.h's format):
 * read over the built-in kinds, the table every bot is drawn from (the
 * setting archetype_table reads over this one). 1, or 0 with the fault
 * in err and the kinds as they were. */
int bc_engine_kinds(bc_engine *e, const char *text, char *err, size_t err_size);

/* A map: the bytes of a .vxl, as the server's BL_EV_MAP named it. Every
 * bot forgets its route; what the fleet learned of the last map goes.
 * 0 if it is not a map. */
int bc_engine_map(bc_engine *e, const uint8_t *vxl, size_t bytes, uint32_t map_seq);

/* One record from the server's queue (a bl_record and its payload), any
 * but BL_EV_MAP -- that one names a file, which is the host's to read. */
void bc_engine_event(bc_engine *e, const bl_record *rec);

/* Think: every bot marked BL_F_BOT in `world` that the server asked for
 * (BL_EV_BOT) gets its intent written into `intents[pid]`; actions go
 * out through the host. `dt` is the seconds since the last call. */
void bc_engine_think(bc_engine *e, const bl_world *world, bl_intent *intents,
	float dt, int budget);

/* Each bot's share of the planner (THE PLANNER'S BUDGET, above): `rate`
 * expansions a second, the host thinking `hz` times a second. Until it
 * is called: BC_PLAN_RATE at 60. */
#define BC_PLAN_RATE 2250
void bc_engine_plan_rate(bc_engine *e, int rate, int hz);

/* THE THINK'S WORK AS JOBS, for a host with threads. The core has none
 * (README.md); what it can offer is its heavy work cut so that a host's
 * threads could do it at once: a BATCH of jobs, each of which writes only
 * what is its own and reads only what nothing writes while the batch
 * runs. What the jobs found is taken in by the core afterwards, in its own
 * order, so the outcome is the same whoever ran them, in whatever order,
 * on however many threads (tests/parallel_test.c proves it, intent for
 * intent). Two kinds of work are handed over so:
 *
 * SIGHT (BC_WORK_SIGHT): the rays of every bot whose turn it is to decide,
 * a job a bot (senses.h, SIGHT IN TWO HALVES). A job reads the map, the
 * world and its own bot's memory, and writes its own bot's look; the
 * memories, the team's board and the alertness are then taken in bot
 * after bot, in the bots' order, as if each had looked alone.
 *
 * ROUTE SEARCHES (BC_WORK_PLAN; skill_move.c, bc_movers_plan): each search
 * is the state of one bot's plan, private to it, and advancing it reads
 * only what nothing writes while the think plans -- the map, the move
 * table, the bot's policy and the engine's memories it points to. Each
 * pass of the planner's budget gives every search under way an equal
 * share, fixed before any of them runs; the searches of such a pass are a
 * batch. When the budget is too thin to share (under 64 expansions a
 * search) the first takes all there is and the next what it leaves: those
 * depend on each other and are handed over one at a time. What they found
 * is applied in the search slots' bots' order, longest waiting first.
 *
 * A runner must call job(arg, i) for every i in 0 .. n-1 before it returns,
 * and touch nothing else of the engine's; `kind` is for a host that keeps
 * count of what it ran. With none (bc_engine_runner(e, NULL, NULL), the
 * default) the core runs the jobs itself, one after the other. */
enum bc_work { BC_WORK_SIGHT = 0, BC_WORK_PLAN = 1 };
typedef void (*bc_job)(void *arg, int i);
typedef void (*bc_runner)(void *ctx, int kind, bc_job job, void *arg, int n);
void bc_engine_runner(bc_engine *e, bc_runner run, void *ctx);

/* How many bots it holds. */
int bc_engine_bots(const bc_engine *e);

/* For a log or a debug view: what bot `pid` is and is doing --
 * "pusher L6 | pick:aggression > fight | route 14/31 RUNJUMP | sees 2".
 * The length written; 0 for no such bot. */
size_t bc_engine_describe(const bc_engine *e, int pid, char *out, size_t out_size);

/* The name of a kind of player (bc_persona.archetype) in this engine's
 * table (the built-in kinds, and the setting archetype_table's); "?" for
 * none. */
const char *bc_engine_kind_name(const bc_engine *e, int kind);

/* WATCHING A BOT THINK (debug.c; the formats are specified in
 * bot/TREES.md). The core writes text into the host's buffer and does
 * no I/O; how often, and where it goes, is the host's.
 *
 * bc_engine_watch: have bot `pid`'s picks note what they weigh (bt.h's
 * tracing), or stop. It changes nothing the bot decides. A bot nobody
 * watches pays nothing; watching survives a change of tree, not the
 * bot's removal. */
void bc_engine_watch(bc_engine *e, int pid, int on);
int bc_engine_watched(const bc_engine *e, int pid);

/* One bot as JSON ("lsd-bt-snapshot"): who it is, what it perceives,
 * its route, and its tree as this engine holds it -- node ids, what is
 * RUNNING, timers, and each option's score, weight, factor, luck, sticky
 * and worth (those only while it is watched). Returns the length in
 * full; if that is not under out_size nothing usable was written (out
 * is ""): give a larger buffer. 0 for no such bot. */
size_t bc_engine_snapshot(const bc_engine *e, int pid, char *out, size_t out_size);

/* Every bot in a line each, the trees the engine has and the one the
 * world runs, as JSON ("lsd-bt-bots"). Sized as bc_engine_snapshot. */
size_t bc_engine_roster(const bc_engine *e, char *out, size_t out_size);

#endif
