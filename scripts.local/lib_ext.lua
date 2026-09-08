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
--   ext_register(name, id, version, ready)
--        declare that this server speaks extension `id` at `version`.
--        `ready` is called as ready(pid) for each client that turns out
--        to speak the same extension at the same version -- the moment
--        to send that extension's opening packets, and the only honest
--        one: negotiation finishes well after on_join, so anything sent
--        at join time is sent before the client has agreed to hear it
--   ext_unregister(id)         stop announcing it (on module unload)
--   ext_supported(pid, id)     -> version, or nil. True only when both
--                                 ends named the extension at the same
--                                 version -- there is no negotiating
--                                 down, see below
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

-- id -> {name=, version=, ready=}. What this server speaks.
local registry = {};
-- pid -> {id -> version}. What the client said it speaks. Cleared on
-- disconnect, because the next occupant of that slot has agreed to
-- nothing -- ids are recycled and an inherited agreement is a client
-- being sent packets it never asked for and cannot parse.
local agreed = pid_connected_table();

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

function mod.after.on_version(pid, idChar, major, minor, patch, msg)
	if (new_enough(major, minor, patch)) then
		ext_announce(pid);
	end
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

function ext_register(name, id, version, ready)
	if (type(name) ~= "string" or type(id) ~= "number"
	    or type(version) ~= "number") then
		error("ext_register: name, id and version required", 2);
	end

	registry[id] = {name = name, version = version, ready = ready};

	-- The list we already announced is now short by one. Re-announcing
	-- is what makes a hot load work at all: every connected client was
	-- told a list that did not have this extension in it, and none of
	-- them will ask again on their own.
	for i in piditer(PID_BROADCAST) do
		if (get_client_char(i) ~= nil) then
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

function mod.on_unload()
	-- see lib_teamplay's EXPORTS for why this is not optional: consumers
	-- test these names to find out whether negotiation is available, and
	-- a name left standing answers yes for a module that is gone
	ext_register = nil;
	ext_unregister = nil;
	ext_supported = nil;
	ext_announce = nil;
end

return mod;
