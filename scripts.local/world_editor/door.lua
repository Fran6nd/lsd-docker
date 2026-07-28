-- world_editor/door.lua -- A built surface that retracts to open.
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
-- It is a RETRACTABLE door, so the box it was marked in is also its
-- frame: only the part of the panel still inside that box is drawn, and
-- whatever has slid out of it is not drawn at all. The panel retracts
-- into the frame and is gone -- no pocket has to be dug behind it,
-- nothing outside the doorway is ever touched, and a door can sit hard
-- against a wall, a ceiling or the bottom of the map with no room to
-- spare. A door sinking into the floor passes under the deepest layer we
-- may write and simply stops being drawn, which is what sinking into the
-- floor looks like anyway.
--
-- Direction is the way the panel retracts:
--   up     into the ceiling  (the gap opens from the floor up)
--   down   into the floor    (the gap opens from the top down)
--   left   toward the low side
--   right  toward the high side
--
-- up/down retract along z; left/right along whichever horizontal axis
-- the door is widest on, so a door laid out along x slides in x and one
-- laid out along y slides in y.
--
-- It opens while anyone stands near it and closes once they leave, so a
-- door needs no switch -- walking up to it is the trigger.
--
-- One step moves the panel by one block, and a step only writes the
-- blocks that actually change -- see motion_for. That is what keeps a
-- big door from dumping hundreds of block updates into a single tick,
-- and it is the same overlap trick the elevator uses; see the block api
-- in world_editor.lua for why re-sending an unchanged cell is not free.
--
-- The map's z axis points *down*: z1 is the top row, z2 the bottom.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local D = {name = "door"};

local areas   = require "world_editor.areas";
local stencil = require "world_editor.stencil";

getcfg("we_door_speed", 8);     -- blocks moved per second
getcfg("we_door_range", 4);     -- how close a player must be, in blocks

-- default panel colour, used for a door placed on an empty box when the
-- placer's palette read fails too
local GREY = {r=170, g=170, b=185};

local DIRS = {up=true, down=true, left=true, right=true};

D.desc  = "a built surface that retracts into its frame when someone is near.";
D.usage = "<up|down|left|right>";
D.help  = {
	"world_editor: door -- a built surface that retracts when a player nears it.",
	"  usage: /place door <up|down|left|right>",
	"  up/down retract into ceiling/floor; left/right retract aside.",
	"  build the shape first, then mark two opposite corners around it:",
	"  its blocks, colours and gaps all become the door and move together.",
	"  the panel retracts into the marked box and needs no room behind it.",
	"  an empty box gives a solid panel in your palette colour instead.",
};

-- --------------------------------------------------------------- stencil
--
-- Reading the marked box off the map and packing it for the layout json
-- is shared with the elevator; see world_editor/stencil.lua. What is the
-- door's own is how that drawing is indexed once decoded: by plane along
-- the retract axis, so a move is a shift of plane indices.

-- Key for a cell within one plane of the panel: the two coordinates the
-- retract axis does not use. Those two never change as the panel
-- travels, which is what lets one key set describe a face of the drawing
-- wherever it currently is. z tops out at 63 and x/y at 511, so this
-- packs cleanly.
local function okey(axis, x, y, z)
	if (axis == "z") then return y*512 + x; end
	if (axis == "x") then return z*512 + y; end
	return z*512 + x;
end


-- ------------------------------------------------------------- geometry

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

-- Which way along that axis the panel travels when it opens. "down" and
-- "right" run toward the high end, "up" and "left" toward the low one --
-- and remember z points down, so "up" (into the ceiling) is -1.
local function step_of(dir)
	if (dir == "down" or dir == "right") then
		return 1;
	end
	return -1;
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

	-- the panel has to have extent along whichever way it retracts,
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

	-- Another component's blocks must not be swallowed. D.render digs the
	-- box to claim it, which would tear a hole through whatever else
	-- lives in there while that component still believed it was intact.
	-- Only the box needs checking: the panel is never drawn outside it.
	for z = d.z1, d.z2 do
		for y = d.y1, d.y2 do
			for x = d.x1, d.x2 do
				if (we.is_guarded(x, y, z)) then
					s.pts = {a};
					return false, "that box overlaps another component -- mark clear of it.";
				end
			end
		end
	end

	d.pal, d.cells = stencil.capture(d.x1, d.y1, d.z1, d.x2, d.y2, d.z2);

	s.data = d;
	return true;
end

-- ------------------------------------------------------------- lifecycle

-- Expand the run-length cells into occupancy: for each plane of the
-- panel, which cells are solid and what colour each is. Returns nil plus
-- a reason when the stencil does not describe this box, so a mismatch
-- draws a plain panel instead of a misaligned mess.
local function decode_occ(inst, npal, cells)
	local axis = inst.axis;
	local occ = {};

	local n, why = stencil.each(inst, npal, cells, function(x, y, z, cidx)
		local li = (axis == "z") and (z - inst.z1)
		        or ((axis == "x") and (x - inst.x1) or (y - inst.y1));
		local o = occ[li];
		if (o == nil) then o = {}; occ[li] = o; end
		o[okey(axis, x, y, z)] = cidx;
	end);

	if (n == nil) then
		return nil, why;
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
-- A cell whose destination already holds one of our blocks in the RIGHT
-- colour is not touched at all: the block is already there and already
-- correct, so moving the panel over it is free. Only a genuine
-- replacement -- a different colour arriving on top of what is there --
-- costs anything, and it costs one repaint rather than a destroy and a
-- rebuild.
--
-- The three sets are pairwise disjoint: a build target was empty before
-- the move, a clear target is empty after it, and a paint target is
-- occupied throughout. So no cell is written twice in a step, whichever
-- way the door is going.
--
-- Everything is keyed by COLOUR first and plane second, because that is
-- how the writes are issued: one call per colour covering every plane it
-- appears on. we.fill sends the block colour once per call (deliberately
-- -- see the block api in world_editor.lua) and ends a clear with one
-- floating-block cull, so grouping this way makes a step cost one colour
-- packet per colour and exactly one cull, instead of one of each per
-- plane.
--
-- Precomputed once per direction, since a door only ever moves by one
-- block and only ever two ways.
local function motion_for(inst, occ, mv)
	local build, paint, clear = {}, {}, {};
	local nb, np, nc = 0, 0, 0;

	-- set[cidx][i] -- cells of colour cidx on plane i
	local function put(t, cidx, i, k)
		local byplane = t[cidx];
		if (byplane == nil) then byplane = {}; t[cidx] = byplane; end
		local s = byplane[i];
		if (s == nil) then s = {}; byplane[i] = s; end
		s[k] = true;
	end

	for i = 0, inst.len - 1 do
		local o = occ[i];
		if (o ~= nil) then
			local onto = occ[i + mv];   -- what is at our destination now
			local after = occ[i - mv];  -- what takes our place when we go

			for k, cidx in pairs(o) do
				local was = onto and onto[k];
				if (was == nil) then
					put(build, cidx, i, k); nb = nb + 1;
				elseif (was ~= cidx) then
					-- something of ours is there, but the wrong colour
					put(paint, cidx, i, k); np = np + 1;
				end

				if (after == nil or after[k] == nil) then
					local s = clear[i];
					if (s == nil) then s = {}; clear[i] = s; end
					s[k] = true; nc = nc + 1;
				end
			end
		end
	end

	return {build=build, paint=paint, clear=(nc > 0) and clear or nil,
	        nbuild=nb, npaint=np, nclear=nc};
end

-- every cell of the panel, by colour then plane -- what a full draw needs
local function bycolour_of(inst, occ)
	local byc = {};
	for i = 0, inst.len - 1 do
		local o = occ[i];
		if (o ~= nil) then
			for k, cidx in pairs(o) do
				local byplane = byc[cidx];
				if (byplane == nil) then byplane = {}; byc[cidx] = byplane; end
				local s = byplane[i];
				if (s == nil) then s = {}; byplane[i] = s; end
				s[k] = true;
			end
		end
	end
	return byc;
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

	-- Moving the panel its own length puts every one of its cells past
	-- the far edge of the frame, so the doorway is completely clear. It
	-- needs no room beyond that, because nothing outside the frame is
	-- ever drawn.
	inst.travel = inst.len;

	-- The captured drawing, if this door has one. Kept on the instance
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

	inst.bycol = bycolour_of(inst, occ);
	-- one table per way the panel can travel along its axis
	inst.motion = {[1] = motion_for(inst, occ, 1),
	               [-1] = motion_for(inst, occ, -1)};

	inst.off = 0;       -- how many blocks the panel has retracted; 0 is shut
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

-- Issue one bulk write for a group of cells, however many planes of the
-- panel they are spread across.
--
-- `byplane` maps a local plane index to the cells wanted on it, and
-- `off` says where the panel is, which together give each cell its real
-- coordinate. The call covers the whole axis range those planes occupy
-- and a keep predicate picks the cells out of it, so the write is ONE
-- we.fill / we.paint: one block-colour packet for the group, and for a
-- clear one floating-block cull for the group, rather than one of each
-- per plane.
--
-- The frame is the box the door was marked in, and the panel is only
-- ever drawn inside it: planes that have retracted past either edge are
-- clipped straight off the range here. That is what makes it a
-- retractable door rather than a slab that has to be given somewhere to
-- go, it is why a door can sit flush against a ceiling, a wall or the
-- bottom of the map, and it means no write can ever land outside the
-- volume the component reserved.
local function span(inst, we, byplane, off, color, mode)
	local a1, a2;
	for i in pairs(byplane) do
		local a = plane_at(inst, i, off);
		if (a >= inst.lo and a <= inst.hi) then
			if (a1 == nil or a < a1) then a1 = a; end
			if (a2 == nil or a > a2) then a2 = a; end
		end
	end
	if (a1 == nil) then
		return;    -- every plane of this group is out of the frame
	end

	local x1, x2 = inst.x1, inst.x2;
	local y1, y2 = inst.y1, inst.y2;
	local z1, z2 = inst.z1, inst.z2;

	if (inst.axis == "z") then z1, z2 = a1, a2;
	elseif (inst.axis == "x") then x1, x2 = a1, a2;
	else y1, y2 = a1, a2; end

	-- a cell's plane index is recoverable from its axis coordinate, so
	-- one predicate serves the whole range
	local axis, base = inst.axis, inst.lo + off * inst.step;
	local function keep(x, y, z)
		local a = (axis == "z") and z or ((axis == "x") and x or y);
		local set = byplane[a - base];
		return set ~= nil and set[okey(axis, x, y, z)] ~= nil;
	end

	if (mode == "paint") then
		we.paint(inst, x1, y1, z1, x2, y2, z2, color, keep);
	else
		we.fill(inst, x1, y1, z1, x2, y2, z2, color, mode == "build", keep);
	end
end

-- the whole panel, as much of it as is still inside the frame: one call
-- per colour, whatever shape the drawing is
local function draw_panel(inst, we, off)
	for cidx, byplane in pairs(inst.bycol) do
		span(inst, we, byplane, off, colour_of(inst, we, cidx), "build");
	end
end

-- Move the panel one block: build what has to appear, recolour what is
-- already in place but wrong, and clear what is left behind. See
-- motion_for for how those three sets are worked out and why they never
-- overlap, and span for what happens to the parts that have
-- retracted out of sight.
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

	for cidx, byplane in pairs(m.build) do
		span(inst, we, byplane, to, colour_of(inst, we, cidx), "build");
	end
	for cidx, byplane in pairs(m.paint) do
		span(inst, we, byplane, to, colour_of(inst, we, cidx), "paint");
	end

	-- every departing cell in one call, so the whole step costs a single
	-- floating-block cull
	if (m.clear ~= nil) then
		span(inst, we, m.clear, from, nil, "clear");
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
-- So clear the frame first, exactly as the elevator clears its shaft,
-- and only then lay the panel down. For a captured door the frame holds
-- the very blocks that were just read: digging them and drawing them
-- back is what converts somebody's build into a component. dig_box skips
-- cells we already own, so a re-render is not a destroy-rebuild cycle.
-- D.reserved keeps the frame ours afterwards.
function D.render(inst, we)
	we.dig_box(inst.x1, inst.y1, inst.z1, inst.x2, inst.y2, inst.z2);
	draw_panel(inst, we, inst.off);
end

-- The whole panel comes down in one we.fill over the frame, wherever
-- inside it the panel happens to be sitting: clears go through the
-- bulk-destroy path, which culls floating blocks once per call, and only
-- cells the door owns are touched. /savemap and /delete both destroy
-- every component, so this is the hot path for them.
function D.destroy(inst, we)
	we.fill(inst, inst.x1, inst.y1, inst.z1,
	        inst.x2, inst.y2, inst.z2, nil, false, nil);
end

-- ---------------------------------------------------------------- trigger

-- The doorway fattened by we_door_range, so someone walking up to either
-- face sets it off. The panel never leaves the frame, so this is built
-- once at spawn rather than rebuilt 60 times a second.
local function near_area(inst)
	if (inst.trigger == nil) then
		local r = we_door_range;
		inst.trigger = areas.box(inst.x1-r, inst.y1-r, inst.z1-r,
		                         inst.x2+r, inst.y2+r, inst.z2+r);
	end
	return inst.trigger;
end

-- Nobody may build inside the frame: a block left in the way would be
-- one we.fill refuses to paint over (it never paints over solid), so the
-- panel would arrive with a hole in it and never recover. The gaps in
-- the drawing are reserved too -- filling those in would wall up a
-- window the door is supposed to carry.
function D.reserved(inst)
	return areas.box(inst.x1, inst.y1, inst.z1, inst.x2, inst.y2, inst.z2);
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

	-- exactly one block per step, and only the cells that change are
	-- touched: redrawing the whole panel every step would be a block storm
	step(inst, we, (inst.off < want) and 1 or -1);
end

return D;
