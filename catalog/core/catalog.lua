-- catalog.lua -- What a script is, what kinds there are, and what loads when
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Pure Lua, no server API: the server's config.lua uses it to work out
-- the load order, and lsdctl uses it to install, remove and set scripts
-- up. One description of a script, read by both.
--
-- A CATALOG ENTRY is a directory, catalog/<category>/<id>/ (effects
-- one level deeper, catalog/effects/player/<id>/), holding
--
--   script.lua         the manifest: one call to its category's class
--   <module>.lua       the LSd module(s) it ships, if any
--   <module>/...       their submodules (require "map_layout.chunks")
--
-- Everything in the directory but script.lua is copied into the
-- server's scripts/ at start. An entry for an upstream module (ctf,
-- time_limit) ships no files and names the module it loads.
--
-- THE CLASSES. Every entry is an instance of exactly one category class,
-- and every category class extends Script. The category decides what
-- the kind of thing has in common -- where it loads, what it depends
-- on, what installing it means -- so a manifest only says what is
-- particular to it:
--
--   Script                abstract: id, title, summary, modules,
--   |                     requires, settings, presets, setup()
--   +- Library            a dependency other scripts pull in; hidden
--   +- Extension          a protocol extension: needs ext/ext_policy,
--   |                     and a default policy -- a level, or a function
--   |                     of its own settings giving one (player_limit:
--   |                     required only above 32 seats),
--   |                     and its setup includes what a client missing
--   |                     it costs (its ext_policy entry)
--   +- Gamemode           exactly one runs; a base module, optionally
--   |                     a rider loaded after the bots; every one runs
--   |                     the map's layout (map_layout)
--   +- Effect             abstract: changes how the game plays. Meant
--   |  |                  to be pulled in by the gamemodes that play
--   |  |                  with it (their `requires`); setup can also
--   |  |                  force one on for any mode
--   |  +- PlayerEffect    changes what a player's own actions do -- a
--   |  |                  weapon, a hit. Its module is a PlayerEffect
--   |  |                  at runtime too (lib_player_effect)
--   |  +- WorldEffect     changes the map or the match for everybody
--   +- Bot                server-side players; needs the bot library
--   +- Tool               everything else an operator adds
--
-- THE SETTINGS FILE is where installed state lives. `scripts` lists the
-- installed scripts, `gamemode` names the one that runs, and each
-- installed script owns a `# ---- <id> ----` section with its settings.
-- Nothing else records anything, so the file is the whole truth and
-- editing it by hand is a supported way to administer the server.
local C = {};

--============================ CLASS MACHINERY =======================--

-- A class is a table of defaults and methods. Calling it with a spec
-- makes an instance; :extend makes a subclass. Instances read missing
-- fields through to their class, then the class's parent, up to Script.
local function make_class(parent, fields)
	local cls = fields or {};
	cls.__index = cls;
	cls.super = parent;

	setmetatable(cls, {
		__index = parent,
		__call = function(c, spec) return c:new(spec); end,
	});

	return cls;
end

local Script = make_class(nil, {
	-- abstract: a manifest must use a category class
	category = nil,
	-- where in the load order the modules go; see PHASES
	phase = nil,
	-- tie-break inside a phase, lower first
	order = 50,
	-- listed by `lsdctl available`
	listed = true,
	-- shipped by upstream LSd rather than by this catalog
	upstream = false,
});
C.Script = Script;

function Script:extend(fields)
	return make_class(self, fields);
end

function Script:is_a(cls)
	local c = getmetatable(self);

	while (c ~= nil) do
		if (c == cls) then return true; end
		c = c.super;
	end

	return false;
end

-- Fields every manifest may set, and what they must be. Anything else
-- is a typo, and a typo in a manifest is reported rather than ignored.
local SPEC = {
	id = "string", title = "string", summary = "string",
	description = "string",
	module = "string", modules = "table",
	requires = "table", after = "table", with = "table",
	phase = "string", order = "number",
	settings = "table", presets = "table", default_preset = "string",
	questions = "table", upstream = "boolean", listed = "boolean",
	-- Extension
	ext_id = "number", ext_title = "string", policy = "string|function",
	-- Gamemode
	base = "string", rider = "string",
};

function Script:new(spec)
	if (rawget(self, "category") == nil and self.category == nil) then
		error("abstract class: use Library, Extension, Gamemode, "
			.. "PlayerEffect, WorldEffect, Bot or Tool", 2);
	end

	for k, v in pairs(spec) do
		local want = SPEC[k];

		if (want == nil) then
			error(string.format("unknown manifest field %q", tostring(k)), 2);
		end
		if (not string.find("|" .. want .. "|", "|" .. type(v) .. "|", 1, true)) then
			error(string.format("manifest field %q is a %s, expected a %s",
				k, type(v), want), 2);
		end
	end

	local o = setmetatable(spec, self);
	o.requires = o.requires or {};
	o.with = o.with or {};
	o.after = o.after or {};
	o.settings = o.settings or {};
	o.questions = o.questions or {};

	return o;
end

-- The LSd modules this script loads, in order.
function Script:load_modules()
	if (self.modules ~= nil) then
		return self.modules;
	end

	return {self.module or self.id};
end

-- Other catalog ids that must be installed for this one to work. The
-- category may add its own: every Extension needs `ext`.
function Script:dependencies()
	local out = self:load_dependencies();

	for _, d in ipairs(self.with) do out[#out+1] = d; end

	return out;
end

-- The ones that must load first. `with` names scripts installed
-- alongside that load later than this one and are not needed at its
-- load: the bots mode's rider sets a global the guards read, and the
-- guards, being bots, load after every rider.
function Script:load_dependencies()
	local out = {};

	for _, d in ipairs(self.class_requires or {}) do out[#out+1] = d; end
	for _, d in ipairs(self.requires) do out[#out+1] = d; end

	return out;
end

-- Ids that must be installed alongside this one but impose no load
-- order: lib_ext_policy is wanted wherever an extension is, and loads
-- after some of them.
function Script:companions()
	local out = {};
	for _, d in ipairs(self.class_companions or {}) do out[#out+1] = d; end
	return out;
end

function Script:kind()
	return self.category;
end

-- The phase whose modules use the dependencies: the script's own.
function Script:needs_from()
	return self.phase;
end

function Script:label()
	return self.title or self.id;
end

-- The presets, in the order they were declared.
function Script:preset(name)
	for _, p in ipairs(self.presets or {}) do
		if (p.name == name) then return p; end
	end
end

function Script:preset_names()
	local out = {};
	for _, p in ipairs(self.presets or {}) do out[#out+1] = p.name; end
	return out;
end

-- Every key this script's setup decides, which is what a re-run of the
-- setup is allowed to rewrite. Keys the operator added to the section
-- by hand survive it.
function Script:setup_keys()
	local keys, seen = {}, {};
	local function add(k)
		if (not seen[k]) then seen[k] = true; keys[#keys+1] = k; end
	end

	for _, p in ipairs(self.presets or {}) do
		for k in pairs(p.values or {}) do add(k); end
	end
	for _, q in ipairs(self.questions) do add(q.key); end
	for k in pairs(self.settings) do add(k); end

	table.sort(keys);
	return keys;
end

-- The values installing writes, without asking anything: the default
-- preset, then each question's default, then plain settings.
function Script:defaults()
	local v = {};

	for k, x in pairs(self.settings) do v[k] = x; end

	local p = self:preset(self.default_preset or (self:preset_names()[1]));
	if (p ~= nil) then
		for k, x in pairs(p.values or {}) do v[k] = x; end
	end

	for _, q in ipairs(self.questions) do
		if (q.default ~= nil and v[q.key] == nil) then
			v[q.key] = q.default;
		end
	end

	return v, p and p.name or nil;
end

-- The interactive setup. `ui` asks (see lsdctl); `current` is what the
-- settings file says now, so re-running the setup offers the values
-- already in force rather than the factory ones. Returns the values to
-- write and the preset chosen, if any.
--
-- Categories extend this; Extension adds its policy question.
function Script:setup(ui, current, opts)
	opts = opts or {};
	current = current or {};

	-- the plain settings, then the chosen preset over them; never the
	-- default preset under a different one, or its values would leak
	local values, preset = {}, nil;
	for k, x in pairs(self.settings) do values[k] = x; end
	local names = self:preset_names();
	local _, default_preset = self:defaults();

	if (#names > 0) then
		local chosen = opts.preset;

		if (chosen == nil) then
			local items = {};
			for _, p in ipairs(self.presets) do
				items[#items+1] = {value = p.name, label = p.name,
					hint = p.summary};
			end
			chosen = ui:choose(self:label() .. " preset", items,
				opts.current_preset or default_preset);
		end

		local p = self:preset(chosen);
		if (p == nil) then
			error(string.format("%s has no preset %q (presets: %s)",
				self.id, tostring(chosen), table.concat(names, ", ")), 0);
		end

		preset = p.name;
		for k, x in pairs(p.values or {}) do values[k] = x; end
	end

	for _, q in ipairs(self.questions) do
		local have = current[q.key];
		if (have == nil) then have = values[q.key]; end

		values[q.key] = ui:ask(q, have);
	end

	return values, preset;
end

-- Hooks for what installing means beyond the script's own section.
-- `doc` is the settings document (see lsdctl); the default is nothing.
function Script:on_install(doc, values) end
function Script:on_remove(doc) end

--============================ THE CATEGORIES ========================--

C.Library = Script:extend({
	category = "library",
	phase = "libs",
	-- pulled in by what needs it, not chosen
	listed = false,
});

C.Extension = Script:extend({
	category = "extension",
	phase = "extensions",
	class_requires = {"ext"},
	class_companions = {"ext_policy"},
	-- what a client missing it costs, unless the setup says otherwise
	policy = "recommended",
});

local POLICIES = {
	{value = "disabled", label = "disabled",
		hint = "not offered at all; the module stays loaded"},
	{value = "applied", label = "applied",
		hint = "offered and used, silently"},
	{value = "recommended", label = "recommended",
		hint = "used, and a client without it is told so"},
	{value = "required", label = "required",
		hint = "a client without it is held in spectator"},
};
C.POLICIES = POLICIES;

-- An extension's setup is its own, plus what a client that does not
-- speak it costs. That answer lives in the shared ext_policy map, not
-- in the extension's section, because lib_ext_policy reads one map for
-- every extension.
-- The policy this extension comes with, for these settings of its own.
function C.Extension:default_policy(values)
	if (type(self.policy) == "function") then
		return self.policy(values or {});
	end
	return self.policy;
end

function C.Extension:setup(ui, current, opts)
	local values, preset = Script.setup(self, ui, current, opts);
	local policy = opts and opts.policy;

	if (policy == nil) then
		local now = type(current.ext_policy) == "table"
			and current.ext_policy[self.ext_id] or nil;
		-- a policy that is the default for the old settings was never
		-- chosen: it follows the settings to their new default
		if (now == self:default_policy(current)) then
			now = nil;
		end
		policy = ui:choose("What a client without " .. self:label()
			.. " costs", POLICIES, now or self:default_policy(values));
	end

	self._policy = policy;
	return values, preset;
end

function C.Extension:on_install(doc)
	local policy = doc:get("ext_policy");
	if (type(policy) ~= "table") then policy = {}; end

	policy[self.ext_id] = self._policy or policy[self.ext_id]
		or self:default_policy({});
	doc:set_policy(policy);
end

function C.Extension:on_remove(doc)
	local policy = doc:get("ext_policy");

	if (type(policy) == "table" and policy[self.ext_id] ~= nil) then
		policy[self.ext_id] = nil;
		doc:set_policy(policy);
	end
end

-- Every gamemode runs the map's layout -- its doors, elevators and edit
-- permissions -- and has its team callouts in the pie menu, so both
-- libraries come with the category.
C.Gamemode = Script:extend({
	category = "gamemode",
	phase = "gamemode",
	class_requires = {"map_layout", "callouts"},
});

-- A gamemode is a base module loaded where the mode belongs -- before
-- the spawns and the bots -- and optionally a rider loaded after them.
-- Hostage is the reason: it plays on ctf's tents and scoring, and has
-- to wrap lib_bot's spawn_at rather than be wrapped by it.
function C.Gamemode:load_modules()
	return {self.base or self.module or self.id};
end

function C.Gamemode:rider_modules()
	return self.rider and {self.rider} or {};
end

-- A mode with a rider needs what the rider needs, which is loaded
-- before the rider -- hostage's lib_bot comes after ctf, before hostage.
function C.Gamemode:needs_from()
	return self.rider and "rider" or self.phase;
end

-- Abstract, like Script: an effect is one of the two below. Both load
-- in the effects phase, before the gamemode, so a gamemode can require
-- one and a forced-on one plays under any mode.
C.Effect = Script:extend({
	phase = "effects",
});

-- Every player effect's module is built on lib_player_effect, so the
-- library comes with the category rather than with each manifest.
C.PlayerEffect = C.Effect:extend({
	category = "player_effect",
	class_requires = {"player_effect"},
});

C.WorldEffect = C.Effect:extend({
	category = "world_effect",
});

C.Bot = Script:extend({
	category = "bot",
	-- after the gamemode and its spawns, which is what bots spawn into
	phase = "late",
	class_requires = {"bot"},
});

C.Tool = Script:extend({
	category = "tool",
	phase = "tools",
});

-- Directory name -> class, which is also the order `available` shows.
C.CATEGORIES = {
	{dir = "gamemodes", class = C.Gamemode, title = "Gamemodes"},
	{dir = "extensions", class = C.Extension, title = "Extensions"},
	{dir = "effects/player", class = C.PlayerEffect, title = "Player effects"},
	{dir = "effects/world", class = C.WorldEffect, title = "World effects"},
	{dir = "bots", class = C.Bot, title = "Bots"},
	{dir = "tools", class = C.Tool, title = "Tools"},
	{dir = "libs", class = C.Library, title = "Libraries"},
};

--============================== LOAD ORDER ==========================--

-- Where things load, which is not a preference but a set of
-- constraints that break the server when broken:
--
--   libs        what the rest builds on (lib_ext, lib_shot_detect)
--   effects     weapon and death rules, inside everything after them
--   extensions  protocol extensions, after lib_ext
--   tools       commands, editors, votes
--   gamemode    the base mode -- before spawns and bots
--   spawns      tentspawns, fixed in config.lua
--   bots        lib_bot, which wants the mode's spawns
--   rider       a gamemode's second half (hostage after lib_bot)
--   late        bot AIs and what rides on lib_bot
--
-- config.lua owns `spawns` and fills `rider` from the gamemode; every
-- other phase is the scripts that declare it.
C.PHASES = {"libs", "effects", "extensions", "tools", "gamemode",
	"spawns", "bots", "rider", "late"};

local PHASE_INDEX = {};
for i, p in ipairs(C.PHASES) do PHASE_INDEX[p] = i; end

--============================== THE CATALOG =========================--

local Catalog = {};
Catalog.__index = Catalog;

-- Build a catalog from manifest sources. `reader` abstracts the file
-- system so the server (lfs) and the tests (a table) can both feed it:
--   reader.dirs(path)     -> iterator of entry names that are dirs
--   reader.exists(path)   -> boolean
--   reader.loadfile(path) -> chunk or nil, err
function C.open(roots, reader)
	local cat = setmetatable({entries = {}, list = {}, errors = {},
		roots = roots}, Catalog);

	local env = setmetatable({}, {__index = function(_, k)
		if (C[k] ~= nil and type(C[k]) == "table" and C[k].category ~= nil
		    or k == "Script" or k == "Effect") then
			return C[k];
		end
		return _G[k];
	end});

	for _, root in ipairs(roots) do
		for _, cdef in ipairs(C.CATEGORIES) do
			local cdir = root .. "/" .. cdef.dir;

			if (reader.exists(cdir)) then
				for name in reader.dirs(cdir) do
					local path = cdir .. "/" .. name .. "/script.lua";

					if (reader.exists(path)) then
						cat:_load(path, name, cdef, root, env, reader);
					end
				end
			end
		end
	end

	table.sort(cat.list, function(a, b) return a.id < b.id; end);
	return cat;
end

function Catalog:_load(path, name, cdef, root, env, reader)
	local chunk, err = reader.loadfile(path);
	local ok, entry;

	if (chunk ~= nil) then
		if (setfenv ~= nil) then setfenv(chunk, env); end
		ok, entry = pcall(chunk);
		if (not ok) then err = entry; end
	end

	if (not ok or type(entry) ~= "table" or getmetatable(entry) == nil) then
		self.errors[#self.errors+1] = string.format("%s: %s", path,
			tostring(err or "does not return a script"));
		return;
	end

	entry.id = entry.id or name;

	if (not entry:is_a(cdef.class)) then
		self.errors[#self.errors+1] = string.format(
			"%s: a %s under %s/", path, entry:kind(), cdef.dir);
		return;
	end

	entry.dir = root .. "/" .. cdef.dir .. "/" .. name;
	entry.root = root;

	-- a later root (the operator's own) replaces an earlier one's entry
	-- of the same id, which is how a fork of a catalog script is used;
	-- what it replaced is kept, for lsdctl to say so
	if (self.entries[entry.id] ~= nil) then
		entry.replaces = self.entries[entry.id];
		for i, e in ipairs(self.list) do
			if (e.id == entry.id) then table.remove(self.list, i); break; end
		end
	end

	self.entries[entry.id] = entry;
	self.list[#self.list+1] = entry;
end

function Catalog:get(id)
	return self.entries[id];
end

-- An id, or an entry's module name -- `lib_flashlight` finds
-- `flashlight`, so the names an operator already knows keep working.
function Catalog:find(name)
	if (self.entries[name] ~= nil) then
		return self.entries[name];
	end

	for _, e in ipairs(self.list) do
		for _, m in ipairs(e:load_modules()) do
			if (m == name) then return e; end
		end
	end
end

function Catalog:of_class(cls)
	local out = {};
	for _, e in ipairs(self.list) do
		if (e:is_a(cls)) then out[#out+1] = e; end
	end
	return out;
end

-- The installed set closed under dependencies. Returns the entries, and
-- the names that could not be found (reported, not fatal: one missing
-- script should cost that script, not the server).
function Catalog:closure(ids)
	local out, seen, missing = {}, {}, {};

	local function visit(id, from)
		if (seen[id]) then return; end
		seen[id] = true;

		local e = self:find(id);
		if (e == nil) then
			missing[#missing+1] = from and (id .. " (needed by " .. from .. ")")
				or id;
			return;
		end

		for _, d in ipairs(e:dependencies()) do visit(d, e.id); end
		out[#out+1] = e;
		for _, d in ipairs(e:companions()) do visit(d, e.id); end
	end

	for _, id in ipairs(ids) do visit(id); end
	return out, missing;
end

-- Order a set of entries by phase, then by dependency inside a phase,
-- then by `order` and id. A dependency in a LATER phase than its user
-- is a manifest bug and an error, since no order can satisfy it.
function Catalog:sort(entries)
	local by_id = {};
	for _, e in ipairs(entries) do by_id[e.id] = e; end

	for _, e in ipairs(entries) do
		for _, d in ipairs(e:load_dependencies()) do
			local de = by_id[d] or self:find(d);
			local at = e:needs_from();
			if (de ~= nil and PHASE_INDEX[de.phase] > PHASE_INDEX[at]) then
				error(string.format("%s (%s) needs %s, which loads later (%s)",
					e.id, at, de.id, de.phase), 0);
			end
		end
	end

	local base = {};
	for _, e in ipairs(entries) do base[#base+1] = e; end
	table.sort(base, function(a, b)
		local pa, pb = PHASE_INDEX[a.phase], PHASE_INDEX[b.phase];
		if (pa ~= pb) then return pa < pb; end
		if (a.order ~= b.order) then return a.order < b.order; end
		return a.id < b.id;
	end);

	-- Kahn's algorithm, always taking the earliest ready entry in the
	-- base order, so the result is the base order wherever dependencies
	-- leave it free. `after` orders without requiring.
	local before = {};   -- id -> ids that must precede it
	for _, e in ipairs(base) do
		local b = {};
		for _, d in ipairs(e:load_dependencies()) do
			local de = by_id[d];
			if (de and de.phase == e.phase) then b[#b+1] = d; end
		end
		for _, d in ipairs(e.after) do
			if (by_id[d]) then b[#b+1] = d; end
		end
		before[e.id] = b;
	end

	local done, out = {}, {};
	while (#out < #base) do
		local picked = nil;

		for _, e in ipairs(base) do
			if (not done[e.id]) then
				local ready = true;
				for _, d in ipairs(before[e.id]) do
					if (not done[d]) then ready = false; break; end
				end
				if (ready) then picked = e; break; end
			end
		end

		if (picked == nil) then
			local left = {};
			for _, e in ipairs(base) do
				if (not done[e.id]) then left[#left+1] = e.id; end
			end
			error("dependency cycle among: " .. table.concat(left, ", "), 0);
		end

		done[picked.id] = true;
		out[#out+1] = picked;
	end

	return out;
end

-- The whole plan for a server: which scripts, in which order, split
-- into the phases config.lua walks. `installed` is the settings file's
-- `scripts` list and `gamemode` its gamemode.
--
-- Returns {phases = {phase = {module, ...}}, entries = {...},
-- gamemode = entry, missing = {...}}.
function Catalog:plan(installed, gamemode)
	local mode = self:find(gamemode or "ctf");
	if (mode == nil or not mode:is_a(C.Gamemode)) then
		local known = {};
		for _, g in ipairs(self:of_class(C.Gamemode)) do
			known[#known+1] = g.id;
		end
		error(string.format("%q is not a gamemode. Known: %s",
			tostring(gamemode), table.concat(known, ", ")), 0);
	end
	-- What runs is what is installed and not a library -- a library is
	-- there for what needs it, so one left behind by a gamemode no longer
	-- running (babel's babel_protect) is not loaded -- and no gamemode
	-- but the one chosen, whose own needs come with it.
	local ids = {};
	for _, id in ipairs(installed or {}) do
		local e = self:find(id);
		if (e == nil or not (e:is_a(C.Library) or (e:is_a(C.Gamemode) and e ~= mode))) then
			ids[#ids+1] = id;
		end
	end
	ids[#ids+1] = mode.id;

	local entries, missing = self:closure(ids);

	-- a gamemode is chosen, not installed: one listed in `scripts` that
	-- is not the one running would load a second mode on top of it
	local kept = {};
	for _, e in ipairs(entries) do
		if (not e:is_a(C.Gamemode) or e == mode) then
			kept[#kept+1] = e;
		end
	end

	local sorted = self:sort(kept);
	local phases = {};
	for _, p in ipairs(C.PHASES) do phases[p] = {}; end

	for _, e in ipairs(sorted) do
		for _, m in ipairs(e:load_modules()) do
			table.insert(phases[e.phase], m);
		end
	end

	for _, m in ipairs(mode:rider_modules()) do
		table.insert(phases.rider, m);
	end

	return {phases = phases, entries = sorted, gamemode = mode,
		missing = missing};
end

--============================ FILE SYSTEMS ==========================--

-- A reader over lfs, which the image builds (exec/lfs.so).
function C.lfs_reader(lfs)
	return {
		exists = function(p) return lfs.attributes(p, "mode") ~= nil; end,
		dirs = function(p)
			local names = {};
			for n in lfs.dir(p) do
				if (n ~= "." and n ~= ".."
				    and lfs.attributes(p .. "/" .. n, "mode") == "directory") then
					names[#names+1] = n;
				end
			end
			table.sort(names);
			local i = 0;
			return function() i = i + 1; return names[i]; end;
		end,
		loadfile = loadfile,
	};
end

return C;
