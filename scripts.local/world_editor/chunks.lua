-- world_editor/chunks.lua -- Spatial authorization: who may edit what.
--
-- A "chunk" is a named region of the map with a permission attached.
-- Every block edit is resolved against them; anything not inside a
-- chunk falls back to a configurable default, so the whole map is
-- always covered by exactly one answer.
--
-- Shapes are box / cylinder / sphere (a "circle" is just a cylinder
-- spanning the full map height -- see the `circle` constructor).
--
-- Two things keep this fast and predictable:
--
--   * Lookup is indexed, not a linear scan. Every chunk registers
--     itself into the XY grid cells its bounding box touches, so
--     resolving a block only tests the handful of chunks that could
--     possibly contain it. Block edits are frequent (a block line is
--     dozens at once), so an O(#chunks) scan per block would bite.
--
--   * Overlap is resolved by priority, highest wins, ties broken by
--     creation order (later wins). That makes exceptions natural:
--     drop a small rw chunk inside a big ro one and it carves a hole
--     rather than fighting it.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local M = {};

local areas = require "world_editor.areas";

local CELL = 32;              -- XY index granularity, in blocks
local GRID = math.ceil(512/CELL);

-- chunks[id] = {id, name, shape, perm, prio, <shape fields>}
local chunks = {};
local nextid = 1;
local index = {};             -- cell key -> {chunk, ...}
local default = {mode="rw"};  -- out-of-chunk fallback

local function cellkey(cx, cy)
	return cy*GRID + cx;
end

-- ---------------------------------------------------------------- perms

-- "ro" | "rw" | "rw:<team>" -- team is the numeric team a writer must
-- be on; absent means everyone may write
function M.parse_perm(str)
	if (str == nil) then
		return nil;
	end
	str = string.lower(str);

	if (str == "ro" or str == "readonly") then
		return {mode="ro"};
	end

	local mode, team = string.match(str, "^(rw):(.+)$");
	if (mode == nil) then
		if (str == "rw" or str == "all" or str == "rwall") then
			return {mode="rw"};
		end
		return nil;
	end

	if (team == "all" or team == "*") then
		return {mode="rw"};
	end

	local n = tonumber(team);
	if (n == nil) then
		return nil;
	end
	return {mode="rw", team=n};
end

function M.format_perm(p)
	if (p == nil) then
		return "?";
	end
	if (p.mode == "ro") then
		return "ro";
	end
	if (p.team == nil) then
		return "rw";
	end
	return "rw:"..p.team;
end

function M.set_default(perm)
	default = perm;
end

function M.get_default()
	return default;
end

-- ---------------------------------------------------------------- shapes

-- Shape maths lives in areas.lua so chunks and component triggers can
-- never drift apart; a chunk *is* an area with a permission bolted on.
function M.shape_names()
	return areas.kinds();
end

-- ---------------------------------------------------------------- index

local function reindex_one(c)
	local x1, y1, x2, y2 = areas.bbox(c.area);

	-- clamp to the map so a fat radius near an edge doesn't spray cells
	x1 = math.max(0, math.min(511, x1));
	y1 = math.max(0, math.min(511, y1));
	x2 = math.max(0, math.min(511, x2));
	y2 = math.max(0, math.min(511, y2));

	for cy = math.floor(y1/CELL), math.floor(y2/CELL) do
		for cx = math.floor(x1/CELL), math.floor(x2/CELL) do
			local k = cellkey(cx, cy);
			index[k] = index[k] or {};
			table.insert(index[k], c);
		end
	end
end

local function reindex_all()
	index = {};
	for _, c in pairs(chunks) do
		reindex_one(c);
	end
end

-- ---------------------------------------------------------------- crud

-- c needs {area, perm}; name/prio optional
function M.add(c)
	if (not areas.valid(c.area)) then
		return nil, "unknown shape";
	end

	c.id = c.id or nextid;
	if (c.id >= nextid) then
		nextid = c.id + 1;
	end
	c.perm = c.perm or {mode="rw"};
	c.prio = c.prio or c.id;   -- later chunks win by default
	c.name = c.name or (c.area.kind.."#"..c.id);

	chunks[c.id] = c;
	reindex_one(c);
	return c;
end

function M.remove(id)
	if (chunks[id] == nil) then
		return false;
	end
	chunks[id] = nil;
	reindex_all();  -- cheap: chunk counts are small and edits are rare
	return true;
end

function M.all()
	return chunks;
end

function M.reset()
	chunks = {};
	index = {};
	nextid = 1;
	default = {mode="rw"};
end

-- ---------------------------------------------------------------- query

-- the winning chunk covering a block, or nil when none does
function M.at(x, y, z)
	if (x < 0 or x > 511 or y < 0 or y > 511) then
		return nil;
	end

	local bucket = index[cellkey(math.floor(x/CELL), math.floor(y/CELL))];
	if (bucket == nil) then
		return nil;
	end

	local best = nil;
	for i = 1, #bucket do
		local c = bucket[i];
		if ((best == nil or c.prio >= best.prio)
		    and areas.contains(c.area, x, y, z)) then
			best = c;
		end
	end
	return best;
end

function M.perm_at(x, y, z)
	local c = M.at(x, y, z);
	if (c == nil) then
		return default, nil;
	end
	return c.perm, c;
end

-- may this player edit this block? team 255 (spectators) never can
function M.can_write(pid, x, y, z)
	local p = M.perm_at(x, y, z);

	if (p.mode ~= "rw") then
		return false;
	end
	if (p.team == nil) then
		return true;
	end
	return get_team(pid) == p.team;
end

-- ---------------------------------------------------------------- json io

function M.serialize()
	local out = {};
	for _, c in pairs(chunks) do
		table.insert(out, {
			id=c.id, name=c.name, prio=c.prio,
			perm=M.format_perm(c.perm),
			area=areas.serialize(c.area),
		});
	end
	table.sort(out, function(a, b) return a.id < b.id; end);
	return out;
end

function M.deserialize(list)
	M.reset();
	if (list == nil) then
		return;
	end
	for _, e in ipairs(list) do
		local area = areas.deserialize(e.area);
		if (area ~= nil) then
			M.add({id=e.id, name=e.name, prio=e.prio, area=area,
			       perm=M.parse_perm(e.perm) or {mode="rw"}});
		end
	end
end

return M;
