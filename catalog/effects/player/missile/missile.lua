-- missile.lua -- A rocket steered by its sender's aim, in real time
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- trigger(pid, opts) launches one from the sender's eye, and it goes
-- for the block under the sender's crosshair as a top-attack missile
-- does (a Javelin): it pops up, cruises missile_loft blocks above the
-- higher of the two ends, and dives onto the target once it is within a
-- 45-degree cone below -- over walls and onto someone in cover. It
-- follows the aim live, every tick, in every phase: look somewhere else
-- and it goes there. Where there is no room above (either end near the
-- top of the map) it flies straight at the crosshair instead. Slower
-- than a rocket (missile_speed), so it can be flown. When the sender
-- dies, leaves, or aims at the open sky, it flies straight on.
--
-- Climbing first, nearly straight up, also takes it clear of what is
-- around the sender before it turns: launched low -- crouched, in a dip
-- -- it would otherwise meet the ground in front of their feet.
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
getcfg("missile_loft", 12, "Blocks above the higher of shooter and target a missile cruises at before it dives; 0 flies straight.");

local TOP = 1.5;      -- the highest a missile cruises: z 0 is the top of the map
local MIN_DROP = 4;   -- a dive needs at least this much height to be one

-- Where a missile heads this tick, for a target point under the
-- crosshair: up, then over, then down onto it. The phase is kept on the
-- blast: once diving it stays diving.
local function waypoint(b, launch, t)
	local cruise = math.max(TOP, math.min(launch.z, t.z) - (tonumber(missile_loft) or 0));
	if (b.diving or t.z - cruise < MIN_DROP) then
		return t; -- diving, or no room above: straight at it
	end
	local head = {x = b.vox.x + 0.5, y = b.vox.y + 0.5, z = b.vox.z + 0.5};
	local dx, dy = t.x - head.x, t.y - head.y;
	local h = math.sqrt(dx*dx + dy*dy);
	-- within the cone below: dive
	if (h <= t.z - head.z) then
		b.diving = true;
		return t;
	end
	-- not up yet: climb, nudged toward the target so it leans into the turn
	if (not b.climbed and head.z > cruise + 1.5) then
		local k = h > 0.01 and 2 / h or 0;
		return {x = head.x + dx * k, y = head.y + dy * k, z = cruise};
	end
	b.climbed = true;
	-- over: level, toward the point above the target
	return {x = t.x, y = t.y, z = cruise};
end

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
	-- top attack: it leaves upward, leaning a little toward the aim, so
	-- its very first cells are above the sender, not along the ground
	if ((tonumber(missile_loft) or 0) > 0 and pos.z - TOP >= MIN_DROP) then
		local h = math.sqrt(dir.x * dir.x + dir.y * dir.y);
		local lean = h > 0.01 and 0.3 / h or 0;
		local ux, uy, uz = dir.x * lean, dir.y * lean, -1;
		local len = math.sqrt(ux*ux + uy*uy + uz*uz);
		dir = {x = ux / len, y = uy / len, z = uz / len};
	end
	return blast_fire(pid, pos, dir, {
		speed = tonumber(opts.speed) or missile_speed,
		range = tonumber(opts.range) or missile_range,
		radius = tonumber(opts.radius) or missile_radius,
		damage = tonumber(opts.damage) or missile_damage,
		kill_radius = tonumber(opts.kill_radius) or missile_kill_radius,
		hostile = function(a, b) return fx:hostile(a, b); end,
		-- the designator: wherever its sender looks, while they can
		guide = function(b)
			if (is_connected(pid) and is_alive(pid)) then
				local t = blast_aim(pid);
				return t and waypoint(b, pos, t);
			end
		end,
	});
end

return mod;
