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

static int in_cover(const bc_bot *b)
{
	int t = b->fight.target >= 0 ? b->fight.target : b->senses.lost.valid ? b->senses.lost.by : -1;

	return t >= 0 && !b->senses.k[t].visible && b->e->now - b->senses.k[t].seen_at < 5.0;
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

static int hurt_ally(const bc_bot *b, float radius)
{
	const bl_player *me = bc_me(b);
	int i;

	for (i = 0; i < BL_MAX_PLAYERS; i++) {
		const bl_player *p = &b->e->w.players[i];
		float dx = p->pos.x - me->pos.x, dy = p->pos.y - me->pos.y;

		if (i != b->pid && p->state == BL_ALIVE && p->team == me->team && p->hp < 50 &&
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
	return in_cover(b);
}

static int c_outnumbered(void *bot, const bt_args *a)
{
	bc_bot *b = bot;

	(void)a; (void)b;
	return b->senses.n_visible > 1 + bc_mates_within(b, bc_me(b)->pos, 20.0f);
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
	return hurt_ally(b, arg(a, 0, 10.0f));
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
	return b->e->now - b->senses.spotted_new_at < 2.0;
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
	return b->e->now - b->senses.hurt_at < 3.0 && b->senses.threat.valid && b->e->now - b->senses.threat.at < 3.0 && b->senses.threat_dist > 50.0f;
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

	(void)a; return b->senses.n_visible > 0 ? 1.0f : 0.0f;
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

	(void)a; return clamp01(0.34f * (float)(b->senses.n_visible - 1 - bc_mates_within(b, bc_me(b)->pos, 20.0f)));
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

enum { VK_C, VK_S, VK_A };

typedef struct word {
	int kind;
	const char *name, *args, *doc;
	bt_cond_fn cond;
	bt_score_fn score;
	bt_action_fn action;
	bt_stop_fn stop;
} word;

static const word WORDS[] = {
	{ VK_C, "enemy_visible", "", "an enemy is in this bot's sight now", c_enemy_visible, NULL, NULL, NULL },
	{ VK_C, "enemy_known", "", "an enemy is in sight, remembered, or told of by the team", c_enemy_known, NULL, NULL, NULL },
	{ VK_C, "enemy_within", "<voxels>", "the nearest enemy in sight is nearer than that", c_enemy_within, NULL, NULL, NULL },
	{ VK_C, "enemy_beyond", "<voxels>", "an enemy is in sight and the nearest is farther than that", c_enemy_beyond, NULL, NULL, NULL },
	{ VK_C, "enemies_grouped", "<count> <radius>", "that many known enemies stand within radius of one another", c_enemies_grouped, NULL, NULL, NULL },
	{ VK_C, "target_in_cover", "", "the man being fought was seen under 5 s ago and is out of sight now", c_target_in_cover, NULL, NULL, NULL },
	{ VK_C, "outnumbered", "", "more enemies in sight than team-mates within 20, itself included", c_outnumbered, NULL, NULL, NULL },
	{ VK_C, "health_below", "<hp>", "its health is under that (of 100)", c_health_below, NULL, NULL, NULL },
	{ VK_C, "hurt_recently", "[secs]", "it lost health within that many seconds (default 3)", c_hurt_recently, NULL, NULL, NULL },
	{ VK_C, "ammo_below", "<fraction>", "rounds left, magazine and reserve, are under that fraction of a full load", c_ammo_below, NULL, NULL, NULL },
	{ VK_C, "ammo_out", "", "no round left at all", c_ammo_out, NULL, NULL, NULL },
	{ VK_C, "has_grenade", "", "it carries a grenade", c_has_grenade, NULL, NULL, NULL },
	{ VK_C, "grenade_worth", "", "it has a grenade, is not just done throwing, and something is worth one (a group, a far man, a place just lost)", c_grenade_worth, NULL, NULL, NULL },
	{ VK_C, "grenade_near", "", "an enemy grenade it has noticed would hurt it where it stands", c_grenade_near, NULL, NULL, NULL },
	{ VK_C, "heard_noise", "", "a noise it heard is still worth going to", c_heard_noise, NULL, NULL, NULL },
	{ VK_C, "lost_enemy", "", "somebody left its sight and the place is still fresh", c_lost_enemy, NULL, NULL, NULL },
	{ VK_C, "has_search", "", "there is a place worth searching: a lost man, a hit's source, a noise, a told sighting", c_has_search, NULL, NULL, NULL },
	{ VK_C, "alert", "<calm|suspicious|engaged>", "its alertness is that", c_alert, NULL, NULL, NULL },
	{ VK_C, "ping_called", "[enemy|help|go]", "a team-mate's ping was given to this bot to answer (of that kind, if said)", c_ping_called, NULL, NULL, NULL },
	{ VK_C, "has_order", "", "the server gave it an order that stands", c_has_order, NULL, NULL, NULL },
	{ VK_C, "is_night", "", "it is night", c_is_night, NULL, NULL, NULL },
	{ VK_C, "has_night_vision", "", "it sees by night as by day (the setting night_vision)", c_has_night_vision, NULL, NULL, NULL },
	{ VK_S, "night_vision", "", "1 by night for a bot that has night vision", NULL, s_night_vision, NULL, NULL },
	{ VK_S, "hit_in_dark", "", "1 by night for a bot with no night vision that was hit in the last 8 s", NULL, s_hit_in_dark, NULL, NULL },
	{ VK_C, "lamp_on", "", "its flashlight is lit", c_lamp_on, NULL, NULL, NULL },
	{ VK_C, "has_item", "<name>", "it holds at least one of that inventory item", c_has_item, NULL, NULL, NULL },
	{ VK_C, "sky_clear", "", "nothing solid above its head (a thing that comes down from the sky needs it)", c_sky_clear, NULL, NULL, NULL },
	{ VK_C, "allies_hurt_near", "<radius>", "a team-mate under 50 health is within radius", c_allies_hurt_near, NULL, NULL, NULL },
	{ VK_C, "mate_within", "<voxels>", "a live team-mate is that near", c_mate_within, NULL, NULL, NULL },
	{ VK_C, "alone", "[voxels]", "no live team-mate within that (default 25)", c_alone, NULL, NULL, NULL },
	{ VK_C, "spotted_new", "", "it has just seen an enemy its team did not know of", c_spotted_new, NULL, NULL, NULL },
	{ VK_C, "losing", "", "it is in a fight, under 45 health and outnumbered, or under 30 and just hit", c_losing, NULL, NULL, NULL },
	{ VK_C, "sniped", "", "it was hit within 3 s from more than 50 voxels away", c_sniped, NULL, NULL, NULL },
	{ VK_C, "setting", "<key> [value]", "the gamemode's setting <key> is set (to <value>, if said): how a mode's tree reads the mode's own rules", c_setting, NULL, NULL, NULL },
	{ VK_C, "chance", "<0..1>", "true that often, by the bot's own dice", c_chance, NULL, NULL, NULL },
	{ VK_C, "knows", "<place>", "the bot knows of such a place now (see the places below)", c_knows, NULL, NULL, NULL },
	{ VK_C, "at", "<place> [voxels]", "it is within that of the place (default 4)", c_at, NULL, NULL, NULL },
	{ VK_S, "always", "", "1", NULL, s_always, NULL, NULL },
	{ VK_S, "enemy_visible", "", "1 with an enemy in sight, else 0", NULL, s_enemy_visible, NULL, NULL },
	{ VK_S, "enemy_known", "", "how sure it is of an enemy it cannot see: 1 fresh, fading to 0; 0 with one in sight", NULL, s_enemy_known, NULL, NULL },
	{ VK_S, "enemy_near", "[voxels]", "1 with an enemy in sight at arm's length, falling to 0 at that distance (default 60)", NULL, s_enemy_near, NULL, NULL },
	{ VK_S, "hurt", "", "health lost: 0 unhurt, 1 nearly dead", NULL, s_hurt, NULL, NULL },
	{ VK_S, "hurt_in_fight", "", "health lost, counted only with an enemy in sight or a hit from somewhere in the last 3 s; 0 for 6 s after a retreat", NULL, s_hurt_in_fight, NULL, NULL },
	{ VK_S, "healthy", "", "health left, 0 to 1", NULL, s_healthy, NULL, NULL },
	{ VK_S, "search", "", "how fresh the place most worth searching is: 1 just now, 0 none", NULL, s_search, NULL, NULL },
	{ VK_S, "ping_called", "", "1 while a team-mate's ping is this bot's to answer", NULL, s_ping_called, NULL, NULL },
	{ VK_S, "has_order", "", "1 while an order stands", NULL, s_has_order, NULL, NULL },
	{ VK_S, "alone", "[voxels]", "0 beside a team-mate, rising to 1 at that distance (default 40) or with none alive", NULL, s_alone, NULL, NULL },
	{ VK_S, "grenade_worth", "", "1 when a grenade is worth throwing now (see the condition)", NULL, s_grenade_worth, NULL, NULL },
	{ VK_S, "grenade_near", "", "1 when an enemy grenade would hurt it here", NULL, s_grenade_near, NULL, NULL },
	{ VK_S, "outnumbered", "", "0 when not; else how badly, up to 1", NULL, s_outnumbered, NULL, NULL },
	{ VK_S, "night", "", "1 by night", NULL, s_night, NULL, NULL },
	{ VK_S, "calm", "", "1 when nothing is known, 0.3 when suspicious, 0 engaged", NULL, s_calm, NULL, NULL },
	{ VK_S, "has_item", "<name>", "1 if it holds one", NULL, s_has_item, NULL, NULL },
	{ VK_S, "ammo_low", "", "0 with a full load, 1 with none", NULL, s_ammo_low, NULL, NULL },
	{ VK_A, "fight", "", "fight the enemy it has chosen (nearest in sight, kept until another is at half his distance): close to its own range, strafe, burst, reload, spade when it comes to that. RUNNING while he lives; SUCCESS on his death; FAILURE with nobody", NULL, NULL, bc_do_fight, bc_do_stop },
	{ VK_A, "go_to", "<place> [radius]", "walk to a place (jumping, digging, bridging as the mode allows), shooting what it meets on the way. SUCCESS there, FAILURE with no such place or no way", NULL, NULL, bc_do_go_to, bc_do_stop },
	{ VK_A, "retreat", "", "run to the nearest place the enemy cannot see, back turned. SUCCESS hidden (or after 10 s), FAILURE with nothing to run from", NULL, NULL, bc_do_retreat, bc_do_stop },
	{ VK_A, "investigate", "", "go to the place most worth searching, look round it, then forget it. SUCCESS looked, FAILURE none or no way", NULL, NULL, bc_do_investigate, bc_do_stop },
	{ VK_A, "roam", "", "walk to where the enemy was last met, else his base, else anywhere. Always RUNNING: this is what a bot does rather than stand", NULL, NULL, bc_do_roam, bc_do_stop },
	{ VK_A, "follow", "[mate|caller|order]", "keep a station 3 voxels from a player: the nearest team-mate (default), the caller of the ping it answers, or the order's man. RUNNING; FAILURE with nobody", NULL, NULL, bc_do_follow, bc_do_stop },
	{ VK_A, "hold", "[place] [secs]", "go to the place (default: here) and watch from it, sweeping the head, crouched if careful. SUCCESS after secs (default 8)", NULL, NULL, bc_do_hold, bc_do_stop },
	{ VK_A, "throw_grenade", "[place]", "throw at the place, or at what is worth one: stands, turns to the arc, lets go. SUCCESS thrown, FAILURE no arc, too near, none left", NULL, NULL, bc_do_throw, bc_do_stop },
	{ VK_A, "evade", "", "run from the grenade that threatens it. RUNNING until it has burst", NULL, NULL, bc_do_evade, bc_do_stop },
	{ VK_A, "ping", "<place> <label...>", "ping the place for the team with one of the mode's labels (\"Enemy\", \"Need help\", \"Sniper\"). SUCCESS sent; FAILURE when the team has such a ping there, it pinged lately, or it is not one to say (teamwork)", NULL, NULL, bc_do_ping, NULL },
	{ VK_A, "use", "<item> [self|enemy|group|<place>] [guide secs]", "use an inventory item, on itself or aimed at a point (the server's \"inv <item> [x y z]\"). With `enemy` and a guide time the head stays on that man for it. SUCCESS asked; FAILURE none held, just used, nothing to aim at", NULL, NULL, bc_do_use, NULL },
	{ VK_A, "lamp", "<on|off|auto>", "flashlight: lit, out (as a bot starts), or auto (lit by night). Never lit by day. SUCCESS at once", NULL, NULL, bc_do_lamp, NULL },
	{ VK_A, "obey", "", "do what the server's order says: go, hold, hunt a player, follow one. FAILURE with no order, SUCCESS when it is done", NULL, NULL, bc_do_obey, bc_do_stop },
	{ VK_A, "look_around", "", "stand and look left, right and behind. SUCCESS after three looks", NULL, NULL, bc_do_look_around, bc_do_stop },
	{ VK_A, "reload", "", "reload now if the magazine is not full. SUCCESS asked, FAILURE nothing to do", NULL, NULL, bc_do_reload, NULL },
};

enum { NWORDS = (int)(sizeof WORDS / sizeof WORDS[0]) };

int bc_vocab_count(void)
{
	return NWORDS;
}

int bc_vocab_register(bt_vocab *v)
{
	int i, ok = 1;

	for (i = 0; i < NWORDS; i++) {
		const word *w = &WORDS[i];

		if (w->kind == VK_C) ok &= bt_vocab_cond(v, w->name, w->cond);
		else if (w->kind == VK_S) ok &= bt_vocab_score(v, w->name, w->score);
		else ok &= bt_vocab_action(v, w->name, w->action, w->stop);
	}
	for (i = 0; i < BC_T_COUNT; i++)
		ok &= bt_vocab_trait(v, bc_trait_name(i), i);
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
		int k = snprintf(out && n < out_size ? out + n : NULL, out && n < out_size ? out_size - n : 0,
		                 "%s %s%s%s -- %s\n", kind[w->kind], w->name, w->args[0] ? " " : "",
		                 w->args, w->doc);

		if (k > 0) n += (size_t)k;
	}
	return n;
}
