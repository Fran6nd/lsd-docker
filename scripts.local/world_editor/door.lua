-- world_editor/door.lua -- A plane that retracts to open.
--
-- Placement: /place door up|down|left|right [perm] [colour]
--   mark 1 -- one corner of the door plane
--   mark 2 -- the opposite corner
--
-- Direction is the way the panel retracts:
--   up     pulls it into the ceiling  (gap grows from the floor)
--   down   sinks it into the floor    (gap grows from the top)
--   left   slides it to the low side  (gap grows from the low side)
--   right  slides it to the high side (gap grows from the high side)
--
-- up/down retract along z; left/right retract along whichever
-- horizontal axis the door is widest on, so a door laid out along x
-- slides in x and one laid out along y slides in y. Closing runs the
-- same animation backwards.
--
-- It opens while anyone stands near it and closes once they leave, so a
-- door needs no switch -- walking up to it is the trigger.
--
-- The motion is deliberately incremental: exactly one slice is added or
-- removed per step, never the whole panel at once, both so it reads as
-- a moving door and so a big door can't dump hundreds of block updates
-- into a single tick.
--
-- The map's z axis points *down*: z1 is the top row, z2 the bottom.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local D = {name = "door"};

local areas = require "world_editor.areas";

getcfg("we_door_speed", 8);     -- slices opened/closed per second
getcfg("we_door_range", 4);     -- how close a player must be, in blocks

-- default panel colour; /place door ... <colour> overrides it
local GREY = {r=170, g=170, b=185};

local function tint(inst)
	return inst.color or GREY;
end

local DIRS = {up=true, down=true, left=true, right=true};

-- ------------------------------------------------------------ placement

function D.start(pid, dir)
	dir = string.lower(dir or "up");
	if (not DIRS[dir]) then
		return nil, "direction must be up, down, left or right.";
	end
	return {dir=dir, pts={}, data=nil,
	        prompt="mark one corner of the door."};
end

function D.click(s, pos)
	table.insert(s.pts, {x=pos.x, y=pos.y, z=pos.z});

	if (#s.pts == 1) then
		s.prompt = "now mark the opposite corner.";
		return false;
	end

	local a, b = s.pts[1], s.pts[2];
	local d = {
		x1=math.min(a.x,b.x), y1=math.min(a.y,b.y), z1=math.min(a.z,b.z),
		x2=math.max(a.x,b.x), y2=math.max(a.y,b.y), z2=math.max(a.z,b.z),
		dir=s.dir,
	};

	-- the panel has to have extent along whichever way it retracts,
	-- otherwise there is nothing to slide out of the way
	if (s.dir == "up" or s.dir == "down") then
		if (d.z1 == d.z2) then
			s.pts = {a};
			return false, "a vertical door needs height -- mark corners at different heights.";
		end
	elseif (d.x1 == d.x2 and d.y1 == d.y2) then
		s.pts = {a};
		return false, "a sliding door needs width -- mark corners apart horizontally.";
	end

	s.data = d;
	return true;
end

-- ------------------------------------------------------------- lifecycle

-- which axis the panel retracts along, and its span on that axis
local function axis_of(d)
	if (d.dir == "up" or d.dir == "down") then
		return "z", d.z1, d.z2;
	end
	if ((d.x2 - d.x1) >= (d.y2 - d.y1)) then
		return "x", d.x1, d.x2;
	end
	return "y", d.y1, d.y2;
end

function D.spawn(d)
	local inst = {
		x1=d.x1, y1=d.y1, z1=d.z1,
		x2=d.x2, y2=d.y2, z2=d.z2,
		dir=d.dir,
	};
	inst.axis, inst.lo, inst.hi = axis_of(inst);
	inst.slices = inst.hi - inst.lo + 1;
	-- "up" and "right" eat slices from the high end, "down" and "left"
	-- from the low end
	inst.from_hi = (d.dir == "up" or d.dir == "right");
	inst.open = 0;      -- how many slices are currently retracted
	inst.t = 0;
	return inst;
end

function D.save(inst)
	return {x1=inst.x1, y1=inst.y1, z1=inst.z1,
	        x2=inst.x2, y2=inst.y2, z2=inst.z2, dir=inst.dir};
end

-- the coordinate of the slice that the n-th step touches
local function slice_at(inst, n)
	if (inst.from_hi) then
		return inst.hi - n;
	end
	return inst.lo + n;
end

local function slice_open(inst, c)
	if (inst.from_hi) then
		return c > inst.hi - inst.open;
	end
	return c < inst.lo + inst.open;
end

-- draw (or clear) the plane slice sitting at coordinate c on the
-- retract axis; the other two axes are swept in full
local function draw_slice(inst, we, c, on)
	local x1, x2 = inst.x1, inst.x2;
	local y1, y2 = inst.y1, inst.y2;
	local z1, z2 = inst.z1, inst.z2;

	if (inst.axis == "z") then z1, z2 = c, c;
	elseif (inst.axis == "x") then x1, x2 = c, c;
	else y1, y2 = c, c; end

	for z = z1, z2 do
		for y = y1, y2 do
			for x = x1, x2 do
				if (x >= 0 and x < 512 and y >= 0 and y < 512
				    and z >= 0 and z < 64) then
					if (on) then we.set(inst, x, y, z, tint(inst));
					else we.clear(inst, x, y, z); end
				end
			end
		end
	end
end

function D.render(inst, we)
	for c = inst.lo, inst.hi do
		draw_slice(inst, we, c, not slice_open(inst, c));
	end
end

function D.destroy(inst, we)
	for c = inst.lo, inst.hi do
		draw_slice(inst, we, c, false);
	end
end

-- ---------------------------------------------------------------- trigger

-- a box around the whole panel, fattened by we_door_range so someone
-- walking up to either face sets it off
local function near_area(inst)
	local r = we_door_range;
	return areas.box(inst.x1-r, inst.y1-r, inst.z1-r,
	                 inst.x2+r, inst.y2+r, inst.z2+r);
end

-- ------------------------------------------------------------------ tick

function D.tick(inst, we)
	local dt = 1/60;
	local want = areas.any_player_in(near_area(inst)) and inst.slices or 0;

	if (inst.open == want) then
		inst.t = 0;
		return;
	end

	inst.t = inst.t + dt;
	local period = 1 / math.max(we_door_speed, 0.1);
	if (inst.t < period) then
		return;
	end
	inst.t = inst.t - period;

	-- exactly one slice per step, and only that slice is touched:
	-- redrawing the whole panel every step would be a block storm
	if (inst.open < want) then
		draw_slice(inst, we, slice_at(inst, inst.open), false);
		inst.open = inst.open + 1;
	else
		inst.open = inst.open - 1;
		draw_slice(inst, we, slice_at(inst, inst.open), true);
	end
end

return D;
