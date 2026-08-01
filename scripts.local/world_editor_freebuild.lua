-- world_editor_freebuild.lua -- Let builders place blocks without the rules
--
-- The block rules a client plays by are enforced in one place: LSd's
-- default on_any_packet (lsd/src/funcs_packetrecv.c), which decides a
-- packet is sane or crap. on_sane_packet then dispatches it to
-- on_block_action / on_block_line and does NOT re-check anything. Both
-- halves are hookable from Lua, so a script sitting on on_any_packet can
-- wave a packet through that the default would have thrown away.
--
-- That is the whole trick. With it, a client is free to implement its own
-- editor -- selections, clipboard, paste, whatever UX it likes -- and
-- express the result as ordinary block packets: place, delete, place
-- line, at any range, in mid-air, with an empty inventory. The server
-- stops arguing and just applies them. Nothing here draws anything
-- itself; it only stops saying no.
--
-- What is waived (all of it policy):
--
--   * alive        -- a spectator's block packets are dropped outright
--                     by the default, before any hook sees them
--   * reach        -- was never server-side to begin with; the vanilla
--                     client is what refuses to send from far away
--   * neighbours   -- a block had to touch another block
--   * inventory    -- the 50-block count, and the line-length limit
--                     derived from it
--   * tool match   -- build needed the block tool in hand, destroy the
--                     spade or gun
--   * occupancy    -- build onto an existing block was refused; allowing
--                     it makes a build packet a repaint, which is what
--                     block_action type 0 does anyway (unconditional
--                     set_solid + set_vox_color, lsd/src/main.c)
--
-- What is NOT waived, and must never be: the checks below are memory
-- safety, not rules. on_sane_packet hands the coordinates straight to
-- on_block_action -> set_solid(), which indexes the map with no bounds
-- check of its own, so a bad coordinate is an out-of-bounds write and a
-- crash any client could ask for. This script re-runs them itself before
-- waiving anything:
--
--   * the packet is exactly as long as its struct (parsing past the
--     buffer otherwise)
--   * 0 <= x,y < 512 and 0 <= z < 62
--   * the packet's playerID is the sender
--
-- z < 62 is also the engine floor and the client's connectivity Root
-- layer -- the same limit world_editor keeps away from, for the reasons
-- written up in its block api.
--
-- Scope is deliberately narrow: only while edit mode is on, only for
-- players who hold the builder cap, and only for the two block packets.
-- Everything else, and everybody else, is validated exactly as before.
-- Edit mode no longer refuses joins, so "every client, always" would
-- hand the map to whoever wandered in.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local mod = init_mod();

local bit = require("bit");

getcfg("world_editor_freebuild", true);   -- master switch

-- lsd/src/protocol.h: PacketTypeBlockAction = 13, PacketTypeBlockLine = 14
local BLOCK_ACTION = 13;
local BLOCK_LINE   = 14;

-- struct PacketBlockAction { u8 packetID, playerID, type; ivec3p pos; }
-- struct PacketBlockLine   { u8 packetID, playerID; ivec3p start, end; }
-- ivec3p is three packed int32, so both are header bytes plus 12 per vec.
local ACTION_LEN = 3 + 12;
local LINE_LEN   = 2 + 24;

-- The cap is granted only for as long as edit mode is on and dropped
-- again after (see world_editor's edit_start/edit_stop), so asking for it
-- answers "is this a builder, right now" without this script having to
-- know anything else about edit mode.
local CAP = "worldedit_build";

-- one little-endian int32 at `off` (1-based, as string.byte counts)
local function i32(data, off)
	local a, b, c, d = string.byte(data, off, off + 3);
	local v = bit.bor(a, bit.lshift(b, 8), bit.lshift(c, 16), bit.lshift(d, 24));
	-- bit.bor yields a signed 32-bit value in LuaJIT, which is what we
	-- want: a negative coordinate must fail the range test below, not
	-- wrap into it
	return v;
end

local function in_map(x, y, z)
	return x >= 0 and x < 512
	   and y >= 0 and y < 512
	   and z >= 0 and z < 62;
end

-- Everything the default would have checked for memory safety, and
-- nothing it checked for policy. Returns true when the packet is safe to
-- hand to on_sane_packet as-is.
local function safe_block_packet(pid, data)
	local id = string.byte(data, 1);

	if (id == BLOCK_ACTION) then
		if (#data ~= ACTION_LEN) then return false; end
		if (string.byte(data, 2) ~= pid) then return false; end
		-- type 3 is the grenade action; the default refuses it from a
		-- block packet and so do we -- it is a different code path
		local t = string.byte(data, 3);
		if (t ~= 0 and t ~= 1 and t ~= 2) then return false; end
		return in_map(i32(data, 4), i32(data, 8), i32(data, 12));
	end

	if (id == BLOCK_LINE) then
		if (#data ~= LINE_LEN) then return false; end
		if (string.byte(data, 2) ~= pid) then return false; end
		return in_map(i32(data, 3),  i32(data, 7),  i32(data, 11))
		   and in_map(i32(data, 15), i32(data, 19), i32(data, 23));
	end

	return false;   -- not ours; let the default have it
end

function mod.on_any_packet(pid, data)
	if (world_editor_freebuild and #data >= 1
	    and has_cap(pid, CAP) and safe_block_packet(pid, data)) then
		return 0;   -- sane: on_sane_packet will dispatch it unexamined
	end

	return mod.next.on_any_packet(pid, data);
end

return mod;
