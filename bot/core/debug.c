/* debug.c -- What a bot is thinking, as JSON, for whoever watches
 * Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
 *
 * engine.h's bc_engine_watch, bc_engine_snapshot and bc_engine_roster.
 * The core does no I/O: these write text into a buffer the host owns,
 * and the host (botd) decides when, how often and where it goes.
 *
 * WHAT IS WRITTEN is the contract a viewer or an editor reads, and is
 * specified in bot/TREES.md ("the live view"): two formats, each with a
 * name and a version.
 *
 *   lsd-bt-snapshot   one bot: who it is, what it perceives in a few
 *                     numbers, its route, and its tree AS THIS ENGINE
 *                     HOLDS IT -- every node of its main tree and of
 *                     its "_also" tree, with the forest's own ids, what
 *                     is RUNNING, each timer, and for every option the
 *                     numbers its pick multiplied
 *   lsd-bt-bots       every bot in a line each, the trees the engine
 *                     has, and the tree the world runs
 *
 * COST. Nothing here is called by a think. A snapshot walks one bot's
 * two trees (a few hundred nodes); a roster walks the bots. What a
 * watched bot pays in its own thinks is bt.h's tracing: its picks note
 * four numbers an option each time they choose. A bot nobody watches
 * pays nothing: bc_engine_watch turns the tracing on for one bot and
 * off again.
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "brain.h"

typedef struct jb { char *out; size_t size, len; } jb;

static void jput(jb *j, const char *fmt, ...)
{
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(j->out && j->len < j->size ? j->out + j->len : NULL, j->out && j->len < j->size ? j->size - j->len : 0, fmt, ap);
	va_end(ap);
	if (n > 0)
		j->len += (size_t)n;
}

static void jstr(jb *j, const char *s)
{
	jput(j, "\"");
	for (; s && *s; s++) {
		unsigned char c = (unsigned char)*s;

		if (c == '"' || c == '\\') jput(j, "\\%c", c);
		else if (c == '\n') jput(j, "\\n");
		else if (c == '\t') jput(j, "\\t");
		else if (c < 0x20) jput(j, "\\u%04x", c);
		else jput(j, "%c", c);
	}
	jput(j, "\"");
}

/* a number a person will read: three decimals are plenty */
static void jnum(jb *j, double v)
{
	char b[32];
	size_t n;

	if (!(v == v) || v > 1e15 || v < -1e15)
		v = 0.0;
	snprintf(b, sizeof b, "%.3f", v);
	n = strlen(b);
	while (n > 1 && b[n - 1] == '0') b[--n] = 0;
	if (n > 1 && b[n - 1] == '.') b[--n] = 0;
	jput(j, "%s", strcmp(b, "-0") ? b : "0");
}

static const char *alert_name(int a)
{
	return a == BC_ALERT_ENGAGED ? "engaged" : a == BC_ALERT_SUSPICIOUS ? "suspicious" : "calm";
}

/* where the forest a bot runs came from */
static const char *forest_from(const bc_engine *e, const bc_bot *b)
{
	if (!b->forest) return "none";
	if (b->forest == b->own) return "own";
	if (b->forest == e->custom) return "server";
	if (b->forest == e->builtin) return "files";
	return "fallback";
}

static const char *tree_name(const bc_bot *b)
{
	bt_tree t;

	return b->forest && bt_forest_tree(b->forest, b->tree, &t) ? t.name : "";
}

static const bc_bot *bot_at(const bc_engine *e, int pid)
{
	if (!e || pid < 0 || pid >= BL_MAX_PLAYERS || e->by_pid[pid] < 0)
		return NULL;
	return &e->bots[e->by_pid[pid]];
}

/* what both formats say of a bot */
static void bot_head(jb *j, const bc_engine *e, const bc_bot *b)
{
	const bl_player *p = &e->w.players[b->pid];
	char doing[160] = "";

	if (b->alive && b->forest && b->bt)
		bt_describe(b->forest, b->bt, doing, sizeof doing);
	jput(j, "\"pid\": %d, \"name\": ", b->pid);
	jstr(j, b->name);
	jput(j, ", \"team\": %d, \"alive\": %s, \"archetype\": ", p->team, b->alive ? "true" : "false");
	jstr(j, bc_archetype_name(b->persona.archetype));
	jput(j, ", \"level\": %d, \"health\": %d, \"tree\": ", b->level, b->alive ? p->hp : 0);
	jstr(j, tree_name(b));
	jput(j, ", \"tree_from\": ");
	jstr(j, forest_from(e, b));
	jput(j, ", \"tree_set\": \"%s\"", b->tree_name[0] ? "bot" : "world");
	jput(j, ", \"doing\": ");
	jstr(j, !b->alive ? "dead" : doing[0] ? doing : "idle");
	jput(j, ", \"watched\": %s", b->watched ? "true" : "false");
}

/* what the server's scripts told it (engine.c, THE BRIDGE): its facts,
 * the bot's own over the world's, then (after "}, \"places\": {") the
 * places, each where it is now or null */
static void bridge_json(jb *j, const bc_engine *e, const bc_bot *b)
{
	int i, k, n = 0;

	for (i = 0; i < BC_BOT_FACTS_MAX + BC_FACTS_MAX; i++) {
		const bc_fact *f = i < BC_BOT_FACTS_MAX ? &b->facts[i] : &e->facts[i - BC_BOT_FACTS_MAX];

		if (!f->name[0]) continue;
		for (k = 0; i >= BC_BOT_FACTS_MAX && k < BC_BOT_FACTS_MAX && strcmp(b->facts[k].name, f->name); k++) ;
		if (i >= BC_BOT_FACTS_MAX && k < BC_BOT_FACTS_MAX) continue;       /* the bot has its own */
		jput(j, "%s\"%s\": ", n++ ? ", " : "", f->name);
		jnum(j, f->value);
	}
	jput(j, "}, \"places\": {");
	for (i = 0, n = 0; i < BC_BOT_SPLACES_MAX + BC_SPLACES_MAX; i++) {
		const bc_splace *p = i < BC_BOT_SPLACES_MAX ? &b->places[i] : &e->places[i - BC_BOT_SPLACES_MAX];
		bl_vec3 at;

		if (!p->name[0]) continue;
		for (k = 0; i >= BC_BOT_SPLACES_MAX && k < BC_BOT_SPLACES_MAX && strcmp(b->places[k].name, p->name); k++) ;
		if (i >= BC_BOT_SPLACES_MAX && k < BC_BOT_SPLACES_MAX) continue;
		jput(j, "%s\"%s\": ", n++ ? ", " : "", p->name);
		if (bc_splace_get(b, p->name, &at)) {
			jput(j, "["); jnum(j, at.x); jput(j, ", "); jnum(j, at.y); jput(j, ", "); jnum(j, at.z); jput(j, "]");
		} else {
			jput(j, "null");
		}
	}
}

void bc_engine_watch(bc_engine *e, int pid, int on)
{
	bc_bot *b = bc_engine_bot(e, pid);

	if (!b)
		return;
	b->watched = on ? 1 : 0;
	if (b->forest && b->bt)
		bt_state_trace(b->bt, b->watched);
}

int bc_engine_watched(const bc_engine *e, int pid)
{
	const bc_bot *b = bot_at(e, pid);

	return b && b->watched;
}

/* the nodes of one tree of the bot's forest, each with what it remembers */
static void tree_nodes(jb *j, const bc_bot *b, int tree, int *first)
{
	const bt_forest *f = b->forest;
	bt_tree t, next;
	int path[BT_DEPTH_MAX], n_path, end, i, k;

	if (!bt_forest_tree(f, tree, &t))
		return;
	end = bt_forest_tree(f, tree + 1, &next) ? next.root : (int)bt_forest_nodes(f);
	n_path = bt_state_running(f, b->bt, tree, path, BT_DEPTH_MAX);
	for (i = t.root; i < end; i++) {
		bt_node n;
		bt_node_state ns;
		int running = 0;

		bt_forest_node(f, i, &n);
		bt_state_node(f, b->bt, i, &ns);
		for (k = 0; k < n_path && k < BT_DEPTH_MAX; k++) running |= path[k] == i;
		jput(j, "%s\n    {\"id\": %d, \"parent\": %d, \"kind\": ", *first ? "" : ",", i, n.parent);
		*first = 0;
		jstr(j, bt_kind_name(n.kind));
		jput(j, ", \"text\": ");
		jstr(j, n.text);
		jput(j, ", \"line\": %d, \"running\": %s", n.line, running && b->alive ? "true" : "false");
		if (n.comment) { jput(j, ", \"comment\": "); jstr(j, n.comment); }
		if (n.kind == BT_K_PICK && n.roll) jput(j, ", \"roll\": \"%s\"", n.roll == BT_ROLL_ONCE ? "once" : n.roll == BT_ROLL_EACH ? "each" : "life");
		if (ns.child >= 0) jput(j, ", \"child\": %d", ns.child);
		if (ns.running && (n.kind == BT_K_PICK || n.kind == BT_K_WAIT || n.kind == BT_K_LIMIT)) {
			jput(j, ", \"elapsed\": "); jnum(j, ns.elapsed);
			jput(j, ", \"remaining\": "); jnum(j, ns.remaining);
		} else if (n.kind == BT_K_COOLDOWN && ns.remaining > 0.0f) {
			jput(j, ", \"remaining\": "); jnum(j, ns.remaining);
		}
		if (n.kind == BT_K_OPTION) {
			bt_worth w[64];
			int m = bt_state_worths(f, b->bt, n.parent, w, 64);

			for (k = 0; k < m && k < 64; k++) {
				if (w[k].option != i || !w[k].weighed) continue;
				jput(j, ", \"worth\": {\"score\": "); jnum(j, w[k].score);
				jput(j, ", \"weight\": "); jnum(j, w[k].weight);
				jput(j, ", \"factor\": "); jnum(j, w[k].factor);
				jput(j, ", \"luck\": "); jnum(j, w[k].luck);
				jput(j, ", \"sticky\": "); jnum(j, w[k].sticky);
				jput(j, ", \"worth\": "); jnum(j, w[k].worth);
				bt_node pk;

				if (bt_forest_node(f, n.parent, &pk) && pk.roll) {     /* a lottery: its part of it, and the draw */
					jput(j, ", \"share\": "); jnum(j, w[k].share);
					jput(j, ", \"draw\": "); jnum(j, w[k].draw);
				}
				jput(j, ", \"held\": %s}", w[k].held ? "true" : "false");
			}
		}
		jput(j, "}");
	}
}

static void tree_head(jb *j, const bc_bot *b, int tree, const char *role)
{
	const bt_forest *f = b->forest;
	bt_tree t, next;
	int path[BT_DEPTH_MAX], n, k;

	if (!bt_forest_tree(f, tree, &t))
		return;
	jput(j, "{\"role\": \"%s\", \"name\": ", role);
	jstr(j, t.name);
	jput(j, ", \"root\": %d, \"end\": %d, \"running\": [", t.root,
	     bt_forest_tree(f, tree + 1, &next) ? next.root : (int)bt_forest_nodes(f));
	n = b->alive ? bt_state_running(f, b->bt, tree, path, BT_DEPTH_MAX) : 0;
	for (k = 0; k < n && k < BT_DEPTH_MAX; k++) jput(j, "%s%d", k ? ", " : "", path[k]);
	jput(j, "]}");
}

size_t bc_engine_snapshot(const bc_engine *e, int pid, char *out, size_t out_size)
{
	const bc_bot *b = bot_at(e, pid);
	const bl_player *p;
	char line[240] = "", route[64];
	jb j;
	int t, first = 1;

	j.out = out_size ? out : NULL; j.size = out_size; j.len = 0;
	if (out && out_size) out[0] = 0;
	if (!b || !b->used)
		return 0;
	p = &e->w.players[b->pid];
	bc_engine_describe(e, pid, line, sizeof line);
	bc_route_text(b, route, sizeof route);
	jput(&j, "{\"format\": \"lsd-bt-snapshot\", \"version\": 1, \"time\": ");
	jnum(&j, e->now);
	jput(&j, ",\n  \"bot\": {");
	bot_head(&j, e, b);
	jput(&j, ",\n    \"pos\": ["); jnum(&j, p->pos.x); jput(&j, ", "); jnum(&j, p->pos.y); jput(&j, ", "); jnum(&j, p->pos.z);
	jput(&j, "], \"sees\": %d, \"knows\": %s, \"alert\": \"%s\", \"target\": %d, \"route\": ", b->senses.n_visible,
	     b->senses.nearest_known >= 0 || b->senses.n_visible > 0 ? "true" : "false", alert_name(b->senses.alert),
	     b->alive ? b->fight.target : -1);
	jstr(&j, route);
	jput(&j, ",\n    \"summary\": ");
	jstr(&j, line);
	jput(&j, ",\n    \"weights\": {");
	for (t = 0; t < BC_T_COUNT; t++) {
		jput(&j, "%s\"%s\": ", t ? ", " : "", bc_trait_name(t));
		jnum(&j, b->persona.trait[t]);
	}
	jput(&j, "},\n    \"facts\": {");
	bridge_json(&j, e, b);
	jput(&j, "}},\n  \"binding\": %u, \"traced\": %s,\n  \"trees\": [", (unsigned)b->binds, b->watched ? "true" : "false");
	if (b->forest && b->bt) {
		tree_head(&j, b, b->tree, "main");
		if (b->tree_also >= 0) { jput(&j, ", "); tree_head(&j, b, b->tree_also, "also"); }
	}
	jput(&j, "],\n  \"nodes\": [");
	if (b->forest && b->bt) {
		tree_nodes(&j, b, b->tree, &first);
		if (b->tree_also >= 0) tree_nodes(&j, b, b->tree_also, &first);
	}
	jput(&j, "\n  ]\n}\n");
	if (j.out && j.len >= j.size) j.out[0] = 0;        /* it did not fit: nothing, not a part */
	return j.len;
}

static void forest_names(jb *j, const bt_forest *f, const char *from, int *first)
{
	bt_tree t;
	int i;

	for (i = 0; f && bt_forest_tree(f, i, &t); i++) {
		if (!strcmp(t.name, "items") || !strcmp(t.name, "extras")) continue;    /* the engine's own writing */
		jput(j, "%s{\"name\": ", *first ? "" : ", ");
		*first = 0;
		jstr(j, t.name);
		jput(j, ", \"from\": \"%s\"}", from);
	}
}

size_t bc_engine_roster(const bc_engine *e, char *out, size_t out_size)
{
	jb j;
	int i, first = 1;

	j.out = out_size ? out : NULL; j.size = out_size; j.len = 0;
	if (out && out_size) out[0] = 0;
	if (!e)
		return 0;
	jput(&j, "{\"format\": \"lsd-bt-bots\", \"version\": 1, \"time\": ");
	jnum(&j, e->now);
	jput(&j, ",\n  \"world\": {\"tree\": ");
	jstr(&j, e->tree_name[0] ? e->tree_name : "default");
	jput(&j, ", \"night\": %s},\n  \"trees\": [", e->w.night ? "true" : "false");
	forest_names(&j, e->custom, "server", &first);
	forest_names(&j, e->builtin, "files", &first);
	if (!e->builtin) forest_names(&j, e->fallback, "fallback", &first);
	jput(&j, "],\n  \"bots\": [");
	for (i = 0, first = 1; i < e->max_bots; i++) {
		const bc_bot *b = &e->bots[i];

		if (!b->used) continue;
		jput(&j, "%s\n    {", first ? "" : ",");
		first = 0;
		bot_head(&j, e, b);
		jput(&j, "}");
	}
	jput(&j, "\n  ]\n}\n");
	if (j.out && j.len >= j.size) j.out[0] = 0;
	return j.len;
}
