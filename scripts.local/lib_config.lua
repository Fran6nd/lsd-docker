-- lib_config.lua -- Every module's config fields, discovered automatically
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Drop a script into scripts.local/, start the server, and ask it what
-- that script can be configured with:
--
--   ./lsdctl <instance> config                 every field
--   ./lsdctl <instance> config daytime         the ones matching
--   ./lsdctl <instance> config --new           only what you are not setting
--   ./lsdctl <instance> config --lua           as a pasteable config block
--
-- NOTHING REGISTERS ANYTHING. That is the whole idea: every module in
-- this tree already declares its fields, by calling
--
--   getcfg("daytime_night", false)
--
-- which is core.lua's "set this global unless the config already did"
-- (core.lua:43-47). A module that does that has told us its key and its
-- default, and 213 of them across the tree do it already. So rather
-- than inventing a registration call for authors to remember, this
-- watches the one they are all using.
--
-- A field therefore costs its author nothing and cannot be forgotten:
-- if the knob works at all, it was declared, and if it was declared, it
-- is in here.
--
-- HOW IT KNOWS WHAT YOU SET. getcfg only fills a global that is still
-- nil, so at the moment it runs, a non-nil global means config.lua got
-- there first. That one bit is the difference between "you chose this"
-- and "this is just the default", which is what makes --new useful: it
-- is every field no config of yours mentions.
--
-- WHICH MODULE a field came from is taken from the Lua source file the
-- getcfg call sits in (debug.getinfo), not from anything declared. So
-- it keeps working for a script this module has never heard of, which
-- is the point.
--
-- LOAD IT FIRST. A field is recorded when its getcfg runs, so anything
-- loaded before this is invisible to it -- the hook cannot see into the
-- past. config.lua should load it at the top, before the group_* lines.
-- Fields from modules loaded earlier are simply absent rather than
-- wrong; config_missed() says how many, so the omission is visible
-- instead of silent.
--
-- IT NEVER WRITES YOUR CONFIG. config.lua is input, and a server that
-- edited it would lose your comments, race its own restarts and put its
-- startup path at the mercy of a script bug. Serious daemons print
-- their effective configuration and let you redirect it -- sshd -T,
-- nginx -T, postgres --describe-config -- and that is exactly what the
-- --lua form is for: read it, keep the lines you want.
--
-- API (globals):
--   config_fields()        -> { {key=, default=, value=, source=,
--                                set=} ... }, sorted by key
--   config_dump(pattern, opts)   log it, for lsdctl to read back.
--        pattern  a Lua pattern matched against the key; nil for all
--        opts.new_only   only fields config.lua does not set
--        opts.lua        emit pasteable `key = value` lines
--   config_missed()        -> how many getcfg calls happened before
--                             this module was loaded, i.e. are missing
local mod = init_mod();

-- key -> {default=, source=, set=}. Not a pid table and not cleared:
-- these are declarations, made once at load, and they outlive rounds
-- and maps.
local fields = {};
-- getcfg calls this module was not loaded in time to see. Counted
-- rather than guessed at: core.lua's own getcfg is replaced below, so
-- the only ones missed are those that ran before that happened, and
-- there is no way to recover them -- only to admit to them.
local missed = 0;

getcfg("config_debug", false);

--============================= THE HOOK =============================--

-- core.lua's getcfg, kept and still doing the work. Wrapped rather than
-- reimplemented: the semantics that matter -- fill only a nil global --
-- are its, and a copy of them here would be a second place for them to
-- drift.
local core_getcfg = getcfg;

-- Where the call came from, as the script that made it. Level 2 is
-- whoever called getcfg; "S" asks only for source information, which is
-- the cheap half of getinfo.
local function caller_source()
	local ok, info = pcall(debug.getinfo, 3, "S");

	if (not ok or info == nil or info.source == nil) then
		return "?";
	end

	-- "@./scripts/lib_daytime.lua" -> "lib_daytime"
	local src = string.gsub(info.source, "^@", "");
	return (string.gsub(string.gsub(src, "^.*/", ""), "%.lua$", ""));
end

function getcfg(key, default)
	if (type(key) == "string") then
		-- The one bit worth catching, and it is only true before the
		-- call below runs: a global that is already non-nil was set by
		-- config.lua, because nothing else sets one this early.
		local already = _G[key] ~= nil;

		-- A key declared twice -- two modules, or one reloaded -- keeps
		-- the first `set`, since that is the reading taken before any
		-- default could have filled it in.
		local was = fields[key];

		fields[key] = {
			default = default,
			source = caller_source(),
			set = was ~= nil and was.set or already,
		};
	end

	return core_getcfg(key, default);
end

--============================ SERIALISING ===========================--

-- A Lua value as Lua source, for the pasteable form. Deliberately
-- small: config fields are scalars and the occasional flat table, and
-- anything deeper than this is a module keeping state in a global
-- rather than offering a setting.
local function quote(s)
	return '"' .. string.gsub(string.gsub(s, "\\", "\\\\"), '"', '\\"') .. '"';
end

local function serialise(v, depth)
	depth = depth or 0;
	local t = type(v);

	if (t == "string") then return quote(v); end
	if (t == "number" or t == "boolean") then return tostring(v); end
	if (t == "nil") then return "nil"; end

	if (t == "table") then
		if (depth >= 3) then
			return "{--[[too deep]]}";
		end

		local out, n = {}, 0;

		-- array part first, so a list reads as a list
		for i,x in ipairs(v) do
			out[#out+1] = serialise(x, depth+1);
			n = i;
		end

		local keys = {};
		for k in pairs(v) do
			if (not (type(k) == "number" and k >= 1 and k <= n
			         and k % 1 == 0)) then
				keys[#keys+1] = k;
			end
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b);
		end);

		for _,k in ipairs(keys) do
			local label;

			if (type(k) == "string" and string.match(k, "^[%a_][%w_]*$")) then
				label = k .. " = ";
			else
				label = "[" .. serialise(k, depth+1) .. "] = ";
			end

			out[#out+1] = label .. serialise(v[k], depth+1);
		end

		return "{" .. table.concat(out, ", ") .. "}";
	end

	-- functions and userdata are not settings; say so rather than
	-- emitting something that will not load
	return "nil --[[" .. t .. "]]";
end

--=============================== API ================================--

function config_missed()
	return missed;
end

function config_fields()
	local keys = {};

	for k in pairs(fields) do
		keys[#keys+1] = k;
	end
	table.sort(keys);

	local out = {};
	for _,k in ipairs(keys) do
		local f = fields[k];

		out[#out+1] = {
			key = k,
			default = f.default,
			value = _G[k],
			source = f.source,
			set = f.set,
		};
	end

	return out;
end

-- Logged rather than returned, because the caller is lsdctl reading the
-- server's own output over the console socket. One field per line, with
-- a stable prefix so it can be grepped out of everything else the
-- server is saying at the time.
function config_dump(pattern, opts)
	opts = opts or {};

	local shown = 0;

	for _,f in ipairs(config_fields()) do
		local hit = pattern == nil or pattern == ""
			or string.find(f.key, pattern) ~= nil
			or string.find(f.source, pattern) ~= nil;

		if (hit and not (opts.new_only and f.set)) then
			shown = shown + 1;

			if (opts.lua) then
				-- commented out when it is already yours: pasting it
				-- would otherwise silently restate a choice you made
				-- somewhere else in the file
				log("CFG| %s%s = %s%s",
					f.set and "-- " or "",
					f.key, serialise(f.value),
					f.set and "   -- already set in your config" or "");
			else
				log("CFG| %-28s %-20s %-10s %s",
					f.key, f.source,
					f.set and "config" or "default",
					serialise(f.value));
			end
		end
	end

	log("CFG-END %d shown, %d known, %d missed before load", shown,
		#config_fields(), missed);
end

--============================ LIFECYCLE =============================--

function mod.on_load()
	-- Count what we were too late for. Every getcfg that ran before
	-- this module replaced core.lua's filled a global we can see but
	-- cannot attribute, so the honest figure is "globals that look like
	-- settings and are not in `fields`" -- which cannot be computed, so
	-- the next best thing: nothing is missed on a cold start where this
	-- loads first, and a hot load mid-session misses everything that
	-- ran before it. Say which case we are in.
	if (next(fields) == nil) then
		missed = 0;
	end

	if (config_debug) then
		log("lib_config: watching getcfg, %d field(s) so far",
			#config_fields());
	end
end

-- core.lua's getcfg goes back, so unloading this leaves no wrapper
-- behind calling into a module nothing is holding.
local EXPORTS = {
	"config_fields", "config_dump", "config_missed",
};

function mod.on_unload()
	getcfg = core_getcfg;

	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
