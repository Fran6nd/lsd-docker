-- lib_stairs.lua -- Stairs from the ground up to a top step, as voxels
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- A script that wants a stair built -- babel's, up to its platform in the
-- sky -- says where the stair's TOP step is and which way it runs down,
-- and is given the voxels to build and the floors a body climbs:
--
--   stair_lay(kind, spec)  -> a stair; or nil and why it cannot be laid there
--
--     spec.top     {x, y, z}: the top step, the floor a body steps off
--                  onto the place the stair leads to
--     spec.dx      -1 or 1: the way along x the stair runs DOWN, away from
--                  that place
--     spec.rows    {y, y2}: the rows it may take. y is the top's own; y2,
--                  beside it (y - 1 or y + 1), a switchback's second row
--     spec.ground  function(x, y): the z of the top of the ground in that
--                  column (63 where there is none)
--     spec.refuse  function(x, y): true for a column the stair may not use
--                  (optional; the map's edge is refused anyway)
--     spec.wide    a straight stair's second row, to widen it (optional)
--
--     stair.kind   as asked
--     stair.top    the top step (spec.top)
--     stair.steps  the floors a body stands on, from the bottom to the top:
--                  each the solid voxel under its feet, the next always a
--                  column beside it and at most one voxel higher, with
--                  three voxels of air over each that no voxel of the
--                  stair takes. The lowest stands on the ground.
--     stair.cells  every voxel to build, SUPPORT FIRST: each, when it is
--                  put, touches by a face one put before it or the ground.
--                  A straight run of them along one axis comes one after
--                  the other, so that a builder can lay it as one line.
--     stair.widen  voxels that make it hold better, built after it, in the
--                  same order (empty when the kind needs none)
--     stair.foot   {x, y, z}: the ground a body climbs onto its lowest step
--                  from: a column beside it, not refused, its ground at
--                  most a voxel under that step, with air for a body over
--                  it. None: the stair is not laid.
--
--   stair_kinds()  -> the kinds, {"straight", "tapered", ...}
--
-- The map's z grows DOWN: z 0 is the sky, 63 the bottom; a step one voxel
-- up is one less z. A body is three voxels tall and climbs one voxel a
-- step. Columns under the ground are left out of every list (the ground
-- is there already), and what is in the way -- a tree, a rock -- is the
-- caller's to judge (it alone sees the map): the stair is laid on the
-- ground the caller describes.
--
-- THE KINDS (each drawn as seen from the side, the top on the right at
-- the place it leads to; # a voxel to build, = the ground):
--
--   straight    one column and one voxel a step, down and away from the
--               top along its row until a step rests on the ground: each
--               step and the voxel under it, a band two voxels deep. The
--               fewest voxels for the climb; a cut anywhere drops all over
--               it. Widened by the same band on the row beside it.
--                                    ##
--                                   ##
--                                  ##
--                                 ==
--   tapered     the straight stair's floors with everything under them
--               filled: a wedge, laid as one LINE a level, from the ground
--               up -- the bottom line the stair's whole length, the top
--               one a single block. Every column stands on the ground, so
--               a cut drops little; more voxels, but a line apiece.
--                                    #
--                                   ##
--                                  ###
--                                 ====
--   switchback  climbs in a small footprint: legs of LEG steps along x on
--               two rows side by side, turning at a landing at each end,
--               so it rises within LEG + 1 columns of the top (its pillars
--               counted) instead of running out to the ground. Widened by
--               a pillar beside each outer landing, from the ground up.
--   spiral      steps round a pillar, a ring of the 8 columns round it,
--               one voxel up a step and the last at the top; the pillar a
--               column from the ground up to the top's level. The smallest
--               footprint: 3 by 3. Its pillar holds it; nothing to widen.
local mod = init_mod();

-- the map, in voxels: x and y 0 to 511, z 0 (the sky) to 63 (the bottom)
local MAP_XY, MAP_Z = 512, 64;
local BODY = 3;             -- voxels of air a body stands in over its floor

-- A SWITCHBACK'S LEG, in steps along a row. Each column of it is walked
-- once a round (out along one row, back along the other), which takes it
-- 2 * (LEG - 1) voxels down; under a floor and its riser a body on the
-- floor a round below needs its three voxels of air and one more to jump
-- up a step: 2 * (LEG - 1) - 2 >= BODY + 1, so LEG >= 4. The shortest that
-- does is the smallest footprint, and its runs are still four blocks.
local LEG = 4;

-- A SPIRAL'S RING round its pillar, as it is walked down from the top:
-- (along dx, along y) from the pillar. The top is the column toward the
-- place the stair leads to, (-1, 0); each the next round, face to face.
local RING = {{-1, 0}, {-1, 1}, {0, 1}, {1, 1}, {1, 0}, {1, -1}, {0, -1}, {-1, -1}};

local KINDS = {"straight", "tapered", "switchback", "spiral"};

local function on_map(x, y)
	return x >= 0 and x < MAP_XY and y >= 0 and y < MAP_XY;
end

local function refused(spec, x, y)
	return spec.refuse ~= nil and spec.refuse(x, y) == true;
end

local function key(x, y, z)
	return (z * MAP_XY + y) * MAP_XY + x;
end

-- the band under a list of floors, bottom first: each floor's riser (the
-- voxel under it, which the next floor down meets face to face) and then
-- the floor, those under the ground left out. On row `y` if given (a
-- straight stair's second row), else each on its own.
local function band(steps, ground, y)
	local cells = {};
	for _, p in ipairs(steps) do
		local row = y or p.y;
		local g = ground(p.x, row);
		if (p.z + 1 < g) then cells[#cells + 1] = {x = p.x, y = row, z = p.z + 1}; end
		if (p.z < g) then cells[#cells + 1] = {x = p.x, y = row, z = p.z}; end
	end
	return cells;
end

local LAY = {};

-- step k at (top x + dx * k, the top's row, top z + k), from the top down
-- to the first that rests on the ground (or sinks into it: kept, its band
-- left out -- the ground is its band); a body would come from the column
-- past it
function LAY.straight(spec)
	local t, dx, ground = spec.top, spec.dx, spec.ground;
	local steps = {};
	for k = 0, MAP_Z - 2 - t.z do
		local x, z = t.x + dx * k, t.z + k;
		if (x < 1 or x > MAP_XY - 2) then return nil, "it runs off the map"; end
		table.insert(steps, 1, {x = x, y = t.y, z = z});
		if (z >= ground(x, t.y) - 1) then break; end
	end
	local b = steps[1];
	if (b == nil) then return nil, "its top is under the map"; end
	return {
		steps = steps,
		cells = band(steps, ground),
		widen = spec.wide ~= nil and band(steps, ground, spec.wide) or {},
		want = {x = b.x + dx, y = t.y},
	};
end

-- the straight stair's floors, and under them, level by level from the
-- ground up, the columns whose floor is at that level or higher: one line
-- a level, from the foot's side toward the top (the way the stair is
-- climbed, so its outer end is the newest step)
function LAY.tapered(spec)
	local st, why = LAY.straight(spec);
	if (st == nil) then return nil, why; end
	local ground = spec.ground;
	local low, high = -1, MAP_Z;        -- the wedge's lowest level and its highest
	for _, p in ipairs(st.steps) do
		low = math.max(low, ground(p.x, p.y) - 1);
		high = math.min(high, p.z);
	end
	local cells = {};
	for z = low, high, -1 do
		for _, p in ipairs(st.steps) do         -- bottom step first: the foot's side
			if (p.z <= z and z < ground(p.x, p.y)) then
				cells[#cells + 1] = {x = p.x, y = p.y, z = z};
			end
		end
	end
	return {steps = st.steps, cells = cells, widen = {}, want = st.want};
end

-- A stair that follows a PATH: path(i) is the column of the i-th floor
-- down from the top and how far under the one before it that floor is
-- (1, or 0 for a landing). Down from the top to the first floor that
-- rests on the ground; one that would be in the ground ends it at the one
-- before, with this column its foot. -> the floors bottom first and the
-- column a body would come from (the path's next), or nil and why.
local function walk(spec, path)
	local t, ground = spec.top, spec.ground;
	local steps, z, i = {}, t.z, 0;
	while (true) do
		local x, y, under = path(i);
		if (i > 0) then z = z + under; end
		if (not on_map(x, y)) then return nil, "it runs off the map"; end
		local g = ground(x, y);
		if (z >= g) then
			if (i == 0) then return nil, "its top is in the ground"; end
			return steps, {x = x, y = y};
		end
		table.insert(steps, 1, {x = x, y = y, z = z});
		if (z == g - 1) then
			local nx, ny = path(i + 1);
			return steps, {x = nx, y = ny};
		end
		i = i + 1;
	end
end

-- out along the top's row, LEG floors a voxel apart; a landing, the
-- second row's column beside the last, level with it; back along the
-- second row; a landing on the top's row again; and so round, down to
-- the ground. Widened by a pillar from the ground beside each row's outer
-- landings (the column past the legs), up to the highest landing there:
-- every leg then hangs on a pillar at its outer end as well as on the leg
-- under it
function LAY.switchback(spec)
	local t, dx = spec.top, spec.dx;
	local y2 = spec.rows ~= nil and spec.rows[2] or nil;
	if (y2 == nil or math.abs(y2 - t.y) ~= 1) then
		return nil, "a switchback takes a second row beside its top's";
	end
	local function path(i)
		local q = i % (2 * LEG);
		if (q < LEG) then
			return t.x + dx * q, t.y, q == 0 and 0 or 1;
		end
		return t.x + dx * (2 * LEG - 1 - q), y2, q == LEG and 0 or 1;
	end
	local steps, want = walk(spec, path);
	if (steps == nil) then return nil, want; end
	local widen = {};
	local outer, pillar = t.x + dx * (LEG - 1), t.x + dx * LEG;
	for _, y in ipairs({t.y, y2}) do
		local top = nil;                -- the highest landing on this row
		for _, p in ipairs(steps) do
			if (p.x == outer and p.y == y and (top == nil or p.z < top)) then top = p.z; end
		end
		if (top ~= nil and on_map(pillar, y)) then
			for z = spec.ground(pillar, y) - 1, top, -1 do
				widen[#widen + 1] = {x = pillar, y = y, z = z};
			end
		end
	end
	return {steps = steps, cells = band(steps, spec.ground), widen = widen, want = want};
end

-- the pillar a column out from the top (so the top is the ring's column
-- toward the place it leads to), from the ground up to the top's level,
-- first and as one line; then the ring's band, bottom first
function LAY.spiral(spec)
	local t, dx, ground = spec.top, spec.dx, spec.ground;
	local cx, cy = t.x + dx, t.y;
	local function path(i)
		local o = RING[i % #RING + 1];
		return cx + dx * o[1], cy + o[2], 1;
	end
	local steps, want = walk(spec, path);
	if (steps == nil) then return nil, want; end
	if (not on_map(cx, cy) or ground(cx, cy) <= t.z) then
		return nil, "no room for its pillar";
	end
	local cells = {};
	for z = ground(cx, cy) - 1, t.z, -1 do cells[#cells + 1] = {x = cx, y = cy, z = z}; end
	for _, c in ipairs(band(steps, ground)) do cells[#cells + 1] = c; end
	return {steps = steps, cells = cells, widen = {}, want = want};
end

-- the ground a body climbs onto the lowest step from: the column the path
-- would have gone on to if it serves, else any column beside the lowest
-- step that does -- on the map, not refused, its ground at most a voxel
-- under the step, and air for a body over it that no voxel of the stair
-- takes
local function foot_of(spec, bottom, want, taken)
	local around = {
		want,
		{x = bottom.x + 1, y = bottom.y}, {x = bottom.x - 1, y = bottom.y},
		{x = bottom.x, y = bottom.y + 1}, {x = bottom.x, y = bottom.y - 1},
	};
	for _, c in ipairs(around) do
		if (on_map(c.x, c.y) and not refused(spec, c.x, c.y)) then
			local g = spec.ground(c.x, c.y);
			local clear = g - bottom.z <= 1;
			for z = g - BODY, g - 1 do
				if (taken[key(c.x, c.y, z)]) then clear = false; end
			end
			if (clear) then return {x = c.x, y = c.y, z = g}; end
		end
	end
end

-- every voxel of a list on the map and in a column the stair may use
local function allowed(spec, list)
	for _, c in ipairs(list) do
		if (not on_map(c.x, c.y) or c.z < 0 or c.z >= MAP_Z) then
			return false, "it runs off the map";
		end
		if (refused(spec, c.x, c.y)) then
			return false, string.format("column %d %d is refused to it", c.x, c.y);
		end
	end
	return true;
end

function stair_lay(kind, spec)
	local make = LAY[kind];
	if (make == nil) then return nil, "no such kind of stair: " .. tostring(kind); end
	local st, why = make(spec);
	if (st == nil) then return nil, why; end
	for _, list in ipairs({st.steps, st.cells}) do
		local ok, no = allowed(spec, list);
		if (not ok) then return nil, no; end
	end
	-- what widens it is no part of it: where it may not go, it goes without
	if (not allowed(spec, st.widen)) then st.widen = {}; end
	-- every kind's foot by the one rule
	local taken = {};
	for _, list in ipairs({st.cells, st.widen}) do
		for _, c in ipairs(list) do taken[key(c.x, c.y, c.z)] = true; end
	end
	st.foot = foot_of(spec, st.steps[1], st.want, taken);
	st.want = nil;
	if (st.foot == nil) then return nil, "no way onto its lowest step"; end
	st.kind, st.top = kind, st.steps[#st.steps];
	return st;
end

function stair_kinds()
	local out = {};
	for i, k in ipairs(KINDS) do out[i] = k; end
	return out;
end

return mod;
