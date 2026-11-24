-- parkour_map_test.lua -- the generated parkour course
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/parkour_map_test.lua      (from the repository root)
--
-- With a file name, writes seed 1's map there instead (and its .txt
-- beside it): what the bots' navigation bench is run on.
--   luajit tests/parkour_map_test.lua /tmp/maps/parkour.vxl [seed]
package.path = "catalog/core/?.lua;" .. package.path;
local P = require "parkour_map";
local MS = require "map_sources";

if (arg[1] ~= nil) then
	local c = P.generate(tonumber(arg[2]) or 1);
	local f = assert(io.open(arg[1], "wb"));
	f:write(P.vxl(c));
	f:close();
	f = assert(io.open((string.gsub(arg[1], "%.vxl$", ".txt")), "w"));
	f:write(P.meta(c, "parkour"));
	f:close();
	print(string.format("start %d,%d,%d tent %d,%d,%d", c.start.x, c.start.y, c.start.z,
		c.tent.x, c.tent.y, c.tent.z));
	for _, p in ipairs(c.checkpoints) do print(string.format("checkpoint %d,%d,%d", p.x, p.y, p.z)); end
	os.exit(0);
end

local passed, failed = 0, 0;
local function check(ok, what)
	if (ok) then passed = passed + 1; print("  PASS " .. what);
	else failed = failed + 1; print("  FAIL " .. what); end
end

-- The .vxl read back as the server reads it: each column's top, and
-- whether it is one span reaching the sea. nil if the file is not that.
local function read_tops(s)
	local tops, at = {}, 1;
	for i = 0, 512 * 512 - 1 do
		local n, top, last, air = string.byte(s, at, at + 3);
		if (n ~= 0 or air ~= 0 or last ~= 63 or top == nil or top > 63) then return nil; end
		tops[i] = top;
		at = at + 4 + (last - top + 1) * 4;
	end
	return at == #s + 1 and tops or nil;
end

-- Where a body can get to from `from`, with only the moves the course is
-- built for (fewer than the bots have): a step of one up, a jump of two
-- up, a drop of MAX_DROP, and along an axis a gap of MAX_GAP columns of
-- water landing level, one up or one down. Returns the set of columns.
local function reach(c, from)
	local seen, queue = {}, {from.y * 512 + from.x};
	seen[queue[1]] = true;
	local head = 1;
	while (head <= #queue) do
		local i = queue[head];
		head = head + 1;
		local x, y, z = i % 512, math.floor(i / 512), c.top[i];
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			for gap = 0, P.MAX_GAP do
				local j = (y + d[2] * (gap + 1)) * 512 + x + d[1] * (gap + 1);
				local to = c.top[j];
				if (to ~= nil) then
					local dz = to - z;   -- below zero is up
					local ok;
					if (gap == 0) then ok = dz >= -P.MAX_CLIMB and dz <= P.MAX_DROP;
					else ok = dz >= -1 and dz <= 1; end
					if (ok and not seen[j]) then
						seen[j] = true;
						queue[#queue + 1] = j;
					end
					break;   -- a column in the way: nothing is jumped beyond it
				end
			end
		end
	end
	return seen;
end

local function at(p) return p.y * 512 + p.x; end

print("\n1. one seed, looked at closely");
local c = P.generate(1);
local vxl = P.vxl(c);
check(MS.looks_like_vxl(string.sub(vxl, 1, 64), #vxl), "map_sources takes it for a map");
local tops = read_tops(vxl);
check(tops ~= nil, "512 x 512 columns, one span each, nothing left over");
local same, land = tops ~= nil, 0;
for i = 0, 512 * 512 - 1 do
	if (tops ~= nil and tops[i] ~= (c.top[i] or P.WATER)) then same = false; end
	if (c.top[i] ~= nil) then land = land + 1; end
end
check(same, "the file's heights are the course's, and the rest is sea");
check(land > 1000 and land < 20000, "a course, not a continent (" .. land .. " columns)");
check(vxl == P.vxl(P.generate(1)), "the same seed is the same file");
check(vxl ~= P.vxl(P.generate(2)), "another seed is another course");
check(#c.checkpoints == 3, "three checkpoints");
check(#c.obstacles == 18, "eighteen obstacles");

local meta = "\n" .. P.meta(c, "parkour");
check(string.find(meta, "\n%s*'water_damage' : 100,\n") ~= nil, "the metadata says the water kills");
check(string.find(meta, "\n%s*'parkour_start' : %(%d+, %d+, %d+%),\n") ~= nil
	and string.find(meta, "\n%s*'parkour_tent' : %(%d+, %d+, %d+%),\n") ~= nil
	and string.find(meta, "\n%s*'parkour_checkpoints' : %(%(.-%)%),\n") ~= nil,
	"and names the start, the tent and the checkpoints, a line each");

print("\n2. forty seeds: every one can be run");
local bad_place, bad_room, bad_way, bad_height, bad_order, kinds = 0, 0, 0, 0, 0, {};
local errors = 0;
for seed = 1, 40 do
	local ok, k = pcall(P.generate, seed * 7919);
	if (not ok) then
		errors = errors + 1;
		print("  seed " .. seed * 7919 .. ": " .. tostring(k));
	else
		local places = {k.start, k.tent};
		for _, p in ipairs(k.checkpoints) do places[#places + 1] = p; end
		for _, p in ipairs(places) do
			if (k.top[at(p)] ~= p.z) then bad_place = bad_place + 1; end
			-- a platform's middle: level ground three columns every way
			for dy = -3, 3 do
				for dx = -3, 3 do
					if (k.top[(p.y + dy) * 512 + p.x + dx] ~= p.z) then bad_room = bad_room + 1; end
				end
			end
		end
		for i, z in pairs(k.top) do
			local x, y = i % 512, math.floor(i / 512);
			if (z < 30 or z > 58 or x < 16 or x > 495 or y < 16 or y > 495) then bad_height = bad_height + 1; end
		end
		-- from each place the next is reached: nobody needs a move the
		-- course was not built for
		local order = {k.start};
		for _, p in ipairs(k.checkpoints) do order[#order + 1] = p; end
		order[#order + 1] = k.tent;
		for i = 1, #order - 1 do
			if (not reach(k, order[i])[at(order[i + 1])]) then bad_way = bad_way + 1; end
			if (order[i + 1].x <= order[i].x) then bad_order = bad_order + 1; end
		end
		for _, name in ipairs(k.obstacles) do kinds[name] = true; end
	end
end
check(errors == 0, "none runs off the map or over itself");
check(bad_place == 0, "start, checkpoints and tent stand on the course, at the height said");
check(bad_room == 0, "each in the middle of a level platform");
check(bad_height == 0, "the walkway keeps off the edges, the sky and the sea");
check(bad_way == 0, "start to checkpoints to tent with steps, jumps of two up, drops of three and gaps of two");
check(bad_order == 0, "the checkpoints are met in order, west to east");
local n = 0;
for _ in pairs(kinds) do n = n + 1; end
check(n == #P.OBSTACLES and n >= 10, "every kind of obstacle turns up (" .. n .. ")");

print("\n3. the moves are needed: without the jumps the tent is out of reach");
local saved = P.MAX_GAP;
P.MAX_GAP = 0;
check(not reach(c, c.start)[at(c.tent)], "no walking round the gaps");
P.MAX_GAP = saved;

print(string.format("\n%d passed, %d failed", passed, failed));
os.exit(failed == 0 and 0 or 1);
