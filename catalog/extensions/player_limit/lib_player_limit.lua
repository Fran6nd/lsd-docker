-- lib_player_limit.lua -- The Player Limit protocol extension
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Player Limit extension (id 192, version 1):
-- "tells client server supports up to 255 players. Player ID 255 is
-- reserved for the server and is never given to a player."
--
-- PACKETLESS, which is the whole of the protocol work. There is no
-- packet id, no sub-packet and nothing to parse: the extension is the
-- announcement, and lib_ext makes it along with every other one. So
-- this module is three things -- the registration, the one knob that
-- makes the claim true, and keeping a client that cannot take the claim
-- from ever seeing it.
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
-- keeps, for its own reasons, and the two agree exactly. The ENet host
-- is made with MAX_PLAYERS+1 peers (main.c:114), so the transport has
-- room for all of them too.
--
-- That reservation is also what the Flashlight extension spends: a
-- Light Config addressed to 255 is the beam of every player who has
-- none of their own. Same id, same reason -- it is the one number that
-- cannot be mistaken for somebody.
--
-- THE LIMIT ITSELF is player_limit_max: how many player ids the server
-- hands out, people and bots together, so N seats are ids 0 to N-1.
-- 255 by default -- every id there is. get_effective_max_players is
-- what assign_new_pid counts up to (main.c:187-191), for a person
-- connecting and for lib_bot making a bot alike, and what the
-- masterlist advertises as capacity (masterlist.lua:25-38, and lib_bot's
-- bot-hiding version of the same sum), so it is the one place the
-- number lives. Without this module the core's answer is 32
-- (DEFAULT_MAX_PLAYERS), which is why a server that cannot speak the
-- extension never seats more.
--
-- An operator may lower it. At 32 or fewer, every id fits every client:
-- nothing below runs, and nobody is asked for anything (the policy
-- script.lua gives the extension is "applied"). Withholding the
-- extension (ext_policy 192 = "disabled") has the same effect: a server
-- that does not tell a client it may see 255 players seats 32.
--
-- BOTS GIVE WAY to people (lib_bot): a person who connects when every
-- seat is taken gets a bot's. So bots never keep anybody out, whatever
-- their count; their owners put them back when a seat comes free.
--
-- THE OUTDATED CLIENT. A pid is assigned when a client connects, by
-- assign_new_pid out of on_any_connect, and the extension handshake
-- happens later -- a version request at the end of the map, a response,
-- an ExtensionInfo each way. So at the moment the server has to choose
-- an id it does not yet know whether that client can handle a big one;
-- the ordering is the protocol's, not LSd's.
--
-- A client that does NOT speak extension 192 holds 32 player slots. A
-- packet naming a player of 32 or more -- an ExistingPlayer, a
-- CreatePlayer, a kill, a chat line, a World Update longer than 32
-- entries -- indexes past them: dropped at best, a crash or a corrupted
-- world at worst. So above 32 seats such a client takes the ONE path
-- every client lacking a required extension takes (lib_ext_policy): it
-- is held in spectator and told, in chat, that its client is outdated
-- and what to install. This module registers the extension as required
-- for as long as the server seats more than 32 (the `floor` lib_ext
-- carries to lib_ext_policy), so no policy written in the settings can
-- let such a client onto a team.
--
-- And it is sent nothing it cannot take. Every packet LSd sends goes
-- through send_packet or send_packet_unreliable, so one hook in each, in
-- mod.late after every other script's, sees them all and splits a
-- broadcast into its recipients, as lib_edit_mode does. Per recipient
-- there are three classes:
--
--   all       a bot, or a client that speaks 192: sent as ever
--   wait      has not answered yet: a packet that names no player goes
--             at once (the handshake, map chunks, the version request),
--             one that names a player is held in order and an
--             unreliable one (World Update) is dropped. When the client
--             has answered, or run out of time to (lib_ext_policy's
--             clock: ext_policy_decided), the queue is sent unchanged to
--             a client that speaks 192 and through the filter below to
--             one that does not
--   outdated  answered without 192, or never answered. It is sent
--             nothing about anybody else: no World Update, no packet
--             naming another player. What names only itself goes, its
--             own id told as itself when that is below 32 and as ALIAS
--             (1) when it is not. Packets that name nobody go (the map,
--             fog, intel and territory positions, a progress bar), and
--             system chat lines go -- which is how it is told.
--
-- So what an outdated client sees is the map, its own spectator, and
-- the chat: the server's welcome and the lockout notice, repeated. It
-- believes the server holds one player, itself, with an id below 32,
-- and it keeps believing that until it leaves.
--
-- At 32 seats or fewer none of this runs: the hooks hand the packet
-- straight on, with no work per recipient at all.
--
-- The classification is a set of small pure functions, exposed as
-- mod.filter for the test (a sub-table: every function stored directly
-- in mod becomes a hook chain).
--
-- API (globals): none. Nothing calls a packetless extension; the only
-- question it answers is "is it agreed with this client", and that is
-- ext_supported(pid, 192) through lib_ext, the same as for every other
-- extension.
local mod = init_mod();
local bit = require("bit");

local EXT_ID = 192;
local EXT_VERSION = 1;

-- What a client without the extension holds: 32 slots.
local LOW = 32;

-- How many players this server will seat, people and bots together.
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
getcfg("player_limit_max", 255,
	"How many players, bots included, this server seats: 1 to 255 (ids "
		.."0 to N-1). Above 32, a client without Player Limit only watches.");
getcfg("player_limit_queue_max", 20000,
	"Most packets held for one client that has not yet said whether it "
		.."speaks Player Limit.");

-- The seats in force. Read out of the global on every call instead of
-- being resolved once, which is what makes `player_limit_max = 64` from
-- the console take effect on the next connection rather than the next
-- restart.
local function seats()
	local n = math.floor(tonumber(player_limit_max) or MAX_PLAYERS);
	n = math.max(1, math.min(n, MAX_PLAYERS));

	-- withheld: no client is told it may see more than 32, so none is
	-- given an id it was not told about
	if (ext_is_disabled ~= nil and ext_is_disabled(EXT_ID)) then
		n = math.min(n, LOW);
	end
	return n;
end

-- Hooked rather than left alone, so that the number has one home: pid
-- assignment (people and bots), the anon pid, the advertised capacity.
-- The masterlist recomputes capacity on every join and disconnect
-- (masterlist.lua:58-74), so the advertised number follows by itself.
function mod.get_effective_max_players()
	return seats();
end

-- THE SERVER'S OWN HAND. get_anon_pid is the free player slot the
-- server acts through when nobody does -- map_layout's doors and
-- platforms, babel, every set_block_color(get_anon_pid(), ...) before a
-- block_action. The core's answer is the slot just past the seats
-- (main.c get_anon_pid: `i = get_effective_max_players()`, free since
-- no seat reaches it). With 255 seats that is 255 -- MAX_PLAYERS, which
-- every Lua call taking a player id refuses ("plid is invalid (255)",
-- lua.c check_plid): the editor's first door raised it. So above the
-- core's answer, the highest free seat is the hand instead -- what the
-- core itself falls back to when its slot is taken, searched from the
-- top since people and bots are given the lowest. Only when all 255 ids
-- are taken is there none; lib_bot keeps one free whenever it has bots.
function mod.get_anon_pid()
	local pid = mod.next.get_anon_pid();
	if (pid < MAX_PLAYERS) then
		return pid;
	end

	local taken = {};
	for i in piditer(PID_BROADCAST) do
		taken[i] = true;
	end
	for i = MAX_PLAYERS - 1, 0, -1 do
		if (not taken[i]) then
			return i;
		end
	end
	return pid;
end

-- Above 32 seats every client that lacks the extension is outdated.
local function big()
	return seats() > LOW;
end

--============================== FILTER ==============================--

-- The id an outdated client with a high id is told it has.
local ALIAS = 1;
-- 255 is the server, never a player.
local SERVER = 255;

-- protocol.h: World Update, StateData, Chat
local PKT_WORLD_UPDATE = 2;
local PKT_STATE = 15;
local PKT_KILL = 16;
local PKT_CHAT = 17;
local CHAT_SYSTEM = 2;

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
-- module does not know, or one too short for its own fields), which an
-- outdated client is never sent. A World Update and the Flashlight
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

-- What an outdated client whose own id is `real` may be sent, or nil:
-- nothing about anybody else, and itself under an id below 32.
local function filter_outdated(data, real)
	local id = string.byte(data, 1);
	local me = (real < LOW) and real or ALIAS;

	local function own_map(v)
		if (v == real) then return me; end
		if (v == SERVER) then return v; end
	end

	if (id == PKT_WORLD_UPDATE) then
		return nil;
	end

	-- A system line is how it is told anything, so it goes whoever it
	-- is from: from itself as itself, from a player it cannot hold as
	-- player 0, the speaker server_msg has always used (main.c:1343).
	if (id == PKT_CHAT and string.byte(data, 3) == CHAT_SYSTEM) then
		local from = string.byte(data, 2);
		if (from == real) then
			return setbyte(data, 2, me);
		end
		if (from >= LOW and from ~= SERVER) then
			return setbyte(data, 2, 0);
		end
		return data;
	end

	if (is_light_state(data)) then
		-- only its own light, in its own place: a bitmap as long as it
		-- takes to reach it (ALIAS: one byte)
		local byte = string.byte(data, 3 + math.floor(real / 8));
		local lit = byte ~= nil and bit.band(byte, bit.lshift(1, real % 8)) ~= 0;
		local out = {};
		for i = 1, math.floor(me / 8) + 1 do out[i] = 0; end
		if (lit) then
			out[#out] = bit.lshift(1, me % 8);
		end
		return string.char(PKT_FLASHLIGHT, 1, unpack(out));
	end

	if (id == PKT_STATE) then
		local d = remap(data, own_map);
		return d and hide_holders(d, own_map);
	end

	if (is_silent_list(data)) then
		if (#data % 2 ~= 0) then return nil; end
		local out = {string.sub(data, 1, 2)};
		for pos = 3, #data - 1, 2 do
			if (string.byte(data, pos) == real) then
				out[#out+1] = string.char(me, string.byte(data, pos + 1));
			end
		end
		return #out > 1 and table.concat(out) or nil;
	end

	return remap(data, own_map);
end

mod.filter = {outdated = filter_outdated, ids_in = ids_in,
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

-- what is held for the clients that have not yet answered; cleared when
-- the client goes
local queue = pid_connected_table();
-- when each client connected: the clock, only if lib_ext_policy is not
-- there to keep the one every extension shares
local since = pid_connected_table();
local FALLBACK_GRACE = 10;

-- Has this client answered, or run out of time to? lib_ext_policy's
-- answer when it is loaded -- one clock, so the moment a client is held
-- in spectator and the moment it is shown nobody are the same moment.
local function decided(pid)
	if (ext_policy_decided ~= nil) then
		return ext_policy_decided(pid);
	end
	if (ext_replied ~= nil and ext_replied(pid)) then
		return true;
	end

	local now = get_time();
	if (since[pid] == nil) then
		since[pid] = now;
	end
	return now - since[pid] >= FALLBACK_GRACE;
end

local function sane_pid(pid)
	pid = tonumber(pid);
	return pid ~= nil and pid >= 0 and pid < MAX_PLAYERS and pid % 1 == 0;
end

-- A broadcast set (PID_BROADCAST, _EXCEPT, _TEAM, ...): a flag in the
-- top bits (state.h PID_SET_FLAG), split into its recipients. Anything
-- else that is not a seat -- the console's 255, a new_fakepid handle
-- (commands.lua is_fakepid: MAX_PLAYERS up to 0x20000000) -- is nobody's
-- client and nobody we filter for: it goes on down the chain untouched,
-- to lib_sock or whoever owns it. piditer would match nobody for it and
-- the packet would vanish.
local SET_FLAGS = 0x20000000;
local function is_set(pid)
	pid = tonumber(pid);
	return pid ~= nil and pid >= SET_FLAGS;
end

local function classify(pid)
	if (not person(pid) or speaks(pid)) then
		return "all";
	end
	if (not decided(pid)) then
		return "wait";
	end
	return "outdated";
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
	if (not big()) then
		class = "all";
	end

	for _, data in ipairs(q) do
		local out = data;
		if (class == "outdated") then
			out = filter_outdated(data, pid);
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

	local out = filter_outdated(data, pid);
	if (out == nil) then
		return 0;
	end
	return raw_send(pid, out, reliable);
end

-- Who has a client (false: a bot), found once for each id and forgotten
-- when it leaves.
local human = pid_connected_table();
-- True while no person connected needs a packet held or cut: every one
-- of them speaks the extension and is owed nothing. Worked out a few
-- times a second (tick, below) and dropped the moment somebody connects.
local calm = false;

-- Every packet LSd sends passes here. With 32 seats or fewer it is the
-- one comparison and nothing else.
local function route(pid, data, reliable)
	if (not big()) then
		return raw_send(pid, data, reliable);
	end

	if (sane_pid(pid)) then
		return deliver(pid, data, reliable);
	end
	if (not is_set(pid)) then
		return raw_send(pid, data, reliable);
	end

	-- Everybody a broadcast names who has a client is sent it as they
	-- always were, in one go, when none of them needs it held or cut.
	if (calm) then
		return raw_send(pid, data, reliable);
	end

	-- Otherwise one by one -- and only to people: a bot has no client to
	-- send to, and a server full of bots must not pay for each of them at
	-- every packet.
	for i in piditer(pid) do
		local h = human[i];
		if (h == nil) then
			h = person(i);
			human[i] = h;
		end
		if (h) then
			deliver(i, data, reliable);
		end
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
	human[pid] = nil;
	calm = false;
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

	local quiet = true;
	for i in piditer(PID_BROADCAST) do
		if (queue[i] ~= nil and decided(i)) then
			flush(i);
		end
		local h = human[i];
		if (h == nil) then
			h = person(i);
			human[i] = h;
		end
		if (h and (queue[i] ~= nil or classify(i) ~= "all")) then
			quiet = false;
		end
	end
	calm = quiet;
end

-- What makes the extension required while the server seats more than
-- 32, whatever ext_policy says: lib_ext_policy asks this of every
-- extension that has one.
local function floor()
	return big() and "required" or nil;
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

	ext_register("lib_player_limit", EXT_ID, EXT_VERSION, nil, "Player Limit", floor);
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
