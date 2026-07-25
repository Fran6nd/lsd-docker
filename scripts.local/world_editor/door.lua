-- world_editor/door.lua -- A plane that retracts to open.
--
-- Placement: /place door up|down|left|right
--   mark 1 -- one corner of the door plane
--   mark 2 -- the opposite corner
-- Colour comes from the placer's block palette, not an argument.
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

-- default panel colour, used when the placer's palette read fails
local GREY = {r=170, g=170, b=185};

local DIRS = {up=true, down=true, left=true, right=true};

D.desc  = "a plane that retracts to open when someone is near.";
D.usage = "<up|down|left|right>";
D.help  = {
	"world_editor: door -- a plane that slides open when a player nears it.",
	"  usage: /place door <up|down|left|right>",
	"  up/down retract into ceiling/floor; left/right slide aside.",
	"  then mark two opposite corners (spade a block, or /here).",
	"  colour is taken from your current block palette.",
};

-- ------------------------------------------------------------ placement

function D.start(pid, args)
	local dir = string.lower(args[1] or "");
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

function D.spawn(d, we)
	local inst = {
		x1=d.x1, y1=d.y1, z1=d.z1,
		x2=d.x2, y2=d.y2, z2=d.z2,
		dir=d.dir,
	};

	-- Keep the panel off the engine floor and the client's Root layer,
	-- the same clamp the elevator applies: we.fill would silently drop
	-- those rows anyway, and a door that is shorter than it thinks would
	-- leave a permanent gap under it.
	if (inst.z2 > we.deepest) then inst.z2 = we.deepest; end
	if (inst.z1 > inst.z2) then inst.z1 = inst.z2; end

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

-- draw (or clear) the plane slice sitting at coordinate c on the retract
-- axis; the other two axes are swept in full. we.fill batches it into
-- block_line rows (build) or a bulk cull (clear) instead of per block.
local function draw_slice(inst, we, c, on)
	local x1, x2 = inst.x1, inst.x2;
	local y1, y2 = inst.y1, inst.y2;
	local z1, z2 = inst.z1, inst.z2;

	if (inst.axis == "z") then z1, z2 = c, c;
	elseif (inst.axis == "x") then x1, x2 = c, c;
	else y1, y2 = c, c; end

	we.fill(inst, x1, y1, z1, x2, y2, z2, we.tint(inst, GREY), on, nil);
end

-- Only the shut slices own blocks; the retracted ones are air the panel
-- has already given up, so there is nothing there to draw or to clear.
-- Sweeping them anyway cost a bulk-destroy cull per slice for no writes.
function D.render(inst, we)
	for c = inst.lo, inst.hi do
		if (not slice_open(inst, c)) then
			draw_slice(inst, we, c, true);
		end
	end
end

-- The whole panel comes down in one we.fill rather than slice by slice:
-- one bulk-destroy cull for the component instead of one per slice.
function D.destroy(inst, we)
	we.fill(inst, inst.x1, inst.y1, inst.z1, inst.x2, inst.y2, inst.z2,
	        nil, false, nil);
end

-- ---------------------------------------------------------------- trigger

-- The panel fattened by we_door_range, so someone walking up to either
-- face sets it off. The panel never moves, so this is built once at
-- spawn rather than rebuilt 60 times a second.
local function near_area(inst)
	if (inst.trigger == nil) then
		local r = we_door_range;
		inst.trigger = areas.box(inst.x1-r, inst.y1-r, inst.z1-r,
		                         inst.x2+r, inst.y2+r, inst.z2+r);
	end
	return inst.trigger;
end

-- Nobody may build inside the panel or its retract path: a block left in
-- the way would be one we.fill refuses to repaint (it never paints over
-- solid), so the door would close with a hole in it and never recover.
-- The elevator reserves its shaft for the same reason.
function D.reserved(inst)
	return areas.box(inst.x1, inst.y1, inst.z1, inst.x2, inst.y2, inst.z2);
end

-- ------------------------------------------------------------------ tick

function D.tick(inst, we, dt)
	local want = areas.any_player_in(near_area(inst)) and inst.slices or 0;

	if (inst.open == want) then
		inst.t = 0;
		return;
	end

	if (not we.due(inst, "t", we_door_speed, dt)) then
		return;
	end

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
