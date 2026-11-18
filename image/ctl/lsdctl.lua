-- lsdctl.lua -- Administer the LSD server from inside its container
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
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

local DEFAULT_SCRIPTS = {"player_limit", "message_types", "daytime",
	"flashlight", "teamplay", "damage_markers", "votekick", "time_limit"};

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
		notes[e.ext_id] = e:label();
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
		if (e.ext_id) then say("  extension: id %d, default policy %s", e.ext_id, e.policy); end
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

local function sh_ok(cmd) return run(cmd); end

command("map", "map list | add <url|file>... | rm <name>... | load <name> | generate <name> [height]",
	"the maps in rotation; `add` downloads, `load` switches the live map",
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
			say(type(rot) == "string" and ("rotation: " .. rot .. "  (* played, - installed only)")
				or "rotation: every map above, in name order");
			for n in pairs(inrot) do
				local found = false;
				for _, m in ipairs(names) do if (m == n) then found = true; end end
				if (not found) then say("warning: %s is in map_rotation but not installed", n); end
			end
		elseif (sub == "add") then
			if (#args == 0) then die("map add <url|file>..."); end
			for _, src in ipairs(args) do
				local base = string.match(src, "([^/]+)$");
				if (not string.match(base, "%.vxl$") and not string.match(base, "%.txt$")) then
					die("%s: expected a .vxl (or its .txt)", src);
				end
				local dst = MAPS .. "/" .. base;
				local ok;
				if (string.match(src, "^https?://")) then
					ok = sh_ok(string.format("curl -fSL --proto '=http,https' -o %s %s",
						sh_quote(dst .. ".part"), sh_quote(src)))
						and os.rename(dst .. ".part", dst);
				else
					ok = sh_ok("cp " .. sh_quote(src) .. " " .. sh_quote(dst));
				end
				if (not ok) then os.remove(dst .. ".part"); die("could not add %s", src); end
				say("added %s", base);
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
			local n = string.gsub(args[1] or die("map load <name>"), "%.vxl$", "");
			if (not exists(MAPS .. "/" .. n .. ".vxl")) then die("no map %s (lsdctl map list)", n); end
			if (not console_up()) then die("the server is not running"); end
			console({"loadmap " .. n}, 1);
			say("loading %s", n);
		elseif (sub == "generate") then
			local n = args[1] or die("map generate <name> [height]");
			if (not string.match(n, "^[%w_%-]+$")) then die("%q is not a map name", n); end
			local h = tonumber(args[2] or 62);
			if (h == nil or h < 1 or h > 62) then die("height is 1 (sky) to 62 (lowest)"); end
			generate_flat(n, h);
			say("generated %s: flat ground at z=%d", n, h);
		else
			die("map %s? (list, add, rm, load, generate)", sub);
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
	local port = tostring(doc:get("port") or 32887);
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
		for _, w in ipairs(doc.warnings) do say("warning:    %s", w); end
		say("");
		print_addresses(doc);
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

# Maps to play, space separated, in order. Unset plays every .vxl in
# /data/maps in name order (lsdctl map list).
# map_rotation = "flat"

# The gamemode: lsdctl gamemode <id>.
gamemode = "ctf"

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

command("init", "init", "write default settings if there are none (the entrypoint runs this)",
	function()
		ensure_maps();
		if (exists(SETTINGS)) then return; end
		local doc = fresh_doc();
		install_ids(doc, DEFAULT_SCRIPTS, make_ui(true), {});
		doc:save();
		say("wrote default settings to %s -- customise with: lsdctl setup", SETTINGS);
	end);

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

		-- the scripts, a category at a time; what is installed starts
		-- ticked, and on a first setup so do the defaults
		local chosen = {};
		for _, id in ipairs(existing and doc:installed() or DEFAULT_SCRIPTS) do
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
