-- rifle_is_a_rail_gun.lua -- Rifle shots pierce the whole map: every
-- block on the trajectory is destroyed (only the unbreakable
-- water-level floor survives, and even that doesn't stop the bullet)
-- and every enemy on the line dies in one hit, behind cover or not.
-- Shots leave a dashed tracer trail of blocks along the trajectory
-- that are destroyed right after being placed.
--
-- The trail blocks are send-only (never in the server map): built for
-- all clients on one tick, destroyed on a later one. The one-tick gap
-- matters: block actions are batched per client frame and a build and
-- destroy landing in the same frame get processed in the wrong order,
-- leaving phantom blocks.
local mod = init_mod();
require "lib_bulk_destroy";

getcfg("rig_range", 725);      -- max bullet travel: the full map diagonal
getcfg("rig_hit_radius", 0.8); -- how close the ray must pass to kill
getcfg("rig_trail_step", 3);   -- one dash every this many voxels
getcfg("rig_trail_range", 48); -- how far the dashes reach

-- trail voxels waiting to be destroyed: newborn were built during the
-- current tick, armed get their destroy broadcast on the next one
local newborn = {};
local armed = {};

-- when each player's last shot was animated, to dedup backup triggers
local lastanim = pid_connected_table(0);

-- when a real bullet of theirs last provably existed (block break or
-- player hit): the engine's mag estimate drains on *estimated* shots
-- and the estimator is sprint- and release-blind, so it can phantom
-- its way to an empty magazine while the real one is half full --
-- fresh evidence overrules it
local lastreal = pid_connected_table(0);

local function sign1(num)
	return num < 0 and -1 or 1;
end

-- one-shot kill everything on the trajectory, cover or not: demoncore
-- clips the body from 1.35 above pos to 2.25 below with a 0.45
-- half-width, so sample that span and call it a hit when the ray
-- passes within rig_hit_radius of any sample
local function rail_kill(pid, start, dir)
	local team = get_team(pid);

	for i in piditer(PID_BROADCAST_EXCEPT(pid)) do
		if (is_alive(i) and get_team(i) ~= team) then
			local p = get_position(i);

			for k=0,8 do
				local w = {x=p.x-start.x, y=p.y-start.y,
				           z=p.z-1.35+k*0.45-start.z};
				local t = w.x*dir.x + w.y*dir.y + w.z*dir.z;

				if (t > 0 and t < rig_range) then
					local ox = w.x - t*dir.x;
					local oy = w.y - t*dir.y;
					local oz = w.z - t*dir.z;

					if (ox*ox + oy*oy + oz*oz <=
					    rig_hit_radius*rig_hit_radius) then
						damage_player_directional(i, 255, start, 0, pid);
						break;
					end
				end
			end
		end
	end
end

local function shoot(pid)
	local start = get_position(pid);
	local dir = get_orientation(pid);
	local traversed = 0;

	lastanim[pid] = get_time();

	local step = {x=sign1(dir.x), y=sign1(dir.y), z=sign1(dir.z)};
	local delta = {x=math.abs(1/dir.x), y=math.abs(1/dir.y), z=math.abs(1/dir.z)};
	local vox = {x=math.floor(start.x), y=math.floor(start.y), z=math.floor(start.z)};
	local tmax = {
		x = (vox.x - start.x + math.max(step.x, 0))/dir.x,
		y = (vox.y - start.y + math.max(step.y, 0))/dir.y,
		z = (vox.z - start.z + math.max(step.z, 0))/dir.z,
	};

	-- each shot traces in a random shade of red
	send_set_block_color(PID_BROADCAST,
		{r=math.random(128, 255), g=0, b=0}, get_anon_pid());

	rail_kill(pid, start, dir);

	while (traversed < rig_range) do
		if (vox.x < 0 or vox.x > 511 or vox.y < 0 or vox.y > 511 or
		    vox.z < 0 or vox.z > 63) then
			break;
		end

		if (is_solid(vox)) then
			-- the water-level floor still can't be broken, but
			-- nothing stops the bullet anymore
			if (vox.z < 62) then
				bdestroy_block_action(vox, 1);
			end
		elseif (traversed >= 2 and traversed <= rig_trail_range
		        and traversed % rig_trail_step == 0) then
			-- dashed tracer: spaced-out voxels only, so no two trail
			-- blocks are ever face-adjacent -- destroying a connected
			-- run makes clients collapse the rest of it as one big
			-- falling structure (skips the shooter's face too). Every
			-- dash costs two reliable packets per player, so the
			-- spacing and reach also keep the per-shot packet burst
			-- small enough not to lag anyone
			local p = {x=vox.x, y=vox.y, z=vox.z};
			send_block_action(PID_BROADCAST, p, 0, get_anon_pid());
			table.insert(newborn, p);
		end

		if (tmax.z <= tmax.x and tmax.z <= tmax.y) then
			vox.z = vox.z + step.z;
			tmax.z = tmax.z + delta.z;
		elseif (tmax.x < tmax.y) then
			vox.x = vox.x + step.x;
			tmax.x = tmax.x + delta.x;
		else
			vox.y = vox.y + step.y;
			tmax.y = tmax.y + delta.y;
		end
		traversed = traversed + 1;
	end

	bdestroy_finish();
end

function mod.after.on_join(pid)
	server_msg(pid, "warning: here rifles are railguns.");
end

function mod.tick()
	mod.next.tick();

	for _,p in ipairs(armed) do
		send_block_action(PID_BROADCAST, p, 1, get_anon_pid());
	end
	armed = newborn;
	newborn = {};
end

-- the server estimates gun cycling from the held inputs (rifle 0.5s,
-- smg 0.1s, shotgun 1s) and calls this per estimated shot, so holding
-- the trigger keeps firing -- clients send nothing while held
function mod.after.before_estimated_fire(pid)
	if (not is_alive(pid) or get_gun(pid) ~= 0) then
		return;
	end
	if (get_mag_ammo(pid) == 0 and get_time() - lastreal[pid] > 1.5) then
		return; -- estimated empty and no recent proof to the contrary
	end

	shoot(pid);
end

-- backup triggers: the estimator is armed only by mouse-input packets
-- and clients suppress those around sprinting and toolswitching, so
-- shots fired while moving can be invisible to it -- but the bullet's
-- effects (a block break, a player hit) still arrive; animate from
-- those unless this shot was already animated
local function real_bullet(pid)
	if (not is_alive(pid) or get_tool(pid) ~= 2 or get_gun(pid) ~= 0) then
		return;
	end

	lastreal[pid] = get_time();
	if (get_time() - lastanim[pid] > 0.35) then
		shoot(pid);
	end
end

function mod.after.on_block_action(pid, pos, type)
	if (type == 1) then
		real_bullet(pid);
	end
end

function mod.after.on_hit(pid, type, hitPlayer)
	real_bullet(pid);
end

return mod;
