-- rifle_is_a_rail_gun.lua -- Rifle shots pierce the whole map
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Every block on the trajectory is destroyed (only the unbreakable
-- water-level floor survives, and even that doesn't stop the bullet)
-- and every enemy on the line dies in one hit, behind cover or not --
-- whether the server's ray found them or the client's own hit report
-- did, and never twice for the one shot (see on_hit).
-- Shots leave a dashed tracer trail of blocks along the trajectory
-- that are destroyed right after being placed, colored with the
-- shooter's team color.
--
-- The trail blocks are send-only (never in the server map): built for
-- all clients on one tick, destroyed on a later one. The one-tick gap
-- matters: block actions are batched per client frame and a build and
-- destroy landing in the same frame get processed in the wrong order,
-- leaving phantom blocks.
--
-- Knowing that a shot happened at all is lib_shot_detect's job, not this one's
-- -- it is the same problem the shotgun script has, and it is harder
-- than it looks. Load lib_shot_detect before this.
local mod = init_mod();
require "lib_bulk_destroy";

getcfg("rig_range", 727);      -- max bullet travel: the map's space
                               -- diagonal, ceil sqrt(512^2+512^2+64^2)
getcfg("rig_hit_radius", 0.8); -- how close the ray must pass to kill
getcfg("rig_trail_step", 3);   -- one dash every this many voxels; with
                               -- the trail now spanning the whole map
                               -- this also caps the per-shot packet
                               -- burst -- widen it (5-6) if a full
                               -- server lags
getcfg("rig_trail_range", rig_range); -- how far the dashes reach (whole map)
getcfg("rig_trail_life", 6);   -- ticks a dash stays up before destroy
                               -- (~100ms at 60Hz, to ride out jitter)

-- HitType as the client reports it (apidoc/src/get_defaults:13-20), and
-- the tool and gun this script is about
local HIT_HEAD = 1;
local HIT_SPADE = 4;
local TOOL_GUN = 2;
local GUN_RIFLE = 0;

-- trail voxels waiting to be destroyed. one tick (~17ms at 60Hz) is
-- shorter than a client's render frame, so a build and its destroy
-- coalesce into the same frame and the dash never draws -- keep each
-- generation up for rig_trail_life ticks so it reliably straddles
-- several frames. newborn collects the current tick's dashes; pending
-- is a FIFO of past generations, oldest first, destroyed once aged out
local newborn = {};
local pending = {};

local function sign1(num)
	return num < 0 and -1 or 1;
end

-- Everyone the current shot has already taken. Two sources decide who
-- the rail went through -- the server's ray and the client's own hit
-- report -- and this is what keeps them from both killing the same
-- person: whoever is in here has been dealt with, and the second source
-- to arrive says nothing new about them. Reset at the top of every shot,
-- so it only ever holds the one in flight.
local struck = pid_spawn_table();

-- Take one target off the rail: instant, whichever source named them,
-- and at most once each. Answers whether this call was the one that did
-- it, so a caller can tell a fresh kill from a duplicate.
local function rail_take(pid, target, start, ktype)
	local set = struck[pid];

	if (set == nil) then
		set = {};
		struck[pid] = set;
	end
	if (set[target] or not is_alive(target)) then
		return false;
	end

	set[target] = true;
	damage_player_directional(target, 255, start, ktype, pid);
	return true;
end

-- one-shot kill everything on the trajectory, cover or not: demoncore
-- clips the body from 1.35 above pos to 2.25 below with a 0.45
-- half-width, so sample that span and call it a hit when the ray
-- passes within rig_hit_radius of any sample
local function rail_kill(pid, team, start, dir)
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
						rail_take(pid, i, start, 0);
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
	local team = get_team(pid);
	local traversed = 0;

	-- a new shot owes nothing to the last one
	struck[pid] = {};

	local step = {x=sign1(dir.x), y=sign1(dir.y), z=sign1(dir.z)};
	local delta = {x=math.abs(1/dir.x), y=math.abs(1/dir.y), z=math.abs(1/dir.z)};
	local vox = {x=math.floor(start.x), y=math.floor(start.y), z=math.floor(start.z)};
	local tmax = {
		x = (vox.x - start.x + math.max(step.x, 0))/dir.x,
		y = (vox.y - start.y + math.max(step.y, 0))/dir.y,
		z = (vox.z - start.z + math.max(step.z, 0))/dir.z,
	};

	-- the trail wears the shooter's team color, so a ray tells you at a
	-- glance who fired it. set here, right before this shot's dashes go
	-- out: the color applies to every following block_action from the
	-- anonymous pid, so two shots in the same tick each keep their own
	send_set_block_color(PID_BROADCAST, get_team_color(team), get_anon_pid());

	rail_kill(pid, team, start, dir);

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
			-- dash costs two reliable packets per player; now that the
			-- reach spans the whole map, rig_trail_step spacing is the
			-- only thing keeping the per-shot packet burst in check --
			-- widen it if a full server starts to lag
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

-- THE SECOND SOURCE. The server's ray is not the only word on who the
-- rail went through, and it is not even the better-informed one. The
-- client ran its own hit detection against the positions it had at the
-- instant it fired; the ray runs here, a round trip later, against
-- positions that have moved since. So it misses people the client hit:
-- someone who has stepped away, someone the ray grazed by a hair more
-- than rig_hit_radius, someone the shooter led correctly and the server
-- has not caught up with. A rail that visibly goes through a man and
-- leaves him standing is the complaint this answers.
--
-- So a reported hit kills too -- and exactly once. rail_take is the one
-- door: the ray put everyone it took into this shot's set, and a report
-- naming one of them is a second account of the same event, not a second
-- event. Whichever source arrives first does the killing and the other
-- finds the name already there.
--
-- The order is not left to chance either. lib_shot_detect watches hits
-- from the xearly chain, so a hit that is the first news of a shot has
-- already credited it -- running the ray, filling the set -- before this
-- std hook is reached with the same packet.
--
-- Chaining is skipped once we have acted: the engine's own on_hit would
-- add a rifle's ordinary damage on top of a body the rail has already
-- taken. Everything we do not act on is passed along untouched --
-- spade hits, teammates, and anyone not holding a rifle.
function mod.on_hit(pid, type, hitPlayer)
	if (type ~= HIT_SPADE and is_alive(pid)
	    and get_tool(pid) == TOOL_GUN and get_gun(pid) == GUN_RIFLE
	    and get_team(pid) ~= get_team(hitPlayer)) then
		-- a headshot stays a headshot in the feed; everything else the
		-- rail does is a gun kill
		rail_take(pid, hitPlayer, get_position(pid),
			type == HIT_HEAD and 1 or 0);
		return;
	end

	mod.next.on_hit(pid, type, hitPlayer);
end

function mod.tick()
	mod.next.tick();

	-- this tick's dashes were built during mod.next.tick(); queue them
	-- and advance the FIFO by one tick (an empty generation still ages
	-- the queue, so lifetime is measured in ticks, not shots)
	table.insert(pending, newborn);
	newborn = {};

	-- destroy the generation that has now been up rig_trail_life ticks
	if (#pending > rig_trail_life) then
		for _,p in ipairs(table.remove(pending, 1)) do
			send_block_action(PID_BROADCAST, p, 1, get_anon_pid());
		end
	end
end

-- One railgun shot per bullet, whoever worked out that there was one.
-- rig_range and the rest still apply; all that has moved out is the
-- question of when.
function mod.on_load()
	if (shot_listen == nil) then
		error("rifle_is_a_rail_gun needs lib_shot_detect loaded first "
			.."(config.lua loads it, or: lsdctl load lib_shot_detect rifle_is_a_rail_gun)", 0);
	end

	shot_listen("rifle_is_a_rail_gun", function(pid, gun)
		if (gun == 0) then
			shoot(pid);
		end
	end);
end

function mod.on_unload()
	if (shot_unlisten ~= nil) then
		shot_unlisten("rifle_is_a_rail_gun");
	end
end

return mod;
