/* bt.h -- Behaviour trees whose choices are weighed
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * What a bot does is decided by a tree. The tree is shared by every bot
 * playing a gamemode and never changes while they play; what each bot
 * keeps is where in it it is (bt_state) and the character that weighs
 * its choices (persona.h). The tree is text, so a gamemode's Lua script
 * can bring its own, and the built-in ones (trees/) are written the
 * same way. (This comment is the grammar in short; bot/TREES.md is the
 * reference, with every keyword's exact answers, examples that are
 * compiled by the tests, and how to write, tune and debug a tree.)
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
 * CONDITIONS ON NUMBERS. A VALUE is a named number read off the bot's
 * situation (how far the nearest enemy is, its health), or UNKNOWN (no
 * enemy in sight has no distance). Wherever a condition goes, a
 * comparison may:
 *
 *   if <value> [args...] <op> <number>       op: <  <=  >  >=
 *   unless <value> [args...] <op> <number>
 *
 * A comparison with an unknown value is false (so `unless` of it is
 * true). A condition may be SHORT for a comparison (bt_vocab_short):
 * `if health_below 30` is `if health < 30`, compiled as that.
 *
 * IF AS A BLOCK. `if` and `unless` with children are a decision:
 *
 *   if enemy_distance < 5
 *       do fight
 *   else
 *       do take_cover
 *
 * The condition is asked when the node is entered (it was not RUNNING);
 * the branch chosen -- its children, in order, as a seq's -- is ticked
 * until it ends, and the node answers what it answers. False with no
 * `else`: FAILURE, as the leaf. `else` is written at the if's indent,
 * right after its children, and holds the other branch.
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
 * says what THIS bot would rather. A comparison may stand for the score
 * (`option caution health < 40 x2`): 1 when it holds, 0 when not.
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
 *   pick roll=once      pick roll=life
 *
 * A ROLE, DRAWN AND KEPT. Such a pick does not take the best: it DRAWS
 * one option, each with a chance in proportion to its worth (score x
 * trait weight x factor: no luck, no sticky) -- options x1, x10, x1 are
 * drawn 1, 10 and 1 times in 12 -- and then keeps it: its child is
 * ticked every time, whatever it answers, and the pick answers what the
 * child does. `roll=once`: the draw is the bot's for good, made from
 * its identity (bt_ctx) and from which pick this is (its tree's name
 * and its place among that tree's picks), so the same bot has the same
 * role in every life, on every map, each time the trees are compiled;
 * nothing is stored. `roll=life`: drawn anew from the bot's randomness
 * after each bt_reset. What the draw LANDS ON is worked out at the first
 * tick after a reset, from the worths as they are then: so the scores
 * of such options should be facts about the bot (its gun, what it
 * holds), not the situation of the moment. `every`, `sticky` and `noise`
 * mean nothing with `roll=once` and `roll=life` and may not be written
 * with them.
 *
 *   pick roll=each [every=<secs>]
 *
 * A LOTTERY AT EVERY CHOICE. The choice is made when a plain pick makes
 * it (the first tick, every `every` seconds, whenever the option's child
 * ends), but it is a draw, as above: one option, each with a chance in
 * proportion to its worth (score x trait weight x factor: no luck, no
 * sticky), from the bot's own randomness (bt_ctx.random, not its
 * identity), and ticked until the next choice. The draw may land on the
 * option already held: that one then goes on, it is not stopped. An
 * option whose score is 0 is never drawn; with none above 0, pick fails
 * (and draws nothing). Like a plain pick, it chooses afresh after
 * bt_restart and bt_reset. `sticky` and `noise` may not be written.
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
 * condition, a score, an action or a value, each a C function given the
 * bot. A
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
/* a value: 1 with the number in *out, or 0 when it is unknown now */
typedef int (*bt_value_fn)(void *bot, const bt_args *args, double *out);

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

/* WHAT A WORD TAKES. A host may say, for a word it registered, what
 * arguments it takes: the compiler then checks every use of it -- how
 * many, a number where a number goes (and within its range), a word
 * that is one of those allowed -- and says which line and column is
 * wrong. A word nobody described is not checked: its arguments are its
 * function's business, as they always were. The specs are also what an
 * editor shows (vocab.h hands them out for the engine's words).
 *
 * `specs` is kept by pointer, as long as the vocabulary: n of them, at
 * most BT_ARGS_MAX, the required ones first. Only the last may repeat. */
enum { BT_ARG_NUMBER, BT_ARG_ONE_OF, BT_ARG_TEXT };
enum { BT_WORD_COND, BT_WORD_SCORE, BT_WORD_ACTION, BT_WORD_VALUE };

typedef struct bt_arg_spec {
	const char *name;           /* "voxels": what it is called in the usage */
	unsigned char type;         /* BT_ARG_NUMBER: a number; BT_ARG_ONE_OF: a
	                               word of `values`, or of the list `set`;
	                               BT_ARG_TEXT: any word */
	unsigned char required;     /* else it may be left out */
	unsigned char repeat;       /* it may be given several times (the last) */
	unsigned char has_default;  /* `def` is what leaving it out means */
	unsigned char has_min, has_max;
	const char *values;         /* ONE_OF: "calm|suspicious|engaged", or NULL */
	const char *set;            /* ONE_OF: the name of a list given with
	                               bt_vocab_set ("place"), or NULL */
	float def, min, max;
	const char *def_text;       /* ONE_OF: the word leaving it out means
	                               ("mate"), or NULL */
	const char *def_note;       /* when what leaving it out means is not one
	                               value: what it depends on, in words */
} bt_arg_spec;

/* 0 if there is no such word, or n is over BT_ARGS_MAX. n may be 0: the
 * word takes no argument, and giving one is a mistake. */
int bt_vocab_args(bt_vocab *v, int kind, const char *name, const bt_arg_spec *specs, int n);
/* a named list of words ("a|b|c", copied) for BT_ARG_ONE_OF's `set`. An
 * entry ending in `*` ("@*") allows any word that begins so and goes on
 * as a name: for words the host cannot list when the tree is compiled */
int bt_vocab_set(bt_vocab *v, const char *name, const char *values);
const char *bt_vocab_set_values(const bt_vocab *v, const char *name);

/* A VALUE (a comparison's left side). `number` says what a number it is
 * compared with is: its `name` is the unit ("voxels"), its has_min/min
 * and has_max/max the range the value keeps within -- a number written
 * outside it is a mistake (`health < 500`). Kept by pointer, as specs
 * are. Its own arguments, if any: bt_vocab_args(v, BT_WORD_VALUE, ...). */
int bt_vocab_value(bt_vocab *v, const char *name, bt_value_fn fn, const bt_arg_spec *number);

/* A condition or a score (kind BT_WORD_COND, BT_WORD_SCORE) that is
 * SHORT for a comparison, and is compiled as it: `comparison` is one, as
 * a tree writes it, with $1..$4 for the word's own arguments ("health <
 * $1"; an argument left out is its spec's default), and for a condition
 * it may begin with `unless` ("unless mate_distance <= $1"). A score so
 * is 1 when it holds and 0 when not. The word's own arguments are
 * checked as any word's (bt_vocab_args). Kept by pointer. */
int bt_vocab_short(bt_vocab *v, int kind, const char *name, const char *comparison);

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
	/* who this bot is, for good: a number that is its own and the same
	 * every time (the host gives its seed). A `pick roll=once` draws
	 * from it. 0: the host has none -- such a pick then draws from
	 * `random`, once a reset. */
	uint64_t identity;
} bt_ctx;

/* Tick tree `tree` of the forest for this bot. */
bt_status bt_tick(const bt_forest *f, int tree, bt_state *s, const bt_ctx *ctx);

/* Forget where the bot was (it died, the map changed): every action
 * still RUNNING is stopped, every timer cleared. */
void bt_reset(const bt_forest *f, bt_state *s, const bt_ctx *ctx);

/* The same, but for the roles drawn by `pick roll=`: those are kept.
 * For a bot that was startled, not born: every other pick chooses now,
 * every action stops, and it is still what it was. */
void bt_restart(const bt_forest *f, bt_state *s, const bt_ctx *ctx);

/* For a log, a test or a debug overlay: the leaf actions RUNNING after
 * the last tick, outermost first, as "fight" or "fetch_intel", joined
 * by " > " with the options chosen on the way ("pick:aggression"). */
size_t bt_describe(const bt_forest *f, const bt_state *s, char *out, size_t out_size);

/* ---- LOOKING INTO A TREE: for a drawing, an editor, a debugger --------
 *
 * Everything above is what a bot needs. What follows is for whoever
 * shows a tree, edits one or watches a bot think: nothing here is used
 * by a tick.
 *
 * There are two shapes of the same text.
 *
 * THE SOURCE (bt_source) is the text as it was written: its trees, each
 * node with its words, its line and column, and its COMMENTS; a
 * `tree <name>` reference is a node like another (BT_K_TREE), and may
 * name a tree the text does not have (`items`, `extras`: the engine
 * writes those). It is what an editor reads and, through
 * bt_source_text, writes: the text is the only form a tree is kept in.
 *
 * THE FOREST (bt_forest) is what is run: every reference opened where
 * it stands, so a tree used twice is there twice, each with its own
 * state. It is what a debugger reads, with a bt_state beside it.
 *
 * A NODE'S ID is its index: in the source, its place among the node
 * lines of the text, from 0; in the forest, its place in the order the
 * text is read with every reference opened (it is also the index of its
 * slot in a bt_state). Both are the same each time the same text is
 * compiled with the same vocabulary, in any process, and that is all
 * that is promised: change the text and they move. A forest node says
 * which source node it was written as (`source`), and many may name the
 * same one.
 */

typedef enum bt_kind {
	BT_K_SEQ, BT_K_SELECT, BT_K_PICK, BT_K_OPTION, BT_K_IF, BT_K_UNLESS, BT_K_DO,
	BT_K_WAIT, BT_K_INVERT, BT_K_ALWAYS, BT_K_NEVER, BT_K_COOLDOWN, BT_K_LIMIT,
	BT_K_TREE, BT_K_ELSE, BT_K_COUNT
} bt_kind;
/* "seq" ... "else": the word the text uses; NULL for no such kind */
const char *bt_kind_name(int kind);

/* AN ELSE is a node of its own: the last child of its `if` or `unless`
 * (its parent), its children the branch taken when the condition does
 * not hold. It is written at its if's indent, so its `column` is the
 * if's; a tick never stops at it (it goes on to its children). */

/* a comparison's operator; BT_OP_NONE: the node names a condition or a
 * score, not a value */
enum { BT_OP_NONE, BT_OP_LT, BT_OP_LE, BT_OP_GT, BT_OP_GE, BT_OP_COUNT };
/* "<", "<=", ">", ">="; NULL for none */
const char *bt_op_name(int op);

/* which of a node's numbers the text gave (the others are the defaults) */
enum { BT_W_EVERY = 1, BT_W_STICKY = 2, BT_W_NOISE = 4, BT_W_FACTOR = 8, BT_W_ROLL = 16 };
/* how a pick chooses (its `roll=`) */
enum { BT_ROLL_WEIGHED = 0, BT_ROLL_ONCE = 1, BT_ROLL_LIFE = 2, BT_ROLL_EACH = 3 };

typedef struct bt_node {
	int id;                     /* its index (see above) */
	int kind;                   /* bt_kind; never BT_K_TREE in a forest */
	int tree;                   /* the tree it is in, by index */
	int parent;                 /* ids, of the source or of the forest as */
	int first_child;            /* the node is; -1 for none */
	int next_sibling;
	int n_children;
	int source;                 /* the source node it was written as */
	int via;                    /* forest: the `tree <name>` source node that
	                               brought this node here, for the root of a
	                               tree opened in place (the outermost, when
	                               a reference leads to another); else -1 */
	int line, column;           /* where it is written, both from 1; a tab
	                               is one column */
	const char *text;           /* its words as written, one space apart */
	const char *name;           /* if, unless: the condition; do: the action;
	                               option: the score; tree: the tree named;
	                               if, unless, option with an `op`: the value
	                               compared; else NULL */
	const char *trait;          /* option; else NULL */
	bt_args args;               /* what follows the name, as written (a
	                               comparison: the value's own, before the
	                               operator) */
	int op;                     /* if, unless, option: BT_OP_* of a comparison */
	float number;               /* a comparison's number */
	float secs;                 /* wait, cooldown, limit */
	float every, sticky, noise; /* pick */
	float factor;               /* option */
	unsigned written;           /* BT_W_*: which of those were written */
	int roll;                   /* pick: BT_ROLL_* */
	const char *comment;        /* the comment on its line, without the `#`
	                               and the spaces round it; NULL for none */
	const char *above;          /* the lines between the node before and
	                               this one -- `# ...` comments and empty
	                               lines -- as written but for their
	                               indentation, each ended by '\n'; NULL */
} bt_node;

typedef struct bt_tree {
	const char *name;
	int root;                   /* its first node's id */
	int line;                   /* of its `tree <name>:` line, or of its
	                               first node when it has none */
	int header;                 /* 0 for the tree "main" of a text with no
	                               `tree <name>:` line */
	const char *comment;        /* on the header's line, as bt_node's */
	const char *above;          /* above the header, as bt_node's */
} bt_tree;

/* A mistake, as data. `column` is that of the word at fault, 0 when the
 * mistake is not in one word (an empty tree, no memory). `message` is
 * the string form's text after its "line N: ". bt_compile, bt_parse and
 * bt_compile_diag stop at the first mistake; bt_diagnose goes on. */
typedef struct bt_diag { int line, column; char message[240]; } bt_diag;

/* The text read, not linked: words and shapes are checked exactly as
 * bt_compile checks them (it is the same code), references are not
 * looked up. NULL on a mistake, said in *diag (which may be NULL). */
typedef struct bt_source bt_source;
bt_source *bt_parse(const bt_vocab *v, const char *text, bt_diag *diag);
void bt_source_free(bt_source *src);
int bt_source_trees(const bt_source *src);
int bt_source_nodes(const bt_source *src);
/* 1 and *out filled, or 0 for an index there is none of */
int bt_source_tree(const bt_source *src, int tree, bt_tree *out);
int bt_source_node(const bt_source *src, int id, bt_node *out);
/* the comments and empty lines after the last node, as bt_node's
 * `above`; NULL for none */
const char *bt_source_tail(const bt_source *src);

/* The source written back as text, in the one canonical form: a tab a
 * level, a tree's root at no indent under its header, words one space
 * apart, a comment on a node's line at column 47 (a tab counted as
 * four; one space after a longer line), comments and empty lines above
 * where they were. Parsing what it wrote gives the same source, and
 * writing that the same text. Returns the length in full, writes at
 * most out_size - 1 and a 0, as snprintf does. */
size_t bt_source_text(const bt_source *src, char *out, size_t out_size);

/* bt_compile, with the mistake as data. */
bt_forest *bt_compile_diag(const bt_vocab *v, const char *text, bt_diag *diag);

/* EVERY mistake of a text, up to `max`, into out[]; returns how many (0:
 * it compiles). The first is the one bt_compile would say. After a line
 * that is wrong the reading goes on: the line keeps its place if only
 * its words were wrong, and what merely follows from a line that had to
 * be dropped (a child left with no parent) is not said. `link` 0: as
 * bt_parse, references are not looked up; else as bt_compile. */
int bt_diagnose(const bt_vocab *v, const char *text, int link, bt_diag *out, int max);

/* The source a forest was compiled from; it lives as long as the forest. */
const bt_source *bt_forest_source(const bt_forest *f);
int bt_forest_trees(const bt_forest *f);
/* as bt_source_tree, `root` being the tree's root in the forest: what
 * bt_tick(f, tree, ...) ticks */
int bt_forest_tree(const bt_forest *f, int tree, bt_tree *out);
/* node i of the forest, 0 <= i < bt_forest_nodes(f) */
int bt_forest_node(const bt_forest *f, int i, bt_node *out);

/* ---- WATCHING A BOT THINK ---------------------------------------------
 *
 * All of this reads a bt_state between two ticks and changes nothing.
 */

/* What one node remembers. */
typedef struct bt_node_state {
	int running;        /* it answered RUNNING at its last tick: a seq, a
	                       select or an if block waiting on a child, a pick
	                       holding an option, a do, a wait or a limit
	                       under way */
	int child;          /* seq, select, an if block: the child it will
	                       resume at (for the branch of an `else`, a child
	                       of the else); pick: the option it holds; -1
	                       for none */
	float elapsed;      /* wait, limit: seconds since it began; pick: since
	                       it last chose; else 0 */
	float remaining;    /* wait, limit: seconds before it ends; pick: before
	                       it chooses again; cooldown: before it may be
	                       asked again; never below 0 */
} bt_node_state;
int bt_state_node(const bt_forest *f, const bt_state *s, int i, bt_node_state *out);

/* The nodes of tree `tree` that are RUNNING after the last tick, from
 * the root down to the action (or the wait) the bot is in: a single
 * path, decorators and the option held included (an `else` is not: the
 * path goes from the if to the child of the else). Returns how many
 * (never more than BT_DEPTH_MAX), 0 when the tree is not RUNNING;
 * writes at most `max` ids. */
int bt_state_running(const bt_forest *f, const bt_state *s, int tree, int *out, int max);

/* WHY a pick chose what it holds. Off by default, and kept off for the
 * bots nobody watches: when on, each time a pick of this state chooses
 * it also notes, for every option, the four numbers it multiplied. They
 * are kept where an option's node had nothing to keep, so a state is no
 * larger, and a tick with it off does one test more an option weighed.
 * bt_state_init turns it off; bt_reset leaves it as it was. */
void bt_state_trace(bt_state *s, int on);

typedef struct bt_worth {
	int option;         /* the option's id in the forest */
	int weighed;        /* 0: this pick has not chosen since tracing began,
	                       or a branch it is in was abandoned since (the
	                       numbers below are then 0, but for factor) */
	int held;           /* it is the option the pick holds now */
	float score;        /* what its score answered */
	float weight;       /* the bot's weight for its trait */
	float factor;       /* its x<factor> */
	float luck;         /* the draw, within 1 +- noise; 0 with a score of 0
	                       (no draw is made) */
	float sticky;       /* 1 + the pick's sticky if it was the one held
	                       when the pick chose, else 1 */
	float worth;        /* the five multiplied: the highest was chosen */
	/* a pick that rolls (roll=once, roll=life, roll=each): luck and sticky
	 * are 1, `held` is the role it drew (RUNNING or not; for roll=each the
	 * option it holds now), and */
	float share;        /* this option's part of the lottery, 0 to 1: its
	                       worth over the sum of them all */
	float draw;         /* the draw, in [0, 1): the same for every option (for
	                       roll=each, the last one made) */
} bt_worth;
/* The options of pick `pick` (a forest id) as last weighed. Returns how
 * many options it has, 0 if `pick` is not a pick; writes at most `max`. */
int bt_state_worths(const bt_forest *f, const bt_state *s, int pick, bt_worth *out, int max);

#endif
