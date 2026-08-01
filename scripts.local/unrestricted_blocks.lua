-- unrestricted_blocks.lua -- Accept block packets the server would refuse
--
-- Sibling of stock infinite_blocks.lua: that one lifts the supply limit,
-- this one lifts the placement rules.
--
-- Those rules all live in one place -- LSd's default on_any_packet
-- (lsd/src/funcs_packetrecv.c), which decides a packet is sane or crap.
-- on_sane_packet then dispatches it to on_block_action / on_block_line
-- and re-checks nothing. Both halves are hookable, so returning "sane"
-- from here waves a packet through that the default would have thrown
-- away.
--
-- That is what lets a client bring its own editor. It can implement
-- whatever UX it likes -- selections, a clipboard, paste, preview -- and
-- express the result as ordinary block packets: place, delete, place
-- line, at any range, in mid-air, with an empty inventory. This script
-- draws nothing itself; it only stops the server saying no.
--
-- Waived, all of it policy:
--
--   * alive      -- a spectator's block packets are dropped outright by
--                   the default, before any hook sees them
--   * reach      -- never server-side anyway; the stock client is what
--                   refuses to send from far away
--   * neighbours -- a block had to touch another block
--   * inventory  -- the 50-block count, and the line length derived
--                   from it
--   * tool match -- build needed the block tool, destroy the spade or gun
--   * occupancy  -- building onto an existing block was refused, which
--                   only made it a repaint (block_action type 0 is an
--                   unconditional set_solid + set_vox_color anyway)
--
-- NOT waived, and never to be: the checks below are memory safety, not
-- rules. on_sane_packet hands the coordinates straight to
-- on_block_action -> set_solid(), which indexes the map with no bounds
-- check of its own, so a bad coordinate is an out-of-bounds write that
-- any client could ask for. They are re-run here before anything is
-- waived: the packet must be exactly as long as its struct, 0<=x,y<512
-- and 0<=z<62, and its playerID must be the sender. z<62 is also the
-- engine floor and the client's connectivity Root layer.
--
-- THE CAP IS THE WHOLE GATE. Anyone holding it can rewrite the map from
-- anywhere, so grant it narrowly and never from a cap group.
-- world_editor grants the default cap only for as long as edit mode is
-- on and drops it again afterwards, which is the intended pairing --
-- but this script does not depend on world_editor and works with any
-- scheme that hands out the cap.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local mod = init_mod();

local bit = require("bit");

getcfg("unrestricted_blocks", true);                   -- master switch
getcfg("unrestricted_blocks_cap", "worldedit_build");  -- who gets to bypass

-- lsd/src/protocol.h: PacketTypeBlockAction = 13, PacketTypeBlockLine = 14.
-- struct PacketBlockAction { u8 packetID, playerID, type; ivec3p pos; }
-- struct PacketBlockLine   { u8 packetID, playerID; ivec3p start, end; }
-- ivec3p is three packed int32, so both are header bytes plus 12 per vec.
local BLOCK_ACTION, ACTION_LEN = 13, 3 + 12;
local BLOCK_LINE,   LINE_LEN   = 14, 2 + 24;

-- one little-endian int32 at `off` (1-based, as string.byte counts).
-- bit.bor yields a signed 32-bit value in LuaJIT, which is what we want:
-- a negative coordinate must fail the range test, not wrap into it.
local function i32(data, off)
	local a, b, c, d = string.byte(data, off, off + 3);
	return bit.bor(a, bit.lshift(b, 8), bit.lshift(c, 16), bit.lshift(d, 24));
end

local function in_map(x, y, z)
	return x >= 0 and x < 512
	   and y >= 0 and y < 512
	   and z >= 0 and z < 62;
end

-- everything the default checks for memory safety, and none of what it
-- checks for policy
local function safe_block_packet(pid, data)
	local id = string.byte(data, 1);

	if (id == BLOCK_ACTION) then
		if (#data ~= ACTION_LEN) then return false; end
		if (string.byte(data, 2) ~= pid) then return false; end
		-- type 3 is the grenade action: a different code path, and the
		-- default refuses it from a block packet too
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
	if (unrestricted_blocks and #data >= 1
	    and has_cap(pid, unrestricted_blocks_cap)
	    and safe_block_packet(pid, data)) then
		return 0;   -- sane: on_sane_packet dispatches it unexamined
	end

	return mod.next.on_any_packet(pid, data);
end

return mod;
