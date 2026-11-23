/* bt.h -- Behaviour trees whose choices are weighed
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * What a bot does is decided by a tree. The tree is shared by every bot
 * playing a gamemode and never changes while they play; what each bot
 * keeps is where in it it is (bt_state) and the character that weighs
 * its choices (persona.h). The tree is text, so a gamemode's Lua script
 * can bring its own, and the built-in ones (trees/) are written the
 * same way.
 *
 * A NODE answers one of three things each time it is ticked: SUCCESS,
 * FAILURE, or RUNNING (not done, tick me again).
 *
 *   seq            children in order; fails at the first that fails,
 *                  waits on one RUNNING, succeeds when all have
 *   select         children in order; the first that does not fail is
 *                  the answer. Written top to bottom, it is a priority
 *                  list -- a decision tree: the first rule that holds
 *   pick           a WEIGHED choice among its `option`s: see below
 *   if <cond> [arg]         SUCCESS if the condition holds, else FAILURE
 *   unless <cond> [arg]     the other way round
 *   do <action> [args...]   a skill: go there, fight, dig, throw, use
 *   wait <secs>             RUNNING for that long, then SUCCESS
 *   invert / always / never       one child: its answer turned / made
 *                                 SUCCESS / made FAILURE
 *   cooldown <secs>         one child; after it ends, FAILURE for that
 *                           long without asking it
 *   limit <secs>            one child; FAILURE if it is still RUNNING
 *                           after that long (and it is stopped)
 *   tree <name>             another tree, by name, as if written here
 *
 * PICK, and why no two bots choose alike. Each option is
 *
 *   option <trait> <score> [x<factor>]
 *       <one child>
 *
 * and its worth, right now, to this bot, is
 *
 *   score(bot)  x  the bot's weight for <trait>  x  factor  x  luck
 *
 * `score` is a named function of the situation, 0 to 1 (how near is the
 * enemy, how hurt am I, is our intel gone); the trait weight is the
 * bot's own, rolled when it was made (persona.h); luck is a draw from
 * its own randomness, within +-`noise`. The best option is ticked. So
 * the tree says what CAN be done and what bears on it; the character
 * says what THIS bot would rather.
 *
 *   pick [every=<secs>] [sticky=<x>] [noise=<x>]
 *
 * The choice is made again every `every` seconds (default 2) and
 * whenever the chosen option ends; between, the chosen one is ticked
 * without asking. The option being done is worth `sticky` more (default
 * 0.25, as a fraction of its own worth), so a bot does not flip between
 * two things about as good. An option whose score is 0 is never chosen;
 * with none above 0, pick fails.
 *
 * THE TEXT. One node a line, children indented under their parent by
 * one step more: a tab, or two or four spaces -- whichever the text's
 * first indented line uses, and the same all through (a mix, or a line
 * off the step, is an error). `#` starts a comment. Several trees in
 * one text, each begun by `tree <name>:` at no indent; a text with no
 * such line is one tree named "main".
 *
 *   tree main:
 *   select
 *       seq                          # hurt and out of the fight: get well
 *           if health_below 30
 *           do retreat
 *       pick every=3
 *           option aggression enemy_near
 *               do fight
 *           option objective intel_free x1.5
 *               do fetch_intel
 *           option curiosity heard_something
 *               do investigate
 *       do roam                      # nothing else to do
 *
 * LEAVES are named, and the host says what each name is (bt_vocab): a
 * condition, a score or an action, each a C function given the bot. A
 * tree that names a leaf nobody registered does not compile, and the
 * error says which line. An action that is RUNNING when its branch
 * stops being chosen is told so (stop), once, so it can let go of what
 * it held -- a route, a key.
 */
#ifndef BT_H
#define BT_H

#include <stddef.h>
#include <stdint.h>

typedef enum bt_status { BT_FAILURE = 0, BT_SUCCESS = 1, BT_RUNNING = 2 } bt_status;

enum { BT_ARGS_MAX = 4, BT_NAME_MAX = 32, BT_DEPTH_MAX = 32 };

/* A leaf's arguments, as the tree wrote them after its name. */
typedef struct bt_args {
	int count;
	float num[BT_ARGS_MAX];              /* each as a number (0 if it is not one) */
	const char *text[BT_ARGS_MAX];       /* each as written; owned by the tree */
} bt_args;

/* The three kinds of leaf. `bot` is the host's own pointer, handed
 * back as given; `dt` is the time since this bot's last tick. */
typedef int (*bt_cond_fn)(void *bot, const bt_args *args);
typedef float (*bt_score_fn)(void *bot, const bt_args *args);
typedef bt_status (*bt_action_fn)(void *bot, const bt_args *args, float dt);
typedef void (*bt_stop_fn)(void *bot, const bt_args *args);

/* The names a tree may use. Filled once by the host, before any tree is
 * compiled, and kept as long as the trees are. */
typedef struct bt_vocab bt_vocab;
bt_vocab *bt_vocab_new(void);
void bt_vocab_free(bt_vocab *v);
/* 0 if the name is taken, too long, or v is full */
int bt_vocab_cond(bt_vocab *v, const char *name, bt_cond_fn fn);
int bt_vocab_score(bt_vocab *v, const char *name, bt_score_fn fn);
/* `stop` may be NULL */
int bt_vocab_action(bt_vocab *v, const char *name, bt_action_fn fn, bt_stop_fn stop);
/* the trait a `pick` option names -> its index into the weights given
 * to bt_tick; registered by the host from persona.h's names */
int bt_vocab_trait(bt_vocab *v, const char *name, int index);

/* Compiled trees: every `tree <name>:` of one text. Immutable, shared. */
typedef struct bt_forest bt_forest;

/* Compile. NULL on a mistake, with what and where in err ("line 12:
 * no action called figth"). */
bt_forest *bt_compile(const bt_vocab *v, const char *text, char *err, size_t err_size);
void bt_forest_free(bt_forest *f);
/* a tree's index, or -1 */
int bt_forest_find(const bt_forest *f, const char *name);
/* how many nodes it has in all: what a bt_state must hold */
size_t bt_forest_nodes(const bt_forest *f);

/* One bot's place in a forest. The caller allocates bt_state_size()
 * bytes once and calls bt_state_init; nothing is allocated after. */
typedef struct bt_state bt_state;
size_t bt_state_size(const bt_forest *f);
void bt_state_init(bt_state *s, const bt_forest *f);

/* What one tick needs that is the bot's own. */
typedef struct bt_ctx {
	void *bot;                 /* handed to every leaf */
	const float *weights;      /* the persona's trait weights, by index */
	int n_weights;
	float dt;                  /* seconds since this bot's last tick */
	/* a draw in [0, 1) from the bot's own randomness */
	float (*random)(void *bot);
} bt_ctx;

/* Tick tree `tree` of the forest for this bot. */
bt_status bt_tick(const bt_forest *f, int tree, bt_state *s, const bt_ctx *ctx);

/* Forget where the bot was (it died, the map changed): every action
 * still RUNNING is stopped, every timer cleared. */
void bt_reset(const bt_forest *f, bt_state *s, const bt_ctx *ctx);

/* For a log, a test or a debug overlay: the leaf actions RUNNING after
 * the last tick, outermost first, as "fight" or "fetch_intel", joined
 * by " > " with the options chosen on the way ("pick:aggression"). */
size_t bt_describe(const bt_forest *f, const bt_state *s, char *out, size_t out_size);

#endif
