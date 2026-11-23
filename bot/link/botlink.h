/* botlink.h -- The file the server and the bot engine share
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * Bots are not clients. A bot is a player slot of the server's with no
 * connection behind it; the engine that decides what it does (botd) is
 * another process in the same container, and the two talk through one
 * memory-mapped file: no socket, no packet, no system call a tick.
 *
 *   the server (lib_botlink.lua, through libbotlink.so)      botd
 *     writes  world    every tick: who is where         ->   reads
 *     writes  events   what happened, in order          ->   reads
 *     reads   intents  each bot's keys, aim, trigger    <-   writes
 *     reads   actions  what a bot does to the world     <-   writes
 *
 * The server stays the only authority: an intent is keys held, as a
 * client's would be, and an action goes through the same checks a
 * player's does. The engine never moves a bot, hits anybody or changes
 * a block; it asks.
 *
 * ONE SOURCE. This header is compiled into both ends (botlink.c) and is
 * also what LuaJIT's ffi.cdef reads, with the preprocessor lines taken
 * out. So: no macros in declarations, constants are enums, every field
 * has a fixed width, and every struct is laid out by hand to need no
 * padding (bl_layout_ok checks, at start, on both ends).
 *
 * VERSIONS. bl_header.version is BL_VERSION; an end that finds another
 * refuses the file. The layout is not a protocol to keep compatible:
 * both ends ship in one image.
 */
#ifndef BOTLINK_H
#define BOTLINK_H

#include <stdint.h>

enum {
	BL_MAGIC = 0x4B4E4C42,     /* "BLNK", little-endian */
	BL_VERSION = 1,
	BL_MAX_PLAYERS = 256,      /* every id the server can seat */
	BL_NO_PLAYER = 255,
	BL_RING_BYTES = 1 << 18,   /* each queue: 256 KiB, a power of two */
	BL_RECORD_MAX = 1024,      /* the longest record, header included */
	BL_PATH_MAX = 256
};

typedef struct bl_vec3 { float x, y, z; } bl_vec3;

/* ------------------------------------------------------------------ */
/* THE WORLD: the server's, rewritten whole every tick.               */

enum bl_player_state {
	BL_ABSENT = 0,     /* no such player */
	BL_LIMBO = 1,      /* connected, not in the game (loading, spectating) */
	BL_DEAD = 2,       /* in the game, waiting to spawn */
	BL_ALIVE = 3
};

enum bl_player_flags {
	BL_F_BOT = 1,          /* one of the engine's: it owes it an intent */
	BL_F_CROUCH = 2,
	BL_F_SPRINT = 4,
	BL_F_AIRBORNE = 8,
	BL_F_WADING = 16,
	BL_F_LAMP = 32,        /* flashlight lit */
	BL_F_FIRING = 64,      /* primary held */
	BL_F_SCOPED = 128      /* secondary held */
};

enum bl_tool { BL_TOOL_SPADE = 0, BL_TOOL_BLOCK = 1, BL_TOOL_GUN = 2, BL_TOOL_GRENADE = 3 };
enum bl_gun { BL_GUN_RIFLE = 0, BL_GUN_SMG = 1, BL_GUN_SHOTGUN = 2 };

/* The keys of a client's InputData, and of an intent. */
enum bl_keys {
	BL_K_FORWARD = 1, BL_K_BACK = 2, BL_K_LEFT = 4, BL_K_RIGHT = 8,
	BL_K_JUMP = 16, BL_K_CROUCH = 32, BL_K_SNEAK = 64, BL_K_SPRINT = 128
};

typedef struct bl_player {          /* 52 bytes */
	uint8_t state;                  /* bl_player_state */
	uint8_t team;                   /* 1 or 2; 0 for a spectator */
	uint8_t tool;                   /* bl_tool */
	uint8_t gun;                    /* bl_gun */
	uint8_t flags;                  /* bl_player_flags */
	uint8_t hp;
	uint8_t mag;                    /* rounds in the gun */
	uint8_t reserve;                /* rounds besides */
	uint8_t blocks;
	uint8_t grenades;
	uint8_t keys;                   /* bl_keys held, as the server has them */
	uint8_t pad_;
	uint32_t life;                  /* goes up at each spawn: a new body */
	bl_vec3 pos;                    /* the eye */
	bl_vec3 ori;                    /* unit vector */
	bl_vec3 vel;
} bl_player;

/* An intel or a base. */
typedef struct bl_object {          /* 16 bytes */
	bl_vec3 pos;
	uint8_t holder;                 /* pid carrying it, or BL_NO_PLAYER */
	uint8_t present;                /* 0: this game has none */
	uint8_t pad_[2];
} bl_object;

typedef struct bl_world {
	uint32_t seq;                   /* odd while the server is writing */
	uint32_t tick;                  /* the server's tick count */
	double time;                    /* its clock, seconds */
	uint32_t map_seq;               /* goes up at each map: see BL_EV_MAP */
	uint8_t night;                  /* 1 by night */
	uint8_t pad_[3];
	uint16_t score[2];              /* team 1, team 2 */
	uint16_t max_score;
	uint8_t pad2_[2];
	bl_object intel[2];             /* team 1's, team 2's */
	bl_object tent[2];
	bl_player players[BL_MAX_PLAYERS];
} bl_world;

/* ------------------------------------------------------------------ */
/* INTENTS: the engine's, one per bot, the newest wins.               */

enum bl_mouse { BL_M_PRIMARY = 1, BL_M_SECONDARY = 2 };

typedef struct bl_intent {          /* 20 bytes */
	uint32_t life;                  /* the bl_player.life it was thought for:
	                                   an intent for a body gone is ignored */
	uint8_t keys;                   /* bl_keys */
	uint8_t mouse;                  /* bl_mouse */
	uint8_t tool;                   /* bl_tool to hold */
	uint8_t flags;                  /* BL_I_* */
	bl_vec3 ori;                    /* where to look, a unit vector */
} bl_intent;

enum bl_intent_flags {
	BL_I_VALID = 1,        /* the engine has thought for this bot at all */
	BL_I_LAMP = 2,         /* wants its flashlight lit */
	BL_I_RELOAD = 4        /* wants to reload now */
};

/* ------------------------------------------------------------------ */
/* THE QUEUES: records in order, one writer and one reader each.      */
/* A record is a bl_record header and `size - 4` bytes of payload,    */
/* never split by the end of the ring (the writer pads to it).        */

typedef struct bl_record {
	uint16_t size;                  /* header and payload; 0: a pad to the
	                                   end of the ring, skip to its start */
	uint8_t type;                   /* bl_event or bl_action */
	uint8_t pid;                    /* whom it is about, or BL_NO_PLAYER */
} bl_record;

typedef struct bl_ring {
	uint32_t head;                  /* bytes written, ever (the writer's) */
	uint32_t tail;                  /* bytes read, ever (the reader's) */
	uint32_t dropped;               /* records the writer could not fit */
	uint32_t pad_;
	uint8_t data[BL_RING_BYTES];
} bl_ring;

/* What the server tells the engine. Payloads follow each name. */
enum bl_event {
	BL_EV_MAP = 1,         /* bl_ev_map: a map is up; load it, forget the last */
	BL_EV_BLOCK = 2,       /* bl_ev_block: one block action, as clients are told */
	BL_EV_LINE = 3,        /* bl_ev_line: a line of blocks built */
	BL_EV_KILL = 4,        /* bl_ev_kill; pid is the victim */
	BL_EV_HURT = 5,        /* bl_ev_hurt; pid lost health, and from where */
	BL_EV_SOUND = 6,       /* bl_ev_sound; pid made a noise */
	BL_EV_GRENADE = 7,     /* bl_ev_grenade; pid threw one */
	BL_EV_PING = 8,        /* bl_ev_ping; pid pinged a place for its team */
	BL_EV_BOT = 9,         /* bl_ev_bot: pid is a bot now, and what kind */
	BL_EV_UNBOT = 10,      /* (none): pid is no bot any more */
	BL_EV_SET = 11,        /* text "key=value": a rule or a setting, for
	                          everybody (pid BL_NO_PLAYER) or one bot */
	BL_EV_ORDER = 12       /* bl_ev_order: what one bot is told to do */
};

enum bl_block_action { BL_B_BUILD = 0, BL_B_DESTROY = 1, BL_B_SPADE = 2, BL_B_GRENADE = 3 };

typedef struct bl_ev_map {
	uint32_t map_seq;               /* the bl_world.map_seq it becomes */
	char path[BL_PATH_MAX];         /* a .vxl of the map as it is now */
} bl_ev_map;

typedef struct bl_ev_block {
	int16_t x, y, z;
	uint8_t action;                 /* bl_block_action */
	uint8_t by;                     /* pid, or BL_NO_PLAYER for the server */
	uint32_t color;                 /* 0x00RRGGBB, for a build */
} bl_ev_block;

typedef struct bl_ev_line {
	int16_t x1, y1, z1, x2, y2, z2;
	uint8_t by;
	uint8_t pad_[3];
	uint32_t color;
} bl_ev_line;

typedef struct bl_ev_kill {
	uint8_t killer;                 /* or BL_NO_PLAYER */
	uint8_t kind;                   /* the protocol's KillType */
	uint8_t pad_[2];
} bl_ev_kill;

typedef struct bl_ev_hurt {
	bl_vec3 from;                   /* where it came from */
	uint8_t by;                     /* pid, or BL_NO_PLAYER */
	uint8_t hp;                     /* what is left */
	uint8_t pad_[2];
} bl_ev_hurt;

enum bl_sound { BL_S_SHOT = 1, BL_S_DIG = 2, BL_S_BUILD = 3, BL_S_STEP = 4, BL_S_BLAST = 5 };

typedef struct bl_ev_sound {
	bl_vec3 pos;
	uint8_t kind;                   /* bl_sound */
	uint8_t pad_[3];
} bl_ev_sound;

typedef struct bl_ev_grenade {
	bl_vec3 pos;
	bl_vec3 vel;
	float fuse;                     /* seconds */
} bl_ev_grenade;

typedef struct bl_ev_ping {
	bl_vec3 pos;
	char reason[64];
} bl_ev_ping;

typedef struct bl_ev_bot {
	uint8_t level;                  /* 1-10 */
	uint8_t gun;                    /* bl_gun */
	uint8_t pad_[2];
	uint32_t seed;                  /* its own randomness: the same seed is
	                                   the same bot */
} bl_ev_bot;

enum bl_order { BL_O_NONE = 0, BL_O_GOTO = 1, BL_O_HUNT = 2, BL_O_FOLLOW = 3, BL_O_HOLD = 4 };

typedef struct bl_ev_order {
	bl_vec3 pos;                    /* for GOTO and HOLD */
	uint8_t order;                  /* bl_order */
	uint8_t target;                 /* a pid, for HUNT and FOLLOW */
	uint8_t pad_[2];
	float secs;                     /* how long it stands; 0: until the next */
} bl_ev_order;

/* What the engine asks of the server. pid is the bot asking. */
enum bl_action {
	BL_AC_BLOCK = 1,       /* bl_ac_block: build or dig one block */
	BL_AC_LINE = 2,        /* bl_ac_line: build a line */
	BL_AC_GRENADE = 3,     /* bl_ac_grenade: throw one */
	BL_AC_COMMAND = 4,     /* text: a command line to run as the bot, no slash */
	BL_AC_COLOR = 5,       /* uint32 0x00RRGGBB: the colour it builds in */
	BL_AC_LOG = 6          /* text: a line for the server's log */
};

typedef struct bl_ac_block {
	int16_t x, y, z;
	uint8_t action;                 /* bl_block_action: build, destroy or spade */
	uint8_t pad_;
} bl_ac_block;

typedef struct bl_ac_line {
	int16_t x1, y1, z1, x2, y2, z2;
} bl_ac_line;

typedef struct bl_ac_grenade {
	bl_vec3 vel;
	float fuse;
} bl_ac_grenade;

/* ------------------------------------------------------------------ */
/* THE FILE.                                                          */

typedef struct bl_header {
	uint32_t magic;                 /* BL_MAGIC */
	uint32_t version;               /* BL_VERSION */
	uint32_t size;                  /* sizeof(bl_file): a second check */
	uint32_t server_beat;           /* goes up while the server lives */
	uint32_t engine_beat;           /* goes up while the engine lives */
	uint32_t engine_pid;            /* the engine's process id, or 0 */
	uint32_t pad_[2];
} bl_header;

typedef struct bl_file {
	bl_header header;
	bl_world world;
	bl_intent intents[BL_MAX_PLAYERS];
	bl_ring events;                 /* server -> engine */
	bl_ring actions;                /* engine -> server */
} bl_file;

/* ------------------------------------------------------------------ */
/* THE CALLS (botlink.c). Each end makes its own half only.           */

/* Does this build lay the structs out as the header says? 1 if so. */
int bl_layout_ok(void);

/* The server makes the file (truncating what a dead server left) and
 * maps it; the engine maps the one there. NULL when it cannot be done,
 * or -- for the engine -- when it is not a file of this version. */
bl_file *bl_create(const char *path);
bl_file *bl_attach(const char *path);
void bl_close(bl_file *f);

/* The server, around its writing of f->world each tick. */
void bl_world_begin(bl_file *f);
void bl_world_end(bl_file *f);

/* The engine: a whole, unbroken copy of the world. 1 if it got one, 0
 * if the server was writing all through `tries` attempts. */
int bl_world_read(const bl_file *f, bl_world *out, int tries);

/* One record onto a ring. 0 if it does not fit: counted in `dropped`,
 * and the reader will see the gap there. */
int bl_push(bl_ring *r, uint8_t type, uint8_t pid, const void *payload, uint32_t bytes);

/* The next record off a ring, header and payload, into buf (of
 * BL_RECORD_MAX bytes). Its size, or 0 with nothing waiting. */
uint32_t bl_pop(bl_ring *r, void *buf);

/* A beat: each end calls its own, often. bl_alive: has the other end's
 * moved since `*last` was last filled in? */
void bl_beat_server(bl_file *f);
void bl_beat_engine(bl_file *f);
int bl_alive(uint32_t beat_now, uint32_t *last);

#endif /* BOTLINK_H */
