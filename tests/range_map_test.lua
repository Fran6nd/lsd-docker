-- range_map_test.lua -- the generated shooting range
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/range_map_test.lua      (from the repository root)
--
-- With a file name, writes seed 1's map there instead (and its .txt
-- beside it):
--   luajit tests/range_map_test.lua /tmp/maps/range.vxl [seed]
package.path = "catalog/core/?.lua;" .. package.path;
local R = require "range_map";
local MS = require "map_sources";

if (arg[1] ~= nil) then
	local c = R.generate(tonumber(arg[2]) or 1);
	local f = assert(io.open(arg[1], "wb"));
	f:write(R.vxl(c));
	f:close();
	f = assert(io.open((string.gsub(arg[1], "%.vxl$", ".txt")), "w"));
	f:write(R.meta(c, "range"));
	f:close();
	os.exit(0);
end

local passed, failed = 0, 0;
local function check(ok, what)
	if (ok) then passed = passed + 1; print("  PASS " .. what);
	else failed = failed + 1; print("  FAIL " .. what); end
end

local FLOOR = R.FLOOR;

-- The .vxl read back as the server reads it (libvxl's loop): every
-- column's solid voxels, as a string of 64 '#' and '.', and whether
-- every solid voxel that shows has a colour. nil if the file is not that.
local function read_columns(s)
	local cols, at = {}, 1;
	for i = 0, 512 * 512 - 1 do
		local v = {};
		for z = 0, 63 do v[z] = "#"; end
		local z = 0;
		while (true) do
			local n, top, last, air = string.byte(s, at, at + 3);
			if (n == nil or top > last + 1 or last > 63) then return nil; end
			for k = z, top - 1 do v[k] = "."; end
			local colored = last - top + 1;
			if (n == 0) then
				at = at + 4 * (colored + 1);
				break;
			end
			if (n - 1 ~= colored) then return nil; end   -- this writer leaves no hidden bottoms
			at = at + n * 4;
			z = string.byte(s, at + 3);   -- the next span's air start
		end
		cols[i] = table.concat(v, "", 0, 63);
	end
	return at == #s + 1 and cols or nil;
end

local function column_of(c, i)
	local x, y = i % 512, math.floor(i / 512);
	local v = {};
	for z = 0, 63 do v[z] = R.solid(c, x, y, z) and "#" or "."; end
	return table.concat(v, "", 0, 63);
end

-- Is the segment clear of solid voxels? Walked in steps of 0.05.
local function clear(c, a, b)
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z;
	local n = math.ceil(math.sqrt(dx * dx + dy * dy + dz * dz) / 0.05);
	for k = 1, n - 1 do
		local t = k / n;
		if (R.solid(c, math.floor(a.x + dx * t), math.floor(a.y + dy * t), math.floor(a.z + dz * t))) then
			return false;
		end
	end
	return true;
end

-- a body standing (or crouched) on the voxel p.z of column p: its eye,
-- and the middle of its chest
local function eye(p, stance)
	return {x = p.x + 0.5, y = p.y + 0.5, z = p.z - (stance == "crouch" and 1.35 or 2.25)};
end
local function chest(p, stance)
	local e = eye(p, stance);
	return {x = e.x, y = e.y, z = e.z + 0.8};
end

-- every place a target can be: each column of a rail, each of a blink
local function places(t)
	if (t.motion ~= "rail") then return t.points; end
	local a, b = t.points[1], t.points[2];
	local n = math.max(math.abs(b.x - a.x), math.abs(b.y - a.y));
	local out = {};
	for k = 0, n do
		out[#out + 1] = {x = a.x + (b.x - a.x) * k / n, y = a.y + (b.y - a.y) * k / n, z = a.z};
	end
	return out;
end

local function inside(b, p)
	return p.x >= b.x0 and p.x <= b.x1 and p.y >= b.y0 and p.y <= b.y1;
end

-- the columns a body can walk to from `from`: floor at FLOOR, three
-- voxels of air above it; `shut` are columns taken as walls, `open`
-- columns whose voxels above the floor are taken as air (a wall down)
local function walk(c, from, shut, open)
	local seen, queue, head = {}, {from.y * 512 + from.x}, 1;
	seen[queue[1]] = true;
	while (head <= #queue) do
		local i = queue[head];
		head = head + 1;
		local x, y = i % 512, math.floor(i / 512);
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			local nx, ny = x + d[1], y + d[2];
			local j = ny * 512 + nx;
			if (not seen[j] and not (shut and shut[j]) and R.solid(c, nx, ny, FLOOR)
			    and ((open and open[j]) or (not R.solid(c, nx, ny, FLOOR - 1)
			    and not R.solid(c, nx, ny, FLOOR - 2) and not R.solid(c, nx, ny, FLOOR - 3)))) then
				seen[j] = true;
				queue[#queue + 1] = j;
			end
		end
	end
	return seen;
end

local function mid(b) return {x = math.floor((b.x0 + b.x1) / 2), y = math.floor((b.y0 + b.y1) / 2), z = b.z}; end
local function at(p) return p.y * 512 + p.x; end

print("\n1. one seed, looked at closely");
local c = R.generate(1);
local vxl = R.vxl(c);
check(MS.looks_like_vxl(string.sub(vxl, 1, 64), #vxl), "map_sources takes it for a map");
local cols = read_columns(vxl);
check(cols ~= nil, "512 x 512 columns of spans, every voxel that shows coloured, nothing left over");
local same = cols ~= nil;
for i = 0, 512 * 512 - 1 do
	if (same and (c.top[i] ~= nil or i % 97 == 0) and cols[i] ~= column_of(c, i)) then same = false; end
end
check(same, "the file's voxels are the plan's, ports and all");
check(vxl == R.vxl(R.generate(1)), "the same seed is the same file");
check(vxl ~= R.vxl(R.generate(2)), "another seed is another range");

print("\n2. the static range");
check(#c.lanes == R.LANES and R.LANES >= 4, R.LANES .. " lanes side by side");
local by = {};
for _, t in ipairs(c.targets) do
	by[t.set] = by[t.set] or {};
	table.insert(by[t.set], t);
end
local same_d, stances, zs, motions, dmin, dmax = true, {}, {}, {}, 99, 0;
local first;
for k = 1, R.LANES do
	local list = by["lane" .. k] or {};
	local ds = {};
	for _, t in ipairs(list) do
		motions[t.motion] = (motions[t.motion] or 0) + 1;
		stances[t.stance] = true;
		for _, p in ipairs(t.points) do
			local d = R.LINE - p.y;
			ds[#ds + 1] = t.motion .. d;
			dmin, dmax = math.min(dmin, d), math.max(dmax, d);
			zs[p.z] = true;
		end
	end
	local key = table.concat(ds, " ");
	first = first or key;
	if (key ~= first) then same_d = false; end
end
check(dmin == 5 and dmax == 50, "targets from 5 to 50 m from the firing line (" .. dmin .. " to " .. dmax .. ")");
check(same_d, "every lane has its targets at the same distances: a time on one is a time on any");
check(stances.stand and stances.crouch, "standing targets and crouched ones");
local nz = 0;
for _ in pairs(zs) do nz = nz + 1; end
check(nz >= 3, "at " .. nz .. " heights (plinths)");
check(motions.rail == R.LANES and motions.blink == R.LANES, "a rail target and a blinking one in every lane");
local far = true;
for k, b in ipairs(c.lanes) do
	for _, t in ipairs(by["lane" .. k]) do
		for _, p in ipairs(t.points) do
			local dx, dy = p.x - t.face.x, p.y - t.face.y;
			local d = math.sqrt(dx * dx + dy * dy);
			if (d < R.LINE - p.y or d > R.LINE - p.y + 3) then far = false; end
			if (p.x < b.x0 or p.x > b.x1) then far = false; end
		end
	end
	if (not inside(b, c.targets[1].face) and k == 1) then far = false; end
end
check(far, "each target in its own lane, the firing position within 3 m of its distance");

print("\n3. the IPSC course");
local I = c.ipsc;
local ipsc = by.ipsc or {};
local shoot, noshoot = {}, {};
for _, t in ipairs(ipsc) do
	if (t.kind == "noshoot") then noshoot[#noshoot + 1] = t; else shoot[#shoot + 1] = t; end
end
check(#shoot >= 8, #shoot .. " IPSC targets");
local poppers = true;
for _, t in ipairs(shoot) do if (t.kind ~= "popper") then poppers = false; end end
for k = 1, R.LANES do
	for _, t in ipairs(by["lane" .. k]) do if (t.kind ~= "plate") then poppers = false; end end
end
check(poppers, "the course's go down when hit (poppers), the lanes' never do (plates)");
check(#noshoot >= 3, #noshoot .. " no-shoots on the course, none on the lanes");
local ins = true;
for _, t in ipairs(ipsc) do
	for _, p in ipairs(t.points) do if (not inside(I.area, p)) then ins = false; end end
	if (not inside(I.area, t.face)) then ins = false; end
end
check(ins, "its targets and its shooting positions inside the course");
check(inside(I.area, mid(I.start)) and inside(I.area, mid(I.finish)) and not inside(I.area, mid(I.wait)),
	"the start and end boxes are in the course, the waiting area outside");
local from_spawn = walk(c, c.spawn);
check(from_spawn[at(mid(I.start))] and from_spawn[at(mid(I.wait))], "from the spawn: the waiting area, and the course's door");
local bays = true;
for _, b in ipairs(c.lanes) do if (not from_spawn[at(mid(b))]) then bays = false; end end
check(bays, "and every lane's firing position");
local downrange = false;
for _, t in ipairs(by.lane1) do if (from_spawn[at(t.points[1])]) then downrange = true; end end
check(downrange, "downrange too: nothing but the rule keeps a shooter on the line");
-- the start wall: one block thick, across the hall from wall to wall,
-- every voxel of it solid and painted its one colour
local W = I.wall;
local whole, painted = W ~= nil and W.y0 == W.y1 and W.z1 == FLOOR - 1 and W.z0 < W.z1, true;
for x = W.x0, W.x1 do
	for z = W.z0, W.z1 do
		if (not R.solid(c, x, W.y0, z)) then whole = false; end
		local p = c.paint[at({x = x, y = W.y0})];
		if (p == nil or p[z] ~= W.color) then painted = false; end
	end
end
for z = W.z0, W.z1 do
	if (not R.solid(c, W.x0 - 1, W.y0, z) or not R.solid(c, W.x1 + 1, W.y0, z)) then whole = false; end
end
check(whole and painted and W.z1 - W.z0 + 1 >= 4,
	"the start wall: " .. (W.z1 - W.z0 + 1) .. " high, one thick, from wall to wall, every voxel its colour");
local down = {};
for x = W.x0, W.x1 do down[at({x = x, y = W.y0})] = true; end
-- the door in shut: nothing in the course reaches out
local shut = {};
for x = I.area.x0, I.area.x1 do shut[(I.area.y1 + 1) * 512 + x] = true; end
local behind = walk(c, mid(I.start), shut);
local boxed, n_behind = true, 0;
for i in pairs(behind) do
	n_behind = n_behind + 1;
	local p = {x = i % 512, y = math.floor(i / 512)};
	if (not inside(I.area, p) or p.y <= W.y0) then boxed = false; end
end
check(boxed and inside(I.area, mid(I.start)) and mid(I.start).y > W.y0,
	"standing, it shuts the start box off from the course (" .. n_behind .. " columns behind it)");
local inner = walk(c, mid(I.start), shut, down);
local closed, cells = true, 0;
for i in pairs(inner) do
	cells = cells + 1;
	if (not inside(I.area, {x = i % 512, y = math.floor(i / 512)})) then closed = false; end
end
check(closed and cells > 400, "down: the course, closed with its door shut, nobody leaves it (" .. cells .. " columns inside)");
check(inner[at(mid(I.finish))], "and the end box is reached from the start box");
local seen_from = {};
for k, p in ipairs(I.positions) do
	if (not inner[at(p)]) then seen_from[k] = false; end
end
check(next(seen_from) == nil, "every shooting position is reached");

-- a no-shoot among the targets: by one shot at from the same position,
-- a column or two from it, never on a column a target can be on
local among = true;
for seed = 1, 20 do
	local k = R.generate(seed * 7919);
	local taken = {};
	for _, t in ipairs(k.targets) do
		if (t.kind ~= "noshoot") then
			for _, p in ipairs(places(t)) do taken[at({x = math.floor(p.x), y = p.y})] = true; end
		end
	end
	for _, t in ipairs(k.targets) do
		if (t.kind == "noshoot") then
			local p = t.points[1];
			local near = false;
			for _, u in ipairs(k.targets) do
				local q = u.points[1];
				if (u.kind == "popper" and u.motion == "static" and u.face == t.face
				    and math.max(math.abs(q.x - p.x), math.abs(q.y - p.y)) <= 1) then
					near = true;
				end
			end
			if (taken[at(p)] or not near or not inside(k.ipsc.area, p)) then among = false; end
		end
	end
end
check(among, "twenty seeds: each no-shoot stands by a target shot from the same position, on a column of its own");

print("\n4. every target and no-shoot: on a floor, room for its body, in sight from where it is shot");
local floored, sighted = true, true;
for seed = 1, 20 do
	local k = R.generate(seed * 7919);
	for _, t in ipairs(k.targets) do
		local h = t.stance == "crouch" and 2 or 3;
		for _, p in ipairs(places(t)) do
			local px, py = math.floor(p.x), math.floor(p.y);
			if (not R.solid(k, px, py, p.z)) then floored = false; end
			for z = p.z - h, p.z - 1 do if (R.solid(k, px, py, z)) then floored = false; end end
			local from = eye(t.face, "stand");
			if (not clear(k, from, eye(p, t.stance)) or not clear(k, from, chest(p, t.stance))) then
				sighted = false;
				print(string.format("    seed %d %s %s at %d,%d,%d not in sight from %d,%d",
					seed * 7919, t.set, t.motion, p.x, p.y, p.z, t.face.x, t.face.y));
			end
		end
	end
end
check(floored, "twenty seeds: every target stands on solid ground with room above it");
check(sighted, "and its head and chest are in clear sight from its firing position");

print("\n5. the metadata");
local meta = "\n" .. R.meta(c, "range");
for _, key in ipairs({"range_spawn", "range_lanes", "range_ipsc", "range_ipsc_start", "range_ipsc_end",
		"range_ipsc_wait", "range_ipsc_wall", "range_targets", "range_version"}) do
	check(string.find(meta, "\n%s*'" .. key .. "' : [%(%d].-,\n") ~= nil, key .. ", on one line");
end
check(string.find(meta, "'noshoot', 'stand', 'static'", 1, true) ~= nil and string.find(meta, "'popper'", 1, true) ~= nil,
	"each target with its kind");

print(string.format("\n%d passed, %d failed", passed, failed));
os.exit(failed == 0 and 0 or 1);
