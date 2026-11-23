-- grenade_launcher.lua -- A grenade that explodes on impact
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- trigger(pid, opts) fires a real grenade from the player's eye along
-- their aim, at grenade_launcher_speed (a full-strength throw is about
-- 1), and it explodes where they aimed: at the block under the
-- crosshair, up to grenade_launcher_range (40) blocks away -- or sooner,
-- the moment it hits something on the way. With nothing to aim at in
-- range, it goes off after that many blocks of flight.
--
-- THE FUSE IS THE FLIGHT. The client flies a grenade with the very
-- physics the server has (simulate_grenade_physics is pyspades' own,
-- as apoc.lua's get_impact_time uses it), so the flight is run here,
-- ahead of time, tick by tick: the grenade is fused for the moment it
-- comes nearest the aimed point (it arcs, so it may pass a little under
-- it), or the first bounce if that comes first. Every client sees it go
-- off there, and the server detonates it there at the same moment.
--
-- It is the engine's grenade, so it is the engine's explosion: the
-- blast, the sound, the damage (the owner's team spared, as for any
-- grenade), and its blocks broken through block_action as the owner --
-- the path every protection already guards (babel's towers included).
--
-- The shooter's own copy of the packet names the anonymous pid: a
-- client takes a grenade from its own stock when it is sent one naming
-- itself, and a launcher shot is not one of theirs (the grenade
-- shotgun does the same).

local launch; -- below

local fx = PlayerEffect {
	name = "grenade_launcher",
	warning = {en = "warning: here grenades are fired from a launcher and explode on impact."},
	tip = {en = "Spicy: a launched grenade goes off the moment it hits -- no bounce, no waiting."},
	trigger = function(pid, opts)
		return launch(pid, opts);
	end,
};
local mod = fx.mod;

getcfg("grenade_launcher_speed", 2, "Launch speed; a full-strength throw is about 1.");
getcfg("grenade_launcher_range", 40, "Blocks out to which a launched grenade goes off at the point aimed at.");
getcfg("grenade_launcher_max_fuse", 5, "Seconds a grenade flies at most before it explodes anyway.");

local STEP = 1/60; -- the client's grenade physics step, as apoc.lua's

local function dist(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z;
	return math.sqrt(dx*dx + dy*dy + dz*dz);
end

-- The fuse, by the client's own physics: the moment the flight comes
-- nearest `target`, or, with none, has carried `range` blocks -- or the
-- first bounce, if that comes first.
local function fuse_for(pos, vel, target, range)
	local start = pos;
	local limit = tonumber(grenade_launcher_max_fuse) or 5;
	local t, best_t, best_d = 0, 0, math.huge;
	while (t < limit) do
		local hit;
		pos, vel, hit = simulate_grenade_physics(pos, vel, STEP);
		if (hit) then
			break;
		end
		t = t + STEP;
		if (target ~= nil) then
			local d = dist(pos, target);
			if (d < best_d) then
				best_d, best_t = d, t;
			elseif (d > best_d + 1) then
				return best_t; -- past it, and going away
			end
		elseif (dist(pos, start) >= range) then
			return t;
		end
	end
	if (target ~= nil and best_d < math.huge) then
		return math.min(best_t, t);
	end
	return math.min(t, limit);
end

function launch(pid, opts)
	local eye = get_position(pid);
	local d = get_orientation(pid);
	local speed = tonumber(opts.speed) or grenade_launcher_speed;
	-- a block out from the eye, so it does not start inside the head
	local pos = {x = eye.x + d.x, y = eye.y + d.y, z = eye.z + d.z};
	local vel = {x = d.x * speed, y = d.y * speed, z = d.z * speed};
	local range = tonumber(grenade_launcher_range) or 40;
	local target = blast_aim ~= nil and blast_aim(pid, range) or nil;
	local fuse = fuse_for({x = pos.x, y = pos.y, z = pos.z}, {x = vel.x, y = vel.y, z = vel.z},
		target, range);

	register_grenade(pid, get_team(pid), pos, vel, fuse);
	send_grenade(PID_BROADCAST_EXCEPT(pid), pos, vel, fuse, pid);
	send_grenade(pid, pos, vel, fuse, get_anon_pid());
	return fuse;
end

return mod;
