-- world_editor/door.lua -- A built surface that slides aside to open.
--
-- Placement: /place door up|down|left|right
--   mark 1 -- one corner of the door box
--   mark 2 -- the opposite corner
--
-- The box is not a blank panel: whatever is already built inside it IS
-- the door. Every solid cell is captured with the colour it already has
-- and every empty cell stays empty, so a door can carry an arbitrary
-- drawing -- a window, a hatch, a logo -- and keeps it as it moves.
-- Build the shape first (by hand, or with sel's /selfill and /selpaint),
-- then mark two opposite corners around it.
--
-- Mark a box with nothing in it and you get a plain solid panel in your
-- block palette colour instead, which is what a door always used to be.
--
-- The panel moves as one rigid piece. It does not dissolve row by row:
-- every block travels one step together, so the drawing stays whole and
-- readable the entire way, and holes in it travel along with it.
--
-- Direction is the way the panel slides:
--   up     into the ceiling  (the gap opens from the floor up)
--   down   into the floor    (the gap opens from the top down)
--   left   toward the low side
--   right  toward the high side
--
-- up/down slide along z; left/right slide along whichever horizontal
-- axis the door is widest on, so a door laid out along x slides in x and
-- one laid out along y slides in y.
--
-- Because it slides rather than dissolves, it needs somewhere to go: a
-- pocket as deep as the panel is thick in that direction. That pocket is
-- dug out of the terrain at placement and reserved, exactly as the
-- elevator digs its shaft, and a door with no room for one is refused
-- rather than placed half-working.
--
-- It opens while anyone stands near it and closes once they leave, so a
-- door needs no switch -- walking up to it is the trigger.
--
-- One step moves the panel by one block, and a step only writes the
-- blocks that actually change: the cells at the leading face of the
-- drawing (which arrive one block further on) and the cells at its
-- trailing face (which are given up). Everything between is already the
-- right block in the right place. That is what keeps a big door from
-- dumping hundreds of block updates into a single tick, and it is the
-- same overlap trick the elevator uses -- see the block api in
-- world_editor.lua for why re-sending an unchanged cell is not free.
--
-- The map's z axis points *down*: z1 is the top row, z2 the bottom.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local D = {name = "door"};

local areas = require "world_editor.areas";

getcfg("we_door_speed", 8);     -- blocks moved per second
getcfg("we_door_range", 4);     -- how close a player must be, in blocks

-- default panel colour, used for a door placed on an empty box when the
-- placer's palette read fails too
local GREY = {r=170, g=170, b=185};

local DIRS = {up=true, down=true, left=true, right=true};

D.desc  = "a built surface that slides aside when someone is near.";
D.usage = "<up|down|left|right>";
D.help  = {
	"world_editor: door -- a built surface that slides open when a player nears it.",
	"  usage: /place door <up|down|left|right>",
	"  up/down slide into ceiling/floor; left/right slide aside.",
	"  build the shape first, then mark two opposite corners around it:",
	"  its blocks, colours and gaps all become the door and move together.",
	"  it needs its own depth of clear space to slide into.",
	"  an empty box gives a solid panel in your palette colour instead.",
};

-- --------------------------------------------------------------- stencil
--
-- The drawing is stored in the layout json rather than in the map,
-- because /savemap takes every component down before dumping the .vxl --
-- so the terrain on disk has a door-shaped hole in it and this is the
-- only record of what used to be there.
--
-- It is kept small enough to live comfortably in that json: a palette of
-- the distinct colours, plus one run-length string over the box in
-- z,y,x order, each run written "<count>*<palette index>" with index 0
-- meaning empty. A door of a few hundred cells in a handful of colours
-- comes to a couple of hundred bytes.

-- Key for a cell within one plane of the panel: the two coordinates the
-- slide axis does not use. Those two never change as the panel travels,
-- which is what lets one key set describe a face of the drawing wherever
-- it currently is. z tops out at 63 and x/y at 511, so this packs
-- cleanly.
local function okey(axis, x, y, z)
	if (axis == "z") then return y*512 + x; end
	if (axis == "x") then return z*512 + y; end
	return z*512 + x;
end

-- Read the box out of the live map: which cells are solid, and what
-- colour each solid one carries. This has to run before D.render digs
-- the box, because digging is exactly what turns that terrain into
-- blocks the door owns.
--
-- get_map_block_color reads colorData straight (lsd/src/lua.c
-- get_map_block_color), so it means nothing for a cell that is not
-- solid -- hence reading it only behind is_solid.
--
-- Returns nil for a box with nothing in it, which is the caller's cue to
-- fall back to a plain solid panel.
local function capture(x1, y1, z1, x2, y2, z2)
	local pal, index, runs = {}, {}, {};
	local prev, count, solid = nil, 0, 0;

	for z = z1, z2 do
		for y = y1, y2 do
			for x = x1, x2 do
				local idx = 0;
				if (is_solid({x=x, y=y, z=z})) then
					local c = get_map_block_color({x=x, y=y, z=z});
					local hex = string.format("%02x%02x%02x", c.r, c.g, c.b);
					idx = index[hex];
					if (idx == nil) then
						table.insert(pal, hex);
						idx = #pal;
						index[hex] = idx;
					end
					solid = solid + 1;
				end

				if (idx == prev) then
					count = count + 1;
				else
					if (prev ~= nil) then
						table.insert(runs, count.."*"..prev);
					end
					prev, count = idx, 1;
				end
			end
		end
	end
	if (prev ~= nil) then
		table.insert(runs, count.."*"..prev);
	end

	if (solid == 0) then
		return nil;
	end
	return pal, table.concat(runs, ",");
end

local function decode_pal(pal)
	if (type(pal) ~= "table") then
		return nil;
	end
	local out = {};
	for i, s in ipairs(pal) do
		if (type(s) ~= "string" or string.len(s) ~= 6) then
			return nil;
		end
		local r = tonumber(string.sub(s, 1, 2), 16);
		local g = tonumber(string.sub(s, 3, 4), 16);
		local b = tonumber(string.sub(s, 5, 6), 16);
		if (r == nil or g == nil or b == nil) then
			return nil;
		end
		out[i] = {r=r, g=g, b=b};
	end
	return out;
end

-- ------------------------------------------------------------- geometry

-- which axis the panel slides along, and its span on that axis
local function axis_of(d)
	if (d.dir == "up" or d.dir == "down") then
		return "z", d.z1, d.z2;
	end
	if ((d.x2 - d.x1) >= (d.y2 - d.y1)) then
		return "x", d.x1, d.x2;
	end
	return "y", d.y1, d.y2;
end

-- Which way along that axis the panel travels when it opens. "down" and
-- "right" run toward the high end, "up" and "left" toward the low one --
-- and remember z points down, so "up" (into the ceiling) is -1.
local function step_of(dir)
	if (dir == "down" or dir == "right") then
		return 1;
	end
	return -1;
end

-- The axis span the panel sweeps: its own extent plus the pocket it
-- retracts into, which is as deep as the panel is thick.
local function sweep(lo, hi, step, travel)
	if (step > 0) then
		return lo, hi + travel;
	end
	return lo - travel, hi;
end

-- The furthest end of that sweep has to stay on the map -- and, on z,
-- above the engine floor and the client's Root layer, the same limit
-- every component writes under.
local function sweep_fits(axis, lo, hi, step, travel, we)
	local s1, s2 = sweep(lo, hi, step, travel);
	local top = (axis == "z") and we.deepest or 511;
	return s1 >= 0 and s2 <= top;
end

-- local index i of a plane -> the axis coordinate it sits at when the
-- panel is `off` blocks open
local function plane_at(inst, i, off)
	return inst.lo + i + off * inst.step;
end

-- ------------------------------------------------------------ placement

function D.start(pid, args)
	local dir = string.lower(args[1] or "");
	if (not DIRS[dir]) then
		return nil, "direction must be up, down, left or right.";
	end
	return {dir=dir, pts={}, data=nil,
	        prompt="mark one corner of the door."};
end

function D.click(s, pos, we)
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

	-- Keep the panel off the engine floor and the client's Root layer,
	-- the same clamp the elevator applies. This has to happen HERE rather
	-- than at spawn: the drawing is indexed by the box, so the box must
	-- be final before a single cell is read out of it.
	if (d.z2 > we.deepest) then d.z2 = we.deepest; end
	if (d.z1 > d.z2) then d.z1 = d.z2; end

	-- the panel has to have extent along whichever way it slides,
	-- otherwise there is nothing to move out of the way
	if (s.dir == "up" or s.dir == "down") then
		if (d.z1 == d.z2) then
			s.pts = {a};
			return false, "a vertical door needs height -- mark corners at different heights.";
		end
	elseif (d.x1 == d.x2 and d.y1 == d.y2) then
		s.pts = {a};
		return false, "a sliding door needs width -- mark corners apart horizontally.";
	end

	-- It slides as one piece, so it needs a pocket its own depth to slide
	-- into. Refuse rather than place a door that can only open part way:
	-- a doorway you cannot walk through is worse than no door at all.
	local axis, lo, hi = axis_of(d);
	local step = step_of(s.dir);
	local travel = hi - lo + 1;
	if (not sweep_fits(axis, lo, hi, step, travel, we)) then
		local s1, s2 = sweep(lo, hi, step, travel);
		s.pts = {a};
		return false, string.format(
			"no room to slide %s: it needs %s %d..%d clear, and the map ends there. "
			.."place it further from the edge, or slide it another way.",
			s.dir, axis, s1, s2);
	end

	-- Another component's blocks must not be swallowed. D.render digs the
	-- whole sweep to claim it, which would tear a hole through whatever
	-- else lives in there while that component still believed it was
	-- intact.
	local sx1, sy1, sz1 = d.x1, d.y1, d.z1;
	local sx2, sy2, sz2 = d.x2, d.y2, d.z2;
	if (axis == "z") then sz1, sz2 = sweep(lo, hi, step, travel);
	elseif (axis == "x") then sx1, sx2 = sweep(lo, hi, step, travel);
	else sy1, sy2 = sweep(lo, hi, step, travel); end

	for z = sz1, sz2 do
		for y = sy1, sy2 do
			for x = sx1, sx2 do
				if (we.is_guarded(x, y, z)) then
					s.pts = {a};
					return false, "that door (or the space it slides into) overlaps another component.";
				end
			end
		end
	end

	d.pal, d.cells = capture(d.x1, d.y1, d.z1, d.x2, d.y2, d.z2);

	s.data = d;
	return true;
end

-- ------------------------------------------------------------- lifecycle

-- Expand the run-length cells into occupancy: for each plane of the
-- panel, which cells are solid and what colour each is. Returns nil plus
-- a reason when the stencil does not describe this box, so a mismatch
-- draws a plain panel instead of a misaligned mess.
local function decode_occ(inst, npal, cells)
	local w = inst.x2 - inst.x1 + 1;
	local h = inst.y2 - inst.y1 + 1;
	local plane = w * h;
	local total = plane * (inst.z2 - inst.z1 + 1);
	local axis = inst.axis;

	local occ, i, n = {}, 0, 0;

	for count, idx in string.gmatch(cells, "(%d+)%*(%d+)") do
		count, idx = tonumber(count), tonumber(idx);
		if (i + count > total) then
			return nil, "more cells than the box holds";
		end

		if (idx ~= 0) then
			if (idx > npal) then
				return nil, "a run names colour "..idx..", which is not in the palette";
			end
			for c = i, i + count - 1 do
				-- capture walked z, then y, then x; unwind that
				local x = inst.x1 + (c % w);
				local y = inst.y1 + (math.floor(c / w) % h);
				local z = inst.z1 + math.floor(c / plane);
				local li = (axis == "z") and (z - inst.z1)
				        or ((axis == "x") and (x - inst.x1) or (y - inst.y1));

				local o = occ[li];
				if (o == nil) then o = {}; occ[li] = o; end
				o[okey(axis, x, y, z)] = idx;
				n = n + 1;
			end
		end
		i = i + count;
	end

	if (i ~= total) then
		return nil, string.format("%d cells for a box of %d", i, total);
	end
	return occ, n;
end

-- Occupancy for a door placed on an empty box: every cell solid, in the
-- one colour the placer was holding. Building it here rather than
-- special-casing it everywhere means the motion code below only ever
-- deals with one representation.
local function full_occ(inst)
	local occ, n = {}, 0;
	for z = inst.z1, inst.z2 do
		for y = inst.y1, inst.y2 do
			for x = inst.x1, inst.x2 do
				local li = (inst.axis == "z") and (z - inst.z1)
				        or ((inst.axis == "x") and (x - inst.x1) or (y - inst.y1));
				local o = occ[li];
				if (o == nil) then o = {}; occ[li] = o; end
				o[okey(inst.axis, x, y, z)] = 1;
				n = n + 1;
			end
		end
	end
	return occ, n;
end

-- Work out what a one-block move actually has to write.
--
-- Slide the drawing one block along its axis and most of its cells land
-- where another of its own cells already was. The block is already there
-- and already solid -- but it may be the wrong COLOUR, because the cell
-- that used to sit there is a different cell of the drawing. That is the
-- part a uniform panel never has to think about and a drawing always
-- does.
--
-- So for a move of `mv` (one block along the axis, either way) each cell
-- of the panel falls into exactly one of three jobs:
--
--   build  -- nothing of ours was at its destination, so a real block
--             has to appear there
--   paint  -- one of our blocks was already there but in another colour,
--             so it only needs recolouring (we.paint, a build packet
--             over a solid cell -- never a destroy plus a create on one
--             cell in one tick)
--   clear  -- nothing of ours follows it, so the cell it leaves behind
--             becomes empty
--
-- and cells whose destination already holds the right colour are not
-- touched at all, which is what keeps a big door off the packet budget.
--
-- The three sets are pairwise disjoint: a build target was empty before
-- the move, a clear target is empty after it, and a paint target is
-- occupied throughout. So no cell is written twice in a step, whichever
-- way the door is going.
--
-- Precomputed once per direction, since a door only ever moves by one
-- block and only ever two ways.
local function motion_for(inst, occ, mv)
	local m = {};

	for i = 0, inst.len - 1 do
		local o = occ[i];
		if (o ~= nil) then
			local onto = occ[i + mv];   -- what is at our destination now
			local after = occ[i - mv];  -- what takes our place when we go

			local build, paint, clear = {}, {}, {};
			local nb, np, nc = 0, 0, 0;

			for k, cidx in pairs(o) do
				local was = onto and onto[k];
				if (was == nil) then
					local s = build[cidx];
					if (s == nil) then s = {}; build[cidx] = s; end
					s[k] = true; nb = nb + 1;
				elseif (was ~= cidx) then
					local s = paint[cidx];
					if (s == nil) then s = {}; paint[cidx] = s; end
					s[k] = true; np = np + 1;
				end

				if (after == nil or after[k] == nil) then
					clear[k] = true; nc = nc + 1;
				end
			end

			if (nb > 0 or np > 0 or nc > 0) then
				m[i] = {build=(nb > 0) and build or nil,
				        paint=(np > 0) and paint or nil,
				        clear=(nc > 0) and clear or nil};
			end
		end
	end

	return m;
end

-- every cell of each plane, by colour -- what a full draw needs
local function planes_of(inst, occ)
	local plane = {};
	for i = 0, inst.len - 1 do
		local o = occ[i];
		if (o ~= nil) then
			local byc = {};
			for k, cidx in pairs(o) do
				local s = byc[cidx];
				if (s == nil) then s = {}; byc[cidx] = s; end
				s[k] = true;
			end
			plane[i] = byc;
		end
	end
	return plane;
end

function D.spawn(d, we)
	local inst = {
		x1=d.x1, y1=d.y1, z1=d.z1,
		x2=d.x2, y2=d.y2, z2=d.z2,
		dir=d.dir,
	};

	-- New doors were clamped at placement, so this only ever bites a
	-- layout hand-edited (or written when we.deepest was different). The
	-- drawing is indexed by the box, so a box that moves invalidates it.
	local cells = d.cells;
	if (inst.z2 > we.deepest) then inst.z2 = we.deepest; cells = nil; end
	if (inst.z1 > inst.z2) then inst.z1 = inst.z2; cells = nil; end
	if (cells == nil and d.cells ~= nil) then
		log("world_editor: door at %d,%d had to be clamped to z<=%d; its drawing no longer fits, using a solid panel",
		    inst.x1, inst.y1, we.deepest);
	end

	-- centre, for the nearest-component search /componentperm does; every
	-- instance owes the framework one of these
	inst.x = math.floor((inst.x1 + inst.x2) / 2);
	inst.y = math.floor((inst.y1 + inst.y2) / 2);

	inst.axis, inst.lo, inst.hi = axis_of(inst);
	inst.step = step_of(inst.dir);
	inst.len  = inst.hi - inst.lo + 1;

	-- Placement refuses a door with nowhere to slide, so this only trims
	-- a hand-edited layout. Opening part way is the graceful failure --
	-- better than writing off the map.
	inst.travel = inst.len;
	while (inst.travel > 0
	       and not sweep_fits(inst.axis, inst.lo, inst.hi, inst.step, inst.travel, we)) do
		inst.travel = inst.travel - 1;
	end
	if (inst.travel < inst.len) then
		log("world_editor: door at %d,%d has room to slide only %d of %d blocks",
		    inst.x1, inst.y1, inst.travel, inst.len);
	end

	local s1, s2 = sweep(inst.lo, inst.hi, inst.step, inst.travel);
	inst.sx1, inst.sy1, inst.sz1 = inst.x1, inst.y1, inst.z1;
	inst.sx2, inst.sy2, inst.sz2 = inst.x2, inst.y2, inst.z2;
	if (inst.axis == "z") then inst.sz1, inst.sz2 = s1, s2;
	elseif (inst.axis == "x") then inst.sx1, inst.sx2 = s1, s2;
	else inst.sy1, inst.sy2 = s1, s2; end

	-- The captured drawing, if this door has one. Kept on the instance
	-- only once it has proved to describe this box, so a stencil we
	-- refused to draw is not written back out on the next save either.
	local occ, n;
	if (cells ~= nil) then
		local pal = decode_pal(d.pal);
		local why;
		if (pal == nil) then
			why = "its palette is not a list of rrggbb strings";
		else
			occ, why = decode_occ(inst, #pal, cells);
		end
		if (occ == nil) then
			log("world_editor: door at %d,%d has an unusable drawing (%s); using a solid panel",
			    inst.x1, inst.y1, tostring(why));
		else
			n = why;                       -- decode_occ's second return: cell count
			inst.pal = pal;                -- runtime colours
			inst.palhex, inst.cells = d.pal, cells;   -- what goes back to json
		end
	end
	if (occ == nil) then
		occ, n = full_occ(inst);
	end
	inst.ncells = n;

	inst.plane = planes_of(inst, occ);
	-- one table per way the panel can travel along its axis
	inst.motion = {[1] = motion_for(inst, occ, 1),
	               [-1] = motion_for(inst, occ, -1)};

	inst.off = 0;       -- how many blocks the panel has slid; 0 is shut
	inst.t = 0;
	return inst;
end

function D.save(inst)
	return {x1=inst.x1, y1=inst.y1, z1=inst.z1,
	        x2=inst.x2, y2=inst.y2, z2=inst.z2, dir=inst.dir,
	        pal=inst.palhex, cells=inst.cells};
end

-- ---------------------------------------------------------------- draw

-- a captured door draws each cell in the colour it was built in; a door
-- placed on empty air is all one colour, and that colour is not known
-- until the framework has set inst.color, which happens after spawn
local function colour_of(inst, we, cidx)
	if (inst.pal == nil) then
		return we.tint(inst, GREY);
	end
	return inst.pal[cidx];
end

-- Draw (or clear) the cells named by `set` on one plane of the panel.
-- The panel only ever moves along its own axis, so the other two extents
-- are those of the box no matter how far it has slid; only the axis
-- coordinate is passed in.
local function fill_plane(inst, we, a, color, on, set)
	local x1, x2 = inst.x1, inst.x2;
	local y1, y2 = inst.y1, inst.y2;
	local z1, z2 = inst.z1, inst.z2;

	if (inst.axis == "z") then z1, z2 = a, a;
	elseif (inst.axis == "x") then x1, x2 = a, a;
	else y1, y2 = a, a; end

	local axis = inst.axis;
	we.fill(inst, x1, y1, z1, x2, y2, z2, color, on, set and function(x, y, z)
		return set[okey(axis, x, y, z)] ~= nil;
	end or nil);
end

-- the whole panel, wherever it currently sits
local function draw_panel(inst, we, off)
	for i = 0, inst.len - 1 do
		local byc = inst.plane[i];
		if (byc ~= nil) then
			local a = plane_at(inst, i, off);
			for cidx, set in pairs(byc) do
				fill_plane(inst, we, a, colour_of(inst, we, cidx), true, set);
			end
		end
	end
end

-- recolour, in place, cells the door already owns (see we.paint)
local function paint_plane(inst, we, a, color, set)
	local x1, x2 = inst.x1, inst.x2;
	local y1, y2 = inst.y1, inst.y2;
	local z1, z2 = inst.z1, inst.z2;

	if (inst.axis == "z") then z1, z2 = a, a;
	elseif (inst.axis == "x") then x1, x2 = a, a;
	else y1, y2 = a, a; end

	local axis = inst.axis;
	we.paint(inst, x1, y1, z1, x2, y2, z2, color, function(x, y, z)
		return set[okey(axis, x, y, z)] ~= nil;
	end);
end

-- Move the panel one block: build what has to appear, recolour what is
-- already in place but wrong, and clear what is left behind. See
-- motion_for for how those three sets are worked out and why they never
-- overlap.
--
-- Arrivals and recolours go first, departures last. The sets never share
-- a cell so the order is not a correctness requirement, but it means the
-- panel is never momentarily thinner than it should be -- and a door is
-- something players walk into.
local function step(inst, we, delta)
	local from = inst.off;
	local to = from + delta;
	-- position is lo + i + off*step, so an offset change of `delta` moves
	-- the panel delta*step blocks along the axis
	local m = inst.motion[delta * inst.step];

	for i = 0, inst.len - 1 do
		local e = m[i];
		if (e ~= nil) then
			local a = plane_at(inst, i, to);
			if (e.build ~= nil) then
				for cidx, set in pairs(e.build) do
					fill_plane(inst, we, a, colour_of(inst, we, cidx), true, set);
				end
			end
			if (e.paint ~= nil) then
				for cidx, set in pairs(e.paint) do
					paint_plane(inst, we, a, colour_of(inst, we, cidx), set);
				end
			end
		end
	end

	for i = 0, inst.len - 1 do
		local e = m[i];
		if (e ~= nil and e.clear ~= nil) then
			fill_plane(inst, we, plane_at(inst, i, from), nil, false, e.clear);
		end
	end

	inst.off = to;
end

-- ------------------------------------------------------------- lifecycle

-- A door has to OWN every cell of its panel, or it cannot move them.
-- we.fill never paints over a solid cell (that is what stops it painting
-- without breaking), so a door laid against existing terrain claimed
-- nothing at all: its state machine opened and closed happily while zero
-- blocks moved, which reads as a completely dead door.
--
-- So clear the whole sweep first -- the panel's own footprint and the
-- pocket it slides into -- exactly as the elevator clears its shaft, and
-- only then lay the panel down. For a captured door the footprint holds
-- the very blocks that were just read: digging them and drawing them
-- back is what converts somebody's build into a component. dig_box skips
-- cells we already own, so a re-render is not a destroy-rebuild cycle.
-- D.reserved keeps the sweep ours afterwards.
function D.render(inst, we)
	we.dig_box(inst.sx1, inst.sy1, inst.sz1, inst.sx2, inst.sy2, inst.sz2);
	draw_panel(inst, we, inst.off);
end

-- The whole panel comes down in one we.fill over the sweep, wherever it
-- happens to be sitting: clears go through the bulk-destroy path, which
-- culls floating blocks once per call, and only cells the door owns are
-- touched. /savemap and /delete both destroy every component, so this is
-- the hot path for them.
function D.destroy(inst, we)
	we.fill(inst, inst.sx1, inst.sy1, inst.sz1,
	        inst.sx2, inst.sy2, inst.sz2, nil, false, nil);
end

-- ---------------------------------------------------------------- trigger

-- The doorway fattened by we_door_range, so someone walking up to either
-- face sets it off. This is the shut box, not the sweep: the pocket is
-- usually buried in a wall or a floor, and someone standing on the far
-- side of that wall is not at the door.
local function near_area(inst)
	if (inst.trigger == nil) then
		local r = we_door_range;
		inst.trigger = areas.box(inst.x1-r, inst.y1-r, inst.z1-r,
		                         inst.x2+r, inst.y2+r, inst.z2+r);
	end
	return inst.trigger;
end

-- Nobody may build inside the doorway or the pocket behind it: a block
-- left in the way would be one we.fill refuses to paint over (it never
-- paints over solid), so the panel would arrive with a hole in it and
-- never recover. The gaps in the drawing are reserved too -- filling
-- those in would wall up a window the door is supposed to carry.
function D.reserved(inst)
	return areas.box(inst.sx1, inst.sy1, inst.sz1,
	                 inst.sx2, inst.sy2, inst.sz2);
end

-- what /components reports for a door
function D.status(inst, we)
	return string.format("%s %s %d..%d open %d/%d %d cells%s near %s",
	                     inst.dir, inst.axis, inst.lo, inst.hi,
	                     inst.off, inst.travel, inst.ncells,
	                     inst.pal and "" or " (plain)",
	                     tostring(areas.any_player_in(near_area(inst))));
end

-- ------------------------------------------------------------------ tick

function D.tick(inst, we, dt)
	local want = areas.any_player_in(near_area(inst)) and inst.travel or 0;

	if (inst.off == want) then
		inst.t = 0;
		return;
	end

	if (not we.due(inst, "t", we_door_speed, dt)) then
		return;
	end

	-- exactly one block per step, and only the faces that change are
	-- touched: redrawing the whole panel every step would be a block storm
	step(inst, we, (inst.off < want) and 1 or -1);
end

return D;
