-- lib_daytime.lua -- The Daytime and Weather protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Daytime and Weather extension (id 0x33, version
-- 1): the server says what time it is and how fast time runs, and the
-- client draws the sun, the daylight and the dark.
--
-- ONE SUB-PACKET, Sky, Server to Client:
--   [0x73][0][Time u16][Speed u16][Weather u16]   -- eight bytes
--
--   Time     minutes since midnight, 0 to 1439
--   Speed    game minutes per real minute. 0 stops the clock, 1 is
--            real time, 60 is a day every 24 real minutes -- a day
--            lasts 1440/Speed real minutes
--   Weather  two bytes, unimplemented in version 1, must be zero
--
-- THE CLIENT KEEPS THE CLOCK, which is what makes this cheap. It
-- advances Time by Speed from the moment the Sky arrives and wraps at
-- 1440, so the server sends one packet and says nothing more until
-- something actually changes. There is no per-tick repaint here and
-- there must not be one: a Sky every second would be a clock reset
-- every second.
--
-- AND THE CLIENT DOES THE LIGHT. With a = (Time - 720)/4 degrees since
-- noon, daylight is D = max(0.1, clamp(2 cos a, 0, 1)); the world's
-- lighting is scaled by D and the fog is drawn as the Fog Colour times
-- D. So 6 PM to 6 AM is night at a tenth of daylight, 8 AM to 4 PM is
-- full daylight, and noon looks exactly as it did before this extension
-- existed. Below the horizon the sun casts nothing, so the night's
-- light falls evenly on every face rather than lighting them from
-- underneath the map.
--
-- That is worth dwelling on, because it is the opposite of what a
-- server would otherwise do. The fog colour is NOT the night here: the
-- server keeps sending the map's own daylight fog and the client
-- darkens it. A server that also darkens the fog itself gets both, and
-- the result at dusk is black rather than dusk. See lib_daynight, which
-- is exactly that fallback and which stands down for any client that
-- has negotiated this.
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
--   daytime_supported(pid)    -> true once ext 0x33 is agreed
--   daytime_now()             -> minutes since midnight, 0-1439
--   daytime_speed_now()       -> the Speed in force
--   daytime_daylight([mins])  -> D at that time, 0.1 to 1. What anything
--                                wanting to know how dark it is should
--                                ask, rather than working it out again
--   daytime_set(mins, speed)  set the clock and tell everybody. Either
--                                may be nil to leave it alone.
--   daytime_announce()        re-send the Sky to everybody who has
--                                negotiated, after changing the
--                                daytime_* globals directly
--
--   DAYTIME_MINUTES_PER_DAY   1440, the wrap
local mod = init_mod();

local EXT_ID = 0x33;
local EXT_VERSION = 1;

-- Daytime and Weather. The packet id is 64 + the extension id, so 0x73.
local PKT = 64 + EXT_ID;
local SUB_SKY = 0;

DAYTIME_MINUTES_PER_DAY = 1440;

-- Noon, and the hinge the daylight curve turns on.
local NOON = 720;

-- The night floor: D never falls below this, so 6 PM to 6 AM is night
-- rather than nothing at all. A spec constant, not a knob -- the client
-- computes its own D and the server cannot talk it out of it, so a
-- server-side setting here could only make the two disagree about how
-- dark it is. If the spec's floor moves, this moves with it.
local NIGHT_FLOOR = 0.1;

-- Weather is two bytes that must be zero in version 1. Spelled out
-- rather than left as a magic "\0\0" because version 2 is where it
-- stops being zero, and this is the line that will change.
local WEATHER_NONE = "\0\0";

-- Game minutes per real minute. 60 is a day every 24 real minutes,
-- which is the figure the spec uses for its own example; 0 stops the
-- clock where daytime_start leaves it, which is how a server pins
-- itself to one hour forever.
getcfg("daytime_speed", 60);
-- Where the clock sits when the server's monotonic clock is at zero,
-- in minutes since midnight. With a stopped clock this is simply the
-- time, forever -- 0 for midnight, 720 for noon.
getcfg("daytime_start", 0);
-- Seconds between unprompted re-sends of the Sky, to pull drifted
-- clients back into line. The client runs its own clock from the moment
-- the Sky arrived, and nothing keeps its idea of a minute exactly equal
-- to ours -- at speed 60, five real minutes is 300 game minutes, so a
-- one percent error is three game minutes of sky. Rare enough that the
-- correction is invisible, often enough that the drift never grows.
--
-- 0 turns it off. A stopped clock never resyncs whatever this says:
-- there is nothing to drift, so a packet would be pure noise.
getcfg("daytime_resync", 300);
getcfg("daytime_debug", false);

local function negotiated(pid)
	return ext_supported ~= nil and ext_supported(pid, EXT_ID) ~= nil;
end

--============================== BYTES ===============================--

-- Little-endian u16, out of arithmetic rather than the FFI: LuaJIT is
-- 5.1 so there is no string.pack, and the modulo says little-endian on
-- every host where a cast would only say it on x86.
local function put_u16(n)
	n = math.floor(tonumber(n) or 0) % 65536;
	return string.char(n % 256, math.floor(n / 256));
end

--============================== CLOCK ===============================--

local function wrap_minutes(m)
	m = tonumber(m);

	if (m == nil or m ~= m) then
		return 0; -- nil or NaN
	end

	m = math.floor(m) % DAYTIME_MINUTES_PER_DAY;
	if (m < 0) then
		m = m + DAYTIME_MINUTES_PER_DAY;
	end

	return m;
end

local function speed_now()
	local s = math.floor(tonumber(daytime_speed) or 0);
	return math.max(0, math.min(65535, s));
end

function daytime_speed_now()
	return speed_now();
end

-- The time now, derived rather than counted. Speed is game minutes per
-- real minute, so game minutes elapsed is (seconds/60) * Speed.
--
-- Derived from get_time() -- CLOCK_MONOTONIC, counted from boot
-- (main.c:130-136) -- so it survives a reload of this module without
-- the sky lurching, and there is no drift to correct. A stopped clock
-- ignores it entirely and answers daytime_start.
function daytime_now()
	local speed = speed_now();

	if (speed == 0) then
		return wrap_minutes(daytime_start);
	end

	return wrap_minutes(get_time() / 60 * speed
		+ (tonumber(daytime_start) or 0));
end

-- The daylight at `mins`, which is the client's own formula and is here
-- so that nothing else has to reimplement it:
--
--   D = max(0.1, clamp(2 cos a, 0, 1))
--
-- with a the degrees since noon, a quarter degree per minute. So 0.1
-- from 6 PM to 6 AM, 1 from 8 AM to 4 PM, and the ramps between.
--
-- The floor is why a pinned midnight is playable. Without it half the
-- day was exactly zero -- 719 of 1440 minutes -- and no amount of
-- choosing the hour could get a dim sky rather than a black one,
-- because night had no gradient to pick from at all.
function daytime_daylight(mins)
	mins = mins ~= nil and wrap_minutes(mins) or daytime_now();

	local a = math.rad((mins - NOON) / 4);
	return math.max(NIGHT_FLOOR,
		math.min(1, 2 * math.cos(a)));
end

--=============================== WIRE ===============================--

local function send_sky(pid)
	send_packet(pid, string.char(PKT, SUB_SKY)
		.. put_u16(daytime_now())
		.. put_u16(speed_now())
		.. WEATHER_NONE);
end

-- The ready callback, and the one packet that must not be missed: a
-- client that has negotiated this draws nothing until the first Sky
-- arrives.
local function on_ready(pid)
	send_sky(pid);

	if (daytime_debug) then
		log("lib_daytime: #%d negotiated, sky at %d min, speed %d",
			pid, daytime_now(), speed_now());
	end
end

--=============================== API ================================--

function daytime_supported(pid)
	return negotiated(pid);
end

-- Re-send the Sky to everybody who has negotiated. The server may send
-- one whenever it likes and it applies on arrival, so this is how a
-- change to daytime_speed or daytime_start reaches clients already
-- connected -- without it, only the ones that negotiate afterwards see
-- the new clock.
--
-- Note what this costs: a Sky RESETS the receiving client's clock to
-- the Time in it. Sent every tick it would be a clock reset every tick
-- -- a stutter rather than a correction. So it goes out when something
-- changes, and otherwise only on the slow daytime_resync heartbeat
-- below, which is five minutes by default.
function daytime_announce()
	for i in piditer(PID_BROADCAST) do
		if (negotiated(i)) then
			send_sky(i);
		end
	end

	if (daytime_debug) then
		log("lib_daytime: announced %d min, speed %d, daylight %.2f",
			daytime_now(), speed_now(), daytime_daylight());
	end
end

-- Set the clock and tell everybody. Either argument may be nil to leave
-- that half alone, so daytime_set(nil, 0) stops the clock where it is
-- and daytime_set(720) jumps to noon at the current speed.
--
-- Stopping the clock has to pin the time it stopped at, or the next
-- answer would come from daytime_start rather than from where the hands
-- actually were -- so that is written back too.
function daytime_set(mins, speed)
	if (speed ~= nil) then
		local was = daytime_now();

		daytime_speed = math.max(0, math.min(65535,
			math.floor(tonumber(speed) or 0)));

		if (daytime_speed == 0 and mins == nil) then
			daytime_start = was;
		end
	end

	if (mins ~= nil) then
		mins = wrap_minutes(mins);

		if (speed_now() == 0) then
			daytime_start = mins;
		else
			-- Running: daytime_start is an offset, not the time, so it
			-- has to be moved by the difference rather than set to the
			-- answer we want.
			daytime_start = wrap_minutes((tonumber(daytime_start) or 0)
				+ mins - daytime_now());
		end
	end

	daytime_announce();
end

--============================= RESYNC ===============================--

-- The slow heartbeat. Everything else about this extension is
-- send-once-and-leave-it; this is the exception, and it exists because
-- the client's clock is the client's -- see daytime_resync.
local last_resync = 0;

function mod.after.tick()
	local every = tonumber(daytime_resync) or 0;

	-- A stopped clock cannot drift, so it is not worth a packet.
	if (every <= 0 or speed_now() == 0) then
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

-- A map change does not need a Sky: "the Time survives Map Start". So
-- there is no finish_map_load hook here, deliberately -- the resync
-- heartbeat will come round soon enough, and a map load is not a reason
-- to reset anybody's clock.
--
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

-- Everything this module put in the global table, taken back out again.
--
-- Unloading a module does not undo its globals -- the functions keep
-- working, closed over the state of a module nothing is calling any
-- more -- and consumers test these names to find out whether the thing
-- is available at all. Left behind, they answer yes forever and every
-- such guard becomes dead code. lib_daynight asks exactly that, to know
-- whether to darken the fog itself.
--
-- The list is exhaustive on purpose: a name added to the API above and
-- forgotten here outlives its own module, and goes on answering for it.
local EXPORTS = {
	"daytime_supported", "daytime_now", "daytime_speed_now",
	"daytime_daylight", "daytime_set", "daytime_announce",
	"DAYTIME_MINUTES_PER_DAY",
};

function mod.on_unload()
	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end

	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
