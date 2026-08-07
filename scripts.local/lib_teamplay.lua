-- lib_teamplay.lua -- The Extended Teamplay protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Extended Teamplay extension (id 2, version 1):
-- the server can point a client at a player -- "outline that one, for
-- ten seconds, because he has the intel" -- and clients can drop pings
-- in the world for their team.
--
-- Nothing in LSd's core knows about any of this. PacketTypeExtensionInfo
-- is declared in protocol.h:804 and the ExtensionID enum lives at :916,
-- but nothing in funcs_packetrecv.c, funcs_send.c, main.c or lua.c ever
-- touches packet 60 -- so the whole negotiation is unclaimed and this
-- module owns it end to end, through send_packet and on_any_packet.
--
-- API (globals):
--   teamplay_supported(pid)              -> true once ext 2 is agreed
--   teamplay_mark(viewer, target, secs, opts)     one viewer
--   teamplay_mark_all(target, secs, opts)         everyone who can see it
--   teamplay_clear(viewer, target) / teamplay_clear_all(target)
--   teamplay_ping(viewer, pos, opts) / teamplay_ping_all(pos, opts)
--   teamplay_listen_ping(name, fn)  / teamplay_unlisten_ping(name)
--        fn(pid, pos, reason) for every ping a client sends
--   teamplay_listen_ready(name, fn) / teamplay_unlisten_ready(name)
--        fn(pid) the moment a client finishes negotiating. This is the
--        hook to hang standing marks off: negotiation finishes well
--        after on_join, so anything sent at join time is sent too early.
--
--   TEAMPLAY_FOREVER  duration meaning "until something clears it"
--
--   opts.reason          free text, shown by the client. Optional, and
--                        may be empty: the spec sizes a mark at "5+"
--                        bytes and a ping at "15+", so the fixed part
--                        alone is a whole packet and a reasonless mark
--                        or ping is an ordinary one, not a degenerate
--   opts.clear_on_death  mark ends when the target dies (marks only)
--   opts.from            pid the ping is attributed to (pings only)
--
-- secs: 0 clears, 1..254 seconds, 255 until cleared.
--
-- WHAT THIS DOES NOT DO: anything for clients that don't speak it. The
-- extension is unreleased, so today that is every client -- they simply
-- never negotiate, never get a packet 66, and never know. There is no
-- fallback path and there should not be one; a body outline drawn
-- through a wall is not something a server can approximate.
--
-- All of it is the client's to render. The server's whole vocabulary is
-- "this player, this long, for this reason".
local mod = init_mod();
local ffi = require("ffi");
local bit = require("bit");

-- ExtensionInfo. [60][length][(id, version) x length], 2+2*length bytes
-- (protocol.h:640-654). Ours lists exactly one entry.
local PKT_EXTINFO = 60;
local EXT_ID = 2;
local EXT_VERSION = 1;

-- Extended Teamplay. Base id is 64 + extension id.
local PKT = 64 + EXT_ID;
local SUB_CONFIG = 0;   -- S->C  [PKT][0][features]
local SUB_PING = 1;     -- S<->C [PKT][1][pid][x f32][y f32][z f32][reason]
local SUB_MARK = 2;     -- S->C  [PKT][2][target][duration][flags][reason]

-- Direction is part of the specification, not a detail of it. Ping is
-- the only sub-packet a client may send; Config and ESP Mark are Server
-- to Client, one way. A client sending an ESP Mark would be claiming an
-- authority it does not have -- to reveal any player it names, through
-- walls, to itself -- so nothing that is not in this table is read at
-- all, let alone acted on.
local CLIENT_MAY_SEND = {[SUB_PING] = true};

-- Sizes of the fixed part of each sub-packet, which is also the whole
-- packet when the reason is empty -- the spec writes them as "15+" and
-- "5+". An empty reason is legal in both directions and is not a special
-- case anywhere: outbound it appends nothing, inbound it is what is left
-- of a packet that is exactly PING_FIXED long.
local PING_FIXED = 15;
local MARK_FIXED = 5;

-- Config feature bits
local TEAM_ESP = 1;     -- bit 0: client may render teammates through walls
local PING_WORLD = 2;   -- bit 1: client may draw pings as 3D markers
local PING_MINIMAP = 4; -- bit 2: client may draw pings on the minimap

-- ESP Mark flag bits
local CLEAR_ON_DEATH = 1;

local SERVER_ORIGIN = 255; -- ping "player id" meaning the server said it

-- Duration 255 is "reveal until the server clears it". Marks are state
-- held per target player id -- one per target, a new one replacing the
-- old -- and the client drops them by itself when the target dies with
-- CLEAR_ON_DEATH set, when the target leaves, or on a map change. So a
-- standing mark is set once and left; there is nothing to refresh.
TEAMPLAY_FOREVER = 255;

-- Which features clients are allowed to use. Sent as the Config
-- sub-packet; reserved bits 3-7 must stay clear.
getcfg("teamplay_features", TEAM_ESP + PING_WORLD + PING_MINIMAP);
-- Seconds between accepted pings from one player. The spec recommends
-- one a second and leaves enforcement to the server.
getcfg("teamplay_ping_interval", 1);
-- Longest ping/mark reason accepted or sent, in bytes.
getcfg("teamplay_reason_max", 128);
-- Relay a client's ping to the rest of its team automatically. Listeners
-- see it either way; turn this off to decide distribution yourself.
getcfg("teamplay_relay_pings", true);
-- Send our ExtensionInfo only to clients newer than this. The spec says
-- to announce "after the Version Info response has been received to
-- compatible clients (OpenSpades versions > 0.1.3)" -- older ones are
-- not known to handle packet 60 gracefully, and nothing is lost by
-- staying quiet at them.
getcfg("teamplay_min_major", 0);
getcfg("teamplay_min_minor", 1);
getcfg("teamplay_min_patch", 3);

-- pid -> version of ext 2 the client announced. Cleared on disconnect,
-- because the next occupant of that slot has agreed to nothing.
local supported = pid_connected_table();
-- pid -> when we last accepted a ping from them
local ping_at = pid_connected_table(0);

local listeners = {};       -- client pings
local ready_listeners = {}; -- clients that have just negotiated

--============================== BYTES ===============================--
-- Three little-endian float32s, which is what the wire wants and what
-- an x86 host natively writes. There is no string.pack here (LuaJIT is
-- 5.1; it arrived in 5.3), so the FFI does it.
local f32 = ffi.new("float[3]");

local function put_f32x3(x, y, z)
	f32[0], f32[1], f32[2] = x, y, z;
	return ffi.string(f32, 12);
end

local function get_f32x3(data, off)
	ffi.copy(f32, string.sub(data, off, off+11), 12);
	return {x=f32[0], y=f32[1], z=f32[2]};
end

-- The spec asks the server to validate the UTF-8 in a reason before
-- passing it on, and LSd exposes no validator, so: walk it. Rejects
-- overlong forms, surrogates and anything past U+10FFFF, which are the
-- ways a decoder gets surprised. The empty string walks zero times and
-- is valid, which is the answer we want -- see clean_reason.
local function valid_utf8(s)
	local i, n = 1, #s;

	while (i <= n) do
		local c = string.byte(s, i);
		local len, cp;

		if (c < 0x80) then len, cp = 1, c;
		elseif (c >= 0xc2 and c <= 0xdf) then len, cp = 2, c - 0xc0;
		elseif (c >= 0xe0 and c <= 0xef) then len, cp = 3, c - 0xe0;
		elseif (c >= 0xf0 and c <= 0xf4) then len, cp = 4, c - 0xf0;
		else return false; end

		if (i + len - 1 > n) then return false; end
		for k = 1, len-1 do
			local cc = string.byte(s, i+k);
			if (cc == nil or cc < 0x80 or cc > 0xbf) then return false; end
			cp = cp*64 + (cc - 0x80);
		end

		if (len == 3 and cp < 0x800) then return false; end
		if (len == 4 and cp < 0x10000) then return false; end
		if (cp > 0x10ffff) then return false; end
		if (cp >= 0xd800 and cp <= 0xdfff) then return false; end

		i = i + len;
	end

	return true;
end

-- Always returns a string, possibly empty, which is exactly what the
-- wire wants: no reason, an empty reason and a reason we refused to
-- believe all serialise to nothing at all after the fixed bytes.
local function clean_reason(s)
	if (s == nil) then return ""; end
	s = string.sub(tostring(s), 1, teamplay_reason_max);
	if (not valid_utf8(s)) then return ""; end
	return s;
end

--=========================== NEGOTIATION ============================--

-- Announce what we speak. Sent once the client has told us what it is,
-- which is the moment the spec nominates.
local function send_extinfo(pid)
	send_packet(pid, string.char(PKT_EXTINFO, 1, EXT_ID, EXT_VERSION));
end

local function send_config(pid)
	send_packet(pid, string.char(PKT, SUB_CONFIG,
		bit.band(teamplay_features, 0xff)));
end

function mod.after.on_version(pid, idChar, major, minor, patch, msg)
	if (major < teamplay_min_major) then return; end
	if (major == teamplay_min_major) then
		if (minor < teamplay_min_minor) then return; end
		if (minor == teamplay_min_minor and patch <= teamplay_min_patch) then
			return;
		end
	end

	send_extinfo(pid);
end

-- Their half of the handshake. An extension is mutually supported once
-- both sides have named it; we have already named ours by now, so
-- finding ext 2 in their list settles it.
local function on_extinfo(pid, data)
	local n = string.byte(data, 2);

	if (n == nil or #data ~= 2 + 2*n) then
		return;
	end

	for i = 0, n-1 do
		local id = string.byte(data, 3 + i*2);
		local ver = string.byte(data, 4 + i*2);

		if (id == EXT_ID) then
			-- version 1 is all this module knows how to speak; a client
			-- announcing something newer is not something to guess at
			if (ver == EXT_VERSION) then
				supported[pid] = ver;
				send_config(pid);

				for lname,fn in pairs(ready_listeners) do
					local ok, err = pcall(fn, pid);
					if (not ok) then
						ready_listeners[lname] = nil;
						log("lib_teamplay: %s crashed on ready, dropped: %s",
							lname, tostring(err));
					end
				end
			end
			return;
		end
	end
end

--========================== CLIENT PINGS ============================--

local function on_ping(pid, data)
	-- the client is told not to send these when both ping bits are
	-- clear, so one arriving anyway is not something to honour
	if (bit.band(teamplay_features, PING_WORLD + PING_MINIMAP) == 0) then
		return;
	end
	-- exactly PING_FIXED is a ping with no reason, which is allowed;
	-- shorter than that is a truncated packet, which is not
	if (#data < PING_FIXED or not is_alive(pid)) then
		return;
	end

	local now = get_time();
	if (now - ping_at[pid] < teamplay_ping_interval) then
		return;
	end

	-- the originating id is the sender's to claim and ours to ignore:
	-- pid is who actually sent the packet
	local pos = get_f32x3(data, 4);
	if (pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z) then
		return; -- NaN
	end
	if (pos.x < 0 or pos.x >= 512 or pos.y < 0 or pos.y >= 512
	    or pos.z < -1 or pos.z > 64) then
		return;
	end

	local reason = clean_reason(string.sub(data, PING_FIXED + 1));

	ping_at[pid] = now;

	if (teamplay_relay_pings) then
		for i in piditer(PID_BROADCAST_TEAM(get_team(pid))) do
			if (supported[i] ~= nil) then
				teamplay_ping(i, pos, {from=pid, reason=reason});
			end
		end
	end

	for name,fn in pairs(listeners) do
		local ok, err = pcall(fn, pid, pos, reason);
		if (not ok) then
			listeners[name] = nil;
			log("lib_teamplay: %s crashed on a ping, dropped: %s",
				name, tostring(err));
		end
	end
end

--============================= INTAKE ===============================--
-- Both packet ids are unknown to the core, which would log them as
-- "Unknown packet ID" crap (funcs_packetrecv.c:485). Returning 0 hands
-- them to on_sane_packet instead, whose switch has no default case, so
-- they are silently dropped there having already been dealt with here.
function mod.on_any_packet(pid, data)
	local id = string.byte(data, 1);

	if (id == PKT_EXTINFO) then
		on_extinfo(pid, data);
		return 0;
	end

	if (id == PKT) then
		local sub = string.byte(data, 2);

		-- one way only, see CLIENT_MAY_SEND
		if (sub == nil or not CLIENT_MAY_SEND[sub]) then
			return 0;
		end

		if (sub == SUB_PING) then
			on_ping(pid, data);
		end
		return 0;
	end

	return mod.next.on_any_packet(pid, data);
end

--=============================== API ================================--

function teamplay_supported(pid)
	return supported[pid] ~= nil;
end

-- Outline `target` on `viewer`'s screen. secs 0 clears it, 255 leaves it
-- until something else does.
function teamplay_mark(viewer, target, secs, opts)
	if (supported[viewer] == nil) then
		return false;
	end

	opts = opts or {};
	secs = math.max(0, math.min(255, math.floor(secs or 0)));

	local flags = 0;
	if (opts.clear_on_death) then
		flags = flags + CLEAR_ON_DEATH;
	end

	send_packet(viewer, string.char(PKT, SUB_MARK, target, secs, flags)
		.. clean_reason(opts.reason));
	return true;
end

function teamplay_mark_all(target, secs, opts)
	for i in piditer(PID_BROADCAST) do
		teamplay_mark(i, target, secs, opts);
	end
end

function teamplay_clear(viewer, target)
	return teamplay_mark(viewer, target, 0);
end

function teamplay_clear_all(target)
	teamplay_mark_all(target, 0);
end

-- Drop a ping at pos on viewer's screen. opts.from attributes it to a
-- player; left out, it comes from the server.
function teamplay_ping(viewer, pos, opts)
	if (supported[viewer] == nil) then
		return false;
	end

	opts = opts or {};

	send_packet(viewer, string.char(PKT, SUB_PING, opts.from or SERVER_ORIGIN)
		.. put_f32x3(pos.x, pos.y, pos.z)
		.. clean_reason(opts.reason));
	return true;
end

function teamplay_ping_all(pos, opts)
	for i in piditer(PID_BROADCAST) do
		teamplay_ping(i, pos, opts);
	end
end

function teamplay_listen_ping(name, fn)
	if (type(name) ~= "string" or type(fn) ~= "function") then
		error("teamplay_listen_ping: name and fn required", 2);
	end
	listeners[name] = fn;
end

function teamplay_unlisten_ping(name)
	listeners[name] = nil;
end

function teamplay_listen_ready(name, fn)
	if (type(name) ~= "string" or type(fn) ~= "function") then
		error("teamplay_listen_ready: name and fn required", 2);
	end
	ready_listeners[name] = fn;
end

function teamplay_unlisten_ready(name)
	ready_listeners[name] = nil;
end

-- Whatever a client agreed with the last copy of this module is not
-- something the new copy has any record of, and the client will not
-- repeat itself. Re-announcing costs one packet and settles it.
function mod.on_load()
	for i in piditer(PID_BROADCAST) do
		if (get_client_char(i) ~= nil) then
			send_extinfo(i);
		end
	end
end

function mod.on_unload()
	listeners = {};
	ready_listeners = {};
end

return mod;
