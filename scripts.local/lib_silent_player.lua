-- lib_silent_player.lua -- The Silent Player protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Silent Player extension (id 3, version 1): the
-- server tells a client to leave certain player ids out of its own
-- furniture -- the scoreboard, the player count, the join and leave
-- notices, the kill feed, its statistics -- without changing anything
-- about the players themselves.
--
-- A silent player is still a player. They are drawn, heard, shot at and
-- shot by, they chat, and the packets that carry all of that are
-- untouched. The flags say what a client may mention, not what exists.
-- That is the whole of it, and it is why this is safe to point at bots:
-- nothing about the game changes, only the bookkeeping the client shows
-- around it.
--
-- WHAT THIS IS FOR HERE: the Fall's fallers. Four bots dropping down the
-- shaft forever are targets, not opponents -- they have no business on
-- the scoreboard, in the player count, or announcing themselves every
-- time they respawn. But a player who kills one has done something, and
-- the kill feed is where that is said. So they are hidden everywhere
-- except the feed, which is exactly a flag mask.
--
-- API (globals):
--   silent_set(target, flags)   set the mask for a player id
--   silent_get(target)          -> the mask this server holds for it
--   silent_clear(target)        the same as silent_set(target, 0)
--   silent_supported(pid)       -> true once ext 3 is agreed with pid
--
--   SILENT_HIDE_ROSTER / SILENT_HIDE_PRESENCE
--   SILENT_HIDE_KILLFEED / SILENT_NO_STATS
--   SILENT_ALL                  every flag, for "hide this one entirely"
--
-- Negotiation belongs to lib_ext, which announces every extension in one
-- ExtensionInfo. Load it first.
--
-- WHAT THIS DOES NOT DO: sub-packet 0, Create Silent Player. See the
-- bottom of the file -- it is a deliberate omission, not an oversight,
-- and this module is complete without it for the way flags are used.
local mod = init_mod();
local bit = require("bit");

local EXT_ID = 3;
local EXT_VERSION = 1;

-- Base id is 64 + extension id.
local PKT = 64 + EXT_ID;
local SUB_CREATE = 0;    -- S->C  Create Silent Player (not sent, see below)
local SUB_SET_FLAGS = 1; -- S->C  [PKT][1][(pid, flags) x n]

-- Both sub-packets are Server to Client. A client has nothing to say in
-- this extension at all -- it does not ask to be hidden and it does not
-- ask about anybody else -- so any packet 67 arriving from one is
-- dropped unread. There is no table of what a client may send because
-- the answer is nothing.

-- Flag bits.
SILENT_HIDE_ROSTER = 1;   -- bit 0: off the scoreboard, out of the count
SILENT_HIDE_PRESENCE = 2; -- bit 1: no join/team/leave notices
SILENT_HIDE_KILLFEED = 4; -- bit 2: no kill feed entries, either way
SILENT_NO_STATS = 8;      -- bit 3: ignored by client-side stats
-- Bits 4-7 are reserved and must go out clear. A client is told to
-- ignore what it does not know, but setting one is still claiming a
-- feature a later version defines and this one cannot honour.
local FLAG_MASK = 15;

SILENT_ALL = FLAG_MASK;

-- The most entries the spec recommends in one Set Flags: 126 pairs plus
-- the two header bytes fits the 255-byte budget. Player ids being a byte
-- and a server holding at most a couple of hundred of them, this is a
-- ceiling that is never reached in practice -- but a snapshot is built
-- from however many ids happen to be flagged, so it is honoured rather
-- than assumed.
local MAX_ENTRIES = 126;

-- target pid -> mask. The server's own record of what it has told
-- clients, which is what a late joiner is caught up from.
--
-- Not a pid_connected_table: those clear on disconnect, and clearing is
-- exactly what must NOT happen quietly here. The spec has the client
-- drop an id's flags when Player Left arrives, so both ends forget
-- together; a table that cleared itself on our side would leave us
-- believing an id was already clean while some client that missed the
-- Player Left still had it flagged. Dropped explicitly below instead, so
-- there is one place where forgetting happens.
local flags = {};

--============================== THE WIRE ============================--

local function put_entries(pairs_)
	local out = {string.char(PKT, SUB_SET_FLAGS)};

	for _,e in ipairs(pairs_) do
		out[#out+1] = string.char(e[1], bit.band(e[2], FLAG_MASK));
	end

	return table.concat(out);
end

-- Everyone who has agreed to hear this.
local function each_listener()
	return piditer(PID_BROADCAST);
end

local function send_entries(pid, pairs_)
	if (#pairs_ == 0 or not silent_supported(pid)) then
		return false;
	end

	-- chunked at the recommended ceiling rather than trusting one packet
	-- to hold everything
	local i = 1;
	while (i <= #pairs_) do
		local chunk = {};
		for k = i, math.min(i + MAX_ENTRIES - 1, #pairs_) do
			chunk[#chunk+1] = pairs_[k];
		end
		send_packet(pid, put_entries(chunk));
		i = i + #chunk;
	end

	return true;
end

-- Every flagged id, as one list. This is the catch-up: a client that has
-- just negotiated, or is about to be told who is already here, needs the
-- whole picture rather than the changes it missed.
local function snapshot()
	local out = {};

	for target,mask in pairs(flags) do
		if (mask ~= 0) then
			out[#out+1] = {target, mask};
		end
	end

	return out;
end

--============================ ORDERING ==============================--

-- THE ONE HARD ORDERING RULE IN THE SPEC: the flags of an id must reach
-- the client before the Existing Player packet that introduces it, on
-- the same reliable ordered channel -- one Set Flags ahead of all of
-- them. Miss it and the client meets a silent player as an ordinary one,
-- puts them on the scoreboard, and only takes them off a packet later.
--
-- send_connected_players is that seam exactly: it is the call that
-- sends an Existing Player for everybody already here (funcs_send.c:335,
-- and it is in the callchain via luaawk.h:1214), so going first here is
-- going first on the wire. Both packets are reliable and ordered, so
-- first sent is first seen.
function mod.send_connected_players(pid)
	send_entries(pid, snapshot());
	mod.next.send_connected_players(pid);
end

-- The other order this can arrive in, and the reason the snapshot is
-- sent twice rather than once. Negotiation is a round trip: if the
-- client's ExtensionInfo has not come back by the time it is told who is
-- here, the send above finds silent_supported false and sends nothing,
-- and this is what covers it.
--
-- Sending it in both places costs a duplicate Set Flags in the case
-- where negotiation did finish first. That is a packet of two bytes per
-- flagged id carrying values the client already has, applied on top of
-- themselves -- flags are absolute, not a delta, so a repeat is a no-op.
-- Cheap insurance against the roster flickering on every join.
local function on_ready(pid)
	send_entries(pid, snapshot());
end

--============================== INTAKE ==============================--

-- Server to client, both sub-packets. Anything on 67 from a client is
-- either a confused client or one claiming an authority it has none of
-- -- to hide any player it names from anybody -- and neither is worth
-- reading. Returning 0 drops it the same way lib_ext drops packet 60.
function mod.on_any_packet(pid, data)
	if (string.byte(data, 1) == PKT) then
		return 0;
	end

	return mod.next.on_any_packet(pid, data);
end

--=============================== API ================================--

function silent_supported(pid)
	return ext_supported ~= nil and ext_supported(pid, EXT_ID) ~= nil;
end

function silent_get(target)
	return flags[target] or 0;
end

-- Set the mask for one id and tell everybody who is listening. A mask of
-- 0 presents the player normally and clears whatever they had, which is
-- why it is stored as nil rather than 0: the table is then exactly the
-- set of ids worth mentioning, and the snapshot is a walk of it.
function silent_set(target, mask)
	if (type(target) ~= "number" or target < 0 or target > 255) then
		error("silent_set: target must be a player id", 2);
	end

	mask = bit.band(tonumber(mask) or 0, FLAG_MASK);

	if (silent_get(target) == mask) then
		return; -- already so, and a Set Flags saying nothing is noise
	end

	flags[target] = (mask ~= 0) and mask or nil;

	-- 0 is sent like any other value: it is how a client is told to stop
	-- hiding somebody, so it has to go out even though we no longer hold
	-- a row for them
	for i in each_listener() do
		send_entries(i, {{target, mask}});
	end
end

function silent_clear(target)
	silent_set(target, 0);
end

--=========================== FORGETTING =============================--

-- Ids are recycled, and that is the whole danger in this extension: a
-- mask outliving its owner does not fade, it lands on whoever takes the
-- id next -- and that player is quietly missing from the scoreboard for
-- reasons nobody can see. The spec has both ends forget together.
--
-- The client drops an id's flags when Player Left arrives, so our job is
-- only to stop believing it too. No packet: the client has already done
-- it, and one addressed to an id that just left is at best ignored.
function mod.after.on_disconnect(pid)
	flags[pid] = nil;
end

-- A map change resets every id to 0 on the client. Our record is not
-- wrong, though -- an id that was silent before the rotation is still
-- silent, and still held by the same bot -- so this re-states it rather
-- than forgetting it. The client's reset is the reason to send, not a
-- reason to agree.
--
-- Clearing here instead would be a race nobody could win: whoever
-- re-flags their ids on a new map does it from this same callchain, and
-- whether their hook runs before or after this one is a question of load
-- order. Re-sending has no such ordering to get wrong -- ids that went
-- away were dropped by on_disconnect above, and ids that stayed are
-- exactly the ones that should be sent again.
function mod.after.finish_map_load()
	local snap = snapshot();

	for i in each_listener() do
		send_entries(i, snap);
	end
end

function mod.on_load()
	if (ext_register == nil) then
		error("lib_silent_player needs lib_ext loaded first "
			.."(config.lua loads it, or: lsdctl <instance> load lib_ext "
			.."lib_silent_player)", 0);
	end

	ext_register("lib_silent_player", EXT_ID, EXT_VERSION, on_ready);

	-- Whoever asked for ids to be hidden did so against a copy of this
	-- module that no longer exists, and the table it kept went with it.
	-- Only the asker still knows, so the askers are asked again. lib_bot
	-- is the one that holds bot visibility; anything else that starts
	-- hiding players will want the same call here.
	if (bot_resilence ~= nil) then
		bot_resilence();
	end
end

function mod.on_unload()
	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end

	-- Take the masks back before going away. Nothing else will: this is
	-- the only thing that knows which ids are hidden, and a client left
	-- believing it would go on hiding them for the rest of the map with
	-- no module left to explain why.
	for target in pairs(flags) do
		for i in each_listener() do
			send_entries(i, {{target, 0}});
		end
	end
	flags = {};

	silent_set = nil;
	silent_get = nil;
	silent_clear = nil;
	silent_supported = nil;
	SILENT_HIDE_ROSTER = nil;
	SILENT_HIDE_PRESENCE = nil;
	SILENT_HIDE_KILLFEED = nil;
	SILENT_NO_STATS = nil;
	SILENT_ALL = nil;
end

-- ON SUB-PACKET 0, Create Silent Player, which this module does not send.
--
-- It is Create Player with a flags byte in front, and what it buys is
-- atomicity: the flags land before the client signals the spawn, so an
-- id that is silent from birth is never briefly loud. Sending it would
-- mean intercepting LSd's own spawn emission and rebuilding the packet
-- -- weapon, team, position, CP437 name -- from Lua, and being wrong
-- about any of that breaks spawning rather than degrading it.
--
-- What makes that trade a bad one is that flags outlive spawns. "Plain
-- Create Player packets do not affect existing flags", so an id flagged
-- once stays flagged through every respawn afterwards, and respawns are
-- all the Fall's fallers ever do. The race is only ever on the FIRST
-- Create Player for an id -- four of them, once, at map load -- and it
-- costs a join notice that a flag would have suppressed.
--
-- So the omission is worth one flicker at map start and nothing after.
-- If that flicker ever matters, this is where sub-packet 0 goes, and
-- SUB_CREATE above is here to be used rather than as decoration.
local _ = SUB_CREATE;

return mod;
