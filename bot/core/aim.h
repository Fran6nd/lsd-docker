/* aim.h -- How a bot's head moves: human aim
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * Ported from aosbot (BasicAI::step_aim, aim_point, pick_aim_spot,
 * sights_on, update_threat; Level.cpp's table), whose docs/internals/
 * 09-aim-and-position.md holds the long form of what follows.
 *
 * WHAT THIS MODULE IS. One bot's head. Each tick it is told where the bot
 * would like to look -- at a target's body, or at a fixed point in the world
 * -- and answers with where the head IS looking this tick, whether that is
 * "on" the target well enough to pull the trigger, and the world point it
 * is aiming at. It never decides what to look at (that is the tree's), and
 * it never says where the head should be: it says where a person's would be.
 *
 * WHY IT IS NOT A SLEW. Two things made a converged aim read as a turret, and
 * a bang-bang turn (full rate, then dead stop on the target) read as a
 * machine. What reads as a person, and what is in here:
 *
 *  - A REACTION DELAY (0.50s at level 1 down to 0.14s at level 10) before a
 *    large new target (over 20 degrees) is acted on at all. Small changes --
 *    following a route, tracking a walking man -- are pursued smoothly and
 *    do not re-trigger it.
 *  - ACCELERATION AND EASE-OUT. Velocity is proportional to the remaining
 *    error (so it eases out as it arrives) but capped, and can only change
 *    so fast (so it eases in). A turn spends a fraction of its time at the
 *    cap, not all of it.
 *  - A TWO-PHASE FLICK. The primary movement lands short on average (95% of
 *    the way at level 10, 90% at level 1), then after a short settle a
 *    smaller corrective movement finishes. This saccade-and-correction is
 *    the single most recognisable feature of human aiming.
 *  - FLICKS THAT DIFFER. Every flick used to be the same shape, and across a
 *    fight that read as a turret even when each one looked fine. A long
 *    flick is thrown faster than a short one (the "main sequence": 0.75x the
 *    turn rate for 20 degrees, 1.25x for a turn round, +-10%), the faster
 *    it is thrown the wider it lands, often past the target, then the pull
 *    back. On a turn over 35 degrees there is a chance (8% at level 10, 30%
 *    at level 1) it is THROWN at 1.3-1.6x that speed, capped at 2x. So the
 *    table's turn rate is the speed of an ordinary turn, not a ceiling.
 *    "How sloppy" is read off aim_error, which the level already sets.
 *  - TREMOR AND SWAY. Three incommensurate sines per axis; the slowest and
 *    largest reads as postural sway (what stops a stationary bot being a
 *    tripod -- pure high-frequency jitter reads as noise, not a person
 *    breathing). Applied to the OUTPUT only, never fed back into the
 *    control loop, so it cannot be "corrected out".
 *  - AIM ERROR THAT WANDERS. Not a random offset re-rolled and teleported to
 *    (the view jumped several times a second): it DRIFTS towards each new
 *    offset (~0.3s time constant). A third of the moves are an over-
 *    correction: haul it back and overshoot to the OTHER side. Careful how
 *    that is written: pulling the error back towards zero (the obvious way)
 *    quietly makes the bot a better shot, because a third of the wander is
 *    then spent near the middle. It draws a fresh magnitude from the same
 *    uniform distribution as a drift and forces only the sign, so the
 *    average miss is unchanged and only its character differs.
 *  - A RANGE FACTOR on that error. Error is angular: six degrees is one
 *    block of miss at ten blocks and ten at a hundred, so no long shot
 *    could ever land. People steady up for a far target: full error inside
 *    15 blocks, tapering to 40% at 90+. Away from a target (looking around,
 *    following a route) the error is 20% -- there is nothing to miss, and
 *    full wander there reads as glancing about at random. It eases between
 *    the two, so entering or leaving a fight does not step the aim.
 *  - WHERE ON THE BODY. Always aiming at centre mass made every bot a
 *    turret. A spot is drawn per ENGAGEMENT (per new target id): 12% head,
 *    33% upper chest, 43% centre mass, 12% low, and the point of aim creeps
 *    slowly round the silhouette (+-0.18 across, +-0.22 up and down),
 *    perpendicular to the line of sight so it is a visible sideways drift
 *    and not an invisible one along the depth axis. Aiming at the head from
 *    afar mostly misses (the head box is +-0.35, the torso +-1.10): that is
 *    realistic. The level's aim_spot scales all of it; 0 is dead centre.
 *  - A STALE LEAD. The aim offsets the target by an estimate of where it is
 *    going that is deliberately a fifth of a second out of date (an EMA with
 *    a 0.22s time constant) times a per-bot horizon of 0.03-0.12s. While the
 *    target moves steadily this cancels the control loop's lag; the moment
 *    it changes direction the estimate still points the old way, so the aim
 *    sweeps past and has to be dragged back. That overshoot is the tell.
 *    Note velocity matching makes the aim MORE accurate on average: the
 *    realism is in the shape of the error, not its size (measured on a
 *    strafing target: 74% of the miss behind, 26% past). A man in the air
 *    has a trajectory already decided, so there is nothing for a belief to
 *    be out of date about: the staleness is skipped while he is airborne.
 *  - FLINCH, and being shot. See bc_aim_events.
 *
 * CONVENTIONS. World z grows DOWNWARD (Ace of Spades): the eye is the
 * player's reported position, a bigger z offset is further down the body,
 * and pitch is asin(dir.z): positive looks DOWN. Orientations are unit
 * vectors; yaw is atan2(y, x). Pitch is held to +-1.53 rad (87.7 degrees):
 * the last degrees are left alone because a perfectly vertical vector makes
 * yaw meaningless and the orientation packet jitter.
 *
 * Time is dt in seconds (a tick; sub-stepped if over 50ms), randomness is
 * the bc_rng the caller owns, in a fixed order, so a seed and the same
 * inputs are the same bot. No globals, no allocation, no I/O.
 *
 * NOT PORTED, on purpose: aosbot's "explicit override" tuning (negative
 * reaction/tremor meaning "derive"): here both are plain numbers in the
 * tuning struct, filled from the table, and a caller that wants another
 * number sets it. The level table's NON-aim columns (aggression, dodge,
 * crouch, sprint, path, reload, dig, grenades, objective bias) are not
 * aiming and belong to the layers that use them.
 */
#ifndef BC_AIM_H
#define BC_AIM_H

#include "rng.h"

typedef struct bc_aim_v3 { float x, y, z; } bc_aim_v3;

/* Everything a level decides about aiming and reacting. Fill it with
 * bc_aim_set_level, then change a field if one bot must differ. */
typedef struct bc_aim_tuning {
	float aim_error_deg;     /* the wander's amplitude: the aim cone */
	float turn_deg_per_sec;  /* speed of an ordinary turn */
	float reaction_sec;      /* delay before acting on a large new target */
	float tremor_deg;        /* amplitude of tremor/sway (derived from aim_error) */
	float aim_spot;          /* 0..1: how far from centre mass the spot strays */
	float track_error;       /* 0..1: 0 a turret, 1 a person's lag and overshoot */
	float threat_sense;      /* 0..1: how well a hit is read: when and from where */
} bc_aim_tuning;

/* Fill from the level table in aim.c (1-10; out of range clamps). */
void bc_aim_set_level(bc_aim_tuning *t, int level);

/* One bot's head. Plain data: the caller owns it, copying it is a save. */
typedef struct bc_aim {
	bc_aim_tuning tune;
	int init;                 /* has an orientation yet */
	float yaw, pitch;         /* where the head actually is (before tremor) */
	float yaw_vel, pitch_vel;
	float tgt_yaw, tgt_pitch; /* what the head is chasing right now */
	float want_yaw, want_pitch; /* what was last asked for */
	float react_left;
	int react_pending, correcting;
	float settle_left, flick_speed;
	float tremor_t, tremor_phase[6], tremor_gain;
	float err_yaw, err_pitch, err_yaw_target, err_pitch_target;
	float err_reroll_left, err_tau, err_scale, err_scale_target;
	/* the target being tracked */
	int target_id;            /* -1: none */
	bc_aim_v3 track_vel;      /* the (stale) belief about its velocity */
	float lead_t;             /* per-bot velocity-matching horizon */
	float spot_z, spot_wander_t, spot_phase;
	/* being shot */
	float flinch_left, flinch_yaw, flinch_pitch;
	float threat_react_left, threat_left;
	int threat_look_valid;
	float threat_yaw, threat_pitch;
	/* last output */
	bc_aim_v3 ori;
} bc_aim;

/* Start a head looking along `ori` (any length; zero looks along +x), with
 * its character drawn from `rng` (phases, lead horizon, first aim spot). */
void bc_aim_init(bc_aim *a, bc_rng *rng, int level, bc_aim_v3 ori);

/* A new body faces the way it is going: look along `ori` at once, with no
 * reaction and no velocity. aosbot kept the last life's orientation across a
 * death, and a bot that died facing its killer spawned facing the same
 * bearing, was handed a route and set off along it while the head took its
 * reaction delay and two-phase turn to come round: half a second of walking
 * forward looking backward, on every spawn. Nobody can see the instant (the
 * player has only just appeared). Do NOT snap to a target: a man already in
 * view on the first tick gets the ordinary turn, because a bot that
 * materialises with its sights on somebody is the other kind of wrong. */
void bc_aim_snap(bc_aim *a, bc_aim_v3 ori);

typedef struct bc_aim_target {
	bc_aim_v3 pos;     /* the eye (reported position) of the target */
	bc_aim_v3 vel;     /* its velocity, blocks/s: what is known of it */
	int crouched;      /* lowers the body: the spot is moved down with it */
	int airborne;      /* skips the lead's staleness */
	int id;            /* >= 0. A new id is a new engagement: a new aim spot */
} bc_aim_target;

typedef struct bc_aim_events {
	int hit;                 /* the bot was hit this tick */
	bc_aim_v3 hit_from;      /* where the shot came from (attacker or grenade) */
	int hit_from_valid;      /* ... and whether that is known */
} bc_aim_events;

typedef struct bc_aim_out {
	bc_aim_v3 ori;      /* unit: the direction to look along this tick */
	bc_aim_v3 point;    /* the world point being aimed at (eye+ori if none) */
	int on_target;      /* inside the firing cone for the range */
	float off_deg;      /* the angle behind that: ori to the point */
} bc_aim_out;

/* One tick, looking at a target body (target != NULL) or holding the last
 * heading (NULL). `eye` is the bot's own eye, `current_ori` the orientation
 * its body has now: a head that is not yet started is born from it, and one
 * that finds the body somewhere else than it left it (it was moved: a
 * teleport, a respawn) is snapped to it. `firing` is a burst in progress:
 * you do not stop a burst because he twitched a degree out of the middle of
 * it, so the cone is twice as wide. `ev` may be NULL.
 *
 * Fire discipline is the cone (see the .c): "on target" is asked of the aim
 * the model has actually produced, error and tremor included, not of the
 * direction it would like to look in -- otherwise a bot that acquired
 * someone behind it opened fire on the spot and swung round still
 * shooting. Whether to shoot at all (range, ammo, bursts) is the caller's.
 *
 * With no target, a hit with a known source turns the head to it after the
 * bot's threat-reaction time, with a bearing error that grows as threat_sense
 * falls (see aim.c). `out` may not be NULL. */
void bc_aim_step(bc_aim *a, bc_rng *rng, float dt, bc_aim_v3 eye,
                 bc_aim_v3 current_ori, const bc_aim_target *target,
                 const bc_aim_events *ev, int firing, bc_aim_out *out);

/* One tick, looking at a fixed world point: the same human motion with no
 * target body (looking around, following a route, steering a guided
 * missile). The low error scale of "nothing to miss" applies, and no spot,
 * lead or range factor. */
void bc_aim_step_point(bc_aim *a, bc_rng *rng, float dt, bc_aim_v3 eye,
                       bc_aim_v3 current_ori, bc_aim_v3 point,
                       const bc_aim_events *ev, int firing, bc_aim_out *out);

/* The cone, in radians, that counts as "on him" at this range. A player is
 * about 0.8 blocks across and 2.8 tall; his exact angular width would be a
 * marksman's discipline and, with degrees of error on top, would mean almost
 * never pulling the trigger. 1.2 blocks -- a bit wider than he is -- is what
 * a person looks like: on him, or nearly. The floor (1.5 degrees) keeps a
 * long shot possible, the ceiling (25) stops it being meaningless at arm's
 * length. */
float bc_aim_fire_cone(float dist);

#endif
