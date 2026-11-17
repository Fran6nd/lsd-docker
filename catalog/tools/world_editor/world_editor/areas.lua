-- world_editor/areas.lua -- Shapes, containment and area triggers
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- One shape vocabulary serves the whole editor: authorization chunks
-- test blocks against it, components test *players* against it. Keeping
-- both on the same primitives means a shape only has to be written (and
-- got right) once, and anything that can be a permission region can
-- equally be a trigger volume.
--
--   rect2d    x1,y1 .. x2,y2          -- footprint, any height
--   circle2d  x,y,r                   -- footprint, any height
--   box       x1,y1,z1 .. x2,y2,z2    -- 3d rectangle
--   sphere    x,y,z,r
--   cylinder  x,y,r, z1..z2           -- vertical
--
-- Note the map's z axis points *down*: z=0 is sky, z=63 is the floor.
-- So "higher up" means a smaller z, and z1/z2 are stored min/max with
-- no assumption about which end is the top.
local A = {};

local defs = {};

defs.rect2d = {
	contains = function(a, x, y, z)
		return x >= a.x1 and x <= a.x2 and y >= a.y1 and y <= a.y2;
	end,
	bbox = function(a) return a.x1, a.y1, a.x2, a.y2; end,
};

defs.circle2d = {
	contains = function(a, x, y, z)
		local dx, dy = x-a.x, y-a.y;
		return dx*dx + dy*dy <= a.r*a.r;
	end,
	bbox = function(a) return a.x-a.r, a.y-a.r, a.x+a.r, a.y+a.r; end,
};

defs.box = {
	contains = function(a, x, y, z)
		return x >= a.x1 and x <= a.x2
		   and y >= a.y1 and y <= a.y2
		   and z >= a.z1 and z <= a.z2;
	end,
	bbox = function(a) return a.x1, a.y1, a.x2, a.y2; end,
};

defs.sphere = {
	contains = function(a, x, y, z)
		local dx, dy, dz = x-a.x, y-a.y, z-a.z;
		return dx*dx + dy*dy + dz*dz <= a.r*a.r;
	end,
	bbox = function(a) return a.x-a.r, a.y-a.r, a.x+a.r, a.y+a.r; end,
};

defs.cylinder = {
	contains = function(a, x, y, z)
		if (z < a.z1 or z > a.z2) then
			return false;
		end
		local dx, dy = x-a.x, y-a.y;
		return dx*dx + dy*dy <= a.r*a.r;
	end,
	bbox = function(a) return a.x-a.r, a.y-a.r, a.x+a.r, a.y+a.r; end,
};

function A.kinds()
	return {"rect2d", "circle2d", "box", "sphere", "cylinder"};
end

function A.valid(a)
	return a ~= nil and defs[a.kind] ~= nil;
end

function A.contains(a, x, y, z)
	local d = defs[a.kind];
	if (d == nil) then
		return false;
	end
	return d.contains(a, x, y, z);
end

function A.bbox(a)
	local d = defs[a.kind];
	if (d == nil) then
		return 0, 0, 0, 0;
	end
	return d.bbox(a);
end

-- ------------------------------------------------------------ builders

function A.rect2d(x1, y1, x2, y2)
	return {kind="rect2d", x1=math.min(x1,x2), y1=math.min(y1,y2),
	                       x2=math.max(x1,x2), y2=math.max(y1,y2)};
end

function A.circle2d(x, y, r)
	return {kind="circle2d", x=x, y=y, r=r};
end

function A.box(x1, y1, z1, x2, y2, z2)
	return {kind="box", x1=math.min(x1,x2), y1=math.min(y1,y2), z1=math.min(z1,z2),
	                    x2=math.max(x1,x2), y2=math.max(y1,y2), z2=math.max(z1,z2)};
end

function A.sphere(x, y, z, r)
	return {kind="sphere", x=x, y=y, z=z, r=r};
end

function A.cylinder(x, y, r, z1, z2)
	return {kind="cylinder", x=x, y=y, r=r,
	        z1=math.min(z1,z2), z2=math.max(z1,z2)};
end

-- move a shape's vertical span without rebuilding it; elevators slide
-- their trigger along with the platform every step
function A.with_z(a, z1, z2)
	local c = {};
	for k, v in pairs(a) do c[k] = v; end
	if (c.z1 ~= nil) then
		c.z1, c.z2 = math.min(z1, z2), math.max(z1, z2);
	elseif (c.z ~= nil) then
		c.z = z1;
	end
	return c;
end

-- ------------------------------------------------------------- triggers

-- Every live player standing inside the area. Bots and spectators are
-- skipped: a trigger should react to people who can actually be there.
--
-- `out` lets a caller pass a scratch table to refill instead of
-- allocating a fresh list: triggers run at 60 Hz per component, so the
-- garbage adds up.
function A.players_in(a, pred, out)
	out = out or {};
	local n = 0;
	for i in piditer(PID_BROADCAST) do
		if (is_joined(i) and is_alive(i) and get_team(i) ~= 255) then
			local p = get_position(i);
			if (A.contains(a, p.x, p.y, p.z) and (pred == nil or pred(i))) then
				n = n + 1;
				out[n] = i;
			end
		end
	end
	for i = #out, n+1, -1 do out[i] = nil; end
	return out;
end

-- Boolean-only form: stops at the first hit and allocates nothing. Most
-- triggers only ask "is anyone there", so this is the common path.
function A.any_player_in(a, pred)
	for i in piditer(PID_BROADCAST) do
		if (is_joined(i) and is_alive(i) and get_team(i) ~= 255) then
			local p = get_position(i);
			if (A.contains(a, p.x, p.y, p.z) and (pred == nil or pred(i))) then
				return true;
			end
		end
	end
	return false;
end

-- ---------------------------------------------------------------- index
--
-- An XY grid of areas, so "which areas cover this block" costs a bucket
-- lookup instead of a scan over everything. Both users need it for the
-- same reason: they are queried once per *block* on every player edit,
-- and a block line is dozens of blocks at once, so O(#areas) per block
-- would bite. Chunks index their permission regions; world_editor
-- indexes component reserved volumes.

local CELL = 32;                    -- grid granularity, in blocks
local GRID = math.ceil(512/CELL);

local Index = {};
Index.__index = Index;

function A.index()
	return setmetatable({cells={}}, Index);
end

function Index:reset()
	self.cells = {};
end

-- register `val` under every grid cell `area`'s bounding box touches
function Index:add(area, val)
	local x1, y1, x2, y2 = A.bbox(area);

	-- clamp to the map so a fat radius near an edge doesn't spray cells
	x1 = math.max(0, math.min(511, x1));
	y1 = math.max(0, math.min(511, y1));
	x2 = math.max(0, math.min(511, x2));
	y2 = math.max(0, math.min(511, y2));

	for cy = math.floor(y1/CELL), math.floor(y2/CELL) do
		for cx = math.floor(x1/CELL), math.floor(x2/CELL) do
			local k = cy*GRID + cx;
			local b = self.cells[k];
			if (b == nil) then b = {}; self.cells[k] = b; end
			b[#b+1] = val;
		end
	end
end

-- the values whose cell covers x,y -- a superset of the real hits, so
-- callers still test containment themselves
function Index:bucket(x, y)
	if (x < 0 or x > 511 or y < 0 or y > 511) then
		return nil;
	end
	return self.cells[math.floor(y/CELL)*GRID + math.floor(x/CELL)];
end

-- ---------------------------------------------------------------- json

function A.serialize(a)
	local out = {};
	for k, v in pairs(a) do out[k] = v; end
	return out;
end

function A.deserialize(t)
	if (t == nil or defs[t.kind] == nil) then
		return nil;
	end
	local a = {};
	for k, v in pairs(t) do a[k] = v; end
	return a;
end

return A;
