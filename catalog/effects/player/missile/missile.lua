-- missile.lua -- A rocket steered by its sender's aim, in real time
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- trigger(pid, opts) launches one from the sender's eye. Every tick it
-- turns to fly straight at the block under the sender's crosshair, as a
-- laser-guided missile follows its designator: look somewhere else and
-- it goes there, round a corner, over a wall, onto someone running.
-- Slower than a rocket (missile_speed), so it can be flown. When the
-- sender dies, leaves, or aims at the open sky, it flies straight on.
--
-- The flight, the trail of blocks and the explosion are lib_blast's,
-- the rocket's own: a direct hit, or anyone within missile_kill_radius
-- of the impact, is killed outright, and the blast falls off beyond.
-- Its crater, like every effect's, breaks nothing a gamemode protects.

local launch; -- below

local fx = PlayerEffect {
	name = "missile",
	warning = {en = "warning: here missiles follow their sender's aim."},
	tip = {en = "Spicy: a guided missile goes where you look -- keep your eye on the target."},
	trigger = function(pid, opts)
		return launch(pid, opts);
	end,
	unload = function()
		if (blast_clear ~= nil) then
			blast_clear();
		end
	end,
};
local mod = fx.mod;

getcfg("missile_speed", 1.2, "Blocks a missile flies each tick; slower is easier to steer.");
getcfg("missile_range", 400, "Blocks a missile flies before it is gone.");
getcfg("missile_radius", 3, "Blocks of terrain destroyed around the impact; damage reaches twice as far.");
getcfg("missile_damage", 90, "Damage at the centre of the explosion, falling off with distance.");
getcfg("missile_kill_radius", 2, "Blocks from the impact within which a missile kills outright; a direct hit always does.");

function launch(pid, opts)
	local pos = get_position(pid);
	local dir = get_orientation(pid);
	-- a pie wedge's %h: start off toward that point
	local t = opts.pos;
	if (t ~= nil and tonumber(t.x) and tonumber(t.y) and tonumber(t.z)) then
		local dx, dy, dz = t.x - pos.x, t.y - pos.y, t.z - pos.z;
		local len = math.sqrt(dx*dx + dy*dy + dz*dz);
		if (len > 0.01) then
			dir = {x = dx / len, y = dy / len, z = dz / len};
		end
	end
	return blast_fire(pid, pos, dir, {
		speed = tonumber(opts.speed) or missile_speed,
		range = tonumber(opts.range) or missile_range,
		radius = tonumber(opts.radius) or missile_radius,
		damage = tonumber(opts.damage) or missile_damage,
		kill_radius = tonumber(opts.kill_radius) or missile_kill_radius,
		hostile = function(a, b) return fx:hostile(a, b); end,
		-- the designator: wherever its sender looks, while they can
		guide = function()
			if (is_connected(pid) and is_alive(pid)) then
				return blast_aim(pid);
			end
		end,
	});
end

return mod;
