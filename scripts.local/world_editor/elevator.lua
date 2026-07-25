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
-- A step never rewrites the platform. The slab and the piston column
-- under it overlap everywhere except the ring between them, so moving a
-- layer only ever changes that ring plus the single layer the slab gains
-- or gives up. Everything else is already the right block in the right
-- place, and re-sending it would be both a packet storm and a
-- destroy-then-create on the same cell in one tick -- the pattern that
-- leaves client connectivity stale (see the block api in
-- world_editor.lua).
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
getcfg("we_elevator_abort", 0.6);  -- empty this long mid-travel -> return
getcfg("we_elevator_headroom", 3); -- rider headroom reserved above the top
getcfg("we_elevator_thick", 1);    -- platform layers thick (1 = flat pad)
getcfg("we_elevator_piston", 0.4); -- piston width as a fraction of the platform
getcfg("we_elevator_stand", 2.4);  -- head-to-feet: pos.z when stood on the top

local RED = {r=255, g=32, b=32};   -- fallback if the palette read fails

-- how far above the platform still counts as standing on it; generous
-- enough that a rider jumping in place stays aboard
local RIDER_REACH = 6;

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

	-- marks land on solid surfaces (you spade a block); the platform is a
	-- new layer that sits ON TOP of them, i.e. one above (z is down, so
	-- top = z-1). Building it at the mark itself would try to occupy the
	-- solid block you clicked, which we correctly refuse to repaint.
	local base = a.z - 1;
	local dest = c.z - 1;
	if (base == dest) then
		s.pts = {a, b};
		return false, "that altitude is the platform's own level -- pick a different height.";
	end

	s.data = {foot=foot, dir=s.dir,
	          zlo=math.min(base, dest), zhi=math.max(base, dest)};
	return true;
end

-- ------------------------------------------------------------- footprint
--
-- The shapes come from we.foot_* -- the same footprint vocabulary any
-- component extruding a 2d shape through z uses.

-- one full footprint layer at z (a slab layer)
local function draw_foot(inst, we, z, on)
	we.layer(inst, inst.foot, z, on and we.tint(inst, RED) or nil, on);
end

-- The piston is the visible support column under the platform: the
-- footprint inset on every side (see we_elevator_piston), running from
-- just beneath the platform down to the shaft base, so the wider
-- platform appears to ride on a narrower shaft. nil when the platform
-- is too small to inset at all.
local function draw_piston(inst, we, z, on)
	if (inst.piston == nil) then return; end
	we.layer(inst, inst.piston, z, on and we.tint(inst, RED) or nil, on);
end

-- The ring between platform and piston: the only cells that differ
-- between "this layer is slab" and "this layer is piston". Moving one
-- layer converts a slab layer into a piston layer (or back), and that is
-- exactly this ring going away or coming back -- nothing else on the
-- layer changes, so nothing else is sent.
local function draw_ring(inst, we, z, on)
	we.layer(inst, inst.foot, z, on and we.tint(inst, RED) or nil, on, inst.piston);
end

-- the platform is a slab we_elevator_thick layers deep, its top surface
-- at z and the rest hanging below (z+1 ..). draw/clear the whole slab
local function draw_slab(inst, we, ztop, on)
	for d = 0, we_elevator_thick - 1 do
		draw_foot(inst, we, ztop + d, on);
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

function E.spawn(d, we)
	local inst = {foot=d.foot, dir=d.dir, zlo=d.zlo, zhi=d.zhi};

	-- Keep the whole structure off the engine floor / client Root layer.
	-- The slab hangs thickness-1 below its top, so the lowest top we can
	-- use is deepest-(thick-1); an elevator marked at bedrock level then
	-- rests directly ON the floor instead of inside it. Writing into
	-- those layers is what crashed zerospades.
	local floor_top = we.deepest - (we_elevator_thick - 1);
	if (inst.zhi > floor_top) then inst.zhi = floor_top; end
	if (inst.zlo > inst.zhi) then inst.zlo = inst.zhi; end

	-- A fixed one-block inset is a fraction of a wide platform and all of
	-- a narrow one, so the column read as "stacked platforms" on big
	-- footprints and vanished on small ones. Scale it with the footprint
	-- instead, always leaving the piston at least one block narrower than
	-- the platform, and nil when there is no room to inset at all.
	local half = we.foot_half(d.foot);
	local target = math.floor(half * we_elevator_piston);
	if (target < 1) then target = 1; end
	if (target > half - 1) then target = half - 1; end
	inst.piston = (target >= 1) and we.foot_inset(d.foot, math.floor(half - target)) or nil;

	local x1, y1, x2, y2 = we.foot_bbox(d.foot);
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

-- top of the shaft, i.e. the highest layer the platform can reach plus
-- the headroom a rider standing on it needs
local function shaft_top(inst)
	return inst.zlo - we_elevator_headroom;
end

function E.render(inst, we)
	-- clear the shaft so the platform has a free path (bulk: one cull for
	-- the whole column), then lay the platform down at its resting layer
	local x1, y1, x2, y2 = we.foot_bbox(inst.foot);
	local f = inst.foot;
	we.dig_box(x1, y1, shaft_top(inst), x2, y2, shaft_bottom(inst),
	           function(x, y) return we.foot_has(f, x, y); end);

	draw_slab(inst, we, inst.z, true);
	for z = inst.z + we_elevator_thick, shaft_bottom(inst) do
		draw_piston(inst, we, z, true);
	end
end

-- The whole structure comes down in one we.fill, not layer by layer:
-- clears go through the bulk-destroy path, which culls floating blocks
-- once per call, so taking the slab and the piston column down together
-- is one cull instead of one per layer. /savemap and /delete both
-- destroy every component, so this is the hot path for them.
function E.destroy(inst, we)
	local x1, y1, x2, y2 = we.foot_bbox(inst.foot);
	local slab_bottom = inst.z + we_elevator_thick - 1;
	local f, p = inst.foot, inst.piston;

	we.fill(inst, x1, y1, inst.z, x2, y2, shaft_bottom(inst), nil, false,
	        function(x, y, z)
		if (z <= slab_bottom) then
			return we.foot_has(f, x, y);
		end
		return p ~= nil and we.foot_has(p, x, y);
	end);
end

-- the full column the platform sweeps, plus headroom above the top stop
function E.reserved(inst, we)
	return we.foot_area(inst.foot, shaft_top(inst), shaft_bottom(inst));
end

-- ---------------------------------------------------------------- trigger

-- The footprint plus rider headroom, sliding with the platform. The
-- volume is cached and its z span mutated in place: this is asked 60
-- times a second per elevator, so building a fresh area table each time
-- was pure garbage.
local function rider_area(inst, we)
	local a = inst.trigger;
	if (a == nil) then
		a = we.foot_area(inst.foot, inst.z - RIDER_REACH, inst.z);
		inst.trigger = a;
		return a;
	end
	a.z1, a.z2 = inst.z - RIDER_REACH, inst.z;
	return a;
end

-- Most checks only need "is anyone aboard", which short-circuits on the
-- first hit and allocates nothing; only a step needs the actual list, and
-- that refills one scratch table rather than making a new one.
local function has_riders(inst, we)
	return areas.any_player_in(rider_area(inst, we));
end

local aboard = {};

local function riders(inst, we)
	return areas.players_in(rider_area(inst, we), nil, aboard);
end

-- ------------------------------------------------------------------ tick

-- Carry riders with the platform. Move them by the same delta so their
-- own walking/jumping is preserved, but never let them end up below the
-- platform's top surface -- that is the "legs stuck in the platform"
-- sink, where relative motion plus client jitter buries them a little
-- deeper each step. inst.z is already the new top layer here.
local function carry(inst, riding, dz)
	local top = inst.z - we_elevator_stand;   -- pos.z of feet-on-surface
	for _, pid in ipairs(riding) do
		local p = get_position(pid);
		local nz = p.z + dz;
		if (nz > top) then nz = top; end       -- z is down: clamp the sink
		set_position(pid, {x=p.x, y=p.y, z=nz});
	end
end

-- Move the slab one layer.
--
-- A 1-layer move changes exactly two layers, whatever the slab's
-- thickness: the layer it gains at the leading edge, and the layer it
-- gives up at the trailing edge. Every layer in between is already
-- correct and is never touched -- that overlap is also what keeps the
-- rider's floor solid the whole time, even if a block packet is briefly
-- late.
--
-- And the trailing layer does not turn into air, it turns into piston,
-- so only the ring between the two shapes moves. Destroying the layer
-- and rebuilding its inset would send both shapes for no visible
-- difference, and would destroy-then-create the same cells inside one
-- tick, which is what makes clients assert.
--
-- The rider must never see a moment with no floor, or client-side
-- physics drops them through: add the new layer before removing the old,
-- and teleport in the safe order per direction. Position, block-build
-- and block-destroy are all reliable and ordered, so the client applies
-- them exactly as sent.
local function step(inst, we, dz)
	local from = inst.z;
	local to = from + dz;
	local riding = riders(inst, we);  -- detect before anything moves
	local thick = we_elevator_thick;

	inst.z = to;

	if (dz < 0) then
		-- rising: lift riders, add the new top layer under their feet,
		-- then let the vacated bottom layer become piston -- it stays
		-- solid and just loses its ring as the platform climbs off it
		carry(inst, riding, dz);
		draw_foot(inst, we, to, true);                  -- new top layer
		draw_ring(inst, we, from + thick - 1, false);   -- old bottom -> piston
	else
		-- descending: the new bottom layer lands on the piston's top
		-- layer, so it only needs its ring filled in to become slab;
		-- catch the riders, then drop the old top layer entirely
		draw_ring(inst, we, to + thick - 1, true);      -- piston -> new bottom
		draw_foot(inst, we, from, false);               -- old top layer off
		carry(inst, riding, dz);
	end
end

function E.tick(inst, we, dt)
	local goal = goal_z(inst);
	local rest = rest_z(inst);

	if (inst.state == "rest") then
		if (inst.z ~= rest) then
			inst.state = "returning";
		elseif (has_riders(inst, we)) then
			inst.state = "going";
			inst.t = 0;
			inst.empty = 0;
		end
		return;
	end

	if (inst.state == "holding") then
		inst.hold = inst.hold - dt;
		if (inst.hold <= 0 and not has_riders(inst, we)) then
			inst.state = "returning";
			inst.t = 0;
		end
		return;
	end

	-- Riders all gone mid-travel: abort and head back to rest. A short
	-- grace absorbs a rider being briefly airborne (a jump), so a hop
	-- doesn't reverse the lift.
	if (inst.state == "going") then
		if (not has_riders(inst, we)) then
			inst.empty = (inst.empty or 0) + dt;
			if (inst.empty >= we_elevator_abort) then
				inst.state = "returning";
				inst.t = 0;
			end
		else
			inst.empty = 0;
		end
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

	if (we.due(inst, "t", we_elevator_speed, dt)) then
		step(inst, we, (target < inst.z) and -1 or 1);
	end
end

return E;
