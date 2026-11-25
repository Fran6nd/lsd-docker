-- range_test.lua -- the range gamemode: its targets, a lane's run, the IPSC queue
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/range_test.lua      (from the repository root)
--
-- The range is a real one: generated, its metadata read back through
-- upstream's own scraper as the server reads a map's .txt. The texts are
-- the real lib_l10n's, the floating numbers the real lib_damage_markers'.
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
	local m = {after = {}, before = {}, next = chain(), impl = {}};
	m.late = {after = {}, before = {}, next = chain()};
	return m;
end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
MAX_PLAYERS = 64;
PID_BROADCAST = 0x20000000;
SPECTATOR = 256;
local now = 1000;
function get_time() return now; end
local logged = {};
function log(fmt, ...) logged[#logged + 1] = string.format(fmt, ...); end

local L = dofile("tests/support/l10n_env.lua").load{};
L.pids = {0, 1, 2, 3};
function is_fakepid(pid) return pid >= MAX_PLAYERS and pid < PID_BROADCAST; end

-- people are 0..3; the bots lib_bot would make take 10 and up
local players = {};
for pid = 0, 3 do
	players[pid] = {name = "Shooter" .. pid, team = 1, alive = true, pos = {x = 0, y = 0, z = 0}, gun = 0, hp = 100};
end
local mod;
local bots, made, crouched, faced, teleports = {}, {}, {}, {}, {};
local seats = 100;
function bot_is_bot(pid) return bots[pid] ~= nil; end
function bot_get(pid) return bots[pid]; end
function bot_create(opts)
	if (seats <= 0) then return nil; end
	seats = seats - 1;
	local pid = 10;
	while (players[pid] ~= nil) do pid = pid + 1; end
	bots[pid] = {team = opts.team, name = opts.name, spawn_at = opts.spawn_at, silent = opts.silent,
		think = opts.think, data = opts.data or {}};
	players[pid] = {name = opts.name, team = opts.team, alive = false, pos = {x = 0, y = 0, z = 0}, gun = 0, hp = 100};
	made[#made + 1] = pid;
	return pid;
end
function bot_destroy(pid)
	if (bots[pid] == nil) then return; end
	bots[pid], players[pid] = nil, nil;
	seats = seats + 1;
	mod.after.on_disconnect(pid);
end
function bot_teleport(pid, pos) players[pid].pos = pos; teleports[#teleports + 1] = {pid = pid, pos = pos, at = now}; end
function bot_crouch(pid) crouched[pid] = true; end
function bot_stop(pid) crouched[pid] = nil; end
function bot_look_at(pid, pos) faced[pid] = pos; end
local linked = 0;
function botlink_add() linked = linked + 1; end

function is_connected(pid) return players[pid] ~= nil; end
function is_joined(pid) return players[pid] ~= nil; end
function is_alive(pid) return players[pid].alive; end
function get_team(pid) return players[pid].team; end
function get_next_team(pid) return players[pid].team; end
function get_gun(pid) return players[pid].gun; end
function get_name(pid) return players[pid].name; end
function get_hp(pid) return players[pid].hp; end
function get_position(pid) local p = players[pid].pos; return {x = p.x, y = p.y, z = p.z}; end
function piditer()
	local list = {};
	for pid in pairs(players) do list[#list + 1] = pid; end
	table.sort(list);
	local k = 0;
	return function() k = k + 1; return list[k]; end
end
local spawns = {};
function spawn_player(pid, pos)
	players[pid].alive, players[pid].pos = true, pos;
	spawns[#spawns + 1] = {pid = pid, pos = pos};
	mod.after.spawn_player(pid);
end
local moved = {};
function set_position(pid, pos) players[pid].pos = pos; moved[#moved + 1] = {pid = pid, pos = pos}; end
local refilled = {};
function restock(pid) refilled[pid] = (refilled[pid] or 0) + 1; end
function set_hp(pid, hp) players[pid].hp = hp; end

local intel, tent = {}, {};
function objgrav(p) return {x = p.x, y = p.y, z = 40}; end
function drop_move_intel(team, pos) intel[team] = pos; end
function move_tent(team, pos) tent[team] = pos; end

local listed, commands = nil, {};
function masterlist_set_gamemode(g) listed = g; end
function register_command(cmd) commands[cmd.name] = cmd; end

-- the real Damage Markers: pid 0 and 1 speak it
local packets = {};
function ext_supported(pid, id) return (pid == 0 or pid == 1) and id == 0x20 and 1 or nil; end
function ext_register() end
function send_packet(pid, data) packets[#packets + 1] = {pid = pid, data = data}; end
local dm = dofile("catalog/extensions/damage_markers/lib_damage_markers.lua");
dm.on_load();

-- upstream's scraper, for the metadata as the server reads it
local scrape = dofile("lsd/scripts/lib_pyscrape.lua");
local meta = {};
function get_map_meta() return meta; end

local R = require "range_map";
local range = R.generate(1);

-- nothing the mode does opens a file (the bot engine's link is one)
local real_open, opened = io.open, 0;
io.open = function(...) opened = opened + 1; return real_open(...); end

local function stand(pid, p, dx, dy)
	players[pid].pos = {x = p.x + 0.5 + (dx or 0), y = p.y + 0.5 + (dy or 0), z = p.z - 2.25};
end
local function mid(b) return {x = math.floor((b.x0 + b.x1) / 2), y = math.floor((b.y0 + b.y1) / 2), z = b.z}; end
local function tick(t) now = t or now; mod.after.tick(); end
local function texts(pid)
	local out = {};
	for _, c in ipairs(L.chat) do if (c.to == pid) then out[#out + 1] = c.text; end end
	return out;
end
local function last(pid) local t = texts(pid); return t[#t]; end

--============================= CHECKS ===============================--
print("\n1. loading, and a map that names a range");
map_web_random = true;
mod = dofile("catalog/gamemodes/range/range.lua");
function get_spawn_position(pid)
	local b = bots[pid];
	if (b ~= nil) then return b.spawn_at(pid); end
	return mod.get_spawn_position(pid);
end
mod.on_load();
check(listed == "range", "listed as range");
check(team_balance_max_diff == math.huge and map_web_random == false, "team_balance and vote_map are told");
check(commands.best ~= nil and commands.ipsc ~= nil, "/best and /ipsc are registered");

mod.after.pyscrape_ext(scrape, "\n" .. R.meta(range, "range") .. "\n", meta);
local r = meta.range;
check(r ~= nil and #r.lanes == R.LANES and #r.targets == #range.targets, #range.targets .. " targets, " .. R.LANES .. " lanes read");
local same = r ~= nil;
for k, t in ipairs(range.targets) do
	local u = r and r.targets[k];
	if (u == nil or u.set ~= t.set or u.stance ~= t.stance or u.motion ~= t.motion or u.param ~= t.param
	    or #u.points ~= #t.points or u.points[#u.points].x ~= t.points[#t.points].x or u.face.y ~= t.face.y) then
		same = false;
	end
end
check(same, "each one as the generator made it: set, stance, motion, pace, face and points");
check(r ~= nil and r.ipsc ~= nil and r.ipsc.start.x0 == range.ipsc.start.x0 and r.ipsc.wait.y1 == range.ipsc.wait.y1,
	"the IPSC course, its start, end and waiting area");
local bad = {};
mod.after.pyscrape_ext(scrape, "\nextensions = {\n    'range_spawn' : (1, 2, 50),\n    'range_targets' : (('lane9', 'stand', 'static', 0, (1, 1, 50), (2, 2, 50)), ('lane1', 'stand', 'rail', 0, (1, 1, 50), (2, 2, 50))),\n}\n", bad);
check(bad.range ~= nil and #bad.range.targets == 0, "a target of a lane the map lacks, or a rail with no pace, is left out");

mod.after.finish_map_load();
check(tent[1].x == range.spawn.x + 0.5 and intel[1].x == 0.5 and intel[2].x == 511.5, "the tent on the plaza, the intels in corners");

print("\n2. the targets: one each, where the map says, hidden, no engine");
seats = 20;
tick(1000);
check(#made == 20, "made while there are seats (20 here)");
tick(1000.5);
check(#made == 20, "and not tried again within the second");
seats = 100;
tick(1001);
check(#made == #r.targets, "the rest a second later: " .. #r.targets .. " targets");
local where, team2, hidden = true, true, true;
for _, pid in ipairs(made) do
	local k = bots[pid].data.range_target;
	local t = r.targets[k];
	local p = players[pid].pos;
	if (t.motion == "static" and (p.x ~= t.points[1].x + 0.5 or p.y ~= t.points[1].y + 0.5 or p.z ~= t.points[1].z - 2.251)) then
		where = false;
	end
	if ((t.stance == "crouch") ~= (crouched[pid] == true)) then where = false; end
	if (faced[pid] == nil or faced[pid].x ~= t.face.x + 0.5) then where = false; end
	if (players[pid].team ~= 2) then team2 = false; end
	local s = bots[pid].silent;
	if (not (s.roster and s.presence and s.killfeed and s.stats) or bots[pid].think ~= nil) then hidden = false; end
end
check(where, "each on its point at once (no respawn wait), standing or crouched, facing its firing position");
check(team2, "on team 2: the people's enemies, the only ones");
check(hidden, "hidden from roster, presence, kill feed and stats; no think");
check(linked == 0 and opened == 0, "no engine: nothing asked of lib_botlink, no file opened");
check(bots[made[1]].name == "L1 5m" and bots[made[7]].name == "L1 rail" and bots[made[8]].name == "L1 blink"
	and bots[made[#made]].name == "IPSC 50", "named for what they are: " .. bots[made[1]].name .. ", " .. bots[made[7]].name);

local function pid_of(set, motion, n)
	local i = 0;
	for _, pid in ipairs(made) do
		local t = r.targets[bots[pid].data.range_target];
		if (t.set == set and (motion == nil or t.motion == motion)) then
			i = i + 1;
			if (i == (n or 1)) then return pid, t; end
		end
	end
end

print("\n3. a hit: no death, a floating number, counted once");
hooks, packets = {}, {};
local tp = pid_of("lane1", "static", 2);
mod.damage_player_directional(tp, 49, {x = 0, y = 0, z = 0}, 0, 0);
check(#hooks == 0 and players[tp].hp == 100 and players[tp].alive, "the damage goes no further: full health, standing");
check(#packets == 1 and packets[1].pid == 0 and packets[1].data == string.char(0x60, tp, 49),
	"the shooter is sent a Damage Marker: 49 over that target");
packets = {};
mod.damage_player(tp, 100, 1, 1);
check(#packets == 1 and packets[1].pid == 1 and packets[1].data == string.char(0x60, tp, 100), "a head shot from another: 100, to him");
packets = {};
mod.damage_player_directional(tp, 30, {x = 0, y = 0, z = 0}, 0, 2);
check(#packets == 0 and #hooks == 0, "a client without the extension gets nothing, and the target still nothing");
mod.damage_player_directional(0, 20, {x = 0, y = 0, z = 0}, 3, 0);
check(#hooks == 1 and hooks[1][1] == "damage_player_directional", "a person's damage goes on as before");

print("\n4. a lane: the countdown, every target, the time");
L.reset();
local lane1 = r.lanes[1];
stand(0, mid(lane1));
refilled = {};
tick(2000);
check(last(0) == "Lane 1: 8 targets. The clock starts in 3 s.", "stepping into the bay: the lane, and the countdown");
check(refilled[0] == 1 and players[0].hp == 100, "health and ammunition made full");
mod.damage_player_directional(pid_of("lane1", "static", 1), 49, {}, 0, 0);
check(last(0) == "Lane 1: 8 targets. The clock starts in 3 s.", "a hit before the clock does not count");
stand(1, mid(lane1), 1);
tick(2001);
check(last(1) == "Lane 1 is in use.", "somebody else in that bay is told it is taken");
tick(2001.5);
check(#texts(1) == 1, "once");
tick(2003);
check(last(0) == "Go!", "three seconds later: go");
now = 2004;
mod.damage_player_directional(pid_of("lane1", "static", 1), 49, {}, 0, 0);
check(last(0) == "Hit: 1/8", "a hit counts");
mod.damage_player_directional(pid_of("lane1", "static", 1), 49, {}, 0, 0);
check(last(0) == "Hit: 1/8" and #texts(0) == 3, "the same target again does not");
mod.damage_player_directional(pid_of("lane2", "static", 2), 49, {}, 0, 0);
mod.damage_player_directional(pid_of("ipsc", "static", 1), 49, {}, 0, 0);
mod.damage_player_directional(pid_of("lane1", "static", 3), 50, {}, 2, 0);
mod.damage_player_directional(pid_of("lane1", "static", 4), 80, {}, 3, 0);
check(last(0) == "Hit: 1/8", "nor another lane's, the course's, a spade's or a grenade's");
for n = 2, 6 do mod.damage_player_directional(pid_of("lane1", "static", n), 49, {}, n % 2, 0); end
mod.damage_player_directional(pid_of("lane1", "rail"), 49, {}, 0, 0);
now = 2015.25;
logged = {};
mod.damage_player_directional(pid_of("lane1", "blink"), 49, {}, 0, 0);
local t0 = texts(0);
check(t0[#t0 - 1] == "Hit: 8/8" and t0[#t0] == "Every target down in 12.25 s: your best on the static range!",
	"the eighth: every target down in 12.25 s, from go");
check(L.chat[#L.chat].to == PID_BROADCAST and L.chat[#L.chat].text == "Shooter0 holds the static range record: 12.25 s",
	"the record, to everybody");
check(logged[1] == "range: Shooter0, static in 12.25 s", "and the log");
tick(2016);
check(#texts(0) == #t0, "standing on in the bay after a run: nothing more");
stand(1, mid(r.lanes[2]));
tick(2017);
check(last(1) == "Lane 2: 8 targets. The clock starts in 3 s.", "another lane at the same time");
stand(0, mid(lane1), 0, 6);
tick(2018);
check(#texts(0) == #t0, "stepping out after the run: nothing to say");
stand(0, mid(lane1));
tick(2019);
check(last(0) == "Lane 1: 8 targets. The clock starts in 3 s.", "and back in: another run");
tick(2022);
stand(0, mid(lane1), 0, -5);
tick(2023);
check(last(0) == "Run void: you left the firing position.", "leaving the line during a run voids it");
-- a slower run on lane 2
check(texts(1)[3] == "Go!", "lane 2 went at its own time");
for _, motion in ipairs({"static", "rail", "blink"}) do
	local n = motion == "static" and 6 or 1;
	for i = 1, n do mod.damage_player_directional(pid_of("lane2", motion, i), 49, {}, 0, 1); end
end
check(last(1) == "Every target down in 3.00 s: your best on the static range!",
	"lane 2's run, its own time: 3 s from its go");

print("\n5. the rail and the blink");
local rp, rt = pid_of("lane1", "rail");
local bp, bt = pid_of("lane1", "blink");
local xs = {};
for k = 0, 48 do
	tick(3000 + k * 0.125);
	xs[#xs + 1] = players[rp].pos.x;
end
local a, b = rt.points[1].x + 0.5, rt.points[2].x + 0.5;
local lo, hi, steady = math.huge, -math.huge, true;
for k, x in ipairs(xs) do
	lo, hi = math.min(lo, x), math.max(hi, x);
	if (k > 1) then
		local step = math.abs(x - xs[k - 1]);
		-- 2.5 a second, an eighth of a second a tick; a turn at an end is shorter
		if (step > 0.3126 or (step < 0.3124 and x ~= lo and x ~= hi and xs[k - 1] ~= lo and xs[k - 1] ~= hi
		    and math.abs(x - a) > 0.32 and math.abs(x - b) > 0.32)) then
			steady = false;
		end
	end
	if (players[rp].pos.y ~= rt.points[1].y + 0.5) then steady = false; end
end
check(lo >= a and hi <= b and hi - lo > 5, string.format("the rail target goes from end to end of its track (%.2f to %.2f)", lo, hi));
check(steady, "at a steady 2.5 blocks a second, on the track");
check(players[rp].pos.z == rt.points[1].z - 2.25, "standing on the floor");
teleports = {};
for k = 0, 23 do tick(4000 + k * 0.25); end
local jumps = {};
for _, e in ipairs(teleports) do if (e.pid == bp) then jumps[#jumps + 1] = e; end end
table.remove(jumps, 1);   -- the first: from where the rail's ticks left it
local order = true;
for k, e in ipairs(jumps) do
	local want = bt.points[1 + math.floor(e.at / bt.param) % #bt.points];
	if (e.pos.x ~= want.x + 0.5 or e.pos.y ~= want.y + 0.5) then order = false; end
	if (k > 1 and math.abs(e.at - jumps[k - 1].at - bt.param) > 1e-9) then order = false; end
end
check(#jumps == 4 and order, "the blinking one: from point to point in turn, every 1.5 s (" .. #jumps .. " jumps in 6 s)");
check(faced[bp] ~= nil and faced[bp].y == bt.face.y + 0.5, "facing its line after each");
local still = true;
for _, e in ipairs(teleports) do
	if (r.targets[bots[e.pid].data.range_target].motion == "static") then still = false; end
end
check(still, "the static ones never move");

print("\n6. the IPSC course: a queue, one inside");
L.reset();
for pid = 0, 3 do stand(pid, range.spawn, pid); end
tick(5000);
commands.ipsc.func(0);
tick(5000);
local I = r.ipsc;
local s = mid(I.start);
check(players[0].pos.x == s.x + 0.5 and players[0].pos.y == s.y + 0.5, "the first in the queue is put in the start box");
check(last(0) == "Your turn on the IPSC course: the clock starts when you leave the green start box and stops in the blue end box once every target is hit. 120 s at most.",
	"and told how it goes");
commands.ipsc.func(1);
check(last(1) == "You are number 1 in the IPSC queue.", "the second waits, first in the queue");
stand(2, mid(I.wait));
tick(5000.2);
check(last(2) == "You are number 2 in the IPSC queue.", "stepping onto the waiting area queues you too");
stand(3, mid(I.finish));
tick(5000.3);
local w = mid(I.wait);
check(players[3].pos.x == w.x + 0.5 and players[3].pos.y == w.y + 0.5 and last(3) == "The IPSC course is in use: you are number 3 in the queue.",
	"an intruder is sent to the waiting area, and queued");
commands.ipsc.func(3);
check(last(3) == "You left the IPSC queue." and #texts(3) == 2, "/ipsc again leaves the queue");
stand(0, mid(I.start), 0, -3);
tick(5001.5);
mod.damage_player_directional(pid_of("ipsc", "static", 1), 49, {}, 0, 0);
check(last(0) == "Hit: 1/10", "out of the start box: the clock runs, hits count");
stand(0, mid(I.finish));
tick(5010);
check(last(0) == "Targets still standing: 9", "in the end box with targets standing: told how many");
tick(5011);
check(last(0) == "Targets still standing: 9", "once");
for n = 2, 9 do mod.damage_player_directional(pid_of("ipsc", "static", n), 49, {}, 0, 0); end
mod.damage_player_directional(pid_of("ipsc", "rail"), 49, {}, 1, 0);
check(last(0) == "Every target hit: to the blue end box!", "every target hit: told to finish");
stand(0, mid(I.finish), 1);
tick(5021.5);
local t = texts(0);
check(t[#t] == "IPSC course in 20.00 s: your best!", "in the end box: 20 s from leaving the start box");
check(math.abs(players[0].pos.x - range.spawn.x - 0.5) <= 2, "and back on the plaza");
tick(5022);
check(players[1].pos.x == s.x + 0.5 and string.find(last(1), "^Your turn") ~= nil, "the next in the queue goes in");
players[1].alive = false;
mod.after.kill(1, 0, 1);
check(last(1) == "IPSC run abandoned: you died." and players[1].alive, "the shooter dies: abandoned, back on the plaza");
tick(5023);
check(players[2].pos.x == s.x + 0.5, "and the next goes in");
stand(2, mid(I.wait));
tick(5025);
check(last(2) == "IPSC run abandoned: you left the course.", "the shooter walks out: abandoned");
tick(5026);
commands.ipsc.func(0);
tick(5030);
check(players[0].pos.x == s.x + 0.5, "the course free, the next one in at once");
tick(5151);
check(last(0) == "IPSC run abandoned: over 120 s." and math.abs(players[0].pos.y - range.spawn.y - 0.5) <= 2,
	"over two minutes: abandoned, and sent out");
commands.ipsc.func(1);
tick(5152);
mod.after.on_disconnect(1);
players[1] = nil;
commands.ipsc.func(2);
tick(5153);
check(players[2].pos.x == s.x + 0.5, "a shooter who leaves the server frees the course");
players[1] = {name = "Shooter1", team = 1, alive = true, pos = {x = 0, y = 0, z = 0}, gun = 0, hp = 100};

print("\n7. /best");
L.reset();
commands.best.func(0);
local b0 = texts(0);
check(b0[1] == "Static range:" and string.find(b0[2] or "", "^1%. ") ~= nil and b0[#b0 - 1] == "Your best on the static range: 12.25 s"
	and b0[#b0] == "Your best on the IPSC course: 20.00 s", "both boards, and the asker's own");
local found = false;
for _, l in ipairs(b0) do if (l == "IPSC course:") then found = true; end end
check(found, "the IPSC board");

print("\n8. a new map: the same range keeps the times, another clears them");
local count = #made;
mod.after.finish_map_load();
L.reset();
commands.best.func(0);
check(last(0) == "Your best on the IPSC course: 20.00 s", "the same range: the times stay");
local n = 0;
for _ in pairs(bots) do n = n + 1; end
check(n == count, "the targets keep their seats");
meta = {};
mod.after.pyscrape_ext(scrape, "\n" .. R.meta(R.generate(2), "range") .. "\n", meta);
mod.after.finish_map_load();
L.reset();
commands.best.func(0);
check(texts(0)[2] == "No times yet.", "another range: nobody has a time on it");
meta = {};
logged = {};
mod.after.finish_map_load();
n = 0;
for _ in pairs(bots) do n = n + 1; end
check(n == 0 and string.find(logged[#logged] or "", "names no range") ~= nil, "a map with no range: the targets go, the log says why");
tick(6000);
check(true, "and the tick does nothing");

L.clean(check);
io.open = real_open;
print(string.format("\n%d passed, %d failed", passed, failed));
os.exit(failed == 0 and 0 or 1);
