-- grenade_launcher.lua -- A grenade that explodes on impact
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- trigger(pid, opts) fires a real grenade from the player's eye along
-- their aim, at grenade_launcher_speed (a full-strength throw is about
-- 1), and it explodes the moment it hits something.
--
-- THE FUSE IS THE FLIGHT. The client flies a grenade with the very
-- physics the server has (simulate_grenade_physics is pyspades' own,
-- as apoc.lua's get_impact_time uses it), so the flight is run here,
-- ahead of time, tick by tick until the first bounce, and the grenade
-- is fused for exactly that long: every client sees it explode where it
-- lands, and the server detonates it there at the same moment.
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
getcfg("grenade_launcher_max_fuse", 5, "Seconds a grenade that hits nothing flies before it explodes anyway.");

local STEP = 1/60; -- the client's grenade physics step, as apoc.lua's

-- Seconds until the first bounce, by the client's own physics.
local function impact_time(pos, vel)
	local t, hit = 0, false;
	local limit = tonumber(grenade_launcher_max_fuse) or 5;
	while (t < limit) do
		pos, vel, hit = simulate_grenade_physics(pos, vel, STEP);
		if (hit) then
			break;
		end
		t = t + STEP;
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
	local fuse = impact_time({x = pos.x, y = pos.y, z = pos.z}, {x = vel.x, y = vel.y, z = vel.z});

	register_grenade(pid, get_team(pid), pos, vel, fuse);
	send_grenade(PID_BROADCAST_EXCEPT(pid), pos, vel, fuse, pid);
	send_grenade(pid, pos, vel, fuse, get_anon_pid());
	return fuse;
end

return mod;
