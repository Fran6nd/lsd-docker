-- medkit.lua -- Use /m for morphine, as a player effect
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Upstream LSd's medkit (lsd/scripts/medkit.lua), which this replaces
-- under the same name and the same id: medkit_quantity kits a life,
-- each giving back medkit_heal health, restocked at the tent. What
-- changes is who has one -- it is a PlayerEffect now, so everybody does
-- while medkit_everyone (the default, upstream's behaviour), and a
-- gamemode can give it to some players only, or set it off itself:
--
--   PlayerEffect.get("medkit"):trigger(pid)               -- uses a kit
--   PlayerEffect.get("medkit"):trigger(pid, {free = true, amount = 60})
--        -> the health given, or nil when nothing was (and why is said)
--
-- /m and /medkit are the player setting it off, for a player who has it.
-- It never fires by itself: medkit_every defaults to 0.

local use; -- below

local fx = PlayerEffect {
	name = "medkit",
	warning = {en = "Type /m to use a medkit."},
	tip = {en = "Hurt? Type /m to use a medkit; restock at your tent."},
	every = 0,
	trigger = function(pid, opts)
		return use(pid, opts);
	end,
};
local mod = fx.mod;

getcfg("medkit_heal", 40);
getcfg("medkit_quantity", 1);

local FULL = 100;

-- upstream's words, so their translations carry over
local dead_msg = {
	en = "The medkit cannot bring you back from the dead."
};
local none_left_msg = {
	en = "You've already used all your medkits! Restock at the tent."
};
local full_hp_msg = {
	en = "The medkit only heals physical wounds."
};

-- pid -> kits left this life
local kits = pid_connected_table();

function use(pid, opts)
	local free = opts.free == true;
	local left = kits[pid] or medkit_quantity;

	if (not free and left <= 0) then
		l10n_send_chat(pid, none_left_msg);
		return nil;
	end

	local hp = get_hp(pid);
	if (hp >= FULL) then
		l10n_send_chat(pid, full_hp_msg);
		return nil;
	end

	local gain = math.min(tonumber(opts.amount) or medkit_heal, FULL - hp);
	if (not free) then
		kits[pid] = left - 1;
	end
	-- negative damage from themselves: a heal, as area_heal deals one
	damage_player(pid, -gain, 0, pid);
	return gain;
end

function mod.after.spawn_player(pid)
	kits[pid] = medkit_quantity;
end

function mod.after.restock(pid)
	kits[pid] = medkit_quantity;
end

local cmd = {name = {"medkit", "m"}, desc = "Use a medkit."};
function cmd.func(pid)
	if (not fx:has(pid)) then
		l10n_send_chat(pid, {en = "You have no medkit here."});
		return;
	end
	if (not is_alive(pid)) then
		l10n_send_chat(pid, dead_msg);
		return;
	end
	fx:trigger(pid);
end
register_command(cmd, mod);

return mod;
