-- nightvision.lua -- A green light only its carrier sees
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- A player who has night vision switches it on and off with the F key,
-- as they would a flashlight: a wide green beam that their own client
-- draws and nobody else's. No beam, no lamp glare -- whoever is lit up
-- by it, or looking straight at them, sees nothing.
--
-- It is the flashlight extension doing the drawing (lib_flashlight's
-- flashlight_private), so that has to be installed. Effects load
-- before extensions, so it is looked up at run time and never on load:
-- without it this does nothing, and says so once in the log.
--
-- Who has it is PlayerEffect's: everybody while nightvision_everyone,
-- else whoever a gamemode gives it to:
--
--   local nv = PlayerEffect.get("nightvision");
--   nv.everyone = false;
--   nv:give(pid, {secs = 60});
--   nv:trigger(pid, {on = true})   -- switch it for them; no `on`
--        -> on or off now          -- toggles
--
-- A player without it keeps the ordinary flashlight, unless
-- nightvision_only, which refuses them the F key altogether. Losing it
-- with the light on puts the light out, rather than leaving it lit for
-- everybody to see.

local switch; -- below

local fx = PlayerEffect {
	name = "nightvision",
	warning = {en = "Press F for night vision: a green light only you can see."},
	tip = {en = "Dark in here? F turns on your night vision, and nobody sees it."},
	every = 0,
	trigger = function(pid, opts)
		return switch(pid, opts);
	end,
};
local mod = fx.mod;

getcfg("nightvision_reach", 70);  -- blocks the light reaches
getcfg("nightvision_cone", 120);  -- full angle, degrees
getcfg("nightvision_only", false); -- others may not light a flashlight

local GREEN = {r = 40, g = 255, b = 64};
local LISTENER = "nightvision";

-- the players whose private beam is ours to end
local mine = pid_connected_table(false);
local listening, warned = false, false;

local function beam()
	return {reach = nightvision_reach, cone = nightvision_cone,
		color = GREEN};
end

local function available()
	if (flashlight_private ~= nil) then
		return true;
	end
	if (not warned) then
		warned = true;
		log("nightvision: the flashlight extension is not loaded, so"
			.. " nothing is drawn (lsdctl install flashlight)");
	end
	return false;
end

-- F: lib_flashlight asks before it switches anyone's light. A player
-- with night vision always may, and their beam is made theirs alone
-- first; one without it may unless nightvision_only.
local function on_request(pid, want)
	if (fx:has(pid)) then
		if (flashlight_get_private(pid) == nil) then
			flashlight_private(pid, beam());
			mine[pid] = true;
		end
		return true;
	end
	if (want and nightvision_only) then
		return false;
	end
end

function switch(pid, opts)
	if (not available() or not fx:has(pid)) then
		return nil;
	end
	local on = opts.on;
	if (on == nil) then
		on = not flashlight_get(pid);
	end
	on_request(pid, on);
	flashlight_set(pid, on);
	return on;
end

-- Kept in step a few times a second rather than on each grant, since a
-- grant runs out on its own: a player who lost night vision is put back
-- to the ordinary light, dark first if it was on.
local SYNC_INTERVAL = 0.25;
local next_sync = 0;

function mod.after.tick()
	local now = get_time();
	if (now < next_sync) then
		return;
	end
	next_sync = now + SYNC_INTERVAL;

	if (flashlight_private == nil) then
		listening = false;   -- unloaded, or never there
		return;
	end
	if (not listening) then
		flashlight_listen_request(LISTENER, on_request);
		listening = true;
	end

	for pid in piditer(PID_BROADCAST) do
		-- not the bots: a guard's lit flashlight is meant to be seen
		local has = fx:has(pid)
			and not (bot_is_headless ~= nil and bot_is_headless(pid));
		if (has and flashlight_get_private(pid) == nil) then
			flashlight_private(pid, beam());
			mine[pid] = true;
		elseif (not has and mine[pid]) then
			if (flashlight_get(pid)) then
				flashlight_set(pid, false);
			end
			flashlight_private(pid, nil);
			mine[pid] = false;
		end
	end
end

fx.unload = function()
	if (flashlight_private == nil) then
		return;
	end
	flashlight_unlisten_request(LISTENER);
	for pid in piditer(PID_BROADCAST) do
		if (mine[pid]) then
			if (flashlight_get(pid)) then
				flashlight_set(pid, false);
			end
			flashlight_private(pid, nil);
		end
	end
end

return mod;
