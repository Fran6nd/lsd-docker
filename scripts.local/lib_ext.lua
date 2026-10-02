-- lib_ext.lua -- ExtensionInfo negotiation, shared by every extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- One place that speaks packet 60, because the protocol only has room
-- for one. The server announces what it supports in a SINGLE
-- ExtensionInfo listing every extension at once -- [60][count][(id,
-- version) x count] -- and a module that sends its own would either be
-- the whole list or contradict it. So no module sends that packet;
-- they register here and this sends one list for all of them.
--
-- It owns the inbound half for the same reason. The client answers with
-- its own list, and every extension needs to read the same reply, which
-- cannot happen if the first module to see packet 60 swallows it.
--
-- API (globals):
--   ext_register(name, id, version, ready, title)
--        declare that this server speaks extension `id` at `version`.
--        `ready` is called as ready(pid) for each client that turns out
--        to speak the same extension at the same version -- the moment
--        to send that extension's opening packets, and the only honest
--        one: a client agrees somewhere around the time it finishes
--        loading the map, which may be either side of the moment the
--        player picks a team, so join time is not a safe place to send.
--        `title` is the extension's name in the specification, e.g.
--        "Flashlight" -- what a player is told when it is missing, as
--        against `name`, which is the module and is for the log
--   ext_unregister(id)         stop announcing it (on module unload)
--   ext_supported(pid, id)     -> version, or nil. True only when both
--                                 ends named the extension at the same
--                                 version -- there is no negotiating
--                                 down, see below
--   ext_replied(pid)           -> has this client sent its list at all.
--                                 The difference between "supports
--                                 nothing" and "has not answered yet",
--                                 which ext_supported cannot show you
--                                 because both are nil
--   ext_each(fn)               fn(id, reg) over everything registered,
--                                 reg being {name=, version=,
--                                 ready=, title=}
--   ext_announce(pid)          re-send the list to one client
--
-- VERSIONS ARE MATCHED, NOT NEGOTIATED. The spec says nothing about
-- resolving a mismatch, and guessing is worse than declining: a client
-- announcing version 2 of something we speak at version 1 is telling us
-- about a packet format we have never seen, and the failure mode of
-- assuming otherwise is malformed packets on a live connection. So an
-- exact match counts and nothing else does. When a version 2 of some
-- extension exists, whoever writes it registers both and picks.
local mod = init_mod();

-- ExtensionInfo. Declared in protocol.h:640-654 and PacketTypeExtensionInfo
-- at :804, but nothing in funcs_packetrecv.c, funcs_send.c, main.c or
-- lua.c ever touches it -- the whole negotiation is unclaimed by the
-- core and this module owns it end to end.
local PKT_EXTINFO = 60;

-- Announce only to clients newer than this. The spec says to send the
-- list "after the Version Info response has been received to compatible
-- clients (OpenSpades versions > 0.1.3)"; older ones are not known to
-- handle packet 60 gracefully and nothing is lost by staying quiet.
getcfg("ext_min_major", 0);
getcfg("ext_min_minor", 1);
getcfg("ext_min_patch", 3);

-- id -> {name=, version=, ready=, title=}. What this server speaks.
--
-- Kept in a global, and that is deliberate rather than sloppy: a module
-- local would be a fresh empty table every time THIS module reloaded,
-- and every extension already loaded would silently stop being
-- announced -- they registered once, at their own load, and nothing
-- would ever ask them again. So `lsdctl load lib_ext` would quietly
-- strip the server of every extension but the ones reloaded after it.
--
-- Surviving the reload is what makes lib_ext safe to reload on its own,
-- which is the whole point of centralising the negotiation here.
-- ext_unregister keeps it honest as modules come and go.
ext_registry = ext_registry or {};
local registry = ext_registry;
-- pid -> {id -> version}. What the client said it speaks. Cleared on
-- disconnect, because the next occupant of that slot has agreed to
-- nothing -- ids are recycled and an inherited agreement is a client
-- being sent packets it never asked for and cannot parse.
local agreed = pid_connected_table();
-- pid -> true once the list has gone out to them, so a client that
-- reports its version twice -- or by both of the two routes below -- is
-- announced to once. Also the set ext_register re-announces to on a hot
-- load: "everyone who has told us what they are".
local announced = pid_connected_table(false);

--=========================== THE WIRE ===============================--

-- [60][count][(id, version) x count]. Ids in ascending order: nothing
-- requires it, but a stable list makes two announcements to the same
-- client comparable by eye in a packet log.
local function build_list()
	local ids = {};

	for id in pairs(registry) do
		ids[#ids+1] = id;
	end
	table.sort(ids);

	local out = {string.char(PKT_EXTINFO, #ids)};
	for _,id in ipairs(ids) do
		out[#out+1] = string.char(id, registry[id].version);
	end

	return table.concat(out), #ids;
end

-- Is this client new enough to be told? Strictly greater than the
-- configured version, which is what "versions > 0.1.3" asks for.
local function new_enough(major, minor, patch)
	if (major ~= ext_min_major) then
		return major > ext_min_major;
	end
	if (minor ~= ext_min_minor) then
		return minor > ext_min_minor;
	end
	return patch > ext_min_patch;
end

function ext_announce(pid)
	local list, n = build_list();

	-- "we support nothing" is a legal packet and a pointless one: it
	-- tells the client only that we speak the negotiation itself, and
	-- invites a reply we have no use for
	if (n == 0) then
		return false;
	end

	send_packet(pid, list);
	return true;
end

--========================== NEGOTIATION =============================--

-- A CLIENT CAN REPORT ITSELF TWO WAYS, and both of them have to land
-- here or the negotiation is not centralised at all -- it is centralised
-- for the clients that happen to use the route we hooked.
--
--   on_version      the VersionResponse packet (funcs_packetrecv.c:611),
--                   which is what most clients answer
--                   demand_fingerprint with
--   on_version_ext  a specially formed ExistingPlayer carrying an
--                   extended version block (funcs_packetrecv.c:525-547),
--                   which the apidoc describes as "called by very few
--                   clients (mostly OpenSpades v0.1.5) in response to
--                   demand_fingerprint()" -- the same demand, a
--                   different answer
--
-- Hooking only the first is a client that supports every extension we
-- have, never being told any of them exist, and looking from here
-- exactly like a client that supports none. Harmless while a missing
-- extension costs nothing; a permanent spectator sentence the moment one
-- is required (lib_ext_policy). So: both.
local function announce_once(pid)
	if (announced[pid]) then
		return;
	end

	announced[pid] = true;
	ext_announce(pid);
end

function mod.after.on_version(pid, idChar, major, minor, patch, msg)
	if (new_enough(major, minor, patch)) then
		announce_once(pid);
	end
end

-- No version gate on this route, and that asymmetry is the point. The
-- gate exists because clients older than 0.1.3 "are not known to handle
-- packet 60 gracefully" -- but a client that answered with an extended
-- version block has demonstrably implemented a protocol extension of
-- its own, so it is not one of those, whatever numbers it reports. The
-- apidoc warns the ext version and the standard version need not agree
-- and that the standard one may be spoofed, which makes those numbers
-- the wrong thing to gate on anyway.
--
-- And the cost of being wrong is lopsided: gate it and a modern client
-- is locked out of a server with a required extension; do not, and at
-- worst a client that asked for extensions receives a list of them.
function mod.after.on_version_ext(pid, major, minor, patch, flags, cli, lang)
	announce_once(pid);
end

-- Their half. An extension is mutually supported once both sides have
-- named it at the same version; ours went out above, so their list
-- settles every extension at once.
local function on_extinfo(pid, data)
	local n = string.byte(data, 2);

	if (n == nil or #data ~= 2 + 2*n) then
		return;
	end

	local seen = {};
	for i = 0, n-1 do
		seen[string.byte(data, 3 + i*2)] = string.byte(data, 4 + i*2);
	end
	agreed[pid] = seen;

	-- Tell each extension that agrees with this client. A ready callback
	-- is other people's code sending its own packets, so one that throws
	-- is dropped rather than left to take down every later extension's
	-- opening packets with it.
	for id,reg in pairs(registry) do
		if (seen[id] == reg.version and reg.ready ~= nil) then
			local ok, err = pcall(reg.ready, pid);
			if (not ok) then
				reg.ready = nil;
				log("lib_ext: %s crashed on ready for #%d, dropped: %s",
					reg.name, pid, tostring(err));
			end
		end
	end
end

-- Packet 60 is unknown to the core, which would log it as "Unknown
-- packet ID" crap (funcs_packetrecv.c:485). Returning 0 hands it to
-- on_sane_packet instead, whose switch has no default case, so it is
-- silently dropped there having already been dealt with here.
function mod.on_any_packet(pid, data)
	if (string.byte(data, 1) == PKT_EXTINFO) then
		on_extinfo(pid, data);
		return 0;
	end

	return mod.next.on_any_packet(pid, data);
end

--============================== API =================================--

function ext_register(name, id, version, ready, title)
	if (type(name) ~= "string" or type(id) ~= "number"
	    or type(version) ~= "number") then
		error("ext_register: name, id and version required", 2);
	end

	registry[id] = {name = name, version = version, ready = ready,
		title = title or name};

	-- The list we already announced is now short by one. Re-announcing
	-- is what makes a hot load work at all: every connected client was
	-- told a list that did not have this extension in it, and none of
	-- them will ask again on their own.
	--
	-- To everyone we have announced to, which is not the same as
	-- everyone get_client_char answers for: that is nil for a client
	-- that reported itself through on_version_ext instead, and skipping
	-- those would hot-load an extension that one half of the server
	-- never hears about.
	for i in piditer(PID_BROADCAST) do
		if (announced[i]) then
			ext_announce(i);
		end
	end
end

function ext_unregister(id)
	registry[id] = nil;
end

-- The version both ends agreed on, or nil. Registration is half the
-- answer: an extension this server has stopped announcing is not
-- supported however recently a client said it spoke it.
function ext_supported(pid, id)
	local reg = registry[id];
	local seen = agreed[pid];

	if (reg == nil or seen == nil or seen[id] ~= reg.version) then
		return nil;
	end
	return reg.version;
end

-- Has this client answered the announcement at all? ext_supported says
-- nil both for a client that listed its extensions and did not name
-- this one, and for a client that has not got round to listing them --
-- and those are different facts. The first is an answer, the second is
-- silence, and anything deciding what to DO about a missing extension
-- has to wait out the silence before it calls it an answer.
--
-- A client that supports nothing still replies, with a count of zero,
-- and that reply is an answer: `agreed[pid]` becomes an empty table,
-- which is not nil. The ones that never reply are the old clients that
-- are never announced to in the first place, and the ones that do not
-- speak packet 60 and drop it unread.
function ext_replied(pid)
	return agreed[pid] ~= nil;
end

-- Everything this server speaks, for whoever needs to name it rather
-- than merely ask about it. Second argument is the registry entry, and
-- it is the live table -- read it, do not keep it.
function ext_each(fn)
	for id,reg in pairs(registry) do
		fn(id, reg);
	end
end

-- The registry survives a reload of this module; the per-client
-- bookkeeping cannot, since pid tables are made fresh. So rebuild the
-- announced set from what the core itself remembers about each client:
-- an id char means it answered with a VersionResponse, ext-supported
-- means it answered with an extended version block. Either way we have
-- already told it the list, and either way ext_register must reach it
-- when a new extension hot-loads.
function mod.on_load()
	for i in piditer(PID_BROADCAST) do
		local ok_char, char = pcall(get_client_char, i);
		local ok_ext, ext = pcall(get_client_ext_supported, i);

		if ((ok_char and char ~= nil) or (ok_ext and ext)) then
			announced[i] = true;
		end
	end
end

-- ext_registry is deliberately NOT cleared here. It is what lets this
-- module be reloaded without every already-loaded extension falling
-- silently out of the announcement, and a module that is going away for
-- good leaves behind a table nothing reads.
function mod.on_unload()
	-- see lib_teamplay's EXPORTS for why this is not optional: consumers
	-- test these names to find out whether negotiation is available, and
	-- a name left standing answers yes for a module that is gone
	ext_register = nil;
	ext_unregister = nil;
	ext_supported = nil;
	ext_replied = nil;
	ext_each = nil;
	ext_announce = nil;
end

return mod;
