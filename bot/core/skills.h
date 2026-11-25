/* skills.h -- What a tree's leaves do
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * A SKILL is the doing behind one `do <action>` of a tree: go there,
 * fight him, look into that noise. Each is a small machine that is asked
 * again at every decision (about 20 times a second) and answers RUNNING,
 * SUCCESS or FAILURE; what it must remember between two askings is in
 * the bot (brain.h), never in a static.
 *
 * WISHES, NOT KEYS. A skill does not write the bot's intent. It states
 * WISHES -- go to this place, look at that man, shoot him if you can,
 * hold the spade -- and the engine turns the wishes into keys, a facing
 * and a trigger EVERY think (bc_brain_act), with the follower (nav.h)
 * and the head (aim.h) in between. So the decision can be slow and the
 * body smooth, and two skills never fight over a key.
 *
 * WHO OWNS THE HEAD. Movement is relative to the facing, and nav's
 * follower says its facing "is not a suggestion": it simulated the move
 * with it. So:
 *   - on a jump, a drop, a pillar, an edit: the head is the follower's;
 *   - on a plain walk/sprint/crouch step with nothing to look at: also
 *     the follower's (a man walks looking where he goes);
 *   - on a plain step WITH something to look at (a target, a noise): the
 *     head is the aim model's, and the follower's keys are turned into
 *     the nearest keys for the facing the head really has (8 ways, so up
 *     to 22 degrees off; the follower corrects from the body's real place
 *     next tick). Sprint is dropped: one cannot run sideways.
 *   - with no route (strafing in a fight, standing): the aim model's.
 *
 * WHAT IS AOSBOT'S (docs/internals/04, 07; AI.cpp) AND WHY IT IS KEPT:
 *  - BURSTS by weapon, not by distance: rifle 0.15-0.35 s then a gap of
 *    0.5-1.1, SMG 0.35-0.8 / 0.4-0.9, shotgun 0.1-0.2 / 0.7-1.4; the gap
 *    counts from the burst's START. A trigger held is a turret.
 *  - The trigger only when the head the aim model PRODUCED is on him
 *    (aim.h's cone), twice the cone to keep a burst going.
 *  - ENGAGE RANGE = the gun's reach x (0.75 + 0.23 x aggression) x a
 *    per-bot fraction re-drawn for each new target (0.55 .. 1): bots do
 *    not all open at the same distance.
 *  - RANGE KEPT: hold = clamp(engage x 0.35, 6, 18), times the bot's
 *    character here (a marksman stays out, a pusher closes). Inside
 *    hold x 1.35 the route is dropped and the bot STRAFES: sideways with
 *    a pull in or out, direction re-drawn every 0.35-1.1 s.
 *  - Keys from a wanted direction with HYSTERESIS (on above 0.35, off
 *    below 0.15), against the facing the body really has: the facing
 *    wobbles with tremor and a flat threshold toggled keys on 44% of
 *    samples.
 *  - CROUCH in bouts (0.35-1.2 s, then 1.6-4.4 s without), more often
 *    by level and when just hit: it is the CHANGE of head height that
 *    spoils the other man's aim.
 *  - RELOAD: at once when dry; topped up out of a fight when the
 *    magazine is under 10% (level 1) to 48% (level 10); and only after
 *    the bot "noticed" (1.24 s down to 0.21 s).
 *  - After a sprint, 0.28 s before the first shot: stopping and firing
 *    on the same tick is the tell.
 *  - NO SHOT THROUGH A TEAM-MATE: a mate within 0.75 of the line, in
 *    front of the target, holds the fire for 0.35 s (a hold, not a
 *    per-tick veto, or the trigger stutters).
 *  - TARGET: the nearest in sight, but the one being fought is kept
 *    until another is at half his distance and 1.2 s have passed -- a
 *    per-tick nearest swapped several times a second and never fought.
 *    Whoever shot the bot, if in sight, beats a stranger.
 *  - SPADE when out of ammunition, or by whim (8% of fights) within 5.
 *  - GRENADES: bc_grenade_* below.
 *
 * NEW HERE (aosbot had none): retreat to cover, jump-dodging, pinging,
 * items, night. The numbers for those are first guesses, said so where
 * they stand.
 *
 * STANDING ON THE EDGE. Strafing has no route to keep it safe, so before
 * a direction is taken a copy of the body is walked that way through the
 * server's physics (body.h): if it would fall more than a step or end in
 * water, the other side is tried, then standing.
 */
#ifndef BC_SKILLS_H
#define BC_SKILLS_H

#include "bt.h"
#include "botlink.h"
#include "map.h"

/* The level's columns that are not aiming (aim.h has those): aosbot's
 * Level.cpp table, verbatim. All 0..1, all growing with the level. */
typedef struct bc_level_row {
	float aggression;   /* engage range fraction */
	float dodge;        /* strafe weave */
	float crouch;       /* crouch bouts a second in a fight */
	float sprint;       /* chance to start a run */
	float reload;       /* top-up threshold and notice delay */
	float threat_sense; /* how well a hit or a noise is read */
	float dig;          /* dig and build cadence */
	float grenade;      /* cook, accuracy, lead, dodging */
} bc_level_row;

const bc_level_row *bc_level(int level);

/* A gun's handling: reach, the server's interval between rounds, burst
 * and gap (seconds), magazine. */
typedef struct bc_gun_row {
	float reach, interval, burst_min, burst_max, gap_min, gap_max, reload_secs;
	int mag;
} bc_gun_row;

const bc_gun_row *bc_gun(int gun);

/* --- grenades (aosbot's Grenade.cpp) ----------------------------------
 * The server's flight: 60 steps a second, gravity one velocity unit a
 * second, 32 voxels a velocity unit, a bounce keeps 0.36 of the speed.
 * A throw is the look direction at speed 1, so it reaches 32 voxels at
 * most. */

/* Fly it. Returns where it bursts; `flight` (or NULL) gets the seconds
 * until then. */
bl_vec3 bc_grenade_fly(const bc_map *m, bl_vec3 pos, bl_vec3 vel, float fuse);

/* The arc from `from` onto `to`: lob = 0 the flat one, 1 the high one.
 * 0 if there is none (too far, too steep, over 3 s). */
int bc_grenade_arc(bl_vec3 from, bl_vec3 to, int lob, bl_vec3 *vel, float *flight);

/* Choose flat or lob on a PERFECT fuse, by where it really bursts on the
 * map (the lesson: measuring arc and cooking together made bots lob
 * everything). 0 if neither bursts within 4 voxels of `to`. */
int bc_grenade_plan(const bc_map *m, bl_vec3 from, bl_vec3 to, bl_vec3 *vel,
                    float *flight, bl_vec3 *burst);

/* What a burst at `at` does to a body at `body`: 4096 / d^2, 100 at
 * most, nothing through a wall or beyond 16 on an axis. */
float bc_grenade_damage(const bc_map *m, bl_vec3 at, bl_vec3 body);

/* --- the actions, as vocab.c registers them --------------------------- */

bt_status bc_do_fight(void *bot, const bt_args *a, float dt);
bt_status bc_do_go_to(void *bot, const bt_args *a, float dt);
bt_status bc_do_retreat(void *bot, const bt_args *a, float dt);
bt_status bc_do_investigate(void *bot, const bt_args *a, float dt);
bt_status bc_do_roam(void *bot, const bt_args *a, float dt);
bt_status bc_do_follow(void *bot, const bt_args *a, float dt);
bt_status bc_do_hold(void *bot, const bt_args *a, float dt);
bt_status bc_do_throw(void *bot, const bt_args *a, float dt);
bt_status bc_do_evade(void *bot, const bt_args *a, float dt);
bt_status bc_do_ping(void *bot, const bt_args *a, float dt);
bt_status bc_do_use(void *bot, const bt_args *a, float dt);
bt_status bc_do_lamp(void *bot, const bt_args *a, float dt);
bt_status bc_do_obey(void *bot, const bt_args *a, float dt);
bt_status bc_do_look_around(void *bot, const bt_args *a, float dt);
bt_status bc_do_reload(void *bot, const bt_args *a, float dt);
/* tell <name> [args...]: a word for the server's scripts (BL_AC_TELL):
 * SUCCESS at once. The same word from the same bot is sent at most once
 * in 0.2 s; one too soon is dropped (and counted), and still succeeds. */
bt_status bc_do_tell(void *bot, const bt_args *a, float dt);
/* skill_cover.c */
bt_status bc_do_crouch(void *bot, const bt_args *a, float dt);
bt_status bc_do_take_cover(void *bot, const bt_args *a, float dt);
bt_status bc_do_advance_by_cover(void *bot, const bt_args *a, float dt);
bt_status bc_do_fall_back_by_cover(void *bot, const bt_args *a, float dt);
void bc_do_cover_stop(void *bot, const bt_args *a);
/* skill_tactics.c */
bt_status bc_do_seek(void *bot, const bt_args *a, float dt);
bt_status bc_do_flank(void *bot, const bt_args *a, float dt);
bt_status bc_do_hunt_noise(void *bot, const bt_args *a, float dt);
bt_status bc_do_take_high_ground(void *bot, const bt_args *a, float dt);
bt_status bc_do_camp(void *bot, const bt_args *a, float dt);
bt_status bc_do_leave_water(void *bot, const bt_args *a, float dt);
void bc_do_tactics_stop(void *bot, const bt_args *a);
/* skill_build.c */
bt_status bc_do_build_at(void *bot, const bt_args *a, float dt);
bt_status bc_do_dig_at(void *bot, const bt_args *a, float dt);
bt_status bc_do_build_perch(void *bot, const bt_args *a, float dt);
void bc_do_build_stop(void *bot, const bt_args *a);
/* skill_objective.c */
bt_status bc_do_fetch(void *bot, const bt_args *a, float dt);
bt_status bc_do_carry_home(void *bot, const bt_args *a, float dt);
bt_status bc_do_escort(void *bot, const bt_args *a, float dt);
bt_status bc_do_intercept(void *bot, const bt_args *a, float dt);
bt_status bc_do_guard(void *bot, const bt_args *a, float dt);
void bc_do_objective_stop(void *bot, const bt_args *a);
/* what every moving action does when its branch is left: lets go */
void bc_do_stop(void *bot, const bt_args *a);

#endif
