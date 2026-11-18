-- lib_player_limit.lua -- The Player Limit protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Player Limit extension (id 192, version 1):
-- "tells client server supports up to 255 players. Player ID 255 is
-- reserved for the server and is never given to a player."
--
-- PACKETLESS, which is the whole of the protocol work. There is no
-- packet id, no sub-packet and nothing to parse: the extension is the
-- announcement, and lib_ext makes it along with every other one. So
-- this module is two things -- the registration, and the one knob that
-- makes the claim true.
--
-- WHY LSd CAN MAKE THE CLAIM AT ALL, and why it is 255 rather than the
-- 256 the spec used to say. protocol.h:20-21 is the answer to both:
--
--   #define MAX_PLAYERS 255
--   #define DEFAULT_MAX_PLAYERS 32
--
-- with the comment above it reading "MAX_PLAYERS used for absolute max,
-- 1 less than 256 so get_anon_pid() still functions". So a player id
-- here runs 0 to 254 and 255 is never a player: it is the first handle
-- new_fakepid hands out (commands.lua:116-120) and what get_anon_pid
-- settles on. The reservation the spec asks for is one LSd already
-- keeps, for its own reasons, and the two agree exactly.
--
-- That reservation is also what the Flashlight extension spends: a
-- Light Config addressed to 255 is the beam of every player who has
-- none of their own. Same id, same reason -- it is the one number that
-- cannot be mistaken for somebody.
--
-- THE LIMIT ITSELF is player_limit_max, and it defaults to 32, which is
-- DEFAULT_MAX_PLAYERS and the number every client copes with; announcing
-- an extension does not change it. get_effective_max_players is what
-- assign_new_pid counts up to (main.c:187-191) and what the masterlist
-- advertises as capacity (masterlist.lua:25-38, and lib_bot's
-- bot-hiding version of the same sum), so it is the one place the
-- number lives. This module hooks it, so a server that raises
-- player_limit_max gets the new count everywhere at once.
--
-- A WORD BEFORE RAISING IT. A pid is assigned when a client connects,
-- by assign_new_pid out of on_any_connect, and the extension handshake
-- happens later -- a version request, a response, an ExtensionInfo each
-- way. So at the moment the server has to choose an id it does not yet
-- know whether that client can handle a big one, and the extension has
-- no mechanism for it; the ordering is the protocol's, not LSd's.
--
-- What a client that does NOT speak extension 192 (an "old client") does
-- with a player id of 32 or more is its own business: it holds 32 slots,
-- and it usually drops the player, sometimes worse. So while
-- player_limit_max is above 32 this module makes the claim true from
-- the other side, by never letting such a client SEE one. Another
-- module (lib_ext_policy, policy "required") keeps an old client out of
-- play, in spectator; this one filters what is sent to it. Every packet
-- LSd sends goes through send_packet or send_packet_unreliable, so one
-- hook in each, in mod.late after every other script's, sees them all
-- and splits a broadcast into its recipients, as lib_edit_mode does.
-- Per recipient there are four classes:
--
--   all     a bot, or a client that speaks 192: sent as ever
--   wait    has not answered yet: a packet that names no player goes
--           at once (the handshake, map chunks, fog), one that names a
--           player is held in order and an unreliable one (World
--           Update) is dropped; when the client has answered, or the
--           grace (player_limit_grace) runs out, the queue is sent
--           unchanged to a client that speaks 192 and through the
--           filter below to one that does not
--   low     an old client whose own id is below 32: any packet that
--           names a player of 32 or more is dropped (255 is the
--           server, not a player, and passes) and a World Update is
--           cut to its first 32 players
--   alias   an old client whose own id is 32 or more. It cannot be
--           told that id, so it is told it is player ALIAS (1) and
--           nothing about anybody else: no World Update, no packet
--           naming another player. Its own id is rewritten to ALIAS in
--           whatever it is sent. A system chat line passes, since the
--           server speaks as player 0.
--
-- Below or at 32 seats none of this runs: the hooks hand the packet
-- straight on, with no work per recipient at all.
--
-- The classification is a set of small pure functions, exposed as
-- mod.filter for the test (a sub-table: every function stored directly
-- in mod becomes a hook chain).
--
-- API (globals): none. Nothing calls a packetless extension; the only
-- question it answers is "is it agreed with this client", and that is
-- ext_supported(pid, 192) through lib_ext, the same as for every other
-- extension. A wrapper here would add a name to the global table and
-- nothing else, so there isn't one.
local mod = init_mod();
local bit = require("bit");

local EXT_ID = 192;
local EXT_VERSION = 1;

-- How many players this server will seat. 32 is the core's own
-- DEFAULT_MAX_PLAYERS and the value every client copes with; the
-- number is raised only with the paragraph above in mind.
--
-- A COUNT, not a highest id, and the difference is the whole reason
-- MAX_PLAYERS is the right ceiling rather than one less. assign_new_pid
-- counts up to this and stops short of it (main.c:187-191), so a value
-- of N hands out 0 to N-1 -- and MAX_PLAYERS, 255, hands out 0 to 254.
-- That is 255 players with 255 itself never assigned, which is exactly
-- what the extension promises: "up to 255 players, Player ID 255 is
-- reserved for the server". Clamping to 254 would seat 254 and reserve
-- two ids, keeping a promise nobody made.
--
-- Clamped at the bottom to 1 as well, since a server that can seat
-- nobody is a typo rather than a configuration.
getcfg("player_limit_max", 32,
	"How many players this server will seat, 1 to 255. Above 32, an "
		.."old client may mishandle players with high ids.");

-- Hooked rather than left alone even at the default, so that the number
-- has one home. An instance that sets player_limit_max gets it applied
-- everywhere the core and the scripts read this -- pid assignment, the
-- anon pid, the advertised capacity -- without hunting for the other
-- places it is spelled.
--
-- Read out of the global on every call instead of being resolved once,
-- which is what makes `player_limit_max = 64` from the console take
-- effect on the next connection rather than the next restart. The
-- masterlist recomputes capacity on every join and disconnect
-- (masterlist.lua:58-74), so the advertised number follows by itself at
-- the next one; it is only the moment between that stays stale.
function mod.get_effective_max_players()
	local n = math.floor(tonumber(player_limit_max) or 32);

	return math.max(1, math.min(n, MAX_PLAYERS));
end

--============================== FILTER ==============================--

getcfg("player_limit_grace", 10,
	"Seconds a connecting client gets to say whether it speaks Player "
		.."Limit; until then packets naming a player are held for it.");
getcfg("player_limit_queue_max", 20000,
	"Most packets held for one client that has not yet said whether it "
		.."speaks Player Limit.");

-- What an old client holds: 32 slots.
local LOW = 32;
-- The id an old client with a high id is told it has.
local ALIAS = 1;
-- 255 is the server, never a player.
local SERVER = 255;

-- protocol.h: World Update, StateData, Kill, Chat
local PKT_WORLD_UPDATE = 2;
local PKT_STATE = 15;
local PKT_KILL = 16;
local PKT_CHAT = 17;
local CHAT_SYSTEM = 2;
-- 1 + 24 bytes for each of the 32 players
local WORLD_UPDATE_MAX = 1 + LOW * 24;

-- Extension packets are 64 + the extension id.
local PKT_PROPERTIES = 0x40;  -- [pid] at index 2 of sub 0
local PKT_SILENT = 0x43;      -- sub 1: [(pid, flags) x n]
local PKT_DAMAGE = 0x60;      -- [pid][amount]
local PKT_TEAMPLAY = 0x70;    -- sub 0 Config; 1 Ping and 2 Mark: pid at 2
local PKT_PIE = 0x71;
local PKT_FLASHLIGHT = 0x72;  -- sub 0 Light and 2 Config: pid at 2; 1 bitmap
local PKT_DAYTIME = 0x73;
local PKT_EDIT = 0x76;        -- sub 0 and 1: pid at 2

-- Where the player id is, as 1-based positions in the string (so byte
-- index 1 of the packet is position 2), for every packet that has one
-- in the same place whatever else it says: protocol.h, 0.75.
local PLAYER_AT = {[PKT_KILL] = {2, 3}, [PKT_DAMAGE] = {2}};
for _, id in ipairs({3, 4, 6, 7, 8, 9, 10, 12, 13, 14, 17, 20, 23, 24, 25,
                     26, 28, 29, 30}) do
	PLAYER_AT[id] = {2};
end

-- The StateData offsets, as 1-based positions (protocol.h PacketStateData
-- and funcs_send.c send_state_ctf): own id at 2, gamemode at 32 (0 is
-- CTF), heldIntels at 36, the two intel slots of 12 bytes at 37 and 49,
-- the two tents of 12 bytes at 61 and 73; 84 bytes in all. LSd sets bit
-- 1 for the holder of intel slot 0 and bit 0 for slot 1 (send_state_ctf:
-- "the ordering is reversed from what you'd expect").
local STATE_LEN = 84;
local STATE_MODE, STATE_FLAGS, STATE_INTEL, STATE_TENT = 32, 36, 37, 61;
local STATE_CTF = 0;

local function setbyte(data, pos, v)
	return string.sub(data, 1, pos - 1) .. string.char(v) .. string.sub(data, pos + 1);
end

-- Is this the one packet that carries a bitmap of players
local function is_light_state(data)
	return string.byte(data, 1) == PKT_FLASHLIGHT and string.byte(data, 2) == 1;
end

local function is_silent_list(data)
	return string.byte(data, 1) == PKT_SILENT and string.byte(data, 2) == 1;
end

-- The player ids a packet names, as {pos, id} in order, where pos is
-- the 1-based position in the string. {} for a packet that names nobody,
-- and nil for one that cannot be classified (an extension packet this
-- module does not know, or one too short for its own fields), which a
-- filtered client is never sent. A World Update and the Flashlight
-- bitmap name players by their place and not by a byte, and are
-- handled where they are filtered.
local function ids_in(data)
	local id = string.byte(data, 1);
	local at = PLAYER_AT[id];

	if (id == PKT_STATE) then
		at = {2};
	elseif (id == PKT_WORLD_UPDATE) then
		return {};
	elseif (id == PKT_SILENT) then
		if (string.byte(data, 2) ~= 1) then return nil; end
		at = {};
		for pos = 3, #data - 1, 2 do
			at[#at+1] = pos;
		end
		if (#data % 2 ~= 0) then return nil; end
	elseif (id == PKT_PROPERTIES) then
		at = string.byte(data, 2) == 0 and {3} or nil;
	elseif (id == PKT_TEAMPLAY) then
		local sub = string.byte(data, 2);
		at = (sub == 0) and {} or ((sub == 1 or sub == 2) and {3} or nil);
	elseif (id == PKT_FLASHLIGHT) then
		local sub = string.byte(data, 2);
		at = (sub == 1) and {} or ((sub == 0 or sub == 2) and {3} or nil);
	elseif (id == PKT_EDIT) then
		local sub = string.byte(data, 2);
		at = (sub == 0 or sub == 1) and {3} or nil;
	elseif (id == PKT_PIE or id == PKT_DAYTIME) then
		at = {};
	elseif (id ~= nil and id >= 64 and at == nil) then
		return nil;
	end

	if (at == nil) then
		-- an extension packet with a sub-packet we do not know is
		-- unclassifiable; below 64 and not in the table names nobody
		if (id ~= nil and id >= 64) then
			return nil;
		end
		return {};
	end

	local out = {};
	for _, pos in ipairs(at) do
		local v = string.byte(data, pos);
		if (v == nil) then return nil; end
		out[#out+1] = {pos = pos, id = v};
	end
	return out;
end

-- Does this packet name somebody, which is what a client that has not
-- answered yet must not be sent. Unknown counts: it cannot be shown to
-- be safe.
local function names_player(data)
	if (string.byte(data, 1) == PKT_WORLD_UPDATE or is_light_state(data)) then
		return true;
	end
	local ids = ids_in(data);
	return ids == nil or #ids > 0;
end

-- map(id) says what an id becomes, or nil for "this packet may not go".
local function remap(data, map)
	local ids = ids_in(data);
	if (ids == nil) then
		return nil;
	end
	for _, e in ipairs(ids) do
		local n = map(e.id);
		if (n == nil) then
			return nil;
		end
		if (n ~= e.id) then
			data = setbyte(data, e.pos, n);
		end
	end
	return data;
end

-- StateData's intel holders. A holder map() will not name is hidden:
-- the flag is cleared and the intel is put back where it belongs, at its
-- own team's tent, which is where it lies when nobody has it.
local function hide_holders(data, map)
	if (#data < STATE_LEN or string.byte(data, STATE_MODE) ~= STATE_CTF) then
		return data;
	end

	local flags = string.byte(data, STATE_FLAGS);
	for slot = 0, 1 do
		local flag = (slot == 0) and 2 or 1;
		if (bit.band(flags, flag) ~= 0) then
			local pos = STATE_INTEL + slot * 12;
			local h = string.byte(data, pos);
			local n = map(h);

			if (n == nil) then
				flags = flags - flag;
				local tent = STATE_TENT + slot * 12;
				data = string.sub(data, 1, pos - 1)
					.. string.sub(data, tent, tent + 11)
					.. string.sub(data, pos + 12);
			elseif (n ~= h) then
				data = setbyte(data, pos, n);
			end
		end
	end

	return setbyte(data, STATE_FLAGS, flags);
end

local function low_map(id)
	if (id < LOW or id == SERVER) then
		return id;
	end
end

-- What an old client whose own id is below 32 may be sent, or nil.
local function filter_low(data)
	local id = string.byte(data, 1);

	if (id == PKT_WORLD_UPDATE) then
		return #data > WORLD_UPDATE_MAX and string.sub(data, 1, WORLD_UPDATE_MAX) or data;
	end

	if (is_light_state(data)) then
		-- 32 players are 4 bytes of bitmap
		return #data > 2 + LOW / 8 and string.sub(data, 1, 2 + LOW / 8) or data;
	end

	if (id == PKT_STATE) then
		local d = remap(data, low_map);
		return d and hide_holders(d, low_map);
	end

	if (is_silent_list(data)) then
		if (#data % 2 ~= 0) then return nil; end
		local out = {string.sub(data, 1, 2)};
		for pos = 3, #data - 1, 2 do
			if (low_map(string.byte(data, pos)) ~= nil) then
				out[#out+1] = string.sub(data, pos, pos + 1);
			end
		end
		return #out > 1 and table.concat(out) or nil;
	end

	return remap(data, low_map);
end

-- What an old client whose own id is `real`, 32 or more, may be sent:
-- nothing about anybody else, and its own id as ALIAS.
local function filter_alias(data, real)
	local id = string.byte(data, 1);

	local function alias_map(v)
		if (v == real) then return ALIAS; end
		if (v == SERVER) then return v; end
	end

	if (id == PKT_WORLD_UPDATE) then
		return nil;
	end

	if (id == PKT_CHAT and string.byte(data, 3) == CHAT_SYSTEM) then
		return string.byte(data, 2) == real and setbyte(data, 2, ALIAS) or data;
	end

	if (is_light_state(data)) then
		-- only its own light, in the place ALIAS has in the bitmap
		local byte = string.byte(data, 3 + math.floor(real / 8));
		local lit = byte ~= nil and bit.band(byte, bit.lshift(1, real % 8)) ~= 0;
		return string.char(PKT_FLASHLIGHT, 1, lit and bit.lshift(1, ALIAS % 8) or 0);
	end

	if (id == PKT_STATE) then
		local d = remap(data, alias_map);
		return d and hide_holders(d, alias_map);
	end

	if (is_silent_list(data)) then
		if (#data % 2 ~= 0) then return nil; end
		local out = {string.sub(data, 1, 2)};
		for pos = 3, #data - 1, 2 do
			if (string.byte(data, pos) == real) then
				out[#out+1] = string.char(ALIAS, string.byte(data, pos + 1));
			end
		end
		return #out > 1 and table.concat(out) or nil;
	end

	return remap(data, alias_map);
end

mod.filter = {low = filter_low, alias = filter_alias, ids_in = ids_in,
	names_player = names_player};

--=============================== WHO ================================--

-- Same tests, and the same reasons, as lib_edit_mode's person: a bot is
-- nobody's client and sees nothing.
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

local function speaks(pid)
	return ext_supported ~= nil and ext_supported(pid, EXT_ID) ~= nil;
end

-- when each client connected, and what is held for the ones that have
-- not yet answered; both cleared when the client goes
local since = pid_connected_table();
local queue = pid_connected_table();

-- Has this client answered, or run out of time to?
local function decided(pid)
	if (ext_replied ~= nil and ext_replied(pid)) then
		return true;
	end

	local now = get_time();
	if (since[pid] == nil) then
		since[pid] = now;
	end
	return now - since[pid] >= player_limit_grace;
end

local function sane_pid(pid)
	pid = tonumber(pid);
	return pid ~= nil and pid >= 0 and pid < MAX_PLAYERS and pid % 1 == 0;
end

local function classify(pid)
	if (not person(pid) or speaks(pid)) then
		return "all";
	end
	if (not decided(pid)) then
		return "wait";
	end
	return pid < LOW and "low" or "alias";
end

--=============================== WIRE ===============================--

local function raw_send(pid, data, reliable)
	if (reliable) then
		return mod.late.next.send_packet(pid, data);
	end
	return mod.late.next.send_packet_unreliable(pid, data);
end

-- What is held for a client that has now answered, in order.
local function flush(pid)
	local q = queue[pid];
	queue[pid] = nil;
	if (q == nil) then
		return;
	end

	local class = classify(pid);
	if (class == "wait") then
		queue[pid] = q;
		return;
	end
	if (tonumber(player_limit_max) <= LOW) then
		class = "all";
	end

	for _, data in ipairs(q) do
		local out = data;
		if (class == "low") then
			out = filter_low(data);
		elseif (class == "alias") then
			out = filter_alias(data, pid);
		end
		if (out ~= nil) then
			raw_send(pid, out, true);
		end
	end
end

local function deliver(pid, data, reliable)
	local class = classify(pid);

	if (queue[pid] ~= nil and class ~= "wait") then
		flush(pid);   -- before this one, to keep the order
	end

	if (class == "all") then
		return raw_send(pid, data, reliable);
	end

	if (class == "wait") then
		if (not names_player(data)) then
			return raw_send(pid, data, reliable);
		end
		if (reliable) then
			local q = queue[pid];
			if (q == nil) then
				q = {};
				queue[pid] = q;
			end
			-- beyond the cap it is dropped and nothing more is held
			if (#q < player_limit_queue_max) then
				q[#q+1] = data;
			end
		end
		return 0;
	end

	local out;
	if (class == "low") then
		out = filter_low(data);
	else
		out = filter_alias(data, pid);
	end
	if (out == nil) then
		return 0;
	end
	return raw_send(pid, out, reliable);
end

-- Every packet LSd sends passes here. With 32 seats or fewer it is the
-- one comparison and nothing else.
local function route(pid, data, reliable)
	if (tonumber(player_limit_max) <= LOW) then
		return raw_send(pid, data, reliable);
	end

	if (sane_pid(pid)) then
		return deliver(pid, data, reliable);
	end

	for i in piditer(pid) do
		deliver(i, data, reliable);
	end
	return 0;
end

function mod.late.send_packet(pid, data)
	return route(pid, data, true);
end

function mod.late.send_packet_unreliable(pid, data)
	return route(pid, data, false);
end

function mod.after.on_successful_connect(pid)
	since[pid] = get_time();
end

local last_sweep = 0;

-- A client that has answered, with nothing sent to it since, is owed
-- what was held.
function mod.after.tick()
	local now = get_time();
	if (now - last_sweep < 0.25) then
		return;
	end
	last_sweep = now;

	for i in piditer(PID_BROADCAST) do
		if (queue[i] ~= nil and decided(i)) then
			flush(i);
		end
	end
end

-- Registering does not re-announce: negotiation happens once per
-- connection, so a client already connected when this is first loaded
-- was told a list without it and keeps that list.
--
-- No ready callback. A packetless extension has nothing to send when a
-- client turns out to speak it -- that is what packetless means.
function mod.on_load()
	if (ext_register == nil) then
		error("lib_player_limit needs lib_ext loaded first "
			.."(its script pulls lib_ext in; check with: lsdctl status)", 0);
	end

	ext_register("lib_player_limit", EXT_ID, EXT_VERSION, nil, "Player Limit");
end

-- No EXPORTS sweep, because there are no globals to sweep: see the API
-- note in the header. Unregistering is the whole teardown, and the
-- get_effective_max_players hook is taken off the chain by the module
-- system itself.
function mod.on_unload()
	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end
end

return mod;
