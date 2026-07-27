-- world_editor/door.lua -- A surface that retracts to open.
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

-- default panel colour, used for a door captured from an empty box when
-- the placer's palette read fails too
local GREY = {r=170, g=170, b=185};

local DIRS = {up=true, down=true, left=true, right=true};

D.desc  = "an existing surface that retracts to open when someone is near.";
D.usage = "<up|down|left|right>";
D.help  = {
	"world_editor: door -- a built surface that slides open when a player nears it.",
	"  usage: /place door <up|down|left|right>",
	"  up/down retract into ceiling/floor; left/right slide aside.",
	"  build the shape first, then mark two opposite corners around it:",
	"  its blocks, colours and gaps all become the door.",
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

-- key for a cell within one slice: the two coordinates the retract axis
-- does not use. z tops out at 63 and x/y at 511, so this packs cleanly.
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

-- Expand the run-length cells into what drawing actually needs: for each
-- slice along the retract axis, the cells of each colour in it.
--
-- Grouping by colour is the whole point. we.fill paints one colour per
-- call (it sets the anon pid's held colour once, deliberately -- see the
-- block api in world_editor.lua), so a slice costs one call per distinct
-- colour it contains rather than one per block.
--
-- Returns nil plus a reason when the stencil does not describe this box,
-- so a mismatch draws a plain panel instead of a misaligned mess.
local function build_slices(inst, pal, cells)
	local w = inst.x2 - inst.x1 + 1;
	local h = inst.y2 - inst.y1 + 1;
	local plane = w * h;
	local total = plane * (inst.z2 - inst.z1 + 1);
	local axis = inst.axis;

	local slice, groups = {}, {};
	local i, ncells = 0, 0;

	for count, idx in string.gmatch(cells, "(%d+)%*(%d+)") do
		count, idx = tonumber(count), tonumber(idx);
		if (i + count > total) then
			return nil, "more cells than the box holds";
		end

		if (idx ~= 0) then
			local col = pal[idx];
			if (col == nil) then
				return nil, "a run names colour "..idx..", which is not in the palette";
			end
			for n = i, i + count - 1 do
				-- capture walked z, then y, then x; unwind that
				local x = inst.x1 + (n % w);
				local y = inst.y1 + (math.floor(n / w) % h);
				local z = inst.z1 + math.floor(n / plane);
				local c = (axis == "z") and z or ((axis == "x") and x or y);

				local byidx = groups[c];
				if (byidx == nil) then
					byidx = {};
					groups[c], slice[c] = byidx, {};
				end
				local g = byidx[idx];
				if (g == nil) then
					g = {color=col, has={}};
					byidx[idx] = g;
					table.insert(slice[c], g);
				end
				g.has[okey(axis, x, y, z)] = true;
				ncells = ncells + 1;
			end
		end
		i = i + count;
	end

	if (i ~= total) then
		return nil, string.format("%d cells for a box of %d", i, total);
	end
	return slice, ncells;
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

	-- Another component's blocks must not be swallowed. D.render digs the
	-- whole box to claim it, which would tear a hole through whatever
	-- else lives in there while that component still believed it was
	-- intact.
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

	d.pal, d.cells = capture(d.x1, d.y1, d.z1, d.x2, d.y2, d.z2);

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

	-- New doors were clamped at placement, so this only ever bites a
	-- layout hand-edited (or written when we_deepest was different). The
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
	inst.slices = inst.hi - inst.lo + 1;

	-- The captured drawing, if this door has one. Kept on the instance
	-- only once it has proved to describe this box, so a stencil we
	-- refused to draw is not written back out on the next save either.
	if (cells ~= nil) then
		local pal = decode_pal(d.pal);
		local slice, n;
		if (pal == nil) then
			n = "its palette is not a list of rrggbb strings";
		else
			slice, n = build_slices(inst, pal, cells);   -- cell count, or why not
		end
		if (slice == nil) then
			log("world_editor: door at %d,%d has an unusable drawing (%s); using a solid panel",
			    inst.x1, inst.y1, tostring(n));
		else
			inst.slice, inst.ncells = slice, n;
			inst.pal, inst.cells = d.pal, cells;
		end
	end

	-- "up" and "right" eat slices from the high end, "down" and "left"
	-- from the low end
	inst.from_hi = (d.dir == "up" or d.dir == "right");
	inst.open = 0;      -- how many slices are currently retracted
	inst.t = 0;
	return inst;
end

function D.save(inst)
	return {x1=inst.x1, y1=inst.y1, z1=inst.z1,
	        x2=inst.x2, y2=inst.y2, z2=inst.z2, dir=inst.dir,
	        pal=inst.pal, cells=inst.cells};
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

-- Draw (or clear) the slice sitting at coordinate c on the retract axis;
-- the other two axes are swept in full.
--
-- Clearing needs no drawing data at all: we.fill only destroys cells the
-- door owns, so the gaps in the drawing -- which it never owned -- come
-- through untouched for free, and the whole slice still culls once.
--
-- Building is where the drawing matters: one we.fill per colour in the
-- slice, each with a keep predicate picking out that colour's cells, so
-- the door goes back up exactly as it was captured, holes and all.
local function draw_slice(inst, we, c, on)
	local x1, x2 = inst.x1, inst.x2;
	local y1, y2 = inst.y1, inst.y2;
	local z1, z2 = inst.z1, inst.z2;

	if (inst.axis == "z") then z1, z2 = c, c;
	elseif (inst.axis == "x") then x1, x2 = c, c;
	else y1, y2 = c, c; end

	if (not on) then
		we.fill(inst, x1, y1, z1, x2, y2, z2, nil, false, nil);
		return;
	end

	if (inst.slice == nil) then
		-- nothing was captured (the box was empty air): the panel is a
		-- solid plane in the placer's colour, as a door always used to be
		we.fill(inst, x1, y1, z1, x2, y2, z2, we.tint(inst, GREY), true, nil);
		return;
	end

	local groups = inst.slice[c];
	if (groups == nil) then
		return;   -- this slice of the drawing is all gaps
	end

	local axis = inst.axis;
	for i = 1, #groups do
		local g = groups[i];
		we.fill(inst, x1, y1, z1, x2, y2, z2, g.color, true, function(x, y, z)
			return g.has[okey(axis, x, y, z)] ~= nil;
		end);
	end
end

-- A door has to OWN every cell of its panel, or it cannot move them.
-- we.fill never paints over a solid cell (that is what stops it painting
-- without breaking), so a door laid against existing terrain claimed
-- nothing at all: its state machine opened and closed happily while zero
-- blocks moved, which reads as a completely dead door.
--
-- So clear the panel volume first, exactly as the elevator clears its
-- shaft, and only then lay the panel down. For a captured door those are
-- the very blocks that were just read: digging them and drawing them
-- back is what converts somebody's build into a component. dig_box skips
-- cells we already own, so a re-render is not a destroy-rebuild cycle.
-- D.reserved keeps the volume ours afterwards.
--
-- Only the shut slices are then drawn; the retracted ones are air the
-- panel has already given up, and sweeping them cost a bulk-destroy cull
-- per slice for no writes.
function D.render(inst, we)
	we.dig_box(inst.x1, inst.y1, inst.z1, inst.x2, inst.y2, inst.z2);

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
-- The whole box is reserved, gaps in the drawing included -- filling
-- those in would wall up a window the door is supposed to keep open.
function D.reserved(inst)
	return areas.box(inst.x1, inst.y1, inst.z1, inst.x2, inst.y2, inst.z2);
end

-- what /components reports for a door
function D.status(inst, we)
	return string.format("%s %s %d..%d open %d/%d %s near %s",
	                     inst.dir, inst.axis, inst.lo, inst.hi,
	                     inst.open, inst.slices,
	                     inst.ncells and (inst.ncells.." drawn") or "solid",
	                     tostring(areas.any_player_in(near_area(inst))));
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
