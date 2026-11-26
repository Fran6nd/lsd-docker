/* aim.c -- How a bot's head moves: human aim. See aim.h for what and why.
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * Ported from aosbot src/AI.cpp (step_aim, set_aim_target, aim_point,
 * pick_aim_spot, sights_on, update_threat) and src/Level.cpp. The constants
 * are aosbot's, tuned against real servers: change one only with a reason.
 */
#include "aim.h"

#include <math.h>

#define DEG2RAD 0.0174532925f
#define TWO_PI 6.2831853f
/* How far up or down the view can be pointed. Was 1.45 rad, which is plenty
 * on the flat and not quite enough for a man on a tower the bot stands at
 * the foot of -- the aim saturated a few degrees short of him and sat there.
 * The last degrees are left alone: a vertical vector makes yaw meaningless. */
#define MAX_PITCH 1.53f
/* A change in what is wanted bigger than this is a "large new target": it
 * is waited on (reaction) and flicked at, rather than followed. */
#define BIG_CHANGE (20.0f * DEG2RAD)

/* How the head's velocity is driven: proportional to the error, capped, and
 * changing no faster than cap * ACCEL_PER_CAP per second. */
#define GAIN 9.0f
#define ACCEL_PER_CAP 7.0f

/* Being shot (aosbot AI.cpp:908-917): how long a bot takes to react to a hit
 * and how far out its reading of where it came from can be, across
 * threat_sense. The bottom of the table is meant to be genuinely bad: nearly
 * a second late and up to forty degrees off is a bot that turns towards the
 * wrong doorway and gets hit again while it stands there, which is exactly
 * what a rookie does. The error goes on the BEARING rather than on the aim:
 * a player who misreads where a shot came from turns to the wrong place and
 * stays there until the next round arrives. */
#define THREAT_REACT_MIN 0.15f
#define THREAT_REACT_MAX 0.95f
#define THREAT_BEARING_ERR_MIN 4.0f
#define THREAT_BEARING_ERR_MAX 40.0f
/* How long a hit keeps the head pointed that way: a reflex, not a plan. */
#define THREAT_MEMORY_SEC 6.0f
/* How much twitchier a bot is, for a moment, after being hit (aosbot:
 * kFlinchScale, 1.0-2.2s). Here the twitch is the tremor's gain. */
#define FLINCH_SCALE 1.6f

/* If the body's orientation is further than this from where the head left
 * it, something else moved it (a teleport, a respawn): follow it, do not
 * turn from the old bearing with a reaction delay. */
#define RESYNC_DEG 60.0f

/* A man's feet under his eye (the reported position), standing and
 * crouched: the server's body (lsd demoncore.c boxclipmove: 0.9 + 1.35,
 * 0.45 + 0.9). Where on the body a spot is is drawn on the standing one.
 * The sea is the map's bottom layer, solid to a bullet, its top face at
 * SEA_TOP: a man wading is in it to the knees (his feet at 64), and what
 * is under that is not there to be shot. */
#define BODY_STANDING 2.25f
#define BODY_CROUCHED 1.35f
#define SEA_TOP 63.0f

/* ------------------------------------------------------------------------
 * THE LEVEL TABLE. The one place to tune how good a level is at aiming and
 * reacting: every per-level number aosbot has that concerns it. Monotonic
 * in every column (aosbot's leveltest checks that, because a table of this
 * shape is where a typo hides). Level 5 is close to aosbot's old "normal"
 * (aim error 6, 180 deg/s); level 3 about "easy" and 8 about "hard".
 *
 *  aim    the aim cone, degrees: the wander's amplitude. It also decides how
 *         sloppy a flick's landing is, and tremor (0.35 + 0.08 * aim deg).
 *  turn   deg/s of an ordinary turn (a long flick runs 1.25x, a short 0.75x)
 *  spot   0..1 how far from dead centre the spot on the body strays
 *  track  0..1 how much the lead lags: 0 a turret, 1 a person
 *  react  seconds before acting on a large new target (+0..0.08 random)
 *  sense  threat_sense, 0..1: reaction to a hit 0.95s..0.15s, bearing error
 *         40..4 degrees
 *
 * A level moves all of them together because that is what separates a weak
 * player from a strong one: it is not just a wider cone, a weak player also
 * reacts later and sprays the shot over the body. Pull one out of step and
 * the bot reads as a good bot with a handicap, which is what people notice.
 * ---------------------------------------------------------------------- */
typedef struct level_row {
	float aim, turn, spot, track, react, sense;
} level_row;

static const level_row LEVELS[10] = {
	/*  aim    turn   spot   track  react  sense */
	{ 14.0f,  90.f, 1.00f, 1.00f, 0.50f, 0.06f },  /* 1 */
	{ 11.5f, 110.f, 1.00f, 1.00f, 0.44f, 0.15f },  /* 2 */
	{  9.5f, 130.f, 0.98f, 0.98f, 0.39f, 0.25f },  /* 3 */
	{  7.8f, 152.f, 0.94f, 0.94f, 0.34f, 0.35f },  /* 4 */
	{  6.2f, 175.f, 0.90f, 0.88f, 0.30f, 0.45f },  /* 5 */
	{  5.0f, 200.f, 0.82f, 0.78f, 0.26f, 0.55f },  /* 6 */
	{  4.0f, 225.f, 0.72f, 0.66f, 0.23f, 0.65f },  /* 7 */
	{  3.2f, 250.f, 0.62f, 0.54f, 0.20f, 0.75f },  /* 8 */
	{  2.5f, 282.f, 0.50f, 0.42f, 0.17f, 0.86f },  /* 9 */
	{  1.8f, 320.f, 0.38f, 0.30f, 0.14f, 0.96f },  /* 10 */
};

void bc_aim_set_level(bc_aim_tuning *t, int level)
{
	if (level < 1) level = 1;
	if (level > 10) level = 10;
	const level_row *r = &LEVELS[level - 1];
	t->aim_error_deg = r->aim;
	t->turn_deg_per_sec = r->turn;
	t->reaction_sec = r->react;
	/* Derived, not a column: it tracks the aim cone, so two knobs do not
	 * quietly fight over the same thing. */
	t->tremor_deg = 0.35f + r->aim * 0.080f;
	t->aim_spot = r->spot;
	t->track_error = r->track;
	t->threat_sense = r->sense;
}

/* ------------------------------------------------------------------------ */

static float clampf(float v, float lo, float hi)
{
	return v < lo ? lo : (v > hi ? hi : v);
}

static int finite3(bc_aim_v3 v)
{
	return isfinite(v.x) && isfinite(v.y) && isfinite(v.z);
}

/* Shortest signed distance between two angles, in (-pi, pi]. Finite input
 * only (a NaN would spin the loop for ever); every caller has checked. */
static float wrap_angle(float a)
{
	if (!isfinite(a)) return 0.0f;
	while (a > 3.14159265f) a -= 6.28318531f;
	while (a < -3.14159265f) a += 6.28318531f;
	return a;
}

static bc_aim_v3 v3(float x, float y, float z)
{
	bc_aim_v3 r = { x, y, z };
	return r;
}

static bc_aim_v3 dir_from_yaw_pitch(float yaw, float pitch)
{
	float cp = cosf(pitch);
	return v3(cp * cosf(yaw), cp * sinf(yaw), sinf(pitch));
}

/* The yaw and pitch of a direction; 0 when it has no length. A direction
 * that is vertical (or nearly) keeps `*yaw`: atan2(0,0) would turn the head
 * to face +x, which is not what looking at a man on a tower means. */
static int yaw_pitch_of(bc_aim_v3 d, float *yaw, float *pitch)
{
	float len = sqrtf(d.x * d.x + d.y * d.y + d.z * d.z);
	if (!(len > 1e-4f)) return 0;
	float nx = d.x / len, ny = d.y / len, nz = d.z / len;
	if (fabsf(nx) > 1e-4f || fabsf(ny) > 1e-4f) *yaw = atan2f(ny, nx);
	*pitch = asinf(clampf(nz, -1.0f, 1.0f));
	return 1;
}

/* atan2(|a x b|, a.b), not acos(a.b): acos loses all precision for nearly
 * parallel vectors, which is where sub-degree tremor lives. */
static float angle_between(bc_aim_v3 a, bc_aim_v3 b)
{
	float cx = a.y * b.z - a.z * b.y;
	float cy = a.z * b.x - a.x * b.z;
	float cz = a.x * b.y - a.y * b.x;
	float cross = sqrtf(cx * cx + cy * cy + cz * cz);
	float dot = a.x * b.x + a.y * b.y + a.z * b.z;
	return atan2f(cross, dot);
}

float bc_aim_fire_cone(float dist)
{
	float d = dist < 1.0f ? 1.0f : dist;
	if (!(dist == dist)) d = 1.0f;
	return clampf(atanf(1.2f / d), 1.5f * DEG2RAD, 25.0f * DEG2RAD);
}

/* A roughly normal deviate in [-3, 3], std ~1 (sum of three uniforms). In
 * statements, not one expression: the order of draws must be defined. */
static float gauss3(bc_rng *rng)
{
	float a = bc_rng_float(rng);
	float b = bc_rng_float(rng);
	float c = bc_rng_float(rng);
	return (a + b + c - 1.5f) * 2.0f;
}

/* Where on the body this engagement's sight goes. z grows downward and the
 * eye is the reported position, so a bigger offset is further down. Weighted
 * the way people shoot: centre mass most of the time, the head now and then,
 * and every so often too low, the classic way to miss. At spread 0 every
 * bot aims dead centre. (Measured over 400 engagements at 11/36/40/13.) */
static void pick_aim_spot(bc_aim *a, bc_rng *rng)
{
	float spread = clampf(a->tune.aim_spot, 0.0f, 1.0f);
	float r = bc_rng_float(rng);
	float spot;
	if (r < 0.12f) spot = 0.15f;       /* head */
	else if (r < 0.45f) spot = 1.00f;  /* upper chest */
	else if (r < 0.88f) spot = 1.50f;  /* centre mass */
	else spot = 2.00f;                 /* low */
	a->spot_z = 1.5f + (spot - 1.5f) * spread;
	a->spot_phase = bc_rng_float(rng) * TWO_PI;
}

void bc_aim_snap(bc_aim *a, bc_aim_v3 ori)
{
	float y = a->yaw, p = a->pitch;
	if (!finite3(ori) || !yaw_pitch_of(ori, &y, &p)) return;
	a->yaw = a->tgt_yaw = a->want_yaw = y;
	a->pitch = a->tgt_pitch = a->want_pitch = clampf(p, -MAX_PITCH, MAX_PITCH);
	a->yaw_vel = a->pitch_vel = 0.0f;
	a->react_left = 0.0f;
	a->react_pending = 0;
	a->correcting = 0;
	a->flick_speed = 1.0f;
	a->threat_react_left = 0.0f;
	a->threat_left = 0.0f;
	a->threat_look_valid = 0;
	a->ori = dir_from_yaw_pitch(a->yaw, a->pitch);
}

void bc_aim_init(bc_aim *a, bc_rng *rng, int level, bc_aim_v3 ori)
{
	bc_aim zero = { 0 };
	*a = zero;
	bc_aim_set_level(&a->tune, level);
	a->init = 1;
	a->tremor_gain = 1.0f;
	a->err_tau = 0.30f;
	a->err_scale = a->err_scale_target = 0.2f;
	a->flick_speed = 1.0f;
	a->target_id = -1;
	/* Drawn once per bot: the phases of the six sines, how hard it tries to
	 * match a target's motion (0.03-0.12s), and a first aim spot. */
	for (int i = 0; i < 6; i++) a->tremor_phase[i] = bc_rng_float(rng) * TWO_PI;
	a->lead_t = 0.03f + bc_rng_float(rng) * 0.09f;
	pick_aim_spot(a, rng);
	a->yaw = a->pitch = 0.0f;
	bc_aim_snap(a, ori);
	if (!(finite3(ori) && (ori.x != 0.0f || ori.y != 0.0f || ori.z != 0.0f))) {
		a->yaw = a->tgt_yaw = a->want_yaw = 0.0f;
		a->pitch = a->tgt_pitch = a->want_pitch = 0.0f;
		a->ori = v3(1.0f, 0.0f, 0.0f);
	}
}

/* The motion itself: advance the head one sub-step towards want_yaw/pitch.
 * aosbot's step_aim, with the old comments' reasons kept. */
static void core_step(bc_aim *a, bc_rng *rng, float dt)
{
	const bc_aim_tuning *tn = &a->tune;
	const float max_vel = fmaxf(1.0f, tn->turn_deg_per_sec) * DEG2RAD;
	const float react_base = tn->reaction_sec;
	const float tremor_rad = tn->tremor_deg * DEG2RAD;

	/* --- decide what we are chasing --- */
	const float d_yaw = wrap_angle(a->want_yaw - a->tgt_yaw);
	const float d_pitch = a->want_pitch - a->tgt_pitch;
	const float change = sqrtf(d_yaw * d_yaw + d_pitch * d_pitch);

	if (a->react_left > 0.0f) {
		a->react_left -= dt; /* still reacting: keep looking where we were */
		if (a->react_left <= 0.0f && a->react_pending) {
			/* Primary saccade: a flick, then a smaller movement to clean it
			 * up. A person's flicks follow the "main sequence" -- a long one
			 * is thrown faster than a short one -- and a faster throw lands
			 * wider, often past the target: the big inaccurate snap and pull
			 * back of somebody just shot from behind. How sloppy the landing
			 * is comes from the aim cone, which the level already sets, so an
			 * ace throws a flick as fast as anybody but lands it. */
			const float dy = wrap_angle(a->want_yaw - a->tgt_yaw);
			const float dp = a->want_pitch - a->tgt_pitch;
			const float amp_deg = sqrtf(dy * dy + dp * dp) / DEG2RAD;
			const float sloppy = clampf((tn->aim_error_deg - 1.5f) / 12.5f, 0.0f, 1.0f);
			/* 0.75x the turn rate for a 20 degree flick, 1.25x for a turn
			 * round, with a little variation so no two are identical. */
			float speed = clampf(0.65f + amp_deg / 180.0f, 0.75f, 1.25f);
			speed *= 0.9f + 0.2f * bc_rng_float(rng);
			/* Now and then it is THROWN: a snap well past the ordinary
			 * rate. More often from a sloppy hand, and only on a long turn. */
			int thrown = 0;
			if (amp_deg > 35.0f) {
				float roll = bc_rng_float(rng);
				if (roll < 0.08f + 0.22f * sloppy) {
					speed *= 1.3f + 0.3f * bc_rng_float(rng);
					thrown = 1;
				}
			}
			a->flick_speed = fminf(speed, 2.0f);
			/* Where it lands: short of the target on average (humans
			 * overwhelmingly undershoot) -- an ace by 5%, a novice by 10% --
			 * scattered by how sloppy the hand is and how hard it was
			 * thrown. The scatter is what overshoots: about one flick in
			 * six at level 1, next to none at level 10. */
			const float spread = (0.025f + 0.10f * sloppy) *
			                     (0.6f + 0.4f * a->flick_speed) *
			                     (thrown ? 1.4f : 1.0f);
			const float f = clampf(0.90f + 0.05f * (1.0f - sloppy) +
			                       gauss3(rng) * spread, 0.55f, 1.45f);
			a->tgt_yaw = wrap_angle(a->tgt_yaw + dy * f);
			a->tgt_pitch = a->tgt_pitch + dp * f;
			/* ...and off the line: a sideways flick does not stay perfectly
			 * level. The correction takes this out along with the rest. */
			a->tgt_pitch = clampf(a->tgt_pitch + amp_deg * DEG2RAD * spread * 0.35f * gauss3(rng),
			                      -MAX_PITCH, MAX_PITCH);
			a->react_pending = 0;
			a->correcting = 1;
			a->settle_left = 0.04f + bc_rng_float(rng) * 0.07f;
		}
	} else if (change > BIG_CHANGE) {
		a->react_left = react_base + bc_rng_float(rng) * 0.08f;
		a->react_pending = 1;
	} else if (!a->correcting) {
		/* Small continuous adjustments (following a path, tracking a walking
		 * target) are pursued smoothly rather than re-triggering a flick. */
		a->tgt_yaw = a->want_yaw;
		a->tgt_pitch = a->want_pitch;
	}

	if (a->correcting) {
		float remaining = fabsf(wrap_angle(a->tgt_yaw - a->yaw)) +
		                  fabsf(a->tgt_pitch - a->pitch);
		if (remaining < 2.0f * DEG2RAD) {
			a->settle_left -= dt;
			if (a->settle_left <= 0.0f) {
				a->tgt_yaw = a->want_yaw;
				a->tgt_pitch = a->want_pitch;
				a->correcting = 0;
				/* The correction is a careful movement, not a throw. */
				a->flick_speed = 1.0f;
			}
		}
	}

	/* --- move the aim ---
	 * Velocity is proportional to the error (so it eases out as it arrives)
	 * but capped, and can only change so fast (so it eases in). The cap is
	 * the flick's own while one is in flight. */
	const float cap = max_vel * (a->correcting ? a->flick_speed : 1.0f);
	const float accel = cap * ACCEL_PER_CAP;
	{
		float want_v = clampf(wrap_angle(a->tgt_yaw - a->yaw) * GAIN, -cap, cap);
		a->yaw_vel += clampf(want_v - a->yaw_vel, -accel * dt, accel * dt);
		a->yaw = wrap_angle(a->yaw + a->yaw_vel * dt);
	}
	{
		float want_v = clampf((a->tgt_pitch - a->pitch) * GAIN, -cap, cap);
		a->pitch_vel += clampf(want_v - a->pitch_vel, -accel * dt, accel * dt);
		a->pitch = clampf(a->pitch + a->pitch_vel * dt, -MAX_PITCH, MAX_PITCH);
	}

	/* --- unsteadiness ---
	 * Three incommensurate sines per axis, on the output only: a quick
	 * tremor, a mid-rate wobble, and a slow postural drift with the largest
	 * amplitude. A hit makes the hand twitchier for a while (the gain
	 * eases, so it does not step). */
	a->tremor_gain += ((a->flinch_left > 0.0f ? FLINCH_SCALE : 1.0f) - a->tremor_gain) *
	                  (1.0f - expf(-dt / 0.3f));
	a->tremor_t += dt;
	const float tr = tremor_rad * a->tremor_gain;
	const float t = a->tremor_t;
	const float ty = tr * (0.45f * sinf(2.10f * t + a->tremor_phase[0]) +
	                       0.35f * sinf(0.83f * t + a->tremor_phase[1]) +
	                       0.70f * sinf(0.27f * t + a->tremor_phase[2]));
	const float tp = tr * 0.6f * (0.45f * sinf(1.70f * t + a->tremor_phase[3]) +
	                              0.35f * sinf(0.61f * t + a->tremor_phase[4]) +
	                              0.70f * sinf(0.19f * t + a->tremor_phase[5]));

	/* Aim error wanders towards a new offset instead of teleporting. */
	const float err_rad = tn->aim_error_deg * DEG2RAD;
	a->err_reroll_left -= dt;
	if (a->err_reroll_left <= 0.0f) {
		if (bc_rng_float(rng) < 0.35f) {
			/* A third of the time: a pull back, faster than a drift, that
			 * OVERCORRECTS to the other side (see aim.h for why it is not a
			 * pull towards zero). */
			float mag = bc_rng_float(rng) * err_rad;
			float magp = bc_rng_float(rng) * err_rad * 0.6f;
			a->err_yaw_target = (a->err_yaw > 0.0f) ? -mag : mag;
			a->err_pitch_target = (a->err_pitch > 0.0f) ? -magp : magp;
			a->err_reroll_left = 0.25f + bc_rng_float(rng) * 0.35f;
			a->err_tau = 0.12f;
		} else {
			float ry = bc_rng_float(rng);
			float rp = bc_rng_float(rng);
			a->err_yaw_target = (ry * 2.0f - 1.0f) * err_rad;
			a->err_pitch_target = (rp * 2.0f - 1.0f) * err_rad * 0.6f;
			a->err_reroll_left = 0.5f + bc_rng_float(rng) * 0.9f;
			a->err_tau = 0.30f;
		}
	}
	const float k = 1.0f - expf(-dt / a->err_tau);
	a->err_yaw += (a->err_yaw_target - a->err_yaw) * k;
	a->err_pitch += (a->err_pitch_target - a->err_pitch) * k;
	/* Ease the scale too, so entering or leaving combat does not step the aim. */
	a->err_scale += (a->err_scale_target - a->err_scale) * (1.0f - expf(-dt / 0.45f));
	/* The flinch's kick recovers (output only, like tremor). */
	{
		float rec = expf(-dt / 0.25f);
		a->flinch_yaw *= rec;
		a->flinch_pitch *= rec;
	}

	a->ori = dir_from_yaw_pitch(
	    a->yaw + ty + a->err_yaw * a->err_scale + a->flinch_yaw,
	    clampf(a->pitch + tp + a->err_pitch * a->err_scale + a->flinch_pitch,
	           -MAX_PITCH, MAX_PITCH));
}

/* A hit. aosbot's update_threat: one reaction per hit; with a source, a
 * look-bearing with error scaled by threat_sense and a reaction delay; a
 * flinch of 1.0-2.2s of twitchier hands. The kick is new here (aosbot
 * only made the bot twitchier in its legs): an immediate small jolt of the
 * aim, bigger the sloppier the hand, that recovers over a quarter second. */
static void take_hit(bc_aim *a, bc_rng *rng, bc_aim_v3 eye, const bc_aim_events *ev)
{
	const bc_aim_tuning *tn = &a->tune;
	const float sense = clampf(tn->threat_sense, 0.0f, 1.0f);

	float ky = bc_rng_float(rng) * 2.0f - 1.0f;
	float kp = bc_rng_float(rng) * 2.0f - 1.0f;
	float kmag = (1.0f + 0.6f * tn->aim_error_deg) * DEG2RAD;
	a->flinch_yaw += ky * kmag;
	a->flinch_pitch += kp * kmag * 0.6f;
	float fl = 1.0f + bc_rng_float(rng) * 1.2f;
	if (fl > a->flinch_left) a->flinch_left = fl;

	if (!ev->hit_from_valid || !finite3(ev->hit_from) || !finite3(eye)) return;
	bc_aim_v3 d = v3(ev->hit_from.x - eye.x, ev->hit_from.y - eye.y,
	                 ev->hit_from.z - eye.z);
	/* Somebody on top of us, or a grenade at our feet: there is no bearing
	 * to read, and turning to a degenerate one would just spin the head. */
	if (d.x * d.x + d.y * d.y < 0.25f) return;
	float yaw = a->yaw, pitch = a->pitch;
	if (!yaw_pitch_of(d, &yaw, &pitch)) return;
	const float err_deg = THREAT_BEARING_ERR_MAX -
	                      (THREAT_BEARING_ERR_MAX - THREAT_BEARING_ERR_MIN) * sense;
	float ey = bc_rng_float(rng);
	float ep = bc_rng_float(rng);
	yaw += (ey - 0.5f) * 2.0f * err_deg * DEG2RAD;
	/* Less error in pitch than in yaw: people are measurably steadier
	 * vertically, and a shot from above or below is the easier half. */
	pitch += (ep - 0.5f) * 0.8f * err_deg * DEG2RAD;
	a->threat_yaw = wrap_angle(yaw);
	a->threat_pitch = clampf(pitch, -MAX_PITCH, MAX_PITCH);
	a->threat_look_valid = 1;
	a->threat_react_left = THREAT_REACT_MAX - (THREAT_REACT_MAX - THREAT_REACT_MIN) * sense;
	a->threat_left = THREAT_MEMORY_SEC;
}

/* Everything the two entry points share: sync with the body, take a hit,
 * set what is wanted, run the motion, judge the cone. `have_want`: a
 * direction to look is given (else the last is held); `dist` the range to
 * the thing aimed at; `err_scale`: 1 at a target (range-factored), else 0.2. */
typedef struct frame {
	int have_want;
	bc_aim_v3 want_dir;
	float err_scale;
	bc_aim_v3 point;
	int have_point;
	float dist;
	int allow_threat_look;
} frame;

static void run_frame(bc_aim *a, bc_rng *rng, float dt, bc_aim_v3 eye,
                      bc_aim_v3 cur, const bc_aim_events *ev, int firing,
                      const frame *f, bc_aim_out *out)
{
	if (!(dt == dt) || dt < 0.0f) dt = 0.0f;
	if (!a->init) bc_aim_init(a, rng, 5, cur);

	/* The body is not where the head left it: it was moved. */
	if (finite3(cur) && (cur.x != 0.0f || cur.y != 0.0f || cur.z != 0.0f) &&
	    angle_between(cur, a->ori) > RESYNC_DEG * DEG2RAD)
		bc_aim_snap(a, cur);

	if (ev && ev->hit) take_hit(a, rng, eye, ev);

	a->flinch_left = fmaxf(0.0f, a->flinch_left - dt);
	a->threat_react_left = fmaxf(0.0f, a->threat_react_left - dt);
	a->threat_left = fmaxf(0.0f, a->threat_left - dt);
	if (a->threat_left <= 0.0f) a->threat_look_valid = 0;

	if (f->have_want) {
		float y = a->want_yaw, p = a->want_pitch;
		if (yaw_pitch_of(f->want_dir, &y, &p)) {
			a->want_yaw = y;
			a->want_pitch = clampf(p, -MAX_PITCH, MAX_PITCH);
		}
		a->threat_look_valid = 0; /* something to look at outranks a hunch */
	} else if (f->allow_threat_look && a->threat_look_valid &&
	           a->threat_react_left <= 0.0f) {
		a->want_yaw = a->threat_yaw;
		a->want_pitch = a->threat_pitch;
	}
	a->err_scale_target = f->err_scale;

	/* Sub-step a long dt rather than lose the time: the model is stable up
	 * to ~50ms and a host that stalls must not freeze the head. */
	int n = 1;
	if (dt > 0.05f) n = (int)ceilf(dt / 0.05f);
	if (n > 40) n = 40;
	float h = dt / (float)n;
	if (h < 0.0005f) h = 0.0005f;
	for (int i = 0; i < n; i++) core_step(a, rng, h);

	out->ori = a->ori;
	out->off_deg = 0.0f;
	out->on_target = 0;
	out->point = finite3(eye) ? v3(eye.x + a->ori.x, eye.y + a->ori.y, eye.z + a->ori.z)
	                          : a->ori;
	if (f->have_point && finite3(eye)) {
		out->point = f->point;
		bc_aim_v3 want = v3(f->point.x - eye.x, f->point.y - eye.y, f->point.z - eye.z);
		if (want.x != 0.0f || want.y != 0.0f || want.z != 0.0f) {
			float ang = angle_between(want, a->ori);
			out->off_deg = ang / DEG2RAD;
			/* `firing`: a burst in progress is not stopped because he
			 * twitched a degree out of the middle of it. */
			out->on_target = ang <= bc_aim_fire_cone(f->dist) * (firing ? 2.0f : 1.0f);
		}
	}
}

void bc_aim_step(bc_aim *a, bc_rng *rng, float dt, bc_aim_v3 eye,
                 bc_aim_v3 cur, const bc_aim_target *t,
                 const bc_aim_events *ev, int firing, bc_aim_out *out)
{
	frame f = { 0 };
	f.err_scale = 0.2f;
	f.allow_threat_look = 1;
	if (!a->init) bc_aim_init(a, rng, 5, cur);

	if (t && finite3(t->pos) && finite3(eye) && finite3(t->vel)) {
		/* A new id is a new engagement: a new spot, a belief about the
		 * motion that starts from nothing. */
		if (t->id != a->target_id) {
			a->target_id = t->id;
			a->track_vel = v3(0.0f, 0.0f, 0.0f);
			pick_aim_spot(a, rng);
		}
		/* The belief is smoothed hard on purpose: it is meant to be out of
		 * date. Sourcing it from the truth fixes its magnitude without
		 * touching its lag. A man in the air is not going to surprise
		 * anybody, so the staleness is skipped while he is. */
		float h = dt > 0.0f ? dt : 0.0f;
		float k = t->airborne ? 1.0f : 1.0f - expf(-h / 0.22f);
		a->track_vel.x += (t->vel.x - a->track_vel.x) * k;
		a->track_vel.y += (t->vel.y - a->track_vel.y) * k;
		a->track_vel.z += (t->vel.z - a->track_vel.z) * k;
		a->spot_wander_t += h;

		/* aim_point: the spot, the creep, the stale lead. The creep is
		 * perpendicular to the line of sight (in the ground plane). */
		const float spread = clampf(a->tune.aim_spot, 0.0f, 1.0f);
		float dx = t->pos.x - eye.x, dy = t->pos.y - eye.y;
		float flat = sqrtf(dx * dx + dy * dy);
		float px = 0.0f, py = 0.0f;
		if (flat > 0.001f) { px = -dy / flat; py = dx / flat; }
		float wide = 0.18f * spread * sinf(a->spot_wander_t * 0.70f + a->spot_phase * 1.7f);
		float tall = 0.22f * spread * sinf(a->spot_wander_t * 0.90f + a->spot_phase);
		float lead = a->lead_t * clampf(a->tune.track_error, 0.0f, 1.0f);
		/* The spot is drawn on a standing man, whose feet are 2.25 under
		 * his eye; it is put at the same place on the body there is to
		 * shoot at. A crouched man's eye is 0.9 lower and his feet where
		 * they were: 1.35 under it (lsd demoncore.c, change_crouch and
		 * boxclipmove) -- the spot is that much nearer his eye, not
		 * lower, which was in the ground at his feet (aosbot does not
		 * know crouching; the caller here does). A man in the sea shows
		 * only what is over it. */
		float under = t->crouched ? BODY_CROUCHED : BODY_STANDING;
		float body;

		if (SEA_TOP - t->pos.z < under) under = SEA_TOP - t->pos.z;
		body = clampf(under, 0.3f, BODY_STANDING) / BODY_STANDING;
		f.point = v3(t->pos.x + a->track_vel.x * lead + px * wide,
		             t->pos.y + a->track_vel.y * lead + py * wide,
		             t->pos.z + (a->spot_z + tall) * body + a->track_vel.z * lead);
		f.have_point = 1;
		f.have_want = 1;
		f.want_dir = v3(f.point.x - eye.x, f.point.y - eye.y, f.point.z - eye.z);
		f.dist = sqrtf(f.want_dir.x * f.want_dir.x + f.want_dir.y * f.want_dir.y +
		               f.want_dir.z * f.want_dir.z);
		/* Aim error is angular: a steadier hand for a far target. Full
		 * inside 15 blocks, 40% by 90. */
		f.err_scale = f.dist > 15.0f ? clampf(sqrtf(15.0f / f.dist), 0.4f, 1.0f) : 1.0f;
	} else {
		a->target_id = -1;
		a->track_vel = v3(0.0f, 0.0f, 0.0f);
	}
	run_frame(a, rng, dt, eye, cur, ev, firing, &f, out);
}

void bc_aim_step_point(bc_aim *a, bc_rng *rng, float dt, bc_aim_v3 eye,
                       bc_aim_v3 cur, bc_aim_v3 point,
                       const bc_aim_events *ev, int firing, bc_aim_out *out)
{
	frame f = { 0 };
	f.err_scale = 0.2f;
	f.allow_threat_look = 1;
	if (!a->init) bc_aim_init(a, rng, 5, cur);
	a->target_id = -1;
	a->track_vel = v3(0.0f, 0.0f, 0.0f);
	if (finite3(point) && finite3(eye)) {
		f.point = point;
		f.have_point = 1;
		f.have_want = 1;
		f.want_dir = v3(point.x - eye.x, point.y - eye.y, point.z - eye.z);
		f.dist = sqrtf(f.want_dir.x * f.want_dir.x + f.want_dir.y * f.want_dir.y +
		               f.want_dir.z * f.want_dir.z);
	}
	run_frame(a, rng, dt, eye, cur, ev, firing, &f, out);
}
