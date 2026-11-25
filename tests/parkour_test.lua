-- parkour_test.lua -- the parkour gamemode: one team, the clock, the best times
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/parkour_test.lua      (from the repository root)
--
-- The course is a real one: generated, its metadata read back through
-- upstream's own scraper as the server reads a map's .txt.
package.path = "catalog/core/?.lua;" .. package.path;
local passed, failed = 0, 0;
local function check(ok, what)
	if (ok) then passed = passed + 1; print("  PASS " .. what);
	else failed = failed + 1; print("  FAIL " .. what); end
end

--============================= STUBS ================================--
local hooks = {};   -- what the chain below the mode was asked
local function chain()
	return setmetatable({}, {__index = function(_, name)
		return function(...) hooks[#hooks + 1] = {name, ...}; end
	end});
end
function init_mod()
	return {after = {}, before = {}, next = chain(), impl = {}};
end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
MAX_PLAYERS = 32;
PID_BROADCAST = 0x20000000;
SPECTATOR = 256;
local now = 1000;
function get_time() return now; end
local logged = {};
function log(fmt, ...) logged[#logged + 1] = string.format(fmt, ...); end

local L = dofile("tests/support/l10n_env.lua").load{};
L.pids = {0, 1, 2};

-- pid 0 and 1 are people, 2 is a bot
local players = {};
for pid = 0, 2 do
	players[pid] = {name = pid == 2 and "Bot7" or ("Runner" .. pid), team = 1, alive = false,
		pos = {x = 0, y = 0, z = 0}, gun = 0};
end
function bot_is_bot(pid) return pid == 2; end
function is_connected(pid) return players[pid] ~= nil; end
function is_joined(pid) return players[pid] ~= nil; end
function is_alive(pid) return players[pid].alive; end
function get_team(pid) return players[pid].team; end
function get_next_team(pid) return players[pid].team; end
function get_gun(pid) return players[pid].gun; end
function get_name(pid) return players[pid].name; end
function get_position(pid) local p = players[pid].pos; return {x = p.x, y = p.y, z = p.z}; end
local spawns = {};
function spawn_player(pid, pos)
	players[pid].alive, players[pid].pos = true, pos;
	spawns[#spawns + 1] = {pid = pid, pos = pos};
end

local intel, tent = {}, {};
function objgrav(p) return {x = p.x, y = p.y, z = 40}; end
function drop_move_intel(team, pos) intel[team] = pos; end
function move_tent(team, pos) tent[team] = pos; end
function get_tentloc() return tent; end
-- lib_ctf's cylinder: 3 across, the eye between 4 above and 1 below
function tent_in_range(pos, t)
	local dx, dy, dz = pos.x - t.x, pos.y - t.y, pos.z - t.z;
	return math.sqrt(dx * dx + dy * dy) <= 3 and dz >= -4 and dz <= 1;
end

local listed, command;
function masterlist_set_gamemode(g) listed = g; end
function register_command(cmd) command = cmd; end

-- upstream's scraper, for the metadata as the server reads it
local scrape = dofile("lsd/scripts/lib_pyscrape.lua");
local meta = {};
function get_map_meta() return meta; end

local P = require "parkour_map";
local course = P.generate(1);

local function stand(pid, p, dx)
	players[pid].pos = {x = p.x + 0.5 + (dx or 0), y = p.y + 0.5, z = p.z - 2.25};
end

--============================= CHECKS ===============================--
print("\n1. loading, and a map that names a course");
map_web_random = true;
local mod = dofile("catalog/gamemodes/parkour/parkour.lua");
-- the chain's top, as the server calls it
function get_spawn_position(pid) return mod.get_spawn_position(pid); end
mod.on_load();
check(listed == "parkour", "listed as parkour");
check(team_balance_max_diff == math.huge, "team_balance is told one team is fine");
check(map_web_random == false, "and vote_map that no map comes from the web");
check(command ~= nil and command.name == "best", "/best is registered");

mod.after.pyscrape_ext(scrape, "\n" .. P.meta(course, "parkour") .. "\n", meta);
local c = meta.parkour;
check(c ~= nil and c.start.x == course.start.x + 0.5 and c.start.z == course.start.z
	and c.tent.y == course.tent.y + 0.5, "the start and the tent are read from the metadata");
check(c ~= nil and #c.checkpoints == #course.checkpoints
	and c.checkpoints[2].x == course.checkpoints[2].x + 0.5, "and every checkpoint, in order");
local other = {};
mod.after.pyscrape_ext(scrape, "\nname = 'Hallway'\nextensions = {\n    'water_damage' : 5,\n}\n", other);
check(other.parkour == nil, "a map without them has no course");

mod.after.finish_map_load();
check(tent[1] ~= nil and tent[1].x == c.tent.x and tent[1].y == c.tent.y, "the tent is put at the end of the course");
check(intel[1].x == 0.5 and intel[2].x == 511.5 and tent[2].x == 0.5, "both intels and the other tent are parked in corners");
tent[1].z = course.tent.z;

print("\n2. one team, whatever is asked for");
hooks = {};
mod.on_join(0, 2, 1, "Runner0");
check(hooks[1][1] == "on_join" and hooks[1][3] == 1, "joining green joins blue");
mod.on_join(1, SPECTATOR, 0, "Runner1");
check(hooks[2][3] == SPECTATOR, "a spectator stays one");
hooks = {};
mod.on_switch(0, 2, 0);
check(#hooks == 0 and L.chat[#L.chat].m == "Everybody runs on the same team here.",
	"switching to green does nothing, and says why");
mod.on_switch(0, 1, 2);
check(#hooks == 1 and hooks[1][3] == 1 and hooks[1][4] == 2, "a change of gun goes through");
hooks = {};
mod.pickup_intel(0);
check(#hooks == 0, "nobody picks an intel up");

print("\n3. no building, no digging, no craters");
hooks = {};
mod.on_block_action(0, {x = 1, y = 1, z = 1}, 0);
mod.on_block_line(0, {x = 1, y = 1, z = 1}, {x = 2, y = 1, z = 1});
check(#hooks == 0, "a block and a line are refused");
check(L.chat[#L.chat].m == "No building or digging on the course.", "and the builder is told");
check(not mod.may_edit_block(0, {x = 1, y = 1, z = 1}, 1) and not mod.may_edit_block(nil, {x = 1, y = 1, z = 1}, 1)
	and not mod.may_edit_block(0, {x = 1, y = 1, z = 1}, 0),
	"no crater, no blast, no script's edit: the one question every edit answers to says no");

print("\n4. spawning: on the start platform, and told the game once");
L.reset();
for pid = 0, 2 do
	spawn_player(pid, mod.get_spawn_position(pid));
	mod.after.spawn_player(pid);
end
local on_start = true;
for pid = 0, 2 do
	local p = players[pid].pos;
	if (math.abs(p.x - c.start.x) > 2 or math.abs(p.y - c.start.y) > 2 or p.z ~= c.start.z - 2.251) then on_start = false; end
end
check(on_start, "everybody stands on the start platform, within two of its middle");
check(#L.chat == 2 and L.chat[1].to == 0 and string.find(L.chat[1].m, "^Parkour: run to the tent") ~= nil,
	"each person is told the game; the bot is not");
mod.after.spawn_player(0);
check(#L.chat == 2, "once, not at every spawn");

print("\n5. the clock: from leaving the start platform to the tent");
L.reset();
now = 2000;
mod.after.tick();
now = 2030;
mod.after.tick();           -- half a minute on the platform: no clock
now = 2040;
stand(0, course.start, 6);  -- off it
mod.after.tick();
now = 2075.5;
stand(0, course.tent);
spawns = {};
mod.after.tick();
check(#L.chat == 2 and L.chat[1].to == 0 and L.chat[1].text == "Finished in 35.50 s: your best time!",
	"35.5 s from leaving the platform, told to the runner");
check(L.chat[2].to == PID_BROADCAST and L.chat[2].text == "Runner0 holds the record: 35.50 s",
	"and to everybody, being the record");
check(#spawns == 1 and spawns[1].pid == 0 and math.abs(spawns[1].pos.x - c.start.x) <= 2,
	"the runner is put back at the start");
check(logged[#logged] == "parkour: Runner0 finished in 35.50 s", "the log has the run");

print("\n6. a slower run, a faster one, somebody else's");
L.reset();
now = 3000; stand(0, course.start, 6); mod.after.tick();
now = 3050; stand(0, course.tent); mod.after.tick();
check(#L.chat == 1 and L.chat[1].text == "Finished in 50.00 s. Your best is 35.50 s.", "slower: the best stands, no record");
L.reset();
now = 4000; stand(1, course.start, 6); mod.after.tick();
now = 4040; stand(1, course.tent); mod.after.tick();
check(#L.chat == 1 and L.chat[1].to == 1 and L.chat[1].text == "Finished in 40.00 s: your best time!",
	"another runner's best is his own, and not the record");
L.reset();
now = 5000; stand(2, course.start, 6); mod.after.tick();
now = 5030; stand(2, course.tent); mod.after.tick();
check(#L.chat == 1 and L.chat[1].to == PID_BROADCAST and L.chat[1].text == "Bot7 holds the record: 30.00 s",
	"a bot's run counts, and only the record is said");
check(players[2].alive and math.abs(players[2].pos.x - c.start.x) <= 2, "the bot is back at the start too");

print("\n7. checkpoints, and dying");
L.reset();
now = 6000; stand(0, course.start, 6); mod.after.tick();
now = 6010; stand(0, course.checkpoints[1]); mod.after.tick();
check(#L.chat == 1 and L.chat[1].text == "Checkpoint 1 of 3", "a checkpoint reached is told");
mod.after.tick();
check(#L.chat == 1, "once");
players[0].alive = false;
spawns = {};
mod.after.kill(0, 4, 0);
check(#spawns == 1 and players[0].alive and math.abs(spawns[1].pos.x - c.checkpoints[1].x) <= 2
	and spawns[1].pos.z == c.checkpoints[1].z - 2.251, "dead: back at once, at that checkpoint");
now = 6030; stand(0, course.tent); mod.after.tick();
check(L.chat[#L.chat].text == "Finished in 30.00 s: your best time!", "and the clock ran on through it");
now = 6040; stand(0, course.start, 6); mod.after.tick();
players[0].alive = false;
spawns = {};
mod.after.kill(0, 4, 0);
check(#spawns == 1 and math.abs(spawns[1].pos.x - c.start.x) <= 2, "a new run starts with no checkpoint: dead is the start again");
players[1].team = SPECTATOR;
spawns = {};
mod.after.kill(1, 6, 1);
check(#spawns == 0, "a runner gone to the spectators is not put back");
players[1].team = 1;

print("\n8. /best");
L.reset();
command.func(0);
check(#L.chat == 4 and L.chat[1].text == "1. Bot7: 30.00 s" and L.chat[2].text == "2. Runner0: 30.00 s"
	and L.chat[3].text == "3. Runner1: 40.00 s", "the best times, fastest first");
check(L.chat[4].text == "Your best: 30.00 s", "and the asker's own");

print("\n9. a new map: the best times stay, the runs start over");
mod.after.finish_map_load();
tent[1].z = course.tent.z;
L.reset();
command.func(1);
check(#L.chat == 4 and L.chat[4].text == "Your best: 40.00 s", "the times are still there");
players[0].alive = false;
spawns = {};
mod.after.kill(0, 4, 0);
check(math.abs(spawns[1].pos.x - c.start.x) <= 2, "and everybody is at the start");

print("\n9b. another course: the times start over");
local c2 = P.generate(2);
meta = {};
mod.after.pyscrape_ext(scrape, "\n" .. P.meta(c2, "parkour") .. "\n", meta);
mod.after.finish_map_load();
L.reset();
command.func(1);
check(#L.chat == 1 and L.chat[1].text == "Nobody has finished the course yet.", "nobody has run this one");

print("\n10. a map with no course: one team, nothing else, and no fault");
meta = {};
logged = {};
mod.after.finish_map_load();
check(string.find(logged[#logged] or "", "names no course") ~= nil, "the log says so");
hooks = {};
mod.get_spawn_position(0);
check(#hooks == 1 and hooks[1][1] == "get_spawn_position", "spawning is left to what is underneath");
L.reset();
mod.after.tick();
check(#L.chat == 0, "the tick does nothing");

L.clean(check);
print(string.format("\n%d passed, %d failed", passed, failed));
os.exit(failed == 0 and 0 or 1);
