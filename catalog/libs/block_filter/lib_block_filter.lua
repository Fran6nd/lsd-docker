-- lib_block_filter.lua -- The one question every edit of the map answers
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- A gamemode that keeps something standing -- babel's platform and tower
-- areas, a map's doors, the range's start wall, a course nobody may
-- build on -- says so ONCE, by answering one question:
--
--   function mod.may_edit_block(who, pos, type)
--       if (<pos is mine to guard>) then return false; end
--       local below = mod.next.may_edit_block;
--       return below == nil or below(who, pos, type);
--   end
--
--        who    the player the edit is for: a player's own action, a
--               bot's, an effect's owner's -- or nil, for the world's
--               own (the_fall) and for a script's
--        pos    one block {x, y, z}
--        type   0: that block would be built; 1: it would be taken
--
-- and the answer holds for everything that edits blocks, because it is
-- asked where they all meet, the three engine calls every edit ends in:
--
--   block_action_rm   every removal: a player's spade or gun, a grenade's
--                     crater, lib_bulk_destroy, a rocket's, a railgun's
--   block_action      every build (type 0)
--   block_line        every line of blocks
--
-- Asked per block: a spade's three and a grenade's 27 are each asked, and
-- when some are refused the rest are still taken, one by one, so a crater
-- beside a platform takes the ground and leaves the platform. Air is
-- never asked about, so a blast's cost is the solid blocks it reaches.
--
-- WHO. A player's own action carries its pid (the engine's `from`). What
-- the server does under the anonymous pid -- everything else -- says
-- whom it is for:
--
--   edit_as(who, fn, ...)    runs fn with its edits for `who` (a pid, or
--                            nil for the world): an effect's blast for
--                            its owner, a bot's dig for the bot. Without
--                            it, an anonymous edit is a script's: nobody's.
--   server_edit(fn, ...)     runs fn as the server rebuilding its own
--                            structures -- a door drawn, the range's wall
--                            raised -- which is not asked at all. Only
--                            the structure's owner has any business
--                            calling it.
--
-- tests/catalog_test.lua refuses an effect or a bot that edits blocks
-- without going through one of the two.
local mod = init_mod();

local NOBODY = false;       -- `actor` for the world and for scripts
local actor = NOBODY;       -- whom the anonymous pid's edits are for now
local serving = 0;          -- how deep in server_edit

function mod.impl.may_edit_block(who, pos, type)
	return true;
end

-- fn(...) with the context undone whether it returns or raises
local function finish(undo, ok, ...)
	undo();
	if (not ok) then
		error((...), 0);
	end
	return ...;
end

function mod.impl.edit_as(who, fn, ...)
	local before = actor;
	actor = who == nil and NOBODY or who;
	return finish(function() actor = before; end, pcall(fn, ...));
end

function mod.impl.server_edit(fn, ...)
	serving = serving + 1;
	return finish(function() serving = serving - 1; end, pcall(fn, ...));
end

-- Whom an edit by `from` is for, as may_edit_block takes it: nothing to
-- ask for the server's own, else true and the player (nil: nobody).
local function judge(from)
	if (serving > 0) then
		return false;
	end
	if (from == get_anon_pid()) then
		return true, actor ~= NOBODY and actor or nil;
	end
	return true, from;
end

local function may(who, x, y, z, type)
	return may_edit_block(who, {x = x, y = y, z = z}, type);
end

--========================== WHAT AN ACTION TAKES ========================--
-- The blocks main.c's block_action_rm takes for each type: those that are
-- solid now, which is all a removal is about.

local function take(cells, x, y, z)
	if (x >= 0 and x < 512 and y >= 0 and y < 512 and z >= 0 and z < 64
	    and is_solid({x = x, y = y, z = z})) then
		cells[#cells+1] = {x = x, y = y, z = z};
	end
end

local function footprint(pos, type)
	local cells = {};
	local x, y, z = pos.x, pos.y, pos.z;
	if (type == 1) then
		take(cells, x, y, z);
	elseif (type == 2) then
		if (z < 62) then take(cells, x, y, z); end
		if (z < 61) then take(cells, x, y, z + 1); end
		if (z > 0) then take(cells, x, y, z - 1); end
	elseif (type == 3) then
		for dz = -1, 1 do
			for dy = -1, 1 do
				for dx = -1, 1 do
					if (z + dz < 62) then take(cells, x + dx, y + dy, z + dz); end
				end
			end
		end
	end
	return cells;
end

--================================= HOOKS ================================--

function mod.early.block_action_rm(pos, type, from)
	local asked, who = judge(from);
	if (not asked or type == 0) then
		return mod.early.next.block_action_rm(pos, type, from);
	end

	local cells = footprint(pos, type);
	local yes = {};
	for i = 1, #cells do
		local c = cells[i];
		if (may(who, c.x, c.y, c.z, 1)) then
			yes[#yes+1] = c;
		end
	end

	if (#yes == #cells) then
		return mod.early.next.block_action_rm(pos, type, from);
	end
	-- some refused: the rest are taken one by one, each with its cull
	for i = 1, #yes do
		local mask = mod.early.next.block_action_rm(yes[i], 1, from);
		if (mask ~= 0) then
			block_action_cull(yes[i], mask);
		end
	end
	return 0;
end

function mod.early.block_action(pos, type, from)
	if (type == 0) then
		local asked, who = judge(from);
		if (asked and not may(who, pos.x, pos.y, pos.z, 0)) then
			return;
		end
	end
	return mod.early.next.block_action(pos, type, from);
end

function mod.early.block_line(start, stop, from)
	local asked, who = judge(from);
	if (asked) then
		-- a half-drawn line is worse than none
		for p in iter_block_line(start, stop) do
			if (not may(who, p.x, p.y, p.z, 0)) then
				return;
			end
		end
	end
	return mod.early.next.block_line(start, stop, from);
end

return mod;
