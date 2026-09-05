-- lib_teamplay.lua -- The Teamplay protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Teamplay extension (id 2, version 1): the server
-- can point a client at a player -- "outline that one, for ten seconds,
-- because he has the intel" -- and clients can drop pings in the world
-- for their team.
--
-- THREE SUB-PACKETS AND NOTHING ELSE: Config, Ping, ESP Mark. The
-- extension adds nothing to the base protocol -- no chat type, no packet
-- of its own beyond 66 -- and this module deliberately offers no more
-- than the specification does. Anything a server wants that is not one
-- of those three is not this extension's to carry.
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
--   teamplay_send_config()               re-announce teamplay_features
--   teamplay_listen_ping(name, fn)  / teamplay_unlisten_ping(name)
--        fn(pid, pos, reason) for every ping a client sends
--   teamplay_listen_ready(name, fn) / teamplay_unlisten_ready(name)
--        fn(pid) the moment a client finishes negotiating. This is the
--        hook to hang standing marks off: negotiation finishes well
--        after on_join, so anything sent at join time is sent too early.
--
--   TEAMPLAY_FOREVER  duration meaning "until something clears it"
--   TEAMPLAY_WORLD / TEAMPLAY_MINIMAP / TEAMPLAY_COMPASS
--        surfaces to show a ping or a mark on; add them together, or
--        leave them out to let the client place it where it likes
--
--   opts.reason            free text, shown by the client. Optional, and
--                          may be empty: the spec sizes a mark at "13+"
--                          bytes and a ping at "24+", so the fixed part
--                          alone is a whole packet and a reasonless mark
--                          or ping is an ordinary one, not a degenerate
--   opts.surfaces          where to show it, from the TEAMPLAY_* above.
--                          Omitted or 0 means the client's own choice
--   opts.clear_on_respawn  mark ends the next time the target spawns
--                          (marks only)
--   opts.show_name         client draws the target's name beside the
--                          outline (marks only)
--   opts.color             colour to draw it in, as LSd's {b=,g=,r=}.
--                          No value is reserved -- black is black -- so
--                          omitting it picks a team colour rather than
--                          asking the client for one: the target's for a
--                          mark, the pinger's for a ping, and white when
--                          neither has a team (a server-made ping, a
--                          spectator)
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
                      --            [duration f32][surfaces][b][g][r]
                      --            [msgid][reason]
local SUB_MARK = 2;   -- S->C  [PKT][2][target][duration f32][surfaces]
                      --            [flags][b][g][r][msgid][reason]

-- Direction is part of the specification, not a detail of it. Ping is
-- the only sub-packet a client may send; Config and ESP Mark are Server
-- to Client, one way. A client sending an ESP Mark would be claiming an
-- authority it does not have -- to reveal any player it names, through
-- walls, to itself -- so nothing that is not in this table is read at
-- all, let alone acted on.
local CLIENT_MAY_SEND = {[SUB_PING] = true};

-- Sizes of the fixed part of each sub-packet, which is also the whole
-- packet when the reason is empty -- the spec writes them as "24+" and
-- "13+". An empty reason is legal in both directions and is not a special
-- case anywhere: outbound it appends nothing, inbound it is what is left
-- of a packet that is exactly PING_FIXED long.
--
-- The Message ID is the last fixed byte of both, which is what lets the
-- reason start at a fixed offset no matter what gets added ahead of it.
local PING_FIXED = 24;
local MARK_FIXED = 13;

-- The Message ID byte both sub-packets carry ahead of their reason. It
-- is reserved in version 1: we send 0 and drop anything else we are
-- sent. The byte exists so a later version can name a label out of a
-- fixed table instead of spelling it, without moving where the reason
-- begins -- which is exactly why honouring the "must be 0" now is what
-- keeps that version additive rather than breaking.
local MSG_ID_NONE = 0;

-- Config feature bits. All three are permissions for things the client
-- does on its own initiative -- draw its own team through walls, draw a
-- compass, send a ping -- and none of them govern what the server sends.
-- Whether a client renders a ping or a mark we sent is not up for
-- negotiation: a server that wants one unseen simply does not send it.
local FEAT_TEAM_ESP = 1;    -- bit 0: may reveal its own team, in team colour
local FEAT_PING = 2;        -- bit 1: may SEND pings
local FEAT_COMPASS_HUD = 4; -- bit 2: may draw a compass HUD at all
-- Bits 3-7 are reserved and must go out clear. Clients are told to ignore
-- what they do not know, but sending a bit set is still claiming
-- something, and the one this module would be claiming is a feature a
-- later version defines and this one cannot honour.
local FEATURE_MASK = 7;

-- Where a ping or a mark is to be shown. Any combination is valid, and 0
-- names nothing at all -- which is not "nowhere" but "wherever the client
-- would put it anyway", the value a server with no opinion sends.
--
-- The compass is a bearing and nothing else: no distance, no position,
-- just which way to turn. That makes it the honest surface for anything
-- known by direction alone, and the only one a client may withhold --
-- when it has no compass, or when FEAT_COMPASS_HUD is clear.
TEAMPLAY_WORLD = 1;    -- bit 0: in the world, in 3D
TEAMPLAY_MINIMAP = 2;  -- bit 1: on the minimap, at the position
TEAMPLAY_COMPASS = 4;  -- bit 2: on the compass, as a bearing
local SURFACE_MASK = 7; -- bits 3-7 are reserved and must go out clear

-- ESP Mark flag bits
local CLEAR_ON_RESPAWN = 1; -- bit 0: mark ends the next time they spawn
local SHOW_NAME = 2;        -- bit 1: client draws the target's name too

-- The ping "player id" meaning the server itself said it. The client
-- names whoever is in that field -- a marker is never anonymous and a
-- label is never read as written by somebody who did not write it -- and
-- 255 is the one value it must not look up: it shows no sender at all
-- rather than crediting whoever happens to hold a nearby id.
--
-- Which is why the field is ours to fill and never the sender's to
-- claim: on a relay it is the pid the packet actually arrived from.
local SERVER_ORIGIN = 255;

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
getcfg("teamplay_features",
	FEAT_TEAM_ESP + FEAT_PING + FEAT_COMPASS_HUD);
-- Seconds between accepted pings from one player. The spec recommends
-- one a second and leaves enforcement to the server.
getcfg("teamplay_ping_interval", 1);
-- How long a relayed ping stays up. How long a ping is worth is the
-- server's call alone and never the pinging client's -- a client sends 0
-- here and we overwrite it -- and 5 seconds is the value the spec names
-- for a server with no opinion of its own.
getcfg("teamplay_ping_seconds", 5);
-- Where a relayed ping is shown: everywhere it can be. A ping is a place
-- somebody wants looked at, and the three surfaces answer three different
-- questions about it -- the world marker says where it is, the minimap
-- says where that is relative to everything, and the compass says which
-- way to turn, which is the one that still works when the marker is
-- behind you and off the minimap's edge.
--
-- 0 would leave the placement to the client, which is what the spec asks
-- of a server with no opinion; naming all three is having one. The
-- compass is the only surface a client may decline anyway, when
-- FEAT_COMPASS_HUD is clear or it has none to draw on.
getcfg("teamplay_ping_surfaces",
	TEAMPLAY_WORLD + TEAMPLAY_MINIMAP + TEAMPLAY_COMPASS);
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

-- Surfaces is a bitmask of the three we know, and the reserved bits go
-- out clear whatever a caller hands us -- a client is told to ignore
-- them, but sending them set is still saying something we do not mean.
local function put_surfaces(surfaces)
	return string.char(bit.band(surfaces or 0, SURFACE_MASK));
end

-- What a ping or a mark is drawn in when nobody has a team to borrow a
-- colour from: a ping the server itself made, or one from a spectator.
local NEUTRAL_COLOR = {b=255, g=255, r=255};

-- A colour, Blue Green Red -- the byte order the base protocol already
-- uses for Set Colour and State Data, and the order LSd's own {b=,g=,r=}
-- colour tables are stored in (lua.c:219-232), so a colour from
-- get_team_color or get_map_block_color goes out as it came in.
--
-- No value is reserved: black is black, and a client that receives it
-- draws black rather than reading anything into it. Working out what
-- colour a thing should be is the server's job start to finish, which is
-- why every caller settles on one before it gets here.
local function put_color(c)
	local function chan(v)
		v = math.floor(tonumber(v) or 0);
		return math.max(0, math.min(255, v));
	end

	c = c or NEUTRAL_COLOR;
	return string.char(chan(c.b), chan(c.g), chan(c.r));
end

-- The team colour of a joined player, or nil for anybody who has no team
-- to speak of. Guarded because get_team_color only accepts 1, 2 and
-- SPECTATOR -- check_teamid (lua.c:78-83) raises a Lua error on anything
-- else -- and a mark or a ping is not worth taking the caller down over.
local function team_color_of(pid)
	if (pid == nil or pid == SERVER_ORIGIN) then
		return nil;
	end

	local ok, team = pcall(get_team, pid);
	if (not ok or (team ~= 1 and team ~= 2)) then
		return nil;
	end

	local got, c = pcall(get_team_color, team);
	return got and c or nil;
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

-- The longest prefix of `s` that is at most `max` bytes AND ends on a
-- codepoint boundary. The spec asks for exactly this -- "cap its length,
-- truncating on a codepoint boundary if needed" -- and the boundary is
-- the whole point: cutting a multi-byte character in half produces a
-- reason that is no longer well-formed UTF-8, which is the one thing the
-- validation either side of this is there to prevent.
--
-- Only ever called on a string valid_utf8 has already passed, so the
-- lengths below are the ones its lead bytes promise and the walk cannot
-- run off the end.
local function utf8_truncate(s, max)
	if (#s <= max) then
		return s;
	end

	local i, cut = 1, 0;

	while (i <= #s) do
		local c = string.byte(s, i);
		local len;

		if (c < 0x80) then len = 1;
		elseif (c <= 0xdf) then len = 2;
		elseif (c <= 0xef) then len = 3;
		else len = 4; end

		-- the first character that would cross the cap ends it, and the
		-- cap falls where the last whole one did
		if (i + len - 1 > max) then
			break;
		end

		cut = i + len - 1;
		i = i + len;
	end

	return string.sub(s, 1, cut);
end

-- Always returns a string, possibly empty, which is exactly what the
-- wire wants: no reason, an empty reason and a reason we refused to
-- believe all serialise to nothing at all after the fixed bytes.
--
-- Validated whole and shortened afterwards, in that order. The reverse
-- -- cut to the byte cap, then check -- fails the label that merely
-- happens to have a multi-byte character lying across the cut: the cut
-- leaves a half character behind, the check calls the result malformed,
-- and a perfectly good reason is thrown away in its entirety for being
-- slightly too long. Malformed input is still dropped outright, which is
-- what the spec asks; being over the cap is not malformed.
local function clean_reason(s)
	if (s == nil) then return ""; end

	s = tostring(s);
	if (not valid_utf8(s)) then return ""; end

	return utf8_truncate(s, teamplay_reason_max);
end

--=========================== NEGOTIATION ============================--

-- Announce what we speak. Sent once the client has told us what it is,
-- which is the moment the spec nominates.
local function send_extinfo(pid)
	send_packet(pid, string.char(PKT_EXTINFO, 1, EXT_ID, EXT_VERSION));
end

local function send_config(pid)
	send_packet(pid, string.char(PKT, SUB_CONFIG,
		bit.band(teamplay_features, FEATURE_MASK)));
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

	-- FEAT_PING is permission to send, and the only bit that bears on a
	-- ping arriving. The client is told not to send these without it, and
	-- the spec has us ignore any that turn up regardless.
	if (bit.band(teamplay_features, FEAT_PING) == 0) then
		if (teamplay_ping_debug) then
			log("lib_teamplay: ping #%d refused: sending is not permitted"
				.. " (features %d)", pid, teamplay_features);
		end
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

	-- The Message ID is read here and acted on nowhere: reserved and
	-- unimplemented, so a receiver that gets a non-zero one renders the
	-- packet anyway and ignores the byte. Dropping over it would be the
	-- wrong instinct -- the byte exists for a version that names labels
	-- out of a table, and refusing what we cannot yet read would make
	-- that version a break rather than an addition.

	-- the originating id is the sender's to claim and ours to ignore
	-- (pid is who actually sent the packet), and so are the duration and
	-- the surfaces: how long a ping is worth and where it is shown are
	-- both decided on the relay, not by whoever asked for it
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
		.. put_surfaces(opts.surfaces)
		.. string.char(flags)
		-- no colour asked for means "point at that one and nothing
		-- further", which used to be spelled black and now has to be
		-- spelled out: the target's own team colour, read from our state
		.. put_color(opts.color or team_color_of(target))
		.. string.char(MSG_ID_NONE)
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
		.. put_surfaces(opts.surfaces or teamplay_ping_surfaces)
		-- the colour is the server's alone -- whatever a client put in
		-- these three bytes was ignored on the way in. With no opinion
		-- of our own, the team colour of whoever pinged.
		.. put_color(opts.color or team_color_of(opts.from))
		.. string.char(MSG_ID_NONE)
		.. clean_reason(opts.reason));
	return true;
end

function teamplay_ping_all(pos, opts)
	for i in piditer(PID_BROADCAST) do
		teamplay_ping(i, pos, opts);
	end
end

-- Re-announce the feature bitmask to everybody who has negotiated. The
-- server may send Config whenever it likes and the client applies the
-- new mask at once, which is how a policy change lands mid-session --
-- turning pings off for a map that plays badly with them, say. Set
-- teamplay_features, then call this; without the call the new value only
-- reaches clients that negotiate afterwards.
--
-- REMOVED, and deliberately not coming back: a teamplay_say() that sent
-- private lines as chat type 7. The extension defines three sub-packets
-- and adds nothing to the base protocol -- no chat type is any part of
-- it -- so that was this module inventing wire format and calling it
-- Teamplay. A server wanting a private line has send_chat already.
function teamplay_send_config()
	for i in piditer(PID_BROADCAST) do
		if (supported[i] ~= nil) then
			send_config(i);
		end
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

-- Everything this module put in the global table, taken back out again.
--
-- Unloading a module does not undo its globals -- the functions keep
-- working, closed over the state of a module nothing is calling any
-- more -- and consumers ask "is teamplay_mark nil?" to find out whether
-- the extension is available at all. esp_demo.lua does exactly that.
-- Left behind, those names answer yes forever and the guard is dead
-- code: a server that unloads this module would go on marking players
-- through a module that is gone.
--
-- It is also what makes removing a name stick. teamplay_say() was a chat
-- type this extension does not have; dropping it from the source is only
-- half of it, because a hot reload leaves the old global standing until
-- something clears it. The list is exhaustive on purpose -- a name added
-- to the API above and forgotten here outlives its own module.
local EXPORTS = {
	"teamplay_supported",
	"teamplay_mark", "teamplay_mark_all",
	"teamplay_clear", "teamplay_clear_all",
	"teamplay_ping", "teamplay_ping_all",
	"teamplay_send_config",
	"teamplay_listen_ping", "teamplay_unlisten_ping",
	"teamplay_listen_ready", "teamplay_unlisten_ready",
	"TEAMPLAY_FOREVER",
	"TEAMPLAY_WORLD", "TEAMPLAY_MINIMAP", "TEAMPLAY_COMPASS",
	-- gone, and listed so that a reload clears it off servers that are
	-- still carrying it. Harmless once every running server has done so
	"teamplay_say",
};

function mod.on_unload()
	listeners = {};
	ready_listeners = {};

	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
