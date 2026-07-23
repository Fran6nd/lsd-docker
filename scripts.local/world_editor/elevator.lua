-- world_editor/elevator.lua -- A rising platform.
--
-- Placement: /place elevator up|down [perm]
--   mark 1 -- spade the block that is the platform's centre; the
--             platform is a filled disc of radius `r` around it
--   mark 2 -- spade a block at the altitude to travel to
--
-- Direction is where the platform *goes* when someone stands on it, so
-- it rests at the opposite end: "up" waits at the bottom, "down" waits
-- at the top. Once the rider steps off it returns to that resting end
-- on its own, ready for the next person.
--
-- Riders are carried by teleport rather than by block physics: the
-- platform is only redrawn a layer at a time, and a player standing on
-- a block that vanishes and reappears one layer along would stutter or
-- fall through. Moving them by the same delta keeps the ride smooth.
--
-- Remember the map's z axis points *down* -- z=0 is sky, z=63 is floor
-- -- so travelling "up" means stepping z towards the smaller value.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local E = {name = "elevator"};

local areas = require "world_editor.areas";

getcfg("we_elevator_radius", 5);   -- platform radius, in blocks
getcfg("we_elevator_speed", 6);    -- blocks per second
getcfg("we_elevator_wait", 1.0);   -- seconds held at the far end

-- default platform colour; /place elevator ... <colour> overrides it
local RED = {r=255, g=32, b=32};

local function tint(inst)
	return inst.color or RED;
end

-- ------------------------------------------------------------ placement

function E.start(pid, dir)
	dir = string.lower(dir or "up");
	if (dir ~= "up" and dir ~= "down") then
		return nil, "direction must be up or down.";
	end
	return {dir=dir, pts={}, data=nil,
	        prompt="spade the platform centre."};
end

function E.click(s, pos)
	table.insert(s.pts, {x=pos.x, y=pos.y, z=pos.z});

	if (#s.pts == 1) then
		s.prompt = "now spade a block at the altitude to travel to.";
		return false;
	end

	local a, b = s.pts[1], s.pts[2];
	if (a.z == b.z) then
		s.pts = {a};
		return false, "that is the same altitude -- pick a different height.";
	end

	s.data = {
		x = a.x, y = a.y,
		zlo = math.min(a.z, b.z),   -- smaller z == higher up
		zhi = math.max(a.z, b.z),
		dir = s.dir,
		r   = we_elevator_radius,
	};
	return true;
end

-- ------------------------------------------------------------- lifecycle

local function rest_z(inst)
	-- "up" waits down at the floor end (larger z)
	if (inst.dir == "up") then return inst.zhi; end
	return inst.zlo;
end

local function goal_z(inst)
	if (inst.dir == "up") then return inst.zlo; end
	return inst.zhi;
end

function E.spawn(d)
	local inst = {
		x=d.x, y=d.y, zlo=d.zlo, zhi=d.zhi,
		dir=d.dir, r=d.r or we_elevator_radius,
	};
	inst.z = rest_z(inst);      -- current platform layer
	inst.state = "rest";        -- rest | going | holding | returning
	inst.t = 0;                 -- seconds accumulated for the next step
	inst.hold = 0;
	return inst;
end

function E.save(inst)
	return {x=inst.x, y=inst.y, zlo=inst.zlo, zhi=inst.zhi,
	        dir=inst.dir, r=inst.r};
end

function E.render(inst, we)
	we.disc(inst, inst.x, inst.y, inst.z, inst.r, tint(inst), true);
end

function E.destroy(inst, we)
	we.disc(inst, inst.x, inst.y, inst.z, inst.r, nil, false);
end

-- ---------------------------------------------------------------- trigger

-- The trigger is a short cylinder sitting directly on top of the
-- platform: same footprint, a few blocks of headroom. It slides with
-- the platform so riders keep triggering it the whole way.
local function rider_area(inst)
	return areas.cylinder(inst.x, inst.y, inst.r, inst.z - 4, inst.z);
end

local function riders(inst)
	return areas.players_in(rider_area(inst));
end

-- ------------------------------------------------------------------ tick

local function step(inst, we, dz)
	local from = inst.z;
	local to = from + dz;

	-- carry anyone aboard before the floor moves out from under them
	local aboard = riders(inst);

	we.disc(inst, inst.x, inst.y, from, inst.r, nil, false);
	inst.z = to;
	we.disc(inst, inst.x, inst.y, to, inst.r, tint(inst), true);

	for _, pid in ipairs(aboard) do
		local p = get_position(pid);
		set_position(pid, {x=p.x, y=p.y, z=p.z + dz});
	end
end

function E.tick(inst, we)
	local dt = 1/60;
	local goal = goal_z(inst);
	local rest = rest_z(inst);

	if (inst.state == "rest") then
		if (inst.z ~= rest) then
			inst.state = "returning";
		elseif (#riders(inst) > 0) then
			inst.state = "going";
			inst.t = 0;
		end
		return;
	end

	if (inst.state == "holding") then
		inst.hold = inst.hold - dt;
		-- don't drop out from under someone still standing there
		if (inst.hold <= 0 and #riders(inst) == 0) then
			inst.state = "returning";
			inst.t = 0;
		end
		return;
	end

	local target = (inst.state == "going") and goal or rest;
	if (inst.z == target) then
		if (inst.state == "going") then
			inst.state = "holding";
			inst.hold = we_elevator_wait;
		else
			inst.state = "rest";
		end
		return;
	end

	inst.t = inst.t + dt;
	local period = 1 / math.max(we_elevator_speed, 0.1);
	if (inst.t < period) then
		return;
	end
	inst.t = inst.t - period;

	step(inst, we, (target < inst.z) and -1 or 1);
end

return E;
