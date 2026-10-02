-- lib_gamemode.lua -- Which gamemode runs, and what that costs to load
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- One setting names the mode:
--
--   gamemode = 'hostage'
--
-- and this knows what that means in terms of modules. Which is more
-- than it sounds, because not every mode is one module loaded at one
-- moment.
--
-- WHY THIS EXISTS. "hostage" is not a gamemode. It has no intel, no
-- score logic and no map setup: it rides on ctf, using ctf's tents and
-- intel-based scoring, and it has to load AFTER lib_bot so that
-- lib_bot's spawn_at stays outermost. So the mode name decomposes into
-- two loads at two different points in the startup order, and that
-- cannot be written as one load(mode) line.
--
-- It was therefore hand-written into every instance's config, four
-- times, and three of the four were different: one loaded hostage
-- unconditionally so the setting could not turn it off, one never
-- loaded it at all so asking for hostage silently gave plain ctf. Four
-- copies of six lines produced two bugs. One table does not.
--
-- AND IT REFUSES WHAT IT DOES NOT KNOW, which is the other half.
-- load() is `require` plus `register` (core.lua:237-242), and require
-- returns the CACHED table for a module already loaded -- so
-- registering it a second time makes add_cat point that module's own
-- `next` at itself (core.lua:118) and the next tick overflows the
-- stack. `dd` is an anti-cheat that group_moderation already loads, and
-- it was listed as a gamemode in the doc string of all four configs:
-- `gamemode = 'dd'` was a one-word edit that crashed the server. A name
-- not in the table below is now an error naming the ones that are.
--
-- NOTHING IS DISCOVERED HERE, deliberately. A directory scan would list
-- filenames, and a filename cannot say whether it is a gamemode: ffa.lua
-- and dd.lua are indistinguishable from outside, which the wrong doc
-- string proved. A module cannot declare itself either -- its getcfg
-- runs inside require, inside load, so registration is strictly after
-- the decision to load it. Adding a mode means adding a line here, and
-- that is the honest cost of the question being unanswerable otherwise.
--
-- API (globals):
--   gamemode_base()     load the base mode. Call it where the base
--                       belongs in the order: before tentspawns and
--                       lib_bot.
--   gamemode_extra()    load the rider, if the mode has one. Call it
--                       after lib_bot.
--   gamemode_of()       -> the mode name in force
--   gamemode_base_of()  -> the base module it resolves to
--   gamemode_list()     -> every mode this knows, sorted
local mod = init_mod();

-- mode name -> what to load.
--
--   base   the gamemode module itself, loaded by gamemode_base()
--   after  a module that rides on it, loaded by gamemode_extra()
--
-- A mode with no `after` is one module and the second call does
-- nothing, which is every real gamemode. Only hostage is two.
local MODES = {
	ctf = {base = "ctf"},
	arena = {base = "arena"},
	babel = {base = "babel"},
	ffa = {base = "ffa"},
	-- rides on ctf, and must come after lib_bot
	hostage = {base = "ctf", after = "hostage"},
};

local function known()
	local names = {};

	for name in pairs(MODES) do
		names[#names+1] = name;
	end
	table.sort(names);

	return names;
end

function gamemode_list()
	return known();
end

-- Declared here and once, rather than copy-pasted into every instance
-- config -- which is what made the doc string wrong in four places at
-- the same time. The list in the text comes from the table above, so it
-- cannot drift from what is actually loadable.
getcfg("gamemode", "ctf",
	"Which gamemode runs: " .. table.concat(known(), ", ") .. ".");

local function resolve()
	local name = tostring(gamemode or "ctf");
	local m = MODES[name];

	if (m == nil) then
		-- Loudly, and fatally. The alternative is handing the name to
		-- load(), where a typo throws a bare require error and -- far
		-- worse -- an already-loaded module like `dd` succeeds and
		-- overflows the tick chain a moment later.
		error(string.format(
			"gamemode: %q is not a gamemode. Known: %s. "
			.."(set it in this instance's .settings)",
			name, table.concat(known(), ", ")), 0);
	end

	return name, m;
end

function gamemode_of()
	local name = resolve();
	return name;
end

function gamemode_base_of()
	local _, m = resolve();
	return m.base;
end

function gamemode_base()
	local name, m = resolve();

	log("lib_gamemode: %s -> load %s%s", name, m.base,
		m.after ~= nil and (" then " .. m.after .. " after lib_bot") or "");

	load(m.base);
end

function gamemode_extra()
	local _, m = resolve();

	if (m.after ~= nil) then
		load(m.after);
	end
end

-- Everything this module put in the global table, taken back out again.
--
-- Unloading a module does not undo its globals -- the functions keep
-- working, closed over the state of a module nothing is calling any
-- more -- and consumers test these names to find out whether the thing
-- is available at all. Left behind, they answer yes forever and every
-- such guard becomes dead code.
--
-- The list is exhaustive on purpose: a name added to the API above and
-- forgotten here outlives its own module, and goes on answering for it.
local EXPORTS = {
	"gamemode_base", "gamemode_extra", "gamemode_of",
	"gamemode_base_of", "gamemode_list",
};

-- The gamemode it loaded is NOT unloaded here. This module decides
-- which one runs; it does not own it afterwards, and tearing a gamemode
-- out from under a live round is not something a reload of this should
-- do quietly.
function mod.on_unload()
	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
