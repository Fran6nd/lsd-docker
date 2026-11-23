-- area_hurt.lua -- Hurt the enemies near a player
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- When triggered for a player, every living enemy within the radius
-- takes damage, dealt as that player: a kill is theirs, and they see
-- each hit float over the one hit (the Damage Markers extension, where
-- their client speaks it -- damage_player is what it watches). Through
-- walls: the radius is the whole rule.
--
-- "Enemy" is PlayerEffect:hostile's, so the_fall's disguised bots count.
--
-- A gamemode sets it off when it decides:
--
--   PlayerEffect.get("area_hurt"):trigger(pid, {radius = 6, amount = 40})
--        -> how many enemies were hit
--
-- On its own it fires every area_hurt_every seconds for each live
-- player who has it -- everybody, unless area_hurt_everyone = False.

local hurt; -- below, once fx is there to ask who is hostile

local fx = PlayerEffect {
	name = "area_hurt",
	warning = {en = "warning: here standing near an enemy hurts them, and them you."},
	tip = {en = "Keep your distance: enemies near you wear you down."},
	every = 2,
	trigger = function(pid, opts)
		return hurt(pid, opts);
	end,
};
local mod = fx.mod;

getcfg("area_hurt_radius", 6);   -- blocks around the player
getcfg("area_hurt_amount", 5);   -- damage dealt each time

local KILL_GUN = 0; -- KillType, protocol.h: credited as a plain kill

function hurt(pid, opts)
	local radius = tonumber(opts.radius) or area_hurt_radius;
	local amount = tonumber(opts.amount) or area_hurt_amount;
	local hit = 0;

	for i in piditer(PID_BROADCAST) do
		if (i ~= pid and is_alive(i) and fx:hostile(pid, i)
		    and PlayerEffect.distance(pid, i) <= radius) then
			damage_player(i, amount, KILL_GUN, pid);
			hit = hit + 1;
		end
	end

	return hit;
end

return mod;
