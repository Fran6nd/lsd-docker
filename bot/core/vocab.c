/* vocab.c -- see vocab.h
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * One table: the word, its arguments, its line of documentation, its
 * function. The conditions and scores are small enough to live here;
 * the actions are the skills (skills.h).
 */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "brain.h"
#include "vocab.h"

static float arg(const bt_args *a, int i, float dflt)
{
	return a && a->count > i ? a->num[i] : dflt;
}

static float clamp01(float v)
{
	return v < 0.0f ? 0.0f : v > 1.0f ? 1.0f : v;
}

/* distance to the nearest enemy in sight; huge with none */
static float near_enemy(const bc_bot *b)
{
	const bl_player *me = bc_me(b);
	const bc_known *k;
	float dx, dy, dz;

	if (b->senses.nearest < 0)
		return 1e9f;
	k = &b->senses.k[b->senses.nearest];
	dx = k->pos.x - me->pos.x; dy = k->pos.y - me->pos.y; dz = k->pos.z - me->pos.z;
	return sqrtf(dx * dx + dy * dy + dz * dz);
}

static int in_cover(const bc_bot *b, float secs)
{
	int t = b->fight.target >= 0 ? b->fight.target : b->senses.lost.valid ? b->senses.lost.by : -1;

	return t >= 0 && !b->senses.k[t].visible && b->e->now - b->senses.k[t].seen_at < (double)secs;
}

static float ammo_frac(const bc_bot *b)
{
	static const float full[3] = { 60.0f, 150.0f, 54.0f };    /* magazine + reserve at spawn */
	const bl_player *me = bc_me(b);

	return ((float)me->mag + (float)me->reserve) / full[me->gun <= 2 ? me->gun : 0];
}

static int nade_worth(bc_bot *b)
{
	bl_vec3 p;

	return bc_me(b)->grenades > 0 && b->e->now >= b->nade.cd_until && bc_grenade_target(b, &p);
}

static int alert_is(const bc_bot *b, const bt_args *a)
{
	const char *w = a->count > 0 ? a->text[0] : "engaged";

	return b->senses.alert == (!strcmp(w, "calm") ? BC_ALERT_CALM :
	       !strcmp(w, "suspicious") ? BC_ALERT_SUSPICIOUS : BC_ALERT_ENGAGED);
}

static int ping_is(const bc_bot *b, const bt_args *a)
{
	const char *w;

	if (!b->ping.taken || b->e->now >= b->ping.until)
		return 0;
	if (!a || a->count == 0)
		return 1;
	w = a->text[0];
	return b->ping.kind == (!strcmp(w, "enemy") ? BC_PING_ENEMY :
	       !strcmp(w, "help") ? BC_PING_HELP : BC_PING_GO);
}

static int order_stands(const bc_bot *b)
{
	return b->order.order != BL_O_NONE && (b->order.until < 0.0 || b->e->now < b->order.until);
}

static int sky_clear(const bc_bot *b)
{
	const bl_player *me = bc_me(b);
	int z = (int)floorf(me->pos.z), x = (int)floorf(me->pos.x), y = (int)floorf(me->pos.y);
	uint64_t above;

	if (!b->e->have_map || z <= 0)
		return 1;
	above = z >= 64 ? ~(uint64_t)0 : (((uint64_t)1 << z) - 1);
	return (bc_map_col(b->e->map, x, y) & above) == 0;
}

static int hurt_ally(const bc_bot *b, float radius, float hp)
{
	const bl_player *me = bc_me(b);
	int i;

	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		const bl_player *p = &b->e->w.players[i];
		float dx = p->pos.x - me->pos.x, dy = p->pos.y - me->pos.y;

		if (i != b->pid && p->state == BL_ALIVE && p->team == me->team && (float)p->hp < hp &&
		    dx * dx + dy * dy <= radius * radius)
			return 1;
	}
	return 0;
}

static int losing(const bc_bot *b)
{
	const bl_player *me = bc_me(b);

	if (b->senses.n_visible == 0)
		return 0;
	if (me->hp < 30 && b->e->now - b->senses.hurt_at < 3.0)
		return 1;
	return me->hp < 45 && b->senses.n_visible > 1 + bc_mates_within(b, me->pos, 20.0f);
}

static int setting_is(const bc_bot *b, const bt_args *a)
{
	const char *v = a->count > 0 ? bc_engine_setting(b->e, a->text[0]) : NULL;

	if (!v || !*v)
		return 0;
	return a->count < 2 || !strcmp(v, a->text[1]);
}

static int at_place(bc_bot *b, const bt_args *a)
{
	const bl_player *me = bc_me(b);
	bl_vec3 p;
	float dx, dy, r = arg(a, 1, 4.0f);

	if (!bc_place_of(b, a->count > 0 ? a->text[0] : "self", &p))
		return 0;
	dx = p.x - me->pos.x; dy = p.y - me->pos.y;
	return dx * dx + dy * dy <= r * r;
}

static float search_fresh(const bc_bot *b)
{
	const bc_senses *s = &b->senses;
	const bc_sense_cfg *c = &b->e->sense;
	double now = b->e->now;
	float best = 0.0f, v;
	int what;

	if (!bc_senses_search(s, c, now, NULL, &what))
		return 0.0f;
	if (s->lost.valid && (v = 1.0f - (float)(now - s->lost.at) / c->memory) > best) best = v;
	if (s->threat.valid && (v = 1.0f - (float)(now - s->threat.at) / 8.0f) > best) best = v;
	if (s->noise.valid && (v = 1.0f - (float)(now - s->noise.at) / c->noise_secs) > best) best = v;
	if (what == 4 && best < 0.4f) best = 0.4f;
	return best < 0.1f ? 0.1f : best;
}

static int c_enemy_visible(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return b->senses.n_visible > 0;
}

static int c_enemy_known(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return b->senses.n_visible > 0 || b->senses.nearest_known >= 0;
}

static int c_enemy_within(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return near_enemy(b) <= arg(a, 0, 20.0f);
}

static int c_enemy_beyond(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return b->senses.n_visible > 0 && near_enemy(b) > arg(a, 0, 20.0f);
}

static int c_enemies_grouped(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return bc_enemy_group(b, (int)arg(a, 0, 2.0f), arg(a, 1, 6.0f), NULL) > 0;
}

static int c_target_in_cover(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return in_cover(b, arg(a, 0, 5.0f));
}

static int c_outnumbered(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return b->senses.n_visible > 1 + bc_mates_within(b, bc_me(b)->pos, arg(a, 0, 20.0f));
}

/* how good it is (1 to 10: aim, reaction, turn -- aim.h), for a branch
 * only the able take: `if level_at_least 8` */
static int c_level_at_least(void *bot, const bt_args *a)
{
	return (float)((bc_bot *)bot)->level >= arg(a, 0, 1.0f);
}

static float s_level(void *bot, const bt_args *a)
{
	(void)a;
	return ((float)((bc_bot *)bot)->level - 1.0f) / 9.0f;
}

static int c_health_below(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return (float)bc_me(b)->hp < arg(a, 0, 40.0f);
}

static int c_hurt_recently(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return b->e->now - b->senses.hurt_at < (double)arg(a, 0, 3.0f);
}

static int c_ammo_below(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return ammo_frac(b) < arg(a, 0, 0.25f);
}

static int c_ammo_out(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return bc_me(b)->mag == 0 && bc_me(b)->reserve == 0;
}

static int c_has_grenade(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return bc_me(b)->grenades > 0;
}

static int c_grenade_worth(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return nade_worth(b);
}

static int c_grenade_near(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return bc_grenade_threat(b, NULL) >= 25.0f;
}

static int c_heard_noise(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	{ bl_vec3 p; return bc_place_of(b, "noise", &p); }
}

static int c_lost_enemy(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	{ bl_vec3 p; return bc_place_of(b, "last_seen", &p); }
}

static int c_has_search(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return bc_senses_search(&b->senses, &b->e->sense, b->e->now, NULL, NULL);
}

static int c_alert(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return alert_is(b, a);
}

static int c_ping_called(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return ping_is(b, a);
}

static int c_has_order(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return order_stands(b);
}

static int c_is_night(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return b->e->w.night != 0;
}

static int c_lamp_on(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return (bc_me(b)->flags & BL_F_LAMP) != 0;
}

static int c_has_item(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return a->count > 0 && bc_item_count(b, a->text[0]) != 0;
}

static int c_sky_clear(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return sky_clear(b);
}

static int c_allies_hurt_near(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return hurt_ally(b, arg(a, 0, 10.0f), arg(a, 1, 50.0f));
}

static int c_mate_within(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	{ float d; return bc_nearest_mate(b, &d) >= 0 && d <= arg(a, 0, 15.0f); }
}

static int c_alone(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	{ float d; return bc_nearest_mate(b, &d) < 0 || d > arg(a, 0, 25.0f); }
}

static int c_spotted_new(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return b->e->now - b->senses.spotted_new_at < (double)arg(a, 0, 2.0f);
}

static int c_losing(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return losing(b);
}

static int c_sniped(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	double secs = (double)arg(a, 1, 3.0f);

	return b->e->now - b->senses.hurt_at < secs && b->senses.threat.valid && b->e->now - b->senses.threat.at < secs &&
	       b->senses.threat_dist > arg(a, 0, 50.0f);
}

static int c_setting(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return setting_is(b, a);
}

static int c_chance(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return bc_frand(b) < arg(a, 0, 0.5f);
}

static int c_knows(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	{ bl_vec3 p; return bc_place_of(b, a->count > 0 ? a->text[0] : "self", &p); }
}

static int c_at(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return at_place(b, a);
}

static float s_always(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)b; (void)a; return 1.0f;
}

static float s_enemy_visible(void *bot, const bt_args *a)
{
	bc_bot *b = bot;
	float secs = arg(a, 0, 0.0f), t;

	if (b->senses.n_visible > 0)
		return 1.0f;
	/* and, asked for, a while after the last one left its sight: a man
	 * behind a wall between two peeks is still the fight it is in --
	 * not back to its duty and round again when he shows (babel) */
	if (secs <= 0.0f || !b->senses.lost.valid)
		return 0.0f;
	t = (float)(b->e->now - b->senses.lost.at);
	return t < secs ? 1.0f - t / secs : 0.0f;
}

static float s_enemy_known(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; return b->senses.n_visible > 0 || b->senses.nearest_known < 0 ? 0.0f : 0.3f + 0.7f * bc_senses_confidence(&b->senses, &b->e->sense, b->senses.nearest_known, b->e->now);
}

static float s_enemy_near(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	{ float d = near_enemy(b), r = arg(a, 0, 60.0f); return d >= r ? 0.0f : 1.0f - d / r; }
}

static float s_hurt(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; return clamp01(1.0f - (float)bc_me(b)->hp / 100.0f);
}

static float s_hurt_in_fight(void *bot, const bt_args *a)
{
	bc_bot *b = bot;
	int threat = b->senses.threat.valid && b->e->now - b->senses.threat.at < 3.0;

	(void)a;
	if (b->senses.n_visible == 0 && !threat)
		return 0.0f;
	if (b->e->now - b->cover.since < 6.0 && !b->cover.valid)
		return 0.0f;        /* just out of a retreat: it fights from where it is */
	return clamp01(1.0f - (float)bc_me(b)->hp / 100.0f);
}

static float s_healthy(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; return clamp01((float)bc_me(b)->hp / 100.0f);
}

static float s_search(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; return search_fresh(b);
}

static float s_ping_called(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; return ping_is(b, NULL) ? 1.0f : 0.0f;
}

static float s_has_order(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; return order_stands(b) ? 1.0f : 0.0f;
}

static float s_alone(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	{ float d, r = arg(a, 0, 40.0f); if (bc_nearest_mate(b, &d) < 0) return 0.0f; return clamp01(d / r); }
}

static float s_grenade_worth(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; return nade_worth(b) ? 1.0f : 0.0f;
}

static float s_grenade_near(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; return bc_grenade_threat(b, NULL) >= 25.0f ? 1.0f : 0.0f;
}

static float s_outnumbered(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	return clamp01(0.34f * (float)(b->senses.n_visible - 1 - bc_mates_within(b, bc_me(b)->pos, arg(a, 0, 20.0f))));
}

static float s_night(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; return b->e->w.night ? 1.0f : 0.0f;
}

static float s_calm(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; return b->senses.alert == BC_ALERT_CALM ? 1.0f : b->senses.alert == BC_ALERT_SUSPICIOUS ? 0.3f : 0.0f;
}

static float s_has_item(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	return a->count > 0 && bc_item_count(b, a->text[0]) != 0 ? 1.0f : 0.0f;
}

static float s_ammo_low(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; return clamp01(1.0f - ammo_frac(b));
}

static int c_has_night_vision(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a;
	return b->night_vision != 0;
}

static float s_night_vision(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a;
	return b->e->w.night && b->night_vision ? 1.0f : 0.0f;
}

static float s_hit_in_dark(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a;
	return b->e->w.night && !b->night_vision && b->e->now - b->senses.hurt_at < 8.0 ? 1.0f : 0.0f;
}


static int gun_named(const bc_bot *b, const bt_args *a, int dflt)
{
	static const char *const names[3] = { "rifle", "smg", "shotgun" };
	int gun = bc_me(b)->gun, i;

	if (!a || a->count == 0)
		return dflt;
	for (i = 0; i < a->count; i++)
		if (gun <= 2 && !strcmp(a->text[i], names[gun]))
			return 1;
	return 0;
}

static float fire_fresh(const bc_bot *b, float secs)
{
	float v = 1.0f - (float)(b->e->now - b->senses.shot_at) / secs;

	return v < 0.0f ? 0.0f : v;
}

/* how hard pressed: health lost, and enemies in sight against mates near */
static float pressed(const bc_bot *b)
{
	const bl_player *me = bc_me(b);

	if (b->senses.n_visible == 0 && b->e->now - b->senses.shot_at > 4.0)
		return 0.0f;
	if (b->e->now - b->cover.since < 6.0 && !b->cover.valid)
		return 0.0f;
	/* truly pressed, and only then: no round left; or hurt AND
	 * outnumbered -- either alone is a fight to face (the owner: "when
	 * getting shot at you should almost never turn around and go back") */
	if (me->mag == 0 && me->reserve == 0)
		return 1.0f;
	return clamp01(1.0f - (float)me->hp / 100.0f) *
	       clamp01((float)(b->senses.n_visible - 1 - bc_mates_within(b, me->pos, 20.0f)));
}

/* the man it would fight is in its gun's reach and beyond its own
 * holding distance: one to stand off and shoot */
static float standoff(const bc_bot *b)
{
	float d = near_enemy(b);

	return d < 0.55f * bc_engage_range(b) && d > 1.35f * bc_hold_range(b) ? 1.0f : 0.0f;
}

static int c_gun_is(void *bot, const bt_args *a) { return gun_named(bot, a, 0); }
static int c_under_fire(void *bot, const bt_args *a) { bc_bot *b = bot; return b->e->now - b->senses.shot_at < (double)arg(a, 0, 3.0f); }
static int c_in_cover(void *bot, const bt_args *a) { bc_bot *b = bot; bl_vec3 th; (void)a; return bc_threat_place(b, &th) && !bc_exposed_to(b, th); }
static int c_in_harmful_water(void *bot, const bt_args *a) { (void)a; return bc_in_harmful_water(bot); }
/* no way from here to anywhere it was sent (skill_move.c, SHUT IN) */
static int c_stranded(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a;
	return b->e->now < b->mv.shut_until || b->e->now < b->mv.stranded_until;
}
static float s_stranded(void *bot, const bt_args *a) { return (float)c_stranded(bot, a); }
static int cover_in_view(bc_bot *b, const bt_args *a)
{
	bl_vec3 th;

	return !bc_in_harmful_water(b) && bc_threat_place(b, &th) &&
	       bc_cover_view(b, th, (int)arg(a, 0, 12.0f), arg(a, 1, 120.0f));
}
static int c_cover_in_view(void *bot, const bt_args *a) { return cover_in_view(bot, a); }
static float s_cover_in_view(void *bot, const bt_args *a) { return cover_in_view(bot, a) ? 1.0f : 0.0f; }
static float s_gun_is(void *bot, const bt_args *a) { return gun_named(bot, a, 0) ? 1.0f : 0.0f; }
static float s_under_fire(void *bot, const bt_args *a) { return fire_fresh(bot, arg(a, 0, 4.0f)); }
static float s_pressed(void *bot, const bt_args *a) { (void)a; return pressed(bot); }
static float s_standoff(void *bot, const bt_args *a) { (void)a; return standoff(bot); }
static float s_harmful_water(void *bot, const bt_args *a) { (void)a; return bc_in_harmful_water(bot) ? 1.0f : 0.0f; }
static float s_flank_open(void *bot, const bt_args *a) { (void)a; return bc_flank_open(bot) ? 1.0f : 0.0f; }
static float s_rumour(void *bot, const bt_args *a) { bc_bot *b = bot; (void)a; return b->e->now < b->hunt.cd_until ? 0.0f : bc_rumour(b, NULL); }

static float s_enemy_far(void *bot, const bt_args *a)
{
	bc_bot *b = bot;
	float d = near_enemy(b), r = arg(a, 0, 60.0f);

	return b->senses.n_visible == 0 ? 0.0f : clamp01(d / r);
}

static float s_mate_near(void *bot, const bt_args *a)
{
	bc_bot *b = bot;
	float d, r = arg(a, 0, 40.0f);

	if (bc_nearest_mate(b, &d) < 0 || b->e->now < b->follow.cd_until)
		return 0.0f;
	return clamp01(1.0f - d / r) * 0.8f + 0.2f;
}

static float s_vantage(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	if (!gun_named(b, a, 1) || b->e->now < b->camp.cd_until || bc_in_harmful_water(b))
		return 0.0f;
	return bc_perch_pick(b, 0) >= 0 ? 1.0f : 0.0f;
}


static int obj_is(void *bot, int own, int state) { return bc_obj_state(bot, own) == state; }
static int c_carrying_intel(void *bot, const bt_args *a) { (void)a; return bc_carrying(bot); }
static int c_their_intel_home(void *bot, const bt_args *a) { (void)a; return obj_is(bot, 0, BC_OBJ_HOME); }
static int c_their_intel_dropped(void *bot, const bt_args *a) { (void)a; return obj_is(bot, 0, BC_OBJ_DROPPED); }
static int c_their_intel_carried(void *bot, const bt_args *a) { (void)a; return obj_is(bot, 0, BC_OBJ_CARRIED) && !bc_carrying(bot); }
static int c_our_intel_home(void *bot, const bt_args *a) { (void)a; return obj_is(bot, 1, BC_OBJ_HOME); }
static int c_our_intel_dropped(void *bot, const bt_args *a) { (void)a; return obj_is(bot, 1, BC_OBJ_DROPPED); }
static int c_our_intel_taken(void *bot, const bt_args *a) { (void)a; return obj_is(bot, 1, BC_OBJ_CARRIED); }
static float s_carrying_intel(void *bot, const bt_args *a) { return (float)c_carrying_intel(bot, a); }
static float s_their_intel_home(void *bot, const bt_args *a) { return (float)c_their_intel_home(bot, a); }
static float s_their_intel_dropped(void *bot, const bt_args *a) { return (float)c_their_intel_dropped(bot, a); }
static float s_their_intel_carried(void *bot, const bt_args *a) { return (float)c_their_intel_carried(bot, a); }
/* A DUTY FOR A FEW OF THE TEAM: `slot <name> <n>` holds while this bot
 * holds it, or while fewer than n team-mates do -- and asking it, with
 * that answer, is holding it (for 2 s: a pick that keeps choosing the
 * branch asks it every second). The first to have come keep it; a branch
 * the bot is in no more lets it go by itself. Like escorts' two a
 * carrier, for whatever a tree wants a few of (babel's platform). */
static int c_slot(void *bot, const bt_args *a)
{
	bc_bot *b = bot;
	bc_engine *e = b->e;
	const char *name = a->count > 0 ? a->text[0] : "";
	int n = a->count > 1 ? (int)(a->num[1] + 0.5f) : 1, i, before = 0, mine;
	double keep = 2.0;

	mine = !strcmp(b->slot.name, name) && e->now - b->slot.at <= keep;
	for (i = 0; i < e->max_bots; i++) {
		const bc_bot *o = &e->bots[i];

		if (!o->used || o == b || e->w.players[o->pid].team != bc_me(b)->team ||
		    strcmp(o->slot.name, name) || e->now - o->slot.at > keep)
			continue;
		if (!mine || o->slot.since < b->slot.since || (o->slot.since == b->slot.since && o->pid < b->pid))
			before++;
	}
	if (before >= n)
		return 0;
	if (!mine) {
		snprintf(b->slot.name, sizeof b->slot.name, "%s", name);
		b->slot.since = e->now;
	}
	b->slot.at = e->now;
	return 1;
}
static float s_slot(void *bot, const bt_args *a) { return (float)c_slot(bot, a); }

static int c_escort_open(void *bot, const bt_args *a) { (void)a; return bc_escort_open(bot); }
static float s_escort_open(void *bot, const bt_args *a) { return (float)c_escort_open(bot, a); }
static float s_our_intel_home(void *bot, const bt_args *a) { return (float)c_our_intel_home(bot, a); }
static float s_our_intel_dropped(void *bot, const bt_args *a) { return (float)c_our_intel_dropped(bot, a); }
static float s_our_intel_taken(void *bot, const bt_args *a) { return (float)c_our_intel_taken(bot, a); }

static float place_near(bc_bot *b, const char *name, float r)
{
	const bl_player *me = bc_me(b);
	bl_vec3 p;
	float dx, dy;

	if (!bc_place_of(b, name, &p))
		return 0.0f;
	dx = p.x - me->pos.x; dy = p.y - me->pos.y;
	return clamp01(1.0f - sqrtf(dx * dx + dy * dy) / r);
}

static int c_near_own_base(void *bot, const bt_args *a) { return place_near(bot, "own_base", arg(a, 0, 20.0f)) > 0.0f; }
static int c_near_their_base(void *bot, const bt_args *a) { return place_near(bot, "enemy_base", arg(a, 0, 20.0f)) > 0.0f; }
static float s_near_own_base(void *bot, const bt_args *a) { return place_near(bot, "own_base", arg(a, 0, 40.0f)); }
static float s_near_their_base(void *bot, const bt_args *a) { return place_near(bot, "enemy_base", arg(a, 0, 40.0f)); }
static int c_mates_near(void *bot, const bt_args *a) { bc_bot *b = bot; return bc_mates_within(b, bc_me(b)->pos, arg(a, 0, 15.0f)) >= (int)arg(a, 1, 1.0f); }
static float s_mates_near(void *bot, const bt_args *a) { bc_bot *b = bot; return clamp01((float)bc_mates_within(b, bc_me(b)->pos, arg(a, 0, 15.0f)) / 3.0f); }


static int c_is_leader(void *bot, const bt_args *a) { bc_bot *b = bot; (void)a; return bc_is_leader(b->e, b->pid); }
static int c_has_leader(void *bot, const bt_args *a) { (void)a; return bc_leader_of(bot) >= 0; }
static int c_leader_fighting(void *bot, const bt_args *a) { bc_bot *b = bot; (void)a; return bc_leader_fighting(b->e, bc_leader_of(b)); }
static float s_is_leader(void *bot, const bt_args *a) { return (float)c_is_leader(bot, a); }
static float s_has_leader(void *bot, const bt_args *a) { return (float)c_has_leader(bot, a); }

static int c_leader_near(void *bot, const bt_args *a)
{
	bc_bot *b = bot;
	int l = bc_leader_of(b);
	float dx, dy, r = arg(a, 0, 12.0f);

	if (l < 0) return 0;
	dx = b->e->w.players[l].pos.x - bc_me(b)->pos.x; dy = b->e->w.players[l].pos.y - bc_me(b)->pos.y;
	return dx * dx + dy * dy <= r * r;
}

static float s_quiet(void *bot, const bt_args *a)
{
	bc_bot *b = bot;
	double since = b->senses.last_sight > b->born_at ? b->senses.last_sight : b->born_at;

	return b->e->now - since >= (double)arg(a, 0, 20.0f) ? 1.0f : 0.0f;
}

/* is a place short of team-mates: 1 with none within radius, 0.5 with one, 0 with two */
static float s_unwatched(void *bot, const bt_args *a)
{
	bc_bot *b = bot;
	bl_vec3 p;
	int n;

	if (!bc_place_of(b, a->count > 0 ? a->text[0] : "own_intel", &p))
		return 0.0f;
	n = bc_mates_within(b, p, arg(a, 1, 20.0f));
	return n >= 2 ? 0.0f : n == 1 ? 0.5f : 1.0f;
}

/* are enough team-mates on guard at a place already (the `guard` action,
 * there now)? Passing by it is not watching it. */
static int c_watched(void *bot, const bt_args *a)
{
	bc_bot *b = bot;
	const bc_engine *e = b->e;
	int team = bc_me(b)->team, i, n = 0;
	float r = arg(a, 1, 20.0f);
	bl_vec3 p;

	if (!bc_place_of(b, a->count > 0 ? a->text[0] : "own_intel", &p))
		return 0;
	for (i = 0; i < e->max_bots; i++) {
		const bc_bot *o = &e->bots[i];
		float dx, dy;

		if (!o->used || !o->alive || o == b || !o->guard.started || e->w.players[o->pid].team != team)
			continue;
		dx = o->guard.place.x - p.x; dy = o->guard.place.y - p.y;
		if (dx * dx + dy * dy <= r * r) n++;
	}
	return n >= (int)arg(a, 2, 2.0f);
}

/* 1 while fewer than `count` team-mates are on guard at the place; with
 * the word `dropped`, only while the place is an intel lying where a
 * carrier fell */
static float s_unguarded(void *bot, const bt_args *a)
{
	bc_bot *b = bot;
	const char *place = a->count > 0 ? a->text[0] : "own_intel";

	if (!strcmp(place, "own_intel") || !strcmp(place, "our_intel") || !strcmp(place, "enemy_intel") ||
	    !strcmp(place, "their_intel")) {
		int st = bc_obj_state(b, place[0] == 'o');

		/* an intel somebody carries is not a place to stand guard at */
		if (st == BC_OBJ_CARRIED || (a->count > 3 && !strcmp(a->text[3], "dropped") && st != BC_OBJ_DROPPED))
			return 0.0f;
	}
	return c_watched(bot, a) ? 0.0f : 1.0f;
}

/* what a server script set (engine.c, THE BRIDGE) */
static int c_fact(void *bot, const bt_args *a)
{
	float v;

	if (a->count < 1 || !bc_fact_get(bot, a->text[0], &v))
		return 0;
	return a->count > 1 ? v >= a->num[1] : v > 0.0f;
}

static float s_fact(void *bot, const bt_args *a)
{
	float v;

	return a->count > 0 && bc_fact_get(bot, a->text[0], &v) ? clamp01(v) : 0.0f;
}

enum { VK_C, VK_S, VK_A };         /* the same numbers as bt.h's BT_WORD_* */

typedef struct word {
	int kind;
	const char *name;
	int n_args;
	bt_arg_spec args[BT_ARGS_MAX];
	const char *doc;
	bt_cond_fn cond;
	bt_score_fn score;
	bt_action_fn action;
	bt_stop_fn stop;
} word;

/* AN ARGUMENT, as data: what the compiler checks a tree against (bt.h,
 * bt_vocab_args), what the usage in `bttree --words` is written from,
 * and what an editor shows. Each default below is the one the function
 * that reads the argument uses -- change them together.
 *   name, type, required, repeat, has_default, has_min, has_max,
 *   values, set, default, min, max, default word, default in words */
#define NOARGS 0, { { 0 } }
/* a number: must be given / may be, with its default / may be, and what
 * leaving it out means cannot be said in one number */
#define NREQ(name)            { name, BT_ARG_NUMBER, 1, 0, 0, 1, 0, NULL, NULL, 0.0f, 0.0f, 0.0f, NULL, NULL }
#define NRANGE(name, lo, hi)  { name, BT_ARG_NUMBER, 1, 0, 0, 1, 1, NULL, NULL, 0.0f, lo, hi, NULL, NULL }
#define NOPT(name, def)       { name, BT_ARG_NUMBER, 0, 0, 1, 1, 0, NULL, NULL, def, 0.0f, 0.0f, NULL, NULL }
#define NOPT_NOTE(name, def, note) { name, BT_ARG_NUMBER, 0, 0, 1, 1, 0, NULL, NULL, def, 0.0f, 0.0f, NULL, note }
#define NNOTE(name, note)     { name, BT_ARG_NUMBER, 0, 0, 0, 1, 0, NULL, NULL, 0.0f, 0.0f, 0.0f, NULL, note }
/* one of the places (skill_misc.c's table) */
#define PLACE                 { "place", BT_ARG_ONE_OF, 1, 0, 0, 0, 0, NULL, "place", 0.0f, 0.0f, 0.0f, NULL, NULL }
#define PLACE_OPT(def)        { "place", BT_ARG_ONE_OF, 0, 0, 0, 0, 0, NULL, "place", 0.0f, 0.0f, 0.0f, def, NULL }
#define PLACE_NOTE(note)      { "place", BT_ARG_ONE_OF, 0, 0, 0, 0, 0, NULL, "place", 0.0f, 0.0f, 0.0f, NULL, note }
/* one of the words listed */
#define ONE(name, values)     { name, BT_ARG_ONE_OF, 1, 0, 0, 0, 0, values, NULL, 0.0f, 0.0f, 0.0f, NULL, NULL }
#define ONE_REP(name, values) { name, BT_ARG_ONE_OF, 1, 1, 0, 0, 0, values, NULL, 0.0f, 0.0f, 0.0f, NULL, NULL }
#define ONE_OPT(name, values, def) { name, BT_ARG_ONE_OF, 0, 0, 0, 0, 0, values, NULL, 0.0f, 0.0f, 0.0f, def, NULL }
#define ONE_NOTE(name, values, note) { name, BT_ARG_ONE_OF, 0, 0, 0, 0, 0, values, NULL, 0.0f, 0.0f, 0.0f, NULL, note }
#define ONE_NOTE_REP(name, values, note) { name, BT_ARG_ONE_OF, 0, 1, 0, 0, 0, values, NULL, 0.0f, 0.0f, 0.0f, NULL, note }
/* any word */
#define TEXT(name)            { name, BT_ARG_TEXT, 1, 0, 0, 0, 0, NULL, NULL, 0.0f, 0.0f, 0.0f, NULL, NULL }
#define TEXT_OPT(name, note)  { name, BT_ARG_TEXT, 0, 0, 0, 0, 0, NULL, NULL, 0.0f, 0.0f, 0.0f, NULL, note }
#define TEXT_REP(name)        { name, BT_ARG_TEXT, 1, 1, 0, 0, 0, NULL, NULL, 0.0f, 0.0f, 0.0f, NULL, NULL }

static const word WORDS[] = {
	{ VK_C, "enemy_visible", NOARGS, "an enemy is in this bot's sight now", c_enemy_visible, NULL, NULL, NULL },
	{ VK_C, "enemy_known", NOARGS, "an enemy is in sight, remembered, or told of by the team", c_enemy_known, NULL, NULL, NULL },
	{ VK_C, "enemy_within", 1, { NREQ("voxels") }, "the nearest enemy in sight is nearer than that", c_enemy_within, NULL, NULL, NULL },
	{ VK_C, "enemy_beyond", 1, { NREQ("voxels") }, "an enemy is in sight and the nearest is farther than that", c_enemy_beyond, NULL, NULL, NULL },
	{ VK_C, "enemies_grouped", 2, { NREQ("count"), NREQ("radius") }, "that many known enemies stand within radius of one another", c_enemies_grouped, NULL, NULL, NULL },
	{ VK_C, "target_in_cover", 1, { NOPT("secs", 5.0f) }, "the man being fought was seen under that many seconds ago (default 5) and is out of sight now", c_target_in_cover, NULL, NULL, NULL },
	{ VK_C, "outnumbered", 1, { NOPT("radius", 20.0f) }, "more enemies in sight than team-mates within radius (default 20), itself included", c_outnumbered, NULL, NULL, NULL },
	{ VK_C, "health_below", 1, { NRANGE("hp", 0.0f, 100.0f) }, "its health is under that (of 100)", c_health_below, NULL, NULL, NULL },
	{ VK_C, "level_at_least", 1, { NRANGE("level", 1.0f, 10.0f) }, "it is a bot of that level or better (1 to 10: how well it aims, how soon it reacts, how fast it turns)", c_level_at_least, NULL, NULL, NULL },
	{ VK_C, "hurt_recently", 1, { NOPT("secs", 3.0f) }, "it lost health within that many seconds (default 3)", c_hurt_recently, NULL, NULL, NULL },
	{ VK_C, "ammo_below", 1, { NRANGE("fraction", 0.0f, 1.0f) }, "rounds left, magazine and reserve, are under that fraction of a full load", c_ammo_below, NULL, NULL, NULL },
	{ VK_C, "ammo_out", NOARGS, "no round left at all", c_ammo_out, NULL, NULL, NULL },
	{ VK_C, "has_grenade", NOARGS, "it carries a grenade", c_has_grenade, NULL, NULL, NULL },
	{ VK_C, "grenade_worth", NOARGS, "it has a grenade, is not just done throwing, and something is worth one (a group, a far man, a place just lost)", c_grenade_worth, NULL, NULL, NULL },
	{ VK_C, "grenade_near", NOARGS, "an enemy grenade it has noticed would hurt it where it stands", c_grenade_near, NULL, NULL, NULL },
	{ VK_C, "heard_noise", NOARGS, "a noise it heard is still worth going to", c_heard_noise, NULL, NULL, NULL },
	{ VK_C, "lost_enemy", NOARGS, "somebody left its sight and the place is still fresh", c_lost_enemy, NULL, NULL, NULL },
	{ VK_C, "has_search", NOARGS, "there is a place worth searching: a lost man, a hit's source, a noise, a told sighting", c_has_search, NULL, NULL, NULL },
	{ VK_C, "alert", 1, { ONE("level", "calm|suspicious|engaged") }, "its alertness is that", c_alert, NULL, NULL, NULL },
	{ VK_C, "ping_called", 1, { ONE_NOTE("kind", "enemy|help|go", "any kind") }, "a team-mate's ping was given to this bot to answer (of that kind, if said)", c_ping_called, NULL, NULL, NULL },
	{ VK_C, "has_order", NOARGS, "the server gave it an order that stands", c_has_order, NULL, NULL, NULL },
	{ VK_C, "is_night", NOARGS, "it is night", c_is_night, NULL, NULL, NULL },
	{ VK_C, "has_night_vision", NOARGS, "it sees by night as by day (the setting night_vision)", c_has_night_vision, NULL, NULL, NULL },
	{ VK_S, "night_vision", NOARGS, "1 by night for a bot that has night vision", NULL, s_night_vision, NULL, NULL },
	{ VK_S, "hit_in_dark", NOARGS, "1 by night for a bot with no night vision that was hit in the last 8 s", NULL, s_hit_in_dark, NULL, NULL },
	{ VK_C, "lamp_on", NOARGS, "its flashlight is lit", c_lamp_on, NULL, NULL, NULL },
	{ VK_C, "has_item", 1, { TEXT("name") }, "it holds at least one of that inventory item", c_has_item, NULL, NULL, NULL },
	{ VK_C, "sky_clear", NOARGS, "nothing solid above its head (a thing that comes down from the sky needs it)", c_sky_clear, NULL, NULL, NULL },
	{ VK_C, "allies_hurt_near", 2, { NREQ("radius"), NOPT("hp", 50.0f) }, "a team-mate under hp health (default 50) is within radius", c_allies_hurt_near, NULL, NULL, NULL },
	{ VK_C, "mate_within", 1, { NREQ("voxels") }, "a live team-mate is that near", c_mate_within, NULL, NULL, NULL },
	{ VK_C, "alone", 1, { NOPT("voxels", 25.0f) }, "no live team-mate within that (default 25)", c_alone, NULL, NULL, NULL },
	{ VK_C, "spotted_new", 1, { NOPT("secs", 2.0f) }, "it has seen, within that many seconds (default 2), an enemy its team did not know of", c_spotted_new, NULL, NULL, NULL },
	{ VK_C, "losing", NOARGS, "it is in a fight, under 45 health and outnumbered, or under 30 and just hit", c_losing, NULL, NULL, NULL },
	{ VK_C, "sniped", 2, { NOPT("voxels", 50.0f), NOPT("secs", 3.0f) }, "it was hit within secs (default 3) from farther than voxels (default 50)", c_sniped, NULL, NULL, NULL },
	{ VK_C, "setting", 2, { TEXT("key"), TEXT_OPT("value", "any value: the setting is set") }, "the gamemode's setting <key> is set (to <value>, if said): how a mode's tree reads the mode's own rules", c_setting, NULL, NULL, NULL },
	{ VK_C, "chance", 1, { NRANGE("probability", 0.0f, 1.0f) }, "true that often, by the bot's own dice", c_chance, NULL, NULL, NULL },
	{ VK_C, "knows", 1, { PLACE }, "the bot knows of such a place now", c_knows, NULL, NULL, NULL },
	{ VK_C, "at", 2, { PLACE, NOPT("voxels", 4.0f) }, "it is within that of the place (default 4)", c_at, NULL, NULL, NULL },
	{ VK_S, "always", NOARGS, "1", NULL, s_always, NULL, NULL },
	{ VK_S, "enemy_visible", 1, { NOPT("secs", 0.0f) }, "1 with an enemy in sight; with secs, for that long after the last one left its sight, fading to 0 (a fight is not dropped between two peeks); else 0", NULL, s_enemy_visible, NULL, NULL },
	{ VK_S, "enemy_known", NOARGS, "how sure it is of an enemy it cannot see: 1 fresh, fading to 0; 0 with one in sight", NULL, s_enemy_known, NULL, NULL },
	{ VK_S, "enemy_near", 1, { NOPT("voxels", 60.0f) }, "1 with an enemy in sight at arm's length, falling to 0 at that distance (default 60)", NULL, s_enemy_near, NULL, NULL },
	{ VK_S, "hurt", NOARGS, "health lost: 0 unhurt, 1 nearly dead", NULL, s_hurt, NULL, NULL },
	{ VK_S, "hurt_in_fight", NOARGS, "health lost, counted only with an enemy in sight or a hit from somewhere in the last 3 s; 0 for 6 s after a retreat", NULL, s_hurt_in_fight, NULL, NULL },
	{ VK_S, "healthy", NOARGS, "health left, 0 to 1", NULL, s_healthy, NULL, NULL },
	{ VK_S, "level", NOARGS, "how good the bot is: 0 at level 1, 1 at level 10 (an option the able lean to)", NULL, s_level, NULL, NULL },
	{ VK_S, "search", NOARGS, "how fresh the place most worth searching is: 1 just now, 0 none", NULL, s_search, NULL, NULL },
	{ VK_S, "ping_called", NOARGS, "1 while a team-mate's ping is this bot's to answer", NULL, s_ping_called, NULL, NULL },
	{ VK_S, "has_order", NOARGS, "1 while an order stands", NULL, s_has_order, NULL, NULL },
	{ VK_S, "alone", 1, { NOPT("voxels", 40.0f) }, "0 beside a team-mate, rising to 1 at that distance (default 40) or with none alive", NULL, s_alone, NULL, NULL },
	{ VK_S, "grenade_worth", NOARGS, "1 when a grenade is worth throwing now (see the condition)", NULL, s_grenade_worth, NULL, NULL },
	{ VK_S, "grenade_near", NOARGS, "1 when an enemy grenade would hurt it here", NULL, s_grenade_near, NULL, NULL },
	{ VK_S, "outnumbered", 1, { NOPT("radius", 20.0f) }, "0 when not (enemies in sight against team-mates within radius, default 20); else how badly, up to 1", NULL, s_outnumbered, NULL, NULL },
	{ VK_S, "night", NOARGS, "1 by night", NULL, s_night, NULL, NULL },
	{ VK_S, "calm", NOARGS, "1 when nothing is known, 0.3 when suspicious, 0 engaged", NULL, s_calm, NULL, NULL },
	{ VK_S, "has_item", 1, { TEXT("name") }, "1 if it holds one", NULL, s_has_item, NULL, NULL },
	{ VK_S, "ammo_low", NOARGS, "0 with a full load, 1 with none", NULL, s_ammo_low, NULL, NULL },
	{ VK_C, "gun_is", 1, { ONE_REP("gun", "rifle|smg|shotgun") }, "its gun is one of those named", c_gun_is, NULL, NULL, NULL },
	{ VK_C, "under_fire", 1, { NOPT("secs", 3.0f) }, "it was shot at within that many seconds (default 3): hurt by somebody, a round that passed within 2.5 voxels, a team-mate killed within 12", c_under_fire, NULL, NULL, NULL },
	{ VK_C, "in_cover", NOARGS, "what threatens it (the man it fights, where a hit came from) has no line of sight to its body as it stands", c_in_cover, NULL, NULL, NULL },
	{ VK_C, "stranded", NOARGS, "it has no way from where it is to anywhere it was sent: three searches in a row found none (a roof with no way down and no edits, a closed room). While so no route is asked for; a goal where it stands is reached. What it does meanwhile is the tree's: hold and watch, shoot from there", c_stranded, NULL, NULL, NULL },
	{ VK_S, "stranded", NOARGS, "1 while stranded (see the condition), else 0", NULL, s_stranded, NULL, NULL },
	{ VK_C, "cover_in_view", 2, { NOPT("steps", 12.0f), NOPT("degrees", 120.0f) }, "there is cover from what threatens it within that many steps walked (default 12) and a cone of that many degrees (default 120, the whole angle) about the bearing to the threat: cover it can see as it faces him, ahead or across, not behind its back", c_cover_in_view, NULL, NULL, NULL },
	{ VK_S, "cover_in_view", 2, { NOPT("steps", 12.0f), NOPT("degrees", 120.0f) }, "1 when there is cover in view (see the condition), else 0", NULL, s_cover_in_view, NULL, NULL },
	{ VK_C, "in_harmful_water", NOARGS, "it is wading in water that hurts (the settings water=lethal or water.damage)", c_in_harmful_water, NULL, NULL, NULL },
	{ VK_S, "gun_is", 1, { ONE_REP("gun", "rifle|smg|shotgun") }, "1 if its gun is one of those named, else 0", NULL, s_gun_is, NULL, NULL },
	{ VK_S, "under_fire", 1, { NOPT("secs", 4.0f) }, "1 just shot at (see the condition), falling to 0 over that many seconds (default 4)", NULL, s_under_fire, NULL, NULL },
	{ VK_S, "pressed", NOARGS, "how hard pressed in a fight: 1 with no round left; else the health lost, times 1 when more enemies are in sight than itself and the team-mates within 20 (0 when not: hurt alone, or outnumbered alone, is a fight to face); 0 with nobody in sight and no round for 4 s", NULL, s_pressed, NULL, NULL },
	{ VK_S, "standoff", NOARGS, "1 when the nearest enemy in sight is within half its gun's opening range and farther than it would close to: one to stand and shoot at", NULL, s_standoff, NULL, NULL },
	{ VK_S, "enemy_far", 1, { NOPT("voxels", 60.0f) }, "0 with an enemy in sight at arm's length, rising to 1 at that distance (default 60); 0 with none in sight", NULL, s_enemy_far, NULL, NULL },
	{ VK_S, "mate_near", 1, { NOPT("voxels", 40.0f) }, "1 beside a team-mate, falling to 0.2 at that distance (default 40); 0 with none alive or one it just gave up following", NULL, s_mate_near, NULL, NULL },
	{ VK_S, "harmful_water", NOARGS, "1 while it wades in water that hurts", NULL, s_harmful_water, NULL, NULL },
	{ VK_S, "flank_open", NOARGS, "1 when the enemy's area (where the team last met him, else his base) is over 45 away and it has not just flanked", NULL, s_flank_open, NULL, NULL },
	{ VK_S, "rumour", NOARGS, "how fresh the freshest rumour of the enemy is -- a noise it heard, a team-mate's sighting, the team's last meeting -- that is over 10 away and it has not just been to: 1 just now, 0 none", NULL, s_rumour, NULL, NULL },
	{ VK_S, "vantage", 1, { ONE_NOTE_REP("gun", "rifle|smg|shotgun", "any gun") }, "1 when the team knows a perch nobody has claimed (high, a long view toward the enemy, a way up) and its gun is one of those named (any, when none is)", NULL, s_vantage, NULL, NULL },
	{ VK_A, "crouch", 1, { NNOTE("secs", "the flinch: 0.3 to 1 s by its caution, once for a burst of fire") }, "down where it stands, turned to what shot at it, shooting if it sees him. With no time said it is the flinch: 0.3 to 1 s by character, once for a burst of fire (asked again it succeeds at once)", NULL, NULL, bc_do_crouch, bc_do_cover_stop },
	{ VK_A, "take_cover", 3, { ONE_OPT("where", "any|in_view", "any"), NOPT("steps", 12.0f), NOPT("degrees", 120.0f) }, "to the best cover from what threatens it (near, well hidden, a way out behind, no team-mate in it), within that many steps walked (default 12), moving with its head on the threat (backing, sidestepping: never turning its back), turned to him before it sets off; there crouched if the cover is low, facing the threat, peeking to fire -- rarely and long for the careful, hardly stopping for the bold. `any`: cover in any direction; with none in reach, crouched where it stands, turned to the threat. `in_view`: only cover within that cone (default 120 degrees, the whole angle) about the bearing to the threat -- ahead or across, as it faces him -- and FAILURE at once with none (the tree then has it face him: `crouch`). SUCCESS after its time there (0.8 to 14 s by character); FAILURE with no threat", NULL, NULL, bc_do_take_cover, bc_do_cover_stop },
	{ VK_A, "advance_by_cover", 2, { PLACE_OPT("enemy"), NOPT_NOTE("radius", 3.0f, "at the enemy, with no radius said: its own fighting distance") }, "toward a place (default: the enemy) from cover to cover, a pause at each by character; a run where no cover gains ground. SUCCESS there (at a man: at its own fighting distance); FAILURE no such place, no way", NULL, NULL, bc_do_advance_by_cover, bc_do_cover_stop },
	{ VK_A, "fall_back_by_cover", 1, { PLACE_OPT("own_base") }, "away from what threatens it toward a place (default own_base; with none, straight away), from cover to cover, not firing. SUCCESS out of sight with no round for 3 s, or there; FAILURE with no threat", NULL, NULL, bc_do_fall_back_by_cover, bc_do_cover_stop },
	{ VK_A, "seek", NOARGS, "go and find the enemy: to his base by the direct way, shooting what it meets; there and nobody, on to where the team last met him, then back as far as the middle, and round again. With no bases, or no way to his, it roams. Always RUNNING: a tree's last resort", NULL, NULL, bc_do_seek, bc_do_stop },
	{ VK_A, "flank", 1, { PLACE_OPT("enemy_area") }, "to the place (default: the enemy's area) the long way round, by a side of its own choosing, so as to come at it from behind. SUCCESS there; FAILURE too near to go round, no ground either side, no way", NULL, NULL, bc_do_flank, bc_do_tactics_stop },
	{ VK_A, "hunt_noise", NOARGS, "go to the freshest rumour of the enemy (see the score). SUCCESS on seeing the place from near; FAILURE none, no way", NULL, NULL, bc_do_hunt_noise, bc_do_tactics_stop },
	{ VK_A, "take_high_ground", NOARGS, "claim the best free perch for its gun and go up to it. SUCCESS on it; FAILURE none free, no way up", NULL, NULL, bc_do_take_high_ground, bc_do_tactics_stop },
	{ VK_A, "camp", 2, { NNOTE("secs", "its patience: 25 to 120 s by its caution and marksmanship"), NOPT("kills", 2.0f) }, "stay where it is, crouched, sweeping the arc toward the enemy, firing at what appears. SUCCESS after `kills` kills (default 2), when shot at, or when its patience is out (25 to 120 s by character, or secs; 0: by character): it then gives up its perch and takes another next time", NULL, NULL, bc_do_camp, bc_do_tactics_stop },
	{ VK_A, "leave_water", NOARGS, "to the nearest dry ground. SUCCESS dry; RUNNING on the way; FAILURE none within 48", NULL, NULL, bc_do_leave_water, bc_do_tactics_stop },
	{ VK_C, "carrying_intel", NOARGS, "it carries the other team's intel", c_carrying_intel, NULL, NULL, NULL },
	{ VK_C, "their_intel_home", NOARGS, "the other team's intel lies where the server put it", c_their_intel_home, NULL, NULL, NULL },
	{ VK_C, "their_intel_dropped", NOARGS, "the other team's intel lies where a carrier of this team fell", c_their_intel_dropped, NULL, NULL, NULL },
	{ VK_C, "their_intel_carried", NOARGS, "a team-mate carries the other team's intel", c_their_intel_carried, NULL, NULL, NULL },
	{ VK_C, "slot", 2, { TEXT("name"), NRANGE("n", 1.0f, 32.0f) }, "a duty for a few of the team: true while this bot holds it, or while fewer than n team-mates do -- and then it holds it (for 2 s, so a branch that keeps asking keeps it; the first to come keep it)", c_slot, NULL, NULL, NULL },
	{ VK_C, "escort_open", NOARGS, "a team-mate carries their intel, is going somewhere (not still for 4 s), and fewer than two escort him -- or this bot is one of them", c_escort_open, NULL, NULL, NULL },
	{ VK_C, "our_intel_home", NOARGS, "this team's intel lies where the server put it", c_our_intel_home, NULL, NULL, NULL },
	{ VK_C, "our_intel_dropped", NOARGS, "this team's intel lies where its thief fell (it cannot be picked up by its own team: it is guarded there)", c_our_intel_dropped, NULL, NULL, NULL },
	{ VK_C, "our_intel_taken", NOARGS, "an enemy carries this team's intel (where he is is known to everybody: the place `thief`)", c_our_intel_taken, NULL, NULL, NULL },
	{ VK_C, "near_own_base", 1, { NOPT("voxels", 20.0f) }, "it is within that of its team's base (default 20)", c_near_own_base, NULL, NULL, NULL },
	{ VK_C, "near_their_base", 1, { NOPT("voxels", 20.0f) }, "it is within that of the other team's base (default 20)", c_near_their_base, NULL, NULL, NULL },
	{ VK_C, "mates_near", 2, { NREQ("radius"), NOPT("count", 1.0f) }, "that many live team-mates (default 1) are within radius", c_mates_near, NULL, NULL, NULL },
	{ VK_S, "carrying_intel", NOARGS, "1 while it carries the other team's intel", NULL, s_carrying_intel, NULL, NULL },
	{ VK_S, "their_intel_home", NOARGS, "1 while the other team's intel lies where the server put it", NULL, s_their_intel_home, NULL, NULL },
	{ VK_S, "their_intel_dropped", NOARGS, "1 while it lies where a carrier fell", NULL, s_their_intel_dropped, NULL, NULL },
	{ VK_S, "their_intel_carried", NOARGS, "1 while a team-mate carries it", NULL, s_their_intel_carried, NULL, NULL },
	{ VK_S, "slot", 2, { TEXT("name"), NRANGE("n", 1.0f, 32.0f) }, "1 while this bot holds the duty, or fewer than n team-mates do (and then it holds it, for 2 s); else 0", NULL, s_slot, NULL, NULL },
	{ VK_S, "escort_open", NOARGS, "1 while a team-mate carries their intel, going somewhere, with a place for this bot beside him (two escorts at most)", NULL, s_escort_open, NULL, NULL },
	{ VK_S, "our_intel_home", NOARGS, "1 while this team's intel lies where the server put it", NULL, s_our_intel_home, NULL, NULL },
	{ VK_S, "our_intel_dropped", NOARGS, "1 while it lies where its thief fell", NULL, s_our_intel_dropped, NULL, NULL },
	{ VK_S, "our_intel_taken", NOARGS, "1 while an enemy carries it", NULL, s_our_intel_taken, NULL, NULL },
	{ VK_S, "near_own_base", 1, { NOPT("voxels", 40.0f) }, "1 at its team's base, falling to 0 at that distance (default 40)", NULL, s_near_own_base, NULL, NULL },
	{ VK_S, "near_their_base", 1, { NOPT("voxels", 40.0f) }, "1 at the other team's base, falling to 0 at that distance (default 40)", NULL, s_near_their_base, NULL, NULL },
	{ VK_S, "mates_near", 1, { NREQ("radius") }, "0 with no team-mate within radius, 1 with three or more", NULL, s_mates_near, NULL, NULL },
	{ VK_A, "fetch", NOARGS, "go to the other team's intel where it lies and walk onto it (the server gives it to whoever of the other team stands within 3 of it). SUCCESS carrying it; FAILURE none, somebody has it, no way", NULL, NULL, bc_do_fetch, bc_do_objective_stop },
	{ VK_A, "carry_home", 1, { NOPT("voxels", 14.0f) }, "the carrier runs for its own base by a route that keeps away from the enemies it knows of, shooting only at a man within voxels (default 14). RUNNING while it carries; SUCCESS when it no longer does; FAILURE no base, no way", NULL, NULL, bc_do_carry_home, bc_do_objective_stop },
	{ VK_A, "escort", NOARGS, "stay by the team-mate who carries the intel: ahead of him toward the base and to a side, shooting what it sees. RUNNING; FAILURE nobody carries", NULL, NULL, bc_do_escort, bc_do_objective_stop },
	{ VK_A, "intercept", NOARGS, "cut off the enemy who carries this team's intel: to the point of his way home it can reach before he does, and fight him on sight. RUNNING; FAILURE nobody has it", NULL, NULL, bc_do_intercept, bc_do_objective_stop },
	{ VK_A, "guard", 2, { PLACE_OPT("own_intel"), NOPT("secs", 30.0f) }, "hold near a place (default own_intel) at a spot of its own on the side the enemy comes from, crouched if careful, watching that way, shooting what appears. SUCCESS after secs (default 30); FAILURE no such place, no way", NULL, NULL, bc_do_guard, bc_do_objective_stop },
	{ VK_C, "is_leader", NOARGS, "it is one of its team's leaders (drawn by lot by the engine; it is not told otherwise)", c_is_leader, NULL, NULL, NULL },
	{ VK_C, "has_leader", NOARGS, "it follows a living leader of its team: a bot or a person, the nearest with room (a loner never does)", c_has_leader, NULL, NULL, NULL },
	{ VK_C, "leader_near", 1, { NOPT("voxels", 12.0f) }, "its leader is within that (default 12)", c_leader_near, NULL, NULL, NULL },
	{ VK_C, "leader_fighting", NOARGS, "its leader has a man in his sights, is firing, or was hurt in the last 3 s", c_leader_fighting, NULL, NULL, NULL },
	{ VK_S, "is_leader", NOARGS, "1 for a leader, else 0: for a tree to lean a leader toward going somewhere", NULL, s_is_leader, NULL, NULL },
	{ VK_S, "has_leader", NOARGS, "1 while it follows a living leader, else 0", NULL, s_has_leader, NULL, NULL },
	{ VK_S, "quiet", 1, { NOPT("secs", 20.0f) }, "1 once it has had no enemy in sight for that many seconds of this life (default 20), else 0", NULL, s_quiet, NULL, NULL },
	{ VK_S, "unwatched", 2, { PLACE_OPT("own_intel"), NOPT("radius", 20.0f) }, "how short of team-mates a place is (default own_intel, within 20): 1 with none there, 0.5 with one, 0 with two or more; 0 with no such place", NULL, s_unwatched, NULL, NULL },
	{ VK_C, "watched", 3, { PLACE_OPT("own_intel"), NOPT("radius", 20.0f), NOPT("count", 2.0f) }, "that many team-mates (default 2), not counting itself, are on guard (the action `guard`) within radius (default 20) of the place (default own_intel)", c_watched, NULL, NULL, NULL },
	{ VK_S, "unguarded", 4, { PLACE_OPT("own_intel"), NOPT("radius", 20.0f), NOPT("count", 2.0f), ONE_NOTE("only", "dropped", "whatever its state, but for one somebody carries") }, "1 while fewer than count team-mates (default 2) are on guard within radius (default 20) of the place (default own_intel), else 0; 0 for an intel somebody carries; with the word `dropped`, only while that intel lies where a carrier fell", NULL, s_unguarded, NULL, NULL },
	{ VK_A, "fight", NOARGS, "fight the enemy it has chosen (nearest in sight, kept until another is at half his distance): close to its own range, strafe, burst, reload, spade when it comes to that. RUNNING while he lives; SUCCESS on his death; FAILURE with nobody", NULL, NULL, bc_do_fight, bc_do_stop },
	{ VK_A, "go_to", 2, { PLACE, NOPT("radius", 2.0f) }, "walk to a place (jumping, digging, bridging as the mode allows), shooting what it meets on the way. SUCCESS there, FAILURE with no such place or no way", NULL, NULL, bc_do_go_to, bc_do_stop },
	{ VK_A, "retreat", 1, { NOPT("secs", 10.0f) }, "run to the nearest place the enemy cannot see, back turned. SUCCESS hidden (or after secs, default 10), FAILURE with nothing to run from", NULL, NULL, bc_do_retreat, bc_do_stop },
	{ VK_A, "investigate", NOARGS, "go to the place most worth searching, look round it, then forget it. SUCCESS looked, FAILURE none or no way", NULL, NULL, bc_do_investigate, bc_do_stop },
	{ VK_A, "roam", NOARGS, "walk to somewhere the team has not been lately: round where the enemy was last met, else between the two bases, else anywhere -- not round its own base. Always RUNNING: what a bot does in a world with nothing to seek", NULL, NULL, bc_do_roam, bc_do_stop },
	{ VK_A, "follow", 1, { ONE_OPT("who", "mate|caller|order|leader", "mate") }, "keep a station 3 voxels from a player: the nearest team-mate who is going somewhere (default), the caller of the ping it answers, or the order's man. `leader`: fall in with its leader -- beside and behind him, never in front of his gun; where he is going, not at his heels; shooting what he shoots; stopping near him when he stops. RUNNING; FAILURE with nobody, or a man who stays put too long", NULL, NULL, bc_do_follow, bc_do_stop },
	{ VK_A, "hold", 2, { PLACE_OPT("self"), NOPT("secs", 8.0f) }, "go to the place (default: here) and watch from it, sweeping the head, crouched if careful. SUCCESS after secs (default 8)", NULL, NULL, bc_do_hold, bc_do_stop },
	{ VK_A, "throw_grenade", 1, { PLACE_NOTE("what is worth one: a group, a far man, a place just lost") }, "throw at the place, or at what is worth one: stands, turns to the arc, lets go. SUCCESS thrown, FAILURE no arc, too near, none left", NULL, NULL, bc_do_throw, bc_do_stop },
	{ VK_A, "evade", NOARGS, "run from the grenade that threatens it. RUNNING until it has burst", NULL, NULL, bc_do_evade, bc_do_stop },
	{ VK_A, "ping", 2, { PLACE, TEXT_REP("label") }, "ping the place for the team with one of the mode's labels (\"Enemy\", \"Need help\", \"Sniper\"). SUCCESS sent; FAILURE when the team has such a ping there, it pinged lately, or it is not one to say (teamwork)", NULL, NULL, bc_do_ping, NULL },
	{ VK_A, "use", 3, { TEXT("item"), PLACE_OPT("self"), NNOTE("guide_secs", "the item's own guide time (the setting item.<name>.guide), else none") }, "use an inventory item, on itself or aimed at a point (the server's \"inv <item> [x y z]\"). With `enemy` and a guide time the head stays on that man for it. SUCCESS asked; FAILURE none held, just used, nothing to aim at", NULL, NULL, bc_do_use, NULL },
	{ VK_A, "lamp", 1, { ONE("mode", "on|off|auto") }, "flashlight: lit, out (as a bot starts), or auto (lit by night). Never lit by day. SUCCESS at once", NULL, NULL, bc_do_lamp, NULL },
	{ VK_A, "obey", NOARGS, "do what the server's order says: go, hold, hunt a player, follow one. FAILURE with no order, SUCCESS when it is done", NULL, NULL, bc_do_obey, bc_do_stop },
	{ VK_A, "look_around", NOARGS, "stand and look left, right and behind. SUCCESS after three looks", NULL, NULL, bc_do_look_around, bc_do_stop },
	{ VK_C, "fact", 2, { TEXT("name"), { "min", BT_ARG_NUMBER, 0, 0, 0, 0, 0, NULL, NULL, 0.0f, 0.0f, 0.0f, NULL, "any value above 0" } }, "a fact a server script set (botlink_set(\"fact.<name>\", number), for every bot or for this one) is at least min; with no min, is above 0. False for a fact nobody set", c_fact, NULL, NULL, NULL },
	{ VK_S, "fact", 1, { TEXT("name") }, "the value of a fact a server script set, kept within 0 to 1; 0 for one nobody set", NULL, s_fact, NULL, NULL },
	{ VK_A, "tell", 2, { TEXT("name"), { "word", BT_ARG_TEXT, 0, 1, 0, 0, 0, NULL, NULL, 0.0f, 0.0f, 0.0f, NULL, "nothing more" } }, "tell the server's scripts a word of the tree's own, with up to three more: whoever listens for that name (botlink_on) is called with this bot and the words. SUCCESS at once, heard or not. The same name from the same bot goes at most once in 0.2 s: put it under a cooldown, or where it is reached once", NULL, NULL, bc_do_tell, NULL },
	{ VK_A, "build_at", 1, { PLACE }, "stand on the floor under the place -- that very voxel, not the nearest floor there is -- BUILDING it if it is not there, and the way to it: up a stair and one step more, a bridge -- only what a player could build from where it stands (a face it sees) (the setting edit must allow building). For a structure a script lays out, a block at a time (`@<name>`). SUCCESS standing there; FAILURE no such place, building not allowed, no way", NULL, NULL, bc_do_build_at, bc_do_build_stop },
	{ VK_A, "build_perch", 1, { PLACE_OPT("enemy_base") }, "a bot up where it cannot get down makes its height a vantage: a LEVEL walkway from where it stands toward the place (default enemy_base), along the axis nearest the way to it, a block a step as a player bridges, until it sees the place within its gun's reach, its blocks run out (nothing is restocked up there), or something or the map's edge is in the way. SUCCESS there (then `camp`); FAILURE building not allowed, no block in hand, no such place, no way", NULL, NULL, bc_do_build_perch, bc_do_build_stop },
	{ VK_A, "dig_at", 1, { PLACE }, "take away the block at the place (a script names a block: x y z): near enough to reach it, spade out, the head on it, dug at its cadence (the setting edit must allow digging). SUCCESS gone (or was); FAILURE no such place, digging not allowed, no way near, 15 s and still there", NULL, NULL, bc_do_dig_at, bc_do_build_stop },
	{ VK_A, "build_cover", NOARGS, "shot at with no cover in view: a wall two high put up where it stands, in the column beside it toward the man who shot it -- the middle, then a column either side while it has the blocks (one to three wide): enough to hide it crouched. Each block as a player puts it, from where it stands (the setting edit must allow building; not where a zone forbids it). SUCCESS the middle stands; FAILURE nobody shot at it, fewer than 2 blocks, building not allowed, or the middle cannot be put there", NULL, NULL, bc_do_build_cover, bc_do_build_stop },
	{ VK_A, "put_at", 1, { PLACE }, "put a block at the voxel at the place (a script names a block: x y z) as a player places one: against a solid neighbour's face it sees, within reach, standing on the nearest floor round it from which that is so -- for a block that is not a floor to stand on (a pillar under a stair, a second row beside one; build_at makes floors). The setting edit must allow building. SUCCESS there (or was); FAILURE no such place, building not allowed, no block in hand, nowhere to place it from, no way there, 15 s", NULL, NULL, bc_do_put_at, bc_do_build_stop },
	{ VK_A, "dig_weakest", 3, { PLACE, NNOTE("voxels", "6: what is dug standing about the place -- the server's reach of 5, and a step"), TEXT_OPT("item", "none: its grenades, else the spade") }, "break a structure where it falls most: of the blocks within that of the place it could cut (a face open to the air -- in its sight, with a grenade or the item in hand; else one a floor in reach digs), the one whose removal drops the most of what stands on it -- the server's own collapse, run on the bot's map; with no such block (two wide, propped) a cut a block wide, it and one beside it. Chosen when it starts. Cut by the cheapest it has: the item named (a rocket...: `inv <item> x y z`), a grenade landing on it (the server's 3x3x3), from where it stands and clear of the blast; else the spade, as dig_at digs (the setting edit must allow digging). SUCCESS the cut made; FAILURE nothing there falls, digging not allowed, no way near, 15 s", NULL, NULL, bc_do_dig_weakest, bc_do_build_stop },
	{ VK_A, "reload", NOARGS, "reload now if the magazine is not full. SUCCESS asked, FAILURE nothing to do", NULL, NULL, bc_do_reload, NULL },
};

enum { NWORDS = (int)(sizeof WORDS / sizeof WORDS[0]) };

int bc_vocab_count(void)
{
	return NWORDS;
}

int bc_vocab_word(int i, bc_word *out)
{
	const word *w;

	if (i < 0 || i >= NWORDS || !out)
		return 0;
	w = &WORDS[i];
	out->kind = w->kind;
	out->name = w->name;
	out->doc = w->doc;
	out->n_args = w->n_args;
	out->args = w->args;
	return 1;
}

size_t bc_vocab_usage(int i, char *out, size_t out_size)
{
	const word *w;
	size_t n = 0;
	int k;

	if (out && out_size)
		out[0] = 0;
	if (i < 0 || i >= NWORDS)
		return 0;
	w = &WORDS[i];
	for (k = 0; k < w->n_args; k++) {
		const bt_arg_spec *a = &w->args[k];
		int r = snprintf(out && n < out_size ? out + n : NULL, out && n < out_size ? out_size - n : 0,
		                 "%s%c%s%c%s", k ? " " : "", a->required ? '<' : '[',
		                 a->type == BT_ARG_ONE_OF && a->values ? a->values : a->name,
		                 a->required ? '>' : ']', a->repeat ? "..." : "");

		if (r > 0) n += (size_t)r;
	}
	return n;
}

int bc_vocab_register(bt_vocab *v)
{
	char places[512];
	size_t n = 0;
	int i, ok = 1;

	for (i = 0; i < NWORDS; i++) {
		const word *w = &WORDS[i];

		if (w->kind == VK_C) ok &= bt_vocab_cond(v, w->name, w->cond);
		else if (w->kind == VK_S) ok &= bt_vocab_score(v, w->name, w->score);
		else ok &= bt_vocab_action(v, w->name, w->action, w->stop);
		ok &= bt_vocab_args(v, w->kind, w->name, w->args, w->n_args);
	}
	for (i = 0; i < BC_T_COUNT; i++)
		ok &= bt_vocab_trait(v, bc_trait_name(i), i);
	/* the places, and the other names each answers to, as one list */
	places[0] = 0;
	for (i = 0; i < bc_place_count(); i++) {
		const char *name, *alias;

		bc_place_at(i, &name, &alias, NULL);
		n += (size_t)snprintf(places + n, n < sizeof places ? sizeof places - n : 0, "%s%s%s%s", n ? "|" : "", name,
		                      alias ? "|" : "", alias ? alias : "");
	}
	/* and any place a server script names: `@name` (engine.c, THE BRIDGE).
	 * The sign is what lets a place nobody has declared compile, while a
	 * built-in place misspelt is still a mistake */
	n += (size_t)snprintf(places + n, n < sizeof places ? sizeof places - n : 0, "|@*");
	ok &= n < sizeof places && bt_vocab_set(v, "place", places);
	return ok;
}

size_t bc_vocab_dump(char *out, size_t out_size)
{
	static const char *const kind[3] = { "cond", "score", "action" };
	size_t n = 0;
	int i;

	if (out && out_size)
		out[0] = 0;
	for (i = 0; i < NWORDS; i++) {
		const word *w = &WORDS[i];
		char usage[128];
		int k;

		bc_vocab_usage(i, usage, sizeof usage);
		k = snprintf(out && n < out_size ? out + n : NULL, out && n < out_size ? out_size - n : 0,
		             "%s %s%s%s -- %s\n", kind[w->kind], w->name, usage[0] ? " " : "", usage, w->doc);
		if (k > 0) n += (size_t)k;
	}
	return n;
}
