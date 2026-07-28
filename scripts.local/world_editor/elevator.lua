-- world_editor/elevator.lua -- A built platform that lifts riders.
--
-- Placement: /place elevator <up|down>
--   mark 1 -- one corner of the platform
--   mark 2 -- the opposite corner
--   mark 3 -- a block at the altitude to travel to
--
-- Like the door, the platform is not drawn from nothing: whatever is
-- already built inside the marked box IS the platform. Every solid cell
-- keeps the colour it already has and every empty cell stays empty, so a
-- pad can carry a pattern, a hole in the middle, a logo, and it keeps
-- all of it while it rides. Build the pad first, then mark it.
--
-- Mark a box with nothing in it and you get a plain solid slab of that
-- box in your block palette colour, which is what an elevator platform
-- always used to be.
--
-- The third mark names the altitude to arrive at: the platform's
-- underside comes to rest on that exact layer, so the pad ends up level
-- with what you marked. Direction is where the platform *goes* when
-- someone stands on it, so it rests at the opposite end: "up" waits at
-- the bottom, "down" waits at the top, and it returns there once empty.
--
-- The piston is kept. It is the visible support column under the
-- platform: the pad's own silhouette eroded on every side (see
-- we_elevator_piston), running from just beneath the platform down to
-- the shaft base, so the wider platform appears to ride on a narrower
-- column. Because the pad is now a drawing rather than one flat colour,
-- the column is drawn in the colour of the platform's CORE -- the block
-- nearest the middle of its underside -- so it reads as an extrusion of
-- the pad rather than a separate object bolted underneath.
--
-- Riders are carried by teleport rather than block physics: the platform
-- is redrawn a layer at a time, and a player on a block that vanishes
-- and reappears one layer along would stutter or fall through. Moving
-- them by the same delta keeps the ride smooth.
--
-- A step never rewrites the whole structure. Moving one layer changes
-- only a couple of layers whatever the shaft's height, and within those
-- it writes only the cells that genuinely differ -- see motion_for. A
-- cell that already holds the right colour is left alone, because
-- re-sending it is both a packet storm and a destroy-then-create on one
-- cell in one tick, which is the pattern that leaves client connectivity
-- stale (see the block api in world_editor.lua).
--
-- On placement the whole shaft is cleared of map blocks and then
-- reserved, so the platform has a free path and nobody can wall it in.
--
-- The map's z axis points *down* (z=0 sky, z=63 floor), so travelling
-- "up" steps z downward.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local E = {name = "elevator"};

local areas   = require "world_editor.areas";
local stencil = require "world_editor.stencil";

getcfg("we_elevator_speed", 6);    -- layers per second
getcfg("we_elevator_wait", 1.0);   -- seconds held at the far end
getcfg("we_elevator_abort", 0.6);  -- empty this long mid-travel -> return
getcfg("we_elevator_headroom", 3); -- rider headroom reserved above the top
getcfg("we_elevator_piston", 0.4); -- piston width as a fraction of the platform
getcfg("we_elevator_stand", 2.4);  -- head-to-feet: pos.z when stood on the top

local RED = {r=255, g=32, b=32};   -- fallback if the palette read fails

-- how far above the platform still counts as standing on it; generous
-- enough that a rider jumping in place stays aboard
local RIDER_REACH = 6;

E.desc  = "a built platform that lifts riders between two altitudes.";
E.usage = "<up|down>";
E.help  = {
	"world_editor: elevator -- a built platform that carries riders up or down.",
	"  usage: /place elevator <up|down>",
	"  up rests at the bottom and rises when stood on; down is the reverse.",
	"  build the pad first, then mark two opposite corners around it,",
	"  then mark the altitude it should travel to -- the pad comes to",
	"  rest level with that mark.",
	"  its blocks, colours and gaps all become the platform.",
	"  the piston column under it takes the colour of the pad's core.",
	"  an empty box gives a plain slab in your palette colour instead.",
};

-- a cell of a layer, keyed on the two coordinates that do not change as
-- the platform rides; x/y top out at 511, so this packs cleanly
local function kxy(x, y)
	return y*512 + x;
end

-- ------------------------------------------------------------ placement

function E.start(pid, args)
	local dir = string.lower(args[1] or "");
	if (dir ~= "up" and dir ~= "down") then
		return nil, "direction must be up or down.";
	end
	return {dir=dir, pts={}, prompt="mark one corner of the platform."};
end

function E.click(s, pos, we)
	table.insert(s.pts, {x=pos.x, y=pos.y, z=pos.z});

	if (#s.pts == 1) then
		s.prompt = "now mark the opposite corner of the platform.";
		return false;
	end
	if (#s.pts == 2) then
		s.prompt = "now mark a block at the altitude to travel to.";
		return false;
	end

	local a, b, c = s.pts[1], s.pts[2], s.pts[3];
	local d = {
		x1=math.min(a.x,b.x), y1=math.min(a.y,b.y), z1=math.min(a.z,b.z),
		x2=math.max(a.x,b.x), y2=math.max(a.y,b.y), z2=math.max(a.z,b.z),
		dir=s.dir,
	};

	-- Keep the platform off the engine floor and the client's Root layer.
	-- This has to happen HERE rather than at spawn: the drawing is indexed
	-- by the box, so the box must be final before a cell is read out of it.
	if (d.z2 > we.deepest) then d.z2 = we.deepest; end
	if (d.z1 > d.z2) then d.z1 = d.z2; end

	local thick = d.z2 - d.z1 + 1;

	-- The third mark names the altitude to arrive AT, not to stop above:
	-- the platform's underside comes to rest on that very layer, so what
	-- you marked is where the pad ends up. (`dest` is the top layer, and
	-- the pad hangs `thick` layers down from it.)
	local dest = c.z - thick + 1;
	if (dest < 0) then dest = 0; end
	local floor_top = we.deepest - (thick - 1);
	if (dest > floor_top) then dest = floor_top; end

	if (dest == d.z1) then
		s.pts = {a, b};
		return false, "that altitude is the platform's own level -- mark a different height.";
	end

	d.zlo = math.min(d.z1, dest);
	d.zhi = math.max(d.z1, dest);

	-- Nothing of another component may be inside the shaft: E.render digs
	-- the whole column to give the platform a free path, which would tear
	-- a hole through whatever else lives there.
	local st = math.max(0, d.zlo - we_elevator_headroom);
	local sb = math.min(we.deepest, d.zhi + thick - 1);
	for z = st, sb do
		for y = d.y1, d.y2 do
			for x = d.x1, d.x2 do
				if (we.is_guarded(x, y, z)) then
					s.pts = {a, b};
					return false, "the shaft would run through another component -- pick another altitude.";
				end
			end
		end
	end

	d.pal, d.cells = stencil.capture(d.x1, d.y1, d.z1, d.x2, d.y2, d.z2);

	s.data = d;
	return true;
end

-- ------------------------------------------------------------- structure

-- Occupancy for an elevator placed on an empty box: every cell solid, in
-- the one colour the placer was holding. Building it here rather than
-- special-casing it everywhere means the motion code only ever deals
-- with one representation.
local function full_occ(inst)
	local occ, n = {}, 0;
	for dz = 0, inst.T - 1 do
		local layer = {};
		for y = inst.y1, inst.y2 do
			for x = inst.x1, inst.x2 do
				layer[kxy(x, y)] = 1;
				n = n + 1;
			end
		end
		occ[dz] = layer;
	end
	return occ, n;
end

local function decode_occ(inst, npal, cells)
	local occ = {};
	for dz = 0, inst.T - 1 do occ[dz] = {}; end

	local n, why = stencil.each(inst, npal, cells, function(x, y, z, cidx)
		occ[z - inst.z1][kxy(x, y)] = cidx;
	end);

	if (n == nil) then
		return nil, why;
	end
	return occ, n;
end

-- every (x,y) the platform covers on any of its layers -- its silhouette
-- seen from above. This is what the shaft is dug through and what the
-- piston is eroded from.
local function silhouette(inst)
	local s = {};
	for dz = 0, inst.T - 1 do
		for k in pairs(inst.occ[dz]) do s[k] = true; end
	end
	return s;
end

-- The piston is the silhouette eroded on every side: a cell belongs to
-- it only where the platform is solid all around it out to `n` blocks.
-- For a rectangular pad that is exactly the old inset; for a captured
-- drawing it is the same idea generalised, so a round pad gets a round
-- column, and one with a bite out of its edge gets a column that keeps
-- clear of the bite. nil when nothing survives the erosion.
local function erode(silh, n, x1, y1, x2, y2)
	if (n < 1) then return nil; end

	local out, any = {}, false;
	for y = y1, y2 do
		for x = x1, x2 do
			if (silh[kxy(x, y)]) then
				local solid = true;
				for dy = -n, n do
					for dx = -n, n do
						if (not silh[kxy(x+dx, y+dy)]) then solid = false; break; end
					end
					if (not solid) then break; end
				end
				if (solid) then out[kxy(x, y)] = true; any = true; end
			end
		end
	end
	return any and out or nil;
end

-- The colour of the platform's core: the block nearest the middle of its
-- underside, which is the face the column grows out of. Layers are tried
-- from the bottom up so a pad whose underside is all holes still finds
-- one.
local function core_of(inst)
	local cx = math.floor((inst.x1 + inst.x2) / 2);
	local cy = math.floor((inst.y1 + inst.y2) / 2);

	for dz = inst.T - 1, 0, -1 do
		local layer = inst.occ[dz];
		local best, bestd;
		for y = inst.y1, inst.y2 do
			for x = inst.x1, inst.x2 do
				local c = layer[kxy(x, y)];
				if (c ~= nil) then
					local dd = math.max(math.abs(x-cx), math.abs(y-cy));
					if (bestd == nil or dd < bestd) then best, bestd = c, dd; end
				end
			end
		end
		if (best ~= nil) then return best; end
	end
	return 1;
end

-- What belongs at column `k`, `d` layers below the platform's top: a
-- palette index, or nil for air. d<0 is above the platform; d>=T is the
-- piston column, which is the same all the way down.
--
-- `nopiston` asks for the pad alone, with no column under it. That is
-- the shape the elevator leaves behind when it is un-placed: the pad was
-- somebody's build and stays, the column never existed before the
-- elevator did and must not be left standing.
local function state(inst, d, k, nopiston)
	if (d < 0) then return nil; end
	if (d < inst.T) then return inst.occ[d][k]; end
	if (nopiston) then return nil; end
	if (inst.piston ~= nil and inst.piston[k]) then return inst.coreidx; end
	return nil;
end

-- What a one-layer move actually has to write.
--
-- Everything is expressed relative to the platform's CURRENT top, so one
-- table serves every altitude: at relative layer r the cell holds
-- state(r) now and state(r - dz) afterwards, and only where those differ
-- is anything sent. Beyond r = T the answer is "piston" both before and
-- after, so the whole column below is untouched however deep the shaft
-- is -- that is what keeps a step cheap.
--
-- Each differing cell falls into exactly one of three jobs:
--
--   build  -- nothing was there, so a block has to appear
--   paint  -- a block of ours is there in another colour, so it only
--             needs recolouring (we.paint -- never a destroy plus a
--             create on one cell in one tick)
--   clear  -- nothing belongs there any more
--
-- Grouped by colour, because that is how the writes are issued: one call
-- per colour spanning every layer it appears on. we.fill sends the block
-- colour once per call and ends a clear with one floating-block cull, so
-- a step costs one colour packet per colour and exactly one cull.
local function motion_for(inst, dz)
	local build, paint, clear = {}, {}, {};
	local nc = 0;

	local function put(t, cidx, r, k)
		local byr = t[cidx];
		if (byr == nil) then byr = {}; t[cidx] = byr; end
		local s = byr[r];
		if (s == nil) then s = {}; byr[r] = s; end
		s[k] = true;
	end

	-- Only the layers a one-layer move disturbs. Above the platform
	-- everything is air both before and after; below it, past the pad's
	-- own depth, it is piston both before and after -- which is what
	-- keeps a step's cost independent of how deep the shaft is.
	for r = -1, inst.T do
		for k in pairs(inst.silh) do
			local a = state(inst, r, k);
			local b = state(inst, r - dz, k);
			if (a ~= b) then
				if (b == nil) then
					local s = clear[r];
					if (s == nil) then s = {}; clear[r] = s; end
					s[k] = true; nc = nc + 1;
				elseif (a == nil) then
					put(build, b, r, k);
				else
					put(paint, b, r, k);
				end
			end
		end
	end

	return {build=build, paint=paint, clear=(nc > 0) and clear or nil};
end

-- the platform itself, by colour then layer -- what a full draw needs
local function bycolour_of(inst)
	local byc = {};
	for dz = 0, inst.T - 1 do
		for k, cidx in pairs(inst.occ[dz]) do
			local byr = byc[cidx];
			if (byr == nil) then byr = {}; byc[cidx] = byr; end
			local s = byr[dz];
			if (s == nil) then s = {}; byr[dz] = s; end
			s[k] = true;
		end
	end
	return byc;
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

-- lowest layer the platform ever reaches: its top travels down to zhi,
-- plus the layers hanging below it
local function shaft_bottom(inst)
	return inst.zhi + inst.T - 1;
end

-- top of the shaft: the highest layer the platform can reach, plus the
-- headroom a rider standing on it needs
local function shaft_top(inst)
	return inst.zlo - we_elevator_headroom;
end

function E.spawn(d, we)
	-- Layouts written before elevators were captured from a build named a
	-- parametric footprint instead of a box. None are known to exist, but
	-- rather than fail the whole load, take the footprint's bounding box
	-- and carry on as a plain one-layer slab.
	if (d.x1 == nil and d.foot ~= nil) then
		local f = d.foot;
		local x1, y1, x2, y2;
		if (f.shape == "circle") then
			x1, y1, x2, y2 = f.cx-f.r, f.cy-f.r, f.cx+f.r, f.cy+f.r;
		else
			x1, y1, x2, y2 = f.x1, f.y1, f.x2, f.y2;
		end
		log("world_editor: elevator #%s uses the old footprint format; loaded as a plain slab",
		    tostring(d.id));
		d = {x1=x1, y1=y1, x2=x2, y2=y2, z1=d.zlo, z2=d.zlo,
		     dir=d.dir, zlo=d.zlo, zhi=d.zhi};
	end

	local inst = {
		x1=d.x1, y1=d.y1, z1=d.z1, x2=d.x2, y2=d.y2, z2=d.z2,
		dir=d.dir,
	};

	-- New elevators were clamped at placement, so this only bites a
	-- hand-edited layout. The drawing is indexed by the box, so a box that
	-- moves invalidates it.
	local cells = d.cells;
	if (inst.z2 > we.deepest) then inst.z2 = we.deepest; cells = nil; end
	if (inst.z1 > inst.z2) then inst.z1 = inst.z2; cells = nil; end
	inst.T = inst.z2 - inst.z1 + 1;

	inst.zlo, inst.zhi = d.zlo, d.zhi;
	local floor_top = we.deepest - (inst.T - 1);
	if (inst.zhi > floor_top) then inst.zhi = floor_top; end
	if (inst.zlo > inst.zhi) then inst.zlo = inst.zhi; end
	if (inst.zlo < 0) then inst.zlo = 0; end

	-- centre, for the nearest-component search /componentperm does; every
	-- instance owes the framework one of these
	inst.x = math.floor((inst.x1 + inst.x2) / 2);
	inst.y = math.floor((inst.y1 + inst.y2) / 2);

	-- The captured drawing, if this elevator has one. Kept on the instance
	-- only once it has proved to describe this box, so a stencil we
	-- refused to draw is not written back out on the next save either.
	local occ, n;
	if (cells ~= nil) then
		local pal = stencil.decode_pal(d.pal);
		local why;
		if (pal == nil) then
			why = "its palette is not a list of rrggbb strings";
		else
			occ, why = decode_occ(inst, #pal, cells);
		end
		if (occ == nil) then
			log("world_editor: elevator at %d,%d has an unusable drawing (%s); using a plain slab",
			    inst.x1, inst.y1, tostring(why));
		else
			n = why;                       -- decode_occ's second return: cell count
			inst.pal = pal;
			inst.palhex, inst.cells = d.pal, cells;
		end
	end
	if (occ == nil) then
		occ, n = full_occ(inst);
	end
	inst.occ, inst.ncells = occ, n;

	inst.silh = silhouette(inst);

	-- A fixed one-block inset is a fraction of a wide platform and all of
	-- a narrow one, so the column read as "stacked platforms" on big pads
	-- and vanished on small ones. Scale it with the pad instead, always
	-- leaving the piston at least one block narrower, and nil when there
	-- is no room to inset at all.
	local half = math.min(inst.x2 - inst.x1, inst.y2 - inst.y1) / 2;
	local target = math.floor(half * we_elevator_piston);
	if (target < 1) then target = 1; end
	if (target > half - 1) then target = half - 1; end
	inst.piston = (target >= 1)
	          and erode(inst.silh, math.floor(half - target),
	                    inst.x1, inst.y1, inst.x2, inst.y2)
	           or nil;

	inst.coreidx = core_of(inst);
	inst.bycol = bycolour_of(inst);
	inst.motion = {[-1] = motion_for(inst, -1), [1] = motion_for(inst, 1)};

	inst.z = rest_z(inst);      -- current top layer of the platform
	inst.state = "rest";        -- rest | going | holding | returning
	inst.t = 0;
	inst.hold = 0;
	return inst;
end

function E.save(inst)
	return {x1=inst.x1, y1=inst.y1, z1=inst.z1,
	        x2=inst.x2, y2=inst.y2, z2=inst.z2,
	        dir=inst.dir, zlo=inst.zlo, zhi=inst.zhi,
	        pal=inst.palhex, cells=inst.cells};
end

-- ---------------------------------------------------------------- draw

-- a captured platform draws each cell in the colour it was built in; a
-- plain one is all the placer's colour, which is not known until the
-- framework has set inst.color, and that happens after spawn
local function colour_of(inst, we, cidx)
	if (inst.pal == nil) then
		return we.tint(inst, RED);
	end
	return inst.pal[cidx];
end

-- Issue one bulk write for a group of cells spread over several layers.
--
-- `byr` maps a layer offset (relative to `basez`) to the cells wanted on
-- it. The call covers the whole z range those layers occupy and a keep
-- predicate picks the cells out of it, so the write is ONE we.fill /
-- we.paint: one block-colour packet for the group, and for a clear one
-- floating-block cull for the group, rather than one of each per layer.
local function span(inst, we, byr, basez, color, mode)
	local z1, z2;
	for r in pairs(byr) do
		local z = basez + r;
		if (z1 == nil or z < z1) then z1 = z; end
		if (z2 == nil or z > z2) then z2 = z; end
	end
	if (z1 == nil) then return; end

	local function keep(x, y, z)
		local s = byr[z - basez];
		return s ~= nil and s[kxy(x, y)] ~= nil;
	end

	if (mode == "paint") then
		we.paint(inst, inst.x1, inst.y1, z1, inst.x2, inst.y2, z2, color, keep);
	else
		we.fill(inst, inst.x1, inst.y1, z1, inst.x2, inst.y2, z2,
		        color, mode == "build", keep);
	end
end

-- the whole structure at platform-top zt: the pad, one call per colour,
-- and the piston column beneath it in one more
local function draw_all(inst, we, zt)
	for cidx, byr in pairs(inst.bycol) do
		span(inst, we, byr, zt, colour_of(inst, we, cidx), "build");
	end

	local top, bot = zt + inst.T, shaft_bottom(inst);
	if (inst.piston ~= nil and top <= bot) then
		local p = inst.piston;
		we.fill(inst, inst.x1, inst.y1, top, inst.x2, inst.y2, bot,
		        colour_of(inst, we, inst.coreidx), true,
		        function(x, y, z) return p[kxy(x, y)] ~= nil; end);
	end
end

function E.render(inst, we)
	-- clear the shaft so the platform has a free path (bulk: one cull for
	-- the whole column), then lay the structure down at its resting layer
	local silh = inst.silh;
	we.dig_box(inst.x1, inst.y1, shaft_top(inst),
	           inst.x2, inst.y2, shaft_bottom(inst),
	           function(x, y) return silh[kxy(x, y)] ~= nil; end);

	draw_all(inst, we, inst.z);
end

-- The whole structure comes down in one we.fill over the shaft, wherever
-- the platform happens to be: clears go through the bulk-destroy path,
-- which culls floating blocks once per call, and only cells the elevator
-- owns are touched. /savemap and /delete both destroy every component,
-- so this is the hot path for them.
function E.destroy(inst, we)
	we.fill(inst, inst.x1, inst.y1, shaft_top(inst),
	        inst.x2, inst.y2, shaft_bottom(inst), nil, false, nil);
end

-- the full column the platform sweeps, plus headroom above the top stop
function E.reserved(inst, we)
	return areas.box(inst.x1, inst.y1, shaft_top(inst),
	                 inst.x2, inst.y2, shaft_bottom(inst));
end

-- ---------------------------------------------------------------- trigger

-- The platform's footprint plus rider headroom, sliding with it. The
-- volume is cached and its z span mutated in place: this is asked 60
-- times a second per elevator, so building a fresh area table each time
-- was pure garbage.
local function rider_area(inst, we)
	local a = inst.trigger;
	if (a == nil) then
		a = areas.box(inst.x1, inst.y1, inst.z - RIDER_REACH,
		              inst.x2, inst.y2, inst.z);
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

-- what /components reports for an elevator
function E.status(inst, we)
	return string.format("%s z %d (%d..%d) x%d %s %d cells%s riders %s",
	                     inst.dir, inst.z, inst.zlo, inst.zhi, inst.T,
	                     inst.state, inst.ncells,
	                     inst.pal and "" or " (plain)",
	                     tostring(has_riders(inst, we)));
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

-- Move the structure one layer.
--
-- The rider must never see a moment with no floor, or client-side
-- physics drops them through: everything that arrives is written before
-- anything is taken away, and the teleport happens in the safe order for
-- the direction. Position, block-build and block-destroy are all
-- reliable and ordered, so the client applies them exactly as sent.
local function step(inst, we, dz)
	local from = inst.z;
	local riding = riders(inst, we);  -- detect before anything moves
	local m = inst.motion[dz];

	inst.z = from + dz;

	-- rising: lift the riders first, so the new layer is built under feet
	-- that have already moved
	if (dz < 0) then
		carry(inst, riding, dz);
	end

	for cidx, byr in pairs(m.build) do
		span(inst, we, byr, from, colour_of(inst, we, cidx), "build");
	end
	for cidx, byr in pairs(m.paint) do
		span(inst, we, byr, from, colour_of(inst, we, cidx), "paint");
	end
	if (m.clear ~= nil) then
		span(inst, we, m.clear, from, nil, "clear");
	end

	-- descending: the new floor is already down, so it is safe to drop
	-- the riders onto it now
	if (dz > 0) then
		carry(inst, riding, dz);
	end
end

-- Leave the map holding exactly what the builder put there: the pad,
-- back at the altitude it was built at, and nothing else.
--
-- Called when the elevator is being un-placed but its blocks are being
-- handed back (see release_component in world_editor.lua). Two things
-- have to happen and they have to happen together:
--
--   * the pad returns to its resting altitude, or an elevator deleted
--     mid-ride would strand its platform halfway up the shaft as
--     permanent terrain;
--   * the piston column goes, because unlike the pad it was never in
--     the map before -- the elevator drew it -- so leaving it would turn
--     the shaft into a solid pillar.
--
-- Done as ONE diff of "everything we own now" against "pad at rest, no
-- column", rather than settling and then taking the column down: that
-- keeps the three sets disjoint, so no cell is written twice in the tick
-- -- in particular none is created and then destroyed again. The loop
-- walks the whole shaft, which is fine for something that happens once.
function E.settle(inst, we)
	local from = inst.z;
	local dz = rest_z(inst) - from;

	local build, paint, clear = {}, {}, {};
	local nc = 0;

	local function put(t, cidx, r, k)
		local byr = t[cidx];
		if (byr == nil) then byr = {}; t[cidx] = byr; end
		local s = byr[r];
		if (s == nil) then s = {}; byr[r] = s; end
		s[k] = true;
	end

	for r = shaft_top(inst) - from, shaft_bottom(inst) - from do
		for k in pairs(inst.silh) do
			local a = state(inst, r, k, false);        -- what stands there now
			local b = state(inst, r - dz, k, true);    -- pad at rest, no column
			if (a ~= b) then
				if (b == nil) then
					local s = clear[r];
					if (s == nil) then s = {}; clear[r] = s; end
					s[k] = true; nc = nc + 1;
				elseif (a == nil) then
					put(build, b, r, k);
				else
					put(paint, b, r, k);
				end
			end
		end
	end

	inst.z = rest_z(inst);

	for cidx, byr in pairs(build) do
		span(inst, we, byr, from, colour_of(inst, we, cidx), "build");
	end
	for cidx, byr in pairs(paint) do
		span(inst, we, byr, from, colour_of(inst, we, cidx), "paint");
	end
	if (nc > 0) then
		span(inst, we, clear, from, nil, "clear");
	end

	inst.state = "rest";
	inst.t = 0;
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
