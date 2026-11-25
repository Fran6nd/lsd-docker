-- range_map.lua -- A shooting range, generated from a seed
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- Pure Lua, no server API: lsdctl writes the map with it when the range
-- gamemode is chosen, and the tests drive it directly. The same seed is
-- the same range, byte for byte. One block is one metre.
--
--   local R = require "range_map";
--   local c = R.generate(seed);     -- the range
--   R.vxl(c)                        -- the .vxl, as a string
--   R.meta(c, "range")              -- its metadata .txt
--   R.solid(c, x, y, z)             -- is that voxel solid?
--
-- THE FACILITY is a block of wall M.WALL high with its rooms carved out
-- of it, so nothing is open that was not carved: a body can only be
-- where the plan says. North is -y; z grows downward and the floor is
-- the voxel at M.FLOOR.
--
--   y 244..247   the backstop, 10 high, the lane numbers on its face
--   y 250..299   the static range: M.LANES lanes, each M.LANE_W wide,
--                between dividers 3 high; a target is d metres from the
--                firing line (y 300) at y = 300 - d; a white line across
--                every 5 m, an orange one every 10, and the dividers'
--                tops painted the same
--   y 300..302   the firing positions (bays), one a lane, open behind
--   y 303..332   the plaza: the spawn, and the IPSC waiting area
--   x 262..285,  the IPSC course, walled 5 high: a hall, three rooms one
--   y 260..299   behind the other, each wall with a door and a port (a
--                window at eye height); the start box at its door, shut
--                off from the hall by the start wall; the end box in the
--                last room
--
-- THE TARGETS are data, the same for the generator, the metadata and
-- the gamemode: {set, kind, stance, motion, param, face, points}
--
--   set      "lane1".."lane5" or "ipsc"
--   kind     what a hit does to it:
--            "plate": nothing -- it never falls; the hit counts
--            "popper": the hit that counts drops it, and it stays down
--                    until its set is made ready for the next run
--            "noshoot": one of the shooter's own team; a hit is a
--                    penalty, and it never falls
--   stance   "stand" or "crouch"
--   motion   "static": points[1]
--            "rail": back and forth from points[1] to points[2] at
--                    param blocks a second
--            "blink": at each of points in turn, param seconds at each
--   face     the point the target faces, and from which it is in sight
--            (a lane's firing position, an IPSC shooting position)
--   points   {x, y, z}: the column, and the z of the voxel it stands on
--
-- THE START WALL is data too: the voxels of a wall one block thick
-- ({x0, y0, z0, x1, y1, z1}, z0 its top) and the colour it is built in,
-- every voxel of it painted that one colour so the server can build it
-- again as it was. It stands in the map; the gamemode brings it down for
-- a run and builds it again after.
--
-- Every lane has the same targets at the same distances (a time on one
-- lane is a time on any), shifted across; the seed varies the IPSC
-- course's targets within their rooms (the no-shoots go with the target
-- they stand by) and the lanes' offsets.
local M = {};

M.VERSION = 2;         -- of the metadata: a range written before is generated again

M.SIZE = 512;
M.FLOOR = 50;          -- the z of the floor voxel
M.WALL = 5;            -- the facility's and the course's walls
M.DIVIDER = 3;         -- between the lanes
M.BACKSTOP = 10;
M.LANES = 5;
M.LANE_W = 9;
M.LINE = 300;          -- the firing line: the bays are y >= LINE
M.BAY_D = 3;           -- bays, y LINE .. LINE + BAY_D - 1
M.LX = 200;            -- the first lane's west column

local FLOOR = M.FLOOR;
local LINE = M.LINE;

local COLORS = {
	grass = {96, 140, 72},
	ground = {120, 100, 80},
	wall = {150, 150, 145},
	divider = {120, 120, 118},
	backstop = {110, 85, 60},
	glyph = {245, 245, 245},
	line5 = {235, 235, 235},
	line10 = {255, 150, 40},
	rail = {60, 60, 66},
	plinth = {200, 60, 50},
	plaza = {170, 168, 160},
	spawn = {90, 180, 90},
	wait = {255, 170, 40},
	course = {205, 185, 140},
	cwall = {225, 225, 220},
	start = {70, 190, 90},
	finish = {70, 120, 235},
	swall = {96, 104, 122},
	position = {245, 215, 60},
	lanes = {
		{120, 150, 200}, {130, 190, 130}, {215, 200, 120}, {175, 140, 205}, {120, 195, 195},
	},
};

-- Park-Miller: the same numbers on every machine, which math.random is not
local function dice(seed)
	local s = math.floor(tonumber(seed) or 1) % 2147483646 + 1;
	return function(lo, hi)
		s = (s * 48271) % 2147483647;
		return lo + s % (hi - lo + 1);
	end
end

--============================= THE PLAN =============================--

local FAC = {x0 = 186, y0 = 240, x1 = 296, y1 = 336};

local function idx(x, y) return y * 512 + x; end

-- every column of the facility starts as wall
local function block(c)
	for y = FAC.y0, FAC.y1 do
		for x = FAC.x0, FAC.x1 do
			local i = idx(x, y);
			c.top[i], c.color[i] = FLOOR - M.WALL, COLORS.wall;
		end
	end
end

local function fill(c, x0, y0, x1, y1, height, rgb)
	for y = y0, y1 do
		for x = x0, x1 do
			local i = idx(x, y);
			c.top[i], c.color[i], c.air[i] = FLOOR - height, rgb, nil;
		end
	end
end

local function carve(c, x0, y0, x1, y1, rgb)
	fill(c, x0, y0, x1, y1, 0, rgb);
end

local function paint(c, x0, y0, x1, y1, rgb)
	for y = y0, y1 do
		for x = x0, x1 do c.color[idx(x, y)] = rgb; end
	end
end

-- a window through a wall: those voxels of those columns are air
local function port(c, x0, y0, x1, y1, z0, z1)
	for y = y0, y1 do
		for x = x0, x1 do
			local i = idx(x, y);
			c.air[i] = c.air[i] or {};
			for z = z0, z1 do c.air[i][z] = true; end
		end
	end
end

-- a 3x5 digit painted on the south face of a wall
local DIGITS = {
	["1"] = {"010", "110", "010", "010", "111"},
	["2"] = {"111", "001", "111", "100", "111"},
	["3"] = {"111", "001", "111", "001", "111"},
	["4"] = {"101", "101", "111", "001", "001"},
	["5"] = {"111", "100", "111", "001", "111"},
};

local function glyph(c, ch, x, y, z)
	for row, bits in ipairs(DIGITS[ch]) do
		for col = 1, 3 do
			if (string.sub(bits, col, col) == "1") then
				local i = idx(x + col - 1, y);
				c.paint[i] = c.paint[i] or {};
				c.paint[i][z + row - 1] = COLORS.glyph;
			end
		end
	end
end

local function pt(x, y, z) return {x = x, y = y, z = z or FLOOR}; end

-- a target standing on a plinth h high (0: on the floor)
local function plinth(c, x, y, h)
	if (h > 0) then
		fill(c, x, y, x, y, h, COLORS.plinth);
	end
	return pt(x, y, FLOOR - h);
end

--=========================== THE STATIC RANGE =======================--

M.LANE_TARGETS = {
	-- d (from the firing line), offset across, stance, plinth
	{d = 5, o = 2, stance = "stand", h = 0},
	{d = 10, o = -3, stance = "crouch", h = 0},
	{d = 15, o = 3, stance = "stand", h = 0},
	{d = 25, o = -1, stance = "crouch", h = 1},
	{d = 35, o = -3, stance = "stand", h = 2},
	{d = 50, o = -2, stance = "stand", h = 3},
};
M.RAIL = {d = 20, from = -3, to = 3, speed = 2.5, stance = "stand"};
M.BLINK = {period = 1.5, stance = "stand", at = {{d = 30, o = -3}, {d = 40, o = 3}, {d = 45, o = 0}}};

local function static_range(c, r)
	local x_end = M.LX + M.LANES * (M.LANE_W + 1) - 1;   -- the east divider
	-- the lanes, downrange to the backstop, and the bays
	for k = 1, M.LANES do
		local x0 = M.LX + (k - 1) * (M.LANE_W + 1);
		carve(c, x0, LINE - 50, x0 + M.LANE_W - 1, LINE + M.BAY_D - 1, COLORS.lanes[k]);
		-- the inner dividers, 3 high, bays included
		if (k > 1) then
			fill(c, x0 - 1, LINE - 50, x0 - 1, LINE + M.BAY_D - 1, M.DIVIDER, COLORS.divider);
		end
	end
	fill(c, M.LX - 1, LINE - 56, x_end, LINE - 51, M.BACKSTOP, COLORS.backstop);
	-- a line across the lanes every 5 m, and the dividers' tops
	for d = 5, 50, 5 do
		local rgb = d % 10 == 0 and COLORS.line10 or COLORS.line5;
		paint(c, M.LX - 1, LINE - d, x_end, LINE - d, rgb);
	end
	paint(c, M.LX, LINE, x_end - 1, LINE, COLORS.line10);    -- the firing line

	-- the same targets in every lane, the seed's shift across them
	local shift = r(-1, 1);
	c.lanes = {};
	for k = 1, M.LANES do
		local x0 = M.LX + (k - 1) * (M.LANE_W + 1);
		local cx = x0 + (M.LANE_W - 1) / 2;
		glyph(c, tostring(k), cx - 1, LINE - 51, FLOOR - 9);
		local bay = {x0 = x0, y0 = LINE, x1 = x0 + M.LANE_W - 1, y1 = LINE + M.BAY_D - 1, z = FLOOR};
		local face = pt(cx, LINE + 1);
		c.lanes[k] = bay;
		local set = "lane" .. k;
		local function across(o) return cx + math.max(-3, math.min(3, o + shift)); end
		for _, t in ipairs(M.LANE_TARGETS) do
			c.targets[#c.targets + 1] = {set = set, kind = "plate", stance = t.stance, motion = "static",
				param = 0, face = face, points = {plinth(c, across(t.o), LINE - t.d, t.h)}};
		end
		paint(c, cx + M.RAIL.from, LINE - M.RAIL.d, cx + M.RAIL.to, LINE - M.RAIL.d, COLORS.rail);
		c.targets[#c.targets + 1] = {set = set, kind = "plate", stance = M.RAIL.stance, motion = "rail",
			param = M.RAIL.speed, face = face, points = {pt(cx + M.RAIL.from, LINE - M.RAIL.d), pt(cx + M.RAIL.to, LINE - M.RAIL.d)}};
		local at = {};
		for j, p in ipairs(M.BLINK.at) do at[j] = pt(across(p.o), LINE - p.d); end
		c.targets[#c.targets + 1] = {set = set, kind = "plate", stance = M.BLINK.stance, motion = "blink",
			param = M.BLINK.period, face = face, points = at};
	end
end

--============================ THE IPSC COURSE =======================--
-- In the course's own frame: u across (x = IX + u), v from the door
-- inward (y = IY - v). Rooms are v 0..9, 11..19, 21..29, 31..39; walls
-- at v 10, 20 and 30, each with a door 3 wide and a port 2 wide at eye
-- height.
local IX, IY = 262, 299;
M.IPSC_W, M.IPSC_L = 24, 40;
local PORT_Z0, PORT_Z1 = FLOOR - 3, FLOOR - 2;   -- z 47..48: eye height

local function cx_(u) return IX + u; end
local function cy_(v) return IY - v; end

M.IPSC_WALLS = {
	{v = 10, door = 18, port = 9},
	{v = 20, door = 2, port = 14},
	{v = 30, door = 20, port = 8},
};
M.IPSC_POSITIONS = {{u = 11, v = 6}, {u = 19, v = 13}, {u = 3, v = 23}, {u = 21, v = 33}};
-- u, v: where in its room; ru, rv: how far the seed may move it
M.IPSC_TARGETS = {
	{u = 2, v = 8, stance = "stand", h = 0, from = 1, ru = 1, rv = 0},
	{u = 21, v = 8, stance = "crouch", h = 0, from = 1, ru = 1, rv = 0},
	{u = 9, v = 15, stance = "crouch", h = 0, from = 2, ru = 2, rv = 1},
	{u = 3, v = 18, stance = "stand", h = 1, from = 2, ru = 1, rv = 0},
	{u = 11, v = 25, stance = "stand", h = 0, from = 3, ru = 2, rv = 1},
	{u = 21, v = 28, stance = "crouch", h = 0, from = 3, ru = 1, rv = 0},
	{u = 10, v = 37, stance = "stand", h = 0, from = 4, ru = 2, rv = 1},
	{u = 15, v = 38, stance = "stand", h = 2, from = 4, ru = 2, rv = 0},
	{u = 2, v = 32, stance = "crouch", h = 0, from = 4, ru = 0, rv = 0},
};
M.IPSC_RAIL = {v = 27, from = 8, to = 16, speed = 3, stance = "stand", from_pos = 3};
-- the no-shoots: each by one of the targets above (its index there), du
-- and dv from where the seed put it, shot at from the same position --
-- standing behind a crouched one, beside one by a door, half behind one
M.IPSC_NOSHOOTS = {
	{near = 2, du = -1, dv = 1, stance = "stand"},    -- behind, by the door to the second room
	{near = 4, du = 1, dv = 0, stance = "stand"},     -- beside, by the door to the third
	{near = 5, du = 1, dv = -1, stance = "stand"},    -- half behind
	{near = 9, du = -1, dv = 0, stance = "stand"},    -- behind, by the door in
};
-- the start wall: across the hall, between the start box and the rest
M.START_WALL_V = 4;

local function box(u0, v0, u1, v1)
	return {x0 = cx_(math.min(u0, u1)), y0 = cy_(math.max(v0, v1)),
		x1 = cx_(math.max(u0, u1)), y1 = cy_(math.min(v0, v1)), z = FLOOR};
end

local function ipsc(c, r)
	local W, L = M.IPSC_W, M.IPSC_L;
	for _, room in ipairs({{0, 9}, {11, 19}, {21, 29}, {31, 39}}) do
		carve(c, cx_(0), cy_(room[2]), cx_(W - 1), cy_(room[1]), COLORS.course);
	end
	for _, w in ipairs(M.IPSC_WALLS) do
		paint(c, cx_(0), cy_(w.v), cx_(W - 1), cy_(w.v), COLORS.cwall);
		carve(c, cx_(w.door), cy_(w.v), cx_(w.door + 2), cy_(w.v), COLORS.course);
		port(c, cx_(w.port), cy_(w.v), cx_(w.port + 1), cy_(w.v), PORT_Z0, PORT_Z1);
	end
	-- the outer walls, white like the inner ones
	paint(c, cx_(-1), cy_(L), cx_(W), cy_(L), COLORS.cwall);
	paint(c, cx_(-1), cy_(L), cx_(-1), cy_(-1), COLORS.cwall);
	paint(c, cx_(W), cy_(L), cx_(W), cy_(-1), COLORS.cwall);
	paint(c, cx_(-1), cy_(-1), cx_(W), cy_(-1), COLORS.cwall);
	-- the door in, and the way to it from the plaza
	carve(c, cx_(10), cy_(-1), cx_(13), LINE + M.BAY_D - 1, COLORS.course);

	c.ipsc = {
		area = box(0, 0, W - 1, L - 1),
		start = box(9, 0, 14, 3),
		finish = box(1, 35, 5, 38),
		wait = {x0 = cx_(8), y0 = LINE + 4, x1 = cx_(15), y1 = LINE + 8, z = FLOOR},
		positions = {},
	};
	local function paint_box(b, rgb) paint(c, b.x0, b.y0, b.x1, b.y1, rgb); end
	paint_box(c.ipsc.start, COLORS.start);
	paint_box(c.ipsc.finish, COLORS.finish);
	paint_box(c.ipsc.wait, COLORS.wait);
	for k, p in ipairs(M.IPSC_POSITIONS) do
		c.ipsc.positions[k] = pt(cx_(p.u), cy_(p.v));
		paint(c, cx_(p.u - 1), cy_(p.v + 1), cx_(p.u + 1), cy_(p.v - 1), COLORS.position);
	end
	local placed = {};
	for k, t in ipairs(M.IPSC_TARGETS) do
		local u, v = t.u + r(-t.ru, t.ru), t.v + r(-t.rv, t.rv);
		placed[k] = {u = u, v = v};
		c.targets[#c.targets + 1] = {set = "ipsc", kind = "popper", stance = t.stance, motion = "static",
			param = 0, face = c.ipsc.positions[t.from], points = {plinth(c, cx_(u), cy_(v), t.h)}};
	end
	local R = M.IPSC_RAIL;
	paint(c, cx_(R.from), cy_(R.v), cx_(R.to), cy_(R.v), COLORS.rail);
	c.targets[#c.targets + 1] = {set = "ipsc", kind = "popper", stance = R.stance, motion = "rail",
		param = R.speed, face = c.ipsc.positions[R.from_pos],
		points = {pt(cx_(R.from), cy_(R.v)), pt(cx_(R.to), cy_(R.v))}};
	for _, n in ipairs(M.IPSC_NOSHOOTS) do
		local at, t = placed[n.near], M.IPSC_TARGETS[n.near];
		c.targets[#c.targets + 1] = {set = "ipsc", kind = "noshoot", stance = n.stance, motion = "static",
			param = 0, face = c.ipsc.positions[t.from], points = {pt(cx_(at.u + n.du), cy_(at.v + n.dv))}};
	end

	-- the start wall, as high as the course's: the hall's whole width
	local y = cy_(M.START_WALL_V);
	c.ipsc.wall = {x0 = cx_(0), y0 = y, z0 = FLOOR - M.WALL, x1 = cx_(W - 1), y1 = y, z1 = FLOOR - 1,
		color = COLORS.swall};
	fill(c, cx_(0), y, cx_(W - 1), y, M.WALL, COLORS.course);
	for x = cx_(0), cx_(W - 1) do
		local i = idx(x, y);
		c.paint[i] = c.paint[i] or {};
		for z = FLOOR - M.WALL, FLOOR - 1 do c.paint[i][z] = COLORS.swall; end
	end
end

--============================== THE RANGE ===========================--

function M.generate(seed)
	seed = math.floor(tonumber(seed) or 1);
	local r = dice(seed);
	local c = {seed = seed, top = {}, color = {}, air = {}, paint = {}, targets = {}};
	block(c);
	-- the plaza, and its spawn mark
	carve(c, 190, LINE + M.BAY_D, 292, LINE + 32, COLORS.plaza);
	c.spawn = pt(236, LINE + 18);
	paint(c, c.spawn.x - 2, c.spawn.y - 2, c.spawn.x + 2, c.spawn.y + 2, COLORS.spawn);
	static_range(c, r);
	ipsc(c, r);
	return c;
end

-- the solid voxels, as the server will have them; off the map is air
function M.solid(c, x, y, z)
	if (x < 0 or x > 511 or y < 0 or y > 511 or z < 0) then return false; end
	if (z > 63) then return true; end
	local i = idx(x, y);
	local top = c.top[i] or FLOOR;
	local air = c.air[i];
	return z >= top and not (air ~= nil and air[z]);
end

--=============================== THE FILES ==========================--

local function shade(rgb, f)
	return string.char(math.floor(rgb[3] * f), math.floor(rgb[2] * f), math.floor(rgb[1] * f), 255);
end

-- A column's spans: each solid run, all of it coloured (no hidden
-- voxels), the last down to the bottom of the map.
local function column(c, i, light)
	local top = c.top[i] or FLOOR;
	local rgb = c.color[i] or COLORS.grass;
	local air, pnt = c.air[i], c.paint[i];
	local runs, s = {}, nil;
	for z = top, 63 do
		local solid = not (air ~= nil and air[z]);
		if (solid and s == nil) then s = z; end
		if ((not solid or z == 63) and s ~= nil) then
			runs[#runs + 1] = {s, solid and z or z - 1};
			s = nil;
		end
	end
	local out, air_start = {}, 0;
	for k, run in ipairs(runs) do
		local last = k == #runs;
		local n = last and 0 or 1 + run[2] - run[1] + 1;
		out[#out + 1] = string.char(n, run[1], run[2], air_start);
		for z = run[1], run[2] do
			local p = pnt ~= nil and pnt[z];
			if (p) then
				out[#out + 1] = shade(p, 1);
			elseif (z <= FLOOR) then
				-- the floor voxel is lit like a top even under a wall: it
				-- is one when the start wall comes down
				out[#out + 1] = shade(rgb, (z == top or z == FLOOR) and light or 0.85 * light);
			else
				out[#out + 1] = shade(COLORS.ground, 0.7 - 0.3 * (z - FLOOR) / (63 - FLOOR));
			end
		end
		air_start = run[2] + 1;
	end
	return table.concat(out);
end

function M.vxl(c)
	local made = {};
	local out = {};
	for y = 0, 511 do
		local row = {};
		for x = 0, 511 do
			local i = idx(x, y);
			local light = ((x + y) % 2 == 0) and 1 or 0.93;
			if (c.top[i] == nil) then
				made[light] = made[light] or column(c, i, light);
				row[x + 1] = made[light];
			else
				row[x + 1] = column(c, i, light);
			end
		end
		out[y + 1] = table.concat(row);
	end
	return table.concat(out);
end

local function tuple(p)
	return string.format("(%d, %d, %d)", p.x, p.y, p.z);
end

local function boxt(b)
	return string.format("(%d, %d, %d, %d, %d)", b.x0, b.y0, b.x1, b.y1, b.z);
end

local function list(items)
	return "(" .. table.concat(items, ", ") .. (#items == 1 and "," or "") .. ")";
end

-- A target as one tuple: ('lane1', 'plate', 'stand', 'rail', 2.5, face, p1, p2)
function M.target_tuple(t)
	local pts = {};
	for k, p in ipairs(t.points) do pts[k] = tuple(p); end
	return string.format("('%s', '%s', '%s', '%s', %s, %s, %s)", t.set, t.kind, t.stance, t.motion,
		tostring(t.param), tuple(t.face), table.concat(pts, ", "));
end

-- The wall as ((x0, y0, z0), (x1, y1, z1), (r, g, b))
function M.wall_tuple(w)
	return string.format("((%d, %d, %d), (%d, %d, %d), (%d, %d, %d))", w.x0, w.y0, w.z0, w.x1, w.y1, w.z1,
		w.color[1], w.color[2], w.color[3]);
end

function M.meta(c, name)
	local lanes, targets = {}, {};
	for k, b in ipairs(c.lanes) do lanes[k] = boxt(b); end
	for k, t in ipairs(c.targets) do targets[k] = M.target_tuple(t); end
	return table.concat({
		"name = '" .. name .. "'",
		"version = '1.0'",
		"author = 'lsdctl'",
		"description = 'A generated shooting range, seed " .. c.seed .. ".'",
		"extensions = {",
		"    'range_version' : " .. M.VERSION .. ",",
		"    'range_seed' : " .. c.seed .. ",",
		"    'range_spawn' : " .. tuple(c.spawn) .. ",",
		"    'range_lanes' : " .. list(lanes) .. ",",
		"    'range_ipsc' : " .. boxt(c.ipsc.area) .. ",",
		"    'range_ipsc_start' : " .. boxt(c.ipsc.start) .. ",",
		"    'range_ipsc_end' : " .. boxt(c.ipsc.finish) .. ",",
		"    'range_ipsc_wait' : " .. boxt(c.ipsc.wait) .. ",",
		"    'range_ipsc_wall' : " .. M.wall_tuple(c.ipsc.wall) .. ",",
		"    'range_targets' : " .. list(targets) .. ",",
		"}",
		"",
	}, "\n");
end

return M;
