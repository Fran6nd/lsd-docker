-- world_editor/areas.lua -- Shapes, containment, and area triggers.
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
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
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
function A.players_in(a, pred)
	local out = {};
	for i in piditer(PID_BROADCAST) do
		if (is_joined(i) and is_alive(i) and get_team(i) ~= 255) then
			local p = get_position(i);
			if (A.contains(a, p.x, p.y, p.z) and (pred == nil or pred(i))) then
				table.insert(out, i);
			end
		end
	end
	return out;
end

function A.any_player_in(a, pred)
	return #A.players_in(a, pred) > 0;
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
