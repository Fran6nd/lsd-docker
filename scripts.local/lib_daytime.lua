-- lib_daytime.lua -- The Daytime and Weather protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Daytime and Weather extension (id 0x33, version
-- 1): the server says whether it is day or night, and the client draws
-- the dark.
--
-- ONE SUB-PACKET, Sky, Server to Client:
--   [0x73][0][Time u16][Reserved u16][Weather u16]   -- eight bytes
--
--   Time      0 is night, anything else is day
--   Reserved  must be 0
--   Weather   two bytes, unimplemented in version 1, must be 0
--
-- IT IS A SWITCH, NOT A CLOCK. Version 1 has no time of day that
-- passes: Time is day or night and nothing in between. The Reserved
-- field is where a later version puts the speed, with Time becoming
-- minutes since midnight -- the spec leaves that out of v1 because
-- moving the sun, and the shadows with it, is still too costly for
-- clients to draw. So there is no hour here, no sun to place and no
-- curve to evaluate, and this module is smaller than it looks like it
-- ought to be.
--
-- WHAT NIGHT IS, which is the client's half: full darkness. The sun
-- casts no light and no shadow, nothing else lights the world, and the
-- fog and sky are black. Not dimmed -- black. By day the client draws
-- the world exactly as it does without this extension.
--
-- SO A FLASHLIGHT IS THE ONLY LIGHT THERE IS, and it burns as brightly
-- as by day. That is the whole reason these two extensions are worth
-- having together: at night lib_flashlight is not decoration, it is the
-- only way anybody sees anything at all.
--
-- Which also means the server has nothing to say about the night sky.
-- The client blacks it out on its own and never consults the Fog
-- Colour, so the global fog stays the map's own daylight colour -- the
-- correct thing by day, and ignored by night. The fallback below is for
-- the clients that cannot do any of this, and it paints them one at a
-- time rather than touching that global.
--
-- THE FIRST SKY IS NOT OPTIONAL. "A client that negotiated this
-- extension waits for the first Sky before drawing the world" -- so a
-- client we agree with and then never send to is a client staring at
-- nothing. It goes out from the ready callback, which is the earliest
-- moment there is, and that is the one packet this module must never
-- fail to send.
--
-- Nothing in LSd's core knows about any of this. PacketTypeExtensionInfo
-- is declared in protocol.h:804 and the ExtensionID enum lives at :916,
-- which names nothing near 0x33, while nothing in funcs_packetrecv.c,
-- funcs_send.c, main.c or lua.c ever touches packet 0x73. So the
-- negotiation is unclaimed, and lib_ext claims it for every extension
-- at once. This module owns packet 0x73 and nothing else; load lib_ext
-- before it.
--
-- API (globals):
--   daytime_supported(pid)  -> true once ext 0x33 is agreed
--   daytime_is_night()      -> is it night
--   daytime_daylight()      -> 1 by day, 0 by night. How much of the
--                              world's own lighting there is, for
--                              anything that wants to match the client
--   daytime_set_night(on)   switch it and tell everybody
--   daytime_announce()      re-send the Sky to everybody who has
--                              negotiated, after setting daytime_night
--                              directly
local mod = init_mod();

local EXT_ID = 0x33;
local EXT_VERSION = 1;

-- Daytime and Weather. The packet id is 64 + the extension id, so 0x73.
local PKT = 64 + EXT_ID;
local SUB_SKY = 0;

-- The two values of Time. 0 is night and "anything else" is day, so the
-- day value is a choice; 1 is the smallest thing that is not 0, which
-- keeps the packet honest about carrying no hour. A later version reads
-- this field as minutes since midnight, where 1 is 00:01 -- near enough
-- to the midnight 0 used to mean that an old server talking to a new
-- client would be wrong by a minute rather than by half a day.
local TIME_NIGHT = 0;
local TIME_DAY = 1;

-- Reserved, and Weather, both of which must be zero in version 1.
-- Spelled out rather than left as a run of "\0" because version 2 is
-- where Reserved becomes the speed, and this is the line that changes.
local RESERVED_ZERO = "\0\0";
local WEATHER_NONE = "\0\0";

-- Night is black, and that is a spec constant rather than a knob: the
-- client draws its own darkness and the server cannot talk it out of
-- it, so a setting here could only make the two disagree about how dark
-- it is. The fallback paints this same black for the clients that
-- cannot.
local NIGHT_FOG = {r = 0, g = 0, b = 0};
-- How much of the world's own lighting survives the night. None of it.
local NIGHT_LIGHT = 0;

-- Night, or day. The whole configuration of this extension in v1.
getcfg("daytime_night", false,
	"Night instead of day. By night nothing lights the world and "
		.."the sky is black; only flashlights light it.");
-- Seconds between unprompted re-sends of the Sky. There is no clock to
-- drift in v1, so this is not the correction it was when Time was an
-- hour -- it is belt and braces: eight bytes a client every five
-- minutes against the chance that one somehow missed the Sky it is
-- waiting for and is sitting there not drawing the world. 0 turns it
-- off.
getcfg("daytime_resync", 300,
	"Seconds between unprompted re-sends of the Sky. 0 turns it "
		.."off.");
-- Paint the fog for clients that have NOT negotiated the extension, so
-- that night at least looks like night to them -- a black sky, which is
-- the half of it the base protocol can express. Off leaves them the
-- map's own sky. See the fallback below for what it cannot do.
getcfg("daytime_fog_fallback", true,
	"Paint a black sky for clients that cannot draw the night "
		.."themselves.");
getcfg("daytime_debug", false,
	"Log every Sky sent and every client that negotiated.");

local function negotiated(pid)
	return ext_supported ~= nil and ext_supported(pid, EXT_ID) ~= nil;
end

-- pid -> the fog we last painted for them, so a client is sent a fog
-- packet only when its own sky actually changed. Cleared on disconnect,
-- since the next occupant of that id has been painted nothing.
local painted = pid_connected_table();

--============================== BYTES ===============================--

-- Little-endian u16, out of arithmetic rather than the FFI: LuaJIT is
-- 5.1 so there is no string.pack, and the modulo says little-endian on
-- every host where a cast would only say it on x86.
local function put_u16(n)
	n = math.floor(tonumber(n) or 0) % 65536;
	return string.char(n % 256, math.floor(n / 256));
end

--=============================== API ================================--

function daytime_supported(pid)
	return negotiated(pid);
end

function daytime_is_night()
	return daytime_night and true or false;
end

function daytime_daylight()
	return daytime_is_night() and NIGHT_LIGHT or 1;
end

local function send_sky(pid)
	send_packet(pid, string.char(PKT, SUB_SKY)
		.. put_u16(daytime_is_night() and TIME_NIGHT or TIME_DAY)
		.. RESERVED_ZERO
		.. WEATHER_NONE);
end

-- Re-send the Sky to everybody who has negotiated. The server may send
-- one whenever it likes and it applies on arrival, so this is how a
-- change to daytime_night reaches clients already connected -- without
-- it, only the ones that negotiate afterwards see the new sky.
function daytime_announce()
	for i in piditer(PID_BROADCAST) do
		if (negotiated(i)) then
			send_sky(i);
		end
	end

	if (daytime_debug) then
		log("lib_daytime: announced %s",
			daytime_is_night() and "night" or "day");
	end
end

function daytime_set_night(on)
	daytime_night = on and true or false;
	daytime_announce();
end

--============================= FALLBACK =============================--

-- The sky for a client that never heard of this extension, which is the
-- most the base 0.75 protocol can say: the same black the extension's
-- clients draw for themselves.
--
-- WHAT IT CANNOT DO is the lighting. Nothing in base 0.75 scales how
-- bright the blocks are, so one of these clients gets a night sky over
-- a fully lit world. It reads as dusk rather than as night, and it is
-- the better deal in a firefight -- which is an argument for requiring
-- the extension (ext_policy) on a server that plays at night, not an
-- argument for telling these clients nothing at all.
--
-- Per client, and never through set_fog. set_fog writes the global and
-- broadcasts it to everybody (main.c:279-285) -- one sky for the whole
-- server. The global has to stay the map's own colour: it is what a
-- joining client reads out of its State Data, what map_meta put there,
-- and what every client falls back to by day. send_fog takes a pid
-- (send:2), so the black goes only to the clients that need to be told
-- about it.
local function want_fog()
	local fog = get_fog();

	if (fog == nil) then
		return nil;
	end

	if (not daytime_is_night()) then
		return fog; -- by day, the map's own sky, unchanged
	end

	return NIGHT_FOG;
end

local function paint()
	local want = want_fog();

	if (want == nil) then
		return;
	end

	for pid in piditer(PID_BROADCAST) do
		-- served by the extension itself, so not ours to paint
		if (not negotiated(pid)) then
			local had = painted[pid];

			if (had == nil or had.r ~= want.r or had.g ~= want.g
			    or had.b ~= want.b) then
				painted[pid] = want;
				send_fog(pid, want);
			end
		end
	end
end

--============================== READY ===============================--

-- The ready callback, and the one packet that must not be missed: a
-- client that has negotiated this draws nothing until the first Sky
-- arrives.
--
-- It also stops being the fallback's business, so whatever was painted
-- for it is forgotten -- it scales the map's own fog for itself from
-- here, and the global it reads is already the right input.
local function on_ready(pid)
	painted[pid] = nil;
	send_sky(pid);

	if (daytime_debug) then
		log("lib_daytime: #%d negotiated, sky is %s", pid,
			daytime_is_night() and "night" or "day");
	end
end

--============================== DRIVE ===============================--

local last_resync = 0;

function mod.after.tick()
	if (daytime_fog_fallback) then
		paint();
	end

	local every = tonumber(daytime_resync) or 0;
	if (every <= 0) then
		return;
	end

	local now = get_time();

	-- Seeded from the first tick rather than from zero, so a server does
	-- not open by broadcasting a Sky to nobody: get_time() counts from
	-- boot (main.c:130-136), so now - 0 is already enormous.
	if (last_resync == 0) then
		last_resync = now;
		return;
	end

	if (now - last_resync < every) then
		return;
	end
	last_resync = now;

	daytime_announce();
end

--============================= INTAKE ===============================--
-- Server to client only: there is no form of this a client may send, so
-- anything arriving on packet 0x73 is swallowed. Claimed rather than
-- left alone because the core would otherwise log every one as
-- "Unknown packet ID" crap (funcs_packetrecv.c:484). Returning 0 hands
-- it to on_sane_packet, whose switch has no default case, so it is
-- dropped there having been dealt with here.
function mod.on_any_packet(pid, data)
	if (string.byte(data, 1) == PKT) then
		return 0;
	end

	return mod.next.on_any_packet(pid, data);
end

--============================ LIFECYCLE =============================--

-- A map change needs no Sky -- "the Time survives Map Start" -- but it
-- does repaint the global fog, from the map's own metadata or the `fog`
-- config (map_meta.lua:41-45). That resets the clients the fallback
-- painted, so they are forgotten here and painted again on the next
-- tick, out of the new map's colour.
function mod.after.finish_map_load()
	for pid in piditer(PID_BROADCAST) do
		painted[pid] = nil;
	end
end

-- Registering re-announces the extension list, and the replies run
-- on_ready, which is what gets a Sky to everybody after a hot load.
function mod.on_load()
	if (ext_register == nil) then
		error("lib_daytime needs lib_ext loaded first "
			.."(config.lua loads it, or: lsdctl <instance> load lib_ext "
			.."lib_daytime)", 0);
	end

	ext_register("lib_daytime", EXT_ID, EXT_VERSION, on_ready,
		"Daytime and Weather");
end


-- Settings can be reloaded without restarting (lib_settings), and this
-- module has already told every client what the sky is. So say it again
-- when the file changes, or a reload would move the setting and leave
-- the clients on the old one.
if (settings_listen ~= nil) then
	settings_listen("lib_daytime", function()
		daytime_announce();
	end);
end
-- Everything this module put in the global table, taken back out again.
--
-- Unloading a module does not undo its globals -- the functions keep
-- working, closed over the state of a module nothing is calling any
-- more -- and consumers test these names to find out whether the thing
-- is available at all. Left behind, they answer yes forever and every
-- such guard becomes dead code.
--
-- The list is exhaustive on purpose: a name added to the API above and
-- forgotten here outlives its own module, and goes on answering for it.
local EXPORTS = {
	"daytime_supported", "daytime_is_night", "daytime_daylight",
	"daytime_set_night", "daytime_announce",
};

-- The clients the fallback painted are put back to the server's own
-- sky, which it can do exactly because it never touched the global:
-- get_fog still holds whatever map_meta last set, so there is a right
-- answer to return them to rather than a guess.
function mod.on_unload()
	local fog = get_fog();

	if (fog ~= nil) then
		for pid in piditer(PID_BROADCAST) do
			if (painted[pid] ~= nil) then
				send_fog(pid, fog);
			end
		end
	end

	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end

	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
