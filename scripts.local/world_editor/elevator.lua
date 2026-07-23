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
getcfg("we_elevator_thick", 2);    -- platform thickness (>=2 rides out lag)
getcfg("we_elevator_stand", 2.4);  -- head-to-feet: pos.z when stood on the top

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

-- draw (or clear) one footprint layer at z
local function draw_foot(inst, we, z, color, on)
	local f = inst.foot;
	if (f.shape == "circle") then
		we.disc(inst, f.cx, f.cy, z, f.r, color, on);
	else
		we.rect(inst, f.x1, f.y1, f.x2, f.y2, z, color, on);
	end
end

-- the platform is a slab we_elevator_thick layers deep, its top surface
-- at z and the rest hanging below (z+1 ..). draw/clear the whole slab
local function draw_slab(inst, we, ztop, color, on)
	for d = 0, we_elevator_thick - 1 do
		draw_foot(inst, we, ztop + d, color, on);
	end
end

-- The piston is the visible support column under the platform: the
-- footprint inset by one block on every side (x-, x+, y-, y+), running
-- from just beneath the platform down to the shaft base, so the wider
-- platform appears to ride on a narrower shaft. nil when the platform
-- is too small to inset.
local function inset_foot(f)
	if (f.shape == "circle") then
		if (f.r - 1 < 1) then return nil; end
		return {shape="circle", cx=f.cx, cy=f.cy, r=f.r-1};
	end
	local x1, y1 = f.x1+1, f.y1+1;
	local x2, y2 = f.x2-1, f.y2-1;
	if (x1 > x2 or y1 > y2) then return nil; end
	return {shape="rect", x1=x1, y1=y1, x2=x2, y2=y2};
end

local function draw_piston_layer(inst, we, z, on)
	local p = inst.piston;
	if (p == nil) then return; end
	local color = on and tint(inst) or nil;
	if (p.shape == "circle") then
		we.disc(inst, p.cx, p.cy, z, p.r, color, on);
	else
		we.rect(inst, p.x1, p.y1, p.x2, p.y2, z, color, on);
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
	inst.piston = inset_foot(d.foot);

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

-- lowest z the slab ever reaches: its top travels down to zhi, plus the
-- thickness hanging below
local function shaft_bottom(inst)
	return inst.zhi + we_elevator_thick - 1;
end

function E.render(inst, we)
	-- clear the shaft so the platform has a free path, then lay the
	-- platform down at its resting layer
	local x1, y1, x2, y2 = foot_bbox(inst.foot);
	local top = inst.zlo - we_elevator_headroom;
	local bot = shaft_bottom(inst);
	local shaft = foot_area(inst.foot, top, bot);
	for z = top, bot do
		for y = y1, y2 do
			for x = x1, x2 do
				if (areas.contains(shaft, x, y, z)) then
					we.dig(x, y, z);
				end
			end
		end
	end
	draw_slab(inst, we, inst.z, tint(inst), true);
	for z = inst.z + we_elevator_thick, shaft_bottom(inst) do
		draw_piston_layer(inst, we, z, true);
	end
end

function E.destroy(inst, we)
	draw_slab(inst, we, inst.z, nil, false);
	for z = inst.z + we_elevator_thick, shaft_bottom(inst) do
		draw_piston_layer(inst, we, z, false);
	end
end

-- the full column the platform sweeps, plus headroom above the top stop
function E.reserved(inst)
	return foot_area(inst.foot, inst.zlo - we_elevator_headroom, shaft_bottom(inst));
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

-- Carry riders with the platform. Move them by the same delta so their
-- own walking/jumping is preserved, but never let them end up below the
-- platform's top surface -- that is the "legs stuck in the platform"
-- sink, where relative motion plus client jitter buries them a little
-- deeper each step. inst.z is already the new top layer here.
local function carry(inst, aboard, dz)
	local top = inst.z - we_elevator_stand;   -- pos.z of feet-on-surface
	for _, pid in ipairs(aboard) do
		local p = get_position(pid);
		local nz = p.z + dz;
		if (nz > top) then nz = top; end       -- z is down: clamp the sink
		set_position(pid, {x=p.x, y=p.y, z=nz});
	end
end

-- Move the slab one layer. With a thick slab a 1-step move overlaps by
-- thickness-1 layers, so we only add the new edge layer and remove the
-- old one -- the overlap stays solid the whole time and the rider never
-- loses their floor, even if a block packet is briefly late.
--
-- The rider must never see a moment with no floor, or client-side
-- physics drops them through: add the new layer before removing the old,
-- and teleport in the safe order per direction. Position, block-build
-- and block-destroy are all reliable and ordered, so the client applies
-- them exactly as sent.
local function step(inst, we, dz)
	local from = inst.z;
	local to = from + dz;
	local aboard = riders(inst);  -- detect before anything moves
	local thick = we_elevator_thick;

	inst.z = to;

	if (dz < 0) then
		-- rising: lift riders, add the new top layer under their feet,
		-- then convert the vacated bottom layer into piston (it stays
		-- solid, just insets by a block as the platform climbs off it)
		carry(inst, aboard, dz);
		draw_foot(inst, we, to, tint(inst), true);            -- new top
		draw_foot(inst, we, from + thick - 1, nil, false);    -- old bottom off
		draw_piston_layer(inst, we, from + thick - 1, true);  -- piston grows up
	else
		-- descending: the new bottom layer lands on the piston's top
		-- layer, drawing the full footprint there absorbs it (piston
		-- shrinks); catch the riders, then drop the old top layer
		draw_foot(inst, we, to + thick - 1, tint(inst), true);-- new bottom
		draw_foot(inst, we, from, nil, false);                -- old top
		carry(inst, aboard, dz);
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
