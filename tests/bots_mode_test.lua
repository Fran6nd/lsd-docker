-- bots_mode_test.lua -- the bots gamemode: its day and night cycle
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/bots_mode_test.lua      (from the repository root)
local passed, failed = 0, 0;
local function check(ok, what)
	if (ok) then passed = passed + 1; print("  PASS " .. what);
	else failed = failed + 1; print("  FAIL " .. what); end
end

--============================= STUBS ================================--
function init_mod() return {after = {}, before = {}, next = {}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
PID_BROADCAST = -1;
local now = 1000;
function get_time() return now; end

local night = false;
local sky_sends = 0;
function daytime_is_night() return night; end
function daytime_set_night(on) night = on; sky_sends = sky_sends + 1; end

local said = {};
function l10n_send_chat(to, m) said[#said+1] = {to = to, m = m}; end
local listed;
function masterlist_set_gamemode(g) listed = g; end

-- the tdm module, which bots loads: a marker is all the cycle needs
local tdm_loaded = 0;
function load(name) if (name == "tdm") then tdm_loaded = tdm_loaded + 1; end end

--============================= CHECKS ===============================--
print("\n1. loading: tdm's scoring, day first, guards unlit");
local mod = dofile("catalog/gamemodes/bots/bots.lua");
mod.on_load();
check(tdm_loaded == 1, "tdm is loaded for its scoring");
check(listed == "bots", "listed as bots");
check(bots_day_secs == 240 and bots_night_secs == 180, "240 s of day, 180 s of night");
check(guard_count == 6, "six guards a team by default");
check(night == false and guard_flashlight == false, "it starts as day, lights off");

print("\n2. the day lasts bots_day_secs");
now = 1000 + 239;
mod.after.tick();
check(night == false and #said == 0, "a second before the end: still day");
now = 1000 + 240;
mod.after.tick();
check(night == true, "at the end: night");
check(#said == 1 and said[1].to == PID_BROADCAST
	and said[1].m.en == "Night falls. Press F for your flashlight.",
	"everyone is told, with the flashlight hint");
check(guard_flashlight == true, "the guards light their flashlights");

print("\n3. the night lasts bots_night_secs, then dawn");
now = 1240 + 179;
mod.after.tick();
check(night == true and #said == 1, "a second before dawn: still night");
now = 1240 + 180;
mod.after.tick();
check(night == false and guard_flashlight == false, "dawn: day, lights off");
check(#said == 2 and said[2].m.en == "Dawn.", "dawn is announced");

print("\n4. it goes round again, once per change");
now = 1420 + 240;
mod.after.tick();
mod.after.tick();
check(night == true and #said == 3, "the next night falls once, however many ticks");

print("\n5. a new map starts at day, with a whole day");
now = 5000;
mod.after.finish_map_load();
check(night == false and guard_flashlight == false, "day again, lights off");
check(#said == 3, "silently: no dawn announced for a map change");
now = 5000 + 239;
mod.after.tick();
check(night == false, "the day is a whole one");
now = 5000 + 240;
mod.after.tick();
check(night == true, "and then night");

print("\n6. bots_day_secs read live");
bots_day_secs = 10;
now = 6000; mod.after.finish_map_load();
now = 6010; mod.after.tick();
check(night == true, "a changed setting shortens the next day");

print(string.format("\n%d passed, %d failed", passed, failed));
os.exit(failed == 0 and 0 or 1);
