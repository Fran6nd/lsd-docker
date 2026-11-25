-- lib_edit_mode.lua -- The Edit Mode protocol extension, server side
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Edit Mode extension (id 0x36, version 1): the
-- server puts a player in edit mode, and from then on accepts building
-- the base game refuses -- no block supply, any reach, blocks in mid-air,
-- z 62, as a spectator -- plus Block Batch, many blocks in one packet.
-- Packet 0x76, two sub-packets:
--
--   0 Edit Mode    S->C    [0x76][0][pid][state]
--   1 Block Batch  C<->S   [0x76][1][pid][action][n * (LE x, y, z)]
--
-- Load lib_ext before this; it owns the negotiation.
--
-- API (globals):
--   edit_mode_set(pid, on)    -> true once it is so. false, "pending"
--        for a client still connecting (it goes on when that client
--        negotiates), false, "unsupported" for one that never will
--   edit_mode_get(pid)        -> is pid in edit mode
--   edit_mode_any()           -> is anybody
--   edit_mode_supported(pid)  -> did pid negotiate ext 0x36
--   edit_mode_listen_batch(name, fn) / edit_mode_unlisten_batch(name)
--        fn(pid, action, pos) for each block of a Block Batch; return
--        false to drop that block. Batches do not pass through
--        on_block_action (see BATCHES), so this is where a protection
--        script says no to them.
-- Command: /editmode [player] [on|off], gated on the "editmode" cap.
--
-- WHAT THE ENGINE REFUSES, AND WHERE. Everything is in LSd's default
-- on_any_packet (funcs_packetrecv.c:356-422): Block Action and Block
-- Line are SCASEALIVE (a spectator's are dropped silently), z must be
-- < 62, a build needs the block tool, a block in hand (blocks > 0) and a
-- neighbour, a line may not be longer than the block count and needs
-- neighbours at both ends, and Set Colour is SCASEALIVE too. There is no
-- reach check and no rate limit anywhere, so "any distance" and "no
-- delay" need nothing. on_sane_packet then dispatches without checking
-- again (funcs_packetrecv.c:584-592), so returning 0 from on_any_packet
-- for an edit-mode player's packet is the whole of the lifting -- what
-- unrestricted_blocks does for a cap, done here for edit mode.
--
-- Kept, because they are memory safety: exact length, the player id is
-- the sender, 0 <= x, y < 512 and 0 <= z <= 62. set_solid indexes the
-- map with no bounds check of its own (main.c:365). z 63 is never
-- written, as the spec says. Also kept, because the spec does not lift
-- them: a build onto a solid block and a destroy of air are refused, as
-- the engine refuses them.
--
-- NOTHING FALLS WHILE ANYBODY IS IN EDIT MODE. The engine drops floating
-- blocks in block_action_cull (main.c:604), which calls libpvx2's
-- map_cull and destroys the voxels there and then. So block_action_cull
-- is replaced while edit_mode_any(): it culls nothing, and only does the
-- other half of its job -- the per-voxel Block Actions send_cull owes
-- clients without QUIRK_OS_BACTION_CULL for a partial spade or grenade
-- destroy (main.c:462-502), whose own type 2/3 block_action_rm withheld
-- from them. Everything that destroys -- block_action, lib_bulk_destroy,
-- grenades -- ends there.
--
-- Z 62. block_action_rm skips z 62 for a spade type 2 (main.c:565-574),
-- but the spec has an edit-mode player's destroy remove "the blocks it
-- covers at z 62 too". So a type 2 by an edit-mode player that covers a
-- solid z 62 is done here instead: each solid block in its column is
-- removed alone, silently, and the Block Action 2 goes to everyone, who
-- apply it the same way.
--
-- CLIENTS THAT DID NOT NEGOTIATE. "While any player is in edit mode,
-- such a client does not play": it would apply a Block Action or Line
-- differently (floating blocks fall for it, z 62 does not change), so it
-- is sent none. Every Block Action and Block Line LSd sends goes out
-- through send_packet (funcs_send.c:450-470 SENDs through
-- st->f.send_packet, which lua.c:503 bridges to the Lua global), so one
-- hook in mod.late -- after every other script's -- sees all of them,
-- splits a broadcast into its recipients and decides per client:
--
--   negotiated              sent, as ever
--   still connecting        held in a queue, in order, with the Set
--                           Colours and Edit Modes around them; sent
--                           when it negotiates, dropped (and it has
--                           missed them) when it turns out not to
--   did not negotiate       not sent, and it has MISSED one
--   a bot (no person)       sent, as ever; there is nobody to bench
--
-- A client that has missed one stays out until it reconnects or the
-- next Map Start reaches it, "even if edit mode ends first", because its
-- map no longer matches. A client that did not negotiate but has missed
-- nothing plays again as soon as edit mode ends.
--
-- Out means edit_mode_legacy: "spectator" (default) holds it in
-- spectator with a chat line saying why, and puts it back on its team
-- when it may play again; "disconnect" kicks it with the same line.
-- A client still connecting is never kicked for being slow -- only held.
--
-- SPECTATORS' COLOUR. The spec has a spectator's blocks take their
-- colour from the Existing Player it sent, then from each Set Colour,
-- relayed. LSd ignores the colour in a client's Existing Player
-- (funcs_event.c:83-91) and spawn_player resets it to grey (main.c:969),
-- and Set Colour from a spectator is SCASEALIVE. So the colour is read
-- off the client's Existing Player here and applied through on_color_
-- change -- the same path, and the same relay, as a Set Colour -- after
-- it spawns as a spectator; a spectator in edit mode's own Set Colour is
-- let through.
--
-- BATCHES are applied with block_action, one block at a time, with that
-- block's own Block Action muted on the way out: the engine sends one
-- per block (main.c:660-673) and the whole point of a batch is that it
-- does not. Only blocks the map actually took -- solid after a build,
-- air after a destroy -- go into the batch that is sent, so a script
-- vetoing block_action (map_layout guards components that way) drops
-- the block instead of desyncing it. on_block_action is not called: it
-- is the per-packet event, and its listeners answer per block with
-- network traffic of their own (infinite_blocks restocks, map_layout
-- reverts). Protection for batches goes through edit_mode_listen_batch.
local mod = init_mod();
local bit = require("bit");

local EXT_ID = 0x36;
local EXT_VERSION = 1;
-- 64 + the extension id
local PKT = 64 + EXT_ID;
local SUB_MODE = 0;   -- S->C   [PKT][0][pid][state]
local SUB_BATCH = 1;  -- C<->S  [PKT][1][pid][action][blocks...]

local BATCH_BUILD, BATCH_DESTROY = 0, 1;
local BATCH_HEADER, BLOCK_SIZE = 4, 12;

-- protocol.h: PacketTypeSetColor = 8, ExistingPlayer = 9,
-- BlockAction = 13, BlockLine = 14
local PKT_SET_COLOR = 8;
local PKT_EXISTING_PLAYER = 9;
local PKT_BLOCK_ACTION, ACTION_LEN = 13, 15;
local PKT_BLOCK_LINE, LINE_LEN = 14, 26;
local SET_COLOR_LEN = 5;

-- The highest z an edit-mode player may change. 63 is the water and is
-- never touched by anybody.
local EDIT_TOP_Z = 62;

-- block_action_rm's mask: type in bits 30-31, "full" in bit 29
-- (main.c:600-601)
local MASK_FULL = 0x20000000;

getcfg("edit_mode_batch_max", 8192,
	"Most blocks one Block Batch may carry; a bigger batch is dropped "
		.."whole, as the spec says.");
getcfg("edit_mode_legacy", "spectator",
	"What happens to a client without Edit Mode while somebody is in "
		.."edit mode: 'spectator' or 'disconnect'.");
getcfg("edit_mode_legacy_message",
	"Edit mode is on and your client does not support it: you are a "
		.."spectator until it ends. Update your client to take part.",
	"Told to a client without Edit Mode when it is benched.");
getcfg("edit_mode_stale_message",
	"Your map missed changes made in edit mode. Reconnect to play again.",
	"Told to a client whose map no longer matches the server's.");
getcfg("edit_mode_release_message",
	"Edit mode is over; you can play again.",
	"Told to a benched client when it may play again.");
-- How long a connecting client's silence is not yet an answer: until it
-- replies to the extension announcement, or runs out of these, it is
-- "still connecting" and its block packets are queued, not dropped. The
-- same two clocks, and for the same reasons, as lib_ext_policy's.
getcfg("edit_mode_grace", 30,
	"Seconds a client still in limbo gets to negotiate.");
getcfg("edit_mode_grace_joined", 3,
	"Seconds of silence that count as an answer once a client has "
		.."picked a team.");
-- Packets held for one connecting client. A client that would need more
-- than this has missed its edits rather than been told them late.
getcfg("edit_mode_queue_max", 20000,
	"Most packets held for one client still negotiating.");
getcfg("edit_mode_cap", "editmode",
	"Cap that /editmode needs.");
getcfg("edit_mode_debug", false,
	"Log every edit mode change, batch and benching.");

--============================== BYTES ===============================--
-- Pure: nothing below reads the server, so tests load it as it is.

-- one little-endian int32 at `off` (1-based). bit.bor is signed in
-- LuaJIT, which is what we want: a negative coordinate fails the range
-- test instead of wrapping into it.
local function i32(data, off)
	local a, b, c, d = string.byte(data, off, off + 3);
	return bit.bor(a, bit.lshift(b, 8), bit.lshift(c, 16), bit.lshift(d, 24));
end

local function le32(v)
	return string.char(bit.band(v, 255), bit.band(bit.rshift(v, 8), 255),
		bit.band(bit.rshift(v, 16), 255), bit.band(bit.rshift(v, 24), 255));
end

-- Where a block may be at all: z 62 only in edit mode, z 63 never.
local function in_map(x, y, z, edit)
	return x >= 0 and x < 512 and y >= 0 and y < 512
	   and z >= 0 and z <= (edit and EDIT_TOP_Z or EDIT_TOP_Z - 1);
end

-- A Block Batch, read. Returns {pid=, action=, blocks={{x,y,z}...}}
-- with only the in-map blocks kept, or nil and why the whole batch is
-- dropped: the spec drops a reserved action, an empty batch and one
-- bigger than the server accepts. A length that is not a whole number of
-- blocks is not a batch at all.
local function parse_batch(data, max)
	if (#data < BATCH_HEADER or string.byte(data, 1) ~= PKT
	    or string.byte(data, 2) ~= SUB_BATCH) then
		return nil, "not a batch";
	end

	local action = string.byte(data, 4);
	if (action ~= BATCH_BUILD and action ~= BATCH_DESTROY) then
		return nil, "reserved action";
	end

	local body = #data - BATCH_HEADER;
	if (body % BLOCK_SIZE ~= 0) then
		return nil, "malformed";
	end

	local n = body / BLOCK_SIZE;
	if (n == 0) then
		return nil, "empty";
	end
	if (n > max) then
		return nil, "too big";
	end

	local blocks = {};
	for i = 0, n - 1 do
		local off = BATCH_HEADER + 1 + i * BLOCK_SIZE;
		local x, y, z = i32(data, off), i32(data, off + 4), i32(data, off + 8);

		if (in_map(x, y, z, true)) then
			blocks[#blocks+1] = {x = x, y = y, z = z};
		end
	end

	return {pid = string.byte(data, 3), action = action, blocks = blocks};
end

local function encode_batch(pid, action, blocks)
	local out = {string.char(PKT, SUB_BATCH, pid, action)};
	for _, b in ipairs(blocks) do
		out[#out+1] = le32(b.x) .. le32(b.y) .. le32(b.z);
	end
	return table.concat(out);
end

-- The blocks of a batch the map takes, in order. Judged one at a time
-- against the map as it stands, so a block named twice is built once:
-- a build onto a solid block and a destroy of air are dropped, as the
-- engine drops them; allow(b) may veto; apply(b) does it and says
-- whether the map took it.
local function filter_batch(action, blocks, solid, allow, apply)
	local kept = {};

	for _, b in ipairs(blocks) do
		if (solid(b) == (action == BATCH_DESTROY) and allow(b) and apply(b)) then
			kept[#kept+1] = b;
		end
	end

	return kept;
end

local function block_action_bytes(pid, type, pos)
	return string.char(PKT_BLOCK_ACTION, pid, type)
		.. le32(pos.x) .. le32(pos.y) .. le32(pos.z);
end

-- An edit-mode player's Block Action, Block Line or Set Colour that the
-- engine's checks may be waived for: everything that is memory safety
-- or that the spec keeps, nothing that is policy. solid(pos) is the map.
local function edit_packet_ok(pid, data, solid)
	local id = string.byte(data, 1);

	if (string.byte(data, 2) ~= pid) then
		return false;
	end

	if (id == PKT_BLOCK_ACTION) then
		if (#data ~= ACTION_LEN) then return false; end

		-- 3 is the grenade's, never a client's
		local t = string.byte(data, 3);
		if (t ~= 0 and t ~= 1 and t ~= 2) then return false; end

		local p = {x = i32(data, 4), y = i32(data, 8), z = i32(data, 12)};
		if (not in_map(p.x, p.y, p.z, true)) then return false; end

		-- building is onto air, destroying is of a block
		return solid(p) == (t ~= 0);
	end

	if (id == PKT_BLOCK_LINE) then
		if (#data ~= LINE_LEN) then return false; end

		local s = {x = i32(data, 3), y = i32(data, 7), z = i32(data, 11)};
		local e = {x = i32(data, 15), y = i32(data, 19), z = i32(data, 23)};
		if (not in_map(s.x, s.y, s.z, true) or not in_map(e.x, e.y, e.z, true)) then
			return false;
		end

		-- the engine's one occupancy rule for a line; the neighbours and
		-- the length are what edit mode lifts
		return not solid(e);
	end

	if (id == PKT_SET_COLOR) then
		return #data == SET_COLOR_LEN;
	end

	return false;
end

mod.pure = {
	i32 = i32, le32 = le32, in_map = in_map,
	parse_batch = parse_batch, encode_batch = encode_batch,
	filter_batch = filter_batch, edit_packet_ok = edit_packet_ok,
	block_action_bytes = block_action_bytes,
};

--============================== STATE ===============================--

-- All pid_connected_tables: a reconnect is a new client, in edit mode
-- or not, stale or not, from scratch -- "a player's edit mode is off
-- when they join", and "it stays out until it joins again".
local editing = pid_connected_table(false);
-- edit_mode_set asked for a client still negotiating
local wanted = pid_connected_table(false);
-- has missed a Block Action, Line or Batch: its map is not the server's
local missed = pid_connected_table(false);
-- packets held for a client still negotiating, in order; nil when none
local queue = pid_connected_table();
-- the team and gun a benched player is owed back; nil when none
local held = pid_connected_table();
-- told why it is out, this time round
local told = pid_connected_table(false);
-- when it connected, and when it first picked a team: the two clocks
local since = pid_connected_table();
local caught_up = pid_connected_table();
-- the colour from the client's own last Existing Player
local ep_color = pid_connected_table();

local listeners = {};

-- Block Actions to swallow on the way out: our own per-block sends while
-- a batch (or a z 62 spade) is applied. Keyed by the exact 15 bytes, so
-- nothing else is ever muted by accident.
local mute = {};

local function dbg(fmt, ...)
	if (edit_mode_debug) then
		log("lib_edit_mode: " .. fmt, ...);
	end
end

--=============================== WHO ================================--

local function negotiated(pid)
	return ext_supported ~= nil and ext_supported(pid, EXT_ID) ~= nil;
end

-- Nobody behind it: lib_bot's bots, a headless fleet, anything without
-- a peer. Same three tests, and the same reasons, as lib_ext_policy's
-- is_not_a_person. There is nobody to bench, and a bot's map is not
-- drawn for anybody.
local function person(pid)
	if (bot_is_nonhuman ~= nil and bot_is_nonhuman(pid)) then
		return false;
	end
	if (bot_is_bot ~= nil and bot_is_bot(pid)) then
		return false;
	end
	local ok, addr = pcall(get_ipaddr, pid);
	return not (ok and addr == 0);
end

-- Has this client answered, or run out of time to? Until then its
-- silence is not yet a no.
local function decided(pid)
	if (ext_replied ~= nil and ext_replied(pid)) then
		return true;
	end

	local now = get_time();
	local up = caught_up[pid];
	if (up ~= nil and now - up >= edit_mode_grace_joined) then
		return true;
	end

	local t = since[pid];
	return t ~= nil and now - t >= edit_mode_grace;
end

local function sane_pid(pid)
	pid = tonumber(pid);
	return pid ~= nil and pid >= 0 and pid < MAX_PLAYERS and pid % 1 == 0;
end

-- Is nobody editing, and nobody owed or missing a block packet? Asked
-- for every block packet there is, so it is worked out once and kept
-- until something that could change it happens (unknown()) or the tick
-- ends -- on a server full of bots that dig and build, walking every
-- player for every block was most of what the server did.
local idle = nil;
local function unknown()
	idle = nil;
end
local function nobody_busy()
	if (idle == nil) then
		idle = true;
		for i in piditer(PID_BROADCAST) do
			if (editing[i] or missed[i] or queue[i] ~= nil) then
				idle = false;
				break;
			end
		end
	end
	return idle;
end

local function edit_any()
	for i in piditer(PID_BROADCAST) do
		if (editing[i]) then
			return true;
		end
	end
	return false;
end

-- Must this client sit out? "missed" until it reconnects or a Map
-- Start; "legacy" or "undecided" while anybody is in edit mode.
local function sit_reason(pid)
	if (not person(pid)) then
		return nil;
	end
	if (missed[pid]) then
		return "missed";
	end
	if (negotiated(pid) or not edit_any()) then
		return nil;
	end
	return decided(pid) and "legacy" or "undecided";
end

--=============================== WIRE ===============================--

-- Straight past our own filter, for a queue that has already been
-- through it. mod.late.next is the chain below us, which ends in C.
local function raw_send(pid, data)
	return mod.late.next.send_packet(pid, data);
end

local function mode_packet(target, on)
	return string.char(PKT, SUB_MODE, target, on and 1 or 0);
end

-- The Edit Modes a client must be told before anything held for it: the
-- state of the moment the queue started. Every later change is queued
-- behind it, so the client ends up where everybody else is.
local function start_queue(pid)
	local q = {n_blocks = 0};
	for i in piditer(PID_BROADCAST) do
		if (editing[i]) then
			q[#q+1] = mode_packet(i, true);
		end
	end
	queue[pid] = q;
	unknown();
	return q;
end

local bench, miss;

local function enqueue(pid, data, is_block)
	local q = queue[pid] or start_queue(pid);

	if (#q >= edit_mode_queue_max) then
		dbg("#%d's queue is full; it has missed edits", pid);
		miss(pid);
		return;
	end

	q[#q+1] = data;
	if (is_block) then
		q.n_blocks = q.n_blocks + 1;
	end
end

-- One recipient of a Block Action, Block Line or Set Colour.
local function deliver(pid, data, id, any)
	if (not person(pid)) then
		return raw_send(pid, data);
	end

	if (id == PKT_SET_COLOR) then
		-- held behind the blocks it colours, when anything is held
		if (queue[pid] ~= nil) then
			enqueue(pid, data, false);
			return 0;
		end
		return raw_send(pid, data);
	end

	if (missed[pid]) then
		return 0;
	end
	if (queue[pid] ~= nil) then
		enqueue(pid, data, true);
		return 0;
	end
	if (negotiated(pid) or not any) then
		return raw_send(pid, data);
	end
	if (not decided(pid)) then
		enqueue(pid, data, true);
		return 0;
	end

	miss(pid);
	return 0;
end

-- An extension packet that changes the map (a batch) or what the map
-- will do (an Edit Mode): to every negotiated client, into the queue of
-- every client still negotiating, and to nobody else -- a client that
-- did not negotiate never gets packet 0x76. One that misses a batch has
-- missed an edit.
local function deliver_ext(data, changes_map)
	for i in piditer(PID_BROADCAST) do
		if (negotiated(i)) then
			raw_send(i, data);
		elseif (person(i) and not missed[i]) then
			if (queue[i] ~= nil or (changes_map and not decided(i))) then
				enqueue(i, data, changes_map);
			elseif (changes_map) then
				miss(i);
			end
		end
	end
end

-- Every Block Action and Block Line LSd sends passes here; see the top
-- of the file. Only those, and Set Colour, are looked at at all: the
-- first byte is the whole cost for everything else.
function mod.late.send_packet(pid, data)
	local id = string.byte(data, 1);

	if (id ~= PKT_BLOCK_ACTION and id ~= PKT_BLOCK_LINE and id ~= PKT_SET_COLOR) then
		return mod.late.next.send_packet(pid, data);
	end

	if (id == PKT_BLOCK_ACTION and mute[data]) then
		return 0;
	end

	-- the common case, with nobody editing and nobody out: untouched,
	-- broadcast and all
	if (nobody_busy()) then
		return mod.late.next.send_packet(pid, data);
	end
	local any = edit_any();

	if (sane_pid(pid)) then
		return deliver(pid, data, id, any);
	end

	for i in piditer(pid) do
		deliver(i, data, id, any);
	end
	return 0;
end

-- Run fn with the Block Actions named muted. Restored however fn ends,
-- so an error in some other script's hook cannot leave a block silenced
-- for good.
local function muted(keys, fn, ...)
	for _, k in ipairs(keys) do mute[k] = true; end
	local ok, err = pcall(fn, ...);
	for _, k in ipairs(keys) do mute[k] = nil; end
	if (not ok) then
		error(err, 0);
	end
end

--============================= BENCHING =============================--

local function tell(pid, text)
	if (text ~= nil and text ~= "") then
		server_msg(pid, text);
	end
end

-- Out of play: told why once, and taken off its team. on_switch to the
-- spectator team is how lib_ext_policy and team_balance do it, and kills
-- the player for a team change on the way.
--
-- "undecided" is never told and never kicked: a client still loading
-- the map is held, not thrown out for being slow, and there is nothing
-- to tell it until it has answered.
function bench(pid, why)
	if (not person(pid)) then
		return;
	end

	if (why ~= "undecided") then
		if (not told[pid]) then
			told[pid] = true;
			tell(pid, why == "missed" and edit_mode_stale_message
				or edit_mode_legacy_message);

			if (edit_mode_legacy == "disconnect") then
				dbg("#%d disconnected (%s)", pid, why);
				disconnect(pid, 2);
				return;
			end
		elseif (edit_mode_legacy == "disconnect") then
			return;   -- already on its way out
		end
	end

	if (held[pid] == nil and is_joined(pid) and get_team(pid) ~= SPECTATOR) then
		held[pid] = {team = get_team(pid), gun = get_gun(pid)};
		dbg("#%d benched (%s)", pid, why);
		on_switch(pid, SPECTATOR, get_gun(pid));
	end
end

-- It has missed an edit: nothing it holds is worth sending any more, and
-- it is out until it reconnects or a Map Start reaches it.
--
-- Only marked here. This runs inside a send, deep in somebody's
-- block_action, which is no place to kill a player; the tick benches it
-- a moment later, and it is sent no block packet in between anyway.
function miss(pid)
	local q = queue[pid];
	queue[pid] = nil;
	missed[pid] = true;
	unknown();

	-- what was held that is not an edit still goes, in order
	if (q ~= nil) then
		for _, data in ipairs(q) do
			if (string.byte(data, 1) == PKT_SET_COLOR) then
				raw_send(pid, data);
			end
		end
	end

	-- a stale map is news, even to a client already sitting out
	told[pid] = false;
	dbg("#%d has missed an edit", pid);
end

-- Back in play, and back on the team it was taken off.
local function release(pid)
	local was_told = told[pid];
	told[pid] = false;

	local h = held[pid];
	held[pid] = nil;

	if (was_told) then
		tell(pid, edit_mode_release_message);
	end
	if (h ~= nil and is_joined(pid) and get_team(pid) == SPECTATOR) then
		on_switch(pid, h.team, h.gun);
	end
	dbg("#%d may play again", pid);
end

-- The team a client asks for, honoured or held. Held first, so bench
-- has nothing to switch: this is already inside the switch.
local function gate(pid, team, gun)
	if (team == SPECTATOR) then
		return team;
	end

	local why = sit_reason(pid);
	if (why == nil) then
		return team;
	end

	held[pid] = {team = team, gun = gun};
	bench(pid, why);
	return SPECTATOR;
end

-- Not mod.after.on_join: core.lua's process_before_after would let one
-- replace the other (see lib_ext_policy's on_join).
function mod.on_join(pid, team, gun, name)
	if (caught_up[pid] == nil) then
		caught_up[pid] = get_time();
	end

	return mod.next.on_join(pid, gate(pid, team, gun), gun, name);
end

function mod.on_switch(pid, team, gun)
	local use = gate(pid, team, gun);

	-- a spectator asking to stay one would be respawned by on_switch's
	-- team == 255 branch (funcs_event.c:100-106): decline outright
	if (use ~= team and get_team(pid) == SPECTATOR) then
		return;
	end

	return mod.next.on_switch(pid, use, gun);
end

function mod.after.on_successful_connect(pid)
	since[pid] = get_time();
end

-- Map Start, to one client or all: a fresh map, so nothing it missed
-- matters any more, and nothing held for the old one may be sent.
function mod.after.send_map_start(pid, size)
	for i in piditer(pid) do
		missed[i] = false;
		queue[i] = nil;
	end
end

--============================== BLOCKS ==============================--

local function solid(p)
	return is_solid(p);
end

-- Spectators' colour: from the client's own Existing Player. The 'x'
-- form is OpenSpades' version block, not a player (funcs_packetrecv.c:
-- 521-547).
local function note_color(pid, data)
	local x, zero, n = string.byte(data, 2, 4);
	if (x == string.byte("x") and zero == 0 and n ~= nil and n >= 3) then
		return;   -- the engine's own test for the version block
	end

	if (#data >= 12) then
		local b, g, r = string.byte(data, 10, 12);
		ep_color[pid] = {b = b, g = g, r = r};
	end
end

-- Through on_color_change, the event a Set Colour raises, so the colour
-- is set and relayed exactly as one would be -- and so a script that
-- polices colours (team_block_colors) polices this one too. pcall'd
-- because such a script is entitled to assume a team colour exists.
function mod.after.spawn_player(pid)
	local c = ep_color[pid];
	if (c ~= nil and get_team(pid) == SPECTATOR) then
		local ok, err = pcall(on_color_change, pid, c);
		if (not ok) then
			dbg("#%d's colour not applied: %s", pid, tostring(err));
		end
	end
end

-- Nothing falls; see the top of the file. Without edit mode, untouched.
local function notify_unquirked(x, y, z)
	-- send_cull's own bounds (main.c:466)
	if (x < 0 or x >= 512 or y < 0 or y >= 512 or z < 0 or z >= 62) then
		return;
	end
	if (QUIRK_OS_BACTION_CULL == nil) then
		return;
	end

	local pos = {x = x, y = y, z = z};
	for i in piditer(PID_BROADCAST) do
		if (not has_quirk(i, QUIRK_OS_BACTION_CULL)) then
			send_block_action(i, pos, 1, get_anon_pid());
		end
	end
end

function mod.block_action_cull(pos, mask)
	if (not edit_any()) then
		return mod.next.block_action_cull(pos, mask);
	end

	if (bit.band(mask, MASK_FULL) ~= 0) then
		return;   -- the whole shape went to everybody already
	end

	local kind = math.floor(mask / 2^30) % 4;

	if (kind == 2) then
		-- main.c:619-643: below, above, centre
		if (bit.band(mask, 4) ~= 0) then notify_unquirked(pos.x, pos.y, pos.z - 1); end
		if (bit.band(mask, 2) ~= 0) then notify_unquirked(pos.x, pos.y, pos.z + 1); end
		if (bit.band(mask, 1) ~= 0) then notify_unquirked(pos.x, pos.y, pos.z); end
	elseif (kind == 3) then
		-- main.c:504-520: x fastest, one bit per cell
		local ctr = 1;
		for dz = -1, 1 do
			for dy = -1, 1 do
				for dx = -1, 1 do
					if (bit.band(mask, ctr) ~= 0) then
						notify_unquirked(pos.x + dx, pos.y + dy, pos.z + dz);
					end
					ctr = ctr * 2;
				end
			end
		end
	end
end

-- A spade by an edit-mode player that covers a solid z 62. The column is
-- removed a block at a time, each removal's Block Action muted, and the
-- one Block Action 2 goes to everybody, who remove the same blocks.
local function spade_with_62(pos, from)
	local removed = {};

	for dz = -1, 1 do
		local p = {x = pos.x, y = pos.y, z = pos.z + dz};

		if (p.z >= 0 and p.z <= EDIT_TOP_Z and is_solid(p)) then
			muted({block_action_bytes(from, 1, p)}, function()
				removed[#removed+1] = {p = p, mask = block_action_rm(p, 1, from)};
			end);
		end
	end

	for _, r in ipairs(removed) do
		block_action_cull(r.p, r.mask);
	end
	finish_cull();

	if (#removed > 0) then
		send_block_action(PID_BROADCAST, pos, 2, from);
	end
end

function mod.block_action(pos, type, from)
	if (type == 2 and pos.z >= EDIT_TOP_Z - 1 and sane_pid(from)
	    and editing[from] and is_solid({x = pos.x, y = pos.y, z = EDIT_TOP_Z})) then
		return spade_with_62(pos, from);
	end

	return mod.next.block_action(pos, type, from);
end

--============================= BATCHES ==============================--

local function batch_allows(pid, action, b)
	for name, fn in pairs(listeners) do
		local ok, allow = pcall(fn, pid, action, b);

		-- a veto that cannot answer is a no, and loses its hook
		if (not ok) then
			listeners[name] = nil;
			log("lib_edit_mode: batch listener %s crashed, dropped: %s",
				name, tostring(allow));
			return false;
		end
		if (allow == false) then
			return false;
		end
	end
	return true;
end

local function on_batch(pid, data)
	if (not negotiated(pid) or not editing[pid] or not is_joined(pid)) then
		dbg("batch from #%d dropped: not in edit mode", pid);
		return;
	end

	local batch, why = parse_batch(data, edit_mode_batch_max);
	if (batch == nil) then
		dbg("batch from #%d dropped: %s", pid, why);
		return;
	end

	local action = batch.action;
	local type = action == BATCH_BUILD and 0 or 1;

	local kept = filter_batch(action, batch.blocks, solid,
		function(b) return batch_allows(pid, action, b); end,
		function(b)
			muted({block_action_bytes(pid, type, b)}, block_action, b, type, pid);
			return is_solid(b) == (action == BATCH_BUILD);
		end);

	dbg("batch from #%d: %s %d of %d blocks", pid,
		action == BATCH_BUILD and "built" or "destroyed",
		#kept, #batch.blocks);

	if (#kept > 0) then
		deliver_ext(encode_batch(pid, action, kept), true);
	end
end

--============================== INTAKE ==============================--

function mod.on_any_packet(pid, data)
	local id = string.byte(data, 1);

	-- Packet 0x76 is unknown to the core. Returning 0 hands it to
	-- on_sane_packet, whose switch ignores it, having dealt with it here.
	if (id == PKT) then
		if (string.byte(data, 2) == SUB_BATCH) then
			on_batch(pid, data);
		end
		return 0;
	end

	if (id == PKT_EXISTING_PLAYER) then
		note_color(pid, data);
	elseif (editing[pid] and is_joined(pid) and edit_packet_ok(pid, data, solid)) then
		return 0;   -- sane: on_sane_packet dispatches it unexamined
	end

	return mod.next.on_any_packet(pid, data);
end

--=============================== API ================================--

local function changed(pid, on)
	deliver_ext(mode_packet(pid, on), false);
	dbg("#%d edit mode %s", pid, on and "on" or "off");

	-- out of play at once, before a single edit can reach them
	if (on) then
		for i in piditer(PID_BROADCAST) do
			local why = sit_reason(i);
			if (why ~= nil) then
				bench(i, why);
			end
		end
	end
end

function edit_mode_set(pid, on)
	if (not sane_pid(pid) or not is_connected(pid)) then
		return false, "no such player";
	end

	on = on and true or false;

	if (on and not negotiated(pid)) then
		if (not decided(pid)) then
			wanted[pid] = true;
			return false, "pending";
		end
		return false, "unsupported";
	end

	wanted[pid] = false;

	if (editing[pid] == on) then
		return true;
	end

	editing[pid] = on;
	unknown();
	changed(pid, on);
	return true;
end

function edit_mode_get(pid)
	return sane_pid(pid) and editing[pid] == true;
end

function edit_mode_any()
	return edit_any();
end

function edit_mode_supported(pid)
	return negotiated(pid);
end

function edit_mode_listen_batch(name, fn)
	if (type(name) ~= "string" or type(fn) ~= "function") then
		error("edit_mode_listen_batch: name and fn required", 2);
	end
	listeners[name] = fn;
end

function edit_mode_unlisten_batch(name)
	listeners[name] = nil;
end

--=========================== NEGOTIATION ============================--

-- A client that has just negotiated: what it held, in order, or else
-- the Edit Mode of everybody in edit mode -- "sends a joining one an
-- Edit Mode for each player in edit mode".
local function on_ready(pid)
	local q = queue[pid];
	queue[pid] = nil;

	if (q ~= nil) then
		for _, data in ipairs(q) do
			raw_send(pid, data);
		end
		dbg("#%d negotiated, sent the %d packets held for it", pid, #q);
	else
		for i in piditer(PID_BROADCAST) do
			if (editing[i]) then
				raw_send(pid, mode_packet(i, true));
			end
		end
	end

	if (wanted[pid]) then
		edit_mode_set(pid, true);
	end
end

--=============================== TICK ===============================--

local last_sweep = 0;

function mod.after.tick()
	unknown();
	local now = get_time();
	if (now - last_sweep < 0.25) then
		return;
	end
	last_sweep = now;

	for i in piditer(PID_BROADCAST) do
		-- answered, and not with us: what it was held has been missed
		if (queue[i] ~= nil and decided(i) and not negotiated(i)) then
			miss(i);
		end

		if (wanted[i] and decided(i) and not negotiated(i)) then
			wanted[i] = false;
		end

		local why = sit_reason(i);
		if (why ~= nil) then
			if (why ~= "undecided" or held[i] ~= nil) then
				bench(i, why);
			end
		elseif (told[i] or held[i] ~= nil) then
			release(i);
		end
	end
end

--============================== COMMAND =============================--

local function onoff(s)
	s = string.lower(s or "");
	if (s == "on" or s == "1" or s == "true") then return true; end
	if (s == "off" or s == "0" or s == "false") then return false; end
	return nil;
end

if (register_command ~= nil) then
	local cmd = {name = "editmode", caps = edit_mode_cap, fakepid = true,
		usage = "[player] [on|off]",
		desc = "Switch a player's Edit Mode: no block limits, Block Batch."};

	function cmd.func(pid, argv)
		cmd_assert(pid, cmd, #argv <= 2);

		local who, want = pid, nil;
		if (#argv == 2) then
			who = get_arg_pid("player", pid, cmd, argv[1]);
			want = onoff(argv[2]);
			cmd_assert(pid, cmd, want ~= nil);
		elseif (#argv == 1) then
			want = onoff(argv[1]);
			if (want == nil) then
				who = get_arg_pid("player", pid, cmd, argv[1]);
			end
		end

		-- the console is not a player and has to name one
		cmd_assert(pid, cmd, sane_pid(who));

		if (want == nil) then
			want = not editing[who];
		end

		local ok, why = edit_mode_set(who, want);
		local name = get_name(who);

		if (ok) then
			l10n_send_chat(pid, want and {en = "Edit mode on for %(name)."}
				or {en = "Edit mode off for %(name)."}, {name = name});
			if (who ~= pid) then
				l10n_send_chat(who, want and {en = "Edit mode on."}
					or {en = "Edit mode off."});
			end
		elseif (why == "pending") then
			l10n_send_chat(pid, {en = "%(name) is still connecting; edit mode "
				.. "goes on once their client has negotiated."}, {name = name});
		elseif (why == "unsupported") then
			l10n_send_chat(pid, {en = "%(name)'s client does not support the "
				.. "Edit Mode extension."}, {name = name});
		else
			l10n_send_chat(pid, {en = "Edit mode: %(why)."}, {why = tostring(why)});
		end
	end

	register_command(cmd, mod);
end

--============================= LIFECYCLE ============================--

function mod.on_load()
	if (ext_register == nil) then
		error("lib_edit_mode needs lib_ext loaded first "
			.. "(installing the edit_mode script pulls it in)", 0);
	end

	-- anybody already here started their clocks before we did
	local now = get_time();
	for i in piditer(PID_BROADCAST) do
		since[i] = since[i] or now;
		if (caught_up[i] == nil and is_joined(i)) then
			caught_up[i] = now;
		end
	end

	ext_register("lib_edit_mode", EXT_ID, EXT_VERSION, on_ready, "Edit Mode");
end

local EXPORTS = {
	"edit_mode_set", "edit_mode_get", "edit_mode_any", "edit_mode_supported",
	"edit_mode_listen_batch", "edit_mode_unlisten_batch",
};

-- Everybody out of edit mode on the way down, while something can still
-- say so, and everybody benched for it back in play -- except those
-- whose map is stale, which unloading does not fix.
function mod.on_unload()
	for i in piditer(PID_BROADCAST) do
		if (editing[i]) then
			edit_mode_set(i, false);
		end
	end
	-- Nothing will filter after this, so what is held goes now, as it
	-- would have without us -- all but packet 0x76, which only a client
	-- that negotiated may be sent.
	for i in piditer(PID_BROADCAST) do
		if (not missed[i] and (told[i] or held[i] ~= nil)) then
			release(i);
		end

		local q = queue[i];
		queue[i] = nil;
		for _, data in ipairs(q or {}) do
			if (string.byte(data, 1) ~= PKT) then
				raw_send(i, data);
			end
		end
	end

	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end

	listeners = {};

	for _, name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
