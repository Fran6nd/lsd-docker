-- bots_ctl_test.lua -- lsdctl's `bots` commands: the tree editor's backend
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/bots_ctl_test.lua      (from the repository root)
--
-- Every operation bot/TREES.md specifies ("The editor's backend"), as far
-- as it goes with no server: the JSON each gives -- its format name, its
-- version, its fields -- and how each fails, which is JSON too. What needs
-- a running server and its bots (list, watch, apply reaching a bot,
-- revert) is checked here up to the point where it asks for the server,
-- and live in the image.
-- Skips (exit 0) if bot/build/bin/bttree is not built: make -C bot tools
local BTTREE = "bot/build/bin/bttree";
do
	local fh = io.open(BTTREE, "rb");
	if (fh == nil) then
		print("SKIP bots_ctl_test: " .. BTTREE .. " is not built (make -C bot tools)");
		os.exit(0);
	end
	fh:close();
end

package.path = "catalog/libs/map_layout/map_layout/?.lua;" .. package.path;
local J = require("json");

local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what) else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end

local function sh(cmd)
	local p = io.popen(cmd);
	local out = p:read("*a");
	p:close();
	return out;
end

local luajit = arg[-1] or "luajit";
local HOME = sh("pwd"):gsub("%s+$", "");
local DATA = sh("mktemp -d"):gsub("%s+$", "");
local ENV = string.format("LSD_HOME=%q LSD_DATA=%q LSD_BTTREE=%q LSD_BOT_TREES=%q ", HOME, DATA,
	HOME .. "/" .. BTTREE, HOME .. "/bot/trees");

-- lsdctl bots <args>, with `input` on its standard input: what it wrote
-- there, its status, and what it said on the standard error
local function bots(args, input)
	local inf = DATA .. "/in.txt";
	local fh = io.open(inf, "wb");
	fh:write(input or "");
	fh:close();
	local out = sh(ENV .. luajit .. " image/ctl/lsdctl.lua bots " .. args .. " < " .. inf .. " 2>" .. DATA .. "/err.txt; echo \"EXIT:$?\"");
	local code = tonumber(out:match("EXIT:(%d+)%s*$"));
	out = out:gsub("EXIT:%d+%s*$", "");
	local ef = io.open(DATA .. "/err.txt", "rb");
	local err = ef:read("*a");
	ef:close();
	return out, code, err;
end

local function decode(text)
	local ok, v = pcall(J.decode, text);
	return ok and type(v) == "table" and v or nil;
end

local GOOD = "tree sentry:   # keeps a post\nselect\n    seq\n        if enemy_visible\n        do fight\n    do hold self 10\n";
local BAD = "tree sentry:\nselect\n\tseq\n\t\tif enemy_within near\n\t\tdo figth\n\tdo go_to nowhere\n";

print("\n1. schema: all a tree may be made of");
do
	local out, code = bots("schema");
	local d = decode(out);
	check(code == 0 and d ~= nil and d.format == "lsd-bt-schema" and d.version == 3, "it is JSON, named and versioned", code);
	check(d ~= nil and #d.kinds == 15 and #d.conditions > 30 and #d.scores > 20 and #d.actions > 20 and #d.traits == 11
		and #d.archetypes == 7 and #d.places > 20 and #d.values >= 15, "the kinds, the words, the values, the traits, the archetypes, the places");
	local go;
	for _, w in ipairs(d and d.actions or {}) do if (w.name == "go_to") then go = w; end end
	check(go ~= nil and go.usage == "<place> [radius]" and go.args[1].type == "place" and go.args[1].required == true
		and go.args[2].type == "number" and go.args[2].default == 2, "a word's arguments are data: type, required, default");
	-- all an editor needs to draw and build every form, with no knowledge of its own
	local kind = {};
	for _, k in ipairs(d and d.kinds or {}) do kind[k.name] = k; end
	local function param(k, name)
		for _, p in ipairs(kind[k] and kind[k].params or {}) do if (p.name == name) then return p; end end
	end
	local value = {};
	for _, v in ipairs(d and d.values or {}) do value[v.name] = v; end
	check(value.enemy_distance ~= nil and value.enemy_distance.unit == "voxels" and value.enemy_distance.min == 0
		and value.enemy_distance.max == nil and value.enemy_distance.doc:find("unknown", 1, true) ~= nil
		and value.health ~= nil and value.health.min == 0 and value.health.max == 100
		and value.distance ~= nil and value.distance.usage == "<place>" and value.distance.args[1].type == "place",
		"the values: each with its arguments, unit, range and doc");
	local ops = {};
	for _, o in ipairs(d and d.operators or {}) do ops[#ops + 1] = o.op; end
	check(table.concat(ops, " ") == "< <= > >=" and d.comparison ~= nil and d.comparison.unknown ~= nil and d.comparison.as_score ~= nil,
		"the operators, and what a comparison answers");
	local cond, score = param("if", "cond"), param("option", "score");
	check(cond ~= nil and cond["or"] ~= nil and cond["or"].form == "comparison" and #cond["or"].params == 3
		and cond["or"].params[1].type == "value" and cond["or"].params[2].values[4] == ">=" and cond["or"].params[3].type == "number"
		and score ~= nil and score["or"] ~= nil and score["or"].form == "comparison" and param("unless", "cond")["or"] ~= nil,
		"a guard takes a condition or a comparison, an option's score a score or a comparison");
	local blk = kind["if"] and kind["if"].block;
	check(blk ~= nil and blk.children == "many" and blk.tries == "all" and blk.roles[1].role == "then"
		and blk.roles[2].role == "otherwise" and blk.roles[2].kind == "else" and blk.roles[2].optional == true
		and kind["if"].children == "none" and kind["unless"].block ~= nil
		and kind["else"] ~= nil and kind["else"].children == "many" and kind["else"].parent == "if"
		and #kind["else"].parents == 2 and kind["else"].position == "last" and kind["else"].indent == "parent",
		"the block form: which kinds hold children, how many, and the role of each child list");
	check(kind.seq.tries == "all" and kind.select.tries == "first" and kind["if"].guard.negates == false
		and kind.unless.guard.negates == true, "how a kind tries its children, and whether a guard negates");
	local roll = param("pick", "roll");
	check(roll ~= nil and #roll.leaves_out.once == 3 and #roll.leaves_out.life == 3 and #roll.leaves_out.each == 2
		and roll.leaves_out.each[1] == "sticky", "which settings a roll leaves out");
	local trees = {};
	for _, t in ipairs(d and d.engine_trees or {}) do trees[t.name] = t.doc; end
	check(trees.items ~= nil and trees.extras ~= nil and d.companion.suffix == "_also" and d.companion.doc ~= nil
		and d.types.place.list == "places" and d.types.place.script.prefix == "@",
		"the trees the engine writes, the companion tree, a script's place");
	local short;
	for _, w in ipairs(d and d.conditions or {}) do if (w.name == "health_below") then short = w.short_for; end end
	check(short == "health < <hp>", "a condition short for a comparison says so", short);
end

print("\n2. trees: what there is, and one of them");
do
	local out, code = bots("trees --json");
	local d = decode(out);
	check(code == 0 and d ~= nil and d.format == "lsd-bt-trees" and d.version == 1, "the list is JSON, named and versioned", out:sub(1, 80));
	local tdm, n = nil, 0;
	for _, t in ipairs(d and d.trees or {}) do
		n = n + 1;
		if (t.name == "tdm") then tdm = t; end
	end
	check(n > 10 and tdm ~= nil and tdm.from == "builtin" and tdm.nodes > 5 and tdm.file:find("tdm.bt", 1, true) ~= nil
		and type(tdm.refers) == "table" and tdm.line > 0, "each tree: name, where from, file, line, size, what it refers to");
	out, code = bots("trees");
	check(code == 0 and out:find("tdm ") ~= nil and out:find("builtin", 1, true) ~= nil, "and as a table for a person");

	out, code = bots("tree default_cover");
	check(code == 0 and out == "tree default_cover:\nseq\n\tdo crouch                                 # the flinch, facing the shot\n"
		.. "\tselect\n\t\tseq\n\t\t\tif cover_in_view                  # cover it can see as it faces him\n"
		.. "\t\t\tdo take_cover in_view             # there, its eyes on him all the way\n"
		.. "\t\tdo crouch 3                           # none: down where it stands, facing him\n",
		"one tree as text, canonical", out);
	out, code = bots("tree default_cover --json");
	d = decode(out);
	local t = d and d.files and d.files[1] and d.files[1].trees[1];
	check(code == 0 and d ~= nil and d.format == "lsd-bt" and d.version == 1 and #d.files[1].trees == 1 and t.name == "default_cover"
		and t.root.kind == "seq" and #t.root.children == 2 and t.root.children[1].action == "crouch", "and as a JSON tree, it alone");
	local err;
	out, code, err = bots("tree no_such_tree --json");
	d = decode(out);
	check(code == 1 and d ~= nil and d.format == "lsd-bt-error" and d.ok == false and d.error:find("no_such_tree", 1, true) ~= nil,
		"a tree there is none of: an error, as JSON, status 1", out);
	out, code, err = bots("tree no_such_tree");
	check(code == 1 and out == "" and err:find("no tree is called", 1, true) ~= nil, "or as a line on the standard error");
end

print("\n3. check: every mistake of a text");
do
	local out, code = bots("check - --json", GOOD);
	local d = decode(out);
	check(code == 0 and d ~= nil and d.format == "lsd-bt-check" and d.version == 1 and d.ok == true and #d.diagnostics == 0
		and d.trees[1] == "sentry", "a text that compiles", out);
	out, code = bots("check - --json", BAD);
	d = decode(out);
	check(code == 1 and d ~= nil and d.ok == false and #d.diagnostics == 3, "one that does not: status 1, and all three mistakes", out);
	local a, b, c = d and d.diagnostics[1], d and d.diagnostics[2], d and d.diagnostics[3];
	check(a ~= nil and a.line == 4 and a.column == 19 and a.message:find("is a number", 1, true) ~= nil
		and b.line == 5 and b.message:find("no action called figth", 1, true) ~= nil
		and c.line == 6 and c.message:find("no place called nowhere", 1, true) ~= nil, "each with its line, column and message");
	out, code = bots("check -", BAD);
	check(code == 1 and out:find("line 5, column 6: no action called figth", 1, true) ~= nil, "for a person, a line each", out);
	local fh = io.open(DATA .. "/good.bt", "wb"); fh:write(GOOD); fh:close();
	out, code = bots("check " .. DATA .. "/good.bt");
	check(code == 0 and out == "ok\n", "a file, by its path");
	out, code = bots("check --json", "");
	d = decode(out);
	check(code == 1 and d ~= nil and d.format == "lsd-bt-error", "nothing given: an error");
end

print("\n4. format: the canonical text, from text or from a JSON tree");
local CANON = "tree sentry:                                  # keeps a post\nselect\n\tseq\n\t\tif enemy_visible\n\t\tdo fight\n\tdo hold self 10\n";
do
	local out, code = bots("format -", GOOD);
	check(code == 0 and out == CANON, "tabs, the comment in its column", out);
	out, code = bots("format - --json", GOOD);
	local d = decode(out);
	check(code == 0 and d ~= nil and d.format == "lsd-bt-text" and d.version == 1 and d.ok == true and d.text == CANON, "as JSON: the text in a field");
	local ast = [[{"trees": [{"name": "sentry", "comment": "keeps a post", "root": {"kind": "select", "children": [
		{"kind": "seq", "children": [{"kind": "if", "cond": "enemy_visible"}, {"kind": "do", "action": "fight"}]},
		{"kind": "do", "action": "hold", "args": ["self", 10]}]}}]}]];
	out, code = bots("format -", ast);
	check(code == 0 and out == CANON, "a JSON tree (what an editor holds) comes out the same text", out);
	out, code = bots("format - --json", BAD);
	d = decode(out);
	check(code == 1 and d ~= nil and d.format == "lsd-bt-error" and #d.diagnostics == 3, "a text that does not compile is not formatted: its mistakes");
	out, code = bots("format - --json", '{"trees": [{"name": "x", "root": {"kind": "do", "action": "figth"}}]}');
	d = decode(out);
	check(code == 1 and d ~= nil and d.format == "lsd-bt-error" and d.error:find("figth", 1, true) ~= nil, "nor a JSON tree with a word there is none of");
	-- every form of the language, comments on the else lines too: text -> JSON (bttree --json) -> text
	local FORMS = "# a decision\ntree duel:                                    # the owner's sentence\n"
		.. "select\n\tif enemy_distance < 5                     # near: fire back\n\t\tdo fight\n"
		.. "\t# else, hide\n\telse                                      # otherwise\n"
		.. "\t\tunless health_below 30\n\t\t\tdo take_cover\n\t\telse\n\t\t\tpick every=1\n"
		.. "\t\t\t\toption caution health < 40 x2\n\t\t\t\t\tdo retreat\n"
		.. "\t\t\t\toption none distance @gate >= 2.5\n\t\t\t\t\tdo go_to @gate\n"
		.. "\tdo seek\n";
	out, code = bots("format -", FORMS);
	check(code == 0 and out == FORMS, "if blocks, else, comparisons, a comparison as a score: canonical as written", out);
	local f = io.open(DATA .. "/forms.bt", "wb");
	f:write(FORMS);
	f:close();
	local json = sh(BTTREE .. " --json " .. DATA .. "/forms.bt");
	d = decode(json);
	local root = d and d.files[1].trees[1].root;
	local blk = root and root.children[1];
	check(blk ~= nil and blk.kind == "if" and blk.value == "enemy_distance" and blk.op == "<" and blk.number == 5
		and blk.children[2].kind == "else" and blk.children[2].comment == "otherwise" and blk.children[2].above[1] == "# else, hide"
		and blk.children[2].children[1].cond == "health_below", "as JSON: the comparison's fields, the else a last child with its comments", json:sub(1, 120));
	out, code = bots("format -", json);
	check(code == 0 and out == FORMS, "and back from JSON, the same text", out);
end

print("\n5. save: a text kept as an operator's tree");
do
	local out, code = bots("save sentry --json", GOOD);
	local d = decode(out);
	check(code == 0 and d ~= nil and d.format == "lsd-bt-saved" and d.version == 1 and d.ok == true
		and d.file == DATA .. "/trees/sentry.bt" and d.trees[1] == "sentry", "saved: where, and the trees in it", out);
	local fh = io.open(DATA .. "/trees/sentry.bt", "rb");
	local text = fh and fh:read("*a");
	if (fh) then fh:close(); end
	check(text == CANON, "the file holds the canonical text", text);
	check(sh("ls " .. DATA .. "/trees"):gsub("%s+$", "") == "sentry.bt", "and nothing else was left beside it");
	for _, name in ipairs({"../evil", "a/b", "/tmp/x", "a.b", "with space", string.rep("n", 40), ""}) do
		out, code = bots(string.format("save %q --json", name), GOOD);
		d = decode(out);
		check(code == 1 and d ~= nil and d.format == "lsd-bt-error", "a name that is not one is refused: " .. name:sub(1, 12), out);
	end
	check(sh("ls " .. DATA .. "/trees; ls /tmp/x.bt 2>/dev/null"):gsub("%s+$", "") == "sentry.bt", "and no file was written for any of them");
	out, code = bots("save broken --json", BAD);
	d = decode(out);
	check(code == 1 and d ~= nil and d.format == "lsd-bt-error" and #d.diagnostics == 3
		and io.open(DATA .. "/trees/broken.bt", "rb") == nil, "a text that does not compile is not saved");
	-- it is among the trees now, as the operator's; one named like a built-in replaces it
	bots("save mine_tdm", "tree tdm:\ndo seek\n");
	out = bots("trees --json");
	d = decode(out);
	local user, replaced, mine = 0, false, false;
	for _, t in ipairs(d and d.trees or {}) do
		if (t.from == "user") then user = user + 1; end
		if (t.name == "tdm" and t.from == "builtin" and t.replaced == true) then replaced = true; end
		if (t.name == "sentry" and t.from == "user") then mine = true; end
	end
	check(user == 2 and mine and replaced, "the saved trees are listed as the operator's; a built-in of the same name says it is replaced", out:sub(1, 200));
	out, code = bots("tree sentry");
	check(code == 0 and out == CANON, "and one is had back as it was saved");
	os.remove(DATA .. "/trees/mine_tdm.bt");
end

print("\n6. apply and revert: refused before anybody is touched");
do
	local out, code = bots("apply - --all --json", BAD);
	local d = decode(out);
	check(code == 1 and d ~= nil and d.format == "lsd-bt-error" and d.ok == false and #d.diagnostics == 3
		and d.error:find("nothing was changed", 1, true) ~= nil, "a text that does not compile: its mistakes, and nothing changed", out);
	out, code = bots("apply - --bot 3 --json", "tree big:\nselect\n" .. string.rep("\tdo hold self 10            # padding padding padding padding padding\n", 1000));
	d = decode(out);
	check(code == 1 and d ~= nil and d.format == "lsd-bt-error" and d.error:find("the most is 60000", 1, true) ~= nil, "a text over the most a tree may be", out:sub(1, 120));
	out, code = bots("apply no_such_tree --all --json");
	d = decode(out);
	check(code == 1 and d ~= nil and d.format == "lsd-bt-error" and d.error:find("no tree is called", 1, true) ~= nil, "a name there is no tree of");
	-- from here a server is needed: with none, that is what is said
	out, code = bots("apply tdm --all --json");
	d = decode(out);
	check(code == 1 and d ~= nil and d.format == "lsd-bt-error" and d.error == "the server is not running", "a tree by name, no server: said", out);
	out, code = bots("apply - --bot 3 --json", GOOD);
	d = decode(out);
	check(code == 1 and d ~= nil and d.error == "the server is not running", "a good text, no server: said");
	out, code = bots("revert --all --json");
	d = decode(out);
	check(code == 1 and d ~= nil and d.format == "lsd-bt-error" and d.error == "the server is not running", "revert, no server: said");
	check(sh("ls " .. DATA .. "/rw 2>/dev/null"):gsub("%s+$", "") == "", "and no file was left for the server to read");
end

print("\n7. list and watch need the server too; the count is as it was");
do
	local out, code = bots("list --json");
	local d = decode(out);
	check(code == 1 and d ~= nil and d.format == "lsd-bt-error" and d.error == "the server is not running", "list, no server: an error as JSON");
	out, code = bots("watch --once --json");
	d = decode(out);
	check(code == 1 and d ~= nil and d.format == "lsd-bt-error", "watch, no server: the same");
	local err;
	out, code, err = bots("list");
	check(code == 1 and err:find("the server is not running", 1, true) ~= nil, "for a person: a line on the standard error");
	out, code, err = bots("nonsense");
	check(code == 1 and err:find("bots <n>", 1, true) ~= nil, "a word that is no command says what there is");
	-- `bots <n>` is still the count
	sh(ENV .. luajit .. " image/ctl/lsdctl.lua setup --defaults 2>&1");
	out, code = bots("4 --no-restart");
	local got = sh(ENV .. luajit .. " image/ctl/lsdctl.lua get engine_bots_count 2>&1"):gsub("%s+$", "");
	check(code == 0 and got == "4", "bots <n> sets how many, as before", got);
end

sh("rm -rf " .. DATA);
print(string.format("\nbots_ctl_test: %d passed, %d failed", checks - failures, failures));
os.exit(failures == 0 and 0 or 1);
