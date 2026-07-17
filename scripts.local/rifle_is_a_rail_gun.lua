-- rifle_is_a_rail_gun.lua -- Rifle shots dig through any surface up
-- to 5 blocks deep, and leave a dashed tracer trail of blocks along
-- the trajectory that are destroyed right after being placed.
--
-- The trail blocks are send-only (never in the server map): built for
-- all clients on one tick, destroyed on a later one. The one-tick gap
-- matters: block actions are batched per client frame and a build and
-- destroy landing in the same frame get processed in the wrong order,
-- leaving phantom blocks.
local mod = init_mod();
require "lib_bulk_destroy";

getcfg("rig_depth", 5);   -- blocks a shot can chew through
getcfg("rig_range", 160); -- max bullet travel, in blocks

-- trail voxels waiting to be destroyed: newborn were built during the
-- current tick, armed get their destroy broadcast on the next one
local newborn = {};
local armed = {};

local function sign1(num)
	return num < 0 and -1 or 1;
end

local function shoot(pid)
	local start = get_position(pid);
	local dir = get_orientation(pid);
	local budget = rig_depth;
	local traversed = 0;

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

	while (traversed < rig_range) do
		if (vox.x < 0 or vox.x > 511 or vox.y < 0 or vox.y > 511 or
		    vox.z < 0 or vox.z > 63) then
			break;
		end

		if (is_solid(vox)) then
			-- ground at water level stays whole; the bullet just stops
			if (vox.z >= 62) then
				break;
			end

			-- chew through; count indestructible blocks against the
			-- budget too so the bullet can't tunnel forever
			bdestroy_block_action(vox, 1);
			budget = budget - 1;
			if (budget <= 0) then
				break;
			end
		elseif (traversed >= 2 and traversed % 2 == 0) then
			-- dashed tracer: every other voxel only, so no two trail
			-- blocks are ever face-adjacent -- destroying a connected
			-- run makes clients collapse the rest of it as one big
			-- falling structure (skips the shooter's face too)
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
	if (not is_alive(pid) or get_gun(pid) ~= 0 or get_mag_ammo(pid) == 0) then
		return;
	end

	shoot(pid);
end

return mod;
