/* senses.h -- What one bot knows
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * The world the server writes tells the ENGINE where everybody is. A bot
 * must not act on that: it acts on what a player in its shoes could have
 * perceived. This module is the filter between the two. Everything above
 * it (the skills, the tree's conditions) asks the senses, never the world,
 * about an enemy. Team-mates are the exception: a client draws them on
 * the map, so their places are simply known.
 *
 * SIGHT (from aosbot's AI.cpp, docs/internals/04 and 09):
 *  - A FIELD OF VIEW of 180 degrees, horizontal: 90 either side of the
 *    facing. A client draws about 100, but what is at the edge of the
 *    screen is "known" all the same; the tell that had to go was the man
 *    BEHIND being shot at once, not the one beside.
 *  - RANGE 128, the fog.
 *  - CLOSE THINGS ARE NOTICED whatever the facing: within 8 voxels a man
 *    is audible. New here: that is his footsteps, so one who is crouched,
 *    sneaking or standing still is only noticed at half of it.
 *  - Once seen, a man stays "noticed" for 6 seconds: stepping round the
 *    bot's back does not make him vanish.
 *  - LINE OF SIGHT is three rays from the eye, to his head, his chest and
 *    his legs, through the server's own ray cast; any one clear and he is
 *    seen. One ray at ankle height broke on every kerb, one at the head
 *    missed a man in a trench.
 *  - The cheap tests come first, the rays last (aosbot once cast 90 rays
 *    a tick for each bot).
 *
 * NIGHT (new, aosbot had none). OFF unless the server turns it on (the
 * setting night.sight=1, sent by its night script with the lamp's cone
 * and reach): without it bl_world.night and lamps change nothing about
 * what a bot sees, and a server with no night script has plain day
 * bots. With it, by night, three rows and no more:
 *  1. A bot WITH NIGHT VISION (the setting night_vision=1, per bot) sees
 *     everybody as by day -- same field of view, range, line of sight --
 *     lamp or no lamp; and whoever has a lamp LIT it sees from farther
 *     than by day (night.far, 192: one and a half times the day's).
 *  2. A bot with its LAMP LIT and no night vision sees ONLY what is in
 *     its own cone of light: night.cone (90 degrees in all) along where
 *     it looks, out to night.reach (60) -- the server's flashlight
 *     (lib_flashlight: flashlight_cone, flashlight_reach). Nothing
 *     outside it, however close, however lit.
 *  3. A bot with its lamp OUT and no night vision sees NOTHING.
 *  Hearing, being hurt and what the team tells are not sight and work
 *  by night as by day: they give a place to turn to or go to, never a
 *  man to shoot. A bot fires only at what it SEES by these rows. So a
 *  lamp is a choice -- lit, the bot sees and gives itself away to those
 *  who can see; out, it is blind -- and the choice is its character's
 *  (the tree).
 *
 * MEMORY. For each enemy: where he was last seen, how he was moving and
 * when. It is kept `memory` seconds (12) and trusted less as it ages
 * (bc_senses_confidence): a place to go and look, never a target.
 *
 * HEARING (BL_EV_SOUND). A noise is a PLACE TO LOOK AT OR GO TO, not a
 * target. Ranges grow with the level, linearly from level 1 to 10:
 *    a shot       14 .. 34     (aosbot)
 *    dig, build    6 .. 14     (aosbot)
 *    a step        4 ..  8
 *    a blast      24 .. 48     (a grenade, a collapse)
 *  A spade hitting a player makes no sound event at all (the server's
 *  choice): melee is silent. A noise whose maker is in sight is dropped
 *  (he is a target already); so is a team-mate's. One noise is held: a
 *  new one replaces it once it is 1.2 s old or if it is nearer.
 *
 * BEING HURT (BL_EV_HURT) says roughly where from: the bearing is wrong
 * by up to 40 degrees at level 1 and 4 at level 10 -- the error is on the
 * BEARING, so a poor bot turns to the wrong doorway and stays there.
 *
 * ALERTNESS, what the three above add up to:
 *    CALM         nothing known
 *    SUSPICIOUS   heard something, was hurt, or lost somebody: there is
 *                 a place worth searching (bc_senses_search)
 *    ENGAGED      somebody in sight, or was until 1.5 s ago
 *
 * THE BOARD, a team's shared knowledge. What one bot sees its team-mates
 * may be told: a sighting goes on the team's board, and once it has stood
 * `relay` seconds (1.5: the time to say it) every bot of the team knows
 * the place -- as a place, not as a man in its sights. The pings that
 * stand are kept there too (who called, where, what for, who answered).
 *
 * No clock, no allocation, no globals: time is `now`, a number of seconds
 * the caller counts.
 */
#ifndef BC_SENSES_H
#define BC_SENSES_H

#include <stdint.h>

#include "botlink.h"
#include "map.h"
#include "rng.h"

typedef struct bc_sense_cfg {
	float sight;            /* 128 */
	float fov_deg;          /* 180, the whole angle */
	float notice;           /* 8 */
	float lamp_range;       /* 60 */
	float lamp_cone_deg;    /* 90, the whole angle */
	float lit_range;        /* 192: night vision, of a lit lamp */
	int night_sight;        /* 0: night is seen as day */
	float memory;           /* 12 s */
	float relay;            /* 1.5 s */
	float board;            /* 10 s: how long a relayed sighting is worth telling */
	float noise_secs;       /* 10 s: how long a noise is worth going to */
} bc_sense_cfg;

void bc_sense_cfg_default(bc_sense_cfg *c);
/* A setting ("sight", "fov", "notice", "memory", "relay", "board",
 * "noise_secs"; "night.sight", "night.cone", "night.reach", "night.far"):
 * 1 if the key was one of these. */
int bc_sense_cfg_set(bc_sense_cfg *c, const char *key, float value);

enum bc_alert { BC_ALERT_CALM = 0, BC_ALERT_SUSPICIOUS = 1, BC_ALERT_ENGAGED = 2 };

/* how a visible man is seen */
enum { BC_SEE_VIEW = 1, BC_SEE_CLOSE = 2, BC_SEE_LIT = 4, BC_SEE_LAMP = 8 };

/* the kinds of ping a bot tells apart (see bc_ping_kind) */
enum bc_ping_kind { BC_PING_NONE = 0, BC_PING_ENEMY, BC_PING_HELP, BC_PING_GO };

typedef struct bc_known {
	bl_vec3 pos, vel;       /* as last seen (or told) */
	double seen_at;         /* by this bot's own eyes; < 0: never */
	double told_at;         /* the board's news of him; < 0: none */
	double dismissed;       /* board news up to then was gone and looked at */
	uint8_t visible;        /* in sight now */
	uint8_t how;            /* BC_SEE_* */
	uint8_t pad_[6];
} bc_known;

typedef struct bc_place {
	bl_vec3 pos;
	double at;
	uint8_t valid, kind, by;
	uint8_t pad_[5];
} bc_place;

typedef struct bc_senses {
	bc_known k[BL_MAX_PLAYERS];
	int n_visible;
	int nearest;            /* nearest visible enemy, or -1 */
	int nearest_known;      /* nearest enemy known but not in sight, or -1 */
	bc_place noise;         /* kind: bl_sound */
	bc_place threat;        /* where a hit seemed to come from; by: who, if known */
	float threat_dist;      /* how far the shooter really was */
	bc_place lost;          /* where the last man to leave sight was heading */
	double last_sight;      /* when anybody was last in sight */
	double hurt_at;
	double spotted_new_at;  /* saw somebody the team's board did not know */
	uint8_t alert;          /* bc_alert */
	uint8_t pad_[7];
} bc_senses;

/* --- the board -------------------------------------------------------- */

enum { BC_BOARD_PINGS = 8 };

typedef struct bc_spot {
	bl_vec3 pos;
	double at;              /* last seen by anybody of the team; < 0: never */
	double since;           /* start of this run of sightings */
	uint8_t by;
	uint8_t pad_[7];
} bc_spot;

typedef struct bc_ping {
	bl_vec3 pos;
	double at, until;
	uint8_t valid, kind, by, takers;
	uint8_t pad_[4];
	uint32_t id;
} bc_ping;

typedef struct bc_board {
	bc_spot spot[2][BL_MAX_PLAYERS];        /* [team - 1][enemy pid] */
	bc_ping ping[2][BC_BOARD_PINGS];
	uint32_t next_ping;
} bc_board;

void bc_board_clear(bc_board *b);
/* A ping called for `team` (1 or 2). Returns it; the oldest gives way. */
bc_ping *bc_board_ping(bc_board *b, int team, int by, bl_vec3 pos, int kind,
                       double now, double secs);
/* Is there a ping of this kind standing within `radius` of pos? */
int bc_board_pinged(const bc_board *b, int team, bl_vec3 pos, int kind,
                    float radius, double now);

/* What a ping's words mean. aosbot's ordered keyword table, cut to what
 * a bot here can do: "enemy", "sniper", "danger", "attack", "contact",
 * "spotted", "hostile" are ENEMY (go and fight there); "help", "backup",
 * "cover", "escort", "follow" are HELP (come to the caller); anything
 * else, the empty reason included, is GO -- a ping is a place first.
 * "yes", "no", "thanks", "affirmative", "negative" are NONE. */
int bc_ping_kind(const char *reason);

/* --- one bot's senses -------------------------------------------------- */

void bc_senses_reset(bc_senses *s);

/* Look: fills in who is visible, the memory, the alertness. `board` may
 * be NULL (a bot alone). `self` must be alive in `w`. `night_vision`:
 * does this bot have it (it only matters by night). */
void bc_senses_see(bc_senses *s, const bc_sense_cfg *c, const bc_map *m,
                   const bl_world *w, int self, int night_vision, double now, bc_board *board);

/* A noise was made at `pos` by `by` (or BL_NO_PLAYER). 1 if this bot
 * heard it and now holds it. */
int bc_senses_hear(bc_senses *s, const bc_sense_cfg *c, const bl_world *w, int self,
                   int level, int kind, bl_vec3 pos, int by, double now);

/* This bot was hurt; `from` is where the server says it came from. A
 * hurt whose `from` is the bot's own place (a fall, drowning) tells
 * nothing. */
void bc_senses_hurt(bc_senses *s, bc_rng *rng, const bl_world *w, int self, int level,
                    bl_vec3 from, int by, double now);

/* How far a noise of this kind carries to a bot of this level. */
float bc_hear_range(int kind, int level);

/* 1 down to 0 as the memory of `pid` ages; 1 while he is in sight. */
float bc_senses_confidence(const bc_senses *s, const bc_sense_cfg *c, int pid, double now);

/* The place most worth searching, if any: a man just lost, a hit's
 * source, a noise, a told sighting -- the freshest. `what` (or NULL)
 * gets 1 lost, 2 threat, 3 noise, 4 told. */
int bc_senses_search(const bc_senses *s, const bc_sense_cfg *c, double now,
                     bl_vec3 *out, int *what);
/* That place has been looked at (or cannot be reached): forget it. */
void bc_senses_searched(bc_senses *s, int what);

/* Is there a clear line from an eye to a point? (the server's ray cast) */
int bc_sight_clear(const bc_map *m, bl_vec3 eye, bl_vec3 point);
/* Could an eye at `eye` see a body whose eye is at `body`? Three rays. */
int bc_sight_body(const bc_map *m, bl_vec3 eye, bl_vec3 body, int crouched);

#endif
