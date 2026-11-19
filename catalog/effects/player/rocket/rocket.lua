-- rocket.lua -- A rocket flies from the player's eye along their aim
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Fired, a rocket leaves the eye along the aim: a short streak of
-- fiery blocks moving a few blocks a tick, which explodes where it
-- meets the ground or a living enemy -- a hole in the map and damage
-- that falls away from the centre (lib_blast does the flying and the
-- blowing up; this is about who fires and what it costs). The shooter
-- feels a third of it, so a rocket at your own feet hurts and a
-- rocket across the map does not.
--
-- A gamemode, or the rewards, sets one off:
--
--   PlayerEffect.get("rocket"):trigger(pid)            -- one free rocket
--   PlayerEffect.get("rocket"):trigger(pid, {damage = 150, radius = 4})
--
-- or hands out charges, each one a shot of ANY gun:
--
--   rocket.everyone = false;
--   for i = 1, 3 do rocket:give(pid, {death = true, stack = true}); end
--
-- Every shot of the holder then fires a rocket instead of mattering,
-- and uses one charge; out of charges, the guns are guns again. While
-- rocket_everyone (the default) every shot of everybody is a rocket,
-- with no charges: a game of its own.
local fire; -- below
local fx;  -- the effect; its own load hook needs the name

fx = PlayerEffect {
	name = "rocket",
	warning = {en = "warning: here every shot fires a rocket."},
	tip = {en = "Spicy: every shot is a rocket -- keep your distance from your own blast."},
	trigger = function(pid, opts)
		return fire(pid, opts);
	end,
	load = function()
		if (shot_listen == nil) then
			error("rocket needs lib_shot_detect loaded first "
				.. "(its script pulls lib_shot_detect in; check with: lsdctl status)", 0);
		end
		-- any gun: the class's on_shot is one gun's
		shot_listen("rocket", function(pid, gun)
			if (fx:has(pid)) then
				fx.shot(pid);
			end
		end);
	end,
	unload = function()
		if (shot_unlisten ~= nil) then
			shot_unlisten("rocket");
		end
		if (blast_clear ~= nil) then
			blast_clear();
		end
	end,
};
local mod = fx.mod;

getcfg("rocket_speed", 2, "Blocks a rocket flies each tick.");
getcfg("rocket_radius", 3, "Blocks of terrain destroyed around the impact; damage reaches twice as far.");
getcfg("rocket_damage", 90, "Damage at the centre of an explosion, falling off with distance.");
getcfg("rocket_range", 150, "Blocks a rocket flies before it is gone.");
getcfg("rocket_kill_radius", 2, "Blocks from the impact within which a rocket kills outright; a direct hit always does.");
getcfg("rocket_gap", 0.5, "Seconds between two rockets from one player's shots.");

local last = pid_connected_table(0);

-- From the eye, along the aim -- or, given opts.pos (a pie wedge's %h,
-- the point under the crosshair), straight at that point.
function fire(pid, opts)
	local pos = get_position(pid);
	local dir = get_orientation(pid);
	-- a player under the crosshair first: the pie's %h is the client's
	-- point, which only ever lands on a block
	local a = blast_aim ~= nil and blast_aim(pid) or nil;
	local t = (a ~= nil and a.pid ~= nil) and a or opts.pos;
	if (t ~= nil and tonumber(t.x) and tonumber(t.y) and tonumber(t.z)) then
		local dx, dy, dz = t.x - pos.x, t.y - pos.y, t.z - pos.z;
		local len = math.sqrt(dx*dx + dy*dy + dz*dz);
		if (len > 0.01) then
			dir = {x = dx / len, y = dy / len, z = dz / len};
		end
	end
	return blast_fire(pid, pos, dir, {
		speed = tonumber(opts.speed) or rocket_speed,
		range = tonumber(opts.range) or rocket_range,
		radius = tonumber(opts.radius) or rocket_radius,
		damage = tonumber(opts.damage) or rocket_damage,
		kill_radius = tonumber(opts.kill_radius) or rocket_kill_radius,
		hostile = function(a, b) return fx:hostile(a, b); end,
	});
end

-- A shot of the holder: a charge buys a rocket, and so does everyone
-- having them. A shot inside the gap costs nothing and fires nothing,
-- so a submachine gun does not burn three charges in a third of a second.
function fx.shot(pid)
	if (not is_alive(pid)) then
		return;
	end
	local now = get_time();
	if (now - last[pid] < rocket_gap) then
		return;
	end

	if (fx:stacks(pid) > 0) then
		-- the oldest charge
		fx:take(pid, fx.grants[pid][1]);
	elseif (not fx.everyone) then
		return;
	end

	last[pid] = now;
	fx:trigger(pid);
end

return mod;
