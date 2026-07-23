-- world_editor/door.lua -- A plane that retracts to open.
--
-- Placement: /place door up|down [perm]
--   mark 1 -- spade one corner of the door plane
--   mark 2 -- spade the opposite corner
--
-- The rectangle between the two marks is the door. Direction is the way
-- it retracts: "up" pulls the panel into the ceiling (the gap grows from
-- the floor up, like a portcullis), "down" sinks it into the floor.
-- Closing runs the same animation backwards.
--
-- It opens while anyone stands near it and closes once they leave, so a
-- door needs no switch -- walking up to it is the trigger.
--
-- The map's z axis points *down*: z1 is the top row, z2 the bottom.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local D = {name = "door"};

local areas = require "world_editor.areas";

getcfg("we_door_speed", 8);     -- rows opened/closed per second
getcfg("we_door_range", 4);     -- how close a player must be, in blocks

-- default panel colour; /place door ... <colour> overrides it
local GREY = {r=170, g=170, b=185};

local function tint(inst)
	return inst.color or GREY;
end

-- ------------------------------------------------------------ placement

function D.start(pid, dir)
	dir = string.lower(dir or "up");
	if (dir ~= "up" and dir ~= "down") then
		return nil, "direction must be up or down.";
	end
	return {dir=dir, pts={}, data=nil,
	        prompt="spade one corner of the door."};
end

function D.click(s, pos)
	table.insert(s.pts, {x=pos.x, y=pos.y, z=pos.z});

	if (#s.pts == 1) then
		s.prompt = "now spade the opposite corner.";
		return false;
	end

	local a, b = s.pts[1], s.pts[2];
	if (a.z == b.z) then
		s.pts = {a};
		return false, "a door needs height -- pick corners at different heights.";
	end

	s.data = {
		x1=math.min(a.x,b.x), y1=math.min(a.y,b.y), z1=math.min(a.z,b.z),
		x2=math.max(a.x,b.x), y2=math.max(a.y,b.y), z2=math.max(a.z,b.z),
		dir=s.dir,
	};
	return true;
end

-- ------------------------------------------------------------- lifecycle

function D.spawn(d)
	local inst = {
		x1=d.x1, y1=d.y1, z1=d.z1,
		x2=d.x2, y2=d.y2, z2=d.z2,
		dir=d.dir,
	};
	inst.rows = inst.z2 - inst.z1 + 1;
	inst.open = 0;      -- how many rows are currently retracted
	inst.t = 0;
	return inst;
end

function D.save(inst)
	return {x1=inst.x1, y1=inst.y1, z1=inst.z1,
	        x2=inst.x2, y2=inst.y2, z2=inst.z2, dir=inst.dir};
end

-- is this row retracted at the current open amount? "up" eats rows from
-- the bottom (z2) upwards, "down" eats them from the top (z1) down
local function row_open(inst, z)
	if (inst.dir == "up") then
		return z > inst.z2 - inst.open;
	end
	return z < inst.z1 + inst.open;
end

local function draw_row(inst, we, z, on)
	for y = inst.y1, inst.y2 do
		for x = inst.x1, inst.x2 do
			if (x >= 0 and x < 512 and y >= 0 and y < 512 and z >= 0 and z < 64) then
				if (on) then we.set(inst, x, y, z, tint(inst));
				else we.clear(inst, x, y, z); end
			end
		end
	end
end

function D.render(inst, we)
	for z = inst.z1, inst.z2 do
		draw_row(inst, we, z, not row_open(inst, z));
	end
end

function D.destroy(inst, we)
	for z = inst.z1, inst.z2 do
		draw_row(inst, we, z, false);
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
	local want = areas.any_player_in(near_area(inst)) and inst.rows or 0;

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

	-- one row per step, and only that row is touched: redrawing the
	-- whole panel every step would be a needless block storm
	if (inst.open < want) then
		local z = (inst.dir == "up") and (inst.z2 - inst.open) or (inst.z1 + inst.open);
		draw_row(inst, we, z, false);
		inst.open = inst.open + 1;
	else
		inst.open = inst.open - 1;
		local z = (inst.dir == "up") and (inst.z2 - inst.open) or (inst.z1 + inst.open);
		draw_row(inst, we, z, true);
	end
end

return D;
