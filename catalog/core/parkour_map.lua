-- parkour_map.lua -- A parkour course over the sea, generated from a seed
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- Pure Lua, no server API: lsdctl writes the map with it when the
-- parkour gamemode is chosen, and the tests drive it directly. The same
-- seed is the same course, byte for byte.
--
--   local P = require "parkour_map";
--   local c = P.generate(seed);     -- the course
--   P.vxl(c)                        -- the .vxl, as a string
--   P.meta(c, "parkour")            -- its metadata .txt
--
-- THE COURSE is a walkway M.WIDTH wide rising out of water that kills,
-- from a start platform to the tent's. It runs east, with jogs north and
-- south, so no part ever comes back beside another: x only grows on the
-- eastward legs and a jog keeps to its own strip of x. Between two turns
-- a leg holds two obstacles; a checkpoint platform opens every eastward
-- leg but the first and the last. A course is
--
--   c.top[y * 512 + x]    the z of the column's top voxel (z grows
--                         downward); nil is water
--   c.color[y * 512 + x]  that voxel's {r, g, b}
--   c.start, c.tent       {x, y, z}: the middle of the two platforms
--   c.checkpoints         the same, in the order they are met
--   c.obstacles           the names of the obstacles, in order
--
-- WHAT A BODY CAN DO decides every obstacle (bot/NAV-STATUS.md, the
-- measured move table): a step of one is walked, two is a jump, a gap of
-- one or two is a standing jump and may land one higher or lower, a drop
-- of three does not hurt. Nothing here asks for more, so the engine's
-- bots run the course, and nothing asks for a diagonal jump or has a
-- ceiling. Every landing is three long (a body slides), and where the
-- way narrows there is more than one lane.
--
-- THE METADATA names the places for the gamemode, and says the water
-- kills (water_damage, which upstream's water_damage.lua applies and
-- lib_botlink tells the bots):
--
--   extensions = {
--       'water_damage' : 100,
--       'parkour_start' : (x, y, z),
--       'parkour_tent' : (x, y, z),
--       'parkour_checkpoints' : ((x, y, z), (x, y, z)),
--   }
local M = {};

M.SIZE = 512;
M.WATER = 63;    -- the z of the sea
M.WIDTH = 5;     -- the walkway, in columns
M.PLAZA = 9;     -- a platform's side: start, checkpoint, tent
M.MAX_GAP = 2;
M.MAX_CLIMB = 2;
M.MAX_DROP = 3;

local W = M.WIDTH;
local HIGH, LOW = 36, 56;   -- the walkway stays between these heights
local LEGS = 9;             -- east, jog, east, ... east

local COLORS = {
	water = {30, 110, 190},
	start = {70, 190, 90},
	checkpoint = {240, 200, 50},
	tent = {70, 120, 235},
	flat = {188, 188, 198},
	turn = {130, 150, 180},
	edge = {255, 140, 0},
	gap = {188, 188, 198},
	stairs = {222, 204, 150},
	kerb = {178, 130, 210},
	drop = {120, 200, 200},
	beams = {165, 115, 65},
	stones = {205, 95, 75},
	hurdles = {230, 120, 150},
	sbend = {110, 170, 120},
	pyramid = {222, 204, 150},
	holes = {150, 150, 160},
};

-- Park-Miller: the same numbers on every machine, which math.random is not
local function dice(seed)
	local s = math.floor(tonumber(seed) or 1) % 2147483646 + 1;
	return function(lo, hi)
		s = (s * 48271) % 2147483647;
		return lo + s % (hi - lo + 1);
	end
end

-- headings: forward and lateral, in columns
local HEADINGS = {
	E = {fx = 1, fy = 0, lx = 0, ly = 1},
	S = {fx = 0, fy = 1, lx = 1, ly = 0},
	N = {fx = 0, fy = -1, lx = 1, ly = 0},
};

--============================== LAYING ==============================--
-- The cursor (c.x, c.y) is the column at row 0, lane 0 of what comes
-- next; rows go forward, lanes across.

local function put(c, s, t, kind)
	local h = HEADINGS[c.heading];
	local x = c.x + h.fx * s + h.lx * t;
	local y = c.y + h.fy * s + h.ly * t;
	if (x < 8 or x > 503 or y < 8 or y > 503) then
		error("parkour_map: the course left the map", 0);
	end
	local i = y * 512 + x;
	if (c.top[i] ~= nil and c.owner[i] ~= c.piece) then
		error("parkour_map: the course crosses itself", 0);
	end
	c.top[i], c.color[i], c.owner[i] = c.z, COLORS[kind], c.piece;
end

local function advance(c, n)
	local h = HEADINGS[c.heading];
	c.x, c.y = c.x + h.fx * n, c.y + h.fy * n;
end

-- n rows, lanes t0..t1 (the whole width by default), then past them
local function rows(c, n, kind, t0, t1)
	for s = 0, n - 1 do
		for t = t0 or 0, t1 or W - 1 do put(c, s, t, kind); end
	end
	advance(c, n);
end

-- the row just laid, painted as the take-off before a gap or a drop
local function edge(c)
	local h = HEADINGS[c.heading];
	for t = 0, W - 1 do
		local i = (c.y - h.fy + h.ly * t) * 512 + c.x - h.fx + h.lx * t;
		if (c.top[i] ~= nil) then c.color[i] = COLORS.edge; end
	end
end

-- a platform wider than the walkway; returns its middle
local function plaza(c, kind)
	local side = M.PLAZA;
	local out = (side - W) / 2;
	for s = 0, side - 1 do
		for t = -out, W - 1 + out do put(c, s, t, kind); end
	end
	local h = HEADINGS[c.heading];
	local mid = (side - 1) / 2;
	local at = {x = c.x + h.fx * mid + h.lx * (W - 1) / 2,
		y = c.y + h.fy * mid + h.ly * (W - 1) / 2, z = c.z};
	advance(c, side);
	return at;
end

-- a square to turn on, and the cursor set for the new heading
local function turn(c, heading)
	local mx, my = c.x, c.y;
	if (c.heading == "N") then my = c.y - W + 1; end
	rows(c, W, "turn");
	c.heading = heading;
	if (heading == "E") then c.x, c.y = mx + W, my;
	elseif (heading == "S") then c.x, c.y = mx, my + W;
	else c.x, c.y = mx, my - 1; end
end

--============================= OBSTACLES ============================--
-- Each starts on ground already laid and ends on a landing of its own.
-- `up` is toward the sky: z - 1.

local function climb(c, r, most)
	-- a change of height that keeps the walkway between HIGH and LOW
	local dz = r(-most, most);
	if (c.z + dz < HIGH) then dz = most; end
	if (c.z + dz > LOW) then dz = -most; end
	return dz;
end

local OBSTACLES = {};

-- a gap of one or two, landing level, one up or one down
function OBSTACLES.gap(c, r)
	edge(c);
	advance(c, r(1, M.MAX_GAP));
	c.z = c.z + climb(c, r, 1);
	rows(c, 3, "gap");
end

function OBSTACLES.stairs(c, r)
	local dz = climb(c, r, 1);
	if (dz == 0) then dz = (c.z > 46) and -1 or 1; end
	for _ = 1, r(2, 4) do
		if (c.z + dz < HIGH or c.z + dz > LOW) then break; end
		c.z = c.z + dz;
		rows(c, 2, "stairs");
	end
end

-- two up at once: a jump
function OBSTACLES.kerb(c, r)
	if (c.z - M.MAX_CLIMB < HIGH) then return OBSTACLES.drop(c, r); end
	c.z = c.z - M.MAX_CLIMB;
	rows(c, 4, "kerb");
end

function OBSTACLES.drop(c, r)
	local d = r(2, M.MAX_DROP);
	if (c.z + d > LOW) then return OBSTACLES.kerb(c, r); end
	edge(c);
	c.z = c.z + d;
	rows(c, 4, "drop");
end

-- three beams one wide, side by side
function OBSTACLES.beams(c, r)
	local n = r(7, 11);
	for s = 0, n - 1 do
		for t = 0, W - 1, 2 do put(c, s, t, "beams"); end
	end
	advance(c, n);
	rows(c, 3, "flat");
end

-- pads to hop along, each shifted a lane from the last
function OBSTACLES.stones(c, r)
	local side = r(0, 1);
	for _ = 1, r(3, 4) do
		edge(c);
		advance(c, r(1, M.MAX_GAP));
		c.z = c.z + climb(c, r, 1);
		rows(c, 3, "stones", side, side + W - 2);
		side = 1 - side;
	end
	edge(c);
	advance(c, 1);
	rows(c, 3, "flat");
end

-- strips across the whole width, up and down
function OBSTACLES.hurdles(c, r)
	local dz = (c.z - 1 < HIGH) and 1 or -1;
	for _ = 1, 3 do
		edge(c);
		advance(c, r(1, M.MAX_GAP));
		c.z = c.z + dz;
		dz = -dz;
		rows(c, 3, "hurdles");
	end
end

-- a way two wide down one side, across, and down the other
function OBSTACLES.sbend(c, r)
	local left = r(0, 1) == 0;
	local n = r(4, 6);
	rows(c, n, "sbend", left and 0 or W - 2, left and 1 or W - 1);
	rows(c, 2, "sbend");
	rows(c, n, "sbend", left and W - 2 or 0, left and W - 1 or 1);
	rows(c, 2, "flat");
end

-- up a flight and down the other side
function OBSTACLES.pyramid(c, r)
	local n = math.min(r(2, 3), c.z - HIGH);
	if (n < 1) then return OBSTACLES.drop(c, r); end
	for _ = 1, n do c.z = c.z - 1; rows(c, 2, "pyramid"); end
	rows(c, 1, "pyramid");
	for _ = 1, n do c.z = c.z + 1; rows(c, 2, "pyramid"); end
end

-- a floor with holes in every other row
function OBSTACLES.holes(c, r)
	for _ = 1, r(3, 5) do
		local t = r(0, W - 2);
		for lane = 0, W - 1 do
			if (lane ~= t and lane ~= t + 1) then put(c, 0, lane, "holes"); end
		end
		advance(c, 1);
		rows(c, 1, "holes");
	end
	rows(c, 2, "flat");
end

local NAMES = {};
for name in pairs(OBSTACLES) do NAMES[#NAMES + 1] = name; end
table.sort(NAMES);
M.OBSTACLES = NAMES;

--============================== THE COURSE ==========================--

function M.generate(seed)
	seed = math.floor(tonumber(seed) or 1);
	local r = dice(seed);
	local c = {seed = seed, top = {}, color = {}, owner = {}, piece = 0,
		checkpoints = {}, obstacles = {},
		x = 96, y = 254, z = 48, heading = "E"};
	local last = nil;

	local function piece() c.piece = c.piece + 1; end

	local function obstacle()
		local name;
		repeat name = NAMES[r(1, #NAMES)]; until (name ~= last);
		last = name;
		c.obstacles[#c.obstacles + 1] = name;
		piece();
		OBSTACLES[name](c, r);
		rows(c, r(2, 3), "flat");
	end

	c.start = plaza(c, "start");
	for leg = 1, LEGS do
		piece();
		rows(c, 3, "flat");
		if (leg % 2 == 1 and leg > 1 and leg < LEGS) then
			c.checkpoints[#c.checkpoints + 1] = plaza(c, "checkpoint");
			rows(c, 2, "flat");
		end
		obstacle();
		obstacle();
		if (leg < LEGS) then
			piece();
			if (c.heading ~= "E") then
				turn(c, "E");
			elseif (c.y > 300) then
				turn(c, "N");
			elseif (c.y < 210) then
				turn(c, "S");
			else
				turn(c, r(0, 1) == 0 and "N" or "S");
			end
		end
	end
	piece();
	c.tent = plaza(c, "tent");

	c.owner, c.piece, c.x, c.y, c.z, c.heading = nil, nil, nil, nil, nil, nil;
	return c;
end

--=============================== THE FILES ==========================--

local function shade(rgb, f)
	return string.char(math.floor(rgb[3] * f), math.floor(rgb[2] * f), math.floor(rgb[1] * f), 255);
end

-- One span a column: the top voxel coloured, and every voxel under it
-- down to the sea (a column's sides show, and what shows needs a
-- colour), darker toward the water. Water is the sea bed alone.
function M.vxl(c)
	local sea = string.char(0, M.WATER, M.WATER, 0) .. shade(COLORS.water, 1);
	local made = {};
	local out = {};

	for y = 0, 511 do
		local row = {};
		for x = 0, 511 do
			local i = y * 512 + x;
			local top = c.top[i];
			if (top == nil) then
				row[x + 1] = sea;
			else
				local rgb = c.color[i];
				local light = ((x + y) % 2 == 0) and 1 or 0.9;
				local key = top .. ":" .. rgb[1] .. ":" .. rgb[2] .. ":" .. rgb[3] .. ":" .. light;
				local col = made[key];
				if (col == nil) then
					local parts = {string.char(0, top, M.WATER, 0), shade(rgb, light)};
					for z = top + 1, M.WATER do
						parts[#parts + 1] = shade(rgb, 0.6 - 0.3 * (z - top) / (M.WATER - top));
					end
					col = table.concat(parts);
					made[key] = col;
				end
				row[x + 1] = col;
			end
		end
		out[y + 1] = table.concat(row);
	end
	return table.concat(out);
end

local function tuple(p)
	return string.format("(%d, %d, %d)", p.x, p.y, p.z);
end

function M.meta(c, name)
	local cps = {};
	for i, p in ipairs(c.checkpoints) do cps[i] = tuple(p); end
	return table.concat({
		"name = '" .. name .. "'",
		"version = '1.0'",
		"author = 'lsdctl'",
		"description = 'A generated parkour course, seed " .. c.seed .. ".'",
		"extensions = {",
		"    'water_damage' : 100,",
		"    'parkour_seed' : " .. c.seed .. ",",
		"    'parkour_start' : " .. tuple(c.start) .. ",",
		"    'parkour_tent' : " .. tuple(c.tent) .. ",",
		"    'parkour_checkpoints' : (" .. table.concat(cps, ", ") .. (#cps == 1 and "," or "") .. "),",
		"}",
		"",
	}, "\n");
end

return M;
