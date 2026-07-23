-- world_editor/elevator.lua -- A rising platform.
--
-- Placement: /place elevator <rect|square|circle> <up|down>
--   rect/square: mark two footprint corners, then an altitude
--                (square snaps the corners to equal sides)
--   circle:      mark the centre, then a rim block (radius), then an
--                altitude
--
-- The footprint rests at the level of its first mark(s); the last mark
-- gives the far altitude. Direction is where the platform *goes* when
-- someone stands on it, so it rests at the opposite end: "up" waits at
-- the bottom, "down" waits at the top, and it returns there once empty.
--
-- Riders are carried by teleport rather than block physics: the platform
-- is redrawn a layer at a time, and a player on a block that vanishes
-- and reappears one layer along would stutter or fall through. Moving
-- them by the same delta keeps the ride smooth.
--
-- On placement the whole shaft is cleared of map blocks and then
-- reserved, so the platform has a free path and nobody can wall it in.
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
E.usage = "<rect|square|circle> <up|down>";
E.help  = {
	"world_editor: elevator -- a platform that carries riders up or down.",
	"  usage: /place elevator <rect|square|circle> <up|down>",
	"  up rests at the bottom and rises when stood on; down is the reverse.",
	"  rect/square: mark two corners then an altitude.",
	"  circle: mark centre, then a rim block, then an altitude.",
	"  colour is taken from your current block palette.",
};

-- ------------------------------------------------------------ placement

function E.start(pid, args)
	local shape = string.lower(args[1] or "");
	local dir   = string.lower(args[2] or "");
	if (shape ~= "rect" and shape ~= "square" and shape ~= "circle") then
		return nil, "shape must be rect, square or circle.";
	end
	if (dir ~= "up" and dir ~= "down") then
		return nil, "direction must be up or down.";
	end
	return {shape=shape, dir=dir, pts={},
	        prompt=(shape == "circle") and "mark the platform centre."
	                                    or "mark one corner of the platform."};
end

function E.click(s, pos)
	table.insert(s.pts, {x=pos.x, y=pos.y, z=pos.z});

	if (#s.pts == 1) then
		s.prompt = (s.shape == "circle") and "now mark a rim block (sets the radius)."
		                                  or "now mark the opposite corner.";
		return false;
	end
	if (#s.pts == 2) then
		s.prompt = "now mark a block at the altitude to travel to.";
		return false;
	end

	local a, b, c = s.pts[1], s.pts[2], s.pts[3];
	local foot;

	if (s.shape == "circle") then
		local r = math.ceil(math.sqrt((b.x-a.x)^2 + (b.y-a.y)^2));
		if (r < 1) then
			s.pts = {a};
			return false, "the rim is on the centre -- mark it further out.";
		end
		foot = {shape="circle", cx=a.x, cy=a.y, r=r};
	else
		local x1, y1 = math.min(a.x, b.x), math.min(a.y, b.y);
		local x2, y2 = math.max(a.x, b.x), math.max(a.y, b.y);
		if (s.shape == "square") then
			local side = math.max(x2 - x1, y2 - y1);
			x2, y2 = x1 + side, y1 + side;
		end
		foot = {shape="rect", x1=x1, y1=y1, x2=x2, y2=y2};
	end

	local base = a.z;
	if (base == c.z) then
		s.pts = {a, b};
		return false, "that altitude is the platform's own level -- pick a different height.";
	end

	s.data = {foot=foot, dir=s.dir,
	          zlo=math.min(base, c.z), zhi=math.max(base, c.z)};
	return true;
end

-- ------------------------------------------------------------- footprint

-- xy bounding box of the footprint, clamped to the map
local function foot_bbox(f)
	if (f.shape == "circle") then
		return f.cx-f.r, f.cy-f.r, f.cx+f.r, f.cy+f.r;
	end
	return f.x1, f.y1, f.x2, f.y2;
end

-- the footprint as an area spanning z1..z2 (for triggers and reserving)
local function foot_area(f, z1, z2)
	if (f.shape == "circle") then
		return areas.cylinder(f.cx, f.cy, f.r, z1, z2);
	end
	return areas.box(f.x1, f.y1, z1, f.x2, f.y2, z2);
end

-- draw (or clear) the platform layer at z
local function draw_foot(inst, we, z, color, on)
	local f = inst.foot;
	if (f.shape == "circle") then
		we.disc(inst, f.cx, f.cy, z, f.r, color, on);
	else
		we.rect(inst, f.x1, f.y1, f.x2, f.y2, z, color, on);
	end
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
	local inst = {foot=d.foot, dir=d.dir, zlo=d.zlo, zhi=d.zhi};

	local x1, y1, x2, y2 = foot_bbox(d.foot);
	inst.x = math.floor((x1 + x2) / 2);   -- centre, for nearest-component search
	inst.y = math.floor((y1 + y2) / 2);

	inst.z = rest_z(inst);      -- current platform layer
	inst.state = "rest";        -- rest | going | holding | returning
	inst.t = 0;
	inst.hold = 0;
	return inst;
end

function E.save(inst)
	return {foot=inst.foot, dir=inst.dir, zlo=inst.zlo, zhi=inst.zhi};
end

function E.render(inst, we)
	-- clear the shaft so the platform has a free path, then lay the
	-- platform down at its resting layer
	local x1, y1, x2, y2 = foot_bbox(inst.foot);
	local shaft = foot_area(inst.foot, inst.zlo - we_elevator_headroom, inst.zhi);
	for z = inst.zlo - we_elevator_headroom, inst.zhi do
		for y = y1, y2 do
			for x = x1, x2 do
				if (areas.contains(shaft, x, y, z)) then
					we.dig(x, y, z);
				end
			end
		end
	end
	draw_foot(inst, we, inst.z, tint(inst), true);
end

function E.destroy(inst, we)
	draw_foot(inst, we, inst.z, nil, false);
end

-- the full column the platform sweeps, plus headroom above the top stop
function E.reserved(inst)
	return foot_area(inst.foot, inst.zlo - we_elevator_headroom, inst.zhi);
end

-- ---------------------------------------------------------------- trigger

-- the footprint with a few blocks of headroom, sliding with the platform
local function rider_area(inst)
	return foot_area(inst.foot, inst.z - 4, inst.z);
end

local function riders(inst)
	return areas.players_in(rider_area(inst));
end

-- ------------------------------------------------------------------ tick

local function step(inst, we, dz)
	local from = inst.z;
	local to = from + dz;

	local aboard = riders(inst);  -- carry them before the floor moves

	draw_foot(inst, we, from, nil, false);
	inst.z = to;
	draw_foot(inst, we, to, tint(inst), true);

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
