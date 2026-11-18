-- lib_player_effect.lua -- The class every player effect is built on
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- A player effect changes what one player's own actions do: what a gun
-- does when it fires, what a hit does to whoever it lands on. Each one
-- is an instance of PlayerEffect, and the class does everything they
-- have in common so that an effect's own file is only about its weapon:
--
--   * telling a joining player what is different here
--   * advertising itself in tip_spam's `tips` while loaded
--   * hearing about its gun's shots from lib_shot_detect, if it wants to
--   * whom a player may hurt, the_fall's disguised bots included
--
-- USE, in the effect's module:
--
--   local fx = PlayerEffect {
--       gun     = PlayerEffect.GUN_RIFLE,  -- the weapon it is about
--       warning = "here rifles are railguns.", -- told on join
--       tip     = "Spicy: ...",            -- optional, for tip_spam
--       on_shot = function(pid) end,       -- optional; once per shot of
--                                          -- `gun`, via lib_shot_detect
--       load    = function() end,          -- optional, after the class's
--       unload  = function() end,          -- optional, after the class's
--   };
--   local mod = fx.mod;     -- the LSd module: hook it as usual
--   ...
--   return mod;
--
-- The class owns mod.on_load, mod.on_unload and mod.after.on_join; an
-- effect puts its own load work in `load` and `unload` instead, and
-- tests/catalog_test.lua refuses a player effect that assigns them.
--
-- The helpers are on `fx`, not on `mod`, on purpose: every function in
-- a module table becomes a hook chain of that name.
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

local SPEC = {gun = "number", warning = "string", tip = "string",
	on_shot = "function", load = "function", unload = "function"};

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
	if (spec.gun == nil or spec.warning == nil) then
		error("a PlayerEffect needs a gun and a warning", 3);
	end

	local fx = setmetatable(spec, PlayerEffect);
	local mod = init_mod();
	fx.mod = mod;

	function mod.on_load() fx:_load(); end
	function mod.on_unload() fx:_unload(); end
	function mod.after.on_join(pid)
		server_msg(pid, "warning: " .. fx.warning);
	end

	return fx;
end

setmetatable(PlayerEffect, {
	__call = function(_, spec) return PlayerEffect.new(spec); end,
});

--============================== HELPERS =============================--

-- Alive, gun in hand, and it is this effect's gun.
function PlayerEffect:holding(pid)
	return is_alive(pid) and get_tool(pid) == PlayerEffect.TOOL_GUN
		and get_gun(pid) == self.gun;
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
		if (tips[i] == self.tip) then
			table.remove(tips, i);
		end
	end
end

function PlayerEffect:_load()
	self:_untip();
	if (tips ~= nil and self.tip ~= nil) then
		tips[#tips+1] = self.tip;
	end

	if (self.on_shot ~= nil) then
		local name = self.mod.name or tostring(self);

		if (shot_listen == nil) then
			error(name .. " needs lib_shot_detect loaded first "
				.. "(its script pulls lib_shot_detect in; check with: lsdctl status)", 0);
		end

		local gun, on_shot = self.gun, self.on_shot;
		shot_listen(name, function(pid, g)
			if (g == gun) then
				on_shot(pid);
			end
		end);
	end

	if (self.load ~= nil) then
		self.load();
	end
end

function PlayerEffect:_unload()
	self:_untip();

	if (self.on_shot ~= nil and shot_unlisten ~= nil) then
		shot_unlisten(self.mod.name or tostring(self));
	end

	if (self.unload ~= nil) then
		self.unload();
	end
end

-- The class is a global, like lib_shot_detect's API: effects load after
-- the libraries and find it there. Nothing to register as a module.
_G.PlayerEffect = PlayerEffect;
