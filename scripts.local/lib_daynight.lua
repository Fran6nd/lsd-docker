-- lib_daynight.lua -- A clock for the sky
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Walks the fog colour around a 24-hour day, so a server has a time of
-- day: dark before dawn, a warm sunrise, the stock blue sky at noon, a
-- red sunset, and dark again. Or stops the clock at one hour and leaves
-- it there, which is how you get a map that is always midnight.
--
-- WHAT A "DAY" CAN BE HERE, honestly. The 0.75 protocol has no sun, no
-- light level and no time: the only thing a server can repaint is the
-- fog colour (set_fog, main.c:279-285), which is global and goes to
-- everybody at once. Fog is the horizon and the sky, NOT the lighting
-- on the blocks -- a voxel is as bright at midnight as at noon, because
-- nothing in the protocol can say otherwise.
--
-- So this is weather and atmosphere, not darkness. What it changes is
-- how far you can see and what colour the world sits in, which is
-- plenty: a midnight map reads as night, distance closes in, and a
-- carried flashlight (lib_flashlight) stops being a toy and starts
-- being the reason you can see somebody. That pairing is the whole
-- point of running the clock at all.
--
-- THE CLOCK IS DERIVED, NOT COUNTED. The hour comes out of get_time()
-- by arithmetic every time it is asked, rather than being advanced by a
-- tick -- so it survives this module being reloaded without the sky
-- jumping, and there is no accumulated drift to correct. get_time() is
-- CLOCK_MONOTONIC (main.c:130-136), which counts from boot, so the
-- phase is arbitrary but it is the same arbitrary phase before and
-- after a hot load.
--
-- IT REASSERTS ITSELF, which it has to. map_meta.lua repaints the fog
-- on every map load, from the map's own .txt metadata or from the `fog`
-- config (map_meta.lua:41-45), and that runs in a before.load_map hook.
-- Rather than racing it, this compares the sky it wants against the fog
-- actually in place (get_fog) and corrects a difference -- so a map
-- load, an /fog from an admin, or anything else that repaints the sky
-- is simply undone within a second. A server that wants a fixed fog
-- does not want this module loaded.
--
-- API (globals):
--   daynight_hour()       -> the hour now, 0 to 24, fractional
--   daynight_phase()      -> the name of the keyframe in force, e.g.
--                            "noon" -- for anything that wants to know
--                            whether it is dark without knowing the
--                            palette
--   daynight_color(hour)  -> the sky at that hour, as {b=,g=,r=}.
--                            Omit `hour` for now.
--   daynight_set_hour(h)  pin the clock to `h`, or nil to let it run.
--                            The same thing daynight_fixed_hour does,
--                            from Lua rather than from config.
local mod = init_mod();

-- Real minutes in one whole in-game day. 24 puts an hour in a minute,
-- which is the figure that makes a 24-minute day read as a day.
getcfg("daynight_minutes", 24);
-- Stop the clock at this hour and leave it: 0 for always-midnight, 12
-- for always-noon. nil lets it run. Fractions are fine.
getcfg("daynight_fixed_hour", nil);
-- What hour the cycle sits at when the server's monotonic clock is at
-- zero. Only an offset -- it decides where in the day you happen to
-- come in, nothing else.
getcfg("daynight_start_hour", 6);
-- Most fog packets per second. Fog is a broadcast, so this is the
-- traffic dial, and it only ever sends when the colour it wants is
-- actually different from the colour in place. One a second is far
-- smoother than the eye needs over a 24-minute day: the steepest ramp
-- in the palette below moves 3.3 units of colour per real second, so a
-- once-a-second repaint steps by three values out of 256.
getcfg("daynight_rate", 1);
getcfg("daynight_debug", false);

-- The sky, by the hour. Interpolated between these, wrapping midnight
-- to midnight, so the whole palette is these eleven rows and the
-- arithmetic below.
--
-- noon is {r=128, g=232, b=255} because that is the stock fog this
-- server already used (config.lua:20), so midday looks like the game
-- always looked and everything else is a departure from it.
--
-- Ordered by hour, and that order is relied on. getcfg means an
-- instance can replace the whole table; keep it sorted if you do.
getcfg("daynight_keyframes", {
	{hour = 0,  r = 6,   g = 8,   b = 24,  name = "midnight"},
	{hour = 4,  r = 12,  g = 16,  b = 40,  name = "night"},
	{hour = 6,  r = 120, g = 90,  b = 90,  name = "dawn"},
	{hour = 7,  r = 232, g = 150, b = 110, name = "sunrise"},
	{hour = 9,  r = 150, g = 220, b = 250, name = "morning"},
	{hour = 12, r = 128, g = 232, b = 255, name = "noon"},
	{hour = 16, r = 140, g = 215, b = 245, name = "afternoon"},
	{hour = 18, r = 240, g = 140, b = 90,  name = "sunset"},
	{hour = 20, r = 90,  g = 70,  b = 100, name = "dusk"},
	{hour = 22, r = 20,  g = 24,  b = 52,  name = "night"},
	{hour = 24, r = 6,   g = 8,   b = 24,  name = "midnight"},
});

local HOURS = 24;

-- nil while the clock runs; an hour while it is pinned. Seeded from
-- config at load, and daynight_set_hour moves it afterwards.
local pinned = nil;

local last_sent = 0;

--============================== CLOCK ===============================--

local function wrap_hour(h)
	h = tonumber(h);

	if (h == nil or h ~= h) then
		return 0; -- nil or NaN
	end

	h = h % HOURS;
	if (h < 0) then
		h = h + HOURS;
	end

	return h;
end

-- The hour now. Pinned, or derived from the monotonic clock: one whole
-- day every daynight_minutes of real time.
--
-- A zero or negative daynight_minutes would be a day of no length,
-- which is a division by zero rather than a fast day -- read as "do not
-- move", since a caller who wanted a still sky has said so clumsily
-- rather than meaning anything else.
function daynight_hour()
	if (pinned ~= nil) then
		return pinned;
	end

	local minutes = tonumber(daynight_minutes) or 0;
	if (minutes <= 0) then
		return wrap_hour(daynight_start_hour);
	end

	local days = get_time() / (minutes * 60);
	return wrap_hour(days * HOURS + (tonumber(daynight_start_hour) or 0));
end

function daynight_set_hour(h)
	pinned = h ~= nil and wrap_hour(h) or nil;
end

--============================= PALETTE ==============================--

local function chan(v)
	v = math.floor(tonumber(v) or 0);
	return math.max(0, math.min(255, v));
end

-- The two keyframes `hour` falls between. The table is sorted and its
-- last row is hour 24, which is the same sky as hour 0 -- that is what
-- makes midnight a seam the interpolation crosses rather than a wall it
-- stops at, with no wrapping arithmetic anywhere below.
local function bracket(hour)
	local kf = daynight_keyframes;

	for i = 1, #kf - 1 do
		if (hour >= kf[i].hour and hour <= kf[i+1].hour) then
			return kf[i], kf[i+1];
		end
	end

	-- Off the end of a table an instance has replaced with something
	-- that does not reach 24. Not worth failing over: the last row is
	-- the nearest thing to an answer.
	return kf[#kf], kf[#kf];
end

-- The sky at `hour`, linearly between its two keyframes. Linear in RGB
-- is not how light works, but it is how the stock palette was chosen
-- and it is what makes a sunrise read as a sunrise rather than as a
-- detour through grey.
function daynight_color(hour)
	hour = hour ~= nil and wrap_hour(hour) or daynight_hour();

	local a, b = bracket(hour);
	local span = b.hour - a.hour;
	local t = span > 0 and (hour - a.hour) / span or 0;

	return {
		r = chan(a.r + (b.r - a.r) * t),
		g = chan(a.g + (b.g - a.g) * t),
		b = chan(a.b + (b.b - a.b) * t),
	};
end

-- The nearer of the two keyframes, not the lower one. Taking the lower
-- would have noon still calling itself "morning" at the instant it
-- arrives, since the hour sits exactly on the boundary and the bracket
-- below it is the one that matches first.
function daynight_phase()
	local hour = daynight_hour();
	local a, b = bracket(hour);
	local span = b.hour - a.hour;
	local t = span > 0 and (hour - a.hour) / span or 0;

	return (t < 0.5 and a or b).name;
end

--============================== DRIVE ===============================--

-- Repaint if the sky we want is not the sky in place.
--
-- Asked of get_fog rather than of a value we remember, which is what
-- makes this self-healing: map_meta repaints on every map load and an
-- admin can repaint with /fog, and either way the difference shows up
-- here on the next pass and is corrected. Remembering what we last sent
-- would miss both.
function mod.after.tick()
	local rate = tonumber(daynight_rate) or 1;
	local now = get_time();

	if (rate > 0 and now - last_sent < 1 / rate) then
		return;
	end

	local want = daynight_color();
	local have = get_fog();

	if (have ~= nil and have.r == want.r and have.g == want.g
	    and have.b == want.b) then
		return;
	end

	last_sent = now;
	set_fog(want);

	if (daynight_debug) then
		log("lib_daynight: %05.2f (%s) -> %d/%d/%d", daynight_hour(),
			daynight_phase(), want.r, want.g, want.b);
	end
end

--============================ LIFECYCLE =============================--

function mod.on_load()
	-- config wins at load; daynight_set_hour moves it afterwards
	pinned = daynight_fixed_hour ~= nil
		and wrap_hour(daynight_fixed_hour) or nil;

	log("lib_daynight: %s", pinned ~= nil
		and string.format("pinned at %05.2f (%s)", pinned, daynight_phase())
		or string.format("%s minutes per day, now %05.2f (%s)",
			tostring(daynight_minutes), daynight_hour(), daynight_phase()));
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
	"daynight_hour", "daynight_phase", "daynight_color",
	"daynight_set_hour",
};

-- The sky is left where it stopped, deliberately. Putting the `fog`
-- config back would be a guess at what the server wanted, and the next
-- map load repaints it from map_meta anyway (map_meta.lua:41-45), which
-- is the server's own answer rather than this module's.
function mod.on_unload()
	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
