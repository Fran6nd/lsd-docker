-- stairs_test.lua -- lib_stairs' promises, for every kind, on uneven ground
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/stairs_test.lua      (from the repository root)
--
-- What a stair is said to be (the header of lib_stairs.lua): floors each
-- beside the last and at most a voxel up, air for a body over each, its
-- voxels support first, its top where asked, nothing in a refused column
-- -- and a FOOT a body can climb from: beside the lowest step, not
-- refused, its ground at most a voxel under that step. babel_test lays
-- each kind on flat ground; here the ground has a pit, a rise and a
-- refused strip where a stair would end.

function init_mod() return {}; end
dofile("catalog/libs/stairs/lib_stairs.lua");

local checks, failures = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then
		print("  ok   " .. what);
	else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""));
	end
end

local function key(x, y, z) return x .. "," .. y .. "," .. z; end
local FACES = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};

-- every promise of one laid stair, on `ground`, `refuse`
local function promises(name, st, spec)
	local ground, top = spec.ground, spec.top;
	local cells = {};
	for _, c in ipairs(st.cells) do cells[key(c.x, c.y, c.z)] = true; end
	local climb, room = true, true;
	for i, p in ipairs(st.steps) do
		local q = st.steps[i - 1];
		if (q ~= nil and (math.abs(p.x - q.x) + math.abs(p.y - q.y) ~= 1 or q.z - p.z > 1 or q.z < p.z)) then
			climb = false;
		end
		for z = p.z - 3, p.z - 1 do
			if (cells[key(p.x, p.y, z)]) then room = false; end
		end
	end
	local support, put = true, {};
	for _, list in ipairs({st.cells, st.widen}) do
		for _, c in ipairs(list) do
			local ok = c.z + 1 >= ground(c.x, c.y);
			for _, d in ipairs(FACES) do
				if (put[key(c.x + d[1], c.y + d[2], c.z + d[3])]) then ok = true; end
			end
			if (not ok) then support = false; end
			put[key(c.x, c.y, c.z)] = true;
		end
	end
	local refused = false;
	for _, list in ipairs({st.steps, st.cells, st.widen}) do
		for _, c in ipairs(list) do
			if (spec.refuse ~= nil and spec.refuse(c.x, c.y)) then refused = true; end
		end
	end
	local last, b, f = st.steps[#st.steps], st.steps[1], st.foot;
	check(climb, name .. ": each floor beside the last, at most one voxel up");
	check(room, name .. ": three voxels of air over every floor");
	check(support, name .. ": every voxel touches the ground or one put before it");
	check(last.x == top.x and last.y == top.y and last.z == top.z, name .. ": its top where asked");
	check(not refused, name .. ": nothing in a refused column");
	check(f ~= nil and math.abs(f.x - b.x) + math.abs(f.y - b.y) == 1,
		name .. ": its foot beside its lowest step");
	check(f ~= nil and f.z == ground(f.x, f.y) and f.z - b.z <= 1,
		name .. ": its foot's ground at most a voxel under the lowest step",
		f and string.format("foot z %d, step z %d", f.z, b.z));
	check(f ~= nil and not (spec.refuse ~= nil and spec.refuse(f.x, f.y)), name .. ": its foot not refused");
	local clear = f ~= nil;
	for z = (f and f.z or 0) - 3, (f and f.z or 0) - 1 do
		if (f ~= nil and cells[key(f.x, f.y, z)]) then clear = false; end
	end
	check(clear, name .. ": air for a body over its foot");
end

local TOP = {x = 200, y = 255, z = 40};

print("A. every kind on flat ground (the ground's top at z 50)");
for _, kind in ipairs(stair_kinds()) do
	local spec = {top = TOP, dx = -1, rows = {255, 256}, ground = function() return 50; end};
	local st, why = stair_lay(kind, spec);
	check(st ~= nil, kind .. ": laid", why);
	if (st ~= nil) then promises(kind, st, spec); end
end

print("B. a pit where the stair would end: the foot is a column a body climbs from");
for _, kind in ipairs(stair_kinds()) do
	-- the straight stair's lowest step lands at z 49 on column 191, and
	-- the column past it is a pit 10 deep
	local function pit(x, y) return (y == 255 and x == 190) and 60 or 50; end
	local spec = {top = TOP, dx = -1, rows = {255, 256}, ground = pit};
	local st, why = stair_lay(kind, spec);
	check(st ~= nil, kind .. ": laid", why);
	if (st ~= nil) then promises(kind .. " (pit)", st, spec); end
end

-- (straight and tapered: a switchback's or a spiral's foot is a column of
-- the stair's own footprint, which a refusal would take from the stair)
print("C. the column past the lowest step refused: the foot is another");
for _, kind in ipairs({"straight", "tapered"}) do
	local spec = {top = TOP, dx = -1, rows = {255, 256}, ground = function() return 50; end};
	local st = stair_lay(kind, spec);
	local want = st and {x = st.foot.x, y = st.foot.y};
	spec.refuse = function(x, y) return want ~= nil and x == want.x and y == want.y; end;
	local st2, why = stair_lay(kind, spec);
	check(st2 ~= nil, kind .. ": laid", why);
	if (st2 ~= nil) then promises(kind .. " (refused)", st2, spec); end
end

print("D. no way onto it: not laid, and why");
do
	-- the straight stair's bottom step on a one-column ledge in a deep pit
	local function ledge(x, y) return (x == 191 and y == 255) and 50 or 60; end
	local st, why = stair_lay("straight", {top = TOP, dx = -1, rows = {255}, ground = ledge});
	check(st == nil and why ~= nil, "straight on a ledge with nothing to climb from", why);
	local _, why2 = stair_lay("switchback", {top = TOP, dx = -1, rows = {255}, ground = function() return 50; end});
	check(why2 ~= nil, "a switchback with no second row", why2);
	local _, why3 = stair_lay("straight", {top = {x = 2, y = 255, z = 10}, dx = -1, rows = {255}, ground = function() return 50; end});
	check(why3 ~= nil, "a straight stair that runs off the map", why3);
	local _, why4 = stair_lay("winding", {top = TOP, dx = -1, ground = function() return 50; end});
	check(why4 ~= nil, "a kind there is none of", why4);
end

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
