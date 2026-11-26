-- lib_player_properties.lua -- The Player Properties protocol extension
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Player Properties extension (id 0, version 1):
-- the server tells a client the authoritative stats of one player --
-- HP, blocks, grenades, magazine and reserve ammo, score -- so it can
-- show them for players other than itself (a scoreboard, a spectator
-- view) and correct its own guesses about itself.
--
-- ONE SUB-PACKET, server to client only, always 12 bytes:
--   [64][0][pid][hp][blocks][grenades][mag][reserve][LE uint32 score]
-- The spec says what it carries and not when to send it, so this module
-- decides: whenever any of those values changes, and the whole set to a
-- client the moment it agrees to the extension.
--
-- WHEN, AND WHY BY POLLING. The values change in too many places to
-- hook them all -- set_hp from any script, damage, restock, kill() for
-- the score, set_ammo, the gunfire estimate that moves the magazine
-- inside the C tick with no hook at all. So once a tick the packet each
-- player WOULD be sent is built and compared, as a string, with the one
-- they were last sent; only a difference goes out. Building twelve
-- bytes per player per tick is a few C getters and one string.char,
-- and on a quiet server the wire stays silent. Every negotiated client
-- is told the same thing about the same player, so "last sent" is kept
-- once per subject rather than once per viewer, and a viewer that turns
-- up later is caught up by the ready callback instead.
--
-- WHERE EACH FIELD COMES FROM (all confirmed in lsd/src/lua.c and
-- lsd/apidoc/src/lua_playerget):
--   HP             get_hp(pid)
--   Magazine Ammo  get_mag_ammo(pid): min(estimate, best case), which
--                  the apidoc recommends over get_estimated_mag_ammo,
--                  the one that can run past the magazine. It is still
--                  an estimate -- LSd does not see the client's shots
--                  one by one -- and that is the best the server knows.
--   Reserve Ammo   get_reserve_ammo(pid)
--   Score          get_score(pid), a uint32_t in C (state.h:211), so
--                  the field's own width
--   Blocks         NO GETTER. struct Player has `blocks` (state.h:199)
--   Grenades       and `grenades` (:200), but lua.c exports neither. So
--                  this module keeps its own count, by the rules the
--                  core and the clients use: 50 and 3 on spawn_player
--                  and on every restock (main.c:929-930, :973-974);
--                  minus one per grenade thrown, which is exactly what
--                  the C sanity check does (funcs_packetrecv.c:324-325);
--                  minus one per block built, minus the length of a
--                  block line, plus one per block destroyed, clamped to
--                  0..50, which is what Voxlap and BetterSpades do with
--                  their own count (apidoc/src/event, on_block_action).
--                  The C never decrements its block count at all -- it
--                  is a TODO at main.c:928 -- so ours is the better
--                  number of the two, not a copy of a worse one.
--
-- Counted at the very top of the chain (xearly, before anything else
-- sees the packet), because the client spent the block or the grenade
-- when it sent it, whatever a script then does with it -- and because
-- that is where the C takes its grenade off. A protected area that
-- refuses the build does not give the client its block back, so neither
-- does this. A script that hands out blocks or grenades of its own, or
-- takes them, says so with player_properties_set_stock.
--
-- Restocks are caught where each kind can be: on restock, the event,
-- which every restock but one goes through and which a bot has too (no
-- Restock packet is ever made for a bot: the core sends a slot with no
-- client nothing, patches/lsd 0002); and on send_restock, for the one
-- that skips the event --
-- infinite_blocks calls server.restock, whose C still sends a person
-- the Restock packet (luaawk.h csend_restock). Both set the same full
-- stock, so a restock seen twice is the same restock.
--
-- WHO IS DESCRIBED: joined players on a team. A spectator has no HP,
-- ammo or blocks worth stating, and one in limbo has not joined. A
-- player who drops out of that set is not "cleared" on the wire --
-- there is no packet for it -- but is resent in full on coming back.
--
-- API (globals):
--   player_properties_supported(pid)  -> true once ext 0 is agreed
--   player_properties_encode(pid, hp, blocks, grenades, mag, reserve,
--        score) -> the 12-byte packet, every field clamped to its width
--   player_properties_send(viewer, subject) -> true if it went out
--        tell `viewer` about `subject` now, whether or not it changed
--   player_properties_get_stock(pid) -> blocks, grenades
--   player_properties_set_stock(pid, blocks, grenades)
--        for a script that gives or takes blocks or grenades itself;
--        nil leaves that one alone
local mod = init_mod();

local EXT_ID = 0;
local EXT_VERSION = 1;

-- 64 + the extension id, and sub-packet 0 is the only one there is.
local PKT = 64 + EXT_ID;
local SUB_PROPERTIES = 0;

-- What spawn_player and restock hand out (main.c:929-930, :973-974).
local FULL_BLOCKS = 50;
local FULL_GRENADES = 3;

getcfg("player_properties_auto", true,
	"Send every player's stats to the clients that speak Player "
		.."Properties whenever they change. Off leaves the API working "
		.."and the wire silent.");

local function negotiated(pid)
	return ext_supported ~= nil and ext_supported(pid, EXT_ID) ~= nil;
end

-- Our count of each player's blocks and grenades; see the header for why
-- there is one. Reset to a full stock when the slot is vacated, which is
-- harmless: spawning is the only way into the set that gets described,
-- and spawning restocks.
local blocks = pid_connected_table(FULL_BLOCKS);
local grenades = pid_connected_table(FULL_GRENADES);

-- pid -> the last packet every negotiated client was sent about them, or
-- nil when they have not been described since joining or since leaving
-- a team.
local last = pid_connected_table();

--============================== BYTES ===============================--

-- One UByte field. Truncated toward zero like the C int binding would,
-- then clamped: an HP of 300 set by some script is told as 255 rather
-- than wrapped round to 44.
local function u8(v)
	v = tonumber(v) or 0;
	if (v ~= v or v <= 0) then
		return 0;
	end
	return math.min(255, math.floor(v));
end

-- The score, LE uint32, out of arithmetic (no string.pack in LuaJIT).
-- Clamped rather than wrapped: the clients disagree on whether it is
-- signed (the spec says so), and a clamp reads the same on all of them.
local function le_u32(v)
	v = tonumber(v) or 0;
	if (v ~= v or v <= 0) then
		v = 0;
	end
	v = math.min(4294967295, math.floor(v));

	local out = {};
	for i = 1, 4 do
		out[i] = string.char(v % 256);
		v = math.floor(v / 256);
	end
	return table.concat(out);
end

function player_properties_encode(pid, hp, nblocks, ngrenades, mag, reserve,
                                  score)
	return string.char(PKT, SUB_PROPERTIES, u8(pid), u8(hp), u8(nblocks),
		u8(ngrenades), u8(mag), u8(reserve)) .. le_u32(score);
end

--============================ THE STATS =============================--

local function valid_pid(pid)
	return type(pid) == "number" and pid >= 0 and pid < MAX_PLAYERS
		and pid % 1 == 0;
end

-- The packet `pid` should be described by right now, or nil if they are
-- not someone this extension describes.
local function snapshot(pid)
	if (not is_joined(pid) or get_team(pid) == SPECTATOR) then
		return nil;
	end

	return player_properties_encode(pid, get_hp(pid), blocks[pid],
		grenades[pid], get_mag_ammo(pid), get_reserve_ammo(pid),
		get_score(pid));
end

--=============================== API ================================--

function player_properties_supported(pid)
	return negotiated(pid);
end

function player_properties_send(viewer, subject)
	if (not valid_pid(subject) or not negotiated(viewer)) then
		return false;
	end

	local pkt = snapshot(subject);
	if (pkt == nil) then
		return false;
	end

	send_packet(viewer, pkt);
	return true;
end

function player_properties_get_stock(pid)
	return blocks[pid], grenades[pid];
end

function player_properties_set_stock(pid, nblocks, ngrenades)
	if (not valid_pid(pid)) then
		return;
	end
	if (nblocks ~= nil) then
		blocks[pid] = u8(nblocks);
	end
	if (ngrenades ~= nil) then
		grenades[pid] = u8(ngrenades);
	end
end

--========================== BOOKKEEPING =============================--

local function restocked(pid)
	if (valid_pid(pid)) then
		blocks[pid] = FULL_BLOCKS;
		grenades[pid] = FULL_GRENADES;
	end
end

local function spend_blocks(pid, n)
	if (valid_pid(pid)) then
		blocks[pid] = math.max(0, math.min(FULL_BLOCKS, blocks[pid] - n));
	end
end

function mod.after.spawn_player(pid, pos)
	restocked(pid);
end

function mod.after.restock(pid)
	restocked(pid);
end

-- `from` is the player restocked: the C restock sends
-- send_restock(pid, pid) (main.c:934), and the Restock packet's player
-- id is whose stock it is.
function mod.after.send_restock(pid, from)
	restocked(from);
end

function mod.xearly.before.on_block_action(pid, pos, type)
	if (type == 0) then
		spend_blocks(pid, 1);
	elseif (type == 1) then
		spend_blocks(pid, -1);
	end
end

-- The length of a line is 1 + the Manhattan distance between its ends,
-- per the apidoc for on_block_line.
function mod.xearly.before.on_block_line(pid, startp, endp)
	spend_blocks(pid, 1 + math.abs(endp.x - startp.x)
		+ math.abs(endp.y - startp.y) + math.abs(endp.z - startp.z));
end

function mod.xearly.before.on_grenade(pid, pos, vel, fuse)
	if (valid_pid(pid)) then
		grenades[pid] = math.max(0, grenades[pid] - 1);
	end
end

--============================= THE TICK =============================--

-- Everyone who agreed, worked out once per tick, among the people only
-- (lib_bot's people_in: a bot agrees to nothing).
local function viewers()
	local out = {};
	for i in (people_in or piditer)(PID_BROADCAST) do
		if (negotiated(i)) then
			out[#out+1] = i;
		end
	end
	return out;
end

function mod.after.tick()
	if (not player_properties_auto) then
		return;
	end

	-- nobody to tell (a fleet of bots and no client that agreed): no
	-- snapshot of anybody either -- one who agrees later is told about
	-- everybody afresh (on_ready)
	local to = viewers();
	if (#to == 0) then
		return;
	end

	for pid in piditer(PID_BROADCAST) do
		local pkt = snapshot(pid);

		if (pkt ~= last[pid]) then
			last[pid] = pkt;

			if (pkt ~= nil) then
				for _, v in ipairs(to) do
					send_packet(v, pkt);
				end
			end
		end
	end
end

-- A client that has just agreed is told about everybody, since the
-- broadcasts it missed are not going to be repeated until something
-- changes. Fresh snapshots rather than `last`: if one differs, the next
-- tick sends it to everyone anyway, and this client is merely told
-- twice.
local function on_ready(viewer)
	if (not player_properties_auto) then
		return;
	end

	for pid in piditer(PID_BROADCAST) do
		player_properties_send(viewer, pid);
	end
end

--============================= INTAKE ===============================--
-- No client-to-server form. Anything arriving on packet 64 is swallowed
-- rather than logged by the core as "Unknown packet ID" each time
-- (funcs_packetrecv.c:484); returning 0 hands it to on_sane_packet,
-- whose switch has no case for it.
function mod.on_any_packet(pid, data)
	if (string.byte(data, 1) == PKT) then
		return 0;
	end

	return mod.next.on_any_packet(pid, data);
end

--============================ LIFECYCLE =============================--

function mod.on_load()
	if (ext_register == nil) then
		error("lib_player_properties needs lib_ext loaded first "
			.."(its script pulls lib_ext in; check with: lsdctl status)", 0);
	end

	ext_register("lib_player_properties", EXT_ID, EXT_VERSION, on_ready,
		"Player Properties");
end

-- Every global this module defines, removed on unload: consumers test
-- `player_properties_send ~= nil` to learn whether the extension is
-- there, and a leftover would answer yes for a module that is gone.
local EXPORTS = {
	"player_properties_supported",
	"player_properties_encode",
	"player_properties_send",
	"player_properties_get_stock",
	"player_properties_set_stock",
};

function mod.on_unload()
	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end

	for _, name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
