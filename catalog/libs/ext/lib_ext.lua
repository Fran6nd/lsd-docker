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
--   ext_disable(id) / ext_enable(id)
--        stop or resume OFFERING an extension. The module stays
--        loaded; the id is left out of the announcement, nobody can
--        agree to it, and ext_supported answers no for everybody --
--        including clients that agreed before it was disabled
--   ext_is_disabled(id)        -> is it being withheld
--   ext_announce(pid)          send the list to one client. Low level:
--                                 it is sent once per connection by
--                                 this module, and a second one is a
--                                 renegotiation the spec rules out
--
-- VERSIONS ARE MATCHED, NOT NEGOTIATED. The spec says nothing about
-- resolving a mismatch, and guessing is worse than declining: a client
-- announcing version 2 of something we speak at version 1 is telling us
-- about a packet format we have never seen, and the failure mode of
-- assuming otherwise is malformed packets on a live connection. So an
-- exact match counts and nothing else does. When a version 2 of some
-- extension exists, whoever writes it registers both and picks.
--
-- NEGOTIATION HAPPENS ONCE PER CONNECTION. The spec is explicit: one
-- ExtInfo each way covers the whole connection, Map Start does not
-- re-run it "and neither side should expect it to". So the list goes out
-- once, the client's first reply is the one that counts, and nothing
-- here -- a map change, an extension hot-loaded or switched on later --
-- sends it again. The cost is that an extension loaded or enabled while
-- a client is connected only reaches clients that connect afterwards;
-- a client that cannot be expected to handle a second ExtInfo is the
-- alternative, and it is the worse one.
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

-- id -> true for an extension this server speaks but will not offer.
-- Disabling is not unregistering: the module stays loaded and its code
-- stays live, it is simply left out of the announcement, so no client
-- can agree to it and every ext_supported about it answers no. That is
-- what makes it switchable from a settings file -- unregistering would
-- mean unloading a module.
--
-- A global for the same reason the registry is: it has to survive a
-- reload of this module, or disabling something would quietly undo
-- itself the next time lib_ext was loaded.
ext_disabled = ext_disabled or {};
local disabled = ext_disabled;
-- pid -> {id -> version}. What the client said it speaks. Cleared on
-- disconnect, because the next occupant of that slot has agreed to
-- nothing -- ids are recycled and an inherited agreement is a client
-- being sent packets it never asked for and cannot parse.
--
-- A global, like the registry, and now for a harder reason: negotiation
-- happens once per connection, so an agreement this module forgot on a
-- reload could never be made again. pid_tables keeps clearing it on
-- disconnect -- it holds the table weakly, and this name holds it.
ext_agreed = ext_agreed or pid_connected_table();
local agreed = ext_agreed;
-- pid -> true once the list has gone out to them, so a client that
-- reports its version twice -- or by both of the two routes below -- is
-- announced to once -- once per connection being what the spec asks.
local announced = pid_connected_table(false);
-- pid -> {id -> true}: what we actually offered them, the half of
-- "mutually supported" that is ours. A client may list extensions we
-- never offered -- the spec lets it reply with everything it speaks --
-- and one we registered after announcing, or had disabled at the time,
-- was not part of this connection's negotiation, so naming it back does
-- not make it agreed.
-- A global for the same reason as ext_agreed.
ext_offered = ext_offered or pid_connected_table();
local offered = ext_offered;
-- ready(pid) calls owed to a re-registered extension, run on the next
-- tick; see ext_register.
local pending_ready = {};

--=========================== THE WIRE ===============================--

-- [60][count][(id, version) x count]. Ids in ascending order: nothing
-- requires it, but a stable list makes two announcements to the same
-- client comparable by eye in a packet log.
local function build_list()
	local ids = {};
	local set = {};

	for id in pairs(registry) do
		if (not disabled[id]) then
			ids[#ids+1] = id;
			set[id] = true;
		end
	end
	table.sort(ids);

	local out = {string.char(PKT_EXTINFO, #ids)};
	for _,id in ipairs(ids) do
		out[#out+1] = string.char(id, registry[id].version);
	end

	return table.concat(out), #ids, set;
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
	local list, n, set = build_list();

	-- "we support nothing" is a legal packet and a pointless one: it
	-- tells the client only that we speak the negotiation itself, and
	-- invites a reply we have no use for
	if (n == 0) then
		return false;
	end

	offered[pid] = set;
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

-- Both ends named `id` at the version we speak, we offered it to this
-- client, and it is not withheld. ext_supported is this, exported.
local function agrees(pid, id)
	local reg = registry[id];
	local seen = agreed[pid];
	local ours = offered[pid];

	-- A disabled extension is not supported by anybody, including a
	-- client that agreed to it before it was disabled. Otherwise
	-- disabling would only stop new clients using it and leave the ones
	-- already here being sent packets the server has decided not to
	-- speak.
	if (disabled[id]) then
		return nil;
	end

	if (reg == nil or seen == nil or ours == nil or not ours[id]
	    or seen[id] ~= reg.version) then
		return nil;
	end
	return reg.version;
end

-- Hand a client to one extension's ready callback. A ready callback is
-- other people's code sending its own packets, so one that throws is
-- dropped rather than left to take down every later extension's opening
-- packets with it.
local function run_ready(pid, id, reg)
	if (reg.ready == nil) then
		return;
	end

	local ok, err = pcall(reg.ready, pid);
	if (not ok) then
		reg.ready = nil;
		log("lib_ext: %s crashed on ready for #%d, dropped: %s",
			reg.name, pid, tostring(err));
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

	-- Once per connection: the first well-formed reply settles it. A
	-- second one is a renegotiation the spec rules out, and honouring it
	-- would re-run every ready callback -- a second Config, a second Sky,
	-- whatever opening packets each extension sends -- on the client's
	-- say-so.
	if (agreed[pid] ~= nil) then
		return;
	end

	-- A reply to nothing. The client answers our list; one that sends its
	-- own before we have sent ours has not been asked yet, and gets asked
	-- -- once -- when its version comes in.
	if (offered[pid] == nil) then
		return;
	end

	local seen = {};
	for i = 0, n-1 do
		seen[string.byte(data, 3 + i*2)] = string.byte(data, 4 + i*2);
	end
	agreed[pid] = seen;

	-- Tell each extension that agrees with this client.
	for id,reg in pairs(registry) do
		if (agrees(pid, id) ~= nil) then
			run_ready(pid, id, reg);
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

	-- No re-announcement: negotiation happens once per connection (see
	-- the header). A client already connected was offered the list as it
	-- stood, and an extension registered for the first time since is
	-- simply not part of its connection.
	--
	-- A module RELOADED is different. Its id was in the list, the client
	-- agreed to it, and that agreement still stands -- but the new copy
	-- of the module has no record of having sent its opening packets, so
	-- it is handed every client that agreed, exactly as at negotiation.
	-- On the next tick rather than now, because this is called from the
	-- module's own on_load and the rest of that may not have run yet.
	if (ready ~= nil) then
		for i in piditer(PID_BROADCAST) do
			if (agrees(i, id) ~= nil) then
				pending_ready[#pending_ready+1] = {pid = i, id = id};
			end
		end
	end
end

function mod.after.tick()
	if (#pending_ready == 0) then
		return;
	end

	local due = pending_ready;
	pending_ready = {};

	for _,p in ipairs(due) do
		local reg = registry[p.id];
		-- still registered, still agreed: neither an unload nor a
		-- disconnect in between leaves anything to tell
		if (reg ~= nil and agrees(p.pid, p.id) ~= nil) then
			run_ready(p.pid, p.id, reg);
		end
	end
end

function ext_unregister(id)
	registry[id] = nil;
end

-- The version both ends agreed on, or nil. Registration is half the
-- answer: an extension this server has stopped announcing is not
-- supported however recently a client said it spoke it. So is having
-- offered it to this client at all -- see `offered`.
function ext_supported(pid, id)
	return agrees(pid, id);
end

-- Stop offering an extension, or start again. Not re-announced, since
-- negotiation happens once per connection: disabling takes effect for
-- everybody at once, through ext_supported, and enabling reaches the
-- clients that connect afterwards plus any already here that were
-- offered it before it was disabled and agreed.
local function set_disabled(id, off)
	if (type(id) ~= "number") then
		error("ext_disable/ext_enable: id must be a number", 3);
	end

	if ((disabled[id] and true or false) == off) then
		return false; -- already so
	end

	disabled[id] = off or nil;

	return true;
end

function ext_disable(id)
	return set_disabled(id, true);
end

function ext_enable(id)
	return set_disabled(id, false);
end

function ext_is_disabled(id)
	return disabled[id] and true or false;
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

-- The registry and the agreements survive a reload of this module; the
-- announced set is a fresh pid table. So rebuild it from what the core
-- itself remembers about each client: an id char means it answered with
-- a VersionResponse, ext-supported means it answered with an extended
-- version block. Either way we have already told it the list, and
-- telling it again would be the renegotiation the spec rules out.
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
	ext_disable = nil;
	ext_enable = nil;
	ext_is_disabled = nil;
	ext_replied = nil;
	ext_each = nil;
	ext_announce = nil;
end

return mod;
