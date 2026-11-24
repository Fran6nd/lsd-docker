/* brain.h -- The inside of the engine: one bot, and what all share
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * PRIVATE to engine.c, skill_*.c and vocab.c (and to the tests that look
 * inside). The host sees engine.h only.
 *
 * A bot's think, each time the server has written a new world:
 *
 *   DECIDE  about 20 times a second, staggered so the bots do not all
 *           decide on the same think: the senses look, a target is
 *           chosen, the tree is ticked. Its actions leave WISHES
 *           (bc_wish): where to go, what to look at, whom to shoot.
 *           A JOLT -- an enemy come into sight, a hit from nowhere, an
 *           order, a ping to answer, a grenade at the feet -- has the
 *           tree entered afresh (bt_reset), so its picks choose NOW and
 *           not when their `every` next comes round: a bot that kept
 *           strolling a second and a half after seeing a man read as
 *           blind. A skill asked for again goes on with its route.
 *   PLAN    the routes asked for are searched within the think's budget
 *           of expansions, the bot that has waited longest first.
 *   ACT     every think: the follower turns the route into keys, the
 *           aim model moves the head, the trigger is weighed, and the
 *           intent is written.
 *
 * A world the engine has already seen (the server writes 30 a second,
 * the host may think 60 times) only repeats the last intent: nothing
 * new is known, and the follower counts its ticks in worlds.
 */
#ifndef BC_BRAIN_H
#define BC_BRAIN_H

#include "aim.h"
#include "body.h"
#include "bt.h"
#include "cull.h"
#include "engine.h"
#include "map.h"
#include "nav.h"
#include "persona.h"
#include "rng.h"
#include "senses.h"
#include "skills.h"

enum {
	BC_ITEMS_MAX = 8,
	BC_SETTINGS_MAX = 64,
	BC_ITEMDEFS_MAX = 24,       /* items and extras together */
	BC_ZONES_MAX = 32,
	BC_GRENADES_MAX = 16,
	BC_DANGER_MAX = 4,
	BC_SEARCH_MAX = 4,
	BC_CHANGE_CELLS = 2048,
	BC_UNREACH_MAX = 16,        /* a team's memory of goals with no way to them */
	BC_PERCH_MAX = 16,          /* a team's vantage points on this map */
	BC_COVER_R = 14,            /* the cover search's reach, columns */
	BC_COVER_W = 2 * BC_COVER_R + 1,
	BC_COVER_QUEUE = 660,
	BC_VISIT_N = 32,            /* the visit grid: 32 x 32 cells of 16 columns */
	BC_AVOID_MAX = 3,           /* enemies a carrier's route keeps away from */
	BC_LEADERS_MAX = 8          /* a team's leaders */
};

enum { BC_COVER_HIDE = 0, BC_COVER_ADVANCE, BC_COVER_BACK };

enum { BC_MOVE_NONE = 0, BC_MOVE_GOTO, BC_MOVE_FREE };
enum { BC_LOOK_AHEAD = 0, BC_LOOK_POINT, BC_LOOK_TARGET };
enum { BC_MV_IDLE = 0, BC_MV_PLANNING, BC_MV_FOLLOWING, BC_MV_ARRIVED, BC_MV_FAILED };
enum { BC_LAMP_AUTO = 0, BC_LAMP_ON, BC_LAMP_OFF };

/* What the last decision wants of the body until the next one. */
typedef struct bc_wish {
	uint8_t move;           /* BC_MOVE_* */
	uint8_t look;           /* BC_LOOK_* */
	uint8_t tool;           /* bl_tool to hold */
	uint8_t crouch, sneak, jump, sprint;
	uint8_t pad_;
	int16_t fire_pid;       /* shoot him when the head is on him; -1 */
	int16_t look_pid;
	bl_vec3 goal;           /* GOTO */
	float radius;
	float mx, my;           /* FREE: a world direction, or 0 0 to stand */
	bl_vec3 look_at;        /* POINT */
} bc_wish;

/* Getting somewhere: one goal, one route, one follower. */
typedef struct bc_mover {
	uint8_t state;          /* BC_MV_* */
	uint8_t has_route;      /* `route` can be followed */
	uint8_t partial_tries;
	uint8_t restarts;
	int8_t search;          /* the engine's search it holds, or -1 */
	uint8_t refusals;
	uint8_t braking;        /* plan from a standstill next time */
	uint8_t goal_set;
	uint8_t again;          /* the route awaited is another to the same goal */
	uint8_t gave_n;
	bc_nav_node gave[4];    /* goals the follower gave up on, lately */
	double gave_until[4];
	bc_nav_node goal;
	bc_nav_node plan_from;  /* where the plan in hand started */
	bc_nav_node first_from; /* where the first plan for this goal started */
	float partial_d;        /* how far from the goal the last partial route ended */
	uint8_t nocap;          /* this goal's next search runs to its end */
	uint8_t noway;          /* searches in a row that found no way to anywhere */
	double noway_at;        /* the last of them */
	double shut_until;      /* SHUT IN: no route is asked for before (skill_move.c) */
	int16_t radius;
	double plan_since;      /* when it began to wait for a route */
	double retry_at;        /* a failed goal is not searched again before */
	double edit_at;         /* the next edit may be asked for at */
	double noedit_until;    /* twice refused: no digging or building until */
	double tool_grace;      /* keep the spade or the blocks out until */
	uint32_t plan_rev;
	uint32_t expansions;    /* of the plan in progress */
	int32_t last_status;    /* bc_nav_follow_status */
	uint8_t edit_tool;      /* the tool the edit in hand needs */
	uint8_t pad_[3];
	bc_nav_cmd cmd;
	bc_nav_policy pol;
	bc_nav_danger danger[BC_DANGER_MAX + 1 + BC_AVOID_MAX];    /* the team's, a flank's, the men a carrier avoids */
	bc_nav_follow follow;
	bc_nav_route route;
} bc_mover;

typedef struct bc_fight {
	int target;             /* pid or -1 */
	double target_since, kill_at;
	float engage_frac;
	uint8_t melee, engaged, strafing, pad_;
	double burst_until, gap_until, ff_until, fire_block_until;
	int strafe_dir;
	float orbit_bias;
	double strafe_until, crouch_until, crouch_cd_until, jump_cd_until;
	double reload_since, reloading_until;
	double chase_at;
	double sprint_was;
} bc_fight;

/* The head while travelling with nothing to aim at (skill_look.c). */
typedef struct bc_gaze {
	double next_at;         /* the next glance is due */
	double until;           /* the glance in hand ends; 0: none */
	bl_vec3 at;             /* what it looks at */
	uint8_t kind;           /* 1 a place worth a look, 2 an opening beside, 3 over a shoulder */
	uint8_t free;           /* the head was its own on the last act */
	uint8_t was_alert, pad_;
	uint32_t glances;
} bc_gaze;

/* One search for cover (skill_cover.c): a flood over the floor a body
 * can walk, outward from where the bot stands, a few cells a decision. */
typedef struct bc_cover_q {
	uint8_t state;          /* 0 none, 1 searching, 2 done */
	uint8_t found, crouch, mode;
	uint8_t best_d, has_toward;
	int16_t radius;
	bl_vec3 threat, toward, me;
	float me_td, me_dd;     /* the bot's distance to the threat, to `toward` */
	bc_nav_node origin;
	uint16_t head, tail;
	float best_score;
	bl_vec3 best;           /* the eye of a body standing in the cell found */
	double at;              /* when it was done */
	uint32_t cells;         /* examined, for the numbers */
	uint8_t q[BC_COVER_QUEUE][4];       /* dx + R, dy + R, z, steps */
	uint64_t seen[(BC_COVER_W * BC_COVER_W + 63) / 64];
} bc_cover_q;

/* What a bot holds of one item: the server says (item.<name>=<count>). */
typedef struct bc_item {
	char name[16];
	int32_t count;          /* -1: without end ("inf") */
	double cd_until;        /* not asked for again before */
} bc_item;

/* An item's own decision, brought by whoever defined the item
 * (item.<name>.tree=<text>), or a script's addition for every bot
 * (extra.<name>.tree=<text>): see engine.c, THE ITEMS TREE, THE EXTRAS. */
typedef struct bc_itemdef {
	char name[16];
	char *tree;             /* its fragment, or NULL */
	float guide;            /* item.<name>.guide: seconds the aim is kept */
	uint8_t ok;
	uint8_t extra;          /* an extra.<name>.tree, not an item's */
	uint8_t said;           /* that it does not compile: once a text */
	uint8_t pad_;
} bc_itemdef;

typedef struct bc_order {
	uint8_t order, target, pad_[2];
	bl_vec3 pos;
	double until;           /* < 0: until the next */
} bc_order;

struct bc_engine;

typedef struct bc_bot {
	struct bc_engine *e;
	uint8_t used, pid, level, gun;
	uint32_t seed;
	uint32_t life;
	uint8_t alive, was_alive, hit, hit_from_valid;
	bl_vec3 hit_from;
	bc_rng rng;
	bc_persona persona;

	/* the tree */
	const bt_forest *forest;
	int tree, tree_also;
	bt_state *bt;
	size_t bt_size;
	char tree_name[BT_NAME_MAX];    /* this bot's own, or "" */
	bt_forest *own;         /* this bot's own tree TEXT, compiled (tree=<text> for one bot), or NULL */
	char *own_text;
	float trait_mul[BC_T_COUNT];    /* traits= for this bot: a factor a trait (0: none said) */

	/* per-bot style, drawn at each life's start from its own stream */
	float style_dodge, style_engage, style_crouch, station_bearing, sweep_phase;
	int flank_side;

	double decide_acc;      /* seconds since its last decision */
	float decide_dt;

	bc_senses senses;
	bc_aim aim;
	bc_aim_out aim_out;
	bc_wish wish;
	bc_mover mv;
	bc_fight fight;

	/* what the skills remember */
	struct { uint8_t phase, what, looks; double until; bl_vec3 place; float base_yaw; } inv;
	struct { uint8_t valid; bl_vec3 goal; double until; } roam;
	struct { uint8_t valid; bl_vec3 goal; double until, since; } cover;
	struct { int leader; double pick_at, still_since, cd_until; } follow;
	struct { uint8_t started; double until; bl_vec3 place; } hold;
	struct { double until; int pid; bl_vec3 at; } guide;   /* an item's aim, kept */
	struct { uint8_t phase; bl_vec3 vel; float fuse; double release_at, give_up_at, cd_until; } nade;
	struct { double cd_until; uint32_t taken; bl_vec3 pos; uint8_t kind, by; double until; } ping;
	struct { double until; bl_vec3 from; } evade;
	/* looking, cover, and what a bot does with nothing known (skill_look.c,
	 * skill_cover.c, skill_tactics.c) */
	bc_gaze gaze;
	bc_cover_q cq;
	struct { uint8_t phase, crouch, tries, peeking, has_peek, pad_[3];
	         double until, peek_at, peek_until, seen_since, go_since, asked_at; bl_vec3 goal, peek; } tc;
	struct { uint8_t phase, crouch, bounds, mode; double until, since, quiet_since, asked_at; bl_vec3 goal, dest; } bd;
	struct { double until, flinched_for; } cr;
	struct { uint8_t phase, tries, n, pad_; int8_t side; double cd_until, leg_since, side_until;
	         bl_vec3 w[3]; bc_nav_danger avoid; uint8_t avoid_on; } flank;
	struct { uint8_t phase, pad_[7]; bl_vec3 place, done_pos; double done_until, cd_until; } hunt;
	struct { int8_t perch, avoid; uint8_t camping, pad_; uint32_t kills0;
	         double cd_until, since, patience_until; } camp;
	struct { uint8_t leg, fails, pad_[6]; double leg_since, roam_until; } seek;
	/* the objects of the game (skill_objective.c) */
	struct { uint8_t n, pad_[7]; bc_nav_danger avoid[BC_AVOID_MAX]; double plan_at; } carry;
	struct { uint8_t started, pad_[7]; double until; bl_vec3 spot, place; } guard;
	struct { double stand_since; } fetch;
	struct { int16_t leader; uint8_t pad_[6]; double eval_at, still_since, off_until; bl_vec3 still_at; } squad;
	uint32_t kills;         /* this life's */
	double born_at;         /* when this life began */
	uint8_t following;      /* the follow skill ran at the last decision */
	bc_order order;
	uint8_t lamp;           /* BC_LAMP_* */
	uint8_t night_vision;   /* the setting night_vision, this bot's */
	int8_t edit;            /* -1: the engine's; else bit 0 dig, bit 1 build */
	bc_item items[BC_ITEMS_MAX];
	double use_at;

	/* being stuck (engine.c, THE NET UNDER EVERYTHING): the last place it
	 * really moved from, how long it has pushed there, what is being tried */
	bl_vec3 anchor;
	double anchor_at, unstick_until;
	uint32_t stuck;         /* times the watchdog had to act */
	struct { double push, idle, until, fired_at; uint8_t run, mode, keys0, pad_[5]; bl_vec3 place; } unstick;
	struct { bl_vec3 from; double acc; } area;  /* on a route and not leaving a small place */
	struct { double until; bl_vec3 goal; float mx, my; uint8_t free, pad_[3]; } elsewhere;
	struct { double turn_at; float mx, my; } pace;      /* shut in: what it does meanwhile */
	double stuck_said_at;
	double stuck_out_at;    /* when a goal was last dropped for it */
	uint32_t stuck_outs;    /* times a goal was dropped for it */
	struct { uint8_t tries, pad_[7]; bl_vec3 goal; double until, cd_until; bl_vec3 bad[4]; } dry;

	bl_intent out;          /* the last intent written */
	uint8_t keys_prev;      /* for the keys' hysteresis */
	uint8_t jolt;           /* something happened: the tree is entered afresh */
	uint8_t was_alert, was_nade;
	uint8_t reload_pulse;
} bc_bot;

typedef struct bc_setting { char key[24]; char val[40]; } bc_setting;

typedef struct bc_nade {
	bl_vec3 burst;
	double at;              /* when it bursts */
	double born;            /* when it was thrown */
	uint8_t team, valid, pad_[6];
} bc_nade;

/* One of the two objects a team may carry off (bl_world.intel): what the
 * engine makes of what the world shows of it. */
enum { BC_OBJ_HOME = 0, BC_OBJ_CARRIED, BC_OBJ_DROPPED };
typedef struct bc_objstate {
	uint8_t state, holder, pad_[6];
	bl_vec3 pos;
	double since;
	uint16_t score;         /* the carrier's team's, when he took it */
} bc_objstate;

/* A team's leaders (skill_squad.c). */
typedef struct bc_leaders {
	uint8_t pid[BC_LEADERS_MAX], deaths[BC_LEADERS_MAX];
	int32_t n;
	double until[BC_LEADERS_MAX], died_at[BC_LEADERS_MAX];
} bc_leaders;

/* A goal a team's bot found no way to, and from about where. */
typedef struct bc_unreach {
	bc_nav_node from, to;
	double until;
	uint8_t caps, pad_[7];  /* what its routes might do then: bit 0 dig, bit 1 build */
} bc_unreach;

/* A place to shoot from: notably higher than what is round it, with a
 * long open view to where the enemy is expected, and a way up. */
typedef struct bc_perch {
	bc_nav_node n;
	float score;
	int16_t claim;          /* the pid that has it, or -1 */
	uint8_t valid, pad_;
	double claim_until, bad_until;
} bc_perch;

typedef struct bc_vantage {
	bc_perch p[BC_PERCH_MAX];
	bl_vec3 from, toward;   /* the team's side and the enemy's, when scanned */
	int16_t x0, y0, x1, y1; /* the box scanned */
	uint32_t k;             /* columns looked at so far */
	uint32_t map_seq;
	uint8_t started, done, pad_[6];
	double done_at;
} bc_vantage;

typedef struct bc_engine_stats {
	uint32_t thinks, decisions, plans, plan_fails, replans, stuck;
	uint32_t expansions;        /* in all */
	uint32_t last_expansions;   /* in the last think */
	uint32_t pings, grenades, edits, uses;
	uint32_t glances, cover_cells, covers, perch_columns, unreach_hits;
	uint32_t action_stops;      /* times a RUNNING action was told to stop (its branch was left) */
	uint32_t shut_in;           /* times a bot was found to have no way to anywhere */
	uint32_t plan_caps;         /* plans stopped at plan.cap and walked as far as they got */
	uint32_t stuck_tries;       /* the watchdog tried a jump, a step back, a sidestep */
	uint32_t stuck_resets;      /* ... and dropped the goal: the tree decided again */
} bc_engine_stats;

struct bc_engine {
	bc_engine_host host;
	int max_bots;
	bc_bot *bots;
	int16_t by_pid[BL_MAX_PLAYERS];

	bc_map *map;
	bc_cull *cull;
	int have_map;
	uint32_t map_seq;
	uint8_t cull_personality;
	uint8_t may_dig, may_build, water_lethal;
	float water_damage;         /* health a second lost wading (water.damage) */
	uint8_t gaze_off;           /* gaze=0: heads follow the steering */
	uint8_t plan_stand;         /* plan.wait=stand: a bot waits for its route standing */
	float plan_greed;           /* plan.greed: nav's h_weight for every plan (1.5) */
	int plan_cap;               /* plan.cap: expansions a plan may take before the
	                               bot sets off toward the nearest place found (8000) */
	int spend;                  /* blocks a bot may spend on a route */

	bc_nav_moves *moves;
	bc_nav_fail fail;
	bc_nav_protect protect;
	bc_nav_zone zones[BC_ZONES_MAX];
	int nzones;
	int nsearch;
	void *search_mem[BC_SEARCH_MAX];
	bc_nav_search *search[BC_SEARCH_MAX];
	int search_owner[BC_SEARCH_MAX];    /* bot index or -1 */

	bt_vocab *vocab;
	bt_forest *builtin, *custom, *fallback;

	bc_sense_cfg sense;
	bc_board board;
	bc_nav_danger danger[2][BC_DANGER_MAX];     /* where a team's men died */
	double danger_at[2][BC_DANGER_MAX];
	bl_vec3 hot[2];             /* where a team last met the other */
	double hot_at[2];
	bc_nade nades[BC_GRENADES_MAX];
	bc_objstate obj[2];         /* [team - 1]: that team's own */
	bc_leaders lead[2];
	bc_rng rng;                 /* the engine's own dice: who leads */
	double lead_at;
	int lead_per;               /* leaders.per: members a leader (5; 0: none) */
	float lead_human;           /* leaders.human: a person's weight in the draw (2) */
	uint8_t hurt_by[BL_MAX_PLAYERS];    /* who last hurt each player, and when */
	double hurt_at[BL_MAX_PLAYERS];
	bc_unreach unreach[2][BC_UNREACH_MAX];
	bc_vantage vantage[2];
	float visit[2][BC_VISIT_N * BC_VISIT_N];    /* when a team's man was last in a cell; 0: never */

	bc_itemdef idefs[BC_ITEMDEFS_MAX];
	int nidefs;
	char *base_text, *custom_text;      /* the trees as given, for recompiling */

	bc_setting settings[BC_SETTINGS_MAX];
	int nsettings;
	float trait_mul[BC_T_COUNT];        /* traits= for everybody (0: none said) */
	float archetypes[BC_A_COUNT];
	int have_archetypes;
	char tree_name[BT_NAME_MAX];
	int ping_takers;
	float ping_radius;

	double now;
	float world_dt;             /* thought time since the last new world */
	float world_dt_last;        /* and what it came to for the world in hand */
	bl_world w;                 /* the newest world, copied */
	uint32_t last_tick;
	int have_world;
	int budget_left;

	uint32_t chg_cells[BC_CHANGE_CELLS];
	bc_engine_stats stats;
};

/* --- engine.c --------------------------------------------------------- */

const bc_engine_stats *bc_engine_stats_get(const bc_engine *e);
bc_bot *bc_engine_bot(bc_engine *e, int pid);
const char *bc_engine_setting(const bc_engine *e, const char *key);
void bc_engine_log(bc_engine *e, int level, const char *fmt, ...);
/* the search a bot was lent goes back */
void bc_engine_search_release(bc_engine *e, bc_bot *b);

static inline const bl_player *bc_me(const bc_bot *b) { return &b->e->w.players[b->pid]; }
static inline float bc_frand(bc_bot *b) { return bc_rng_float(&b->rng); }

/* --- skill_move.c ------------------------------------------------------ */

void bc_mover_reset(bc_bot *b);
/* Ask to be at `pos` (within `radius` columns). Asked again with the
 * same place it only reports: BC_MV_PLANNING, FOLLOWING, ARRIVED or
 * FAILED. A new place starts a new plan; the old route is walked
 * meanwhile if it leads the same way. */
int bc_move_to(bc_bot *b, bl_vec3 pos, float radius);
void bc_move_stop(bc_bot *b);
/* PLAN: every bot waiting for a route, longest first. */
void bc_movers_plan(bc_engine *e);
/* ACT: the follower's keys and facing for this world. 1 if it drives. */
int bc_mover_act(bc_bot *b, const bc_body *body, bc_nav_cmd *cmd);
/* A world direction as keys for the facing the body has, with hysteresis. */
uint8_t bc_keys_toward(float mx, float my, bl_vec3 ori, uint8_t prev);
/* Would walking that way for a third of a second keep the feet up? */
int bc_walk_safe(const bc_bot *b, float mx, float my);
/* A place near `b` out of sight of `threat`. 0 if none. */
int bc_find_cover(bc_bot *b, bl_vec3 threat, bl_vec3 *out);
/* Somewhere worth walking to when nothing is known. */
int bc_roam_goal(bc_bot *b, bl_vec3 *out);
void bc_body_of(const bl_player *p, bc_body *body);

/* a body is wading in water that hurts */
int bc_in_harmful_water(const bc_bot *b);
/* the floor a body can walk to in column (x, y) from a floor at z: within
 * one voxel, not the sea. -1 if none. */
int bc_floor_near(const bc_map *m, int x, int y, int z);

/* --- skill_fight.c ----------------------------------------------------- */

/* DECIDE, before the tree: whom this bot is fighting (fight.target). */
void bc_fight_select(bc_bot *b);
/* ACT: bursts, the mate in the line, the trigger. Returns the mouse bits. */
uint8_t bc_fight_trigger(bc_bot *b, int on_target, float dist);
/* ACT: reload discipline. 1 on the think the reload is asked. */
int bc_reload_act(bc_bot *b);
float bc_engage_range(const bc_bot *b);
float bc_hold_range(const bc_bot *b);
/* opportunity fire for a skill that is doing something else */
void bc_fire_at_will(bc_bot *b);

/* --- skill_misc.c ------------------------------------------------------ */

/* A named place, for go_to / look / ping / use: "enemy" (nearest known),
 * "last_seen", "noise", "threat", "search" (the freshest of those),
 * "ping", "order", "mate", "caller", "enemy_group", "enemy_base",
 * "own_base", "enemy_intel", "own_intel", "cover", "hot", "self".
 * 0 when the bot knows of no such place now. */
int bc_place_of(bc_bot *b, const char *name, bl_vec3 *out);
int bc_item_count(const bc_bot *b, const char *name);
bc_item *bc_item_find(bc_bot *b, const char *name, int make);
/* the centre of the tightest group of >= n known enemies within radius */
int bc_enemy_group(bc_bot *b, int n, float radius, bl_vec3 *out);
int bc_mates_within(const bc_bot *b, bl_vec3 at, float radius);
int bc_nearest_mate(const bc_bot *b, float *dist);

/* --- skill_look.c ------------------------------------------------------ */

/* ACT, on a plain stretch of route with nothing to aim at: where the head
 * looks. 0 when the follower must keep it (see the file). */
int bc_look_travel(bc_bot *b, const bc_nav_cmd *cmd, bl_vec3 *at);

/* --- skill_cover.c ----------------------------------------------------- */

/* Search for cover from `threat` (an eye), `budget` cells examined a
 * call: 0 while it searches, 1 when done -- then b->cq.found says whether
 * there is one, b->cq.best where, b->cq.crouch whether it only hides a
 * crouched body. `toward` (or NULL) is where the bot is going: with
 * BC_COVER_ADVANCE and BC_COVER_BACK only cover that brings it nearer
 * counts. Asked again with the same things it goes on, or answers from
 * what it found under a second ago. */
int bc_cover_query(bc_bot *b, bl_vec3 threat, int mode, const bl_vec3 *toward, int radius, int budget);
/* What this bot is hiding from or would: the man it fights, where a hit
 * came from, the nearest enemy it knows of. 0 with none. */
int bc_threat_place(bc_bot *b, bl_vec3 *out);
/* Can an eye at `threat` see this bot's body as it stands? */
int bc_exposed_to(const bc_bot *b, bl_vec3 threat);

/* --- skill_tactics.c --------------------------------------------------- */

/* PLAN: the vantage scans, a few columns a think. */
void bc_tactics_think(bc_engine *e);
void bc_tactics_map(bc_engine *e);          /* a new map: forget */
void bc_tactics_bot_gone(bc_bot *b);        /* died or left: its claims go */
void bc_unreach_note(bc_bot *b, bc_nav_node from, bc_nav_node to);
double bc_unreach_until(bc_bot *b, bc_nav_node from, bc_nav_node to);
/* where the enemy is expected: where the team last met him (under a
 * minute ago), else his base. 0 with neither. */
int bc_enemy_area(bc_bot *b, bl_vec3 *out);
/* the best free perch for this bot, or -1; with `claim` it is taken */
int bc_perch_pick(bc_bot *b, int claim);
/* the freshest rumour of the enemy: a noise, a team-mate's sighting, the
 * last meeting. Returns its freshness 0..1 (0: none). */
float bc_rumour(bc_bot *b, bl_vec3 *out);
int bc_flank_open(bc_bot *b);

/* --- skill_objective.c ------------------------------------------------- */

/* A new world: what became of the two objects. A change is news to
 * everybody: every bot's tree is entered afresh. */
void bc_objective_world(bc_engine *e);
/* 0 home, 1 carried, 2 dropped, -1 none: `own` this bot's team's or the other's */
int bc_obj_state(const bc_bot *b, int own);
int bc_carrying(const bc_bot *b);
/* "thief" (who carries this team's), "carrier" (the team-mate who carries
 * the other's), "intercept" (where to cut the thief off) */
int bc_objective_place(bc_bot *b, const char *name, bl_vec3 *out);
/* ask for another route to the goal in hand, walking the old one meanwhile */
void bc_move_replan(bc_bot *b);

/* --- skill_squad.c ----------------------------------------------------- */

void bc_leaders_think(bc_engine *e);
void bc_leaders_died(bc_engine *e, int pid);
int bc_is_leader(const bc_engine *e, int pid);
/* the leader this bot follows (looked at again now and then), or -1 */
int bc_leader_of(bc_bot *b);
int bc_leader_fighting(const bc_engine *e, int leader);
/* whom its leader is fighting, if this bot sees him; else -1 */
int bc_squad_target(bc_bot *b);
bt_status bc_follow_leader(bc_bot *b);

/* --- skill_grenade.c --------------------------------------------------- */

/* the burst of the enemy grenade that threatens this bot most; damage */
float bc_grenade_threat(bc_bot *b, bl_vec3 *burst);
int bc_grenade_target(bc_bot *b, bl_vec3 *out);

#endif
