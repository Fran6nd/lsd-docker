/* engine.c -- engine.h: all the bots of one server
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * brain.h says how a think goes (decide / plan / act). This file holds
 * what is shared, applies what the server says, and runs that loop.
 *
 * SETTINGS (BL_EV_SET, "key=value"; for everybody, or one bot where
 * marked *):
 *   tree=<name>            * the tree to run ("default" when unset). A
 *                            value of several lines is the TEXT of trees
 *                            (bt.h), compiled on its own (with the items
 *                            and extras: it cannot refer to the built-in
 *                            files' trees) and kept beside them; the
 *                            first tree in it is the one run. FOR ONE
 *                            BOT the text is that bot's own (a gamemode's
 *                            NPC with a role of its own): compiled and
 *                            kept for it alone, replaced by its next
 *                            tree=, freed with the bot; an empty value
 *                            gives it back the world's tree. A text that
 *                            does not compile changes nothing and is said
 *                            with its line. Changing a tree in play stops
 *                            whatever action was RUNNING, once.
 *   traits=<trait>:<f>,... * every named trait's weight (persona.h) is
 *                            MULTIPLIED by f, on top of what each bot
 *                            rolled, within persona's range (0.2 to 3):
 *                            the bots keep their differences, the lot
 *                            leans. For everybody and for one bot the two
 *                            multiply. Empty clears. A name nobody knows
 *                            is said and left out.
 *   cull=voxlap|openspades   the server's floating-block personality
 *   archetypes=camper:2,pusher:3,...   the mix characters are drawn from
 *   archetype_table=<text>   the kinds of player as data (trees/
 *                            archetypes.txt, persona.h), over the built-in
 *   sight, fov, notice, memory, relay, board, noise_secs   the senses
 *   night.sight=0|1          the three rows of night sight (senses.h) hold
 *                            (0: a night world is seen as by day)
 *   night.cone=<degrees>     a lamp's cone, the whole angle (90)
 *   night.reach=<voxels>     and how far it lights (60)
 *   night.far=<voxels>       how far night vision sees a lit lamp (192)
 *   night_vision=0|1       * the bot sees by night as by day (senses.h)
 *   name=<text>            * what the server calls this bot: only for a
 *                            person reading a view of it (debug.c)
 *   edit=none|dig|build|all  * what a route may do to the map (none)
 *   spend=<n>                blocks a route may use (50)
 *   water=lethal|safe
 *   water.damage=<n>         health a second a wading body loses (0)
 *   zone=x0 y0 x1 y1 [nodig] [nobuild] [team N][; ...]   the rectangles
 *                            where routes do not edit (both, when neither
 *                            is said), for everybody or for team N's bots;
 *                            each set the whole list; zone=clear
 *   protect=x y z            a voxel the server will refuse to change
 *   blueprint.<name>=x y z; ...   a structure the team builds a part each
 *                            (blueprint.h; name@team for a team's)
 *   leaders.per=<n>          one leader for every n of a team (5; 0: none)
 *   leaders.human=<weight>   a person's weight in the draw, a bot's being
 *                            about 1 (2): skill_squad.c
 *   plan.greed=<x>           how greedy a route search is (1.5; nav.h h_weight;
 *                            1: exact, and water searched as land is)
 *   plan.cap=<n>             expansions a search may take before the bot sets
 *                            off for the nearest place it found (8000; 0: none)
 *   plan.share=0|1           a team's bots going the same way share one search
 *                            (1; routes.h, the route board)
 *   plan.wait=walk|stand     what a bot does while its route is searched
 *                            (walk: on toward the goal)
 *   gaze=0|1                 1 (default): a travelling bot's head is its
 *                            own (skill_look.c). 0: it faces as it steers
 *   ping_takers=<n>          how many bots answer one ping (2)
 *   ping_radius=<voxels>     and from how far (40; aosbot's numbers)
 *   item.<name>=<count>    * what a bot holds ("inf": without end)
 *   item.<name>.tree=<text>  the item's own decision (below)
 *   item.<name>.guide=<secs> how long the aim stays on the man it was
 *                            used on (a guided thing follows the aim)
 *   extra.<name>.tree=<text> a script's addition to every bot (below)
 *   anything else            is kept, for a tree's `if setting <key>`.
 *
 * THE BRIDGE: what a server's script tells the trees, by names of its
 * own choosing. The engine knows none of them -- no gamemode, no item,
 * no script: it carries the names, and the trees ask by name.
 *   fact.<name>=<number>   * a FACT: the condition and the score `fact
 *                            <name>` read it. For everybody, or for one
 *                            bot (its own is read before the world's).
 *                            Empty: forgotten. Names are letters, digits
 *                            and _, 23 at most; 64 for the world, 8 a
 *                            bot: one more is refused and said. Nothing
 *                            is done when a fact changes: a pick sees it
 *                            at its next choice (`every`).
 *   place.<name>=x y z     * a PLACE, written `@<name>` wherever a tree
 *   place.<name>=pid <n>     takes a place: a point, or wherever player n
 *                            is while he lives. The same rules; 32 for
 *                            the world, 4 a bot. While it is not set,
 *                            `knows @name` is false and going there
 *                            fails, as for any place there is none of.
 *   (and `do tell <name> ...` goes the other way: skill_misc.c, BL_AC_TELL)
 *
 * A VALUE TOO LONG FOR ONE RECORD (a tree's text: a record is under 1000
 * bytes) comes in pieces, each a record of its own: "+key#<total>=..."
 * first, "+key=..." for those between, and "+key!=..." last
 * (part_add). The whole is taken only if every piece came -- its length
 * is the total said -- and is else refused and said: a tree is never run
 * cut short. The most is 64 KiB.
 *
 * THE ITEMS TREE. The engine knows no item by name. Whoever defines an
 * item sends, with it, a fragment of tree saying when a bot should use
 * it; the engine writes one tree from all of them,
 *
 *     tree items:
 *     select
 *         seq
 *             if has_item medkit
 *             <the medkit's fragment>
 *         seq
 *             if has_item missile
 *             <the missile's fragment>
 *         ...
 *
 * and compiles it with the trees it was given, so any of them may say
 * `tree items` where using something fits. A SELECT, not a pick: a pick
 * ticks its one best option and fails with it, so a bot holding a medkit
 * it does not need would never get to its missile; and a trait that
 * weighs every option alike weighs nothing. Greed acts where it can be
 * seen: in how soon a bot uses the next thing (skill_misc.c, use). The
 * fragment is re-indented to the trees' own step. One that does not
 * compile is said (level 2, the item and the line in ITS text) and left
 * out; the rest stand. With no item the tree is one leaf that fails.
 *
 * THE EXTRAS TREE, for what a server's script adds to every bot's
 * behaviour without being an item -- NIGHT AND LAMPS first of all: the
 * engine's own trees know only day and no flashlight, and a server with
 * no night script gets plain day bots. A script sends
 * extra.<name>.tree=<text>, and the engine writes
 *
 *     tree extras:
 *     seq
 *         always
 *             seq
 *                 <the first fragment, in name order>
 *         always
 *             seq
 *                 <the next>
 *         ...
 *
 * each ticked at every decision whatever the others answer (a tree says
 * `tree extras` in its "_also" part). Same rules: re-indented, left out
 * and said if it does not compile, withdrawn by an empty value; with
 * none the tree is one leaf that succeeds. Keep an extra to actions
 * that end at once: one that stays RUNNING holds up those after it.
 *
 * THE NET UNDER EVERYTHING (act, watchdog). Whatever a skill or the
 * follower does or fails to report, a bot must not stand pushing at
 * something: 40 bots once stood for minutes wading against a bank with
 * the forward key down. So, independent of every skill, the engine
 * watches the BODY:
 *   - PUSHING: movement keys down (and not waiting on an edit) without
 *     the body getting a block away from where it was. Time with the
 *     keys up does not count but does not clear it either, unless it
 *     lasts a second (the first version cleared it on one think with no
 *     keys, and every new plan has such a think: it never fired). After
 *     1.5 s: a JUMP, and the route is planned again with the move it was
 *     on priced as failed (which, where edits are allowed, is what makes
 *     digging through or laying a step win). After 1.5 s more: a step
 *     BACK, then a SIDESTEP with a jump. After 1.5 s more: OUT.
 *   - GOING NOWHERE: on a route, not editing, and not leaving a circle of
 *     4 voxels for 8 s (sliding along a bank, backing up and coming on
 *     again). OUT at once.
 *   - OUT: the goal fails and is remembered as having no way to it from
 *     here (the team's, 30 s: skill_tactics.c), the place goes among the
 *     team's bad places so plans shy from it, the keys come up, the tree
 *     is entered afresh, and for 4 s the bot goes SOMEWHERE ELSE -- a
 *     place it can walk straight to, away from what it pushed at, dry if
 *     it can be -- before the tree's choice is taken up. Counted
 *     (stats.stuck_resets) and said at level 1, once a minute a bot.
 *   No crouch-jump: changing crouch in the air lifts a server-moved body
 *   (body.h).
 *
 * WHAT IS ALLOCATED, AND WHEN. bc_engine_new: the map (2 MiB), the cull
 * scratch (7 MiB), the move table, the searches (5.5 MiB each, 2 to 4),
 * the bots. A tree text arriving (bc_engine_trees, tree=, item.*.tree=)
 * allocates the compiled forest and each bot's place in it -- at that
 * event, never in a think.
 */
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "brain.h"
#include "vocab.h"

static const double DECIDE_PERIOD = 0.05;       /* about 20 a second */
enum { SEARCH_NODES = 131072 };

static const char FALLBACK_TREES[] =
	"tree default:\n"
	"pick every=1\n"
	"\toption none enemy_visible x3\n"
	"\t\tdo fight\n"
	"\toption none always\n"
	"\t\tdo roam\n";

/* ====================================================================== */
/* small things                                                           */

void bc_engine_log(bc_engine *e, int level, const char *fmt, ...)
{
	char line[400];
	va_list ap;

	if (!e->host.log)
		return;
	va_start(ap, fmt);
	vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	e->host.log(e->host.ctx, level, line);
}

const bc_engine_stats *bc_engine_stats_get(const bc_engine *e) { return &e->stats; }

bc_bot *bc_engine_bot(bc_engine *e, int pid)
{
	if (pid < 0 || pid >= BL_MAX_PLAYERS || e->by_pid[pid] < 0)
		return NULL;
	return &e->bots[e->by_pid[pid]];
}

const char *bc_engine_setting(const bc_engine *e, const char *key)
{
	int i;

	for (i = 0; i < e->nsettings; i++)
		if (!strcmp(e->settings[i].key, key))
			return e->settings[i].val;
	return NULL;
}

void bc_engine_search_release(bc_engine *e, bc_bot *b)
{
	if (b->mv.search >= 0 && b->mv.search < e->nsearch)
		e->search_owner[b->mv.search] = -1;
	b->mv.search = -1;
	if (b->mv.join) {
		/* a way onto a team-mate's route, left: its local bounds go */
		b->mv.join = 0;
		b->mv.pol.scope = 0;
		b->mv.pol.goal_exact_z = b->mv.exact;
	}
}

static float bot_random(void *bot)
{
	return bc_rng_float(&((bc_bot *)bot)->rng);
}

static void bot_ctx(bc_bot *b, bt_ctx *c, float dt)
{
	c->bot = b;
	c->weights = b->persona.trait;
	c->n_weights = BC_T_COUNT;
	c->dt = dt;
	c->random = bot_random;
	/* who it is for good (bt.h, `pick roll=once`): its seed, never 0 */
	c->identity = ((uint64_t)b->seed << 1) | 1u;
}

static char *dup_text(const char *s)
{
	size_t n = strlen(s) + 1;
	char *d = malloc(n);

	if (d) memcpy(d, s, n);
	return d;
}

/* ====================================================================== */
/* trees                                                                  */

/* the indent step a tree text uses: its first indented line's */
static void indent_of(const char *text, char *unit, size_t cap)
{
	const char *p = text;

	strcpy(unit, "\t");
	while (p && *p) {
		const char *eol = strchr(p, '\n');
		size_t n = 0;

		if (*p == '\t')
			return;
		while (p[n] == ' ') n++;
		if (n > 0 && p[n] != '\n' && p[n] != '\r' && p[n] != '#' && p[n] != 0) {
			if (n >= cap) n = cap - 1;
			memset(unit, ' ', n);
			unit[n] = 0;
			return;
		}
		p = eol ? eol + 1 : NULL;
	}
}

static void put(char **out, size_t *len, size_t *cap, const char *s, size_t n)
{
	if (*len + n + 1 > *cap) {
		size_t nc = (*cap + n + 1) * 2;
		char *t = realloc(*out, nc);

		if (!t) return;
		*out = t;
		*cap = nc;
	}
	memcpy(*out + *len, s, n);
	*len += n;
	(*out)[*len] = 0;
}

/* One item's fragment, re-indented to `unit` and set `depth` steps in. */
static void put_fragment(char **out, size_t *len, size_t *cap, const char *frag,
                         const char *unit, int depth)
{
	char own[16];
	size_t ownlen;
	const char *p = frag;

	indent_of(frag, own, sizeof own);
	ownlen = strlen(own);
	while (p && *p) {
		const char *eol = strchr(p, '\n');
		size_t n = eol ? (size_t)(eol - p) : strlen(p), lead = 0, d, i;

		while (lead < n && (p[lead] == ' ' || p[lead] == '\t')) lead++;
		while (n > lead && (p[n - 1] == '\r' || p[n - 1] == ' ')) n--;
		if (n > lead) {
			d = own[0] == '\t' ? lead : lead / ownlen;
			for (i = 0; i < d + (size_t)depth; i++)
				put(out, len, cap, unit, strlen(unit));
			put(out, len, cap, p + lead, n - lead);
			put(out, len, cap, "\n", 1);
		}
		p = eol ? eol + 1 : NULL;
	}
}

/* The next definition of a kind after `prev` in name order, or -1. */
static int next_def(const bc_engine *e, int extra, int prev)
{
	int i, best = -1;

	for (i = 0; i < e->nidefs; i++) {
		const bc_itemdef *d = &e->idefs[i];

		if (!d->tree || d->extra != extra)
			continue;
		if (prev >= 0 && strcmp(d->name, e->idefs[prev].name) <= 0)
			continue;
		if (best < 0 || strcmp(d->name, e->idefs[best].name) < 0)
			best = i;
	}
	return best;
}

static int count_lines(const char *s)
{
	int n = 0;

	for (; *s; s++)
		if (*s == '\n') n++;
	return n;
}

/* `base` and the two trees the engine writes, "items" and "extras"
 * (each unless `base` has one of its own), holding definition `only`
 * alone (-1: every one that is ok). `at` (or NULL) gets the line of the
 * text where `only`'s fragment begins. malloc'd. */
static char *with_generated(const bc_engine *e, const char *base, int only, int *at)
{
	char unit[16], line[96];
	char *out = NULL;
	size_t len = 0, cap = 0;
	int i, extra;

	put(&out, &len, &cap, base, strlen(base));
	if (len && out[len - 1] != '\n')
		put(&out, &len, &cap, "\n", 1);
	if (!out)
		return NULL;
	indent_of(base, unit, sizeof unit);
	for (extra = 0; extra < 2; extra++) {
		if (strstr(base, extra ? "tree extras:" : "tree items:"))
			continue;
		put(&out, &len, &cap, extra ? "tree extras:\nseq\n" : "tree items:\nselect\n", extra ? 17 : 19);
		for (i = next_def(e, extra, -1); i >= 0; i = next_def(e, extra, i)) {
			const bc_itemdef *d = &e->idefs[i];

			if (only >= 0 ? i != only : !d->ok)
				continue;
			if (extra) {
				/* each on its own, whatever the others answer */
				snprintf(line, sizeof line, "%salways\n%s%sseq\n", unit, unit, unit);
				put(&out, &len, &cap, line, strlen(line));
			} else {
				/* at once a failure for a bot that holds none */
				snprintf(line, sizeof line, "%sseq\n%s%sif has_item %s\n", unit, unit, unit, d->name);
				put(&out, &len, &cap, line, strlen(line));
			}
			if (at && i == only)
				*at = count_lines(out) + 1;
			put_fragment(&out, &len, &cap, d->tree, unit, extra ? 3 : 2);
		}
		/* so the tree is never empty: items fails, extras succeeds */
		snprintf(line, sizeof line, "%s%s has_item -\n", unit, extra ? "unless" : "if");
		put(&out, &len, &cap, line, strlen(line));
	}
	return out;
}

/* Which fragments compile, each tried alone with `base`. */
static void check_items(bc_engine *e, const char *base)
{
	char err[200];
	int i;

	for (i = 0; i < e->nidefs; i++) {
		bc_itemdef *d = &e->idefs[i];
		const char *what = d->extra ? "extra" : "item";
		char *text;
		bt_forest *f;
		int first = 1;

		d->ok = 0;
		if (!d->tree)
			continue;
		text = with_generated(e, base, i, &first);
		if (!text)
			continue;
		f = bt_compile(e->vocab, text, err, sizeof err);
		if (f) {
			d->ok = 1;
			bt_forest_free(f);
		} else if (!d->said) {
			int line = 0, at = 0;

			d->said = 1;

			/* its line in the fragment, not in the text made round it */
			if (sscanf(err, "line %d:%n", &line, &at) == 1 && at > 0 && line >= first)
				bc_engine_log(e, 2, "%s %s: its tree is left out: line %d:%s",
				              what, d->name, line - first + 1, err + at);
			else
				bc_engine_log(e, 2, "%s %s: its tree is left out: %s", what, d->name, err);
		}
		free(text);
	}
}

static bt_forest *compile_all(bc_engine *e, const char *base, char *err, size_t err_size)
{
	bt_forest *f, *g;
	char *text;
	char err2[200];
	int i;

	/* first with an items tree that holds nothing: a mistake found now is
	 * the trees' own, and its line is the line in `base` */
	for (i = 0; i < e->nidefs; i++)
		e->idefs[i].ok = 0;
	text = with_generated(e, base, -1, NULL);
	if (!text)
		return NULL;
	f = bt_compile(e->vocab, text, err, err_size);
	free(text);
	if (!f)
		return NULL;
	check_items(e, base);
	text = with_generated(e, base, -1, NULL);
	if (!text)
		return f;
	g = bt_compile(e->vocab, text, err2, sizeof err2);
	free(text);
	if (!g) {
		bc_engine_log(e, 2, "the items and extras do not compile with these trees: %s", err2);
		return f;
	}
	bt_forest_free(f);
	return g;
}

/* Leave the tree cleanly: every action RUNNING is told to stop. */
static void bot_leave_tree(bc_bot *b)
{
	bt_ctx c;

	if (b->forest && b->bt) {
		bot_ctx(b, &c, 0.0f);
		bt_reset(b->forest, b->bt, &c);
	}
	b->forest = NULL;
	b->lamp = BC_LAMP_OFF;      /* whoever lit it may be gone with the old trees */
}

/* Point a bot at the tree its settings name, in the forest that has it. */
static void bot_bind(bc_engine *e, bc_bot *b)
{
	const char *name = b->tree_name[0] ? b->tree_name : e->tree_name[0] ? e->tree_name : "default";
	const bt_forest *fs[3], *f = NULL;
	char also[BT_NAME_MAX + 8];
	int i, tree = -1;
	size_t need;

	fs[0] = e->custom; fs[1] = e->builtin; fs[2] = e->fallback;
	if (b->own && (tree = bt_forest_find(b->own, name)) >= 0)
		f = b->own;             /* its own text first */
	for (i = 0; i < 3 && tree < 0; i++)
		if (fs[i] && (tree = bt_forest_find(fs[i], name)) >= 0) f = fs[i];
	for (i = 1; i < 3 && tree < 0; i++)
		if (fs[i] && (tree = bt_forest_find(fs[i], "default")) >= 0) {
			f = fs[i];
			name = "default";
		}
	if (tree < 0)
		return;
	if (f == b->forest && tree == b->tree)
		return;
	bot_leave_tree(b);
	need = bt_state_size(f);
	if (need > b->bt_size) {
		void *m = realloc(b->bt, need);

		if (!m) return;
		b->bt = m;
		b->bt_size = need;
	}
	bt_state_init(b->bt, f);
	bt_state_trace(b->bt, b->watched);      /* a watched bot stays watched in its new tree */
	b->binds++;
	b->forest = f;
	b->tree = tree;
	snprintf(also, sizeof also, "%s_also", name);
	b->tree_also = strlen(also) < BT_NAME_MAX ? bt_forest_find(f, also) : -1;
}

static void bind_all(bc_engine *e)
{
	int i;

	for (i = 0; i < e->max_bots; i++)
		if (e->bots[i].used)
			bot_bind(e, &e->bots[i]);
}

/* Put a new forest in a slot: the bots in the old one leave it first. */
static void swap_forest(bc_engine *e, bt_forest **slot, bt_forest *f)
{
	int i;

	for (i = 0; i < e->max_bots; i++)
		if (e->bots[i].used && e->bots[i].forest == *slot)
			bot_leave_tree(&e->bots[i]);
	if (*slot)
		bt_forest_free(*slot);
	*slot = f;
	bind_all(e);
}

int bc_engine_trees(bc_engine *e, const char *text, char *err, size_t err_size)
{
	bt_forest *f;
	char *copy;

	if (err && err_size) err[0] = 0;
	if (!text)
		return 0;
	f = compile_all(e, text, err, err_size);
	if (!f)
		return 0;               /* and the engine is as it was */
	copy = dup_text(text);
	if (!copy) {
		bt_forest_free(f);
		return 0;
	}
	free(e->base_text);
	e->base_text = copy;
	swap_forest(e, &e->builtin, f);
	return 1;
}

/* The item fragments changed: both forests again. */
static void recompile(bc_engine *e)
{
	char err[200];
	bt_forest *f;

	if (e->base_text) {
		f = compile_all(e, e->base_text, err, sizeof err);
		if (f) swap_forest(e, &e->builtin, f);
	} else {
		f = compile_all(e, FALLBACK_TREES, err, sizeof err);
		if (f) swap_forest(e, &e->fallback, f);
	}
	if (e->custom_text) {
		f = compile_all(e, e->custom_text, err, sizeof err);
		if (f) swap_forest(e, &e->custom, f);
	}
	{
		/* and each bot's own text */
		int i;

		for (i = 0; i < e->max_bots; i++) {
			bc_bot *b = &e->bots[i];

			if (!b->used || !b->own_text)
				continue;
			f = compile_all(e, b->own_text, err, sizeof err);
			if (!f)
				continue;
			bot_leave_tree(b);
			bt_forest_free(b->own);
			b->own = f;
			bot_bind(e, b);
		}
	}
}

/* A bot's own compiled text goes (it leaves it first). */
static void bot_drop_own(bc_bot *b)
{
	if (b->own) {
		if (b->forest == b->own)
			bot_leave_tree(b);
		bt_forest_free(b->own);
		b->own = NULL;
	}
	free(b->own_text);
	b->own_text = NULL;
}

/* ====================================================================== */
/* new, free, map                                                         */

bc_engine *bc_engine_new(const bc_engine_host *host, int max_bots)
{
	bc_engine *e;
	char err[200];
	int i;

	if (max_bots < 1) max_bots = 1;
	if (max_bots > BL_MAX_PLAYERS) max_bots = BL_MAX_PLAYERS;
	e = calloc(1, sizeof *e);
	if (!e)
		return NULL;
	if (host) e->host = *host;
	e->max_bots = max_bots;
	e->bots = calloc((size_t)max_bots, sizeof *e->bots);
	e->turn = calloc((size_t)max_bots, sizeof *e->turn);
	e->map = malloc(sizeof *e->map);
	e->cull = malloc(sizeof *e->cull);
	e->blueprints = calloc(1, sizeof *e->blueprints);
	e->moves = malloc(sizeof *e->moves);
	e->vocab = bt_vocab_new();
	e->nsearch = max_bots / 8;
	if (e->nsearch < 2) e->nsearch = 2;
	if (e->nsearch > BC_SEARCH_MAX) e->nsearch = BC_SEARCH_MAX;
	for (i = 0; i < e->nsearch; i++) {
		e->search_mem[i] = malloc(bc_nav_search_size(SEARCH_NODES));
		e->search_owner[i] = -1;
	}
	if (!e->bots || !e->turn || !e->map || !e->cull || !e->moves || !e->vocab) {
		bc_engine_free(e);
		return NULL;
	}
	for (i = 0; i < e->nsearch; i++) {
		if (!e->search_mem[i]) {
			bc_engine_free(e);
			return NULL;
		}
		e->search[i] = bc_nav_search_init(e->search_mem[i], SEARCH_NODES);
	}
	for (i = 0; i < BL_MAX_PLAYERS; i++)
		e->by_pid[i] = -1;
	for (i = 0; i < max_bots; i++) {
		e->bots[i].e = e;
		e->bots[i].mv.search = -1;
	}
	/* the moves, measured on the map-to-be as a scratch */
	bc_map_clear(e->map);
	bc_nav_moves_measure(e->moves, e->map);
	bc_map_clear(e->map);
	bc_cull_init(e->cull);
	bc_nav_fail_clear(&e->fail);
	bc_nav_protect_clear(&e->protect);
	bc_board_clear(&e->board);
	bc_sense_cfg_default(&e->sense);
	bc_kinds_builtin(&e->kinds_base);
	e->kinds = e->kinds_base;
	e->cull_personality = BC_CULL_OPENSPADES;
	e->spend = 50;
	e->ping_takers = 2;
	e->ping_radius = 40.0f;
	e->plan_greed = 1.5f;
	e->plan_share = 1;
	e->plan_cap = 8000;
	e->lead_per = 5;
	bc_engine_plan_rate(e, BC_PLAN_RATE, 60);
	e->lead_human = 2.0f;
	bc_rng_seed(&e->rng, 0x6c656164, 1);
	memset(e->hurt_by, BL_NO_PLAYER, sizeof e->hurt_by);
	e->hot_at[0] = e->hot_at[1] = -1e9;
	for (i = 0; i < BC_DANGER_MAX; i++)
		e->danger_at[0][i] = e->danger_at[1][i] = -1e9;
	if (!bc_vocab_register(e->vocab))
		bc_engine_log(e, 2, "the vocabulary did not all fit");
	e->fallback = compile_all(e, FALLBACK_TREES, err, sizeof err);
	if (!e->fallback)
		bc_engine_log(e, 2, "the fallback tree does not compile: %s", err);
	return e;
}

void bc_engine_free(bc_engine *e)
{
	int i;

	if (!e)
		return;
	free(e->part.buf);
	if (e->bots)
		for (i = 0; i < e->max_bots; i++) {
			if (e->bots[i].used)
				bot_leave_tree(&e->bots[i]);
			if (e->bots[i].own) bt_forest_free(e->bots[i].own);
			free(e->bots[i].own_text);
			free(e->bots[i].bt);
		}
	if (e->builtin) bt_forest_free(e->builtin);
	if (e->custom) bt_forest_free(e->custom);
	if (e->fallback) bt_forest_free(e->fallback);
	if (e->vocab) bt_vocab_free(e->vocab);
	for (i = 0; i < BC_SEARCH_MAX; i++)
		free(e->search_mem[i]);
	for (i = 0; i < BC_ITEMDEFS_MAX; i++)
		free(e->idefs[i].tree);
	free(e->base_text);
	free(e->custom_text);
	free(e->bots);
	free(e->turn);
	free(e->map);
	free(e->cull);
	if (e->blueprints) {
		bc_blueprints_free(e->blueprints);
		free(e->blueprints);
	}
	free(e->moves);
	free(e);
}

int bc_engine_bots(const bc_engine *e)
{
	int i, n = 0;

	for (i = 0; i < e->max_bots; i++)
		n += e->bots[i].used;
	return n;
}

/* A bot's routes and plans are void (a new map, a death). */
static void bot_forget_route(bc_bot *b)
{
	bc_mover_reset(b);
	b->wish.move = BC_MOVE_NONE;
	b->roam.valid = 0;
	b->cover.valid = 0;
}

int bc_engine_map(bc_engine *e, const uint8_t *vxl, size_t bytes, uint32_t map_seq)
{
	int i, ok = bc_map_load_vxl(e->map, vxl, bytes);

	e->map->cull_personality = e->cull_personality;
	e->have_map = ok;
	e->map_seq = map_seq;
	/* what was learned of the last map goes */
	bc_nav_fail_clear(&e->fail);
	bc_nav_protect_clear(&e->protect);
	bc_board_clear(&e->board);
	bc_routes_clear(&e->routes);
	e->hot_at[0] = e->hot_at[1] = -1e9;
	memset(e->nades, 0, sizeof e->nades);
	e->nnades = 0;
	bc_tactics_map(e);
	memset(e->obj, 0, sizeof e->obj);
	memset(e->lead, 0, sizeof e->lead);
	e->lead_at = 0.0;
	bc_rng_seed(&e->rng, 0x6c656164, map_seq);
	for (i = 0; i < BC_DANGER_MAX; i++)
		e->danger_at[0][i] = e->danger_at[1][i] = -1e9;
	for (i = 0; i < e->max_bots; i++)
		if (e->bots[i].used) {
			bot_forget_route(&e->bots[i]);
			bc_senses_reset(&e->bots[i].senses);
		}
	if (!ok)
		bc_engine_log(e, 2, "map %u is not a map: the bots stand until the next", (unsigned)map_seq);
	else
		bc_engine_log(e, 1, "map %u loaded", (unsigned)map_seq);
	return ok;
}

/* ====================================================================== */
/* bots                                                                   */

static void roll_persona(bc_engine *e, bc_bot *b);

/* A new table of kinds: the mix said before read again over it (a mix
 * naming a kind it has not keeps the old table), every bot drawn again. */
static int use_kinds(bc_engine *e, const bc_kinds *t)
{
	float w[BC_KINDS_MAX];
	int i;

	if (e->have_archetypes && !bc_kinds_weights(t, e->archetypes_text, w)) {
		bc_engine_log(e, 2, "kinds: archetypes=%s names a kind the new table has not: the kinds stay as they were",
		              e->archetypes_text);
		return 0;
	}
	e->kinds = *t;
	if (e->have_archetypes) memcpy(e->archetypes, w, sizeof w);
	for (i = 0; i < e->max_bots; i++)
		if (e->bots[i].used) roll_persona(e, &e->bots[i]);
	return 1;
}

int bc_engine_kinds(bc_engine *e, const char *text, char *err, size_t err_size)
{
	bc_kinds t;

	bc_kinds_builtin(&t);
	if (!bc_kinds_parse(&t, text, err, err_size))
		return 0;
	if (!use_kinds(e, &t)) {
		snprintf(err, err_size, "archetypes=%s names a kind these have not", e->archetypes_text);
		return 0;
	}
	e->kinds_base = t;
	return 1;
}

const char *bc_engine_kind_name(const bc_engine *e, int kind)
{
	return kind >= 0 && kind < e->kinds.n ? e->kinds.k[kind].name : "?";
}

static void roll_persona(bc_engine *e, bc_bot *b)
{
	bc_rng r;

	/* its own stream, so the character is the seed's and the mix's and
	 * can be drawn again when the mix arrives after the bot */
	bc_rng_seed(&r, b->seed, 0x70657273);
	bc_kinds_roll(&e->kinds, &b->persona, &r, e->have_archetypes ? e->archetypes : NULL, b->level);
	{
		/* traits=: the lot leans, each keeps its own roll under it */
		int t;

		for (t = 1; t < BC_T_COUNT; t++) {
			float v = b->persona.trait[t];

			if (e->trait_mul[t] > 0.0f) v *= e->trait_mul[t];
			if (b->trait_mul[t] > 0.0f) v *= b->trait_mul[t];
			b->persona.trait[t] = v < 0.2f ? 0.2f : v > 3.0f ? 3.0f : v;
		}
	}
}

/* "aggression:2,caution:0.5" into factors (0: not named). Names nobody
 * knows are said and left out. */
static void parse_traits(bc_engine *e, const char *val, float *mul)
{
	const char *q = val;
	int t;

	for (t = 0; t < BC_T_COUNT; t++)
		mul[t] = 0.0f;
	while (*q) {
		char name[32];
		size_t n = 0;
		float f = 1.0f;

		while (*q == ' ' || *q == ',') q++;
		while (*q && *q != ':' && *q != ',' && n + 1 < sizeof name) name[n++] = *q++;
		name[n] = 0;
		while (n && name[n - 1] == ' ') name[--n] = 0;
		if (*q == ':') {
			char *end;

			f = (float)strtod(q + 1, &end);
			q = end;
		}
		while (*q && *q != ',') q++;
		if (!n)
			continue;
		t = bc_trait_by_name(name);
		if (t <= 0 || !(f > 0.0f))
			bc_engine_log(e, 2, "traits=: %s: %s", name, t <= 0 ? "no trait of that name" : "its factor must be over 0");
		else
			mul[t] = f;
	}
}

static void bot_new_life(bc_bot *b, const bl_player *p)
{
	bc_aim_v3 ori;
	bt_ctx c;

	b->life = p->life;
	b->alive = 1;
	bc_senses_reset(&b->senses);
	bot_forget_route(b);
	memset(&b->fight, 0, sizeof b->fight);
	b->fight.target = -1;
	b->fight.engage_frac = 0.8f;
	b->fight.kill_at = -1e9;
	if (b->forest && b->bt) {
		bot_ctx(b, &c, 0.0f);
		bt_reset(b->forest, b->bt, &c);
	}
	memset(&b->wish, 0, sizeof b->wish);
	b->wish.fire_pid = b->wish.look_pid = -1;
	b->wish.tool = BL_TOOL_GUN;
	memset(&b->inv, 0, sizeof b->inv);
	memset(&b->nade, 0, sizeof b->nade);
	memset(&b->hold, 0, sizeof b->hold);
	memset(&b->evade, 0, sizeof b->evade);
	memset(&b->guide, 0, sizeof b->guide);
	memset(&b->ping, 0, sizeof b->ping);
	memset(&b->gaze, 0, sizeof b->gaze);
	b->cq.state = 0;
	memset(&b->tc, 0, sizeof b->tc);
	memset(&b->bd, 0, sizeof b->bd);
	memset(&b->cr, 0, sizeof b->cr);
	b->cr.flinched_for = -1e9;
	memset(&b->flank, 0, sizeof b->flank);
	memset(&b->hunt, 0, sizeof b->hunt);
	memset(&b->camp, 0, sizeof b->camp);
	b->camp.perch = b->camp.avoid = -1;
	memset(&b->seek, 0, sizeof b->seek);
	memset(&b->unstick, 0, sizeof b->unstick);
	memset(&b->area, 0, sizeof b->area);
	memset(&b->elsewhere, 0, sizeof b->elsewhere);
	memset(&b->dry, 0, sizeof b->dry);
	memset(&b->carry, 0, sizeof b->carry);
	b->squad.leader = -1;
	b->squad.eval_at = 0.0;
	b->squad.still_since = b->e->now;
	memset(&b->guard, 0, sizeof b->guard);
	memset(&b->fetch, 0, sizeof b->fetch);
	b->area.from = p->pos;
	b->kills = 0;
	b->born_at = b->e->now;
	b->stuck_out_at = -1e9;
	b->following = 0;
	b->follow.leader = -1;
	b->follow.pick_at = 0.0;
	b->cover.since = -1e9;
	b->lamp = BC_LAMP_OFF;
	b->hit = 0;
	b->keys_prev = 0;
	b->reload_pulse = 0;
	b->use_at = 0.0;
	b->anchor = p->pos;
	b->anchor_at = b->e->now;
	/* this life's manner (aosbot's style_* draws) */
	b->style_dodge = bc_rng_range(&b->rng, 0.7f, 1.3f);
	b->style_engage = bc_rng_range(&b->rng, 0.5f, 1.0f);
	b->style_crouch = bc_rng_range(&b->rng, 0.7f, 1.3f);
	b->station_bearing = bc_rng_range(&b->rng, 0.0f, 6.2831853f);
	b->sweep_phase = bc_rng_range(&b->rng, 0.0f, 6.2831853f);
	b->flank_side = bc_rng_float(&b->rng) < 0.5f ? -1 : 1;
	ori.x = p->ori.x; ori.y = p->ori.y; ori.z = p->ori.z;
	if (!b->aim.init)
		bc_aim_init(&b->aim, &b->rng, b->level, ori);
	else
		bc_aim_snap(&b->aim, ori);      /* a new body faces the way it is put */
}

static void bot_died(bc_bot *b)
{
	bt_ctx c;

	b->alive = 0;
	bot_forget_route(b);
	bc_tactics_bot_gone(b);
	if (b->forest && b->bt) {
		bot_ctx(b, &c, 0.0f);
		bt_reset(b->forest, b->bt, &c);
	}
	b->fight.target = -1;
}

static void ev_bot(bc_engine *e, int pid, const bl_ev_bot *ev)
{
	bc_bot *b = bc_engine_bot(e, pid);
	int i;

	if (b && b->seed == ev->seed && b->level == ev->level && b->gun == ev->gun)
		return;                 /* told again (a new map, an engine back) */
	if (!b) {
		for (i = 0; i < e->max_bots && e->bots[i].used; i++)
			;
		if (i == e->max_bots) {
			bc_engine_log(e, 2, "bot #%d: no room: the engine is sized for %d bots (botd --bots); "
			              "this one will stand still", pid, e->max_bots);
			return;
		}
		b = &e->bots[i];
		e->by_pid[pid] = (int16_t)i;
	} else {
		bot_leave_tree(b);
		bc_engine_search_release(e, b);
		bot_drop_own(b);
	}
	{
		bt_state *bt = b->bt;
		size_t bt_size = b->bt_size;

		memset(b, 0, sizeof *b);
		b->bt = bt;
		b->bt_size = bt_size;
		b->e = e;
		b->used = 1;
		b->pid = (uint8_t)pid;
		b->level = ev->level < 1 ? 1 : ev->level > 10 ? 10 : ev->level;
		b->gun = ev->gun;
		b->seed = ev->seed;
		b->edit = -1;
		b->mv.search = -1;
		b->fight.target = -1;
		b->follow.leader = -1;
		b->camp.perch = b->camp.avoid = -1;
	}
	bc_rng_seed(&b->rng, b->seed, 0x62726169);
	roll_persona(e, b);
	bot_bind(e, b);
	bc_engine_log(e, 1, "bot #%d: %s, level %d", pid, bc_engine_kind_name(e, b->persona.archetype), b->level);
}

static void ev_unbot(bc_engine *e, int pid)
{
	bc_bot *b = bc_engine_bot(e, pid);

	if (!b)
		return;
	bot_leave_tree(b);
	bc_engine_search_release(e, b);
	bc_tactics_bot_gone(b);
	bot_drop_own(b);
	b->used = 0;
	b->alive = 0;
	e->by_pid[pid] = -1;
}

/* ====================================================================== */
/* settings                                                               */

static void keep_setting(bc_engine *e, const char *key, const char *val)
{
	int i;

	if (strlen(key) >= sizeof e->settings[0].key)
		return;
	for (i = 0; i < e->nsettings && strcmp(e->settings[i].key, key); i++)
		;
	if (i == e->nsettings) {
		if (i == BC_SETTINGS_MAX)
			return;
		e->nsettings++;
		strcpy(e->settings[i].key, key);
	}
	snprintf(e->settings[i].val, sizeof e->settings[i].val, "%s", val);
}

static void set_item(bc_engine *e, bc_bot *only, const char *key, const char *val, int extra)
{
	char name[16];
	const char *dot = strchr(key, '.');
	size_t n = dot ? (size_t)(dot - key) : strlen(key);
	bc_itemdef *d = NULL;
	int i;

	if (n == 0 || n >= sizeof name)
		return;
	memcpy(name, key, n);
	name[n] = 0;
	if (!dot && extra)
		return;
	if (!dot) {
		/* a count */
		int count = !strcmp(val, "inf") ? -1 : atoi(val);

		for (i = 0; i < e->max_bots; i++) {
			bc_bot *b = &e->bots[i];
			bc_item *it;

			if (!b->used || (only && b != only))
				continue;
			it = bc_item_find(b, name, count != 0);
			if (it) it->count = count;
		}
		return;
	}
	for (i = 0; i < e->nidefs; i++)
		if (!strcmp(e->idefs[i].name, name) && e->idefs[i].extra == extra) d = &e->idefs[i];
	if (!d) {
		if (e->nidefs == BC_ITEMDEFS_MAX) {
			bc_engine_log(e, 2, "%s: too many items and extras (%d)", name, BC_ITEMDEFS_MAX);
			return;
		}
		d = &e->idefs[e->nidefs++];
		memset(d, 0, sizeof *d);
		strcpy(d->name, name);
		d->extra = (uint8_t)extra;
	}
	if (!strcmp(dot, ".guide")) {
		d->guide = (float)atof(val);
	} else if (!strcmp(dot, ".tree")) {
		if (d->tree && !strcmp(d->tree, val))
			return;
		free(d->tree);
		d->tree = val[0] ? dup_text(val) : NULL;
		d->said = 0;
		recompile(e);
	}
}

static void set_tree(bc_engine *e, bc_bot *b, const char *val)
{
	char name[BT_NAME_MAX] = "";

	if (b) {
		/* ONE BOT'S OWN TREE: a name, its own text, or (empty) the world's again */
		if (strchr(val, '\n')) {
			const char *h = strncmp(val, "tree ", 5) ? strstr(val, "\ntree ") : val;
			char err[200];
			bt_forest *f = compile_all(e, val, err, sizeof err);
			char *text;

			if (!f) {
				bc_engine_log(e, 2, "bot #%d: tree= does not compile, it keeps its tree: %s", b->pid, err);
				return;
			}
			text = dup_text(val);
			if (!text) {
				bt_forest_free(f);
				return;
			}
			bot_drop_own(b);
			b->own = f;
			b->own_text = text;
			strcpy(name, "main");
			if (h) {
				size_t n;

				h += h == val ? 5 : 6;
				n = strcspn(h, ":\n");
				if (n > 0 && n < sizeof name) {
					memcpy(name, h, n);
					name[n] = 0;
				}
			}
			strcpy(b->tree_name, name);
			bot_bind(e, b);
			return;
		}
		bot_drop_own(b);
		if (strlen(val) < sizeof name)
			strcpy(name, val);
		if (name[0] && !(e->custom && bt_forest_find(e->custom, name) >= 0) &&
		    !(e->builtin && bt_forest_find(e->builtin, name) >= 0)) {
			bc_engine_log(e, 1, "bot #%d: tree=%s: no tree of that name, it runs the world's", b->pid, name);
			name[0] = 0;
		}
		strcpy(b->tree_name, name);
		bot_bind(e, b);
		return;
	}
	if (strchr(val, '\n')) {
		/* the text of trees: the first one in it is the one run */
		const char *h = strncmp(val, "tree ", 5) ? strstr(val, "\ntree ") : val;
		char err[200];
		bt_forest *f = compile_all(e, val, err, sizeof err);

		if (!f) {
			bc_engine_log(e, 2, "tree= does not compile, the old one stays: %s", err);
			return;
		}
		free(e->custom_text);
		e->custom_text = dup_text(val);
		strcpy(name, "main");
		if (h) {
			size_t n;

			h += h == val ? 5 : 6;
			n = strcspn(h, ":\n");
			if (n > 0 && n < sizeof name) {
				memcpy(name, h, n);
				name[n] = 0;
			}
		}
		if (b) strcpy(b->tree_name, name);
		else strcpy(e->tree_name, name);
		swap_forest(e, &e->custom, f);
		return;
	}
	if (strlen(val) < sizeof name)
		strcpy(name, val);
	if (b) strcpy(b->tree_name, name);
	else strcpy(e->tree_name, name);
	bind_all(e);
	if (name[0] && !(e->custom && bt_forest_find(e->custom, name) >= 0) &&
	    !(e->builtin && bt_forest_find(e->builtin, name) >= 0))
		bc_engine_log(e, 1, "tree=%s: no tree of that name, the bots run \"default\"", name);
}

/* ---- THE BRIDGE: what a server script tells the trees ----------------- */

/* A name: letters, digits, _. For the world's facts and places it may end
 * in a TEAM SCOPE, "@1" or "@2": the bots of that team read it under the
 * name before the "@" (bc_fact_get, bc_splace_get) -- what a mode with
 * one of a thing for each team (a stair, a base of its own) tells once
 * for the team, not once for every bot (a bot holds few of its own). */
static int bridge_name_ok(const char *name, int world)
{
	size_t i, n = strlen(name);

	if (n == 0 || n >= BC_BRIDGE_NAME)
		return 0;
	if (world && n > 2 && name[n - 2] == '@' && (name[n - 1] == '1' || name[n - 1] == '2'))
		n -= 2;
	for (i = 0; i < n; i++) {
		char c = name[i];

		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'))
			return 0;
	}
	return 1;
}

/* fact.<name>=<number>, for everybody or for one bot; empty: forgotten */
static void set_fact(bc_engine *e, bc_bot *b, const char *name, const char *val)
{
	bc_fact *t = b ? b->facts : e->facts, *slot = NULL;
	int n = b ? BC_BOT_FACTS_MAX : BC_FACTS_MAX, i;
	char *end;
	double v;

	if (!bridge_name_ok(name, b == NULL)) {
		bc_engine_log(e, 2, "fact.%.40s=: not a name (letters, digits, _, for the world @1 or @2 at the end; %d at most): ignored", name, BC_BRIDGE_NAME - 1);
		return;
	}
	for (i = 0; i < n; i++) {
		if (!strcmp(t[i].name, name)) { slot = &t[i]; break; }
		if (!slot && !t[i].name[0]) slot = &t[i];
	}
	if (!val[0]) {                          /* forgotten */
		if (i < n) memset(&t[i], 0, sizeof t[i]);
		return;
	}
	v = strtod(val, &end);
	if (end == val || !(v == v)) {
		bc_engine_log(e, 2, "fact.%s=%.40s: not a number: ignored", name, val);
		return;
	}
	if (!slot) {
		bc_engine_log(e, 2, "fact.%s=: no room for another fact (%d %s): ignored", name, n, b ? "a bot" : "for the world");
		return;
	}
	strcpy(slot->name, name);
	slot->value = (float)v;
}

/* place.<name>="x y z" or "pid <n>", for everybody or for one bot; empty: forgotten */
static void set_splace(bc_engine *e, bc_bot *b, const char *name, const char *val)
{
	bc_splace *t = b ? b->places : e->places, *slot = NULL;
	int n = b ? BC_BOT_SPLACES_MAX : BC_SPLACES_MAX, i, pid = -1;
	float x, y, z;

	if (!bridge_name_ok(name, b == NULL)) {
		bc_engine_log(e, 2, "place.%.40s=: not a name (letters, digits, _, for the world @1 or @2 at the end; %d at most): ignored", name, BC_BRIDGE_NAME - 1);
		return;
	}
	for (i = 0; i < n; i++) {
		if (!strcmp(t[i].name, name)) { slot = &t[i]; break; }
		if (!slot && !t[i].name[0]) slot = &t[i];
	}
	if (!val[0]) {
		if (i < n) memset(&t[i], 0, sizeof t[i]);
		return;
	}
	if (sscanf(val, "pid %d", &pid) == 1) {
		if (pid < 0 || pid >= BL_MAX_PLAYERS || pid == BL_NO_PLAYER) pid = -2;
	} else if (sscanf(val, "%f %f %f", &x, &y, &z) != 3 || !(x == x) || !(y == y) || !(z == z)) {
		pid = -2;
	}
	if (pid == -2) {
		bc_engine_log(e, 2, "place.%s=%.40s: neither \"x y z\" nor \"pid <n>\": ignored", name, val);
		return;
	}
	if (!slot) {
		bc_engine_log(e, 2, "place.%s=: no room for another place (%d %s): ignored", name, n, b ? "a bot" : "for the world");
		return;
	}
	memset(slot, 0, sizeof *slot);
	strcpy(slot->name, name);
	if (pid >= 0) { slot->follows = 1; slot->pid = (uint8_t)pid; }
	else { slot->pos.x = x; slot->pos.y = y; slot->pos.z = z; }
}

/* "<name>@<its team>": the world's name for a team's own (bridge_name_ok) */
static void team_name(const bc_bot *b, const char *name, char out[BC_BRIDGE_NAME + 2])
{
	int team = bc_me(b)->team;

	out[0] = 0;
	if ((team == 1 || team == 2) && strlen(name) + 2 < BC_BRIDGE_NAME)
		snprintf(out, BC_BRIDGE_NAME + 2, "%s@%d", name, team);
}

/* its own, its team's, the world's */
int bc_fact_get(const bc_bot *b, const char *name, float *out)
{
	const bc_engine *e = b->e;
	char tn[BC_BRIDGE_NAME + 2];
	int i, pass;

	for (i = 0; i < BC_BOT_FACTS_MAX; i++)
		if (b->facts[i].name[0] && !strcmp(b->facts[i].name, name)) { *out = b->facts[i].value; return 1; }
	team_name(b, name, tn);
	for (pass = 0; pass < 2; pass++)
		for (i = 0; i < BC_FACTS_MAX; i++)
			if (e->facts[i].name[0] && !strcmp(e->facts[i].name, pass ? name : tn)) { *out = e->facts[i].value; return 1; }
	return 0;
}

int bc_splace_get(const bc_bot *b, const char *name, bl_vec3 *out)
{
	const bc_engine *e = b->e;
	const bc_splace *p = NULL;
	char tn[BC_BRIDGE_NAME + 2];
	int i, pass;

	for (i = 0; i < BC_BOT_SPLACES_MAX && !p; i++)
		if (b->places[i].name[0] && !strcmp(b->places[i].name, name)) p = &b->places[i];
	team_name(b, name, tn);
	for (pass = 0; pass < 2 && !p; pass++)
		for (i = 0; i < BC_SPLACES_MAX && !p; i++)
			if (e->places[i].name[0] && !strcmp(e->places[i].name, pass ? name : tn)) p = &e->places[i];
	if (!p)
		return 0;
	if (p->follows) {
		if (e->w.players[p->pid].state != BL_ALIVE) return 0;
		*out = e->w.players[p->pid].pos;
	} else {
		*out = p->pos;
	}
	return 1;
}

static void ev_set(bc_engine *e, int pid, const char *text);

/* A piece of a setting too long for one record (its `+` taken off):
 * "key#total=first piece", "key=next piece" as often as needed, and
 * "key!=last piece". The whole is applied only when its length is the
 * total said: a piece lost, pieces of another setting or for another
 * bot coming in between, an end with no beginning -- refused and said. */
enum { PART_MAX = 1 << 16 };

static void part_add(bc_engine *e, int pid, const char *text)
{
	const char *eq = strchr(text, '='), *mark;
	char key[64];
	size_t n, kn;
	int first, last;

	if (!eq || eq == text)
		return;
	mark = eq;
	while (mark > text && mark[-1] != '#' && mark[-1] != '!' && mark[-1] >= '0' && mark[-1] <= '9') mark--;
	first = mark > text && mark[-1] == '#';
	last = eq[-1] == '!';
	kn = (size_t)((first ? mark : eq) - text) - (size_t)(first || last);
	if (kn == 0 || kn >= sizeof key)
		return;
	memcpy(key, text, kn);
	key[kn] = 0;
	if (!e->part.buf && !(e->part.buf = malloc(PART_MAX + sizeof key + 2)))
		return;
	if (first) {                /* it says how long the whole is */
		if (e->part.active && !e->part.bad)
			bc_engine_log(e, 2, "%s=: a long value was cut short (%d of %d bytes came): ignored", e->part.key,
			              (int)e->part.len, (int)e->part.want);
		e->part.active = 1;
		e->part.bad = 0;
		e->part.pid = pid;
		e->part.len = 0;
		e->part.want = (size_t)strtoul(mark, NULL, 10);
		strcpy(e->part.key, key);
		if (e->part.want > PART_MAX) {
			bc_engine_log(e, 2, "%s=: %d bytes is too long a value (the most is %d): ignored", key, (int)e->part.want, PART_MAX);
			e->part.bad = 1;
		}
	} else if (!e->part.active || e->part.pid != pid || strcmp(e->part.key, key)) {
		if (last)
			bc_engine_log(e, 2, "%s=: the end of a long value came without its beginning: ignored", key);
		return;
	}
	n = strlen(eq + 1);
	if (!e->part.bad && e->part.len + n <= e->part.want) {
		size_t head = strlen(e->part.key) + 1;

		if (e->part.len == 0)
			snprintf(e->part.buf, sizeof key + 2, "%s=", e->part.key);
		memcpy(e->part.buf + head + e->part.len, eq + 1, n + 1);
		e->part.len += n;
	} else if (!e->part.bad) {
		e->part.len += n;       /* more than it said: counted, and refused below */
	}
	if (!last)
		return;
	e->part.active = 0;
	if (e->part.bad)
		return;
	if (e->part.len != e->part.want) {
		bc_engine_log(e, 2, "%s=: a long value was cut short (%d of %d bytes came): ignored", e->part.key,
		              (int)e->part.len, (int)e->part.want);
		return;
	}
	ev_set(e, pid, e->part.buf);
}

static void ev_set(bc_engine *e, int pid, const char *text)
{
	char key[64];
	const char *eq, *val;
	bc_bot *b = pid == BL_NO_PLAYER ? NULL : bc_engine_bot(e, pid);
	size_t n;
	int i;

	if (text[0] == '+') {
		part_add(e, pid, text + 1);
		return;
	}
	eq = strchr(text, '=');

	if (!eq || eq == text || (size_t)(eq - text) >= sizeof key)
		return;
	if (pid != BL_NO_PLAYER && !b)
		return;
	n = (size_t)(eq - text);
	memcpy(key, text, n);
	key[n] = 0;
	val = eq + 1;
	if (!strncmp(key, "item.", 5)) {
		set_item(e, b, key + 5, val, 0);
		return;
	}
	if (!strncmp(key, "extra.", 6)) {
		if (!b) set_item(e, NULL, key + 6, val, 1);
		return;
	}
	if (!strncmp(key, "fact.", 5)) {
		set_fact(e, b, key + 5, val);
		return;
	}
	if (!strncmp(key, "place.", 6)) {
		set_splace(e, b, key + 6, val);
		return;
	}
	if (!strncmp(key, "blueprint.", 10) && !b) {
		/* a structure to build (blueprint.h): the world's, or a team's */
		char err[120];

		if (!e->blueprints || !bc_blueprint_set(e->blueprints, key + 10, val, err, sizeof err))
			bc_engine_log(e, 2, "blueprint.%.30s: %s: ignored", key + 10, e->blueprints ? err : "no memory");
		return;
	}
	if (!strcmp(key, "tree")) {
		set_tree(e, b, val);
		return;
	}
	if (!strcmp(key, "edit")) {
		int v = !strcmp(val, "dig") ? 1 : !strcmp(val, "build") ? 2 : !strcmp(val, "all") ? 3 : 0;

		if (b) b->edit = (int8_t)v;
		else { e->may_dig = v & 1; e->may_build = (v >> 1) & 1; }
		memset(e->unreach, 0, sizeof e->unreach);   /* what had no way may have one now */
		return;
	}
	if (!strcmp(key, "traits")) {
		if (b) parse_traits(e, val, b->trait_mul);
		else parse_traits(e, val, e->trait_mul);
		for (i = 0; i < e->max_bots; i++)
			if (e->bots[i].used && (!b || b == &e->bots[i]))
				roll_persona(e, &e->bots[i]);
		return;
	}
	if (!strcmp(key, "name")) {
		if (b) snprintf(b->name, sizeof b->name, "%s", val);
		return;
	}
	if (!strcmp(key, "night_vision")) {
		for (i = 0; i < e->max_bots; i++)
			if (e->bots[i].used && (!b || b == &e->bots[i]))
				e->bots[i].night_vision = atoi(val) != 0;
		return;
	}
	if (b)
		return;                 /* the rest are for everybody */
	if (!strcmp(key, "cull")) {
		e->cull_personality = !strcmp(val, "voxlap") ? BC_CULL_VOXLAP : BC_CULL_OPENSPADES;
		e->map->cull_personality = e->cull_personality;
	} else if (!strcmp(key, "archetypes")) {
		float w[BC_KINDS_MAX];

		if (strlen(val) >= sizeof e->archetypes_text || !bc_kinds_weights(&e->kinds, val, w)) {
			bc_engine_log(e, 2, "archetypes=%s: a name nobody knows", val);
			return;
		}
		snprintf(e->archetypes_text, sizeof e->archetypes_text, "%s", val);
		memcpy(e->archetypes, w, sizeof w);
		e->have_archetypes = val[0] != 0;
		for (i = 0; i < e->max_bots; i++)
			if (e->bots[i].used) roll_persona(e, &e->bots[i]);
	} else if (!strcmp(key, "archetype_table")) {
		/* the kinds of player as data, from a script: read over the files' */
		bc_kinds t = e->kinds_base;
		char err[160];

		if (!bc_kinds_parse(&t, val, err, sizeof err))
			bc_engine_log(e, 2, "archetype_table: %s: the kinds stay as they were", err);
		else
			use_kinds(e, &t);
	} else if (bc_sense_cfg_set(&e->sense, key, (float)atof(val))) {
		;
	} else if (!strcmp(key, "spend")) {
		e->spend = atoi(val);
	} else if (!strcmp(key, "water")) {
		e->water_lethal = !strcmp(val, "lethal");
		memset(e->unreach, 0, sizeof e->unreach);
	} else if (!strcmp(key, "fire")) {
		e->hold_fire = !strcmp(val, "hold");
	} else if (!strcmp(key, "water.damage")) {
		e->water_damage = (float)atof(val);
		if (!(e->water_damage > 0.0f)) e->water_damage = 0.0f;
		memset(e->unreach, 0, sizeof e->unreach);
	} else if (!strcmp(key, "leaders.per")) {
		e->lead_per = atoi(val);
		e->lead_at = 0.0;
	} else if (!strcmp(key, "leaders.human")) {
		e->lead_human = (float)atof(val);
		if (!(e->lead_human >= 0.0f)) e->lead_human = 0.0f;
	} else if (!strcmp(key, "plan.greed")) {
		e->plan_greed = (float)atof(val);
	} else if (!strcmp(key, "plan.cap")) {
		e->plan_cap = atoi(val);
	} else if (!strcmp(key, "plan.wait")) {
		e->plan_stand = !strcmp(val, "stand");
	} else if (!strcmp(key, "plan.share")) {
		e->plan_share = (uint8_t)(atoi(val) != 0);
	} else if (!strcmp(key, "gaze")) {
		e->gaze_off = !atoi(val);
	} else if (!strcmp(key, "ping_takers")) {
		e->ping_takers = atoi(val);
	} else if (!strcmp(key, "ping_radius")) {
		e->ping_radius = (float)atof(val);
	} else if (!strcmp(key, "zone")) {
		/* the whole list, each set: rectangles separated by ";" (one
		 * setting a key: what lib_botlink keeps and sends again to an
		 * engine that comes back is all of it) */
		const char *r = val;

		e->nzones = 0;
		while (r && *r && strcmp(r, "clear")) {
			int x0, y0, x1, y1;
			const char *end = strchr(r, ';');
			char one[96];
			size_t len = end ? (size_t)(end - r) : strlen(r);

			if (len >= sizeof one) len = sizeof one - 1;
			memcpy(one, r, len);
			one[len] = 0;
			if (sscanf(one, "%d %d %d %d", &x0, &y0, &x1, &y1) == 4 && e->nzones < BC_ZONES_MAX) {
				bc_nav_zone *z = &e->zones[e->nzones++];
				int nd = strstr(one, "nodig") != NULL, nb = strstr(one, "nobuild") != NULL, team = 0;
				const char *t = strstr(one, "team ");

				if (t) team = atoi(t + 5);
				memset(z, 0, sizeof *z);
				z->team = (uint8_t)(team == 1 || team == 2 ? team : 0);
				z->x0 = (int16_t)(x0 < x1 ? x0 : x1); z->x1 = (int16_t)(x0 < x1 ? x1 : x0);
				z->y0 = (int16_t)(y0 < y1 ? y0 : y1); z->y1 = (int16_t)(y0 < y1 ? y1 : y0);
				z->no_dig = (uint8_t)(nd || !nb);
				z->no_build = (uint8_t)(nb || !nd);
			} else {
				bc_engine_log(e, 2, "zone: \"%.60s\" is not \"x0 y0 x1 y1 [nodig] [nobuild] [team N]\" (or no room, %d at most): ignored", one, BC_ZONES_MAX);
			}
			r = end ? end + 1 : NULL;
			while (r && *r == ' ') r++;
		}
	} else if (!strcmp(key, "protect")) {
		int x, y, z;

		if (sscanf(val, "%d %d %d", &x, &y, &z) == 3)
			bc_nav_protect_add(&e->protect, x, y, z);
	} else if (!bc_engine_setting(e, key)) {
		/* not the engine's: a gamemode's own, for its tree to read */
		bc_engine_log(e, 1, "setting %s: not one the engine knows; kept for a tree's `if setting %s`", key, key);
	}
	keep_setting(e, key, val);
}

/* ====================================================================== */
/* events                                                                 */

static void noise_for_all(bc_engine *e, int kind, bl_vec3 pos, int by)
{
	int i;

	if (!e->have_world)
		return;
	for (i = 0; i < e->max_bots; i++) {
		bc_bot *b = &e->bots[i];

		if (b->used && b->alive)
			bc_senses_hear(&b->senses, &e->sense, &e->w, b->pid, b->level, kind, pos, by, e->now);
	}
}

/* The map changed inside a box: routes through it are looked at again
 * (the follower does that on any change), and one that crossed a
 * COLLAPSE is planned again at once -- the follower checks the steps,
 * not that the ground a step lands on is still held up from below. */
static void map_changed(bc_engine *e, const bc_map_change *c)
{
	int i, k;

	if (c->collapsed <= 0)
		return;
	{
		bl_vec3 at;

		at.x = 0.5f * (float)(c->x0 + c->x1) + 0.5f;
		at.y = 0.5f * (float)(c->y0 + c->y1) + 0.5f;
		at.z = 0.5f * (float)(c->z0 + c->z1) + 0.5f;
		noise_for_all(e, BL_S_BLAST, at, BL_NO_PLAYER);     /* a collapse is heard */
	}
	for (i = 0; i < e->max_bots; i++) {
		bc_bot *b = &e->bots[i];

		if (!b->used || !b->mv.has_route)
			continue;
		for (k = b->mv.follow.step < 0 ? 0 : b->mv.follow.step; k < b->mv.route.n; k++) {
			const bc_nav_node *n = &b->mv.route.steps[k].to;

			if (n->x >= c->x0 - 1 && n->x <= c->x1 + 1 && n->y >= c->y0 - 1 && n->y <= c->y1 + 1 &&
			    n->z >= c->z0 - 1 && n->z <= c->z1 + 4) {
				b->mv.has_route = 0;
				if (b->mv.state == BC_MV_FOLLOWING) {
					b->mv.state = BC_MV_PLANNING;
					b->mv.plan_since = e->now;
					b->mv.again = 1;
					e->stats.replans++;
				}
				break;
			}
		}
	}
}

static void ev_ping(bc_engine *e, int by, const bl_ev_ping *ev)
{
	char reason[65];
	int team, kind, taken = 0, round;
	bc_ping *pg;

	if (by == BL_NO_PLAYER || !e->have_world)
		return;
	team = e->w.players[by].team;
	memcpy(reason, ev->reason, 64);
	reason[64] = 0;
	kind = bc_ping_kind(reason);
	if (kind == BC_PING_NONE || team < 1 || team > 2)
		return;
	pg = bc_board_ping(&e->board, team, by, ev->pos, kind, e->now,
	                   kind == BC_PING_ENEMY ? 15.0 : kind == BC_PING_HELP ? 30.0 : 20.0);
	if (!pg)
		return;
	/* The nearest few answer, not everybody (aosbot: 2 within 40), and
	 * a bot is "nearer" the keener it is on teamwork; one with little
	 * of it does not answer at all, and one busy with a ping stays on it. */
	for (round = 0; round < e->ping_takers; round++) {
		bc_bot *best = NULL;
		float bd = 1e30f;
		int i;

		for (i = 0; i < e->max_bots; i++) {
			bc_bot *b = &e->bots[i];
			const bl_player *p;
			float dx, dy, d, tw;

			if (!b->used || !b->alive || b->pid == by)
				continue;
			p = &e->w.players[b->pid];
			tw = b->persona.trait[BC_T_TEAMWORK];
			if (p->team != team || tw < 0.7f || (b->ping.taken && e->now < b->ping.until))
				continue;
			dx = p->pos.x - ev->pos.x; dy = p->pos.y - ev->pos.y;
			d = sqrtf(dx * dx + dy * dy);
			if (d > e->ping_radius)
				continue;
			d /= tw;
			if (d < bd) { bd = d; best = b; }
		}
		if (!best)
			break;
		best->ping.taken = pg->id;
		best->ping.pos = ev->pos;
		best->ping.kind = (uint8_t)kind;
		best->ping.by = (uint8_t)by;
		best->ping.until = pg->until;
		best->jolt = 1;
		taken++;
	}
	pg->takers = (uint8_t)taken;
}

void bc_engine_event(bc_engine *e, const bl_record *rec)
{
	const void *pl = rec + 1;
	size_t n = rec->size >= sizeof *rec ? rec->size - sizeof *rec : 0;
	int pid = rec->pid;

	switch (rec->type) {
	case BL_EV_BLOCK: {
		bl_ev_block ev;
		bc_map_change c;

		if (n < sizeof ev || !e->have_map) break;
		memcpy(&ev, pl, sizeof ev);
		bc_map_change_init(&c, e->chg_cells, BC_CHANGE_CELLS);
		bc_map_apply(e->map, e->cull, ev.action, ev.x, ev.y, ev.z, &c);
		map_changed(e, &c);
		break;
	}
	case BL_EV_LINE: {
		bl_ev_line ev;

		if (n < sizeof ev || !e->have_map) break;
		memcpy(&ev, pl, sizeof ev);
		if (bc_map_in(ev.x1, ev.y1, ev.z1) && bc_map_in(ev.x2, ev.y2, ev.z2))
			bc_map_line(e->map, ev.x1, ev.y1, ev.z1, ev.x2, ev.y2, ev.z2, NULL);
		break;
	}
	case BL_EV_KILL: {
		int team, i, old = 0;

		if (pid == BL_NO_PLAYER || !e->have_world) break;
		team = e->w.players[pid].team;
		if (team < 1 || team > 2) break;
		bc_leaders_died(e, pid);
		/* where a team's man died is a place its routes shy from (aosbot) */
		for (i = 1; i < BC_DANGER_MAX; i++)
			if (e->danger_at[team - 1][i] < e->danger_at[team - 1][old]) old = i;
		e->danger[team - 1][old].x = e->w.players[pid].pos.x;
		e->danger[team - 1][old].y = e->w.players[pid].pos.y;
		e->danger[team - 1][old].radius = 9.0f;
		e->danger[team - 1][old].weight = 3.0f;
		e->danger_at[team - 1][old] = e->now;
		e->board.spot[2 - team][pid].at = e->board.spot[2 - team][pid].since = -1e9;
		{
			bl_ev_kill ev;
			bc_bot *kb;

			if (n < sizeof ev) break;
			memcpy(&ev, pl, sizeof ev);
			kb = ev.killer != pid ? bc_engine_bot(e, ev.killer) : NULL;
			if (kb && kb->alive) kb->kills++;
			/* a man dropping beside a bot tells it it is under fire */
			if (ev.killer != BL_NO_PLAYER && e->w.players[ev.killer].team != team)
				for (i = 0; i < e->max_bots; i++) {
					bc_bot *b = &e->bots[i];
					const bl_player *m;
					float dx, dy;

					if (!b->used || !b->alive || b->pid == pid) continue;
					m = &e->w.players[b->pid];
					if (m->team != team) continue;
					dx = m->pos.x - e->w.players[pid].pos.x; dy = m->pos.y - e->w.players[pid].pos.y;
					if (dx * dx + dy * dy > 12.0f * 12.0f) continue;
					bc_senses_shot_at(&b->senses, &b->rng, &e->w, b->pid, b->level,
					                  e->w.players[ev.killer].pos, ev.killer, 2, e->now);
					if (b->senses.fire_since == e->now) b->jolt = 1;
				}
		}
		break;
	}
	case BL_EV_HURT: {
		bl_ev_hurt ev;
		bc_bot *b = bc_engine_bot(e, pid);

		if (n >= sizeof ev && pid != BL_NO_PLAYER) {
			memcpy(&ev, pl, sizeof ev);
			e->hurt_by[pid] = ev.by;
			e->hurt_at[pid] = e->now;
		}
		if (n < sizeof ev || !b || !b->alive || !e->have_world) break;
		memcpy(&ev, pl, sizeof ev);
		bc_senses_hurt(&b->senses, &b->rng, &e->w, pid, b->level, ev.from, ev.by, e->now);
		b->hit = 1;
		b->hit_from = ev.from;
		b->hit_from_valid = b->senses.threat.valid && b->senses.threat.at == e->now;
		if (b->senses.n_visible == 0 || b->senses.fire_since == e->now)
			b->jolt = 1;            /* hit from nowhere, or the first of a burst */
		break;
	}
	case BL_EV_SOUND: {
		bl_ev_sound ev;

		if (n < sizeof ev) break;
		memcpy(&ev, pl, sizeof ev);
		noise_for_all(e, ev.kind, ev.pos, pid);
		/* a round that passes close is being shot at, hit or not */
		if (ev.kind == BL_S_SHOT && pid != BL_NO_PLAYER && e->have_world) {
			int i;

			for (i = 0; i < e->max_bots; i++) {
				bc_bot *b = &e->bots[i];

				if (!b->used || !b->alive || !bc_senses_near_miss(&e->w, b->pid, pid, 2.5f))
					continue;
				bc_senses_shot_at(&b->senses, &b->rng, &e->w, b->pid, b->level, ev.pos, pid, 1, e->now);
				if (b->senses.fire_since == e->now) b->jolt = 1;
			}
		}
		break;
	}
	case BL_EV_GRENADE: {
		bl_ev_grenade ev;
		int i, slot = -1;

		if (n < sizeof ev || pid == BL_NO_PLAYER || !e->have_world) break;
		memcpy(&ev, pl, sizeof ev);
		/* a slot burst already, else a new one; with every one live (more
		 * than three a player: a restock between throws) the one to burst
		 * first gives way, said */
		for (i = 0; i < e->nnades && slot < 0; i++)
			if (!e->nades[i].valid || e->nades[i].at < e->now) slot = i;
		if (slot < 0 && e->nnades < BC_GRENADES_MAX)
			slot = e->nnades++;
		if (slot < 0) {
			for (slot = 0, i = 1; i < BC_GRENADES_MAX; i++)
				if (e->nades[i].at < e->nades[slot].at) slot = i;
			bc_engine_log(e, 2, "grenade of #%d: %d live already; the one to burst first is forgotten",
			              pid, BC_GRENADES_MAX);
		}
		e->nades[slot].burst = bc_grenade_fly(e->have_map ? e->map : NULL, ev.pos, ev.vel, ev.fuse);
		e->nades[slot].born = e->now;
		e->nades[slot].at = e->now + (double)ev.fuse;
		e->nades[slot].team = e->w.players[pid].team;
		e->nades[slot].valid = 1;
		break;
	}
	case BL_EV_PING: {
		bl_ev_ping ev;

		if (n < sizeof ev) break;
		memcpy(&ev, pl, sizeof ev);
		ev_ping(e, pid, &ev);
		break;
	}
	case BL_EV_BOT: {
		bl_ev_bot ev;

		if (n < sizeof ev || pid == BL_NO_PLAYER) break;
		memcpy(&ev, pl, sizeof ev);
		ev_bot(e, pid, &ev);
		break;
	}
	case BL_EV_UNBOT:
		ev_unbot(e, pid);
		break;
	case BL_EV_SET: {
		char text[BL_RECORD_MAX];

		if (n == 0 || n >= sizeof text) break;
		memcpy(text, pl, n);
		text[n] = 0;
		ev_set(e, pid, text);
		break;
	}
	case BL_EV_ORDER: {
		bl_ev_order ev;
		bc_bot *b = bc_engine_bot(e, pid);

		if (n < sizeof ev || !b) break;
		memcpy(&ev, pl, sizeof ev);
		b->order.order = ev.order;
		b->order.target = ev.target;
		b->order.pos = ev.pos;
		b->order.until = ev.secs > 0.0f ? e->now + (double)ev.secs : -1.0;
		b->jolt = 1;
		break;
	}
	default:
		break;
	}
}

/* ====================================================================== */
/* the think                                                              */

/* A bot that thinks this time: alive in the world, on the map the engine
 * has. The rest think nothing. */
static int living(const bc_engine *e, const bl_player *p)
{
	return (p->flags & BL_F_BOT) && p->state == BL_ALIVE && e->have_map && e->w.map_seq == e->map_seq;
}

/* Its eyes (senses.h, SIGHT IN TWO HALVES): the rays, into its own look.
 * A bot about to begin a new life looks as one that remembers nobody. */
static void look(const bc_engine *e, bc_bot *b)
{
	bc_senses_look(b->born ? NULL : &b->senses, &e->sense, e->map, &e->w, b->pid, b->night_vision,
	               e->now, &b->look);
}

static void look_job(void *arg, int i)
{
	bc_engine *e = arg;

	look(e, &e->bots[e->turn[i]]);
}

void bc_engine_runner(bc_engine *e, bc_runner run, void *ctx)
{
	e->run = run;
	e->run_ctx = ctx;
}

void bc_engine_run(bc_engine *e, int kind, bc_job job, void *arg, int n)
{
	int i;

	if (e->run && n > 0) {
		e->run(e->run_ctx, kind, job, arg, n);
		return;
	}
	for (i = 0; i < n; i++)
		job(arg, i);
}

static void decide(bc_engine *e, bc_bot *b, float dt)
{
	const bl_player *me = bc_me(b);
	bt_ctx c;

	bc_senses_take(&b->senses, &e->sense, &e->w, b->pid, e->now, &b->look, &e->board);
	if (b->senses.nearest >= 0 && me->team >= 1 && me->team <= 2) {
		e->hot[me->team - 1] = b->senses.k[b->senses.nearest].pos;
		e->hot_at[me->team - 1] = e->now;
	}
	bc_leader_of(b);        /* whom it follows, if anybody: looked at again now and then */
	bc_fight_select(b);
	if (b->ping.taken && e->now >= b->ping.until)
		b->ping.taken = 0;
	if (me->team >= 1 && me->team <= 2) {
		/* where the team has been: roaming prefers where it has not */
		int vx = (int)me->pos.x / (BC_MAP_X / BC_VISIT_N), vy = (int)me->pos.y / (BC_MAP_Y / BC_VISIT_N);

		if (vx >= 0 && vx < BC_VISIT_N && vy >= 0 && vy < BC_VISIT_N)
			e->visit[me->team - 1][vy * BC_VISIT_N + vx] = (float)e->now + 1.0f;
	}
	{
		int nade = bc_grenade_threat(b, NULL) >= 25.0f;

		if ((b->senses.alert == BC_ALERT_ENGAGED && b->was_alert != BC_ALERT_ENGAGED) ||
		    (nade && !b->was_nade))
			b->jolt = 1;
		b->was_alert = b->senses.alert;
		b->was_nade = (uint8_t)nade;
	}

	/* the wishes are stated anew by whatever the tree runs */
	b->wish.move = BC_MOVE_NONE;
	b->wish.look = BC_LOOK_AHEAD;
	b->wish.tool = BL_TOOL_GUN;
	b->wish.fire_pid = b->wish.look_pid = -1;
	b->wish.crouch = b->wish.sneak = b->wish.jump = b->wish.sprint = 0;
	b->wish.mx = b->wish.my = 0.0f;
	b->following = 0;

	if (b->forest && b->bt) {
		if (b->jolt) {
			/* startled, not born: every pick chooses now -- but a role it
			 * drew for this life (`pick roll=`) is its own still */
			bot_ctx(b, &c, 0.0f);
			bt_restart(b->forest, b->bt, &c);
		}
		b->jolt = 0;
		if (b->tree_also >= 0) {
			bot_ctx(b, &c, 0.0f);
			bt_tick(b->forest, b->tree_also, b->bt, &c);
		}
		if (e->now < b->elsewhere.until) {
			/* just dropped a goal it was stuck on: somewhere else first */
			if (b->elsewhere.free) {
				b->wish.move = BC_MOVE_FREE;
				if (bc_walk_safe(b, b->elsewhere.mx, b->elsewhere.my)) {
					b->wish.mx = b->elsewhere.mx;
					b->wish.my = b->elsewhere.my;
				}
			} else {
				int st = bc_move_to(b, b->elsewhere.goal, 1.0f);

				if (st == BC_MV_ARRIVED || st == BC_MV_FAILED)
					b->elsewhere.until = 0.0;
			}
			bc_fire_at_will(b);
		} else {
			bot_ctx(b, &c, dt);
			bt_tick(b->forest, b->tree, b->bt, &c);
		}
	}
	if (e->now < b->mv.shut_until && b->wish.move == BC_MOVE_GOTO && b->wish.fire_pid < 0) {
		/* SHUT IN (skill_move.c): no way to anywhere, and no route is
		 * asked for. A tree that asks to go somewhere all the same (it
		 * did not read `stranded`) gets this: not a post, it paces what
		 * room it has, a new way every second or two, and looks about. A
		 * tree that holds or camps where it is, is left to. */
		if (e->now >= b->pace.turn_at) {
			float a = bc_rng_range(&b->rng, 0.0f, 6.2831853f);

			b->pace.mx = cosf(a);
			b->pace.my = sinf(a);
			b->pace.turn_at = e->now + (double)bc_rng_range(&b->rng, 1.0f, 2.2f);
		}
		b->wish.move = BC_MOVE_FREE;
		b->wish.mx = b->wish.my = 0.0f;
		if (bc_walk_safe(b, b->pace.mx, b->pace.my)) {
			b->wish.mx = b->pace.mx;
			b->wish.my = b->pace.my;
		} else {
			b->pace.turn_at = 0.0;
		}
		if (b->wish.look == BC_LOOK_AHEAD) {
			b->wish.look = BC_LOOK_POINT;
			b->wish.look_at.x = me->pos.x + b->pace.mx * 12.0f;
			b->wish.look_at.y = me->pos.y + b->pace.my * 12.0f;
			b->wish.look_at.z = me->pos.z;
		}
	}
	e->stats.decisions++;
}

/* The follower's keys, meant for its own facing, as the nearest keys for
 * the facing the head really has. */
static uint8_t remap_keys(uint8_t keys, bc_v3 from, bl_vec3 to, int aiming)
{
	float fl = sqrtf(from.x * from.x + from.y * from.y), fx, fy, f, r, mx, my, l;
	uint8_t k;

	f = (float)((keys & BL_K_FORWARD) != 0) - (float)((keys & BL_K_BACK) != 0);
	r = (float)((keys & BL_K_RIGHT) != 0) - (float)((keys & BL_K_LEFT) != 0);
	if (fl < 1e-4f || (f == 0.0f && r == 0.0f))
		return (uint8_t)(keys & (BL_K_JUMP | BL_K_CROUCH | BL_K_SNEAK));
	fx = from.x / fl; fy = from.y / fl;
	mx = fx * f - fy * r;
	my = fy * f + fx * r;
	l = sqrtf(mx * mx + my * my);
	k = bc_keys_toward(mx / l, my / l, to, 0);
	k |= (uint8_t)(keys & (BL_K_JUMP | BL_K_CROUCH | BL_K_SNEAK));
	if (!aiming && (keys & BL_K_SPRINT) && k == (BL_K_FORWARD | (keys & (BL_K_JUMP | BL_K_CROUCH | BL_K_SNEAK))) &&
	    f > 0.0f && r == 0.0f)
		k |= BL_K_SPRINT;
	return k;
}

/* Somewhere else to go for a moment: a place it can walk straight to,
 * away from `px, py` (what it was pushing at), dry if it can be. */
static void pick_elsewhere(bc_bot *b, float px, float py)
{
	bc_engine *e = b->e;
	const bl_player *me = bc_me(b);
	float best = -1e30f;
	int k, z0 = (int)floorf(me->pos.z + 2.75f), found = 0;
	bc_nav_node n;

	if (bc_nav_snap(e->map, (int)floorf(me->pos.x), (int)floorf(me->pos.y), z0, 1, &n))
		z0 = n.z;
	for (k = 0; k < 12; k++) {
		float a = (float)k * (6.2831853f / 12.0f), cx = cosf(a), cy = sinf(a), sc;
		int z = z0, i, lx = -1, ly = -1, lz = 0, dry = 0;

		for (i = 1; i <= 10; i++) {
			int x = (int)floorf(me->pos.x + cx * (float)i), y = (int)floorf(me->pos.y + cy * (float)i), fz;

			if (x < 1 || y < 1 || x > BC_MAP_X - 2 || y > BC_MAP_Y - 2)
				break;
			if (bc_map_is_water(e->map, x, y)) {
				if (z < BC_MAP_WATER_Z - 1) break;      /* a drop into the sea */
				fz = BC_MAP_WATER_Z;
			} else if ((fz = bc_floor_near(e->map, x, y, z)) < 0) {
				break;
			}
			z = fz;
			if (i >= 5) { lx = x; ly = y; lz = z; dry = fz != BC_MAP_WATER_Z; }
		}
		if (lx < 0)
			continue;
		sc = -4.0f * (cx * px + cy * py) + (dry ? 3.0f : 0.0f) + bc_frand(b);
		if (sc > best) {
			best = sc;
			b->elsewhere.goal.x = (float)lx + 0.5f;
			b->elsewhere.goal.y = (float)ly + 0.5f;
			b->elsewhere.goal.z = (float)lz - 2.25f;
			found = 1;
		}
	}
	b->elsewhere.free = (uint8_t)!found;
	b->elsewhere.mx = -px;
	b->elsewhere.my = -py;
	b->elsewhere.until = e->now + (found ? 4.0 : 1.5);
}

/* OUT (see the top of the file): the goal is dropped, the tree decides again. */
static void stuck_out(bc_engine *e, bc_bot *b, const bc_body *body, const char *why)
{
	const bl_player *me = bc_me(b);
	bc_mover *mv = &b->mv;
	float px = me->ori.x, py = me->ori.y, l;
	int team = me->team;

	e->stats.stuck_resets++;
	b->stuck_outs++;
	b->stuck_out_at = e->now;    /* and it leads nobody for a while (skill_squad.c) */
	if (e->now - b->stuck_said_at > 60.0 || b->stuck_said_at == 0.0) {
		char d[200];

		b->stuck_said_at = e->now;
		bc_engine_describe(e, b->pid, d, sizeof d);
		bc_engine_log(e, 1, "bot #%d stuck at %.0f,%.0f,%.0f (%s) doing %s", b->pid, (double)me->pos.x,
		              (double)me->pos.y, (double)me->pos.z, why, d);
	}
	if (mv->goal_set && b->wish.move == BC_MOVE_GOTO) {
		bc_nav_node from, to;
		int kind;

		px = (float)mv->goal.x + 0.5f - me->pos.x;
		py = (float)mv->goal.y + 0.5f - me->pos.y;
		if (mv->has_route && bc_nav_follow_failed(&mv->follow, &mv->route, &from, &to, &kind))
			bc_nav_fail_note(&e->fail, from, to, kind, e->now, 30.0);
		/* the team is told there is no way from here only when "here" is
		 * a floor: from a body in the air (knocked off a stair, mid-jump)
		 * it would say so of a place nobody stands on */
		if (bc_nav_node_of_body(e->map, body, &from))
			bc_unreach_note(b, from, mv->goal);
		mv->has_route = 0;
		mv->state = BC_MV_FAILED;
		mv->retry_at = e->now + 20.0;
		mv->gave[mv->gave_n & 3] = mv->goal;
		mv->gave_until[mv->gave_n & 3] = mv->retry_at;
		mv->gave_n++;
		bc_engine_search_release(e, b);
	}
	if (team >= 1 && team <= 2) {
		/* a bad place: the team's plans shy from it for a while */
		int i, old = 0;

		for (i = 1; i < BC_DANGER_MAX; i++)
			if (e->danger_at[team - 1][i] < e->danger_at[team - 1][old]) old = i;
		e->danger[team - 1][old].x = me->pos.x;
		e->danger[team - 1][old].y = me->pos.y;
		e->danger[team - 1][old].radius = 5.0f;
		e->danger[team - 1][old].weight = 4.0f;
		e->danger_at[team - 1][old] = e->now;
	}
	l = sqrtf(px * px + py * py);
	if (l < 1e-3f) { px = 1.0f; py = 0.0f; l = 1.0f; }
	pick_elsewhere(b, px / l, py / l);
	b->jolt = 1;
	b->roam.valid = 0;
	b->cover.valid = 0;
	b->cq.state = 0;
	b->seek.fails++;
	b->unstick.run = 0;
	b->unstick.push = 0.0;
	b->unstick.until = 0.0;
	b->area.acc = 0.0;
	b->area.from = me->pos;
}

/* THE NET UNDER EVERYTHING (see the top of the file). May change the keys. */
static void watchdog(bc_engine *e, bc_bot *b, const bc_body *body, int nav, const bc_nav_cmd *cmd, uint8_t *keys)
{
	const bl_player *me = bc_me(b);
	float dt = e->world_dt_last;
	int editing = nav && cmd->edit != BC_NAV_EDIT_NONE, building = 0;
	/* (strafing in a fight goes back and forth on purpose: not pushing.
	 * Taken for it, the net's jump threw a bot fighting on a roof's edge
	 * off the roof, 2026-11-25) */
	int pushing = (*keys & 15) != 0 && !editing && !(b->fight.strafing && b->wish.move == BC_MOVE_FREE);
	float dx = me->pos.x - b->anchor.x, dy = me->pos.y - b->anchor.y, dz = me->pos.z - b->anchor.z;

	if (nav && cmd->step >= 0 && cmd->step < b->mv.route.n) {
		int kind = b->mv.route.steps[cmd->step].kind;

		building = editing || kind == BC_NAV_DIG || kind == BC_NAV_BUILD || kind == BC_NAV_PILLAR;
	}

	/* --- pushing */
	if (dx * dx + dy * dy + dz * dz > 1.0f) {
		b->anchor = me->pos;
		b->anchor_at = e->now;
		b->unstick.push = 0.0;
	}
	if (pushing) {
		b->unstick.push += (double)dt;
		b->unstick.idle = 0.0;
	} else {
		b->unstick.idle += (double)dt;
		if (b->unstick.idle > 1.0 || editing)
			b->unstick.push = 0.0;
	}
	if (b->unstick.run) {
		float ex = me->pos.x - b->unstick.place.x, ey = me->pos.y - b->unstick.place.y;

		if (ex * ex + ey * ey > 3.0f * 3.0f || e->now - b->unstick.fired_at > 8.0)
			b->unstick.run = 0;         /* it got away */
	}
	if (b->unstick.push > 1.5) {
		b->unstick.push = 0.0;
		b->unstick.fired_at = e->now;
		if (b->unstick.run == 0)
			b->unstick.place = me->pos;
		b->unstick.run++;
		b->stuck++;
		e->stats.stuck++;
		if (b->unstick.run >= 3) {
			stuck_out(e, b, body, "pushing");
			*keys = 0;
			return;
		}
		e->stats.stuck_tries++;
		b->unstick.mode = b->unstick.run;
		b->unstick.keys0 = (uint8_t)(*keys & 15);
		b->unstick.until = e->now + (b->unstick.run == 1 ? 0.3 : 1.0);
		b->fight.strafe_dir = -b->fight.strafe_dir;
		b->fight.strafe_until = e->now + 0.8;
		if (b->unstick.run >= 2 && (b->mv.state == BC_MV_FOLLOWING || b->mv.has_route)) {
			bc_nav_node from, to;
			int kind;

			/* the move it was on did not work: the next plan pays for it */
			if (b->mv.has_route && bc_nav_follow_failed(&b->mv.follow, &b->mv.route, &from, &to, &kind))
				bc_nav_fail_note(&e->fail, from, to, kind, e->now, 30.0);
			b->mv.has_route = 0;
			b->mv.state = BC_MV_PLANNING;
			b->mv.plan_since = e->now;
			b->mv.braking = 0;
			b->mv.again = 1;
		}
		bc_engine_log(e, 0, "bot #%d: held at %.1f %.1f %.1f with keys down, try %d",
		              b->pid, (double)me->pos.x, (double)me->pos.y, (double)me->pos.z, b->unstick.run);
	}

	/* --- going nowhere on a route */
	dx = me->pos.x - b->area.from.x; dy = me->pos.y - b->area.from.y;
	if (dx * dx + dy * dy > 4.0f * 4.0f || !nav || building || b->wish.move != BC_MOVE_GOTO) {
		if (dx * dx + dy * dy > 4.0f * 4.0f || building)
			b->area.from = me->pos;
		if (dx * dx + dy * dy > 4.0f * 4.0f || building || b->wish.move != BC_MOVE_GOTO)
			b->area.acc = 0.0;
	} else if (pushing) {
		b->area.acc += (double)dt;
		if (b->area.acc > 8.0) {
			stuck_out(e, b, body, "going nowhere");
			*keys = 0;
			return;
		}
	}

	/* --- what is being tried */
	if (e->now < b->unstick.until && !body->airborne) {
		uint8_t k = *keys, mv = (uint8_t)(k & 15), rest = (uint8_t)(k & (BL_K_CROUCH | BL_K_SNEAK));

		if (!mv) mv = b->unstick.keys0;     /* between two routes: what it was pressing */
		if (b->unstick.mode == 1) {
			*keys = (uint8_t)(mv | rest | BL_K_JUMP);
		} else if (b->unstick.until - e->now > 0.55) {
			/* a step back from it */
			uint8_t back = 0;

			if (mv & BL_K_FORWARD) back |= BL_K_BACK;
			if (mv & BL_K_BACK) back |= BL_K_FORWARD;
			if (mv & BL_K_LEFT) back |= BL_K_RIGHT;
			if (mv & BL_K_RIGHT) back |= BL_K_LEFT;
			*keys = (uint8_t)(back | rest);
		} else {
			/* and at it again from the side, with a jump */
			uint8_t side = b->flank_side > 0 ? BL_K_RIGHT : BL_K_LEFT;

			*keys = (uint8_t)((mv & (BL_K_FORWARD | BL_K_BACK)) | side | rest);
			if (b->unstick.until - e->now > 0.45)
				*keys |= BL_K_JUMP;
		}
		{
			/* not off an edge: the way these keys take the body, for the
			 * facing it has, must keep its feet up (a step back off a
			 * slab's edge killed a bot, 2026-11-25) -- else it stands */
			float fx = me->ori.x, fy = me->ori.y, fl = sqrtf(fx * fx + fy * fy);
			float f = (float)((*keys & BL_K_FORWARD) != 0) - (float)((*keys & BL_K_BACK) != 0);
			float r = (float)((*keys & BL_K_RIGHT) != 0) - (float)((*keys & BL_K_LEFT) != 0);

			if (fl > 1e-4f && (f != 0.0f || r != 0.0f)) {
				float mx, my;

				fx /= fl; fy /= fl;
				mx = fx * f - fy * r;
				my = fy * f + fx * r;
				if (!bc_walk_safe(b, mx, my))
					*keys &= (uint8_t)~(15 | BL_K_JUMP);
			}
		}
	}
}

/* WAITING FOR A ROUTE. A plan takes a share of every think's budget, and
 * forty bots asking at once wait their turn: seconds, on a map where
 * routes are long (prisonbreakv1: 80% of all bot-time stood still, 96% of
 * it waiting -- "after a map change all bots are frozen"). A bot that has
 * asked for a route and has none to walk meanwhile does not stand: it
 * walks straight at the goal, where a body walked that way for a third of
 * a second keeps its feet (bc_walk_safe: no edge, no sea it is not
 * already in). The route, when it comes, is taken up from where the body
 * then is (skill_move.c, plan_done). Not when the last plan was told to
 * start from a standstill, not when this goal already ended a route short
 * (straight on is then the wrong way), not while the net is trying
 * something. 1 and the direction when it walks. */
static int waiting_for_route(bc_bot *b, const bc_body *body, float *wx, float *wy)
{
	const bl_player *me = bc_me(b);
	const bc_mover *mv = &b->mv;
	float dx, dy, l;

	if (b->e->plan_stand)
		return 0;
	if (b->wish.move != BC_MOVE_GOTO || mv->state != BC_MV_PLANNING || mv->has_route || !mv->goal_set ||
	    mv->braking || mv->partial_tries || b->unstick.run || body->airborne)
		return 0;
	dx = (float)mv->goal.x + 0.5f - me->pos.x;
	dy = (float)mv->goal.y + 0.5f - me->pos.y;
	l = sqrtf(dx * dx + dy * dy);
	if (l < 3.0f)
		return 0;
	if (mv->goal.z - (int)floorf(me->pos.z + 2.75f) > BC_NAV_DZ_MAX)
		return 0;       /* far below (off a roof): the way is down, from
		                   where it stands -- an edit, a stair -- not on
		                   toward it (it walked off the route's start) */
	dx /= l; dy /= l;
	if (!bc_walk_safe(b, dx, dy))
		return 0;
	*wx = dx;
	*wy = dy;
	return 1;
}

static void act(bc_engine *e, bc_bot *b, float dt)
{
	const bl_player *me = bc_me(b);
	bc_body body;
	bc_nav_cmd cmd;
	bc_aim_out out;
	bc_aim_events ev;
	bc_aim_v3 eye, cur;
	bl_vec3 ori, look_at = b->wish.look_at;
	uint8_t keys = 0, mouse = 0, flags = BL_I_VALID, tool = b->wish.tool;
	int nav, precise = 0, flying = 0, look = b->wish.look, look_pid = b->wish.look_pid, on_target = 0, heading = 0;
	float dist = 1e9f, dx, dy, dz, wx = 0.0f, wy = 0.0f;

	memset(&out, 0, sizeof out);
	bc_body_of(me, &body);

	/* --- the route */
	nav = bc_mover_act(b, &body, &cmd);
	if (nav) {
		/* past the last step (braking at the end) is no move that needs
		 * the facing: the head is not snapped round to the follower's */
		int kind = cmd.step >= 0 && cmd.step < b->mv.route.n ? b->mv.route.steps[cmd.step].kind : BC_NAV_WALK;

		precise = cmd.edit != BC_NAV_EDIT_NONE ||
		          !(kind == BC_NAV_WALK || kind == BC_NAV_SPRINT || kind == BC_NAV_CROUCH);
		/* off the ground on a jump or a drop the keys hardly steer the
		 * body: the head may stay on a man (below) */
		flying = cmd.edit == BC_NAV_EDIT_NONE && body.airborne &&
		         (kind == BC_NAV_JUMP || kind == BC_NAV_RUNJUMP || kind == BC_NAV_DROP);
	}

	/* --- an item's aim, kept on its man for the time it asked */
	if (e->now < b->guide.until) {
		int g = b->guide.pid;

		if (g >= 0 && e->w.players[g].state != BL_ALIVE) {
			b->guide.until = 0.0;
		} else if (g >= 0 && b->senses.k[g].visible) {
			look = BC_LOOK_TARGET;
			look_pid = g;
		} else {
			look = BC_LOOK_POINT;
			look_at = g >= 0 ? b->senses.k[g].pos : b->guide.at;
		}
	}
	if (look == BC_LOOK_TARGET && (look_pid < 0 || e->w.players[look_pid].state != BL_ALIVE))
		look = BC_LOOK_AHEAD;
	/* a man in its sights while it is in the air: it keeps aiming at him,
	 * and may fire (it used to look where it jumped and start over on
	 * landing) */
	if (precise && flying && look == BC_LOOK_TARGET)
		precise = 0;
	/* travelling with nothing to aim at: the head is its own (skill_look.c) */
	b->gaze.free = 0;
	if (nav && !precise && look == BC_LOOK_AHEAD && !e->gaze_off) {
		heading = bc_look_travel(b, &cmd, &look_at);
		b->gaze.free = heading != 0;
		if (heading == 1) look = BC_LOOK_POINT;
		heading = heading == 2;
	}
	/* walked by hand (no route: a bound begun, a pace, somewhere else for
	 * a moment) with nothing to look at: the way it walks */
	if (!nav && look == BC_LOOK_AHEAD && b->wish.move == BC_MOVE_FREE && !e->gaze_off &&
	    (b->wish.mx != 0.0f || b->wish.my != 0.0f)) {
		look = BC_LOOK_POINT;
		look_at = me->pos;
		look_at.x += b->wish.mx * 8.0f;
		look_at.y += b->wish.my * 8.0f;
	}

	/* --- the head */
	eye.x = me->pos.x; eye.y = me->pos.y; eye.z = me->pos.z;
	cur = b->aim.ori;
	ev.hit = b->hit;
	ev.hit_from.x = b->hit_from.x; ev.hit_from.y = b->hit_from.y; ev.hit_from.z = b->hit_from.z;
	ev.hit_from_valid = b->hit_from_valid;
	b->hit = 0;
	if (nav && (precise || look == BC_LOOK_AHEAD)) {
		bc_aim_v3 o;
		float l = sqrtf(cmd.ori.x * cmd.ori.x + cmd.ori.y * cmd.ori.y + cmd.ori.z * cmd.ori.z);

		if (l > 1e-4f) { o.x = cmd.ori.x / l; o.y = cmd.ori.y / l; o.z = cmd.ori.z / l; }
		else o = cur;
		if (heading)
			o = bc_look_heading(b, o, dt);  /* on the heading, turned to it as a head turns */
		bc_aim_snap(&b->aim, o);
		b->aim.ori = o;
		ori.x = o.x; ori.y = o.y; ori.z = o.z;
		keys = heading ? remap_keys(cmd.keys, cmd.ori, ori, 0) : cmd.keys;
	} else {
		int firing = e->now < b->fight.burst_until;

		if (look == BC_LOOK_TARGET) {
			const bl_player *t = &e->w.players[look_pid];
			bc_aim_target tg;

			tg.pos.x = t->pos.x; tg.pos.y = t->pos.y; tg.pos.z = t->pos.z;
			tg.vel.x = t->vel.x * 32.0f; tg.vel.y = t->vel.y * 32.0f; tg.vel.z = t->vel.z * 32.0f;
			tg.crouched = (t->flags & BL_F_CROUCH) != 0;
			tg.airborne = (t->flags & BL_F_AIRBORNE) != 0;
			tg.id = look_pid;
			bc_aim_step(&b->aim, &b->rng, dt, eye, cur, &tg, &ev, firing, &out);
			on_target = out.on_target;
			dx = t->pos.x - me->pos.x; dy = t->pos.y - me->pos.y; dz = t->pos.z - me->pos.z;
			dist = sqrtf(dx * dx + dy * dy + dz * dz);
		} else if (look == BC_LOOK_POINT) {
			bc_aim_v3 pt;

			pt.x = look_at.x; pt.y = look_at.y; pt.z = look_at.z;
			bc_aim_step_point(&b->aim, &b->rng, dt, eye, cur, pt, &ev, 0, &out);
		} else {
			bc_aim_step(&b->aim, &b->rng, dt, eye, cur, NULL, &ev, 0, &out);
		}
		ori.x = out.ori.x; ori.y = out.ori.y; ori.z = out.ori.z;
		if (nav) {
			keys = remap_keys(cmd.keys, cmd.ori, ori, look == BC_LOOK_TARGET);
		} else if (b->wish.move == BC_MOVE_FREE) {
			keys = bc_keys_toward(b->wish.mx, b->wish.my, ori, b->keys_prev);
			if (b->wish.sprint && keys == BL_K_FORWARD)
				keys |= BL_K_SPRINT;
		} else if (waiting_for_route(b, &body, &wx, &wy)) {
			/* WAITING FOR A ROUTE is not standing: on toward the goal */
			keys = bc_keys_toward(wx, wy, ori, b->keys_prev);
		} else if (!body.airborne && bc_body_speed(&body) > 3.0f) {
			/* stand means stop: letting go coasts two voxels */
			float s = bc_body_speed(&body) / 32.0f;

			keys = bc_keys_toward(-body.vel.x / s, -body.vel.y / s, ori, 0);
		}
		if (!nav) {
			/* crouch only changes on the ground, and only up where
			 * there is room (body.h) */
			int want = b->wish.crouch;

			if (body.airborne) want = (body.keys & BC_K_CROUCH) != 0;
			else if (!want && (body.keys & BC_K_CROUCH) && !bc_body_can_stand(&body, e->map)) want = 1;
			if (want) keys |= BL_K_CROUCH;
			if (b->wish.sneak) keys |= BL_K_SNEAK;
			if (b->wish.jump && !body.airborne) keys |= BL_K_JUMP;
		}
	}
	b->wish.jump = 0;
	b->keys_prev = keys;

	/* --- the tool, the trigger */
	if (nav && cmd.edit != BC_NAV_EDIT_NONE)
		tool = b->mv.edit_tool;
	else if (e->now < b->mv.tool_grace && b->wish.fire_pid < 0 && b->mv.edit_tool != BL_TOOL_GUN &&
	         b->wish.move == BC_MOVE_GOTO)
		tool = b->mv.edit_tool;
	if ((b->out.keys & BL_K_SPRINT) && !(keys & BL_K_SPRINT))
		b->fight.fire_block_until = e->now + 0.28;      /* aosbot kGunUpSec */
	if (tool == b->wish.tool && look == BC_LOOK_TARGET && look_pid == b->wish.fire_pid)
		mouse = bc_fight_trigger(b, on_target, dist);
	if (bc_reload_act(b) || b->reload_pulse) {
		flags |= BL_I_RELOAD;
		if (b->reload_pulse && e->now >= b->fight.reloading_until)
			b->fight.reloading_until = e->now + (double)bc_gun(me->gun)->reload_secs;
		b->reload_pulse = 0;
	}
	if (e->w.night && b->lamp != BC_LAMP_OFF)
		flags |= BL_I_LAMP;         /* never by day; and never unless a tree lit it */

	watchdog(e, b, &body, nav, &cmd, &keys);

	b->out.life = me->life;
	b->out.keys = keys;
	b->out.mouse = mouse;
	b->out.tool = tool;
	b->out.flags = flags;
	b->out.ori = ori;
	b->aim_out = out;
}

void bc_engine_plan_bound(bc_engine *e, int most)
{
	e->plan_bound = most > 0 ? most : 0;
}

uint32_t bc_engine_plan_spent(const bc_engine *e)
{
	return e->stats.last_expansions;
}

void bc_engine_plan_rate(bc_engine *e, int rate, int hz)
{
	if (rate < 0) rate = 0;
	if (hz < 1) hz = 1;
	e->plan_per_bot = (rate + hz / 2) / hz;
}

/* THE THINK, with a new world (a think without one leaves the intents as
 * they stand: the world comes at 30 a second, botd thinks at 60):
 *
 *   WHOSE TURN  every bot decides DECIDE_PERIOD apart, at a phase of the
 *               period of its own (its slot's: turn_phase), so a think
 *               decides for an even share of the bots, about two thirds at
 *               30 worlds a second. The phase is a time, not a count the
 *               bot keeps: a think that comes late (a stall, a map
 *               loading) has every bot decide once and the next is back to
 *               its share. Until 2026-11-25 it was a count, by four phases,
 *               reset to 0 after a late think -- and the bots it reset
 *               decided together for good after (BRAIN-STATUS.md (c4)).
 *   LOOK        the rays of every bot whose turn it is, a job each (engine.h,
 *               THE THINK'S WORK AS JOBS): each writes only its own look
 *   DECIDE      bot after bot, in slot order: a death or a new life, what
 *               it saw taken in (the team's board written in that order),
 *               its tree
 *   PLAN        the route searches, with this think's budget -- no more
 *               than the host's bound (engine.h, THE PLANNER'S BOUND: what
 *               made botd's slow rounds was one long search spending a
 *               think's whole share)
 *   ACT         the follower, the head, the trigger
 *
 * (Planning in the thinks between worlds as well, at half the numbers,
 * was tried: rounds as short, but ctf_test's six a side went from a
 * capture in every one of 8 seeds to none in 2 -- (c4).)
 */
static double turn_phase(int idx)
{
	/* the golden ratio's sequence: any number of slots spread evenly */
	double f = (double)idx * 0.6180339887498949;

	return DECIDE_PERIOD * (f - floor(f));
}

void bc_engine_think(bc_engine *e, const bl_world *world, bl_intent *intents,
                     float dt, int budget)
{
	int i, fresh;
	float dtw;

	if (!(dt >= 0.0f)) dt = 0.0f;
	if (dt > 0.25f) dt = 0.25f;
	e->now += (double)dt;
	e->stats.thinks++;
	e->stats.last_expansions = 0;

	e->world_dt += dt;
	fresh = !e->have_world || world->tick != e->last_tick;
	if (!fresh) {
		/* nothing new is known: the same intents stand */
		for (i = 0; i < e->max_bots; i++)
			if (e->bots[i].used && (world->players[e->bots[i].pid].flags & BL_F_BOT))
				intents[e->bots[i].pid] = e->bots[i].out;
		return;
	}
	memcpy(&e->w, world, sizeof e->w);
	e->last_tick = world->tick;
	e->have_world = 1;
	bc_objective_world(e);
	bc_leaders_think(e);
	{
		/* engine.h, THE PLANNER'S BUDGET: the think's own, or every
		 * bot's share, whichever is more; and no more than the bound */
		long long share = (long long)e->plan_per_bot * bc_engine_bots(e);

		e->budget_left = budget > 0 ? budget : 0;
		if (budget > 0 && share > e->budget_left)
			e->budget_left = share > INT32_MAX ? INT32_MAX : (int)share;
		if (e->plan_bound > 0 && e->budget_left > e->plan_bound)
			e->budget_left = e->plan_bound;
	}
	dtw = e->world_dt > 0.25f ? 0.25f : e->world_dt;
	e->world_dt = 0.0f;

	/* WHOSE TURN */
	for (i = 0; i < e->max_bots; i++) {
		bc_bot *b = &e->bots[i];
		const bl_player *p;
		double ph;

		b->due = 0;
		if (!b->used)
			continue;
		p = &e->w.players[b->pid];
		b->decide_dt += dtw;
		if (!living(e, p))
			continue;
		b->born = !b->alive || p->life != b->life;
		ph = turn_phase(i);
		b->due = floor((e->now + ph) / DECIDE_PERIOD) != floor((e->decided_at + ph) / DECIDE_PERIOD);
	}
	e->decided_at = e->now;

	/* LOOK */
	e->nturn = 0;
	for (i = 0; i < e->max_bots; i++)
		if (e->bots[i].due)
			e->turn[e->nturn++] = (int16_t)i;
	bc_engine_run(e, BC_WORK_SIGHT, look_job, e, e->nturn);

	/* DECIDE */
	for (i = 0; i < e->max_bots; i++) {
		bc_bot *b = &e->bots[i];
		const bl_player *p;

		if (!b->used)
			continue;
		p = &e->w.players[b->pid];
		if (!living(e, p)) {
			/* dead, in limbo, or no map: it thinks nothing */
			if (b->alive)
				bot_died(b);
			memset(&b->out, 0, sizeof b->out);
			b->out.life = p->life;
			b->out.flags = BL_I_VALID;
			b->out.ori.x = 1.0f;
			b->out.tool = BL_TOOL_GUN;
			continue;
		}
		if (!b->alive || p->life != b->life)
			bot_new_life(b, p);
		if (!b->due)
			continue;
		decide(e, b, b->decide_dt);
		b->decide_dt = 0.0f;
	}

	/* PLAN */
	e->world_dt_last = dtw;
	if (e->have_map) {
		bc_movers_plan(e);
		bc_tactics_think(e);
	}

	/* ACT */
	for (i = 0; i < e->max_bots; i++) {
		bc_bot *b = &e->bots[i];

		if (!b->used || !(e->w.players[b->pid].flags & BL_F_BOT))
			continue;
		if (b->alive)
			act(e, b, dtw);
		intents[b->pid] = b->out;
	}
}

void bc_route_text(const bc_bot *b, char *out, size_t out_size)
{
	snprintf(out, out_size, "no route");
	if (b->mv.has_route) {
		int s = b->mv.follow.step < 0 ? 0 : b->mv.follow.step;

		snprintf(out, out_size, "route %d/%d %s", s, (int)b->mv.route.n,
		         s < b->mv.route.n ? bc_nav_kind_name(b->mv.route.steps[s].kind) : "end");
	} else if (b->mv.state == BC_MV_PLANNING && b->wish.move == BC_MOVE_GOTO) {
		snprintf(out, out_size, "planning");
	}
}

size_t bc_engine_describe(const bc_engine *e, int pid, char *out, size_t out_size)
{
	const bc_bot *b;
	char tree[160] = "", route[64];
	int n;

	if (pid < 0 || pid >= BL_MAX_PLAYERS || e->by_pid[pid] < 0 || !out || !out_size)
		return 0;
	b = &e->bots[e->by_pid[pid]];
	if (b->forest && b->bt)
		bt_describe(b->forest, b->bt, tree, sizeof tree);
	bc_route_text(b, route, sizeof route);
	n = snprintf(out, out_size, "%s L%d | %s | %s | sees %d%s",
	             bc_engine_kind_name(e, b->persona.archetype), b->level,
	             !b->alive ? "dead" : tree[0] ? tree : "idle", route, b->senses.n_visible,
	             b->senses.alert == BC_ALERT_SUSPICIOUS ? " suspicious" : "");
	if (n < 0)
		return 0;
	return (size_t)n < out_size ? (size_t)n : out_size - 1;
}
