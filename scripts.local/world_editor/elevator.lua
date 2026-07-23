-- world_editor/elevator.lua -- A rising platform.
--
-- Placement: /place elevator <rect|square> <up|down>
--   mark 1 -- one corner of the platform footprint
--   mark 2 -- the opposite corner (square snaps it to equal sides)
--   mark 3 -- a block at the altitude to travel to
--
-- The footprint is the rectangle between marks 1 and 2, resting at their
-- level; mark 3 gives the far altitude. Direction is where the platform
-- *goes* when someone stands on it, so it rests at the opposite end:
-- "up" waits at the bottom, "down" waits at the top. Once the rider
-- steps off it returns to that resting end on its own.
--
-- Riders are carried by teleport rather than by block physics: the
-- platform is only redrawn a layer at a time, and a player standing on
-- a block that vanishes and reappears one layer along would stutter or
-- fall through. Moving them by the same delta keeps the ride smooth.
--
-- The whole shaft the platform sweeps -- plus rider headroom -- is
-- reserved, so no one can wall the platform in or block its path.
--
-- Colour comes from the placer's block palette. The map's z axis points
-- *down* (z=0 sky, z=63 floor), so travelling "up" steps z downward.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local E = {name = "elevator"};

local areas = require "world_editor.areas";

getcfg("we_elevator_speed", 6);    -- blocks per second
getcfg("we_elevator_wait", 1.0);   -- seconds held at the far end
getcfg("we_elevator_headroom", 3); -- rider headroom reserved above the top

local RED = {r=255, g=32, b=32};   -- fallback if the palette read fails

local function tint(inst)
	return inst.color or RED;
end

E.desc  = "a platform that lifts riders between two altitudes.";
E.usage = "<rect|square> <up|down>";
E.help  = {
	"world_editor: elevator -- a platform that carries riders up or down.",
	"  usage: /place elevator <rect|square> <up|down>",
	"  up rests at the bottom and rises when stood on; down is the reverse.",
	"  then mark two footprint corners and one altitude (spade, or /here).",
	"  colour is taken from your current block palette.",
};

-- ------------------------------------------------------------ placement

function E.start(pid, args)
	local shape = string.lower(args[1] or "");
	local dir   = string.lower(args[2] or "");
	if (shape ~= "rect" and shape ~= "square") then
		return nil, "shape must be rect or square.";
	end
	if (dir ~= "up" and dir ~= "down") then
		return nil, "direction must be up or down.";
	end
	return {shape=shape, dir=dir, pts={}, data=nil,
	        prompt="mark one corner of the platform."};
end

function E.click(s, pos)
	table.insert(s.pts, {x=pos.x, y=pos.y, z=pos.z});

	if (#s.pts == 1) then
		s.prompt = "now mark the opposite corner.";
		return false;
	end
	if (#s.pts == 2) then
		s.prompt = "now mark a block at the altitude to travel to.";
		return false;
	end

	local a, b, c = s.pts[1], s.pts[2], s.pts[3];

	local x1, y1 = math.min(a.x, b.x), math.min(a.y, b.y);
	local x2, y2 = math.max(a.x, b.x), math.max(a.y, b.y);

	-- square: grow the shorter side to match the longer, anchored at the
	-- low corner, so both dimensions end up equal
	if (s.shape == "square") then
		local side = math.max(x2 - x1, y2 - y1);
		x2, y2 = x1 + side, y1 + side;
	end

	local base = a.z;
	if (base == c.z) then
		s.pts = {a, b};
		return false, "that altitude is the platform's own level -- pick a different height.";
	end

	s.data = {
		x1=x1, y1=y1, x2=x2, y2=y2,
		zlo=math.min(base, c.z),   -- smaller z == higher up
		zhi=math.max(base, c.z),
		dir=s.dir,
	};
	return true;
end

-- ------------------------------------------------------------- lifecycle

local function rest_z(inst)
	if (inst.dir == "up") then return inst.zhi; end  -- wait low (large z)
	return inst.zlo;
end

local function goal_z(inst)
	if (inst.dir == "up") then return inst.zlo; end
	return inst.zhi;
end

function E.spawn(d)
	local inst = {
		x1=d.x1, y1=d.y1, x2=d.x2, y2=d.y2,
		zlo=d.zlo, zhi=d.zhi, dir=d.dir,
	};
	-- centre, kept for /componentperm's nearest-component search
	inst.x = math.floor((d.x1 + d.x2) / 2);
	inst.y = math.floor((d.y1 + d.y2) / 2);
	inst.z = rest_z(inst);      -- current platform layer
	inst.state = "rest";        -- rest | going | holding | returning
	inst.t = 0;
	inst.hold = 0;
	return inst;
end

function E.save(inst)
	return {x1=inst.x1, y1=inst.y1, x2=inst.x2, y2=inst.y2,
	        zlo=inst.zlo, zhi=inst.zhi, dir=inst.dir};
end

function E.render(inst, we)
	we.rect(inst, inst.x1, inst.y1, inst.x2, inst.y2, inst.z, tint(inst), true);
end

function E.destroy(inst, we)
	we.rect(inst, inst.x1, inst.y1, inst.x2, inst.y2, inst.z, nil, false);
end

-- the full column the platform sweeps, plus headroom above the topmost
-- stop, so nobody can build in the shaft or over the exit
function E.reserved(inst)
	return areas.box(inst.x1, inst.y1, inst.zlo - we_elevator_headroom,
	                 inst.x2, inst.y2, inst.zhi);
end

-- ---------------------------------------------------------------- trigger

-- a box on top of the platform footprint with a few blocks of headroom,
-- sliding with the platform so riders keep triggering the whole way
local function rider_area(inst)
	return areas.box(inst.x1, inst.y1, inst.z - 4,
	                 inst.x2, inst.y2, inst.z);
end

local function riders(inst)
	return areas.players_in(rider_area(inst));
end

-- ------------------------------------------------------------------ tick

local function step(inst, we, dz)
	local from = inst.z;
	local to = from + dz;

	local aboard = riders(inst);  -- carry them before the floor moves

	we.rect(inst, inst.x1, inst.y1, inst.x2, inst.y2, from, nil, false);
	inst.z = to;
	we.rect(inst, inst.x1, inst.y1, inst.x2, inst.y2, to, tint(inst), true);

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
