-- lib_player_effect.lua -- The class every player effect is built on
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- A player effect changes what one player's own actions do: what a gun
-- does when it fires, what a hit does to whoever it lands on -- or what
-- happens around them when it is triggered: a heal for the teammates
-- near them, a medkit. Each one
-- is an instance of PlayerEffect, and the class does everything they
-- have in common so that an effect's own file is only about its weapon:
--
--   * who has the effect: everybody, or the players it was given to
--   * telling a joining player what is different here
--   * advertising itself in tip_spam's `tips` while loaded
--   * hearing about its gun's shots from lib_shot_detect, if it wants to
--   * whom a player may hurt, the_fall's disguised bots included
--
-- USE, in the effect's module:
--
--   local fx = PlayerEffect {
--       name    = "railgun",               -- its catalog id
--       gun     = PlayerEffect.GUN_RIFLE,  -- the weapon it is about
--       warning = {en = "warning: here rifles are railguns."},
--                                          -- told on join
--       tip     = {en = "Spicy: ..."},     -- optional, for tip_spam
--
-- warning and tip are lib_l10n messages, written {en = "..."} so that
-- dev/l10n.lua finds them for the script's locales/template.pot; each
-- player reads them in their own language.
--       on_shot = function(pid) end,       -- optional; once per shot of
--                                          -- `gun` by a player who has
--                                          -- the effect
--       load    = function() end,          -- optional, after the class's
--       unload  = function() end,          -- optional, after the class's
--   };
--   local mod = fx.mod;     -- the LSd module: hook it as usual, and ask
--   ...                     -- fx:holding(pid) / fx:has(pid) in the hooks
--   return mod;
--
-- The class owns mod.on_load, mod.on_unload and mod.after.on_join; an
-- effect puts its own load work in `load` and `unload` instead, and
-- tests/catalog_test.lua refuses a player effect that assigns them.
--
-- The helpers are on `fx`, not on `mod`, on purpose: every function in
-- a module table becomes a hook chain of that name.
--
--============================= WHO HAS IT ===========================--
--
-- Forced on by setup, an effect is everybody's: `<name>_everyone`, true
-- unless the settings say otherwise. A gamemode that hands an effect
-- out instead turns that off and gives it:
--
--   local rail = PlayerEffect.get("railgun");  -- nil if not loaded
--   rail.everyone = false;
--   rail:give(pid, {secs = 30});               -- 30 s, replacing any
--   rail:give(pid, {minutes = 2, stack = true});  -- on top of the rest
--   rail:give(pid, {death = true});            -- until they die
--   rail:give(pid, {map = true});              -- until the map changes
--   rail:give(pid, {ms = 500, death = true});  -- whichever comes first
--   rail:give(pid);                            -- until taken
--   rail:take(pid [, grant]);                  -- all of them, or one
--   rail:has(pid), rail:stacks(pid)
--
-- A grant ends at the first of its limits: ms, secs and minutes add up
-- to its time, `death` ends it when the player dies, `map` when the map
-- changes. Every grant ends when the player leaves. `stack` keeps the
-- grants already there; without it, giving replaces them. What a stack
-- means is the effect's business: `stacks` counts the live grants, and
-- has() is whether there is at least one.
--
-- has() is what the hooks ask, often -- every hit, every tick for every
-- player -- so it is one comparison while nothing has run out: each
-- player's grants keep the time the first of them ends.
local PlayerEffect = {};
PlayerEffect.__index = PlayerEffect;

-- The client's numbers (apidoc/src/get_defaults:13-20), named once here
-- rather than in every effect.
PlayerEffect.GUN_RIFLE = 0;
PlayerEffect.GUN_SMG = 1;
PlayerEffect.GUN_SHOTGUN = 2;
PlayerEffect.TOOL_GUN = 2;
PlayerEffect.HIT_HEAD = 1;
PlayerEffect.HIT_SPADE = 4;

-- name -> the loaded effect of that name
local loaded = {};

local SPEC = {name = "string", gun = "number", trigger = "function",
	every = "number", warning = "table",
	tip = "table", on_shot = "function", load = "function",
	unload = "function"};

-- A message for every player in their language, or the English alone
-- where lib_l10n is not loaded (the host-side tests).
local function message(tab)
	if (l10n_msg ~= nil) then
		return l10n_msg(tab);
	end
	return tab.en;
end

-- The English of a tip as it sits in `tips`, whatever form it took
local function english(t)
	if (l10n_is_msg ~= nil and l10n_is_msg(t)) then
		return t.tab.en;
	end
	return t;
end

function PlayerEffect.new(spec)
	for k, v in pairs(spec) do
		if (SPEC[k] == nil) then
			error(string.format("unknown PlayerEffect field %q", tostring(k)), 3);
		end
		if (type(v) ~= SPEC[k]) then
			error(string.format("PlayerEffect field %q is a %s, expected a %s",
				k, type(v), SPEC[k]), 3);
		end
	end
	if (spec.name == nil or spec.warning == nil) then
		error("a PlayerEffect needs a name and a warning", 3);
	end
	if (spec.gun == nil and spec.trigger == nil) then
		error("a PlayerEffect is about a gun, or has a trigger", 3);
	end
	for _, k in ipairs({"warning", "tip"}) do
		if (spec[k] ~= nil and type(spec[k].en) ~= "string") then
			error(string.format("PlayerEffect field %q needs en = \"...\"", k), 3);
		end
	end

	local fx = setmetatable(spec, PlayerEffect);
	-- the spec's trigger is the effect's own; fx:trigger is the class's
	fx.trigger_fn, fx.trigger = spec.trigger, nil;
	local mod = init_mod();
	fx.mod = mod;
	-- pid -> {n = <live grants>, ends = <when the first runs out>,
	-- [1..n] = grants}; cleared when the player leaves
	fx.grants = pid_connected_table();

	getcfg(fx.name .. "_everyone", true);
	-- an effect with a trigger fires by itself every this many seconds
	-- for each live player who has it; 0 leaves it to a gamemode
	if (fx.trigger_fn ~= nil) then
		getcfg(fx.name .. "_every", fx.every or 0);
	end
	fx.everyone = _G[fx.name .. "_everyone"] ~= false;

	function mod.on_load() fx:_load(); end
	function mod.on_unload() fx:_unload(); end
	-- only when it is everybody's: a player told rifles are railguns
	-- here, who then finds his is not, has been told something false
	function mod.after.on_join(pid)
		if (fx.everyone) then
			server_msg(pid, message(fx.warning));
		end
	end

	return fx;
end

setmetatable(PlayerEffect, {
	__call = function(_, spec) return PlayerEffect.new(spec); end,
});

-- The loaded effect called `name`, for a gamemode to hand out.
function PlayerEffect.get(name)
	return loaded[name];
end

--============================== GRANTS ==============================--

-- When the first of these grants runs out, or never.
local function first_end(g)
	local ends = math.huge;
	for i = 1, g.n do
		if (g[i].ends < ends) then ends = g[i].ends; end
	end
	return ends;
end

-- Drop the grants of `pid` that `gone` says are over.
function PlayerEffect:_drop(pid, gone)
	local g = self.grants[pid];
	if (g == nil) then
		return;
	end

	local n = 0;
	for i = 1, g.n do
		local x = g[i];
		g[i] = nil;
		if (not gone(x)) then
			n = n + 1;
			g[n] = x;
		end
	end
	g.n = n;

	if (n == 0) then
		self.grants[pid] = nil;
	else
		g.ends = first_end(g);
	end
end

function PlayerEffect:give(pid, opts)
	opts = opts or {};

	local secs = (opts.ms or 0)/1000 + (opts.secs or 0)
		+ (opts.minutes or 0)*60;
	local grant = {
		ends = (opts.ms or opts.secs or opts.minutes)
			and get_time() + secs or math.huge,
		death = opts.death or false,
		map = opts.map or false,
	};

	local g = self.grants[pid];
	if (g == nil or not opts.stack) then
		g = {n = 0, ends = math.huge};
		self.grants[pid] = g;
	end
	g.n = g.n + 1;
	g[g.n] = grant;
	if (grant.ends < g.ends) then g.ends = grant.ends; end

	return grant;
end

-- Take one grant back, or every grant when none is named.
function PlayerEffect:take(pid, grant)
	if (grant == nil) then
		self.grants[pid] = nil;
	else
		self:_drop(pid, function(x) return x == grant; end);
	end
end

-- How many of the player's grants are live.
function PlayerEffect:stacks(pid)
	local g = self.grants[pid];
	if (g == nil) then
		return 0;
	end
	if (get_time() >= g.ends) then
		local now = get_time();
		self:_drop(pid, function(x) return now >= x.ends; end);
		g = self.grants[pid];
	end
	return g and g.n or 0;
end

function PlayerEffect:has(pid)
	if (self.everyone) then
		return true;
	end
	local g = self.grants[pid];
	return g ~= nil and (get_time() < g.ends or self:stacks(pid) > 0);
end

--============================== HELPERS =============================--

-- Has the effect, alive, gun in hand, and it is this effect's gun.
function PlayerEffect:holding(pid)
	return self.gun ~= nil and is_alive(pid) and get_tool(pid) == PlayerEffect.TOOL_GUN
		and get_gun(pid) == self.gun and self:has(pid);
end

-- Whom `shooter` may hurt. Not just a team comparison: the_fall keeps
-- bots in its shaft that are on a real team server-side while every
-- client is told they are the enemy, so half of them read as the
-- shooter's own teammates. Read live, not captured on load: the_fall
-- registers fall_is_hostile after the effects, and it is nil for good
-- on an instance without it, where the raw teams are the answer.
function PlayerEffect:hostile(shooter, target)
	if (fall_is_hostile ~= nil) then
		return fall_is_hostile(shooter, target);
	end
	return get_team(shooter) ~= get_team(target);
end

--============================= LIFECYCLE ============================--

-- The tip. The script that changes a weapon is the thing that knows
-- what changed, so an instance gets the line by loading the script and
-- the claim cannot drift from the code. tip_spam reads `tips` live; it
-- is nil on an instance not running tip_spam. Taken out before being
-- put in, so a reload leaves one.
function PlayerEffect:_untip()
	if (tips == nil or self.tip == nil) then
		return;
	end
	for i = #tips, 1, -1 do
		-- by its English, so the tip of a reloaded copy of this
		-- effect is found too
		if (english(tips[i]) == self.tip.en) then
			table.remove(tips, i);
		end
	end
end

function PlayerEffect:_load()
	self:_untip();
	if (tips ~= nil and self.tip ~= nil) then
		tips[#tips+1] = message(self.tip);
	end

	if (self.on_shot ~= nil) then
		local name = self.mod.name or self.name;

		if (shot_listen == nil) then
			error(name .. " needs lib_shot_detect loaded first "
				.. "(its script pulls lib_shot_detect in; check with: lsdctl status)", 0);
		end

		local fx = self;
		shot_listen(name, function(pid, g)
			if (g == fx.gun and fx:has(pid)) then
				fx.on_shot(pid);
			end
		end);
	end

	loaded[self.name] = self;

	if (self.load ~= nil) then
		self.load();
	end
end

function PlayerEffect:_unload()
	self:_untip();

	if (self.on_shot ~= nil and shot_unlisten ~= nil) then
		shot_unlisten(self.mod.name or self.name);
	end

	if (loaded[self.name] == self) then
		loaded[self.name] = nil;
	end

	if (self.unload ~= nil) then
		self.unload();
	end
end

-- The class is a global, like lib_shot_detect's API: effects load after
-- the libraries and find it there.
_G.PlayerEffect = PlayerEffect;

--========================= ENDING THE GRANTS ========================--

-- Death and a new map end the grants given until them, for every
-- loaded effect at once. Leaving needs nothing: the grants are a
-- pid_connected_table.
--============================= TRIGGERS =============================--
--
-- An effect with a trigger does something when it is set off, around or
-- for the player it is set off for: heal the teammates near them, hurt
-- the enemies near them, use a medkit. Who sets it off is a gamemode's
-- business:
--
--   PlayerEffect.get("area_heal"):trigger(pid, {radius = 10, amount = 30})
--
-- opts are the effect's own (each says which it takes); what is left out
-- comes from its settings. A trigger does nothing for a dead player, and
-- answers what it did (the effect says: how many were healed, ...).
--
-- On its own -- installed, forced on, no gamemode driving it -- an effect
-- fires by itself: every <name>_every seconds, for each live player who
-- has it (everybody, while <name>_everyone). The dumb version, and the
-- one setting an operator needs; a gamemode that triggers it itself
-- sets <name>_every = 0.
function PlayerEffect:trigger(pid, opts)
	if (self.trigger_fn == nil or not is_alive(pid)) then
		return nil;
	end
	return self.trigger_fn(pid, opts or {});
end

-- The 3D distance between two players, for effects with a radius.
function PlayerEffect.distance(a, b)
	local p, q = get_position(a), get_position(b);
	local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z;
	return math.sqrt(dx*dx + dy*dy + dz*dz);
end

local mod = init_mod();

-- The timer behind <name>_every, for every loaded effect with a trigger:
-- here rather than in each effect, so an effect's own tick hook is its
-- own. Each effect keeps its own clock.
local next_at = {};

function mod.after.tick()
	local now = get_time();
	for name, fx in pairs(loaded) do
		local every = fx.trigger_fn and tonumber(_G[name .. "_every"]) or 0;
		if (every > 0) then
			if (next_at[name] == nil or next_at[name] > now + every) then
				next_at[name] = now + every;
			elseif (now >= next_at[name]) then
				next_at[name] = now + every;
				for pid in piditer(PID_BROADCAST) do
					if (is_alive(pid) and fx:has(pid)) then
						fx:trigger(pid);
					end
				end
			end
		end
	end
end

local function drop_everywhere(pid, field)
	local gone = function(x) return x[field]; end;
	for _, fx in pairs(loaded) do
		fx:_drop(pid, gone);
	end
end

function mod.after.kill(pid)
	drop_everywhere(pid, "death");
end

function mod.after.load_map()
	for _, fx in pairs(loaded) do
		for pid in pairs(fx.grants) do
			if (type(pid) == "number") then
				fx:_drop(pid, function(x) return x.map; end);
			end
		end
	end
end

return mod;
