/* senses.c -- see senses.h
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * The ray is the server's own (lsd_core.h's cast_ray): what blocks a
 * bullet there blocks a look here.
 */
#include "senses.h"

#include <math.h>
#include <string.h>

#include "lsd_core.h"

enum { NOTICE_MEMORY_SECS = 6 };            /* aosbot kNoticeMemorySec */
static const float NOISE_HOLD = 1.2f;       /* aosbot kNoiseHoldSec */
static const float THREAT_SECS = 8.0f;      /* aosbot: a threat stays valid 8 s */
static const float ENGAGED_GRACE = 1.5f;    /* aosbot: target-lost grace */

void bc_sense_cfg_default(bc_sense_cfg *c)
{
	c->sight = 128.0f;
	c->fov_deg = 180.0f;
	c->notice = 8.0f;
	c->lamp_range = 60.0f;      /* lib_flashlight: flashlight_reach */
	c->lamp_cone_deg = 90.0f;   /* flashlight_cone */
	c->lit_range = 192.0f;
	c->night_sight = 0;
	c->memory = 12.0f;
	c->relay = 1.5f;
	c->board = 10.0f;
	c->noise_secs = 10.0f;
}

int bc_sense_cfg_set(bc_sense_cfg *c, const char *key, float v)
{
	if (!strcmp(key, "sight")) c->sight = v;
	else if (!strcmp(key, "fov")) c->fov_deg = v;
	else if (!strcmp(key, "notice")) c->notice = v;
	else if (!strcmp(key, "night.sight")) c->night_sight = v != 0.0f;
	else if (!strcmp(key, "night.reach")) c->lamp_range = v;
	else if (!strcmp(key, "night.cone")) c->lamp_cone_deg = v;
	else if (!strcmp(key, "night.far")) c->lit_range = v;
	else if (!strcmp(key, "memory")) c->memory = v;
	else if (!strcmp(key, "relay")) c->relay = v;
	else if (!strcmp(key, "board")) c->board = v;
	else if (!strcmp(key, "noise_secs")) c->noise_secs = v;
	else return 0;
	return 1;
}

/* --- the board -------------------------------------------------------- */

void bc_board_clear(bc_board *b)
{
	int t, i;

	memset(b, 0, sizeof *b);
	for (t = 0; t < 2; t++)
		for (i = 0; i < BL_MAX_PLAYERS; i++)
			b->spot[t][i].at = b->spot[t][i].since = -1e9;
	b->next_ping = 1;
}

static float dist3(bl_vec3 a, bl_vec3 b)
{
	float dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;

	return sqrtf(dx * dx + dy * dy + dz * dz);
}

bc_ping *bc_board_ping(bc_board *b, int team, int by, bl_vec3 pos, int kind,
                       double now, double secs)
{
	bc_ping *best = NULL;
	int i;

	if (team < 1 || team > 2)
		return NULL;
	for (i = 0; i < BC_BOARD_PINGS; i++) {
		bc_ping *p = &b->ping[team - 1][i];

		/* aosbot: a new ping from the same caller withdraws his last */
		if (p->valid && p->by == by)
			p->valid = 0;
		if (p->valid && p->until <= now)
			p->valid = 0;
		if (!best || (!p->valid && best->valid) ||
		    (p->valid == best->valid && p->at < best->at))
			best = p;
	}
	memset(best, 0, sizeof *best);
	best->pos = pos;
	best->at = now;
	best->until = now + secs;
	best->valid = 1;
	best->kind = (uint8_t)kind;
	best->by = (uint8_t)by;
	best->id = b->next_ping++;
	return best;
}

int bc_board_pinged(const bc_board *b, int team, bl_vec3 pos, int kind,
                    float radius, double now)
{
	int i;

	if (team < 1 || team > 2)
		return 0;
	for (i = 0; i < BC_BOARD_PINGS; i++) {
		const bc_ping *p = &b->ping[team - 1][i];

		if (p->valid && p->until > now && p->kind == kind && dist3(p->pos, pos) <= radius)
			return 1;
	}
	return 0;
}

/* Does the lowercased text hold the word (a prefix match, as aosbot's
 * `enem*`), at the start of a word? */
static int has_word(const char *low, const char *word)
{
	size_t n = strlen(word);
	const char *p = low;

	while ((p = strstr(p, word)) != NULL) {
		if (p == low || p[-1] == ' ')
			return 1;
		p += n;
	}
	return 0;
}

int bc_ping_kind(const char *reason)
{
	static const char *const none[] = { "affirmative", "negative", "thank", "yes", "no ", NULL };
	static const char *const enemy[] = { "enem", "sniper", "danger", "attack", "contact",
		"spotted", "hostile", "spawnkill", "camp", NULL };
	static const char *const help[] = { "help", "backup", "cover", "escort", "follow", NULL };
	char low[72];
	size_t i, n = 0;

	for (i = 0; reason && reason[i] && n < sizeof low - 2; i++) {
		char ch = reason[i];

		if (ch >= 'A' && ch <= 'Z')
			ch = (char)(ch - 'A' + 'a');
		low[n++] = (ch >= 'a' && ch <= 'z') ? ch : ' ';
	}
	low[n++] = ' ';
	low[n] = 0;
	for (i = 0; enemy[i]; i++)
		if (has_word(low, enemy[i])) return BC_PING_ENEMY;
	for (i = 0; help[i]; i++)
		if (has_word(low, help[i])) return BC_PING_HELP;
	for (i = 0; none[i]; i++)
		if (has_word(low, none[i])) return BC_PING_NONE;
	return BC_PING_GO;
}

/* --- sight ------------------------------------------------------------ */

int bc_sight_clear(const bc_map *m, bl_vec3 eye, bl_vec3 point)
{
	float a[3], b[3];

	if (!m)
		return 1;
	a[0] = eye.x; a[1] = eye.y; a[2] = eye.z;
	b[0] = point.x; b[1] = point.y; b[2] = point.z;
	return !bc_lsd_cast_ray(m, a, b, NULL);
}

int bc_sight_body(const bc_map *m, bl_vec3 eye, bl_vec3 body, int crouched)
{
	/* head, chest, legs: z grows downward from the eye */
	const float off[3] = { 0.0f, crouched ? 0.6f : 1.2f, crouched ? 1.1f : 2.0f };
	int i;

	for (i = 0; i < 3; i++) {
		bl_vec3 p = body;

		p.z += off[i];
		if (bc_sight_clear(m, eye, p))
			return 1;
	}
	return 0;
}

float bc_hear_range(int kind, int level)
{
	float lo, hi, t;

	if (level < 1) level = 1;
	if (level > 10) level = 10;
	t = (float)(level - 1) / 9.0f;
	switch (kind) {
	case BL_S_SHOT: lo = 14.0f; hi = 34.0f; break;
	case BL_S_DIG: case BL_S_BUILD: lo = 6.0f; hi = 14.0f; break;
	case BL_S_STEP: lo = 4.0f; hi = 8.0f; break;
	case BL_S_BLAST: lo = 24.0f; hi = 48.0f; break;
	default: return 0.0f;
	}
	return lo + (hi - lo) * t;
}

void bc_senses_reset(bc_senses *s)
{
	int i;

	memset(s, 0, sizeof *s);
	for (i = 0; i < BL_MAX_PLAYERS; i++)
		s->k[i].seen_at = s->k[i].told_at = s->k[i].dismissed = -1e9;
	s->nearest = s->nearest_known = -1;
	s->last_sight = s->hurt_at = s->spotted_new_at = -1e9;
	s->shot_at = s->fire_since = -1e9;
}

static int is_enemy(const bl_world *w, int self, int i)
{
	const bl_player *me = &w->players[self], *p = &w->players[i];

	return i != self && p->state == BL_ALIVE && p->team != 0 && p->team != me->team;
}

static void set_alert(bc_senses *s, const bc_sense_cfg *c, double now)
{
	if (s->n_visible > 0 || now - s->last_sight < ENGAGED_GRACE)
		s->alert = BC_ALERT_ENGAGED;
	else if (bc_senses_search(s, c, now, NULL, NULL))
		s->alert = BC_ALERT_SUSPICIOUS;
	else
		s->alert = BC_ALERT_CALM;
}

void bc_senses_see(bc_senses *s, const bc_sense_cfg *c, const bc_map *m,
                   const bl_world *w, int self, int night_vision, double now, bc_board *board)
{
	const bl_player *me = &w->players[self];
	float fl = sqrtf(me->ori.x * me->ori.x + me->ori.y * me->ori.y);
	float cos_fov = cosf(c->fov_deg * 0.5f * 3.14159265f / 180.0f);
	float cos_lamp = cosf(c->lamp_cone_deg * 0.5f * 3.14159265f / 180.0f);
	int my_lamp = (me->flags & BL_F_LAMP) != 0;
	float best = 1e30f, best_known = 1e30f;
	int i, team = me->team, night = w->night && c->night_sight;

	s->n_visible = 0;
	s->nearest = s->nearest_known = -1;
	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		const bl_player *p = &w->players[i];
		bc_known *k = &s->k[i];
		float dx, dy, dz, flat, d3, cosv, speed, notice;
		int was = k->visible, in_view, noticed, loud, cand, how = 0;

		k->visible = 0;
		k->how = 0;
		if (!is_enemy(w, self, i)) {
			/* a dead man is not somewhere to look for */
			if (p->state != BL_ALIVE)
				k->seen_at = k->told_at = -1e9;
			continue;
		}
		dx = p->pos.x - me->pos.x;
		dy = p->pos.y - me->pos.y;
		dz = p->pos.z - me->pos.z;
		flat = sqrtf(dx * dx + dy * dy);
		d3 = sqrtf(dx * dx + dy * dy + dz * dz);

		/* cheap tests first, the rays last */
		cosv = (fl < 1e-3f || flat < 1e-3f) ? 1.0f
		       : (dx * me->ori.x + dy * me->ori.y) / (flat * fl);
		in_view = cosv >= cos_fov - 1e-3f;
		noticed = now - k->seen_at < (double)NOTICE_MEMORY_SECS;
		speed = sqrtf(p->vel.x * p->vel.x + p->vel.y * p->vel.y) * 32.0f;
		loud = speed > 2.0f && !(p->flags & BL_F_CROUCH) && !(p->keys & BL_K_SNEAK);
		notice = loud ? c->notice : c->notice * 0.5f;

		cand = 0;
		if (!night || night_vision) {
			if (d3 <= notice) {
				cand = 1;
				how |= BC_SEE_CLOSE;
			}
			if (flat <= c->sight && (in_view || noticed)) {
				cand = 1;
				how |= BC_SEE_VIEW;
			}
			/* night vision: a lit lamp shows from farther than day */
			if (night && (p->flags & BL_F_LAMP) && flat <= c->lit_range &&
			    (in_view || noticed)) {
				cand = 1;
				how |= BC_SEE_LIT;
			}
		} else if (my_lamp) {
			/* only what its own light falls on */
			if (d3 <= c->lamp_range && d3 > 1e-3f &&
			    (dx * me->ori.x + dy * me->ori.y + dz * me->ori.z) / d3 >= cos_lamp) {
				cand = 1;
				how |= BC_SEE_LAMP;
			}
		}
		if (cand && bc_sight_body(m, me->pos, p->pos, (p->flags & BL_F_CROUCH) != 0)) {
			k->visible = 1;
			k->how = (uint8_t)how;
			k->pos = p->pos;
			k->vel = p->vel;
			k->seen_at = now;
			s->n_visible++;
			s->last_sight = now;
			if (d3 < best) {
				best = d3;
				s->nearest = i;
			}
			if (board && team >= 1 && team <= 2) {
				bc_spot *sp = &board->spot[team - 1][i];

				if (now - sp->at > (double)c->board) {
					sp->since = now;
					s->spotted_new_at = now;
				}
				sp->at = now;
				sp->pos = p->pos;
				sp->by = (uint8_t)self;
			}
		} else {
			if (was) {
				/* he left sight: where he was heading (aosbot's search
				 * point: last seen plus half a second of his velocity) */
				s->lost.pos.x = k->pos.x + k->vel.x * 32.0f * 0.5f;
				s->lost.pos.y = k->pos.y + k->vel.y * 32.0f * 0.5f;
				s->lost.pos.z = k->pos.z;
				s->lost.at = now;
				s->lost.valid = 1;
				s->lost.by = (uint8_t)i;
			}
			/* what the team says of him */
			if (board && team >= 1 && team <= 2) {
				const bc_spot *sp = &board->spot[team - 1][i];

				if (sp->by != self && now - sp->since >= (double)c->relay &&
				    now - sp->at < (double)c->board && sp->at > k->seen_at &&
				    sp->at > k->dismissed) {
					k->told_at = sp->at;
					k->pos = sp->pos;
					k->vel.x = k->vel.y = k->vel.z = 0.0f;
				}
			}
			if ((now - k->seen_at < (double)c->memory ||
			     now - k->told_at < (double)c->board)) {
				float kd = dist3(k->pos, me->pos);

				if (kd < best_known) {
					best_known = kd;
					s->nearest_known = i;
				}
			}
		}
	}
	/* somebody in sight near the place being searched settles it */
	if (s->n_visible > 0) {
		s->lost.valid = 0;
		if (s->noise.valid && s->nearest >= 0 &&
		    dist3(s->noise.pos, s->k[s->nearest].pos) < 12.0f)
			s->noise.valid = 0;
	}
	set_alert(s, c, now);
}

int bc_senses_hear(bc_senses *s, const bc_sense_cfg *c, const bl_world *w, int self,
                   int level, int kind, bl_vec3 pos, int by, double now)
{
	const bl_player *me = &w->players[self];
	float d = dist3(pos, me->pos);

	if (d > bc_hear_range(kind, level))
		return 0;
	if (by == self)
		return 0;
	if (by != BL_NO_PLAYER) {
		/* a team-mate's noise is no news; a man in sight is a target */
		if (w->players[by].team == me->team)
			return 0;
		if (s->k[by].visible)
			return 0;
	}
	if (s->noise.valid && now - s->noise.at < (double)NOISE_HOLD &&
	    dist3(s->noise.pos, me->pos) <= d)
		return 0;
	s->noise.pos = pos;
	s->noise.at = now;
	s->noise.valid = 1;
	s->noise.kind = (uint8_t)kind;
	s->noise.by = (uint8_t)by;
	set_alert(s, c, now);
	return 1;
}

static void threat_from(bc_senses *s, bc_rng *rng, const bl_world *w, int self, int level,
                        bl_vec3 from, int by, float slack, double now)
{
	const bl_player *me = &w->players[self];
	float dx = from.x - me->pos.x, dy = from.y - me->pos.y;
	float flat = sqrtf(dx * dx + dy * dy);
	float sense, err, a, ca, sa;

	if (level < 1) level = 1;
	if (level > 10) level = 10;
	/* aosbot: bearing error 40 - 36 * threat_sense degrees */
	sense = 0.06f + 0.10f * (float)(level - 1);
	if (sense > 0.96f) sense = 0.96f;
	err = (40.0f - 36.0f * sense) * slack * 3.14159265f / 180.0f;
	a = bc_rng_range(rng, -1.0f, 1.0f) * err;
	ca = cosf(a);
	sa = sinf(a);
	s->threat.pos.x = me->pos.x + dx * ca - dy * sa;
	s->threat.pos.y = me->pos.y + dx * sa + dy * ca;
	s->threat.pos.z = from.z;
	s->threat.at = now;
	s->threat.valid = 1;
	s->threat.by = (uint8_t)by;
	s->threat.kind = 0;
	s->threat_dist = flat;
	if (s->alert == BC_ALERT_CALM)
		s->alert = BC_ALERT_SUSPICIOUS;
}

static void under_fire(bc_senses *s, double now)
{
	if (now - s->shot_at > 4.0)
		s->fire_since = now;
	s->shot_at = now;
}

void bc_senses_hurt(bc_senses *s, bc_rng *rng, const bl_world *w, int self, int level,
                    bl_vec3 from, int by, double now)
{
	const bl_player *me = &w->players[self];
	float dx = from.x - me->pos.x, dy = from.y - me->pos.y;
	float flat = sqrtf(dx * dx + dy * dy);

	s->hurt_at = now;
	if (flat < 0.5f && fabsf(from.z - me->pos.z) < 0.5f)
		return;                 /* a fall, the sea: from nowhere */
	if (by != BL_NO_PLAYER && w->players[by].team == me->team)
		return;
	under_fire(s, now);
	threat_from(s, rng, w, self, level, from, by, 1.0f, now);
}

void bc_senses_shot_at(bc_senses *s, bc_rng *rng, const bl_world *w, int self, int level,
                       bl_vec3 from, int by, int kind, double now)
{
	const bl_player *me = &w->players[self];

	if (by != BL_NO_PLAYER && w->players[by].team == me->team)
		return;
	under_fire(s, now);
	/* a hit's own reading stands; so does a man in plain sight */
	if (s->threat.valid && s->threat.kind == 0 && now - s->threat.at < 1.0)
		return;
	if (by != BL_NO_PLAYER && s->k[by].visible) {
		s->threat.pos = s->k[by].pos;
		s->threat.at = now;
		s->threat.valid = 1;
		s->threat.by = (uint8_t)by;
		s->threat.kind = (uint8_t)kind;
		return;
	}
	threat_from(s, rng, w, self, level, from, by, 1.5f, now);
	s->threat.kind = (uint8_t)kind;
}

int bc_senses_near_miss(const bl_world *w, int self, int by, float miss)
{
	const bl_player *me = &w->players[self], *p;
	float dx, dy, dz, t, ox, oy, oz;

	if (by == BL_NO_PLAYER || by == self)
		return 0;
	p = &w->players[by];
	if (p->state != BL_ALIVE || p->team == me->team || me->state != BL_ALIVE)
		return 0;
	dx = me->pos.x - p->pos.x; dy = me->pos.y - p->pos.y; dz = me->pos.z + 1.0f - p->pos.z;
	if (dx * dx + dy * dy + dz * dz < 6.0f * 6.0f)
		return 1;
	t = dx * p->ori.x + dy * p->ori.y + dz * p->ori.z;
	if (t <= 0.0f || t > 128.0f)
		return 0;
	ox = dx - p->ori.x * t; oy = dy - p->ori.y * t; oz = dz - p->ori.z * t;
	return ox * ox + oy * oy + oz * oz <= miss * miss;
}

float bc_senses_confidence(const bc_senses *s, const bc_sense_cfg *c, int pid, double now)
{
	const bc_known *k;
	float a, b;

	if (pid < 0 || pid >= BL_MAX_PLAYERS)
		return 0.0f;
	k = &s->k[pid];
	if (k->visible)
		return 1.0f;
	a = 1.0f - (float)(now - k->seen_at) / c->memory;
	b = 0.6f * (1.0f - (float)(now - k->told_at) / c->board);
	if (b > a) a = b;
	return a < 0.0f ? 0.0f : a;
}

int bc_senses_search(const bc_senses *s, const bc_sense_cfg *c, double now,
                     bl_vec3 *out, int *what)
{
	double at = -1e9;
	int w = 0;
	bl_vec3 p = { 0.0f, 0.0f, 0.0f };

	if (s->lost.valid && now - s->lost.at < (double)c->memory) {
		at = s->lost.at; p = s->lost.pos; w = 1;
	}
	if (s->threat.valid && now - s->threat.at < (double)THREAT_SECS && s->threat.at > at) {
		at = s->threat.at; p = s->threat.pos; w = 2;
	}
	if (s->noise.valid && now - s->noise.at < (double)c->noise_secs && s->noise.at > at) {
		at = s->noise.at; p = s->noise.pos; w = 3;
	}
	if (!w && s->nearest_known >= 0) {
		p = s->k[s->nearest_known].pos; w = 4;
	}
	if (!w)
		return 0;
	if (out) *out = p;
	if (what) *what = w;
	return 1;
}

void bc_senses_searched(bc_senses *s, int what)
{
	if (what == 1) s->lost.valid = 0;
	else if (what == 2) s->threat.valid = 0;
	else if (what == 3) s->noise.valid = 0;
	else if (what == 4 && s->nearest_known >= 0) {
		s->k[s->nearest_known].dismissed = s->k[s->nearest_known].told_at;
		s->k[s->nearest_known].seen_at = s->k[s->nearest_known].told_at = -1e9;
		s->nearest_known = -1;
	}
}
