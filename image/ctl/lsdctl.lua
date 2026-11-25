-- lsdctl.lua -- Administer the LSD server from inside its container
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   docker exec -it lsd lsdctl <command>          a running server
--   docker run --rm -it -v lsd-data:/data IMAGE <command>   a stopped one
--
-- Everything here is a change to the settings file, a change to the
-- maps folder, or a line sent to the server's console. The settings
-- file is the whole of the installed state -- which scripts, which
-- gamemode, every value -- so nothing done here is hidden anywhere
-- else, and editing the file by hand is equally supported.
--
-- Run with luajit. Shares catalog.lua and settings_format.lua with the
-- server, so the two read the same file the same way.

local HOME = os.getenv("LSD_HOME") or "/lsd";
local DATA = os.getenv("LSD_DATA") or "/data";

package.path = HOME .. "/catalog/core/?.lua;" .. package.path;
package.cpath = HOME .. "/exec/?.so;" .. package.cpath;

local F = require "settings_format";
local catalog = require "catalog";

local SETTINGS = DATA .. "/settings";
local MAPS = DATA .. "/maps";
local SOCK = DATA .. "/rw/console.sock";
local ROOTS = {HOME .. "/catalog", DATA .. "/catalog"};

--============================== PLUMBING ============================--

local function die(fmt, ...)
	io.stderr:write("lsdctl: " .. string.format(fmt, ...) .. "\n");
	os.exit(1);
end

local function say(fmt, ...)
	io.write(string.format(fmt, ...), "\n");
end

local function sh_quote(s)
	return "'" .. string.gsub(tostring(s), "'", "'\\''") .. "'";
end

-- os.execute's result differs between Lua 5.1 (a number) and 5.2+.
local function run(cmd)
	local a, _, c = os.execute(cmd);
	if (type(a) == "number") then return a == 0; end
	return a == true and (c == nil or c == 0);
end

local function read_file(path)
	local f = io.open(path, "rb");
	if (f == nil) then return nil; end
	local s = f:read("*a");
	f:close();
	return s;
end

-- Written beside and renamed over, so the server never reads half a
-- file, and an editor holding the old one sees the change.
local function write_file(path, text)
	local tmp = path .. ".tmp";
	local f = assert(io.open(tmp, "wb"));
	f:write(text);
	f:close();
	assert(os.rename(tmp, path));
end

local function exists(path)
	return run("test -e " .. sh_quote(path));
end

local function interactive()
	return os.getenv("LSDCTL_YES") == nil and run("test -t 0");
end

local function version()
	local v = read_file(HOME .. "/VERSION") or "dev\n";
	local c = read_file(HOME .. "/LSD_COMMIT") or "unknown\n";
	return (string.gsub(v, "%s+$", "")), (string.gsub(c, "%s+$", ""));
end

-- Which sandbox the server binary was built with; see the Dockerfile.
local function sandbox()
	local s = string.gsub(read_file(HOME .. "/exec/SANDBOX") or "unknown", "%s+$", "");
	if (s == "none") then
		return "no seccomp (upstream's filter does not support this arch)";
	end
	return s;
end

-- A reader for catalog.open over the shell, so lsdctl needs nothing
-- compiled -- lfs is used when it is there.
local function reader()
	local ok, lfs = pcall(require, "lfs");
	if (ok) then return catalog.lfs_reader(lfs); end

	return {
		exists = exists,
		dirs = function(p)
			local names = {};
			local h = io.popen("cd " .. sh_quote(p)
				.. " 2>/dev/null && for d in */; do [ -d \"$d\" ] && echo \"${d%/}\"; done");
			for n in h:lines() do names[#names+1] = n; end
			h:close();
			local i = 0;
			return function() i = i + 1; return names[i]; end;
		end,
		loadfile = loadfile,
	};
end

local cat_cache;
local function cat()
	if (cat_cache == nil) then
		cat_cache = catalog.open(ROOTS, reader());
		for _, e in ipairs(cat_cache.errors) do
			io.stderr:write("lsdctl: catalog: " .. e .. "\n");
		end
	end
	return cat_cache;
end

-- What a new server runs: every protocol extension -- each at its own
-- policy, which is never "required", so no client is turned away -- and
-- votekick, time_limit, rewards and vote_map.
local function default_scripts()
	local ids = {};
	for _, e in ipairs(cat():of_class(catalog.Extension)) do
		if (e.listed) then ids[#ids+1] = e.id; end
	end
	ids[#ids+1] = "votekick";
	ids[#ids+1] = "time_limit";
	ids[#ids+1] = "rewards";
	ids[#ids+1] = "vote_map";
	return ids;
end

local function entry(name)
	local e = cat():find(name);
	if (e == nil) then
		die("no script %q in the catalog (lsdctl available)", name);
	end
	return e;
end

--=============================== CONSOLE ============================--

-- The server's admin console is a unix socket (sock_console). A call
-- is a few lines in and whatever the server logs back for `wait`
-- seconds. Replies are found by a marker the server prints, which the
-- console's echo of the command does not contain: the command spells
-- it in two halves.
local function console_up()
	return run("test -S " .. sh_quote(SOCK));
end

local function console(lines, wait)
	if (not console_up()) then
		return nil;
	end

	local tmp = os.tmpname();
	local f = assert(io.open(tmp, "w"));
	for _, l in ipairs(lines) do f:write(l, "\n"); end
	f:close();

	local h = io.popen(string.format(
		"(cat %s; sleep %s) | socat - UNIX-CONNECT:%s 2>/dev/null",
		sh_quote(tmp), tostring(wait or 1), sh_quote(SOCK)));
	local out = h:read("*a");
	h:close();
	os.remove(tmp);

	return out;
end

-- Lines of the reply carrying `marker`, with the marker and anything
-- before it removed.
local function replies(out, marker)
	local got = {};
	for line in string.gmatch(out or "", "[^\n]+") do
		local s, e = string.find(line, marker, 1, true);
		if (s ~= nil) then got[#got+1] = string.sub(line, e + 1); end
	end
	return got;
end

local function running()
	local out = console({'exec log("LSDCTL" .. "-PONG|")'}, 1);
	return out ~= nil and #replies(out, "LSDCTL-PONG|") > 0;
end

--============================ SETTINGS FILE =========================--

local Doc = {};
Doc.__index = Doc;

local function open_doc(must)
	local text = read_file(SETTINGS);
	if (text == nil and must) then
		die("no settings yet in %s -- run: lsdctl setup", SETTINGS);
	end

	local d = setmetatable({text = text or ""}, Doc);
	d:reparse();
	return d;
end

function Doc:reparse()
	local warnings = {};
	self.values = F.parse(self.text, function(n, msg)
		warnings[#warnings+1] = string.format("line %d: %s", n, msg);
	end);
	self.warnings = warnings;
end

function Doc:get(k)
	return self.values[k];
end

function Doc:set(k, v, opts)
	local text, err = F.set(self.text, k, v, opts);
	if (text == nil) then die("%s: %s", k, err); end
	self.text = text;
	self:reparse();
end

function Doc:unset(k)
	local changed;
	self.text, changed = F.unset(self.text, k);
	self:reparse();
	return changed;
end

-- ext_policy, with every extension named in a comment beside its id,
-- since 0x32 says nothing to anybody reading the file.
function Doc:set_policy(map)
	local notes = {};
	for _, e in ipairs(cat():of_class(catalog.Extension)) do
		for _, x in ipairs(e:ext_list()) do
			notes[x.id] = x.title;
		end
	end
	self:set("ext_policy", map, {notes = notes});
end

function Doc:installed()
	local s = self.values.scripts;
	return type(s) == "table" and s or {};
end

function Doc:is_installed(id)
	for _, x in ipairs(self:installed()) do
		if (x == id) then return true; end
	end
	return false;
end

function Doc:set_installed(list)
	self:set("scripts", list);
end

-- What a script's section says, and the preset its header names.
function Doc:section(id)
	local text = F.section(self.text, id);
	if (text == nil) then return nil; end

	local preset = string.match(text, "^[^\n]*preset (%S+)");
	return (F.parse(text)), preset;
end

-- Rewrite a script's section from its setup: the keys the setup decides
-- come from `values`; keys the operator added by hand are kept. A key
-- the setup decides that is set elsewhere in the file moves here, so
-- the file never says one thing twice.
function Doc:write_section(e, values, preset)
	local old = self:section(e.id) or {};
	local decided = {};
	for _, k in ipairs(e:setup_keys()) do decided[k] = true; end

	local merged = {};
	for k, v in pairs(old) do
		if (not decided[k]) then merged[k] = v; end
	end
	for k, v in pairs(values) do merged[k] = v; end

	self.text = F.remove_section(self.text, e.id);
	self:reparse();
	for k in pairs(merged) do
		if (self.values[k] ~= nil) then self:unset(k); end
	end

	local asks = {};
	for _, q in ipairs(e.questions) do asks[q.key] = q.ask; end

	local keys = {};
	for k in pairs(merged) do keys[#keys+1] = k; end
	table.sort(keys);

	local body = {};
	for _, k in ipairs(keys) do
		if (asks[k] ~= nil) then body[#body+1] = "# " .. asks[k]; end
		local a = F.assignment(k, merged[k]);
		if (a ~= nil) then
			for line in string.gmatch(a, "[^\n]+") do body[#body+1] = line; end
		end
	end
	if (#body == 0) then
		body[1] = "# (nothing set; `lsdctl info " .. e.id
			.. "` lists what it supports)";
	end

	local title = e:label() .. ", " .. e:kind()
		.. (preset and (", preset " .. preset) or "");
	self.text = F.add_section(self.text, e.id, title, body);
	self:reparse();
end

function Doc:remove_section(id)
	self.text = F.remove_section(self.text, id);
	self:reparse();
end

function Doc:save()
	write_file(SETTINGS, self.text);
end

--================================= UI ===============================--

-- Questions on a terminal; defaults everywhere else, so every command
-- works the same from a script (or with --yes).
local UI = {};
UI.__index = UI;

local function make_ui(force_defaults)
	return setmetatable({tty = not force_defaults and interactive()}, UI);
end

local function prompt(text)
	io.write(text);
	io.flush();
	local line = io.read("*l");
	if (line == nil) then
		io.write("\n");
		os.exit(130);
	end
	return (string.gsub(line, "^%s*(.-)%s*$", "%1"));
end

function UI:choose(question, items, default)
	if (not self.tty) then
		return default or items[1].value;
	end

	say("");
	say("%s:", question);
	local def_i = 1;
	for i, it in ipairs(items) do
		if (it.value == default) then def_i = i; end
		say("  %d) %-14s %s", i, it.label, it.hint or "");
	end

	while (true) do
		local a = prompt(string.format("choice [%d]: ", def_i));
		if (a == "") then return items[def_i].value; end

		local n = tonumber(a);
		if (n ~= nil and items[n] ~= nil) then return items[n].value; end
		for _, it in ipairs(items) do
			if (it.value == a) then return it.value; end
		end
		say("  pick a number from 1 to %d", #items);
	end
end

-- Several of a list. `chosen` is a set of values picked to start with.
function UI:pick_many(question, items, chosen)
	if (not self.tty) then
		local out = {};
		for _, it in ipairs(items) do
			if (chosen[it.value]) then out[#out+1] = it.value; end
		end
		return out;
	end

	say("");
	say("%s", question);
	local def = {};
	for i, it in ipairs(items) do
		local on = chosen[it.value];
		if (on) then def[#def+1] = tostring(i); end
		say("  %s %2d) %-18s %s", on and "*" or " ", i, it.label, it.hint or "");
	end

	while (true) do
		local a = prompt(string.format(
			"numbers separated by spaces, - for none [%s]: ",
			#def > 0 and table.concat(def, " ") or "-"));
		if (a == "") then a = #def > 0 and table.concat(def, " ") or "-"; end

		local out, bad = {}, nil;
		if (a ~= "-") then
			for w in string.gmatch(a, "[^%s,]+") do
				local n = tonumber(w);
				if (n == nil or items[n] == nil) then bad = w; break; end
				out[#out+1] = items[n].value;
			end
		end

		if (bad == nil) then return out; end
		say("  %q is not one of the numbers above", bad);
	end
end

function UI:ask(q, current)
	if (current == nil) then current = q.default; end
	if (not self.tty) then return current; end

	local shown = current;
	if (q.type == "boolean") then shown = current and "y" or "n"; end

	while (true) do
		local a = prompt(string.format("%s [%s]: ", q.ask or q.key,
			tostring(shown == nil and "" or shown)));

		if (a == "") then return current; end

		if (q.type == "boolean") then
			local l = string.lower(a);
			if (l == "y" or l == "yes") then return true; end
			if (l == "n" or l == "no") then return false; end
			say("  y or n");
		elseif (q.type == "number") then
			local n = tonumber(a);
			if (n == nil) then
				say("  a number, please");
			elseif ((q.min and n < q.min) or (q.max and n > q.max)) then
				say("  between %s and %s", tostring(q.min), tostring(q.max));
			else
				return n;
			end
		else
			return a;
		end
	end
end

function UI:confirm(question, default)
	if (not self.tty) then return default; end
	local a = string.lower(prompt(question .. (default and " [Y/n]: " or " [y/N]: ")));
	if (a == "") then return default; end
	return a == "y" or a == "yes";
end

--============================ ARGUMENTS =============================--

-- Flags anywhere, words in order. A flag that takes a value is named in
-- `valued`.
local function parse_args(args, valued)
	local words, flags = {}, {};
	local i = 1;
	while (i <= #args) do
		local a = args[i];
		local long = string.match(a, "^%-%-([%w-]+)$");
		if (long ~= nil and valued[long]) then
			flags[long] = args[i + 1] or die("--%s needs a value", long);
			i = i + 2;
		elseif (long ~= nil) then
			flags[long] = true;
			i = i + 1;
		elseif (a == "-y") then
			flags.yes = true;
			i = i + 1;
		else
			words[#words+1] = a;
			i = i + 1;
		end
	end
	return words, flags;
end

--============================== APPLYING ============================--

-- Changes to which scripts load, or to the gamemode, need the server
-- restarted: the load order is decided once, at start. The players are
-- warned first and the container stays up -- the entrypoint restarts
-- the server process when it exits.
local function restart(message, delay)
	if (not console_up()) then
		say("server not running: applies when it starts");
		return false;
	end

	delay = delay or 5;
	local lines = {};
	if (delay > 0) then
		lines[#lines+1] = "say " .. (message or string.format(
			"Server restarts in %d seconds to apply changes.", delay));
	end
	console(lines, delay);
	console({"exec os.exit(0)"}, 1);
	say("server restarting");
	return true;
end

-- Every change is applied by restarting the server process: the
-- settings are read once, at start, into the globals the modules read.
-- Players are warned first; the container stays up.
local function apply(flags)
	if (flags["no-restart"]) then
		say("saved; apply with: lsdctl restart");
	else
		restart(nil, flags.now and 0 or 5);
	end
end

--============================ THE COMMANDS ==========================--

local commands = {};
local help = {};

local function command(name, usage, text, fn)
	commands[name] = fn;
	help[#help+1] = {name = name, usage = usage, text = text};
end

local function category_title(e)
	for _, c in ipairs(catalog.CATEGORIES) do
		if (e:is_a(c.class)) then return c.title; end
	end
	return "?";
end

-- Run a script's setup and write what it decides. Used by install,
-- configure, gamemode and the setup wizard.
local function setup_entry(doc, e, ui, flags)
	local current, current_preset = doc:section(e.id);
	current = current or {};
	current.ext_policy = doc:get("ext_policy");

	local any = #e:preset_names() > 0 or #e.questions > 0
		or e:is_a(catalog.Extension);
	if (ui.tty and any) then
		say("");
		say("== %s (%s): %s", e:label(), e.id, e.summary or "");
	end

	local values, preset = e:setup(ui, current, {preset = flags.preset,
		policy = flags.policy, current_preset = current_preset});

	if (next(values) ~= nil or preset ~= nil or doc:section(e.id) ~= nil) then
		doc:write_section(e, values, preset);
	end
	e:on_install(doc, values);
end

-- The installed list closed under dependencies, so a library pulled in
-- by a script is recorded too and nothing has to be worked out twice.
local function install_ids(doc, ids, ui, flags)
	local list = doc:installed();
	local have = {};
	for _, x in ipairs(list) do have[x] = true; end

	local added = {};
	local entries, missing = cat():closure(ids);
	if (#missing > 0) then
		die("not in the catalog: %s", table.concat(missing, ", "));
	end

	for _, e in ipairs(entries) do
		if (e:is_a(catalog.Gamemode)) then
			die("%s is a gamemode: lsdctl gamemode %s", e.id, e.id);
		end
		if (not have[e.id]) then
			have[e.id] = true;
			list[#list+1] = e.id;
			added[#added+1] = e;
		end
	end

	doc:set_installed(list);

	-- the scripts named run their setup even when already installed;
	-- that is what installing again is for
	local named = {};
	for _, id in ipairs(ids) do named[cat():find(id).id] = true; end
	for _, e in ipairs(entries) do
		if (named[e.id] or not doc:section(e.id)) then
			setup_entry(doc, e, ui, named[e.id] and flags or {});
		end
	end

	return added;
end

command("install", "install <script>... [--preset P] [--policy L] [--yes] [--no-restart]",
	"install scripts (and what they need), running each one's setup",
	function(args)
		local words, flags = parse_args(args, {preset = true, policy = true});
		if (#words == 0) then die("install what? (lsdctl available)"); end

		local doc = open_doc(true);
		local added = install_ids(doc, words, make_ui(flags.yes), flags);
		doc:save();

		for _, e in ipairs(added) do say("installed %s (%s)", e.id, e:kind()); end
		if (#added == 0) then say("already installed; settings updated"); end
		apply(flags);
	end);

command("remove", "remove <script>... [--no-restart]",
	"uninstall scripts; libraries nothing else needs go with them",
	function(args)
		local words, flags = parse_args(args, {});
		if (#words == 0) then die("remove what? (lsdctl list)"); end

		local doc = open_doc(true);
		local gone = {};
		for _, w in ipairs(words) do
			local e = entry(w);
			if (not doc:is_installed(e.id)) then die("%s is not installed", e.id); end
			gone[e.id] = true;
		end

		-- what is still needed once those are gone: every remaining
		-- script's dependencies, so an orphaned library goes too but a
		-- shared one stays
		local keep = {};
		for _, id in ipairs(doc:installed()) do
			local e = cat():find(id);
			if (not gone[id] and (e == nil or not e:is_a(catalog.Library))) then
				keep[#keep+1] = id;
			end
		end
		keep[#keep+1] = doc:get("gamemode") or "ctf";
		local needed = {};
		for _, e in ipairs((cat():closure(keep))) do needed[e.id] = true; end

		for id in pairs(gone) do
			if (needed[id]) then die("%s is needed by another installed script", id); end
		end

		local list = {};
		for _, id in ipairs(doc:installed()) do
			local e = cat():find(id);
			if (needed[id] or (e == nil and not gone[id])) then
				list[#list+1] = id;
			else
				if (e ~= nil) then e:on_remove(doc); end
				doc:remove_section(id);
				say("removed %s", id);
			end
		end

		doc:set_installed(list);
		doc:save();
		apply(flags);
	end);

command("configure", "configure <script> [--preset P] [--policy L] [--yes]",
	"run an installed script's setup again",
	function(args)
		local words, flags = parse_args(args, {preset = true, policy = true});
		if (#words ~= 1) then die("configure which script?"); end

		local doc = open_doc(true);
		local e = entry(words[1]);
		if (not e:is_a(catalog.Gamemode) and not doc:is_installed(e.id)) then
			die("%s is not installed (lsdctl install %s)", e.id, e.id);
		end

		setup_entry(doc, e, make_ui(flags.yes), flags);
		doc:save();
		say("%s configured", e.id);
		apply(flags);
	end);

-- defined with the games, below: a game that plays a generated map has
-- it made, and the rotation set to it, whenever it is chosen
local force_map;

local function choose_gamemode(doc, id, ui, flags)
	local old = doc:get("gamemode") or "ctf";
	local e = entry(id);
	if (not e:is_a(catalog.Gamemode)) then die("%s is not a gamemode", e.id); end

	if (old ~= e.id) then
		local o = cat():find(old);
		if (o ~= nil) then o:on_remove(doc); end
		doc:remove_section(old);
	end

	doc:set("gamemode", e.id);
	-- what the mode itself needs is installed with it
	local deps = e:dependencies();
	if (#deps > 0) then install_ids(doc, deps, ui, {}); end
	setup_entry(doc, e, ui, flags);
	force_map(doc, e.id, old ~= e.id);
	return old ~= e.id;
end

command("gamemode", "gamemode [<id>] [--yes] [--no-restart]",
	"show the gamemodes, or switch to one",
	function(args)
		local words, flags = parse_args(args, {preset = true});
		local doc = open_doc(true);
		local now = doc:get("gamemode") or "ctf";

		if (#words == 0) then
			for _, g in ipairs(cat():of_class(catalog.Gamemode)) do
				say("%s %-10s %s", g.id == now and "*" or " ", g.id, g.summary or "");
			end
			return;
		end

		local changed = choose_gamemode(doc, words[1], make_ui(flags.yes), flags);
		doc:save();
		say("gamemode: %s", doc:get("gamemode"));
		apply(flags);
	end);

-- An entry from the data volume's catalog: the operator's own, which an
-- update of the image never touches.
local function is_local(e)
	return e.root == DATA .. "/catalog";
end

local function show_entries(entries, doc, mark_installed)
	local last;
	for _, e in ipairs(entries) do
		local t = category_title(e);
		if (t ~= last) then say(""); say("%s", t); last = t; end

		local mark = " ";
		if (mark_installed) then
			if (e:is_a(catalog.Gamemode)) then
				mark = (doc:get("gamemode") or "ctf") == e.id and "*" or " ";
			elseif (doc:is_installed(e.id)) then
				mark = "*";
			end
		end
		local presets = e:preset_names();
		say("  %s %-20s %s%s%s", mark, e.id, e.summary or "",
			#presets > 0 and ("  [presets: " .. table.concat(presets, ", ") .. "]") or "",
			is_local(e) and "  (yours)" or "");
	end
end

local function by_category(entries)
	local order = {};
	for i, c in ipairs(catalog.CATEGORIES) do order[c.class] = i; end
	local function rank(e)
		for _, c in ipairs(catalog.CATEGORIES) do
			if (e:is_a(c.class)) then return order[c.class]; end
		end
		return 99;
	end
	table.sort(entries, function(a, b)
		if (rank(a) ~= rank(b)) then return rank(a) < rank(b); end
		return a.id < b.id;
	end);
	return entries;
end

-- The modules the running server has loaded, of those named; nil when
-- it is not running.
local function loaded_modules(names)
	if (#names == 0) then return {}; end
	local list = {};
	for _, n in ipairs(names) do list[#list+1] = string.format("%q", n); end
	local out = console({"exec for _, m in ipairs({" .. table.concat(list, ",")
		.. "}) do log(\"LSDCTL\" .. \"-MOD|\" .. m .. \"|\" .. tostring(package.loaded[m] ~= nil)) end"}, 1);
	if (out == nil) then return nil; end
	local got = {};
	for _, r in ipairs(replies(out, "LSDCTL-MOD|")) do
		local m, yes = string.match(r, "^([^|]+)|(%a+)");
		if (m ~= nil) then got[m] = yes == "true"; end
	end
	return got;
end

command("local", "local",
	"your own scripts on /data: whether each is installed, running, and what it replaces",
	function()
		local doc = open_doc(false);

		local mine = {};
		for _, e in ipairs(cat().list) do
			if (is_local(e)) then mine[#mine+1] = e; end
		end

		local loose = {};
		local h = io.popen("cd " .. sh_quote(DATA .. "/scripts") .. " 2>/dev/null && find . -name '*.lua' | sort");
		for f in h:lines() do loose[#loose+1] = string.sub(f, 3); end
		h:close();

		local names = {};
		for _, e in ipairs(mine) do
			for _, m in ipairs(e:load_modules()) do names[#names+1] = m; end
		end
		for _, f in ipairs(loose) do
			names[#names+1] = (string.gsub(string.gsub(f, "%.lua$", ""), "/", "."));
		end
		local up = loaded_modules(names);

		local function state(mods)
			if (up == nil) then return "server not running"; end
			for _, m in ipairs(mods) do
				if (not up[m]) then return "not running"; end
			end
			return "running";
		end

		say("Your entries (%s/catalog), kept across updates:", DATA);
		if (#mine == 0) then say("  none"); end
		for _, e in ipairs(by_category(mine)) do
			local installed = doc:is_installed(e.id) or doc:get("gamemode") == e.id;
			say("  %s %-18s %-16s %s%s", installed and "*" or " ", e.id, category_title(e),
				installed and state(e:load_modules()) or "not installed",
				e.replaces and ("; replaces the image's " .. e.id) or "");
		end

		say("");
		say("Loose modules (%s/scripts), kept across updates:", DATA);
		if (#loose == 0) then say("  none"); end
		for _, f in ipairs(loose) do
			local m = string.gsub(string.gsub(f, "%.lua$", ""), "/", ".");
			local base = string.match(f, "[^/]+$");
			local over = read_file(HOME .. "/scripts.dist/" .. f) ~= nil and "upstream LSd's"
				or (run("find " .. sh_quote(HOME .. "/catalog") .. " -name " .. sh_quote(base)
					.. " | grep -q .") and "the image's" or nil);
			say("    %-34s %s%s", f, state({m}),
				over and ("; replaces " .. over .. " " .. base) or "");
		end

		say("");
		say("* installed. Adding one: docs/catalog.md, \"Your own scripts\".");
	end);

command("available", "available [category] [--all]",
	"every script this image can install (* installed); --all shows libraries",
	function(args)
		local words, flags = parse_args(args, {});
		local doc = open_doc(false);
		local out = {};
		for _, e in ipairs(cat().list) do
			local ok = flags.all or e.listed;
			if (ok and words[1] ~= nil) then
				ok = string.find(string.lower(category_title(e)), string.lower(words[1]), 1, true) ~= nil;
			end
			if (ok) then out[#out+1] = e; end
		end
		show_entries(by_category(out), doc, true);
		say("");
		say("install with: lsdctl install <id>   details: lsdctl info <id>");
	end);

command("list", "list", "what is installed, and the gamemode",
	function()
		local doc = open_doc(true);
		local out = {};
		local mode = cat():find(doc:get("gamemode") or "ctf");
		if (mode ~= nil) then out[#out+1] = mode; end
		for _, id in ipairs(doc:installed()) do
			local e = cat():find(id);
			if (e == nil) then
				say("  ! %s (not in this image's catalog)", id);
			else
				out[#out+1] = e;
			end
		end
		show_entries(by_category(out), doc, false);
	end);

command("info", "info <script>", "what a script is, needs and asks",
	function(args)
		local e = entry(args[1] or die("info about which script?"));
		local doc = open_doc(false);
		say("%s -- %s", e.id, e:label());
		say("  kind:      %s%s", e:kind(), e.upstream and " (upstream LSd)" or "");
		if (is_local(e)) then
			say("  source:    %s (yours: updates keep it)", e.dir);
			if (e.replaces ~= nil) then
				say("  replaces:  the image's %s, at %s", e.id, e.replaces.dir);
			end
		end
		say("  summary:   %s", e.summary or "");
		say("  modules:   %s", table.concat(e:load_modules(), ", "));
		local deps = e:dependencies();
		if (#deps > 0) then say("  requires:  %s", table.concat(deps, ", ")); end
		if (e:is_a(catalog.Extension)) then
			for _, x in ipairs(e:ext_list()) do
				say("  extension: id %d (0x%x), %s, default policy %s", x.id, x.id,
					x.title, e:default_policy(doc:section(e.id) or {}, x.id));
			end
		end
		for _, p in ipairs(e.presets or {}) do
			say("  preset %-12s %s", p.name, p.summary or "");
		end
		for _, q in ipairs(e.questions) do
			say("  asks %-24s %s", q.key, q.ask or "");
		end
		-- Every setting its modules declare, read from their getcfg calls:
		-- what can go in the settings file, with the default.
		local files = {};
		for _, m in ipairs(e:load_modules()) do
			files[#files+1] = e.upstream and (HOME .. "/scripts.dist/" .. m .. ".lua")
				or (e.dir .. "/" .. m .. ".lua");
		end
		if (e.rider) then files[#files+1] = e.dir .. "/" .. e.rider .. ".lua"; end
		local shown = false;
		for _, path in ipairs(files) do
			local src = read_file(path) or read_file(HOME .. "/lsd/scripts/"
				.. string.match(path, "([^/]+)$")) or "";
			for key, default in string.gmatch(src, 'getcfg%(%s*"([%w_]+)"%s*,%s*([^\n]-)%s*[,%)]') do
				if (not shown) then say("  settings:"); shown = true; end
				say("    %-30s default %s", key, default);
			end
		end
		say("  installed: %s", (doc:is_installed(e.id)
			or doc:get("gamemode") == e.id) and "yes" or "no");
	end);

command("get", "get <key>", "a setting's value, as the file says it",
	function(args)
		local doc = open_doc(true);
		local v = doc:get(args[1] or die("get which key?"));
		if (v == nil) then os.exit(1); end
		if (type(v) == "table") then say("%s", F.emit(v)); else say("%s", tostring(v)); end
	end);

command("set", "set <key> <value> [--no-restart]",
	"set any setting; the value is in settings syntax ('text', 3, True, [...])",
	function(args)
		local words, flags = parse_args(args, {});
		if (#words < 2) then die("usage: lsdctl set <key> <value>"); end
		local key = words[1];
		if (not string.match(key, "^[%a_][%w_]*$")) then die("%q is not a setting name", key); end
		if (key == "scripts" or key == "gamemode") then
			die("use lsdctl install/remove/gamemode for %s", key);
		end

		local raw = table.concat(words, " ", 2);
		local warn;
		local parsed = F.parse("v = " .. raw, function(_, m) warn = m; end);
		if (warn ~= nil) then die("%s", warn); end

		local doc = open_doc(true);
		doc:set(key, parsed.v);
		doc:save();
		say("%s = %s", key, F.emit(parsed.v));
		apply(flags);
		if (key == "port") then
			say("the container still publishes the old port: recreate it with lsdctl update");
		end
	end);

command("unset", "unset <key>", "remove a setting, back to its default",
	function(args)
		local doc = open_doc(true);
		if (not doc:unset(args[1] or die("unset which key?"))) then
			die("%s is not set", args[1]);
		end
		doc:save();
		apply({});
	end);

command("show", "show", "print the settings file",
	function()
		io.write(open_doc(true).text);
	end);

command("edit", "edit", "edit the settings file ($EDITOR, else vi), then apply it",
	function()
		local doc = open_doc(true);
		local editor = os.getenv("EDITOR") or "vi";
		if (not run(editor .. " " .. sh_quote(SETTINGS))) then die("editor failed"); end
		doc = open_doc(true);
		for _, w in ipairs(doc.warnings) do say("warning: %s", w); end
		if (make_ui(false):confirm("Restart the server to apply it?", true)) then
			apply({});
		else
			say("saved; apply with: lsdctl restart");
		end
	end);

--================================ MAPS ==============================--

local function map_names()
	local names = {};
	local h = io.popen("ls -1 " .. sh_quote(MAPS) .. " 2>/dev/null");
	for f in h:lines() do
		local n = string.match(f, "^(.+)%.vxl$");
		if (n) then names[#names+1] = n; end
	end
	h:close();
	table.sort(names);
	return names;
end

-- A flat map, generated: the one map the server can always have, so a
-- fresh install boots without anything downloaded. Every column is one
-- span: a coloured top voxel at `height` and solid ground beneath it
-- down to the bottom of the map (z grows downward; 63 is the floor).
local function generate_flat(name, height)
	height = math.floor(height or 62);
	local col = string.char(0, height, height, 0, 50, 130, 70, 255);
	local row = string.rep(col, 512);
	local path = MAPS .. "/" .. name .. ".vxl";
	local f = assert(io.open(path .. ".tmp", "wb"));
	for _ = 1, 512 do f:write(row); end
	f:close();
	assert(os.rename(path .. ".tmp", path));

	local txt = assert(io.open(MAPS .. "/" .. name .. ".txt", "w"));
	txt:write("name = '" .. name .. "'\nauthor = 'lsdctl'\n");
	txt:close();
end

-- The map of a game that plays a generated one, from a seed: its
-- generator (GAMES, `generator`: a module of catalog/core with
-- generate(seed), vxl(map) and meta(map, name) -- parkour_map's course,
-- range_map's range) writes the map and the metadata naming its places.
local function generate_course(name, seed)
	local P = require(game(name).generator);
	local c = P.generate(seed);
	local path = MAPS .. "/" .. name .. ".vxl";
	local f = assert(io.open(path .. ".tmp", "wb"));
	f:write(P.vxl(c));
	f:close();
	assert(os.rename(path .. ".tmp", path));

	local txt = assert(io.open(MAPS .. "/" .. name .. ".txt", "w"));
	txt:write(P.meta(c, name));
	txt:close();
end

local function sh_ok(cmd) return run(cmd); end

--=============================== MAP SOURCES ========================--
-- What `map add` and the setup wizard accept, and from where: see
-- catalog/core/map_sources.lua. aos.party is built in; map_sources in
-- the settings adds more.
local MS = require "map_sources";

local function map_sources(doc)
	local list, bad = MS.sources((doc or open_doc(false)):get("map_sources"));
	for _, b in ipairs(bad) do
		say("map_sources: %s is not a usable source (name, and a vxl with %%(id)), skipped", b);
	end
	return list;
end

local function file_size(path)
	local f = io.open(path, "rb");
	if (f == nil) then return nil, nil; end
	local head = f:read(16) or "";
	local size = f:seek("end");
	f:close();
	return size, head;
end

-- One download into maps/, under the name the server gives it (or the
-- URL's). `as` forces the name: a map's .txt is named after its .vxl, as
-- LSd looks it up. Returns the name, or nil and why.
local function fetch(url, as)
	local tmp = MAPS .. "/.part-" .. tostring(os.time()) .. "-" .. tostring(math.random(1e6));
	local ok = sh_ok(string.format("curl -fsSL --proto '=http,https' --max-time 300 -D %s -o %s %s",
		sh_quote(tmp .. ".h"), sh_quote(tmp), sh_quote(url)));
	local headers = read_file(tmp .. ".h") or "";
	os.remove(tmp .. ".h");
	if (not ok) then
		os.remove(tmp);
		return nil, "could not download " .. url;
	end

	local name, err = MS.safe_name(as or MS.disposition_name(headers)
		or string.match(string.gsub(url, "[?#].*$", ""), "([^/]+)$"));
	if (name == nil) then
		os.remove(tmp);
		return nil, url .. ": " .. err;
	end
	if (string.match(name, "%.vxl$")) then
		local size, head = file_size(tmp);
		local good, why = MS.looks_like_vxl(head, size);
		if (not good) then
			os.remove(tmp);
			return nil, url .. ": " .. why;
		end
	end
	if (not os.rename(tmp, MAPS .. "/" .. name)) then
		os.remove(tmp);
		return nil, "could not write " .. name;
	end
	return name;
end

-- Add one map from whatever was pasted. Returns a line saying what was
-- added, or nil and why. Nothing is half-added: a map whose .vxl fails
-- leaves nothing behind, and a missing .txt only costs its metadata.
local function add_map(input, sources)
	local plan, err = MS.resolve(input, sources);
	if (plan == nil) then
		return nil, err;
	end

	if (plan[1].file ~= nil) then
		local src = plan[1].file;
		local name, why = MS.safe_name(src);
		if (name == nil) then return nil, src .. ": " .. why; end
		if (string.match(name, "%.vxl$")) then
			local size, head = file_size(src);
			if (size == nil) then return nil, "no file " .. src; end
			local good, why2 = MS.looks_like_vxl(head, size);
			if (not good) then return nil, src .. ": " .. why2; end
		end
		if (not sh_ok("cp " .. sh_quote(src) .. " " .. sh_quote(MAPS .. "/" .. name))) then
			return nil, "could not copy " .. src;
		end
		return "added " .. name;
	end

	local vxl, why = fetch(plan[1].url);
	if (vxl == nil) then
		return nil, why;
	end
	local line = "added " .. vxl .. (plan[1].source and (" from " .. plan[1].source) or "");
	if (plan[2] ~= nil) then
		local txt = fetch(plan[2].url, (string.gsub(vxl, "%.vxl$", ".txt")));
		if (txt ~= nil) then line = line .. ", with its .txt"; end
	end
	return line;
end

-- The hint for finding maps, naming every source.
local function where_to_find(sources)
	local names = {};
	for _, s in ipairs(sources) do names[#names+1] = s.name; end
	local first = sources[1];
	local example = first and (first.view and string.gsub(first.view, "%%%(id%)", "864")
		or (first.name .. ":864")) or "https://example.org/map.vxl";
	return string.format("find maps on %s; add one with: lsdctl map add %s",
		table.concat(names, ", "), example);
end

-- defined with the games, below; the map command's web-random needs them
local game, random_maps;

command("map", "map list | add <page|url|source:id|file>... | rm <name>... | load <name>|random | generate <name> [height] | course [seed] | web-random [gamemode]",
	"the maps in rotation; `add` downloads (aos.party by default: lsdctl map add https://aos.party/view/864), `load` switches the live map",
	function(args)
		local sub = table.remove(args, 1) or "list";
		run("mkdir -p " .. sh_quote(MAPS));

		if (sub == "list") then
			local doc = open_doc(false);
			local rot = doc:get("map_rotation");
			local inrot = {};
			if (type(rot) == "string") then
				for m in string.gmatch(rot, "%S+") do inrot[m] = true; end
			end
			local names = map_names();
			for _, n in ipairs(names) do
				local mark = type(rot) == "string" and (inrot[n] and "*" or "-") or " ";
				say("  %s %s", mark, n);
			end
			if (#names == 0) then say("  no maps in %s", MAPS); end
			-- only the map generated on a first start: say where the
			-- real ones are
			if (#names == 0 or (#names == 1 and names[1] == "flat")) then
				say("%s", where_to_find(map_sources()));
			end
			say(type(rot) == "string" and ("rotation: " .. rot .. "  (* played, - installed only)")
				or "rotation: every map above, in name order");
			for n in pairs(inrot) do
				local found = false;
				for _, m in ipairs(names) do if (m == n) then found = true; end end
				if (not found) then say("warning: %s is in map_rotation but not installed", n); end
			end
		elseif (sub == "add") then
			local sources = map_sources();
			if (#args == 0) then
				die("map add <page|url|source:id|file>...\n  %s", where_to_find(sources));
			end
			for _, src in ipairs(args) do
				local line, err = add_map(src, sources);
				if (line == nil) then die("%s", err); end
				say("%s", line);
			end
			say("maps join the rotation at the next map change");
		elseif (sub == "rm") then
			for _, n in ipairs(args) do
				n = string.gsub(n, "%.vxl$", "");
				if (not os.remove(MAPS .. "/" .. n .. ".vxl")) then die("no map %s", n); end
				os.remove(MAPS .. "/" .. n .. ".txt");
				say("removed %s", n);
			end
		elseif (sub == "load") then
			local n = string.gsub(args[1] or die("map load <name>|random"), "%.vxl$", "");
			if (n == "random") then
				local names = map_names();
				if (#names == 0) then die("no maps (lsdctl map list)"); end
				math.randomseed(os.time());
				n = names[math.random(#names)];
			end
			if (not exists(MAPS .. "/" .. n .. ".vxl")) then die("no map %s (lsdctl map list)", n); end
			if (not console_up()) then die("the server is not running"); end
			console({"loadmap " .. n}, 1);
			say("loading %s", n);
		elseif (sub == "web-random") then
			-- a random map for the game, from what the map sources list,
			-- downloaded but not loaded: /va's, which loads it (the server
			-- asks the entrypoint for it, being forbidden to run programs)
			local doc = open_doc(false);
			local g = game(args[1] or doc:get("gamemode") or "");
			if (g ~= nil and g.maps == "generated") then
				say("%s plays its own generated map: none from the web (another course: lsdctl map course)", g.value);
				return;
			end
			math.randomseed(os.time());
			local n = random_maps(g and g.maps or "ctf", map_sources(doc), 1,
				function(line) say("%s", line); end);
			if (n == 0) then
				die("no map could be had");
			end
		elseif (sub == "course") then
			-- another course for the game that plays a generated one
			local doc = open_doc(true);
			local g = game(doc:get("gamemode") or "");
			if (g == nil or g.maps ~= "generated") then
				die("the gamemode (%s) does not play a generated course", tostring(doc:get("gamemode") or "ctf"));
			end
			local seed = args[1] == nil and os.time() % 1000000 or tonumber(args[1]);
			if (seed == nil or seed < 0 or seed ~= math.floor(seed)) then die("map course [seed]: a whole number"); end
			generate_course(g.value, seed);
			say("generated %s: a new course, seed %d (it plays at the next map change: lsdctl map load %s)",
				g.value, seed, g.value);
		elseif (sub == "generate") then
			local n = args[1] or die("map generate <name> [height]");
			if (not string.match(n, "^[%w_%-]+$")) then die("%q is not a map name", n); end
			local h = tonumber(args[2] or 62);
			if (h == nil or h < 1 or h > 62) then die("height is 1 (sky) to 62 (lowest)"); end
			generate_flat(n, h);
			say("generated %s: flat ground at z=%d", n, h);
		else
			die("map %s? (list, add, rm, load, generate, course, web-random)", sub);
		end
	end);

--============================= ADDRESSES ============================--

-- Where players connect, as the aos:// URLs clients open.
--
-- A container cannot see its host's LAN address -- only docker's own
-- network -- so the host tells it: install.sh puts the host's addresses
-- in LSD_HOST_ADDRESSES. The public address is looked up the way
-- upstream's /server does, from icanhazip (IPv4: the protocol has no
-- IPv6), and only for a listed server.
local function host_addresses()
	local out = {};
	for a in string.gmatch(os.getenv("LSD_HOST_ADDRESSES") or "", "[^%s,]+") do
		out[#out+1] = a;
	end
	return out;
end

local function public_address()
	local h = io.popen("curl -fsS --max-time 4 https://ipv4.icanhazip.com 2>/dev/null");
	local ip = h:read("*l");
	h:close();
	if (ip ~= nil and string.match(ip, "^%d+%.%d+%.%d+%.%d+$")) then
		return ip;
	end
end

local function print_addresses(doc)
	-- the port players use: the host's, when it publishes the server's
	-- on another one (play.sh picks a free one)
	local port = os.getenv("LSD_HOST_PORT") or tostring(doc:get("port") or 32887);
	local listed = doc:get("masterlist_enabled") ~= false;

	say("Players connect with:");
	if (listed) then
		local ip = public_address();
		if (ip ~= nil) then
			say("  internet:      aos://%s:%s", ip, port);
		else
			say("  internet:      (could not look up this host's public address)");
		end
		say("                 (needs UDP %s forwarded to this host if it is behind a router)", port);
	end

	local lan = host_addresses();
	for _, a in ipairs(lan) do
		say("  local network: aos://%s:%s", a, port);
	end
	say("  this machine:  aos://127.0.0.1:%s", port);

	if (#lan == 0) then
		say("  (local network addresses are unknown inside the container: run it with");
		say("   -e LSD_HOST_ADDRESSES=\"<host LAN IP>\", as install.sh does)");
	end
end

--================================ PLAY ==============================--
-- A casual game: `play` in the entrypoint runs this on a throwaway
-- container (docker run --rm, nothing kept), then the server once.
-- lib_play stops it when the last player leaves.

-- The games the short questions offer, the first the default. None of
-- them holds a client back: bots by night only recommends Daytime.
-- `maps` is the kind of map a random pick asks the map sources for
-- (map_sources.lua, list): "ctf" -- two bases, a field between -- or
-- "babel" -- or "generated": the game plays one map, made for it here
-- by its `generator` (generate_course), and none from the web. `bots`:
-- the game the bot engine has a tree for (bot/trees), so the short
-- questions offer to add some. `teams = 1`: everybody is on team 1, the
-- bots too (the range's targets are its own, not the engine's).
local GAMES = {
	{value = "tdm", label = "tdm", hint = "team deathmatch: every kill scores", maps = "ctf", bots = true},
	{value = "parkour", label = "parkour", hint = "one team, no enemies: run a generated course against the clock",
		maps = "generated", generator = "parkour_map", bots = true, teams = 1},
	{value = "range", label = "range", hint = "a shooting range: targets from 5 to 50 m and an IPSC course, against the clock",
		maps = "generated", generator = "range_map", teams = 1},
	{value = "ctf", label = "ctf", hint = "capture the flag", maps = "ctf", bots = true},
	{value = "bots", label = "bots", hint = "team deathmatch with bots, day and night", maps = "ctf"},
	{value = "bots_rewards", label = "bots_rewards", hint = "bots, with every reward free and unlimited", maps = "ctf"},
	{value = "babel", label = "babel", hint = "build a tower to the enemy's flag", maps = "babel", bots = true},
};

function game(mode)
	for _, g in ipairs(GAMES) do
		if (g.value == mode) then return g; end
	end
end

-- The map of a game that plays a generated one: made when the game is
-- newly chosen or the map is not there, and the only one in rotation.
-- Another course for the same game is `lsdctl map course [seed]`.
function force_map(doc, mode, fresh)
	local g = game(mode);
	if (g == nil or g.maps ~= "generated") then
		return;
	end
	run("mkdir -p " .. sh_quote(MAPS));
	if (fresh or not exists(MAPS .. "/" .. g.value .. ".vxl")) then
		local seed = os.time() % 1000000;
		generate_course(g.value, seed);
		say("map: %s, a course generated for the game (seed %d; another: lsdctl map course)", g.value, seed);
	end
	doc:set("map_rotation", g.value);
	doc:set("map_random", false);
	doc:set("map_web_random", false);
end

-- The game and the map, from the words given or asked: shared by play
-- and the quick setup. Returns the gamemode id and the map wanted:
-- "random", or a page, link or source:id.
local function ask_game_and_map(ui, mode, want, default)
	if (mode == nil) then
		mode = ui:choose("Game", GAMES, default or GAMES[1].value);
	end
	if (game(mode) == nil) then
		local ids = {};
		for _, g in ipairs(GAMES) do ids[#ids+1] = g.value; end
		die("the game is one of %s, not %s", table.concat(ids, ", "), tostring(mode));
	end
	if (game(mode).maps == "generated") then
		return mode, want or "random";
	end
	if (want == nil) then
		want = ui:ask({key = "map", type = "string",
			ask = "Map: random, or a link or source:id (aos.party, hosting.dgd.cx)"}, "random");
	end
	if (string.match(want, "^%d+$")) then
		want = "aos.party:" .. want;
	end
	return mode, want;
end

-- Bots, for a game that can have them: how many a team (in all, where
-- the game is one team), asked or given (`play tdm random 8`); 0 for
-- none. nil for a game without.
local function ask_bots(ui, mode, given)
	local g = game(mode);
	if (g == nil or not g.bots) then
		return nil;
	end
	local n = tonumber(given);
	if (n == nil) then
		n = ui:ask({key = "bots", type = "number", min = 0, max = 100,
			ask = g.teams == 1 and "Bots (0 for none)" or "Bots per team (0 for none)"}, 0);
	end
	return math.max(0, math.min(100, math.floor(tonumber(n) or 0)));
end

-- Rewards (catalog/tools/rewards): earned, off, or every one free and
-- unlimited. Asked, or given as a word (`play tdm random 8 infinite`).
local REWARDS = {
	{value = "on", label = "on", hint = "kills and captures earn them"},
	{value = "off", label = "off", hint = "no rewards"},
	{value = "infinite", label = "infinite", hint = "every reward, unlimited, for everybody"},
};

local function ask_rewards(ui, given, default)
	for _, r in ipairs(REWARDS) do
		if (given == r.value) then return given; end
	end
	return ui:choose("Rewards", REWARDS, default or "on");
end

local function set_rewards(doc, how)
	if (not doc:is_installed("rewards")) then
		if (how == "off") then
			return;
		end
		install_ids(doc, {"rewards"}, make_ui(true), {});
	end
	doc:set("rewards_enabled", how ~= "off");
	doc:set("rewards_free", how == "infinite");
	if (how ~= "on") then
		say("rewards: %s", how);
	end
end

-- ...and into the settings: the engine's bots installed at that count.
-- None asked for where they were installed before: the count goes to 0,
-- which is a server with no bots (lib_botlink makes no file for none).
-- A game of one team has them all on team 1; any other game gets the
-- second team's back, if such a game had taken them.
local function set_bots(doc, n, mode)
	if (n == nil) then
		return;
	end
	local g = game(mode);
	local one = g ~= nil and g.teams == 1;
	local have = false;
	for _, id in ipairs(doc:installed()) do
		if (id == "engine_bots") then have = true; end
	end
	if (n > 0 and not have) then
		install_ids(doc, {"engine_bots"}, make_ui(true), {});
		have = true;
	end
	if (have) then
		doc:set("engine_bots_count", n);
		if (one) then
			doc:set("engine_bots_team2", 0);
		elseif (doc:get("engine_bots_team2") == 0) then
			doc:set("engine_bots_team2", -1);
		end
	end
	if (n > 0) then
		say(one and "bots: %d" or "bots: %d a team", n);
	end
end

-- What a source's listing answers: the text, or nil. A short timeout:
-- a site that is down must not hold the game up.
local function http_text(req)
	local cmd = "curl -fsSL --proto '=http,https' --max-time 20";
	if (req.method == "POST") then
		cmd = cmd .. " -X POST";
		if (req.content_type) then
			cmd = cmd .. " -H " .. sh_quote("Content-Type: " .. req.content_type);
		end
		cmd = cmd .. " --data " .. sh_quote(req.body or "");
	end
	local f = io.popen(cmd .. " " .. sh_quote(req.url) .. " 2>/dev/null");
	if (f == nil) then return nil; end
	local text = f:read("*a");
	local ok = f:close();
	return (ok and text ~= "") and text or nil;
end

local function shuffled(t)
	local out = {};
	for i, v in ipairs(t) do out[i] = v; end
	for i = #out, 2, -1 do
		local j = math.random(i);
		out[i], out[j] = out[j], out[i];
	end
	return out;
end

-- Up to `want` random maps of a kind ("ctf", "babel"), downloaded: the
-- sources that can list, in a random order; from each, its maps of
-- that kind in a random order, until enough have come down. A source
-- that does not answer, or a map that does not download, is said and
-- passed over -- MAX_TRIES downloads in all, so a bad day ends.
local MAX_TRIES = 8;
function random_maps(kind, sources, want, got)
	local tries, n = 0, 0;
	for _, s in ipairs(shuffled(sources)) do
		local req = MS.list_request(s, kind);
		if (req ~= nil) then
			local ids = MS.list_ids(s, http_text(req));
			if (#ids == 0) then
				say("%s lists no %s maps right now", s.name, kind);
			end
			for _, id in ipairs(shuffled(ids)) do
				if (n >= want or tries >= MAX_TRIES) then return n; end
				tries = tries + 1;
				local line, err = add_map(s.name .. ":" .. id, sources);
				if (line ~= nil) then
					n = n + 1;
					got(line);
				else
					say("could not get %s:%s (%s)", s.name, id, tostring(err));
				end
			end
		end
	end
	return n;
end

-- How many maps a rotation set up by `random` holds.
local ROTATION = 6;

-- Set the game up in doc and get its map(s). "random" is a map picked
-- at random from what the map sources list for the game (random_maps),
-- one for a single game (play), ROTATION of them in a random order for
-- a server that keeps going (opts.rotation). A map that cannot be had is
-- said and skipped; with none at all, what is already here plays (the
-- generated flat one, at worst).
local function set_game_and_map(doc, mode, want, opts)
	choose_gamemode(doc, mode, make_ui(true), {});
	if (game(mode).maps == "generated") then
		-- its map came with it (force_map)
		if (want ~= "random") then say("%s plays its own generated map: %s is not fetched", mode, want); end
		return;
	end

	local sources = map_sources(doc);
	local names = {};
	local function got(line)
		say("%s", line);
		names[#names+1] = string.match(line, "^added ([^ ]+)%.vxl");
	end

	if (want ~= "random") then
		local line, err = add_map(want, sources);
		if (line ~= nil) then got(line); else say("could not get %s (%s)", want, tostring(err)); end
	else
		math.randomseed(os.time());
		local g = game(mode);
		random_maps(g and g.maps or "ctf", sources, opts.rotation and ROTATION or 1, got);
	end

	-- random mode: /va fetches the next map from the web as well
	doc:set("map_web_random", want == "random");
	if (#names > 0) then
		doc:set("map_rotation", table.concat(names, " "));
		doc:set("map_random", opts.rotation == true and want == "random");
	else
		say("no map could be had: playing a generated one");
	end
end

command("play", "play [tdm|parkour|range|ctf|bots|bots_rewards|babel] [random|<page|url|source:id>] [bots per team] [on|off|infinite]",
	"set up a casual game on a fresh container (the entrypoint's play runs it)",
	function(args)
		local words = parse_args(args, {});
		local doc = open_doc(true);
		local ui = make_ui(false);
		local mode, want = ask_game_and_map(ui, words[1], words[2]);
		-- after the game and the map, in any order: a number is the
		-- bots, a word of REWARDS the rewards
		local nbots, how;
		for i = 3, #words do
			if (tonumber(words[i]) ~= nil) then nbots = words[i]; else how = words[i]; end
		end
		local bots = ask_bots(ui, mode, nbots);
		local rewards = ask_rewards(ui, how);

		-- a game among friends: never listed
		doc:set("masterlist_enabled", false);
		doc:set("play_mode", true);
		set_game_and_map(doc, mode, want, {});
		set_bots(doc, bots, mode);
		set_rewards(doc, rewards);

		doc:save();
		say("");
		print_addresses(doc);
		say("");
		say("It stops by itself when the last player leaves. Ctrl-C stops it now.");
	end);

--======================== THE BOTS' TREES ===========================--

-- Everything a tree editor's backend does, as commands that take and
-- give JSON (bot/TREES.md, "The editor's backend"): look at the trees,
-- check and format a text, see the bots and what one is thinking, give
-- a tree to one bot, to many or to all while they play, take it back,
-- keep a text as an operator's tree. A future HTTP endpoint is these
-- with a transport and a password in front, and nothing else.
--
-- The work is bttree's (the engine's own compiler) and the server's
-- (lib_botlink, through the console); what is here is the plumbing and
-- the checks no caller may skip: a tree's name is letters, digits, _
-- and - (it becomes a file name); a text is at most 60000 bytes; a text
-- is compiled before anybody is given it.
local BTTREE = os.getenv("LSD_BTTREE") or "bttree";
local TREES_BUILTIN = os.getenv("LSD_BOT_TREES") or "/opt/botd/trees";
local TREES_USER = DATA .. "/trees";
local BOTDEBUG = DATA .. "/rw/botdebug";
local TREE_BYTES = 60000;

local function json_quote(s)
	return '"' .. string.gsub(tostring(s), '[%c"\\]', function(c)
		if (c == '"' or c == "\\") then return "\\" .. c; end
		if (c == "\n") then return "\\n"; end
		if (c == "\t") then return "\\t"; end
		return string.format("\\u%04x", string.byte(c));
	end) .. '"';
end

-- A value as JSON. A table with [1], or marked {array = true}, is a
-- list; any other is an object, its keys in `order` (if it names one)
-- and then by name.
local ARRAY = {};
local function json(v)
	local t = type(v);
	if (t == "nil") then return "null"; end
	if (t == "boolean" or t == "number") then return tostring(v); end
	if (t ~= "table") then return json_quote(v); end
	if (v[1] ~= nil or getmetatable(v) == ARRAY) then
		local out = {};
		for i, x in ipairs(v) do out[i] = json(x); end
		return "[" .. table.concat(out, ", ") .. "]";
	end
	local keys, seen, out = {}, {}, {};
	for _, k in ipairs(rawget(v, "__order") or {}) do
		if (v[k] ~= nil) then keys[#keys + 1] = k; seen[k] = true; end
	end
	local rest = {};
	for k in pairs(v) do
		if (k ~= "__order" and not seen[k]) then rest[#rest + 1] = k; end
	end
	table.sort(rest);
	for _, k in ipairs(rest) do keys[#keys + 1] = k; end
	for i, k in ipairs(keys) do out[i] = json_quote(k) .. ": " .. json(v[k]); end
	return "{" .. table.concat(out, ", ") .. "}";
end
local function list(t) return setmetatable(t or {}, ARRAY); end

-- JSON read: what bttree and the engine write (no surprises in it).
local function json_read(text)
	local at = 1;
	local value;
	local function skip() at = string.find(text, "[^ \n\r\t]", at) or #text + 1; end
	local function str()
		local out, i = {}, at + 1;
		while (true) do
			local j = string.find(text, '["\\]', i);
			if (j == nil) then error("bad JSON", 0); end
			out[#out + 1] = string.sub(text, i, j - 1);
			if (string.sub(text, j, j) == '"') then at = j + 1; break; end
			local c = string.sub(text, j + 1, j + 1);
			if (c == "u") then
				out[#out + 1] = string.char(tonumber(string.sub(text, j + 2, j + 5), 16) % 256);
				i = j + 6;
			else
				out[#out + 1] = ({n = "\n", t = "\t", r = "\r", b = "\b", f = "\f"})[c] or c;
				i = j + 2;
			end
		end
		return table.concat(out);
	end
	value = function()
		skip();
		local c = string.sub(text, at, at);
		if (c == "{") then
			local o = {};
			at = at + 1; skip();
			if (string.sub(text, at, at) == "}") then at = at + 1; return o; end
			while (true) do
				skip();
				local k = str();
				skip(); at = at + 1;
				o[k] = value();
				skip();
				local d = string.sub(text, at, at);
				at = at + 1;
				if (d == "}") then return o; end
				if (d ~= ",") then error("bad JSON", 0); end
			end
		elseif (c == "[") then
			local a = list();
			at = at + 1; skip();
			if (string.sub(text, at, at) == "]") then at = at + 1; return a; end
			while (true) do
				a[#a + 1] = value();
				skip();
				local d = string.sub(text, at, at);
				at = at + 1;
				if (d == "]") then return a; end
				if (d ~= ",") then error("bad JSON", 0); end
			end
		elseif (c == '"') then
			return str();
		elseif (string.sub(text, at, at + 3) == "true") then at = at + 4; return true;
		elseif (string.sub(text, at, at + 4) == "false") then at = at + 5; return false;
		elseif (string.sub(text, at, at + 3) == "null") then at = at + 4; return nil;
		end
		local n = string.match(text, "^-?[%d.eE+-]+", at);
		if (n == nil) then error("bad JSON", 0); end
		at = at + #n;
		return tonumber(n);
	end
	local ok, v = pcall(value);
	return ok and v or nil;
end

-- A command's output and its exit status.
local function capture(cmd)
	local h = io.popen(cmd .. '; echo "LSDCTL-EXIT:$?"');
	local out = h:read("*a") or "";
	h:close();
	local code = tonumber(string.match(out, "LSDCTL%-EXIT:(%d+)%s*$")) or 1;
	return (string.gsub(out, "LSDCTL%-EXIT:%d+%s*$", "")), code;
end

local function bttree(args, quiet)
	return capture(BTTREE .. " " .. args .. (quiet and " 2>/dev/null" or " 2>&1"));
end

-- How a `bots` command ends when it cannot do what was asked: one line
-- for a person, or -- with --json -- the same as data, on the standard
-- output; a status of 1 either way.
local function bots_fail(flags, message, diagnostics)
	if (flags.json) then
		io.write(json({__order = {"format", "version", "ok", "error", "diagnostics"},
			format = "lsd-bt-error", version = 1, ok = false, error = message,
			diagnostics = diagnostics}), "\n");
		os.exit(1);
	end
	for _, d in ipairs(diagnostics or {}) do
		io.stderr:write(string.format("  line %d, column %d: %s\n", d.line or 0, d.column or 0, d.message or ""));
	end
	die("%s", message);
end

local function tree_name_ok(name)
	return type(name) == "string" and #name <= 31 and string.match(name, "^[%w_%-]+$") ~= nil;
end

local function bt_files(dir)
	local out = {};
	local h = io.popen("ls " .. sh_quote(dir) .. "/*.bt 2>/dev/null");
	for line in h:lines() do out[#out + 1] = line; end
	h:close();
	return out;
end

-- Every tree of the built-in files and of the operator's, each with
-- where it is from; one of the operator's with a built-in's name is the
-- one the engine runs.
local function all_trees(flags)
	local trees, by_name = list(), {};
	for _, from in ipairs({"builtin", "user"}) do
		local files = bt_files(from == "builtin" and TREES_BUILTIN or TREES_USER);
		if (#files > 0) then
			local q = {};
			for i, f in ipairs(files) do q[i] = sh_quote(f); end
			-- each of the operator's files alone: one that does not compile must not hide the others
			for _, arg in ipairs(from == "builtin" and {table.concat(q, " ")} or q) do
				local out, code = bttree("--list --json " .. arg, true);
				local doc = code == 0 and json_read(out) or nil;
				for _, t in ipairs(doc and doc.trees or {}) do
					t.from = from;
					t.__order = {"name", "from", "file", "line", "nodes", "refers", "about", "replaced"};
					if (by_name[t.name] ~= nil) then by_name[t.name].replaced = true; end
					by_name[t.name] = t;
					trees[#trees + 1] = t;
				end
				if (doc == nil and from == "builtin") then
					bots_fail(flags, "cannot read the trees in " .. TREES_BUILTIN .. " (is bttree there?)");
				end
			end
		end
	end
	return trees, by_name;
end

-- The text a command was given: a file, or `-` for the standard input.
-- A JSON tree (what an editor holds) is made text here.
local function tree_text(flags, source)
	local text;
	if (source == nil or source == "-") then
		text = io.read("*a");
	else
		text = read_file(source) or bots_fail(flags, "cannot read " .. tostring(source));
	end
	if (text == nil or #text == 0) then bots_fail(flags, "no tree text was given"); end
	if (#text > 4 * TREE_BYTES) then bots_fail(flags, "too long to be a tree"); end
	local tmp = os.tmpname();
	if (string.match(text, "^%s*{")) then
		write_file(tmp, text);
		local out, code = bttree("--from-json " .. sh_quote(tmp));
		os.remove(tmp);
		if (code ~= 0) then bots_fail(flags, "that JSON is not a tree: " .. (string.gsub(out, "%s+$", ""))); end
		text = out;
	end
	return text;
end

-- All that is wrong with a text, by the engine's compiler: nil if nothing.
local function tree_check(text)
	local tmp = os.tmpname();
	write_file(tmp, text);
	local out, code = bttree("--check --json " .. sh_quote(tmp), true);
	local doc = json_read(out);
	local names = code == 0 and json_read((bttree("--list --json " .. sh_quote(tmp), true))) or nil;
	os.remove(tmp);
	if (doc == nil) then return {{line = 0, column = 0, message = "bttree could not be run"}}; end
	for _, d in ipairs(doc.diagnostics or {}) do d.file = nil; d.__order = {"line", "column", "message"}; end
	return (not doc.ok) and doc.diagnostics or nil, names and names.trees or {};
end

-- The engine's bots, as it says them now (the debug channel).
local function roster(flags)
	if (not console_up()) then bots_fail(flags, "the server is not running"); end
	local out, code = bttree("--bots --json --dir " .. sh_quote(BOTDEBUG));
	local doc = code == 0 and json_read(out) or nil;
	if (doc == nil) then
		bots_fail(flags, "the bot engine does not answer (are there engine bots? lsdctl bots <n>)");
	end
	return doc, out;
end

-- Which bots a command means: --bot a,b (ids or names), --team n,
-- --archetype x, together; --each, every engine bot one by one; or
-- --all, which is the world's tree and not a list (a bot that was given
-- a tree of its own keeps it).
local function targets(flags, doc)
	if (flags.all) then return nil; end
	if (not (flags.bot or flags.team or flags.archetype or flags.each)) then
		bots_fail(flags, "say whom: --bot <id or name>[,...], --team <1|2>, --archetype <kind>, --each (every bot), or --all (the world's tree)");
	end
	local want, pids, missing = {}, list(), {};
	for w in string.gmatch(flags.bot or "", "[^,]+") do want[#want + 1] = w; end
	local found = {};
	for _, b in ipairs(doc.bots or {}) do
		local hit = false;
		for i, w in ipairs(want) do
			if (tostring(b.pid) == w or b.name == w) then hit = true; found[i] = true; end
		end
		if (flags.team and tostring(b.team) == tostring(flags.team)) then hit = true; end
		if (flags.archetype and b.archetype == flags.archetype) then hit = true; end
		if (flags.each) then hit = true; end
		if (hit) then pids[#pids + 1] = b.pid; end
	end
	for i, w in ipairs(want) do
		if (not found[i]) then missing[#missing + 1] = w; end
	end
	if (#missing > 0) then bots_fail(flags, "no engine bot is called " .. table.concat(missing, ", ")); end
	if (#pids == 0) then bots_fail(flags, "no engine bot matches"); end
	return pids;
end

-- One call into lib_botlink through the console: its answer, a number
-- of bots, or nil and why.
local function botlink_call(expr)
	local out = console({'exec do local n, why = ' .. expr .. '; log("%s", "LSDCTL" .. "-TREE|" .. tostring(n) .. "|" .. tostring(why)); end'}, 1);
	local r = replies(out, "LSDCTL-TREE|")[1];
	if (r == nil) then return nil, "the server did not answer (is lib_botlink loaded?)"; end
	local n, why = string.match(r, "^([^|]*)|(.*)$");
	if (tonumber(n) == nil) then return nil, why; end
	return tonumber(n);
end

-- What each of those bots runs now, read back from the engine.
local function report(flags, pids, want_tree, what)
	run("sleep 1.2");
	local doc = roster(flags);
	local rows, ok = list(), true;
	for _, b in ipairs(doc.bots or {}) do
		local mine = pids == nil;
		for _, pid in ipairs(pids or {}) do
			if (pid == b.pid) then mine = true; end
		end
		if (mine) then
			-- for the world's tree, a bot with one of its own is as it should be
			local good;
			if (pids == nil) then
				good = b.tree_set == "bot" or want_tree == nil or b.tree == want_tree;
			elseif (want_tree == nil) then
				good = b.tree_set == "world";
			else
				good = b.tree == want_tree and b.tree_set == "bot";
			end
			ok = ok and good;
			rows[#rows + 1] = {__order = {"pid", "name", "team", "tree", "tree_from", "tree_set", "ok"},
				pid = b.pid, name = b.name, team = b.team, tree = b.tree, tree_from = b.tree_from,
				tree_set = b.tree_set, ok = good};
		end
	end
	local res = {__order = {"format", "version", "ok", "action", "scope", "tree", "world", "bots", "error"},
		format = "lsd-bt-apply", version = 1, ok = ok, action = what, scope = pids == nil and "world" or "bots",
		tree = want_tree, world = doc.world and doc.world.tree, bots = rows};
	if (not ok) then
		res.error = "the engine did not take it for every bot: see the bot engine's log (docker logs)";
	end
	if (flags.json) then
		io.write(json(res), "\n");
	else
		for _, r in ipairs(rows) do
			say("%s #%-3d %-16s now runs %s%s", r.ok and " " or "!", r.pid, r.name or "", r.tree or "?",
				r.tree_set == "bot" and " (its own)" or "");
		end
		if (pids == nil) then say("the world's tree: %s (a bot given one of its own keeps it: --each reaches every bot)", tostring(res.world)); end
		if (not ok) then io.stderr:write("lsdctl: " .. res.error .. "\n"); end
	end
	if (not ok) then os.exit(1); end
end

local bots_sub = {};

bots_sub.schema = function(words, flags)
	local out, code = bttree("--schema");
	if (code ~= 0) then bots_fail(flags, "bttree --schema failed"); end
	io.write(out);
end

bots_sub.trees = function(words, flags)
	local trees = all_trees(flags);
	local world = nil;
	if (console_up()) then
		local out, code = bttree("--bots --json --dir " .. sh_quote(BOTDEBUG), true);
		local doc = code == 0 and json_read(out) or nil;
		world = doc and doc.world and doc.world.tree;
	end
	if (flags.json) then
		io.write(json({__order = {"format", "version", "world", "trees"}, format = "lsd-bt-trees", version = 1,
			world = world, trees = trees}), "\n");
		return;
	end
	for _, t in ipairs(trees) do
		say("%-22s %-8s %3d nodes  %s%s", t.name, t.from, t.nodes or 0, t.file,
			t.replaced and "  (replaced by the operator's)" or "");
	end
	if (world ~= nil) then say("the world runs: %s", world); end
end

-- The games, as data for a front end: which have a tree for the bots,
-- one team or two, a generated map or one from the web (GAMES, above).
bots_sub.games = function(words, flags)
	local rows = list();
	for _, g in ipairs(GAMES) do
		rows[#rows + 1] = {__order = {"name", "bots", "teams", "maps", "about"}, name = g.value,
			bots = g.bots == true, teams = g.teams or 2, maps = g.maps, about = g.hint};
	end
	if (flags.json) then
		io.write(json({__order = {"format", "version", "games"}, format = "lsd-bt-games", version = 1, games = rows}), "\n");
		return;
	end
	for _, g in ipairs(rows) do
		say("%-14s %-9s %d team%s  %-9s %s", g.name, g.bots and "bots" or "no bots", g.teams, g.teams == 1 and " " or "s",
			g.maps, g.about);
	end
end

bots_sub.tree = function(words, flags)
	local name = words[2] or bots_fail(flags, "bots tree <name>");
	local _, by_name = all_trees(flags);
	local t = by_name[name] or bots_fail(flags, "no tree is called " .. name .. " (lsdctl bots trees)");
	if (flags.json) then
		local out, code = bttree("--json --tree " .. sh_quote(name) .. " " .. sh_quote(t.file));
		if (code ~= 0) then bots_fail(flags, (string.gsub(out, "%s+$", ""))); end
		io.write(out);
	else
		local out, code = bttree("--format --tree " .. sh_quote(name) .. " " .. sh_quote(t.file));
		if (code ~= 0) then bots_fail(flags, (string.gsub(out, "%s+$", ""))); end
		io.write(out);
	end
end

bots_sub.check = function(words, flags)
	local text = tree_text(flags, flags.file or words[2]);
	local bad, names = tree_check(text);
	if (flags.json) then
		local tn = list();
		for _, t in ipairs(names or {}) do tn[#tn + 1] = t.name; end
		io.write(json({__order = {"format", "version", "ok", "trees", "diagnostics"}, format = "lsd-bt-check", version = 1,
			ok = bad == nil, trees = tn, diagnostics = list(bad)}), "\n");
	elseif (bad == nil) then
		say("ok");
	else
		for _, d in ipairs(bad) do say("line %d, column %d: %s", d.line, d.column, d.message); end
	end
	if (bad ~= nil) then os.exit(1); end
end

bots_sub.format = function(words, flags)
	local text = tree_text(flags, flags.file or words[2]);
	local bad = tree_check(text);
	if (bad ~= nil) then bots_fail(flags, "it does not compile", bad); end
	local tmp = os.tmpname();
	write_file(tmp, text);
	local out = bttree("--format " .. sh_quote(tmp));
	os.remove(tmp);
	if (flags.json) then
		io.write(json({__order = {"format", "version", "ok", "text"}, format = "lsd-bt-text", version = 1, ok = true, text = out}), "\n");
	else
		io.write(out);
	end
end

bots_sub.list = function(words, flags)
	local doc, raw = roster(flags);
	if (flags.json) then io.write(raw); return; end
	say("%4s  %-16s %4s  %-8s %5s %6s  %-20s %s", "id", "name", "team", "kind", "level", "health", "tree", "doing");
	for _, b in ipairs(doc.bots or {}) do
		say("%4d  %-16s %4d  %-8s %5d %6d  %-20s %s", b.pid, b.name or "", b.team or 0, b.archetype or "", b.level or 0,
			b.health or 0, (b.tree or "") .. (b.tree_set == "bot" and " (its own)" or ""), b.doing or "");
	end
	say("the world runs: %s", tostring(doc.world and doc.world.tree));
end

bots_sub.watch = function(words, flags)
	if (not console_up()) then bots_fail(flags, "the server is not running"); end
	local cmd = BTTREE .. " --watch --dir " .. sh_quote(BOTDEBUG);
	if (words[2] ~= nil) then cmd = cmd .. " --bot " .. sh_quote(words[2]); end
	for _, f in ipairs({"json", "once", "full", "plain"}) do
		if (flags[f]) then cmd = cmd .. " --" .. f; end
	end
	if (flags.hz) then cmd = cmd .. " --hz " .. sh_quote(flags.hz); end
	if (flags.json and flags.once) then
		local out, code = capture(cmd .. " 2>/dev/null");
		if (code ~= 0 or json_read(out) == nil) then bots_fail(flags, "no such bot, or the bot engine does not answer"); end
		io.write(out);
		return;
	end
	if (not run(cmd)) then os.exit(1); end
end

bots_sub.apply = function(words, flags)
	local name, text = words[2], nil;
	if (flags.file or name == nil or name == "-") then
		text = tree_text(flags, flags.file or "-");
		local bad, names = tree_check(text);
		if (bad ~= nil) then bots_fail(flags, "the tree does not compile: nothing was changed", bad); end
		if (#text > TREE_BYTES) then bots_fail(flags, string.format("the tree is %d bytes: the most is %d", #text, TREE_BYTES)); end
		name = names[1] and names[1].name or "main";
	else
		local _, by_name = all_trees(flags);
		if (not tree_name_ok(name) or by_name[name] == nil) then
			bots_fail(flags, "no tree is called " .. tostring(name) .. " (lsdctl bots trees); for a text: --file <file>, or - for the standard input");
		end
	end
	local doc = roster(flags);
	if (text == nil) then
		-- a name is a tree the ENGINE holds: one just saved is only a file until the next map
		local held = false;
		for _, t in ipairs(doc.trees or {}) do
			if (t.name == name) then held = true; end
		end
		if (not held) then
			bots_fail(flags, "the bot engine has not read the tree " .. name .. " yet (it reads " .. TREES_USER
				.. " at the next map load): change the map, or give it the text now: lsdctl bots apply --file "
				.. tostring(select(2, all_trees(flags))[name].file) .. " ...");
		end
	end
	local pids = targets(flags, doc);
	local expr;
	if (text ~= nil) then
		local file = string.format("apply-%d-%d.bt", os.time(), math.random(100000, 999999));
		write_file(BOTDEBUG .. "/" .. file, text);
		expr = string.format("botlink_tree_apply({file = %q}, %s)", file, pids and ("{" .. table.concat(pids, ", ") .. "}") or "nil");
		local n, why = botlink_call(expr);
		os.remove(BOTDEBUG .. "/" .. file);
		if (n == nil) then bots_fail(flags, "the server refused: " .. tostring(why)); end
	else
		expr = string.format("botlink_tree_apply(%q, %s)", name, pids and ("{" .. table.concat(pids, ", ") .. "}") or "nil");
		local n, why = botlink_call(expr);
		if (n == nil) then bots_fail(flags, "the server refused: " .. tostring(why)); end
	end
	report(flags, pids, name, "apply");
end

bots_sub.revert = function(words, flags)
	local doc = roster(flags);
	local pids = targets(flags, doc);
	local n, why = botlink_call(string.format("botlink_tree_revert(%s)", pids and ("{" .. table.concat(pids, ", ") .. "}") or "nil"));
	if (n == nil) then bots_fail(flags, "the server refused: " .. tostring(why)); end
	report(flags, pids, nil, "revert");
end

bots_sub.save = function(words, flags)
	local name = words[2];
	if (not tree_name_ok(name)) then
		bots_fail(flags, "bots save <name> [--file <file> | -]: a name of letters, digits, _ and -, 31 at most");
	end
	local text = tree_text(flags, flags.file or "-");
	local bad, names = tree_check(text);
	if (bad ~= nil) then bots_fail(flags, "the tree does not compile: nothing was saved", bad); end
	if (#text > TREE_BYTES) then bots_fail(flags, string.format("the tree is %d bytes: the most is %d", #text, TREE_BYTES)); end
	local tmp = os.tmpname();
	write_file(tmp, text);
	local canon = bttree("--format " .. sh_quote(tmp));
	os.remove(tmp);
	run("mkdir -p " .. sh_quote(TREES_USER));
	local path = TREES_USER .. "/" .. name .. ".bt";
	write_file(path, canon);
	local tn = list();
	for _, t in ipairs(names or {}) do tn[#tn + 1] = t.name; end
	if (flags.json) then
		io.write(json({__order = {"format", "version", "ok", "file", "trees", "note"}, format = "lsd-bt-saved", version = 1,
			ok = true, file = path, trees = tn,
			note = "read by the bot engine at the next map load; run it with: lsdctl bots apply <tree> --all, or the setting engine_bots_tree"}), "\n");
	else
		say("saved %s (%s): the bot engine reads it at the next map load", path, table.concat(tn, ", "));
	end
end

command("bots", "bots <n> [--no-restart] | bots list | watch [name|id] | games | trees | tree <name> | check | format | apply | revert | save | schema   [--json]",
	"the bot engine's bots: n a team (n in all in a game of one team; 0 for none). And their behaviour trees (bot/TREES.md): "
	.. "list the bots; watch one think; games: which have a tree, one team or two; trees, tree <name>; check or format a text (a file, or - for the standard input; a JSON tree too); "
	.. "apply <tree> | apply --file <f> | apply - to --bot <id or name>[,...], --team <n>, --archetype <kind> or --all, live; "
	.. "revert the same; save <name> as an operator's tree; schema: all a tree may be made of. --json: answers, and errors, as JSON",
	function(args)
		local words, flags = parse_args(args, {bot = true, team = true, archetype = true, file = true, hz = true});
		local sub = bots_sub[words[1] or ""];
		if (sub ~= nil) then
			math.randomseed(os.time());
			return sub(words, flags);
		end
		local n = tonumber(words[1]);
		if (n == nil) then die("bots <n>, or bots list | watch | games | trees | tree | check | format | apply | revert | save | schema"); end
		local doc = open_doc(true);
		set_bots(doc, math.max(0, math.min(100, math.floor(n))), doc:get("gamemode") or "ctf");
		doc:save();
		apply(flags);
	end);

command("address", "address", "the aos:// addresses players connect with",
	function()
		print_addresses(open_doc(true));
	end);

--============================== SERVER ==============================--

command("restart", "restart [--now] [message]",
	"restart the server (warns players; the container stays up)",
	function(args)
		local words, flags = parse_args(args, {});
		if (not restart(#words > 0 and table.concat(words, " ") or nil,
			flags.now and 0 or 5)) then
			os.exit(1);
		end
	end);

command("say", "say <message>", "a message to everybody in game",
	function(args)
		if (#args == 0) then die("say what?"); end
		if (console({"say " .. table.concat(args, " ")}, 1) == nil) then
			die("the server is not running");
		end
	end);

command("exec", "exec <console command>", "send one admin console command and print the reply",
	function(args)
		local out = console({table.concat(args, " ")}, 2);
		if (out == nil) then die("the server is not running"); end
		io.write(out);
	end);

command("console", "console", "the in-game admin console (Ctrl-C leaves)",
	function()
		if (not console_up()) then die("the server is not running"); end
		os.exit(run("socat READLINE UNIX-CONNECT:" .. sh_quote(SOCK)) and 0 or 1);
	end);

command("masterlist", "masterlist [on|off]",
	"whether the server is announced to the public server lists",
	function(args)
		local doc = open_doc(true);
		if (args[1] == nil) then
			say("masterlist: %s", doc:get("masterlist_enabled") == false and "off" or "on");
			return;
		end
		if (args[1] ~= "on" and args[1] ~= "off") then die("masterlist on|off"); end
		local on = args[1] == "on";
		doc:set("masterlist_enabled", on);
		doc:save();
		-- live, without dropping anybody: load and unload the module
		if (console_up()) then
			console({(on and "load" or "unload") .. " masterlist"}, 1);
		end
		say("masterlist %s%s", args[1],
			on and "" or " (unlisted is not private: ip:port still joins)");
	end);

--============================ UPDATE CHECK ==========================--
-- Whether a newer image is published: the registry is asked, anonymously,
-- for the image's tags -- the versions an update can actually pull --
-- and the answer kept in UPDATE_FILE, where lib_update_notice reads it
-- to tell admins as they log in. The entrypoint runs this every six
-- hours unless update_check = False; nothing else here goes online.

local IMAGE_REPO = os.getenv("LSD_IMAGE_REPO") or "fran6nd/lsd-docker";
local UPDATE_FILE = DATA .. "/rw/update-check";

local function release_parts(v)
	local a, b, c, d = string.match(tostring(v), "^(%d+)%.(%d+)%.(%d+)%.(%d+)$");
	if (a == nil) then return nil; end
	return {tonumber(a), tonumber(b), tonumber(c), tonumber(d)};
end

-- Is release `a` newer than release `b`? Not for a build that is not a
-- release ("dev"): nothing can be said to be newer than that.
local function newer(a, b)
	local x, y = release_parts(a), release_parts(b);
	if (x == nil or y == nil) then return false; end
	for i = 1, 4 do
		if (x[i] ~= y[i]) then return x[i] > y[i]; end
	end
	return false;
end

-- The newest release published on ghcr.io, or nil and why.
local function latest_release()
	local cmd = "tok=$(curl -fsS --max-time 20 "
		.. sh_quote("https://ghcr.io/token?scope=repository:" .. IMAGE_REPO .. ":pull")
		.. " | jq -r .token) && curl -fsS --max-time 20 -H \"Authorization: Bearer $tok\" "
		.. sh_quote("https://ghcr.io/v2/" .. IMAGE_REPO .. "/tags/list")
		.. " | jq -r '.tags[]' 2>/dev/null";
	local h = io.popen(cmd);
	local best;
	for tag in h:lines() do
		if (release_parts(tag) ~= nil and (best == nil or newer(tag, best))) then
			best = tag;
		end
	end
	h:close();
	if (best == nil) then
		return nil, "could not ask ghcr.io/" .. IMAGE_REPO;
	end
	return best;
end

-- What the last check found: {running=, latest=, checked=}, or nil.
local function update_state()
	local t = read_file(UPDATE_FILE);
	if (t == nil) then return nil; end
	local st = {};
	for k, v in string.gmatch(t, "(%w+) ([^\n]+)") do st[k] = v; end
	return st;
end

command("status", "status", "version, state, gamemode, scripts, maps",
	function()
		local v, c = version();
		local doc = open_doc(false);
		say("lsd-docker %s (lsd %s)", v, c);
		if (doc.text == "") then
			say("not set up yet: lsdctl setup");
			return;
		end
		say("server:     %s", running() and "running" or "not running");
		say("sandbox:    %s", sandbox());
		say("name:       %s", tostring(doc:get("masterlist_name") or "LSd server"));
		say("port:       %s/udp", tostring(doc:get("port") or 32887));
		say("listed:     %s", doc:get("masterlist_enabled") == false and "no" or "yes");
		say("gamemode:   %s", tostring(doc:get("gamemode") or "ctf"));
		local ok, plan = pcall(cat().plan, cat(), doc:installed(), doc:get("gamemode"));
		if (ok) then
			local ids = {};
			for _, e in ipairs(plan.entries) do
				if (not e:is_a(catalog.Gamemode)) then ids[#ids+1] = e.id; end
			end
			say("scripts:    %s", #ids > 0 and table.concat(ids, ", ") or "none");
			for _, m in ipairs(plan.missing) do say("missing:    %s", m); end
		else
			say("error:      %s", tostring(plan));
		end
		say("maps:       %s", table.concat(map_names(), ", "));
		local up = update_state();
		if (up ~= nil and newer(up.latest, v)) then
			say("update:     %s available (checked %s): lsd update", up.latest,
				up.checked or "?");
		end
		for _, w in ipairs(doc.warnings) do say("warning:    %s", w); end
		say("");
		print_addresses(doc);
	end);

command("update-check", "update-check [--quiet]",
	"is a newer image published? (the server asks every 6 hours; update_check = False stops it)",
	function(args)
		local _, flags = parse_args(args, {});
		local doc = open_doc(false);
		if (flags.quiet and doc:get("update_check") == false) then
			os.remove(UPDATE_FILE);
			return;
		end

		local running_v = version();
		local latest, err = latest_release();
		if (latest == nil) then
			if (not flags.quiet) then die("%s", err); end
			os.exit(1);
		end

		local f = io.open(UPDATE_FILE, "w");
		if (f ~= nil) then
			f:write(string.format("running %s\nlatest %s\nchecked %s\n", running_v,
				latest, os.date("!%Y-%m-%dT%H:%M:%SZ")));
			f:close();
		end

		if (flags.quiet) then return; end
		if (newer(latest, running_v)) then
			say("lsd-docker %s is available (this is %s): lsd update", latest, running_v);
		elseif (release_parts(running_v) == nil) then
			say("this is a development build (%s); the latest release is %s",
				running_v, latest);
		else
			say("up to date (%s)", running_v);
		end
	end);

command("version", "version", "this image's version and upstream LSd commit",
	function()
		local v, c = version();
		say("%s (lsd %s)", v, c);
	end);

--=============================== SETUP ==============================--

local HEADER = [[
# LSD server settings -- /data/settings
#
# The whole of this server's configuration. `lsdctl` edits it, and so
# may you: `lsdctl edit` (or edit it and run `lsdctl restart`). It is
# read when the server starts, so every change applies on a restart.
#
# Syntax: name = 'text'   flag = True   number = 300   hex = 0x33
#         list = ['a', 'b']   map = {key: value}   (r, g, b)
# Anything after an unquoted # is a comment.
#
# Each installed script keeps its settings in its own `# ---- id ----`
# section below; `lsdctl configure <id>` rewrites it. What a script
# supports: lsdctl info <id>
]];

-- The server's own settings, above every script's section.
local SERVER_SECTION = [[

# Server name shown in the server lists (31 characters at most).
masterlist_name = "LSd server"

# UDP port. Changing it needs the container recreated: lsdctl update.
port = 32887

# Announce the server to the public server lists. Unlisted is not
# private: anyone with ip:port can still join.
masterlist_enabled = True

# Which server lists to announce to. Unset is every list the image
# knows (LSD's own and Build and Shoot's), and follows image updates.
# masterlist_remotes = ["66.135.15.57", "master.buildandshoot.com"]

# Every six hours the server asks ghcr.io whether a newer lsd-docker
# image is published, and tells admins as they log in. False stops it.
# update_check = False

# Where `lsdctl map add` finds maps by page, link or name:id. aos.party
# is built in; more sites that publish maps by id go here.
# map_sources = [{name: 'example', view: 'https://example.org/map/%(id)', vxl: 'https://example.org/get/%(id).vxl', txt: 'https://example.org/get/%(id).txt'}]

# Play the maps in a random order, the first one too; reshuffled each
# time round, never the same map twice in a row.
map_random = False

# Maps to play, space separated, in order. Unset plays every .vxl in
# /data/maps in name order (lsdctl map list).
# map_rotation = "flat"

# The gamemode: lsdctl gamemode <id>.
gamemode = "tdm"

# Installed scripts: lsdctl install / lsdctl remove. Libraries they
# need are listed too.
scripts = []
]];

local function fresh_doc()
	local d = setmetatable({text = HEADER .. SERVER_SECTION}, Doc);
	d:reparse();
	return d;
end

local function ensure_maps()
	run("mkdir -p " .. sh_quote(MAPS));
	if (#map_names() == 0) then
		generate_flat("flat", 62);
		say("no maps yet: generated 'flat' (add real ones with lsdctl map add <url>)");
	end
end

-- Settings a release renamed, carried to their new names. world_editor
-- (a tool) became map_layout (the runtime every gamemode loads) and the
-- editor gamemode: its keys move, and the tool leaves the installed
-- list -- `lsdctl gamemode editor` is how to edit now.
local RENAMED = {
	world_editor_dir = "map_layout_dir",
	world_editor_default_perm = "map_layout_default_perm",
	world_editor_readonly = "map_layout_readonly",
	world_editor_autosave = "map_layout_autosave",
	world_editor_door_speed = "map_layout_door_speed",
	world_editor_door_range = "map_layout_door_range",
	world_editor_elevator_speed = "map_layout_elevator_speed",
	world_editor_elevator_wait = "map_layout_elevator_wait",
	world_editor_elevator_abort = "map_layout_elevator_abort",
	world_editor_elevator_headroom = "map_layout_elevator_headroom",
	world_editor_elevator_piston = "map_layout_elevator_piston",
	world_editor_elevator_stand = "map_layout_elevator_stand",
	world_editor_mark_range = "editor_mark_range",
	world_editor_water_level = "editor_water_level",
};
local RETIRED = {"world_editor"};

-- Scripts a release merged into one: daytime and flashlight are night
-- now (one file speaks both protocol extensions, and tells the bot
-- engine how bots behave in the dark). A server that had either gets
-- night, which ships BOTH -- one that had only the flashlight now also
-- has the daytime extension, harmless at its default (day). Night takes
-- the place of the first of them in the installed list, so the order is
-- kept; their sections merge into night's, every value kept (the keys
-- never clash: daytime_* and flashlight_*). The ext_policy map is
-- keyed by protocol extension id, which did not change, so it stays.
local MERGED = {night = {"daytime", "flashlight"}};

-- Bring an older settings file up to date; true if it changed.
local function migrate(doc)
	local changed = false;

	local moved = {};
	for old, new in pairs(RENAMED) do
		local v = doc:get(old);
		if (v ~= nil) then moved[new] = v; end
	end

	for _, id in ipairs(RETIRED) do
		if (doc:is_installed(id) or doc:section(id) ~= nil) then
			local keep = {};
			for _, x in ipairs(doc:installed()) do
				if (x ~= id) then keep[#keep+1] = x; end
			end
			doc:set_installed(keep);
			doc:remove_section(id);
			changed = true;
		end
	end

	for old, new in pairs(RENAMED) do
		if (doc:get(old) ~= nil) then
			doc:unset(old);
			changed = true;
		end
		if (moved[new] ~= nil and doc:get(new) == nil) then
			doc:set(new, moved[new]);
			changed = true;
		end
	end

	for into, olds in pairs(MERGED) do
		local e = cat():get(into);
		local had, values = false, {};
		for _, old in ipairs(olds) do
			if (doc:is_installed(old) or doc:section(old) ~= nil) then
				had = true;
			end
		end

		if (had and e ~= nil) then
			-- night's own section, if there already is one, under theirs
			for k, v in pairs(doc:section(into) or {}) do values[k] = v; end
			for _, old in ipairs(olds) do
				for k, v in pairs(doc:section(old) or {}) do values[k] = v; end
				doc:remove_section(old);
			end

			local list, put = {}, false;
			for _, x in ipairs(doc:installed()) do
				local old = false;
				for _, o in ipairs(olds) do if (x == o) then old = true; end end
				if (x == into) then old = true; end
				if (not old) then
					list[#list+1] = x;
				elseif (not put) then
					list[#list+1] = into;
					put = true;
				end
			end
			if (not put) then list[#list+1] = into; end
			doc:set_installed(list);

			doc:write_section(e, values);

			-- the extension a server did not have before gets its default
			local policy = doc:get("ext_policy");
			if (type(policy) == "table") then
				for _, x in ipairs(e:ext_list()) do
					if (policy[x.id] == nil) then
						policy[x.id] = e:default_policy(values, x.id);
					end
				end
				doc:set_policy(policy);
			end
			changed = true;
		end
	end

	-- Player Limit seats 255 now, every id, bots included. The seats an
	-- older setup wrote by itself -- 32, and the 254 before it -- under
	-- one of its questions (each began "How many players may the server
	-- seat") become 255, and the policy that went with 32 (applied)
	-- becomes 255's (required). Any other number was chosen, and is
	-- kept. The section is rewritten with today's question, so a 32 set
	-- after this is never taken for the old default again.
	local section = doc:section("player_limit");
	local text = F.section(doc.text, "player_limit");
	local seats = tonumber(section and section.player_limit_max);
	if ((seats == 32 or seats == 254) and text ~= nil
	    and string.find(text, "# How many players may the server seat (", 1, true)) then
		local e = cat():get("player_limit");
		if (e ~= nil) then
			section.player_limit_max = 255;
			doc:write_section(e, section);
			local policy = doc:get("ext_policy");
			if (type(policy) == "table" and policy[192] == "applied") then
				policy[192] = e:default_policy(section, 192);
				doc:set_policy(policy);
			end
			changed = true;
		end
	end

	-- Policies from when every extension came "recommended": one still
	-- on it takes its extension's default now, for its settings.
	local policy = doc:get("ext_policy");
	if (type(policy) == "table") then
		local moved = false;
		for _, e in ipairs(cat():of_class(catalog.Extension)) do
			for _, x in ipairs(e:ext_list()) do
				if (policy[x.id] == "recommended") then
					local now = e:default_policy(doc:section(e.id) or {}, x.id);
					if (now ~= "recommended") then
						policy[x.id] = now;
						moved = true;
					end
				end
			end
		end
		if (moved) then
			doc:set_policy(policy);
			changed = true;
		end
	end

	return changed;
end

command("init", "init", "write default settings if there are none, and bring older ones up to date (the entrypoint runs this)",
	function()
		ensure_maps();
		if (exists(SETTINGS)) then
			local doc = open_doc(true);
			if (migrate(doc)) then
				doc:save();
				say("settings brought up to date (%s)", SETTINGS);
			end
			return;
		end
		local doc = fresh_doc();
		install_ids(doc, default_scripts(), make_ui(true), {});
		doc:save();
		say("wrote default settings to %s -- customise with: lsdctl setup", SETTINGS);
	end);

-- The quick setup: the four questions somebody new to all this can
-- answer, everything else as a new server has it -- every extension,
-- none required, the game's own settings at their defaults. Run again,
-- it keeps the scripts that are installed.
local function quick_setup(doc, ui, existing, flags)
	doc:set("masterlist_name", ui:ask({key = "masterlist_name", type = "string",
		ask = "Server name"}, doc:get("masterlist_name")));
	doc:set("masterlist_enabled", ui:ask({key = "masterlist_enabled", type = "boolean",
		ask = "List the server publicly"}, doc:get("masterlist_enabled") ~= false));

	local now = doc:get("gamemode");
	local mode, want = ask_game_and_map(ui, nil, nil,
		game(now or "") and now or nil);
	local bots = ask_bots(ui, mode, nil);
	local rewards = ask_rewards(ui, nil,
		doc:get("rewards_enabled") == false and "off"
		or doc:get("rewards_free") == true and "infinite" or "on");
	if (not existing) then
		install_ids(doc, default_scripts(), make_ui(true), {});
	end
	set_game_and_map(doc, mode, want, {rotation = true});
	set_bots(doc, bots, mode);
	set_rewards(doc, rewards);

	ensure_maps();
	doc:save();
	say("");
	say("saved %s -- every other setting: lsdctl setup, then full", SETTINGS);
	say("");
	print_addresses(doc);
	say("");
	apply(flags);
end

command("setup", "setup [--defaults]",
	"the setup wizard: name, port, listing, gamemode, scripts and their setup. Run it again any time.",
	function(args)
		local _, flags = parse_args(args, {});
		local ui = make_ui(flags.defaults);
		local existing = exists(SETTINGS);
		local doc = existing and open_doc(true) or fresh_doc();
		local old_port = doc:get("port");

		if (ui.tty) then
			local v = version();
			say("LSD server setup (lsd-docker %s). Enter keeps the value in brackets.", v);
			local how = ui:choose("Setup", {
				{value = "quick", label = "quick",
					hint = "name, public or not, game and map; the rest as a new server has it"},
				{value = "full", label = "full",
					hint = "every setting: port, gamemode, maps, each script"},
			}, "quick");
			if (how == "quick") then
				quick_setup(doc, ui, existing, flags);
				return;
			end
			say("");
		end

		doc:set("masterlist_name", ui:ask({key = "masterlist_name", type = "string",
			ask = "Server name"}, doc:get("masterlist_name")));
		doc:set("port", ui:ask({key = "port", type = "number", min = 1, max = 65535,
			ask = "UDP port"}, doc:get("port") or 32887));
		doc:set("masterlist_enabled", ui:ask({key = "masterlist_enabled", type = "boolean",
			ask = "List the server publicly"}, doc:get("masterlist_enabled") ~= false));

		-- the gamemode
		local modes = {};
		for _, g in ipairs(cat():of_class(catalog.Gamemode)) do
			modes[#modes+1] = {value = g.id, label = g.id, hint = g.summary};
		end
		local mode = ui:choose("Gamemode", modes, doc:get("gamemode") or "ctf");
		choose_gamemode(doc, mode, ui, {});

		-- the maps: what is here, more from the map sources, and which to
		-- play. Downloads happen as they are answered; a failed one is
		-- said and skipped, never fatal to the setup.
		if (ui.tty) then
			local sources = map_sources(doc);
			say("");
			say("Maps installed: %s", table.concat(map_names(), ", "));
			say("%s", where_to_find(sources));
			say("Paste a map's page, its download link or source:id -- one per line, empty to finish.");
			while (true) do
				local input = ui:ask({key = "map", type = "string", ask = "Map to add"}, "");
				if (input == nil or input == "") then break; end
				local line, err = add_map(input, sources);
				say("  %s", line or err);
			end
			doc:set("map_random", ui:ask({key = "map_random", type = "boolean",
				ask = "Play the maps in a random order"}, doc:get("map_random") == true));
			local rot = doc:get("map_rotation");
			local want = ui:ask({key = "map_rotation", type = "string",
				ask = "Maps to play, in order, space separated ('all' for every map)"},
				type(rot) == "string" and rot or "all");
			if (want == "all" or want == "") then
				if (rot ~= nil) then doc:unset("map_rotation"); end
			elseif (want ~= rot) then
				doc:set("map_rotation", want);
			end
		end

		-- the scripts, a category at a time; what is installed starts
		-- ticked, and on a first setup so do the defaults
		local chosen = {};
		for _, id in ipairs(existing and doc:installed() or default_scripts()) do
			chosen[id] = true;
		end

		local want = {};
		for _, c in ipairs(catalog.CATEGORIES) do
			if (c.class ~= catalog.Gamemode and c.class ~= catalog.Library) then
				local items = {};
				for _, e in ipairs(cat():of_class(c.class)) do
					if (e.listed) then
						items[#items+1] = {value = e.id, label = e.id, hint = e.summary};
					end
				end
				if (#items > 0) then
					for _, id in ipairs(ui:pick_many(c.title .. ":", items, chosen)) do
						want[#want+1] = id;
					end
				end
			end
		end

		-- out with what was unticked, libraries included; in with the rest
		local keep = {};
		for _, id in ipairs(doc:installed()) do
			local e = cat():find(id);
			if (e == nil) then keep[#keep+1] = id; end   -- not ours to drop
		end
		local want_set = {};
		for _, id in ipairs(want) do want_set[id] = true; end
		for _, id in ipairs(doc:installed()) do
			local e = cat():find(id);
			if (e ~= nil and not want_set[id] and not e:is_a(catalog.Library)) then
				e:on_remove(doc);
				doc:remove_section(id);
			end
		end
		doc:set_installed(keep);
		-- what the gamemode needs is installed with it, as `gamemode` does
		local mode_e = cat():find(doc:get("gamemode"));
		local add = {};
		for _, id in ipairs(want) do add[#add+1] = id; end
		for _, d in ipairs(mode_e and mode_e:dependencies() or {}) do add[#add+1] = d; end
		install_ids(doc, add, ui, {});

		-- libraries nothing needs any more
		local needed = {};
		local roots = {doc:get("gamemode")};
		for _, id in ipairs(want) do roots[#roots+1] = id; end
		for _, e in ipairs((cat():closure(roots))) do needed[e.id] = true; end
		local final = {};
		for _, id in ipairs(doc:installed()) do
			if (needed[id] or cat():find(id) == nil) then
				final[#final+1] = id;
			else
				doc:remove_section(id);
			end
		end
		doc:set_installed(final);

		local welcome = ui:ask({key = "motd", type = "string",
			ask = "Welcome message (one line; empty keeps the current one)"}, "");
		if (welcome ~= nil and welcome ~= "") then
			doc:set("motd", {welcome});
		end

		ensure_maps();
		doc:save();
		say("");
		say("saved %s", SETTINGS);
		say("");
		print_addresses(doc);
		say("");

		if (doc:get("port") ~= old_port and existing) then
			say("the port changed: recreate the container so it publishes the new one:");
			say("  docker run --rm --volumes-from lsd -v /var/run/docker.sock:/var/run/docker.sock IMAGE update");
		end

		apply(flags);
	end);

-- From the multi-instance layout: its load_order named modules; here
-- `scripts` names catalog entries and the order is worked out.
command("import", "import <old .settings file>",
	"adopt a settings file from the old multi-instance layout",
	function(args)
		local path = args[1] or die("import which file?");
		local text = read_file(path) or die("cannot read %s", path);
		local vals = F.parse(text);
		local d = setmetatable({text = text}, Doc);
		d:reparse();

		local ids, seen = {}, {};
		for _, m in ipairs(type(vals.load_order) == "table" and vals.load_order or {}) do
			local e = cat():find(m);
			if (e ~= nil and not e:is_a(catalog.Gamemode) and not seen[e.id]) then
				seen[e.id] = true;
				ids[#ids+1] = e.id;
			end
		end
		d:unset("load_order");
		if (d:get("port") == nil) then d:set("port", 32887); end
		d.text = HEADER .. "\n" .. d.text;
		d:reparse();
		d:set_installed(ids);
		write_file(SETTINGS, d.text);
		say("imported %s: gamemode %s, scripts %s", path, tostring(d:get("gamemode") or "ctf"),
			table.concat(ids, ", "));
	end);

command("help", "help", "this", function()
	local v = version();
	say("lsdctl -- administer the LSD server (lsd-docker %s)", v);
	say("");
	say("  docker exec -it lsd lsdctl <command>");
	say("");
	for _, h in ipairs(help) do
		say("  %s", h.usage);
		say("      %s", h.text);
	end
	say("");
	say("  update   (run from the host) pull the newest image and recreate the server:");
	say("      docker run --rm --volumes-from lsd -v /var/run/docker.sock:/var/run/docker.sock IMAGE update");
end);

--================================ MAIN ==============================--

local name = table.remove(arg, 1) or "help";
local aliases = {scripts = "list", ls = "list", rm = "remove", uninstall = "remove",
	["-h"] = "help", ["--help"] = "help", ["--version"] = "version", maps = "map"};
name = aliases[name] or name;

local fn = commands[name];
if (fn == nil) then
	die("no command %q (lsdctl help)", name);
end

local ok, err = xpcall(function() fn(arg); end, debug.traceback);
if (not ok) then
	-- errors raised with level 0 are messages for the operator;
	-- anything else is a bug and keeps its traceback
	local msg = tostring(err);
	local short = string.match(msg, "^([^\n]*)\nstack traceback");
	if (short ~= nil and not string.find(short, "%.lua:%d+:")) then
		die("%s", short);
	end
	die("%s", msg);
end
