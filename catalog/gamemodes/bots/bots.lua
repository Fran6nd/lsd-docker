-- bots.lua -- Team deathmatch with guard bots, through day and night
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- tdm's scoring, loaded rather than copied, plus a clock: bots_day_secs
-- of day, then bots_night_secs of night, round and round. The old
-- "hallwayatnight" instance was permanent night; this is the same fear
-- with a morning to look forward to.
--
-- By night the Daytime extension blacks out the world and the only
-- light is a flashlight, so the guards carry theirs lit then and put
-- them out by day. The guards read guard_flashlight on every tick, so
-- flipping that one setting at the transition is all it takes; it is
-- this mode's to flip, whatever the setting was before.
--
-- A new map starts at day, with a full day ahead.
local mod = init_mod();

-- the kill counting and the win; its setting, tdm_kills, is asked of
-- this mode too
load("tdm");

getcfg("bots_day_secs", 240, "Seconds of day before night falls.");
getcfg("bots_night_secs", 180, "Seconds of night before dawn.");
getcfg("guard_count", 6, "Guard bots kept alive per team.");

local night_msg = {en = "Night falls. Press F for your flashlight."};
local dawn_msg = {en = "Dawn."};

local flips_at;  -- get_time() of the next change

local function set_night(on, announce)
	daytime_set_night(on);
	guard_flashlight = on;
	flips_at = get_time() + (on and bots_night_secs or bots_day_secs);
	if (announce) then
		l10n_send_chat(PID_BROADCAST, on and night_msg or dawn_msg);
	end
end

function mod.after.tick()
	if (flips_at ~= nil and get_time() >= flips_at) then
		set_night(not daytime_is_night(), true);
	end
end

function mod.after.finish_map_load()
	set_night(false, false);
end

function mod.on_load()
	masterlist_set_gamemode("bots");
	set_night(false, false);
end

-- the tdm loaded above goes with this mode, and the day comes back
function mod.on_unload()
	if (package.loaded.tdm ~= nil) then
		unload("tdm");
	end
	if (daytime_set_night ~= nil and daytime_is_night ~= nil and daytime_is_night()) then
		daytime_set_night(false);
	end
end

return mod;
