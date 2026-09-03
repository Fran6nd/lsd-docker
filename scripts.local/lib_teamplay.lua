-- lib_teamplay.lua -- The Teamplay protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Teamplay extension (id 2, version 1): the server
-- can point a client at a player -- "outline that one, for ten seconds,
-- because he has the intel" -- clients can drop pings in the world for
-- their team, and the server can say a line to one player alone.
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
--   teamplay_say(pid, msg, from)         one line, to that player alone
--   teamplay_listen_ping(name, fn)  / teamplay_unlisten_ping(name)
--        fn(pid, pos, reason) for every ping a client sends
--   teamplay_listen_ready(name, fn) / teamplay_unlisten_ready(name)
--        fn(pid) the moment a client finishes negotiating. This is the
--        hook to hang standing marks off: negotiation finishes well
--        after on_join, so anything sent at join time is sent too early.
--
--   TEAMPLAY_FOREVER  duration meaning "until something clears it"
--
--   opts.reason            free text, shown by the client. Optional, and
--                          may be empty: the spec sizes a mark at "9+"
--                          bytes and a ping at "20+", so the fixed part
--                          alone is a whole packet and a reasonless mark
--                          or ping is an ordinary one, not a degenerate
--   opts.clear_on_respawn  mark ends the next time the target spawns
--                          (marks only)
--   opts.show_name         client draws the target's name beside the
--                          outline (marks only)
--   opts.from              pid the ping is attributed to (pings only)
--   opts.secs              how long a ping stays; defaults to
--                          teamplay_ping_seconds (pings only)
--
-- secs: a number of seconds, 0 to clear, TEAMPLAY_FOREVER to leave it
-- until something else does. Fractions are fine -- it goes on the wire
-- as a float. Negative and NaN are refused rather than sent.
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

-- Teamplay. Base id is 64 + extension id.
local PKT = 64 + EXT_ID;
local SUB_CONFIG = 0; -- S->C  [PKT][0][features]
local SUB_PING = 1;   -- S<->C [PKT][1][pid][x f32][y f32][z f32]
                      --                  [duration f32][msgid][reason]
local SUB_MARK = 2;   -- S->C  [PKT][2][target][duration f32][flags]
                      --                  [msgid][reason]

-- Direction is part of the specification, not a detail of it. Ping is
-- the only sub-packet a client may send; Config and ESP Mark are Server
-- to Client, one way. A client sending an ESP Mark would be claiming an
-- authority it does not have -- to reveal any player it names, through
-- walls, to itself -- so nothing that is not in this table is read at
-- all, let alone acted on.
local CLIENT_MAY_SEND = {[SUB_PING] = true};

-- Sizes of the fixed part of each sub-packet, which is also the whole
-- packet when the reason is empty -- the spec writes them as "20+" and
-- "9+". An empty reason is legal in both directions and is not a special
-- case anywhere: outbound it appends nothing, inbound it is what is left
-- of a packet that is exactly PING_FIXED long.
local PING_FIXED = 20;
local MARK_FIXED = 9;

-- The Message ID byte both sub-packets carry ahead of their reason. It
-- is reserved in version 1: we send 0 and drop anything else we are
-- sent. The byte exists so a later version can name a label out of a
-- fixed table instead of spelling it, without moving where the reason
-- begins -- which is exactly why honouring the "must be 0" now is what
-- keeps that version additive rather than breaking.
local MSG_ID_NONE = 0;

-- Config feature bits
local TEAM_ESP = 1;     -- bit 0: client may render teammates through walls
local PING_WORLD = 2;   -- bit 1: client may draw pings as 3D markers
local PING_MINIMAP = 4; -- bit 2: client may draw pings on the minimap

-- ESP Mark flag bits
local CLEAR_ON_RESPAWN = 1; -- bit 0: mark ends the next time they spawn
local SHOW_NAME = 2;        -- bit 1: client draws the target's name too

-- Direct chat. Not a sub-packet: a chat type the extension adds to the
-- base Chat Message packet, for a line meant for one player alone.
local CHAT_DIRECT = 7;

local SERVER_ORIGIN = 255; -- ping "player id" meaning the server said it

-- An infinite duration is "reveal until the server clears it". Marks are
-- state held per target player id -- one per target, a new one replacing
-- the old -- and the client drops them by itself when the target spawns
-- with CLEAR_ON_RESPAWN set, when the target leaves, or on a map change.
-- So a standing mark is set once and left; there is nothing to refresh.
--
-- A finite duration is the other half of the same dial, and the cheaper
-- half: the client forgets the mark on its own and the server keeps no
-- timer, no state and sends no removal packet. Both spellings cost the
-- same four bytes, so the choice is only ever about who does the work.
TEAMPLAY_FOREVER = math.huge;

-- Which features clients are allowed to use. Sent as the Config
-- sub-packet; reserved bits 3-7 must stay clear.
getcfg("teamplay_features", TEAM_ESP + PING_WORLD + PING_MINIMAP);
-- Seconds between accepted pings from one player. The spec recommends
-- one a second and leaves enforcement to the server.
getcfg("teamplay_ping_interval", 1);
-- How long a relayed ping stays up. How long a ping is worth is the
-- server's call alone and never the pinging client's -- a client sends 0
-- here and we overwrite it -- and 5 seconds is the value the spec names
-- for a server with no opinion of its own.
getcfg("teamplay_ping_seconds", 5);
-- How near the crosshair a pinged point has to be to be believed, as the
-- cosine of the angle between it and the player's aim. 0.985 is about
-- ten degrees, which is slack for the tick of lag between the
-- orientation we hold and the one the client pinged from, and nothing
-- like enough to ping something it is not looking at.
getcfg("teamplay_ping_aim_cos", 0.985);
-- How far short of the pinged point a wall may sit and still count as
-- the thing being pinged, in blocks. raycast reports a voxel index while
-- the ping is a point on a surface, which is up to a block and a half
-- apart before anybody is lying; 2 covers that and little else.
getcfg("teamplay_ping_los_slack", 2.0);
-- Log every ping and every reason one was refused. For working out why a
-- client's pings are not arriving; noisy, and off unless you are asking.
getcfg("teamplay_ping_debug", false);
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

local function put_f32(v)
	f32[0] = v;
	return ffi.string(f32, 4);
end

local function put_f32x3(x, y, z)
	f32[0], f32[1], f32[2] = x, y, z;
	return ffi.string(f32, 12);
end

local function get_f32x3(data, off)
	ffi.copy(f32, string.sub(data, off, off+11), 12);
	return {x=f32[0], y=f32[1], z=f32[2]};
end

-- The smallest positive float32 there is. Everything under it rounds to
-- zero on the wire, and zero is the value that *removes* a mark, so a
-- caller asking for an absurdly short one would silently clear it
-- instead. Round up to the shortest lifetime the encoding can say.
local F32_TINY = 1.4e-45;

-- Durations travel as an LE float32 count of seconds. 0 removes, a
-- positive finite number is a lifetime, +inf stays until something
-- clears it, and negative or NaN is invalid -- the spec has the receiver
-- drop such a packet, so there is no point sending one. Returns nil for
-- those, which every caller reads as "did not send".
local function put_duration(secs)
	if (type(secs) ~= "number" or secs ~= secs or secs < 0) then
		return nil;
	end
	if (secs > 0 and secs < F32_TINY) then
		secs = F32_TINY;
	end
	return put_f32(secs);
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

-- The spec has the server identify the target of a ping itself rather
-- than take the client's word for it: the coordinates are there so the
-- two ends can be checked against each other, and the server raycasts
-- from the pinger through their crosshair to confirm line of sight.
--
-- So: the point has to lie along the aim, and the line to it has to be
-- clear. A point behind the pinger or through a wall is a desynced
-- client at best and a client pinging what it cannot see at worst, and
-- the two are not worth telling apart -- neither is a ping.
local function ping_is_sane(pid, pos)
	local eye = get_position(pid);
	local dir = get_orientation(pid);
	local dx, dy, dz = pos.x - eye.x, pos.y - eye.y, pos.z - eye.z;
	local reach = math.sqrt(dx*dx + dy*dy + dz*dz);
	local aim = math.sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z);

	-- get_orientation is documented as a direction vector, not as a unit
	-- one (lua_playerget:27 leaves its length open), so normalise before
	-- reading a dot product as a cosine
	if (reach > 0.001 and aim > 0.001) then
		local dot = (dx*dir.x + dy*dir.y + dz*dir.z) / (reach * aim);
		if (dot < teamplay_ping_aim_cos) then
			if (teamplay_ping_debug) then
				log("lib_teamplay: ping #%d refused, off aim: cos %.4f < %.4f"
					.. " (eye %.1f,%.1f,%.1f -> %.1f,%.1f,%.1f, %.1f away)",
					pid, dot, teamplay_ping_aim_cos, eye.x, eye.y, eye.z,
					pos.x, pos.y, pos.z, reach);
			end
			return false;
		end
	end

	-- raycast walks to the last empty voxel before whatever it hit, so
	-- what matters is how far along the line that voxel sits: at about
	-- the pinged point, the wall being pinged is the wall in front of
	-- it; well short of it, something else is in the way.
	--
	-- Distances, not voxel identity. A ping lands on a *surface*, and a
	-- surface coordinate does not floor to the voxel behind it -- enter a
	-- block from the far side and the intersection is exactly on the next
	-- voxel's boundary, and a client that nudges its marker off the wall
	-- to keep it from z-fighting misses by a whole block every time. That
	-- test refused honest pings from half the compass.
	--
	-- Linear, not squared, because the slack is a distance in blocks and
	-- has to stay one at any range: a squared tolerance that is generous
	-- up close is nothing at all fifty blocks out.
	local hit = raycast(eye, pos, false);
	if (hit == nil) then
		return true;
	end

	local hd = math.sqrt((hit.x-eye.x)^2 + (hit.y-eye.y)^2 + (hit.z-eye.z)^2);

	if (hd < reach - teamplay_ping_los_slack) then
		if (teamplay_ping_debug) then
			log("lib_teamplay: ping #%d refused, wall in the way: solid at"
				.. " %.1f but the ping is %.1f away (slack %.1f)",
				pid, hd, reach, teamplay_ping_los_slack);
		end
		return false;
	end

	return true;
end

local function on_ping(pid, data)
	if (teamplay_ping_debug) then
		log("lib_teamplay: ping from #%d, %d bytes, msgid %s",
			pid, #data, tostring(string.byte(data, PING_FIXED)));
	end

	-- the client is told not to send these when both ping bits are
	-- clear, so one arriving anyway is not something to honour
	if (bit.band(teamplay_features, PING_WORLD + PING_MINIMAP) == 0) then
		return;
	end
	-- exactly PING_FIXED is a ping with no reason, which is allowed;
	-- shorter than that is a truncated packet, which is not
	if (#data < PING_FIXED or not is_alive(pid)) then
		if (teamplay_ping_debug) then
			log("lib_teamplay: ping #%d refused: %d bytes (want >=%d), alive %s",
				pid, #data, PING_FIXED, tostring(is_alive(pid)));
		end
		return;
	end

	local now = get_time();
	if (now - ping_at[pid] < teamplay_ping_interval) then
		if (teamplay_ping_debug) then
			log("lib_teamplay: ping #%d refused, too soon: %.2fs since the"
				.. " last (need %.2fs)", pid, now - ping_at[pid],
				teamplay_ping_interval);
		end
		return;
	end

	-- reserved in version 1, and the spec says to drop rather than
	-- ignore: a client putting something else here means a label we have
	-- no table for, so relaying it would pass on a meaning we cannot read
	if (string.byte(data, PING_FIXED) ~= MSG_ID_NONE) then
		if (teamplay_ping_debug) then
			log("lib_teamplay: ping #%d refused, message id %d is not 0",
				pid, string.byte(data, PING_FIXED));
		end
		return;
	end

	-- the originating id is the sender's to claim and ours to ignore
	-- (pid is who actually sent the packet), and so is the duration:
	-- how long a ping is worth is decided below, not here
	local pos = get_f32x3(data, 4);
	if (pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z) then
		return; -- NaN
	end
	if (pos.x < 0 or pos.x >= 512 or pos.y < 0 or pos.y >= 512
	    or pos.z < -1 or pos.z > 64) then
		if (teamplay_ping_debug) then
			log("lib_teamplay: ping #%d refused, off the map: %.1f,%.1f,%.1f",
				pid, pos.x, pos.y, pos.z);
		end
		return;
	end
	if (not ping_is_sane(pid, pos)) then
		return;
	end

	local reason = clean_reason(string.sub(data, PING_FIXED + 1));

	ping_at[pid] = now;

	-- the pinger's own team, which includes the pinger: a player sees the
	-- marker they just placed, the same as everyone they placed it for
	if (teamplay_relay_pings) then
		local sent = 0;

		for i in piditer(PID_BROADCAST_TEAM(get_team(pid))) do
			if (supported[i] ~= nil and teamplay_ping(i, pos, {
					from = pid, reason = reason})) then
				sent = sent + 1;
			end
		end

		if (teamplay_ping_debug) then
			log("lib_teamplay: ping #%d accepted at %.1f,%.1f,%.1f,"
				.. " relayed to %d of team %d (reason %q)",
				pid, pos.x, pos.y, pos.z, sent, get_team(pid), reason);
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

-- Outline `target` on `viewer`'s screen. secs 0 clears it,
-- TEAMPLAY_FOREVER leaves it until something else does.
function teamplay_mark(viewer, target, secs, opts)
	if (supported[viewer] == nil) then
		return false;
	end

	local duration = put_duration(secs or 0);
	if (duration == nil) then
		return false;
	end

	opts = opts or {};

	local flags = 0;
	if (opts.clear_on_respawn) then
		flags = flags + CLEAR_ON_RESPAWN;
	end
	if (opts.show_name) then
		flags = flags + SHOW_NAME;
	end

	send_packet(viewer, string.char(PKT, SUB_MARK, target) .. duration
		.. string.char(flags, MSG_ID_NONE)
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
--
-- One ping per originating id: a second one from the same id replaces
-- the first. A server wanting several standing markers at once wants
-- marks, or a ping per id -- not several from SERVER_ORIGIN.
function teamplay_ping(viewer, pos, opts)
	if (supported[viewer] == nil) then
		return false;
	end

	opts = opts or {};

	local duration = put_duration(opts.secs or teamplay_ping_seconds);
	if (duration == nil) then
		return false;
	end

	send_packet(viewer, string.char(PKT, SUB_PING, opts.from or SERVER_ORIGIN)
		.. put_f32x3(pos.x, pos.y, pos.z)
		.. duration
		.. string.char(MSG_ID_NONE)
		.. clean_reason(opts.reason));
	return true;
end

function teamplay_ping_all(pos, opts)
	for i in piditer(PID_BROADCAST) do
		teamplay_ping(i, pos, opts);
	end
end

-- Say `msg` to `pid` and to nobody else, as a private message. This is
-- the one thing the extension adds outside packet 66: a chat type on the
-- base Chat Message packet, which already carries the sender in its
-- Player ID and takes the recipient from who it was sent to, so it needs
-- no field of its own. send_chat writes the type straight into that byte
-- (funcs_send.c:383-393) and nothing on the way clamps it, so type 7 is
-- ours to use.
--
-- Only for clients that negotiated: type 7 means nothing to a client
-- that did not agree to this, and what it does with an unknown type is
-- its own business. Callers get false for those and fall back to
-- whatever private form they already had.
function teamplay_say(pid, msg, from)
	if (supported[pid] == nil) then
		return false;
	end

	send_chat(pid, msg, CHAT_DIRECT, from or SERVER_ORIGIN);
	return true;
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
