-- area_heal.lua -- Heal the teammates near a player
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- When triggered for a player, every living teammate within the radius
-- -- not the player themselves -- gets health back, up to full: area_hurt
-- turned round. The heal is dealt the same way, as negative damage from
-- the healer, so the healer sees it float over each one healed as a
-- heal (the Damage Markers extension, where their client speaks it,
-- draws a negative amount as one) -- with no marker code of its own.
--
-- A gamemode sets it off when it decides:
--
--   PlayerEffect.get("area_heal"):trigger(pid, {radius = 10, amount = 30})
--        -> how many teammates were healed
--
-- On its own it fires every area_heal_every seconds for each live
-- player who has it -- everybody, unless area_heal_everyone = False.

local heal; -- below, once fx is there to ask who is hostile

local fx = PlayerEffect {
	name = "area_heal",
	warning = {en = "warning: here teammates near each other heal one another."},
	tip = {en = "Stick together: teammates near you heal you over time."},
	every = 2,
	trigger = function(pid, opts)
		return heal(pid, opts);
	end,
};
local mod = fx.mod;

getcfg("area_heal_radius", 8);   -- blocks around the healer
getcfg("area_heal_amount", 5);   -- health given each time, up to 100

local FULL = 100;
local KILL_GUN = 0; -- KillType; never used, health only goes up

function heal(pid, opts)
	local radius = tonumber(opts.radius) or area_heal_radius;
	local amount = tonumber(opts.amount) or area_heal_amount;
	local healed = 0;

	for i in piditer(PID_BROADCAST) do
		if (i ~= pid and is_alive(i) and not fx:hostile(pid, i)
		    and PlayerEffect.distance(pid, i) <= radius) then
			-- never past full: LSd's damage_player does not cap a
			-- negative amount (main.c set_hp clamps at 0 only)
			local gain = math.min(amount, FULL - get_hp(i));
			if (gain > 0) then
				damage_player(i, -gain, KILL_GUN, pid);
				healed = healed + 1;
			elseif (damage_markers_show ~= nil) then
				-- already full: nothing to give, but the healer still sees
				-- the heal float over them -- what it would give someone
				-- with nothing left -- so the effect shows it is working
				damage_markers_show(pid, i, -math.min(amount, FULL));
			end
		end
	end

	return healed;
end

return mod;
