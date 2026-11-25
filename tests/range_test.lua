-- range_test.lua -- the range gamemode: its targets, a lane's run, the IPSC course
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
-- what the mode logs through lib_l10n, in English, with the rest
function l10n_log(m, a) logged[#logged + 1] = m.en; end
function is_fakepid(pid) return pid >= MAX_PLAYERS and pid < PID_BROADCAST; end

-- people are 0..3; the bots lib_bot would make take 10 and up
local players = {};
for pid = 0, 3 do
	players[pid] = {name = "Shooter" .. pid, team = 1, alive = true, pos = {x = 0, y = 0, z = 0}, gun = 0, hp = 100};
end
local mod;
local bots, made, stood, crouched, faced, teleports, ori = {}, {}, {}, {}, {}, {}, {};
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
	if (opts.data.range_standin ~= nil) then stood[#stood + 1] = pid; else made[#made + 1] = pid; end
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
function bot_look_at(pid, pos) faced[pid] = pos; ori[pid] = {at = pos}; end
function bot_look_toward(pid, dir) ori[pid] = dir; end
function get_orientation(pid) return ori[pid]; end
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

-- the map's voxels: the generated range's, and what the server wrote over them
local R = require "range_map";
local range = R.generate(1);
local written, writes, colors = {}, {}, {};
local function vkey(p) return (p.z * 512 + p.y) * 512 + p.x; end
function is_solid(p)
	local w = written[vkey(p)];
	if (w ~= nil) then return w; end
	return R.solid(range, p.x, p.y, p.z);
end
function get_anon_pid() return 63; end
function set_block_color(pid, c) colors[#colors + 1] = {pid = pid, c = c}; end
function block_action(p, type, from)
	written[vkey(p)] = type == 0;
	writes[#writes + 1] = {x = p.x, y = p.y, z = p.z, type = type, from = from};
end
local reverted = {};
map_layout = {
	revert_action = function(pid, pos, type) reverted[#reverted + 1] = {pid = pid, pos = pos, type = type}; end,
	revert = function(pid, pos, type) reverted[#reverted + 1] = {pid = pid, pos = pos, type = type}; end,
};
function iter_block_line(a, b)
	local list, k = {a, b}, 0;
	return function() k = k + 1; return list[k]; end
end

-- a death: the core's kill(), and the hooks after it
local kills = {};
function kill(pid, type, killer)
	players[pid].alive = false;
	kills[#kills + 1] = {pid = pid, type = type, killer = killer};
	mod.after.kill(pid, type, killer);
end
function get_hit_damage(pid, type) return type == 1 and 100 or 49; end

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
-- the chain as the core runs it: a hit packet first, then the damage
function damage_player_directional(...) return mod.damage_player_directional(...); end
function get_spawn_position(pid)
	local b = bots[pid];
	if (b ~= nil) then return b.spawn_at(pid); end
	return mod.get_spawn_position(pid);
end
mod.on_load();
check(listed == "range", "listed as range");
check(team_balance_max_diff == math.huge and map_web_random == false, "team_balance and vote_map are told");
check(commands.best ~= nil and commands.ipsc ~= nil, "/best and /ipsc are registered");
check(gamemode_rewards == false, "it gives no rewards: says so to lib_rewards (gamemode_rewards)");
check(range_noshoot_penalty == 10, "a no-shoot hit costs 10 s, a setting (range_noshoot_penalty)");

mod.after.pyscrape_ext(scrape, "\n" .. R.meta(range, "range") .. "\n", meta);
local r = meta.range;
check(r ~= nil and #r.lanes == R.LANES and #r.targets == #range.targets, #range.targets .. " targets, " .. R.LANES .. " lanes read");
local same = r ~= nil;
for k, t in ipairs(range.targets) do
	local u = r and r.targets[k];
	if (u == nil or u.set ~= t.set or u.kind ~= t.kind or u.stance ~= t.stance or u.motion ~= t.motion or u.param ~= t.param
	    or #u.points ~= #t.points or u.points[#u.points].x ~= t.points[#t.points].x or u.face.y ~= t.face.y) then
		same = false;
	end
end
check(same, "each one as the generator made it: set, kind, stance, motion, pace, face and points");
check(r ~= nil and r.ipsc ~= nil and r.ipsc.start.x0 == range.ipsc.start.x0 and r.ipsc.wait.y1 == range.ipsc.wait.y1,
	"the IPSC course, its start, end and waiting area");
local W = r.ipsc.wall;
local GW = range.ipsc.wall;
check(W ~= nil and W.x0 == GW.x0 and W.x1 == GW.x1 and W.y0 == GW.y0 and W.z0 == GW.z0 and W.z1 == GW.z1
	and W.color.r == GW.color[1] and W.color.b == GW.color[3], "its start wall: the voxels and the colour");
check(r.count.ipsc == 10 and r.count.lane1 == 8, "a run counts the targets, not the no-shoots (10 on the course)");
local bad = {};
mod.after.pyscrape_ext(scrape, "\nextensions = {\n    'range_version' : 3,\n    'range_cell' : (1, 1, 3, 3, 50),\n    'range_spawn' : (1, 2, 50),\n    'range_targets' : (('lane9', 'plate', 'stand', 'static', 0, (1, 1, 50), (2, 2, 50)), ('lane1', 'plate', 'stand', 'rail', 0, (1, 1, 50), (2, 2, 50)), ('lane1', 'brick', 'stand', 'static', 0, (1, 1, 50), (2, 2, 50))),\n}\n", bad);
check(bad.range ~= nil and #bad.range.targets == 0, "a target of a lane the map lacks, a rail with no pace or a kind unknown is left out");
local old = {};
mod.after.pyscrape_ext(scrape, "\nextensions = {\n    'range_spawn' : (1, 2, 50),\n    'range_targets' : (('lane1', 'stand', 'static', 0, (1, 1, 50), (2, 2, 50)),),\n}\n", old);
check(old.range == nil and string.find(logged[#logged] or "", "older version") ~= nil,
	"a range of an older generator: none, and the log says to generate another");

mod.after.finish_map_load();
check(tent[1].x == range.spawn.x + 0.5 and intel[1].x == 0.5 and intel[2].x == 511.5, "the tent on the plaza, the intels in corners");

local C = r.cell;
local function in_cell(pid)
	local p = players[pid].pos;
	return p.x > C.x0 and p.x < C.x1 + 1 and p.y > C.y0 and p.y < C.y1 + 1 and p.z < C.z and p.z > C.z - 3;
end
print("\n2. the targets: one each, where the map says, hidden, no engine");
seats = 20;
tick(1000);
check(#made == 20, "made while there are seats (20 here)");
tick(1000.5);
check(#made == 20, "and not tried again within the second");
seats = 200;
tick(1001);
check(#made == #r.targets, "the rest a second later: " .. #r.targets .. " targets");
local where, teams, hidden = true, true, true;
for _, pid in ipairs(made) do
	local k = bots[pid].data.range_target;
	local t = r.targets[k];
	local p = players[pid].pos;
	if (t.motion == "static" and (p.x ~= t.points[1].x + 0.5 or p.y ~= t.points[1].y + 0.5 or p.z ~= t.points[1].z - 2.251)) then
		where = false;
	end
	if ((t.stance == "crouch") ~= (crouched[pid] == true)) then where = false; end
	if (faced[pid] == nil or faced[pid].x ~= t.face.x + 0.5) then where = false; end
	if (players[pid].team ~= (t.kind == "noshoot" and 1 or 2)) then teams = false; end
	local s = bots[pid].silent;
	if (not (s.roster and s.presence and s.killfeed and s.stats) or bots[pid].think ~= nil) then hidden = false; end
end
check(where, "each on its point at once (no respawn wait), standing or crouched, facing its firing position");
check(teams, "targets on team 2, the people's enemies; no-shoots on team 1, the people's own");
check(#stood == 50 and r.cell ~= nil and r.cell.x0 == range.cell.x0, "a stand-in for each of the 40 plates and 10 poppers, none for a no-shoot: 50 more seats");
local st_ok = true;
for _, sp in ipairs(stood) do
	local t = r.targets[bots[sp].data.range_standin];
	local s = bots[sp].silent;
	if (players[sp].team ~= 1 or t.kind == "noshoot" or not in_cell(sp) or bots[sp].think ~= nil
	    or not (s.roster and s.presence and s.killfeed and s.stats)
	    or (t.stance == "crouch") ~= (crouched[sp] == true)) then
		st_ok = false;
	end
end
check(st_ok, "the stand-ins: the shooters' team, silent, no think, crouched as the target is, waiting in the holding cell");
local tin = true;
for _, pid in ipairs(made) do if (in_cell(pid)) then tin = false; end end
check(tin, "and the targets out on the range, not in the cell");
check(hidden, "hidden from roster, presence, kill feed and stats; no think");
check(linked == 0 and opened == 0, "no engine: nothing asked of lib_botlink, no file opened");
check(bots[made[1]].name == "L1 5m" and bots[made[7]].name == "L1 rail" and bots[made[8]].name == "L1 blink"
	and bots[made[#made - 4]].name == "IPSC 10" and bots[made[#made]].name == "No-shoot 4",
	"named for what they are: " .. bots[made[1]].name .. ", " .. bots[made[7]].name .. ", " .. bots[made[#made]].name);

local function pid_of(set, motion, n, kind)
	local i = 0;
	for _, pid in ipairs(made) do
		local t = r.targets[bots[pid].data.range_target];
		if (t.set == set and (motion == nil or t.motion == motion) and (t.kind == "noshoot") == (kind == "noshoot")) then
			i = i + 1;
			if (i == (n or 1)) then return pid, t; end
		end
	end
end
local function noshoot(n) return pid_of("ipsc", nil, n, "noshoot"); end
-- a target's stand-in, and where each is: out on the range, or in the holding cell
local function standin_of(pid)
	local k = bots[pid].data.range_target;
	for _, sp in ipairs(stood) do if (bots[sp].data.range_standin == k) then return sp; end end
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
check(logged[1] == "range: Shooter0, static in 12.25 s (0 no-shoot hits)", "and the log");
local standing = true;
for _, motion in ipairs({"static", "rail", "blink"}) do
	if (not players[pid_of("lane1", motion)].alive) then standing = false; end
end
check(standing and #kills == 0, "plates: every one hit, every one standing");
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
check(players[rp].pos.z == rt.points[1].z - 2.251, "standing on the floor, as a spawn puts a body");
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

print("\n6. the IPSC course: a queue, one inside, behind the start wall");
L.reset();
local function wall_voxels(f)
	for z = W.z0, W.z1 do
		for y = W.y0, W.y1 do
			for x = W.x0, W.x1 do f({x = x, y = y, z = z}); end
		end
	end
end
local function wall_standing()
	local all = true;
	wall_voxels(function(p) if (not is_solid(p)) then all = false; end end);
	return all;
end
local function wall_gone()
	local none = true;
	wall_voxels(function(p) if (is_solid(p)) then none = false; end end);
	return none;
end
local function course_up()
	local up = true;
	for k, t in ipairs(r.targets) do
		if (t.set == "ipsc") then
			local pid;
			for p, b in pairs(bots) do if (b.data.range_target == k) then pid = p; end end
			local at = pid and players[pid].pos;
			if (pid == nil or not players[pid].alive or faced[pid] == nil or faced[pid].x ~= t.face.x + 0.5
			    or (t.motion == "static" and (at.x ~= t.points[1].x + 0.5 or at.y ~= t.points[1].y + 0.5))) then
				up = false;
			end
		end
	end
	return up;
end

for pid = 0, 3 do stand(pid, range.spawn, pid); end
tick(5000);
check(wall_standing(), "the start wall stands, as the map has it");
commands.ipsc.func(0);
tick(5000);
local I = r.ipsc;
local s = mid(I.start);
check(players[0].pos.x == s.x + 0.5 and players[0].pos.y == s.y + 0.5 and s.y > W.y0,
	"the first in the queue is put in the start box, behind the wall");
check(last(0) == "Your turn on the IPSC course: the wall in front of you comes down when the course is ready, and the clock starts then. Every target down, then to the blue end box; each hit on a no-shoot (your own team) costs 10 s. 120 s at most.",
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
local p1 = pid_of("ipsc", "static", 1);
mod.damage_player_directional(p1, 49, {}, 0, 0);
tick(5002);
check(string.find(last(0), "^Your turn") ~= nil and players[p1].alive and wall_standing(),
	"before the wall falls: a hit counts for nothing, nothing falls, the wall stands");

-- somebody else on the course: not ready
stand(3, mid(I.finish));
tick(5003);
check(wall_standing() and string.find(last(0), "^Your turn") ~= nil, "somebody else on the course: the wall waits");
commands.ipsc.func(3);
-- a target missing (its seat taken): not ready
local ns1 = noshoot(1);
seats = 0;
bot_destroy(ns1);
tick(5003.5);
check(wall_standing(), "a target of the course missing: the wall waits");
seats = 100;
writes = {};
tick(5005);
check(players[ns1] ~= nil and players[ns1].alive and wall_gone() and last(0) == "Go!",
	"made again, and all ready: the wall comes down, go");
local first, ends = writes[1], true;
local n_ends = (W.z1 - W.z0 + 1) * 2;
for k = 1, n_ends do
	local e = writes[k];
	if (e.type ~= 1 or (e.x ~= W.x0 and e.x ~= W.x1) or e.from ~= 63) then ends = false; end
end
local bottom = true;
for k = n_ends + 1, n_ends + (W.x1 - W.x0 - 1) do
	if (writes[k].z ~= W.z1 or writes[k].type ~= 1) then bottom = false; end
end
check(first ~= nil and ends and bottom, "by the server, a block at a time: both ends first, then the bottom row (the rest falls)");

print("\n6b. the run: targets go down, no-shoots cost");
packets, hooks, kills = {}, {}, {};
now = 5006;
mod.damage_player_directional(p1, 49, {}, 0, 0);
local sp1 = standin_of(p1);
check(last(0) == "Hit: 1/10", "a hit: counted");
check(#kills == 0 and players[p1].alive and gamemode_rewards == false,
	"nothing is killed: no kill for anybody, no feed line, no reward, the target alive");
check(in_cell(p1) and not in_cell(sp1) and players[sp1].team == 1,
	"the popper is in the holding cell and a stand-in of the shooter's team has its place: it reads as down");
check(#packets == 1 and packets[1].data == string.char(0x60, p1, 49), "the shooter is shown the hit");
check(#hooks == 0, "the damage goes no further");
tick(5007);
tick(5010);
check(in_cell(p1) and not in_cell(sp1), "it stays down: swapped back by nothing but the end of the run");
check(mod.get_spawn_time(p1) == 0 and mod.get_spawn_time(sp1) == 0, "nothing respawns either, nor the engine");
check(#hooks == 0 and mod.get_spawn_time(0) == nil and hooks[1][1] == "get_spawn_time", "a person's respawn is the chain's");
hooks, packets = {}, {};
local ns2 = noshoot(2);
check(players[ns2].team == 1, "a no-shoot is on the shooter's team");
mod.late.on_hit(0, 0, ns2);
check(last(0) == "No-shoot hit: +10 s" and players[ns2].alive, "a no-shoot hit: told at once, and it stands");
check(#packets == 1 and packets[1].data == string.char(0x60, ns2, 49), "a marker over it");
check(#hooks == 1 and hooks[1][1] == "on_hit", "the hit goes on to the core, which drops a team's own");
mod.late.on_hit(0, 1, ns2);
local t = texts(0);
check(t[#t] == "No-shoot hit: +10 s" and t[#t - 1] == "No-shoot hit: +10 s", "every hit is one more");
hooks = {};
local p2 = pid_of("ipsc", "static", 2);
mod.late.on_hit(0, 0, p2);
check(players[p2].alive and #hooks == 1 and last(0) == "No-shoot hit: +10 s",
	"an enemy target's hit is the core's to send on: nothing done twice");
stand(0, mid(I.finish));
tick(5012);
check(last(0) == "Targets still standing: 9", "in the end box with targets standing: told how many");
tick(5013);
check(last(0) == "Targets still standing: 9", "once");
for n = 2, 9 do mod.damage_player_directional(pid_of("ipsc", "static", n), 49, {}, 0, 0); end
mod.damage_player_directional(pid_of("ipsc", "rail"), 49, {}, 1, 0);
check(last(0) == "Every target hit: to the blue end box!", "every target hit: told to finish");
local alive = 0;
for n = 1, 9 do if (not in_cell(pid_of("ipsc", "static", n))) then alive = alive + 1; end end
check(alive == 0 and in_cell(pid_of("ipsc", "rail")), "every one of them down: all ten swapped for a stand-in");
stand(0, mid(I.finish), 1);
writes, colors = {}, {};
tick(5020.5);
t = texts(0);
check(t[#t - 1] == "15.50 s + 20 s penalty = 35.50 s" and t[#t] == "IPSC course in 35.50 s: your best!",
	"in the end box: 15.5 s on the clock from the wall's fall, 20 s of penalty, 35.5 s");
check(L.chat[#L.chat].to == PID_BROADCAST and L.chat[#L.chat].text == "Shooter0 holds the IPSC record: 35.50 s",
	"the boards rank by the whole of it");
check(math.abs(players[0].pos.x - range.spawn.x - 0.5) <= 2, "and back on the plaza");
check(course_up(), "the course made ready at once: every target standing in its place, facing its position");
check(wall_standing() and #colors >= 1 and colors[1].c == W.color and writes[1].type == 0 and writes[1].z == W.z1,
	"and the wall built again, in its colour, from the bottom up");
tick(5021);
check(players[1].pos.x == s.x + 0.5 and string.find(last(1), "^Your turn") ~= nil and wall_standing(),
	"the next in the queue goes in, behind the wall");
tick(5024);
check(last(1) == "Go!" and wall_gone(), "the course ready: down it comes");
now = 5025;
mod.damage_player_directional(p1, 49, {}, 0, 1);
check(in_cell(p1), "a target down");
players[1].alive = false;
mod.after.kill(1, 0, 1);
check(last(1) == "IPSC run abandoned: you died." and players[1].alive, "the shooter dies: abandoned, back on the plaza");
check(course_up() and wall_standing(), "the course ready again: the target up, the wall built");
tick(5026);
check(players[2].pos.x == s.x + 0.5, "and the next goes in");
stand(2, mid(I.wait));
tick(5028);
check(last(2) == "IPSC run abandoned: you left the course." and wall_standing(), "the shooter walks out: abandoned");
tick(5029);
commands.ipsc.func(0);
tick(5030);
check(players[0].pos.x == s.x + 0.5, "the course free, the next one in at once");
tick(5033);
check(last(0) == "Go!", "go");
tick(5153);
check(last(0) == "Go!", "two minutes from the wall's fall: still on");
tick(5153.5);
check(last(0) == "IPSC run abandoned: over 120 s." and math.abs(players[0].pos.y - range.spawn.y - 0.5) <= 2
	and wall_standing(), "over two minutes: abandoned, sent out, the wall built again");
commands.ipsc.func(1);
tick(5154);
mod.after.on_disconnect(1);
players[1] = nil;
check(wall_standing(), "a shooter who leaves the server: the course made ready");
commands.ipsc.func(2);
tick(5155);
check(players[2].pos.x == s.x + 0.5, "and free for the next");
mod.after.on_disconnect(2);
players[2] = {name = "Shooter2", team = 1, alive = true, pos = {x = 0, y = 0, z = 0}, gun = 0, hp = 100};
players[1] = {name = "Shooter1", team = 1, alive = true, pos = {x = 0, y = 0, z = 0}, gun = 0, hp = 100};

print("\n6c. nothing a player has breaks the wall, or anything");
reverted, hooks, writes = {}, {}, {};
L.reset();
local wp = {x = W.x0 + 5, y = W.y0, z = W.z1};
mod.late.on_block_action(0, wp, 1);
check(#reverted == 1 and reverted[1].pos == wp and #hooks == 0 and is_solid(wp) and last(0) == "No building or digging on the range.",
	"a bullet's or a spade's: refused, put back on the client");
mod.late.on_block_line(0, {x = 1, y = 1, z = 40}, {x = 2, y = 1, z = 40});
check(#reverted == 3 and reverted[3].type == 0 and #hooks == 0, "a line of blocks: every one taken back");
mod.block_action(wp, 3, 0);
check(#hooks == 0 and is_solid(wp), "a grenade: no crater");
mod.block_action(wp, 1, 63);
check(#hooks == 1 and hooks[1][1] == "block_action", "the server's own writes go through");

print("\n7. /best");
L.reset();
commands.best.func(0);
local b0 = texts(0);
check(b0[1] == "Static range:" and string.find(b0[2] or "", "^1%. ") ~= nil and b0[#b0 - 1] == "Your best on the static range: 12.25 s"
	and b0[#b0] == "Your best on the IPSC course: 35.50 s", "both boards, and the asker's own");
local found = false;
for _, l in ipairs(b0) do if (l == "IPSC course:") then found = true; end end
check(found, "the IPSC board");

print("\n7b. a flip: the plate swapped for a stand-in, five seconds, and back")
L.reset();
local function at_place(pid, t, p)
	p = p or t.points[1];
	local q = players[pid].pos;
	return q.x == p.x + 0.5 and q.y == p.y + 0.5 and q.z == p.z - (t.stance == "crouch" and 1.351 or 2.251);
end
check(range_flip_secs == 5, "five seconds, a setting (range_flip_secs)");
for pid = 0, 3 do stand(pid, range.spawn, pid); end
tick(7000);
local fp, ft = pid_of("lane3", "static", 2);        -- crouched, 10 m
local fs = standin_of(fp);
check(ft.stance == "crouch" and crouched[fp] and crouched[fs], "a crouched plate, and its stand-in crouched as well");
local was = ori[fp];
now = 7000;
packets, hooks, kills = {}, {}, {};
mod.damage_player_directional(fp, 49, {}, 0, 0);
check(in_cell(fp) and at_place(fs, ft) and players[fs].team == 1 and players[fp].team == 2,
	"a hit: the plate is in the holding cell, a team 1 stand-in in its exact place");
check(ori[fs] == was and #kills == 0 and players[fp].alive, "with its facing, and nothing killed");
check(#packets == 1 and #hooks == 0, "the shooter is shown the hit; the damage goes no further");
tick(7004.9);
check(in_cell(fp) and at_place(fs, ft), "four and nine tenths seconds on: still flipped");
tick(7005);
check(at_place(fp, ft) and in_cell(fs) and ori[fp] == was, "five seconds: swapped back, same place, pose and facing");
check(crouched[fp] and crouched[fs], "poses unchanged");

-- the stand-in is not a target
now = 7006;
mod.damage_player_directional(fp, 49, {}, 0, 0);
L.reset(); packets, hooks = {}, {};
mod.damage_player_directional(fs, 49, {}, 0, 0);
mod.damage_player(fs, 100, 1, 0);
mod.late.on_hit(0, 0, fs);
check(#packets == 0 and #texts(0) == 0 and #hooks == 1 and hooks[1][1] == "on_hit" and players[fs].hp == 100,
	"a hit on a stand-in: no marker, no count, no penalty (not a no-shoot), nothing; the chain below sees only the core's own")
check(at_place(fs, ft) and in_cell(fp), "and it does not flip back early");
check(bots[fs].think == nil and mod.get_spawn_time(fs) == 0, "it never thinks or shoots: no think, a spade");
tick(7011);
local flipped_before = #teleports;

-- a run: every plate flipped counts, none counts twice, a plate flips again
L.reset();
local lane3 = r.lanes[3];
stand(0, mid(lane3));
tick(7100);
tick(7103);
check(last(0) == "Go!", "a run on lane 3");
now = 7104;
for n = 1, 5 do mod.damage_player_directional(pid_of("lane3", "static", n), 49, {}, 0, 0); end
mod.damage_player_directional(pid_of("lane3", "static", 6), 49, {}, 0, 0);
mod.damage_player_directional(pid_of("lane3", "rail"), 49, {}, 0, 0);
check(last(0) == "Hit: 7/8", "seven hit, seven flipped");
local nt = #texts(0);
mod.damage_player_directional(pid_of("lane3", "static", 1), 49, {}, 0, 0);
check(#texts(0) == nt, "a flipped one cannot be hit: the stand-in has its place, and counts for nothing");
now = 7106;
mod.damage_player_directional(pid_of("lane3", "blink"), 49, {}, 0, 0);
local t3 = texts(0);
check(t3[#t3 - 1] == "Hit: 8/8", "the eighth: the run is complete although the first have flipped back");
tick(7109.5);
tick(7111);
local back = true;
for n = 1, 6 do local pid, t = pid_of("lane3", "static", n); if (not at_place(pid, t) or in_cell(pid)) then back = false; end end
check(back, "five seconds on: they all stand again in their places");
nt = #texts(0);
local again = pid_of("lane3", "static", 3);
mod.damage_player_directional(again, 49, {}, 0, 0);
check(in_cell(again) and at_place(standin_of(again), r.targets[bots[again].data.range_target]) and #texts(0) == nt,
	"shot again after it flipped back: it flips again (feedback), and does not count again");
tick(7116.1);

-- a rail plate's stand-in goes along the rail; a blink's follows the blink
local rp2, rt2 = pid_of("lane4", "rail");
local rs = standin_of(rp2);
now = 7200;
tick(7200);
mod.damage_player_directional(rp2, 49, {}, 0, 0);
local xs2, ok2 = {}, true;
for k = 1, 8 do
	tick(7200 + k * 0.125);
	xs2[k] = players[rs].pos.x;
end
for k = 2, 8 do if (math.abs(math.abs(xs2[k] - xs2[k - 1]) - 0.3125) > 1e-6) then ok2 = false; end end
check(ok2 and in_cell(rp2), "a rail plate flipped: its stand-in goes along the rail at the rail's pace, the plate waits in the cell")
tick(7205.125);
check(in_cell(rs) and not in_cell(rp2) and players[rp2].pos.y == rt2.points[1].y + 0.5, "and the plate is back on the rail when the time is up");
local bp2, bt2 = pid_of("lane4", "blink");
local bs = standin_of(bp2);
tick(7300);
mod.damage_player_directional(bp2, 49, {}, 0, 0);
local seen, onpts = {}, true;
for k = 0, 23 do
	tick(7300 + k * 0.2);
	local q = players[bs].pos;
	local hit = false;
	for _, p in ipairs(bt2.points) do if (q.x == p.x + 0.5 and q.y == p.y + 0.5) then hit = true; seen[p.x] = true; end end
	if (not hit) then onpts = false; end
end
local nseen = 0;
for _ in pairs(seen) do nseen = nseen + 1; end
check(onpts and nseen >= 2 and faced[bs] ~= nil and faced[bs].y == bt2.face.y + 0.5,
	"a blink plate flipped: its stand-in blinks from point to point, facing its line");

-- no seat for a stand-in: the plate does not flip, the hit counts, the log says so
local ap, at_ = pid_of("lane5", "static", 1);
local as = standin_of(ap);
seats = 0;
bot_destroy(as);
logged = {};
packets = {};
mod.damage_player_directional(ap, 49, {}, 0, 0);
check(not in_cell(ap) and #packets == 1 and string.find(logged[1] or "", "no stand%-in") ~= nil,
	"a stand-in missing (the server full): the plate stays, the marker is shown, a line in the log, no error");
seats = 200;
tick(7400);
tick(7401);
local made_again = false;
for _, sp in ipairs(stood) do if (bots[sp] ~= nil and bots[sp].data.range_standin == bots[ap].data.range_target) then made_again = true; end end
check(made_again, "and made again a second later");

-- a popper hit outside a run does not flip: only the run's shooter's hit falls it
local op = pid_of("ipsc", "static", 3);
mod.damage_player_directional(op, 49, {}, 0, 0);
check(not in_cell(op), "a popper hit by one who is not on the course: nothing happens to it");

print("\n8. a new map: the same range keeps the times, another clears them");
local count = 0;   -- a seat each, and a stand-in's for the plates and poppers
for _ in pairs(bots) do count = count + 1; end
check(count == #r.targets + 50, "54 targets and 50 stand-ins: 104 seats");
mod.after.finish_map_load();
L.reset();
commands.best.func(0);
check(last(0) == "Your best on the IPSC course: 35.50 s", "the same range: the times stay");
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
mod.on_unload();
check(gamemode_rewards == nil, "unloaded: rewards are the setting's again");

L.clean(check);
io.open = real_open;
print(string.format("\n%d passed, %d failed", passed, failed));
os.exit(failed == 0 and 0 or 1);
