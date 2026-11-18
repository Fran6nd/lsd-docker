-- lib_teamplay.lua -- The Teamplay protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Teamplay extension (id 48, version 1): the server
-- can point a client at a player -- "outline that one, for ten seconds,
-- because he has the intel" -- clients can drop pings in the world for
-- their team, and the server says which way north is, so a compass has
-- something to point at.
--
-- THREE SUB-PACKETS AND NOTHING ELSE: Config, Ping, ESP Mark, all three
-- carried inside packet 112 and nothing else added to the base protocol.
-- This module offers no more than the specification does; anything a
-- server wants that is not one of those three is not this extension's to
-- carry.
--
-- Nothing in LSd's core knows about any of this. PacketTypeExtensionInfo
-- is declared in protocol.h:804 and the ExtensionID enum lives at :916 --
-- which names 0, 1 and the packetless ones, and nothing near 48 -- while
-- nothing in funcs_packetrecv.c, funcs_send.c, main.c or lua.c ever
-- touches packet 60. So the negotiation is unclaimed, and lib_ext claims
-- it for every extension at once. This module owns packet 112 and nothing
-- else; load lib_ext before it.
--
-- API (globals):
--   teamplay_supported(pid)              -> true once ext 48 is agreed
--   teamplay_mark(viewer, target, secs, opts)     one viewer
--   teamplay_mark_all(target, secs, opts)         everyone who can see it,
--        including clients that negotiate later: the mark is remembered
--        and re-sent to them with the time it has left
--   teamplay_clear(viewer, target) / teamplay_clear_all(target)
--   teamplay_ping(viewer, pos, opts) / teamplay_ping_all(pos, opts)
--   teamplay_send_config()               re-announce features and north
--   teamplay_listen_ping(name, fn)  / teamplay_unlisten_ping(name)
--        fn(pid, pos, reason) for every ping a client sends
--   teamplay_listen_ready(name, fn) / teamplay_unlisten_ready(name)
--        fn(pid) the moment a client finishes negotiating. This is the
--        hook to hang standing marks off: negotiation finishes well
--        after on_join, so anything sent at join time is sent too early.
--
--   /pingmark <x> <y> <z> [reason...]
--        the spec's chat command for a ping, under the Ping packet's
--        rules; it exists only for clients that negotiated ext 48
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
-- A MAP CHANGE keeps the connection and throws away the world, and the
-- extension splits along the same line. Negotiation happens once and is
-- not repeated; the Config is not held against any player and survives,
-- which is why this module re-sends it after a map load rather than
-- waiting to be asked (see mod.after.finish_map_load) -- north is the
-- one field a new world is likely to want different. Everything else is
-- per player id and is dropped on both ends: every mark and every ping
-- is gone from every client the moment the new map starts, and from
-- this module's memory too. A server holding standing marks re-sends
-- them itself, from its own finish_map_load. Marks made with
-- teamplay_mark_all are re-sent to a client that has only just
-- negotiated by this module; per-viewer ones are the caller's, through
-- teamplay_listen_ready.
--
-- WHAT THIS DOES NOT DO: anything for clients that don't speak it. A
-- client that does not name ext 48 never gets a packet 112 and never
-- learns there was anything to see. There is no fallback path and there
-- should not be one; a body outline drawn through a wall is not something
-- a server can approximate.
--
-- All of it is the client's to render. The server's whole vocabulary is
-- "this player, this long, for this reason".
local mod = init_mod();
local ffi = require("ffi");
local bit = require("bit");

local EXT_ID = 48;
local EXT_VERSION = 1;

-- Teamplay. The packet id is 64 + the extension id, so 112.
local PKT = 64 + EXT_ID;
local SUB_CONFIG = 0; -- S->C  [PKT][0][features][north x f32][north y f32]
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

-- The fixed part of a Ping, which is also the whole packet when the
-- reason is empty -- the spec writes the size as "24+", and a mark's as
-- "13+". An empty reason is legal in both directions and is not a
-- special case anywhere: outbound it appends nothing, inbound it is what
-- is left of a packet that is exactly this long.
--
-- Only the Ping needs the number, since it is the only sub-packet that
-- arrives; a mark is built a field at a time and never measured. The
-- Message ID is the last fixed byte of both, which is what lets the
-- reason start at a fixed offset no matter what gets added ahead of it.
local PING_FIXED = 24;

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
-- Which way north is: the map-plane components of a vector pointing at
-- it, in the frame every position packet already uses. The base
-- protocol names no orientation at all, so every client that ever drew
-- a compass had to hardcode one, and these two bytes-and-a-bit are what
-- make it the server's to state.
--
-- A vector rather than an angle because an angle needs a convention
-- agreed in advance -- which axis is zero, which way it grows, degrees
-- or radians -- and each of those is a way to disagree without either
-- end noticing. Only the direction is read, so the length is free; it
-- goes out normalised anyway.
--
-- -Y is the top of the map as a minimap draws it, which is what the
-- clients that guessed had already guessed. It is also what a client
-- falls back to when the vector it receives is degenerate, so a server
-- that says nothing here and one that has never heard of north agree.
--
-- Sent whether or not FEAT_COMPASS_HUD is set, so a client handed the
-- bit mid-round already has the direction. Which means the two travel
-- together: change the features alone and the north still has to be the
-- north already given, or every bearing a player has been told turns
-- under them. teamplay_send_config sends both, so that is free here.
getcfg("teamplay_north_x", 0);
getcfg("teamplay_north_y", -1);
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
-- How far from where the server has the pinger a ping may land, in
-- blocks. The spec has the server check a ping against "the player's
-- actual position" and refuse ones that diverge from it; 128 is the fog
-- distance, past which nobody can see anything to ping.
getcfg("teamplay_ping_range", 128);
-- Log every ping and every reason one was refused. For working out why a
-- client's pings are not arriving; noisy, and off unless you are asking.
getcfg("teamplay_ping_debug", false);
-- Longest ping/mark reason accepted or sent, in bytes.
getcfg("teamplay_reason_max", 128);
-- Relay a client's ping to the rest of its team automatically. Listeners
-- see it either way; turn this off to decide distribution yourself.
getcfg("teamplay_relay_pings", true);
-- (Which clients are new enough to be told about extensions at all is
-- lib_ext's ext_min_major/minor/patch, since it is one announcement for
-- every extension and cannot be per-module.)

-- Whether this client and this server have both named ext 48 at version
-- 1. lib_ext holds the agreement -- one table for every extension, keyed
-- by the pid it belongs to and dropped when that pid does -- so there is
-- nothing to keep here beyond asking it.
local function negotiated(pid)
	return ext_supported ~= nil and ext_supported(pid, EXT_ID) ~= nil;
end

-- pid -> when we last accepted a ping from them
local ping_at = pid_connected_table(0);

-- target pid -> {expires=, opts=} for each mark made through
-- teamplay_mark_all, whose audience is everybody -- including whoever
-- has not negotiated yet. The spec has a server keeping +inf marks
-- remember them for players who join later, and one using finite ones
-- re-send an active mark with the time that is left; on_ready does both
-- from here. A mark sent to one viewer is not kept: its audience was
-- that viewer, and a client connecting later is not them.
--
-- Keyed by the TARGET and cleared when the target disconnects: "the
-- server does the same and stops referring to the id" on Player Left,
-- and a mark that outlived its target would land on the next player to
-- be given the id.
local standing = pid_connected_table();

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

-- Where north points when the configured vector says nothing usable,
-- and the same direction the client falls back to on its own.
local NORTH_X, NORTH_Y = 0, -1;

-- North, as two LE float32s, normalised on the way out. The client
-- normalises whatever arrives, so this is not what makes it work -- it
-- is what makes a packet log readable, and it costs one square root per
-- Config.
--
-- Zero length, NaN and infinity are malformed rather than values: the
-- spec has the client substitute (0,-1) and carry on with the rest of
-- the packet, so a bad vector is not worth refusing the whole Config
-- over. Sending the fallback deliberately is the same outcome, arrived
-- at on the end that can still see what was asked for.
--
-- Asked of the components themselves rather than of the length, and
-- scaled by the longer of them before anything is squared. A length is
-- the obvious thing to test and gets two of these wrong: 1e200 squared
-- is an infinity, so a perfectly good north would be called malformed
-- for being written in large numbers, and 1e-200 squared is a zero, so
-- another would be called malformed for small ones. Dividing through by
-- the longer component first puts every direction in the same range, so
-- the length really is free rather than free within the window that
-- survives a square.
local function bad(v)
	return v ~= v or v == math.huge or v == -math.huge;
end

local function put_north(x, y)
	x, y = tonumber(x) or 0, tonumber(y) or 0;

	if (bad(x) or bad(y) or (x == 0 and y == 0)) then
		x, y = NORTH_X, NORTH_Y;
	end

	local big = math.max(math.abs(x), math.abs(y));
	x, y = x/big, y/big;

	local len = math.sqrt(x*x + y*y);

	f32[0], f32[1] = x/len, y/len;
	return ffi.string(f32, 8);
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

-- Handled by lib_ext, and deliberately not here. The server announces
-- everything it supports in ONE ExtensionInfo -- [60][count][(id,
-- version) x count] -- so a module that sent its own would be claiming
-- to be the whole list, and the second extension to load would either
-- contradict the first or swallow the client's reply before it got
-- there. This module says "id 48, version 1" to lib_ext and lib_ext does
-- the talking.
local function send_config(pid)
	send_packet(pid, string.char(PKT, SUB_CONFIG,
		bit.band(teamplay_features, FEATURE_MASK))
		.. put_north(teamplay_north_x, teamplay_north_y));
end

-- Called by lib_ext for every client that turns out to speak ext 48 at
-- version 1. The spec requires a Config once the extension is negotiated,
-- and it is the first thing such a client needs anyway -- until it
-- arrives every feature bit is clear and it may do none of them -- and
-- the ready listeners are told after it, since they send marks and a
-- mark before the client knows what it is allowed to draw is early.
local function on_ready(pid)
	send_config(pid);

	-- Standing marks next, before the listeners: it is the module's own
	-- state and theirs may replace it.
	local now = get_time();
	for target = 0, MAX_PLAYERS-1 do
		local m = standing[target];
		if (m ~= nil) then
			local left = m.expires - now;
			if (left > 0) then
				teamplay_mark(pid, target, left, m.opts);
			else
				standing[target] = nil;
			end
		end
	end

	for lname,fn in pairs(ready_listeners) do
		local ok, err = pcall(fn, pid);
		if (not ok) then
			ready_listeners[lname] = nil;
			log("lib_teamplay: %s crashed on ready, dropped: %s",
				lname, tostring(err));
		end
	end
end

-- A Config belongs to the connection and not to the world, so a map
-- change does not clear it and the client never asks for another. North
-- is the one field the new world is likely to want different, though,
-- so it goes out again once the map has: a server whose maps share a
-- north pays an 11-byte packet per client per map for the guarantee,
-- and one whose maps don't gets a compass that is right afterwards.
--
-- On the tick rather than in the hook, because a server that sets north
-- per map sets it from a finish_map_load hook of its own, and which of
-- two modules' hooks runs first is a question of load order. Deferring
-- by a tick takes the question away: every hook has run by then,
-- whichever order they ran in.
local resend_config = false;

function mod.after.finish_map_load()
	resend_config = true;
end

-- Map Start "clears everything for every id on both ends", and the Map
-- Start goes out from inside finish_map_load (main.c:1030-1043) -- so the
-- standing marks are forgotten before it. Before, not after: a mode that
-- re-marks its carriers from its own finish_map_load hook is marking the
-- new world, and those have to be the ones remembered.
function mod.before.finish_map_load()
	for target = 0, MAX_PLAYERS-1 do
		standing[target] = nil;
	end
end

-- CLEAR_ON_RESPAWN ends a mark on the target's next Create Player. The
-- clients drop it themselves; this drops it from what a joining client
-- would otherwise be sent.
function mod.after.spawn_player(pid)
	local m = standing[pid];
	if (m ~= nil and m.opts.clear_on_respawn) then
		standing[pid] = nil;
	end
end

function mod.after.tick()
	if (resend_config) then
		resend_config = false;
		teamplay_send_config();
	end
end

--========================== CLIENT PINGS ============================--

-- The spec has the server identify the target of a ping itself rather
-- than take the client's word for it: the coordinates are there so the
-- two ends can be checked against each other, and the server raycasts
-- from the pinger through their crosshair to confirm line of sight.
--
-- So: the point has to be within sight range of where the server has
-- the pinger, lie along their aim, have a clear line to it, and have
-- something there to ping. A point behind the pinger, through a wall or
-- in mid-air is a desynced client at best and a client pinging what it
-- cannot see at worst, and the two are not worth telling apart --
-- neither is a ping.

-- Is a living player standing at pos? The one thing a ping may name that
-- the voxel raycast cannot see: a body is not a block, and a ping on an
-- enemy in the open has no wall behind it within reach. Position is the
-- head and z grows downwards, so a body runs from a little above it to
-- about three blocks below; a block either side covers its width.
local function body_at(pos)
	for i in piditer(PID_BROADCAST) do
		local ok, alive = pcall(is_alive, i);
		if (ok and alive) then
			local p = get_position(i);
			if (math.abs(p.x - pos.x) <= 1 and math.abs(p.y - pos.y) <= 1
			    and pos.z >= p.z - 1 and pos.z <= p.z + 3) then
				return true;
			end
		end
	end
	return false;
end

local function ping_is_sane(pid, pos)
	local eye = get_position(pid);
	local dir = get_orientation(pid);
	local dx, dy, dz = pos.x - eye.x, pos.y - eye.y, pos.z - eye.z;
	local reach = math.sqrt(dx*dx + dy*dy + dz*dz);
	local aim = math.sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z);

	-- The spec's "the player's actual position": a point further from
	-- where the server has them than anybody can see has diverged from
	-- it, whatever direction it is in.
	if (reach > teamplay_ping_range) then
		if (teamplay_ping_debug) then
			log("lib_teamplay: ping #%d refused, out of range: %.1f > %.1f",
				pid, reach, teamplay_ping_range);
		end
		return false;
	end

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
	-- Distances, not voxel identity: asking whether the hit voxel is the
	-- voxel the ping is in refuses honest pings from half the compass. A
	-- ping lands on a *surface*, and a surface coordinate does not floor
	-- to the voxel behind it -- enter a block from the far side and the
	-- intersection is exactly on the next voxel's boundary, and a client
	-- that nudges its marker off the wall to keep it from z-fighting
	-- misses by a whole block every time.
	--
	-- Linear, not squared, because the slack is a distance in blocks and
	-- has to stay one at any range: a squared tolerance that is generous
	-- up close is nothing at all fifty blocks out.
	local hit = raycast(eye, pos, false);
	if (hit ~= nil) then
		local hd = math.sqrt((hit.x-eye.x)^2 + (hit.y-eye.y)^2
			+ (hit.z-eye.z)^2);

		if (hd < reach - teamplay_ping_los_slack) then
			if (teamplay_ping_debug) then
				log("lib_teamplay: ping #%d refused, wall in the way: solid"
					.. " at %.1f but the ping is %.1f away (slack %.1f)",
					pid, hd, reach, teamplay_ping_los_slack);
			end
			return false;
		end

		return true;
	end

	-- A clear line all the way to the point only says nothing is in the
	-- way. The spec's raycast is also how the server identifies what was
	-- pinged, and a point the line reaches without meeting anything is a
	-- point in the air -- unless something stands just past it. So carry
	-- the same line on by the slack: a surface there is the target, and
	-- so is a player's body, which the voxels do not show.
	if (reach > 0.001) then
		local k = (reach + teamplay_ping_los_slack) / reach;
		local far = {x = eye.x + dx*k, y = eye.y + dy*k, z = eye.z + dz*k};

		if (raycast(eye, far, false) == nil and not body_at(pos)) then
			if (teamplay_ping_debug) then
				log("lib_teamplay: ping #%d refused, nothing there:"
					.. " %.1f,%.1f,%.1f is open air", pid, pos.x, pos.y, pos.z);
			end
			return false;
		end
	end

	return true;
end

-- Why a ping request was refused, as said back to a /pingmark user. A
-- client that sent the packet is told nothing -- the spec gives the
-- packet no answer -- so these only ever reach chat.
local REFUSED = {
	off = {en = "Pinging is turned off on this server."},
	dead = {en = "You cannot ping while dead."},
	soon = {en = "Too soon: wait a moment before pinging again."},
	map = {en = "That position is off the map."},
	sight = {en = "You can only ping what you are looking at."},
};

-- A client's request for a ping, from the packet or from /pingmark --
-- the spec has the command follow the packet's rules exactly, so they
-- share this. Returns nil once the ping is accepted and relayed, or the
-- key into REFUSED saying why it was not.
local function request_ping(pid, pos, raw_reason)
	-- FEAT_PING is permission to send, and the only bit that bears on a
	-- ping arriving. The client is told not to send these without it, and
	-- the spec has us ignore any that turn up regardless.
	--
	-- A client that never negotiated was never sent a Config, so it was
	-- never given the bit either: its pings are ignored the same way.
	if (bit.band(teamplay_features, FEAT_PING) == 0 or not negotiated(pid)) then
		return "off";
	end

	-- A dead player does not ping: the client is told not to send one and
	-- the server drops any that turn up regardless. Whether a spectator
	-- may is the server's to decide, and is_alive settles both questions
	-- at once -- SPECTATORs are not alive (lua_playerget:8), so the answer
	-- here is no.
	if (not is_alive(pid)) then
		return "dead";
	end

	local now = get_time();
	if (now - ping_at[pid] < teamplay_ping_interval) then
		return "soon";
	end

	-- the originating id is the sender's to claim and ours to ignore
	-- (pid is who actually sent it), and so are the duration, the
	-- surfaces and the colour: how long a ping is worth, where it is shown
	-- and what it is drawn in are all decided on the relay, not by
	-- whoever asked for it -- and never a reason to refuse it.
	if (pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z) then
		return "map"; -- NaN
	end
	-- The map is 512 x 512 x 64, edges included: a ping lands on a face,
	-- and the outer faces of the last voxels sit exactly on the bounds.
	if (pos.x < 0 or pos.x > 512 or pos.y < 0 or pos.y > 512
	    or pos.z < 0 or pos.z > 64) then
		return "map";
	end
	if (not ping_is_sane(pid, pos)) then
		return "sight";
	end

	local reason = clean_reason(raw_reason);

	ping_at[pid] = now;

	-- the pinger's own team, which includes the pinger: a player sees the
	-- marker they just placed, the same as everyone they placed it for
	if (teamplay_relay_pings) then
		local sent = 0;

		for i in piditer(PID_BROADCAST_TEAM(get_team(pid))) do
			if (negotiated(i) and teamplay_ping(i, pos, {
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

	return nil;
end

local function on_ping(pid, data)
	if (teamplay_ping_debug) then
		log("lib_teamplay: ping from #%d, %d bytes, msgid %s",
			pid, #data, tostring(string.byte(data, PING_FIXED)));
	end

	-- exactly PING_FIXED is a ping with no reason, which is allowed;
	-- shorter than that is a truncated packet, which is not.
	if (#data < PING_FIXED) then
		if (teamplay_ping_debug) then
			log("lib_teamplay: ping #%d refused: %d bytes (want >=%d)",
				pid, #data, PING_FIXED);
		end
		return;
	end

	-- The Message ID is read here and acted on nowhere: reserved and
	-- unimplemented, so a receiver that gets a non-zero one renders the
	-- packet anyway and ignores the byte. Dropping over it would be the
	-- wrong instinct -- the byte exists for a version that names labels
	-- out of a table, and refusing what we cannot yet read would make
	-- that version a break rather than an addition.
	local why = request_ping(pid, get_f32x3(data, 4),
		string.sub(data, PING_FIXED + 1));

	if (why ~= nil and teamplay_ping_debug) then
		log("lib_teamplay: ping #%d refused: %s", pid, REFUSED[why].en);
	end
end

--============================ /PINGMARK =============================--

-- "/pingmark <x> <y> <z> [reason...]": a ping asked for in chat, so one
-- can come from a key bind or a Pie Menu slice (its %h is the point under
-- the crosshair). The spec has it follow the Ping packet's rules
-- exactly -- request_ping -- and answer in chat whenever it refuses.
--
-- A number here is what the spec says it is: base 10, `.` for the
-- decimal point. Narrower than tonumber, which would also take hex,
-- exponents and padding nobody's %h produces.
local function decimal(s)
	if (s == nil) then
		return nil;
	end
	if (string.find(s, "^[-+]?%d+%.?%d*$") or string.find(s, "^[-+]?%.%d+$")) then
		return tonumber(s);
	end
	return nil;
end

-- What commands.lua says to a command it does not know. The command
-- exists only for players whose client negotiated the extension, and for
-- anybody else it is to look exactly like one that does not exist.
local UNKNOWN_CMD = {en = "Unknown command"};
local BAD_POSITION = {en = "Nothing to ping: /pingmark needs a position,"
	.. " three numbers, before the reason."};

local pingmark = {name = "pingmark", usage = "<x> <y> <z> [reason...]",
	desc = "Ping a position for your team."};

function pingmark.func(pid, argv)
	if (not negotiated(pid)) then
		l10n_send_chat(pid, UNKNOWN_CMD);
		return;
	end

	-- "when the line does not start with three numbers, as when a slice's
	-- %h met nothing" -- which is the commonest refusal, so it says what
	-- was missing rather than only printing the usage
	local x, y, z = decimal(argv[1]), decimal(argv[2]), decimal(argv[3]);
	if (x == nil or y == nil or z == nil) then
		send_usage(pid, pingmark);
		l10n_send_chat(pid, BAD_POSITION);
		return;
	end

	-- The rest of the line, read the way commands.lua reads any argument:
	-- split on whitespace and unquoted, then put back with one space.
	local words = {};
	for i = 4, #argv do
		words[#words+1] = argv[i];
	end

	local why = request_ping(pid, {x = x, y = y, z = z},
		table.concat(words, " "));
	if (why ~= nil) then
		l10n_send_chat(pid, REFUSED[why]);
	end
end

-- commands.lua is stock and loaded first, but a server stripped of it
-- has no commands at all rather than a reason to fail to load this
if (register_command ~= nil) then
	register_command(pingmark, mod);
end

-- Kept out of /commands for the players it does not exist for, for the
-- same reason it answers them "Unknown command".
function mod.can_see_command(pid, cmd)
	if (cmd == pingmark and not negotiated(pid)) then
		return false;
	end
	return mod.next.can_see_command(pid, cmd);
end

--============================= INTAKE ===============================--
-- Packet 112 is unknown to the core, which would log it as "Unknown
-- packet ID" crap (funcs_packetrecv.c:483). Returning 0 hands it to
-- on_sane_packet instead, whose switch has no default case, so it is
-- silently dropped there having already been dealt with here.
function mod.on_any_packet(pid, data)
	local id = string.byte(data, 1);

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
	return negotiated(pid);
end

-- Outline `target` on `viewer`'s screen. secs 0 clears it,
-- TEAMPLAY_FOREVER leaves it until something else does.
function teamplay_mark(viewer, target, secs, opts)
	if (not negotiated(viewer)) then
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
		-- further", and the spec reserves no value for it -- black is
		-- black -- so it is spelled out: the target's own team colour
		.. put_color(opts.color or team_color_of(target))
		.. string.char(MSG_ID_NONE)
		.. clean_reason(opts.reason));
	return true;
end

function teamplay_mark_all(target, secs, opts)
	secs = secs or 0;
	if (put_duration(secs) == nil) then
		return;
	end

	-- remembered for whoever negotiates later -- see `standing`. A copy
	-- of the options, so a caller reusing its table cannot change a mark
	-- that is already out.
	if (standing[target] ~= nil or (secs > 0 and target >= 0
	    and target < MAX_PLAYERS)) then
		if (secs == 0) then
			standing[target] = nil;
		else
			local copy = {};
			for k,v in pairs(opts or {}) do
				copy[k] = v;
			end
			standing[target] = {expires = get_time() + secs, opts = copy};
		end
	end

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
	if (not negotiated(viewer)) then
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

-- Re-announce the feature bitmask and north to everybody who has
-- negotiated. The server may send Config whenever it likes and the
-- client applies each one immediately and in full, which is how a policy
-- change lands mid-session -- turning pings off for a map that plays
-- badly with them, say, or turning a world a quarter turn. Set
-- teamplay_features or teamplay_north_x/y, then call this; without the
-- call the new values only reach clients that negotiate afterwards.
--
-- Both fields go every time because the packet carries both: there is no
-- Config that changes the features and leaves north alone, so a caller
-- touching one still has to mean the other. Which is the argument for
-- keeping north in the globals rather than passing it here -- whatever
-- is in them is what every Config says, including the ones this module
-- sends on its own after a map load and on negotiation.
function teamplay_send_config()
	for i in piditer(PID_BROADCAST) do
		if (negotiated(i)) then
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

-- Registering does not re-announce: negotiation happens once per
-- connection. On a reload lib_ext keeps what each client agreed with the
-- last copy of this module and runs on_ready again for them, which sends
-- the Config this copy owes them.
function mod.on_load()
	if (ext_register == nil) then
		error("lib_teamplay needs lib_ext loaded first "
			.."(its script pulls lib_ext in; check with: lsdctl status)", 0);
	end

	ext_register("lib_teamplay", EXT_ID, EXT_VERSION, on_ready, "Teamplay");
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
-- The list is exhaustive on purpose: a name added to the API above and
-- forgotten here outlives its own module, and goes on answering for it.
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
};

function mod.on_unload()
	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end

	listeners = {};
	ready_listeners = {};

	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
