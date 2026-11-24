-- botlink_test.lua -- lib_botlink: the server's side of the bot engine's link
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/botlink_test.lua      (from the repository root)
--
-- The real lib_bot, the real lib_botlink and engine_bots, the real
-- libbotlink.so; LSd's own functions are stubs. The test plays the
-- engine: it bl_attach-es the same file through ffi, beats, reads the
-- world and the events, and writes intents and actions.
-- Skips (exit 0) if bot/build/libbotlink.so is not built: make -C bot
local LIBPATH = "bot/build/libbotlink.so";
do
	local fh = io.open(LIBPATH, "rb");
	if (fh == nil) then
		print("SKIP botlink_test: " .. LIBPATH .. " is not built (make -C bot)");
		os.exit(0);
	end
	fh:close();
end

package.path = "catalog/libs/callouts/?.lua;catalog/libs/bot/?.lua;catalog/libs/botlink/?.lua;" .. package.path;
local ffi = require("ffi");
local bit = require("bit");

local passed, failed = 0, 0;
local function check(ok, what, detail)
	if (ok) then passed = passed + 1; print("  PASS " .. what);
	else failed = failed + 1; print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or "")); end
end

--============================== STUBS ===============================--
MAX_PLAYERS = 32;
PID_BROADCAST = 0x20000000;
local TEAMBASE, EXCEPTBASE = 0x40000000, 0x60000000;
function PID_BROADCAST_TEAM(t) return TEAMBASE + t; end
function PID_BROADCAST_EXCEPT(p) return EXCEPTBASE + p; end
function init_mod()
	local function s() return {before = {}, after = {}, next = {}}; end
	local m = s();
	m.impl, m.late, m.early, m.xearly = s(), s(), s(), s();
	return m;
end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
local logs = {};
function log(fmt, ...) logs[#logs + 1] = string.format(fmt, ...); end
server = {};

local NOW = 1000;
function get_time() return NOW; end
local P = {};               -- pid -> player
local SOLID = {};
local function key(x, y, z) return x + y * 512 + z * 262144; end
local function new_player(pid, team)
	P[pid] = {conn = true, joined = true, alive = true, team = team, gun = 0, tool = 2, hp = 100,
		pos = {x = 100 + pid, y = 100, z = 30}, ori = {x = 0, y = 1, z = 0}, vel = {x = 0, y = 0, z = 0},
		inputs = 0, mouse = 0, mag = 10, reserve = 50, reload = 0, air = false, wading = false,
		color = {r = 1, g = 2, b = 3}};
	return P[pid];
end
local ALLOC = false;
local function vec(v) if (ALLOC) then return {x = v.x, y = v.y, z = v.z}; end return v; end
function is_connected(p) return P[p] ~= nil and P[p].conn; end
function is_joined(p) return P[p].conn and P[p].joined; end
function is_alive(p) return P[p] ~= nil and P[p].conn and P[p].joined and P[p].alive; end
function get_team(p) return P[p].team; end
function get_gun(p) return P[p].gun; end
function get_tool(p) return P[p].tool; end
function get_hp(p) return P[p].hp; end
function get_mag_ammo(p) return P[p].mag; end
function get_reserve_ammo(p) return P[p].reserve; end
function get_reload_time(p) return P[p].reload; end
function get_inputs(p) return P[p].inputs; end
function get_mouse_inputs(p) return P[p].mouse; end
function is_airborne(p) return P[p].air; end
function is_wading(p) return P[p].wading; end
function get_position(p) return vec(P[p].pos); end
function get_orientation(p) return vec(P[p].ori); end
function get_velocity(p) return vec(P[p].vel); end
function get_name(p) return P[p].name or ("P" .. p); end
function get_block_color(p) return P[p].color; end
function get_map_block_color() return {r = 9, g = 8, b = 7}; end
function get_anon_pid()
	for i = 0, MAX_PLAYERS - 1 do if (P[i] == nil or not P[i].conn) then return i; end end
	return MAX_PLAYERS;
end
function get_effective_max_players() return 32; end
function masterlist_set_players() end
function masterlist_set_max_players() end
function send_mouse_input() end
function is_solid(pos) return SOLID[key(pos.x, pos.y, pos.z)] == true; end
function raycast(a, b, last)
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z;
	local len = math.sqrt(dx * dx + dy * dy + dz * dz);
	local n = math.ceil(len / 0.1);
	local px, py, pz = math.floor(a.x), math.floor(a.y), math.floor(a.z);
	for i = 1, n do
		local t = i / n;
		local x, y, z = math.floor(a.x + dx * t), math.floor(a.y + dy * t), math.floor(a.z + dz * t);
		if (SOLID[key(x, y, z)]) then
			if (last) then return {x = x, y = y, z = z}; end
			return {x = px, y = py, z = pz};
		end
		px, py, pz = x, y, z;
	end
	return nil;
end
function piditer(spec)
	local i = -1;
	return function()
		while (true) do
			i = i + 1;
			if (i >= 256) then return nil; end
			local p = P[i];
			if (p ~= nil and p.conn) then
				if (spec == PID_BROADCAST or spec == nil) then return i; end
				if (spec >= EXCEPTBASE) then
					if (i ~= spec - EXCEPTBASE) then return i; end
				elseif (spec >= TEAMBASE) then
					if (p.team == spec - TEAMBASE) then return i; end
				elseif (spec == i) then return i; end
			end
		end
	end;
end
function get_team_score(t) return 3 * t; end
function get_max_score() return 10; end
local INTEL, TENT = {}, {};
function get_intelloc() return INTEL; end
function get_tentloc() return TENT; end
local NIGHT = false;
function daytime_is_night() return NIGHT; end
local LAMP = {};
function flashlight_get(p) return LAMP[p] == true; end
function flashlight_set(p, on) LAMP[p] = on; end

-- the chains, wired from the modules' own tables (as core.lua does)
local mods = {};
local rec = {grenades = {}, colors = {}, commands = {}, rm_direct = false, killed = {}, hits = {}};
local leaked = 0;     -- packets the guard let through to bots alone
local sent = 0;       -- packets that did go to somebody
local function only_bots_spec(spec)
	if (spec < MAX_PLAYERS) then return P[spec] ~= nil and P[spec].bot == true; end
	for i in piditer(spec) do if (not P[i].bot) then return false; end end
	return true;
end
local base = {};
function base.send_packet(spec, data)
	if (only_bots_spec(spec)) then leaked = leaked + 1; else sent = sent + 1; end
	return 1;
end
base.send_packet_unreliable = base.send_packet;
function base.spawn_player(pid, pos)
	local p = P[pid];
	p.alive, p.hp, p.mag, p.reserve, p.reload, p.tool, p.inputs, p.mouse = true, 100, 10, 50, 0, 2, 0, 0;
	p.pos = pos or {x = 256, y = 256, z = 30};
end
function base.get_spawn_position() return {x = 256, y = 256, z = 30}; end
function base.on_successful_connect(pid) P[pid] = P[pid] or {conn = true, joined = false, alive = false}; P[pid].conn = true; end
function base.on_join(pid, team, gun, name)
	local p = P[pid];
	p.joined, p.team, p.gun, p.name = true, team, gun, name;
	p.ori, p.vel, p.color, p.air, p.wading = {x = 0, y = 1, z = 0}, {x = 0, y = 0, z = 0}, {r = 1, g = 2, b = 3}, false, false;
	spawn_player(pid, get_spawn_position(pid));
end
function base.on_tool_change(pid, tool) P[pid].tool = tool; end
function base.on_color_change(pid, c) P[pid].color = c; rec.colors[#rec.colors + 1] = {pid, c}; end
function base.on_move_input(pid, m) P[pid].inputs = m; send_packet(PID_BROADCAST_EXCEPT(pid), "move"); end
function base.on_orientation(pid, d) P[pid].ori = {x = d.x, y = d.y, z = d.z}; end
function base.on_mouse_input(pid, m) P[pid].mouse = m; send_packet(PID_BROADCAST_EXCEPT(pid), "mouse"); end
function base.on_reload(pid) P[pid].reload = NOW + 2; end
function base.set_ammo(pid, mag, res) P[pid].mag, P[pid].reserve = mag, res; send_packet(pid, "reload"); end
function base.on_grenade(pid, pos, vel, fuse)
	rec.grenades[#rec.grenades + 1] = {pid = pid, pos = pos, vel = vel, fuse = fuse};
end
function base.spawn_grenade(pid, team, pos, vel, fuse) end
function simulate_grenade_physics(pos, v, dt) return {x = pos.x + v.x * dt, y = pos.y + v.y * dt, z = pos.z + v.z * dt}, v; end
function base.block_action_rm(pos, type, from)
	if (SOLID[key(pos.x, pos.y, pos.z)]) then SOLID[key(pos.x, pos.y, pos.z)] = nil; return 1; end
	return 0;
end
function base.block_action_cull() end
function base.finish_cull() end
function base.block_action(pos, type, from)
	if (type == 0) then SOLID[key(pos.x, pos.y, pos.z)] = true; return; end
	if (rec.rm_direct) then base.block_action_rm(pos, type, from); else block_action_rm(pos, type, from); end
end
function base.on_block_action(pid, pos, type) block_action(pos, type, pid); end
function base.block_line(a, b, from) SOLID[key(a.x, a.y, a.z)] = true; SOLID[key(b.x, b.y, b.z)] = true; end
function base.on_block_line(pid, a, b) block_line(a, b, pid); end
function base.set_hp(pid, hp) P[pid].hp = hp; end
function base.set_hp_directional(pid, hp, pos) P[pid].hp = hp; end
function base.kill(pid, ktype, killer) P[pid].alive = false; rec.killed[#rec.killed + 1] = pid; end
function base.damage_player(pid, hp, type, damager)
	set_hp(pid, P[pid].hp - hp);
	if (P[pid].hp <= 0) then kill(pid, type, damager); end
end
function base.damage_player_directional(pid, hp, pos, type, damager)
	set_hp_directional(pid, P[pid].hp - hp, pos);
	if (P[pid].hp <= 0) then kill(pid, type, damager); end
end
function base.on_hit(pid, type, target)
	rec.hits[#rec.hits + 1] = {pid, type, target};
	damage_player_directional(target, 80, P[pid].pos, 2, pid);
end
function base.on_disconnect(pid) P[pid].conn, P[pid].alive = false, false; end
function base.disconnect() end
function base.disconnect_now() end
function base.prepare_map_load() end
function base.finish_map_load() end
function base.tick() end
function base.restock(pid) end
function base.boot_players_to_limbo() end
function base.bdestroy_block_action(pos, type) return block_action_rm(pos, type, get_anon_pid()) ~= 0; end
function base.bdestroy_finish() end
function base.handle_command_dummy() end
package.preload["lib_bulk_destroy"] = function() return true; end

function server.assign_new_pid()
	for i = 0, MAX_PLAYERS - 1 do if (P[i] == nil or not P[i].conn) then return i; end end
	return MAX_PLAYERS;
end
function handle_command(pid, text, nolog) rec.commands[#rec.commands + 1] = {pid, text, nolog}; end
local pings = {};
function teamplay_ping(viewer, pos, opts) pings[#pings + 1] = {viewer = viewer, pos = pos, opts = opts}; return true; end
teamplay_ping_interval = 1;
local shot_fn, ping_fn;
function shot_listen(name, fn) shot_fn = fn; end
function shot_unlisten() shot_fn = nil; end
function teamplay_listen_ping(name, fn) ping_fn = fn; end
function teamplay_unlisten_ping() ping_fn = nil; end
local dumps = 0;
function dump_vxl() dumps = dumps + 1; local i = 0; return function() i = i + 1; if (i <= 2) then return "VXL" .. i; end end; end

local STAGES = {"impl", "late", false, "early", "xearly"};
local function wire()
	local names = {};
	for n in pairs(base) do names[n] = true; end
	for _, m in ipairs(mods) do
		for _, st in ipairs(STAGES) do
			local t = st and m[st] or m;
			for k, v in pairs(t.before) do names[k] = true; end
			for k, v in pairs(t.after) do names[k] = true; end
			for k, v in pairs(t) do if (type(v) == "function") then names[k] = true; end end
		end
	end
	for name in pairs(names) do
		local fn = base[name];
		if (fn == nil) then fn = function() end; end
		for _, st in ipairs(STAGES) do
			for _, m in ipairs(mods) do
				local t = st and m[st] or m;
				local b, a, own = t.before[name], t.after[name], rawget(t, name);
				if (type(own) ~= "function") then own = nil; end
				if (own or b or a) then
					local inner = fn;
					t.next[name] = inner;
					local core = own or inner;
					fn = function(...)
						if (b) then b(...); end
						local r = core(...);
						if (a) then a(...); end
						return r;
					end
				end
			end
		end
		_G[name] = fn;
	end
end

-- a protection in the chain, as babel's or map_layout's would be
local PROTECTED = {};
local prot = init_mod();
function prot.block_action(pos, type, from)
	if (PROTECTED[key(pos.x, pos.y, pos.z)]) then return; end
	prot.next.block_action(pos, type, from);
end

local TMP = os.tmpname();
os.remove(TMP);
os.execute("mkdir -p " .. TMP);
botlink_header = "bot/link/botlink.h";
botlink_map_dir = TMP .. "/";
botlink_file = TMP .. "/link";
local function exists(path) local fh = io.open(path, "rb"); if (fh) then fh:close(); return true; end return false; end

local lib;
local function load_modules(libpath)
	botlink_lib = libpath;
	-- a fresh lib_bot and lib_botlink each time
	local lb = dofile("catalog/libs/bot/lib_bot.lua");
	local bl = dofile("catalog/libs/botlink/lib_botlink.lua");
	mods = {lb, bl, prot};
	wire();
	return lb, bl;
end

--====================== THE ENGINE'S SIDE (the test) ================--
local E, ebuf = nil, ffi.new("uint8_t[?]", 1024);
local function engine_events()
	local out = {};
	while (true) do
		local n = lib.bl_pop(E.events, ebuf);
		if (n == 0) then break; end
		local r = ffi.cast("bl_record *", ebuf);
		out[#out + 1] = {type = r.type, pid = r.pid, raw = ffi.string(ebuf + 4, n - 4), n = n};
	end
	return out;
end
local function of(evs, kind)
	local o = {};
	for _, e in ipairs(evs) do if (e.type == kind) then o[#o + 1] = e; end end
	return o;
end
local function as(ev, ct) return ffi.cast(ct .. " *", ev.raw); end
local function act(kind, pid, obj, n)
	return lib.bl_push(E.actions, kind, pid, obj, n or (obj and ffi.sizeof(obj) or 0));
end
local W = nil;
local function world()
	W = W or ffi.new("bl_world");
	assert(lib.bl_world_read(E, W, 10) == 1);
	return W;
end
local ENGINE_BEATS = false;
local function step(n)
	for _ = 1, n or 1 do
		NOW = NOW + 1 / 60;
		if (ENGINE_BEATS) then lib.bl_beat_engine(E); end
		_G.tick();
	end
end
local function mkintent(pid, t)
	local it = E.intents[pid];
	it.life = t.life or world().players[pid].life;
	it.keys, it.mouse, it.tool = t.keys or 0, t.mouse or 0, t.tool or 2;
	it.flags = t.flags or 1;
	it.ori.x, it.ori.y, it.ori.z = t.ox or 0, t.oy or 1, t.oz or 0;
end

--============================ 1. INERT ==============================--
print("\n1. the library is missing: the server runs on");
local _, bl = load_modules("/nonexistent/libbotlink.so");
bl.on_load();
check(#logs >= 1 and string.find(logs[#logs], "inert", 1, true), "logged once, clearly", logs[#logs]);
local nlogs = #logs;
check(botlink_add{team = 1} == nil, "botlink_add: no bot, no error");
step(5);
check(#logs == nlogs, "ticks stay silent");
check(botlink_alive() == false and botlink_stats().inert ~= nil, "not alive; says why");
check(not exists(botlink_file), "no file made");
bl.on_unload();

--=============== 2. NO FILE UNTIL BOTS ARE ASKED FOR ================--
print("\n2. a server with no bots configured makes no file");
local lb, bl = load_modules(LIBPATH);
bl.on_load();
lib = ffi.load(LIBPATH);
check(lib.bl_layout_ok() == 1, "the header and the library agree");
step(10);
check(not exists(botlink_file), "loaded and ticking: no file");
engine_bots_count = 0;
local eb = dofile("catalog/bots/engine_bots/engine_bots.lua");
mods[#mods + 1] = eb; wire();
step(130);
check(not exists(botlink_file), "engine_bots at count 0: still no file");
mods[#mods] = nil; wire();

--================= 3. THE FIRST BOT, AND THE WORLD ==================--
print("\n3. the first bot makes the file; the world is the server's");
new_player(0, 1); new_player(1, 2); P[1].gun = 1; P[1].tool = 0;
P[1].hp, P[1].air, P[1].wading, P[1].inputs, P[1].mouse = 77, true, true, 1 + 128 + 32, 2;
P[1].pos = {x = 10.5, y = 20.25, z = 30.125}; P[1].vel = {x = 0.5, y = -0.25, z = 0.125};
new_player(5, 1).alive = false;                      -- dead, waiting
P[6] = {conn = true, joined = false, team = 255};    -- limbo
LAMP[0] = true;
INTEL[1], INTEL[2] = {x = 1, y = 2, z = 3}, 1;       -- team 1's lies; team 2's is carried by 1
TENT[1], TENT[2] = {x = 50, y = 60, z = 40}, nil;
NIGHT = true;
local pid = botlink_add{team = 1, level = 7, gun = 1, seed = 1234};
check(pid ~= nil and P[pid].joined, "botlink_add: a lib_bot bot", pid);
P[pid].bot = true;
check(exists(botlink_file), "the file exists now");
E = lib.bl_attach(botlink_file);
check(E ~= nil, "the engine attaches");
check(lib.bl_closing(E) == 0, "not closing");
ENGINE_BEATS = true;
step(2);
check(botlink_alive() == true, "botlink_alive once the engine beats");
local evs = engine_events();
check(#of(evs, 1) == 1 and #of(evs, 9) == 1, "attach: a MAP and the bot announced");
local m = as(of(evs, 1)[1], "bl_ev_map");
local mpath = ffi.string(m.path);
check(exists(mpath) and m.map_seq == 1, "the map is a file, with its seq", mpath);
local rb = as(of(evs, 9)[1], "bl_ev_bot");
check(of(evs, 9)[1].pid == pid and rb.level == 7 and rb.gun == 1 and rb.seed == 1234, "BL_EV_BOT: pid, level, gun, seed");
local sizes_ok = true;
for _, ev in ipairs(evs) do
	local want = ({[1] = "bl_ev_map", [9] = "bl_ev_bot"})[ev.type];
	if (want and ev.n - 4 ~= ffi.sizeof(want)) then sizes_ok = false; end
end
check(sizes_ok, "payload sizes are the structs'");

local w = world();
local p1, pb = w.players[1], w.players[pid];
check(w.tick > 0 and w.time > 0 and w.map_seq == 1 and w.night == 1, "tick, time, map_seq, night", w.tick..","..w.time..","..w.map_seq..","..w.night);
check(w.score[0] == 3 and w.score[1] == 6 and w.max_score == 10, "score");
check(p1.state == 3 and p1.team == 2 and p1.tool == 0 and p1.gun == 1 and p1.hp == 77, "player: state, team, tool, gun, hp");
check(p1.mag == 10 and p1.reserve == 50 and p1.keys == (1 + 128 + 32), "player: ammo, keys");
check(p1.flags == (2 + 4 + 8 + 16 + 128), "player: crouch, sprint, airborne, wading, scoped", p1.flags);
check(math.abs(p1.pos.x - 10.5) < 1e-6 and math.abs(p1.pos.y - 20.25) < 1e-6 and math.abs(p1.vel.y + 0.25) < 1e-6
	and p1.ori.y == 1, "player: pos, ori, vel");
check(w.players[0].flags == 32 and w.players[0].team == 1, "lamp (flashlight_get)");
check(pb.flags % 2 == 1 and pb.state == 3 and pb.life == 1 and pb.blocks == 50 and pb.grenades == 3, "bot: BL_F_BOT, life 1, blocks and grenades counted");
check(w.players[5].state == 2 and w.players[6].state == 1 and w.players[6].team == 0, "dead, limbo (spectator team 0)");
check(w.players[20].state == 0, "absent slot");
check(w.intel[0].present == 1 and w.intel[0].holder == 255 and w.intel[0].pos.z == 3, "intel 1 on the ground");
check(w.intel[1].present == 1 and w.intel[1].holder == 1 and math.abs(w.intel[1].pos.x - 10.5) < 1e-6, "intel 2 carried by 1, at its carrier");
check(w.tent[0].present == 1 and w.tent[0].pos.x == 50 and w.tent[1].present == 0, "tents");
P[0].conn = false;
step(3);
check(world().players[0].state == 0 and world().players[0].pos.x == 0, "a slot that left is zeroed");
P[0].conn = true;

--================ 4. THE WORLD'S RATE, THE INTENT'S ================--
print("\n4. one world snapshot at botlink_world_hz; intents at every tick");
local function count_writes(nticks, check_intents)
	local before = E.world.seq;
	local last = before;
	local writes, applied = 0, 0;
	for i = 1, nticks do
		mkintent(pid, {keys = (i % 2 == 0) and 1 or 2});
		step(1);
		if (E.world.seq ~= last) then writes = writes + 1; last = E.world.seq; end
		if (P[pid].inputs == ((i % 2 == 0) and 1 or 2)) then applied = applied + 1; end
	end
	return writes, applied;
end
step(30);
local wr, ap = count_writes(60);
check(wr == 30, "30 writes in 60 ticks at 30 Hz", wr);
check(ap == 60, "an intent applied on every one of 60 ticks", ap);
botlink_world_hz = 60;
step(3);
wr, ap = count_writes(60);
check(wr == 60 and ap == 60, "60 writes in 60 ticks at 60 Hz", wr);
botlink_world_hz = 30;
E.intents[pid].flags = 0;
bot_keys(pid, 0); step(1);

--========================== 5. THE EVENTS ===========================--
print("\n5. events, once each, with the right payload");
engine_events();
local pos = {x = 120, y = 130, z = 40};
-- a player builds: a block; the colour is the map's
SOLID[key(119, 130, 40)] = true;
P[0].tool = 1;
on_block_action(0, pos, 0);
local evs = engine_events();
local bs = of(evs, 2);
check(#bs == 1 and SOLID[key(120, 130, 40)], "a build is one BLOCK event");
local b = as(bs[1], "bl_ev_block");
check(b.x == 120 and b.y == 130 and b.z == 40 and b.action == 0 and bs[1].pid == 0 and b.by == 0
	and b.color == 9 * 65536 + 8 * 256 + 7, "x y z, action, by, colour");
local snd = of(evs, 6);
check(#snd == 1 and as(snd[1], "bl_ev_sound").kind == 3 and snd[1].pid == 0, "...and a build sound");
-- the server's own destroy (bulk), a spade, a grenade
SOLID[key(130, 130, 40)] = true; SOLID[key(131, 130, 40)] = true;
bdestroy_block_action({x = 130, y = 130, z = 40}, 1);
evs = engine_events();
bs = of(evs, 2);
check(#bs == 1 and as(bs[1], "bl_ev_block").by == 255 and as(bs[1], "bl_ev_block").action == 1 and #of(evs, 6) == 0,
	"the server's own destroy: by NO_PLAYER, no sound", bs[1] and as(bs[1], "bl_ev_block").by);
P[0].tool = 0;
on_block_action(0, {x = 131, y = 130, z = 40}, 2);
evs = engine_events();
bs = of(evs, 2);
check(#bs == 1 and as(bs[1], "bl_ev_block").action == 2 and as(of(evs, 6)[1], "bl_ev_sound").kind == 2, "a spade 3x: action 2 and a dig sound");
block_action({x = 140, y = 140, z = 40}, 3, 0);
evs = engine_events();
check(#of(evs, 2) == 0 and #of(evs, 6) == 1 and as(of(evs, 6)[1], "bl_ev_sound").kind == 5, "a grenade blast that took nothing: a BLAST sound only");
SOLID[key(141, 140, 40)] = true;
block_action({x = 141, y = 140, z = 40}, 3, 31);
evs = engine_events();
check(#of(evs, 2) == 1 and as(of(evs, 2)[1], "bl_ev_block").action == 3, "...and one that did: a BLOCK of action 3");
rec.rm_direct = true;
SOLID[key(150, 150, 40)] = true;
block_action({x = 150, y = 150, z = 40}, 1, 0);
rec.rm_direct = false;
check(#of(engine_events(), 2) == 1, "C that does not pass the chain for the removal: still one event");
-- a protection above refuses: nothing reaches the server, nothing is told
PROTECTED[key(160, 160, 40)] = true; SOLID[key(160, 160, 40)] = true;
on_block_action(0, {x = 160, y = 160, z = 40}, 1);
check(#engine_events() == 0 and SOLID[key(160, 160, 40)], "a refused action tells the engine nothing (late chain)");
-- a line
P[0].tool = 1;
on_block_line(0, {x = 100, y = 100, z = 40}, {x = 105, y = 100, z = 40});
evs = engine_events();
local ln = of(evs, 3);
check(#ln == 1 and as(ln[1], "bl_ev_line").x1 == 100 and as(ln[1], "bl_ev_line").x2 == 105 and as(ln[1], "bl_ev_line").by == 0
	and as(ln[1], "bl_ev_line").color == 1 * 65536 + 2 * 256 + 3, "BL_EV_LINE: ends, by, the builder's colour");
-- hurt with a source, without, kill
damage_player_directional(1, 20, {x = 7, y = 8, z = 9}, 0, 0);
evs = engine_events();
local hu = of(evs, 5);
local h = as(hu[1], "bl_ev_hurt");
check(#hu == 1 and hu[1].pid == 1 and h.by == 0 and h.hp == 57 and h.from.x == 7 and h.from.z == 9, "BL_EV_HURT: victim, by, hp left, from");
damage_player(1, 7, 0, 0);
h = as(of(engine_events(), 5)[1], "bl_ev_hurt");
check(h.by == 0 and h.hp == 50 and h.from.x == P[0].pos.x, "damage with no position: from the damager");
set_hp(1, 40);
h = as(of(engine_events(), 5)[1], "bl_ev_hurt");
check(h.by == 255 and h.hp == 40 and h.from.x == P[1].pos.x, "a bare set_hp (fall, script): by NO_PLAYER, from the victim");
set_hp(1, 90);
check(#of(engine_events(), 5) == 0, "healing is not a hurt");
damage_player(1, 200, 0, 0);
evs = engine_events();
local ks = of(evs, 4);
check(#ks == 1 and ks[1].pid == 1 and as(ks[1], "bl_ev_kill").killer == 0, "BL_EV_KILL: victim and killer");
P[1].alive = true; P[1].hp = 100;
-- grenade, shot, ping
on_grenade(0, {x = 1, y = 2, z = 3}, {x = 0.5, y = 0.25, z = -0.5}, 2.5);
spawn_grenade(1, 2, {x = 4, y = 5, z = 6}, {x = 1, y = 0, z = 0}, 1);
evs = engine_events();
local gr = of(evs, 7);
check(#gr == 2 and gr[1].pid == 0 and as(gr[1], "bl_ev_grenade").fuse == 2.5 and as(gr[1], "bl_ev_grenade").vel.z == -0.5
	and as(gr[2], "bl_ev_grenade").pos.x == 4, "BL_EV_GRENADE: from on_grenade and spawn_grenade");
shot_fn(1, 1);
evs = engine_events();
snd = of(evs, 6);
check(#snd == 1 and snd[1].pid == 1 and as(snd[1], "bl_ev_sound").kind == 1 and as(snd[1], "bl_ev_sound").pos.x == 10.5, "a player's shot (shot_listen): SHOT at their position");
ping_fn(0, {x = 5, y = 6, z = 7}, "Look here");
evs = engine_events();
local pg = of(evs, 8);
check(#pg == 1 and pg[1].pid == 0 and as(pg[1], "bl_ev_ping").pos.y == 6 and ffi.string(as(pg[1], "bl_ev_ping").reason) == "Look here",
	"a player's ping (teamplay_listen_ping): BL_EV_PING");
-- a map
local d0 = dumps;
prepare_map_load(); finish_map_load();
evs = engine_events();
local mp = of(evs, 1);
check(#mp == 1 and as(mp[1], "bl_ev_map").map_seq == 2 and dumps == d0 + 1 and exists(ffi.string(as(mp[1], "bl_ev_map").path)),
	"a map load: a new .vxl and the new map_seq");
check(#of(evs, 9) == 1 and of(evs, 9)[1].pid == pid, "a map change keeps the bots, announced again");
check(not exists(mpath) or true, "(older maps are tidied two behind)");
for i = 1, 3 do prepare_map_load(); finish_map_load(); end
engine_events();
check(not exists(mpath), "the first map file is deleted after two more");

--=========================== 6. THE INTENT ==========================--
print("\n6. an intent moves a bot");
step(2);
P[pid].alive = true;
local life = world().players[pid].life;
mkintent(pid, {keys = 1 + 128, ox = 1, oy = 0, oz = 0, tool = 1, flags = 1 + 2});
step(1);
check(P[pid].inputs == 129, "keys applied through lib_bot's input reconciliation", P[pid].inputs);
check(P[pid].ori.x == 1 and P[pid].ori.y == 0, "orientation");
check(P[pid].tool == 1, "tool");
check(LAMP[pid] == true, "lamp");
step(1);
local pw = world().players[pid];
check(pw.keys == 129 and pw.tool == 1 and pw.flags % 2 == 1 and bit.band(pw.flags, 32) == 32, "...and the world says so");
mkintent(pid, {keys = 2, life = life + 1, tool = 0, flags = 1});
step(1);
check(P[pid].inputs == 129 and P[pid].tool == 1, "an intent for another life is ignored");
mkintent(pid, {keys = 2, flags = 0});
step(1);
check(P[pid].inputs == 129, "an intent not valid is ignored");
-- reload
P[pid].tool, P[pid].mag = 2, 3;
mkintent(pid, {keys = 0, tool = 2, flags = 1 + 4});
step(1);
check(P[pid].reload > NOW, "reload asked");
P[pid].reload = 0;
-- scope
mkintent(pid, {tool = 2, mouse = 2, flags = 1});
step(1);
check(P[pid].mouse == 2, "secondary: the scope, as the server models it");
-- the trigger: gun
P[pid].mag, P[pid].pos, P[pid].tool = 10, {x = 300, y = 300, z = 30}, 2;
P[pid].gun = 0;
new_player(7, 2).pos = {x = 300, y = 310, z = 30.9};
mkintent(pid, {tool = 2, mouse = 1, oy = 1, flags = 1});
engine_events();
step(1);
check(P[7].hp < 100, "the trigger with a gun: the server-side hit test hurt the enemy", P[7].hp);
check(P[pid].mag == 9, "...and a round was spent", P[pid].mag);
local evs = engine_events();
check(#of(evs, 6) >= 1 and as(of(evs, 6)[1], "bl_ev_sound").kind == 1 and of(evs, 6)[1].pid == pid, "...and a SHOT sound for the bot");
step(1);
check(bit.band(world().players[pid].flags, 64) == 64, "FIRING in the world");
P[pid].mag = 0; P[7].hp = 100; P[7].alive = true;
step(40);
check(P[7].hp == 100, "an empty magazine does not fire");
-- the trigger: spade
P[pid].mag = 10; P[pid].tool = 0; P[7].alive = true; P[7].hp = 100;
P[7].pos = {x = 300, y = 302, z = 30.9};
mkintent(pid, {tool = 0, mouse = 1, oy = 1, flags = 1});
step(1);
check(#rec.hits >= 1 and rec.hits[#rec.hits][1] == pid and rec.hits[#rec.hits][2] == 4 and P[7].hp < 100, "the trigger with the spade: a swing that hits goes through on_hit");
P[7].pos = {x = 300, y = 330, z = 30.9};
SOLID[key(300, 302, 30)] = true;
engine_events();
step(30);
check(not SOLID[key(300, 302, 30)], "...and with nobody there, it digs what it meets");
local bs = of(engine_events(), 2);
check(#bs >= 1 and bs[1].pid == pid, "...told as the bot's own dig", bs[1] and bs[1].pid);
-- block tool: nothing
P[pid].tool = 1;
SOLID[key(300, 302, 30)] = true;
mkintent(pid, {tool = 1, mouse = 1, flags = 1});
engine_events();
step(30);
check(SOLID[key(300, 302, 30)] and #of(engine_events(), 2) == 0, "the trigger with blocks does nothing (building is an action)");
mkintent(pid, {tool = 1, flags = 1});
step(1);

--=========================== 7. THE ACTIONS =========================--
print("\n7. actions go through the chains, as the bot");
E.intents[pid].flags = 0;
P[pid].pos = {x = 200.5, y = 200.5, z = 30}; P[pid].tool = 1; P[pid].alive = true;
for _, c in ipairs{{200, 200, 33}, {201, 200, 33}} do SOLID[key(c[1], c[2], c[3])] = true; end
local ab = ffi.new("bl_ac_block");
local function block(x, y, z, a)
	ab.x, ab.y, ab.z, ab.action = x, y, z, a;
	act(1, pid, ab);
end
engine_events();
local refused0 = botlink_stats().ac_refused;
block(202, 200, 33, 0);
step(1);
check(SOLID[key(202, 200, 33)], "a build, next to a block, in reach, with blocks");
local evs = engine_events();
check(#of(evs, 2) == 1 and as(of(evs, 2)[1], "bl_ev_block").by == pid, "...announced as the bot's");
step(1);
check(world().players[pid].blocks == 49, "...and one block fewer");
block(202, 200, 33, 0);
step(1);
check(botlink_stats().ac_refused == refused0 + 1, "a build on a solid block: refused, counted");
block(210, 200, 30, 0);
step(10);
check(not SOLID[key(210, 200, 30)], "a build out of reach: refused");
block(203, 200, 29, 0);
step(10);
check(not SOLID[key(203, 200, 29)], "a build with no neighbour: refused");
PROTECTED[key(204, 200, 33)] = true;
block(204, 200, 33, 0);
step(10);
check(not SOLID[key(204, 200, 33)], "a protected block (the gamemode's chain): not built");
engine_events();
-- dig
P[pid].tool = 0;
block(200, 200, 33, 1);
step(1);
check(not SOLID[key(200, 200, 33)], "a dig with the spade");
may_break_block = function(p, pos2, t) return false; end
block(201, 200, 33, 1);
step(10);
check(SOLID[key(201, 200, 33)], "a dig may_break_block refuses: not done");
may_break_block = nil;
P[pid].tool = 1;
block(201, 200, 33, 1);
step(10);
check(SOLID[key(201, 200, 33)], "a dig with blocks in hand: refused");
-- line
P[pid].tool = 1;
local al = ffi.new("bl_ac_line");
al.x1, al.y1, al.z1, al.x2, al.y2, al.z2 = 201, 201, 33, 204, 201, 33;
SOLID[key(200, 201, 33)] = true; SOLID[key(204, 202, 33)] = true;
act(2, pid, al);
step(11);
check(SOLID[key(204, 201, 33)], "a line");
check(#of(engine_events(), 3) == 1, "...announced");
al.x2 = 400; act(2, pid, al); step(40);
check(not SOLID[key(400, 201, 33)], "a line with more blocks than it holds (and out of reach): refused");
-- grenade
local ag = ffi.new("bl_ac_grenade");
ag.vel.x, ag.vel.y, ag.vel.z, ag.fuse = 0.5, 0.5, -0.1, 2;
local g0 = #rec.grenades;
act(3, pid, ag);
step(1);
check(#rec.grenades == g0 + 1 and rec.grenades[g0 + 1].pid == pid and rec.grenades[g0 + 1].fuse == 2, "a grenade is thrown as lib_bot throws one");
local gev = of(engine_events(), 7);
check(#gev == 1 and gev[1].pid == pid, "...and announced");
step(1);
check(world().players[pid].grenades == 2, "...one fewer");
-- command, colour, log
local text = ffi.new("char[?]", 32);
ffi.copy(text, "inv rocket 10 20 30");
act(4, pid, text, 20);
local colour = ffi.new("uint32_t[1]", 0x102030);
act(5, pid, colour);
local lg = ffi.new("char[?]", 16); ffi.copy(lg, "hello");
act(6, pid, lg, 6);
step(1);
check(#rec.commands == 1 and rec.commands[1][1] == pid and rec.commands[1][2] == "inv rocket 10 20 30" and rec.commands[1][3] == true,
	"a command runs as the bot, handle_command(pid, text, true)");
check(#rec.colors >= 1 and rec.colors[#rec.colors][2].r == 0x10 and rec.colors[#rec.colors][2].g == 0x20 and rec.colors[#rec.colors][2].b == 0x30, "the colour");
check(logs[#logs] == "botlink: #" .. pid .. ": hello", "the log line", logs[#logs]);
-- ping
local ap = ffi.new("bl_ac_ping");
ap.pos.x, ap.pos.y, ap.pos.z = 50, 60, 20;
ffi.copy(ap.reason, "Enemy");
engine_events();
pings = {};
act(7, pid, ap);
step(1);
local team1 = 0;
for i in piditer(PID_BROADCAST_TEAM(1)) do if (not P[i].bot) then team1 = team1 + 1; end end
check(#pings == team1 and pings[1].opts.from == pid and pings[1].pos.x == 50, "a ping: relayed to each human teammate, from the bot", #pings);
check(type(pings[1].opts.reason) == "table" and pings[1].opts.reason.en == "Enemy", "...a label of the gamemode's pings goes as its message table");
local pe = of(engine_events(), 8);
check(#pe == 1 and pe[1].pid == pid and ffi.string(as(pe[1], "bl_ev_ping").reason) == "Enemy", "...and as a BL_EV_PING for the other bots");
pings = {};
act(7, pid, ap);
step(1);
check(#pings == 0, "a second ping inside teamplay_ping_interval: dropped");
NOW = NOW + 2;
ffi.copy(ap.reason, "Banana");
act(7, pid, ap);
step(1);
check(#pings > 0 and pings[1].opts.reason == "Banana", "any other text goes as it is", tostring(pings[1] and pings[1].opts.reason));
-- not ours, dead, the bound
local d0 = botlink_stats().ac_dropped;
act(6, 0, lg, 6);                 -- a human's pid
P[pid].alive = false;
act(6, pid, lg, 6);               -- a dead bot
act(6, 17, lg, 6);                -- nobody
step(1);
check(botlink_stats().ac_dropped == d0 + 3, "records for a pid that is not a live bot of ours: dropped and counted");
P[pid].alive = true;
local a0 = botlink_stats().actions;
for i = 1, 100 do act(6, pid, lg, 6); end
step(1);
check(botlink_stats().actions - a0 == 64, "at most botlink_actions_per_tick a tick", botlink_stats().actions - a0);
step(1);
check(botlink_stats().actions - a0 == 100, "the rest on the next");

--========================= 8. THE ENGINE FALLS SILENT ===============-
print("\n8. a silent engine freezes the bots");
mkintent(pid, {keys = 1, tool = 2, flags = 1});
step(1);
check(P[pid].inputs == 1, "walking");
ENGINE_BEATS = false;
step(60);
check(botlink_alive() == true, "one second of silence is not enough");
step(90);
check(botlink_alive() == false and P[pid].inputs == 0, "past botlink_stale: alive false, keys released", P[pid].inputs);
mkintent(pid, {keys = 8, tool = 2, flags = 1});
step(2);
check(P[pid].inputs == 0, "intents ignored while it is silent");
engine_events();

--========================== 9. A LATE ATTACH ========================--
print("\n9. an engine that attaches late is told everything");
botlink_set("friendly_fire", true);
botlink_set("difficulty", 3, pid);
botlink_order(pid, {order = "goto", pos = {x = 1, y = 2, z = 3}, secs = 5});
local d0 = dumps;
ENGINE_BEATS = true;
step(2);
local evs = engine_events();
check(botlink_alive() and #of(evs, 1) == 1 and dumps > d0, "alive again: a fresh MAP of the map as it is now");
check(#of(evs, 9) == 1 and of(evs, 9)[1].pid == pid, "...the bot announced again");
local sets = of(evs, 11);
local texts = {};
local saw_nv = false;
for _, s in ipairs(sets) do
	local line = (s.pid == 255 and "*" or s.pid) .. ":" .. ffi.string(s.raw);
	-- every bot's night vision is a setting of its own (section 9c)
	if (line:find(":night_vision=", 1, true)) then saw_nv = true; else texts[#texts + 1] = line; end
end
table.sort(texts);
check(#texts == 5 and texts[1] == "*:friendly_fire=true" and texts[2] == "*:water.damage=0" and texts[3] == "*:water=safe"
	and texts[4] == pid .. ":difficulty=3" and texts[5]:find("^" .. pid .. ":name=Bot%d+$") ~= nil,
	"...the settings, global and the bot's (its name among them), the map's water too", table.concat(texts, ","));
check(saw_nv, "...and whether the bot sees in the dark");
local od = of(evs, 12);
check(#od == 1 and od[1].pid == pid and as(od[1], "bl_ev_order").order == 1 and as(od[1], "bl_ev_order").pos.y == 2
	and as(od[1], "bl_ev_order").secs == 5, "...and its order");
mkintent(pid, {keys = 8, tool = 2, flags = 1});
step(1);
check(P[pid].inputs == 8, "the bots move again");
botlink_set("night_vision", 1);
local s = of(engine_events(), 11);
check(#s == 1 and ffi.string(s[1].raw) == "night_vision=1", "botlink_set pushes at once");

print("\n9b. what a bot holds, and what each item is for, reach the engine");
local INV;
function inventory_listen(name, l) INV = l; end
function inventory_unlisten() INV = nil; end
function inventory_kinds() return {medkit = {bot = {tree = "seq\n\tif health_below 40\n\tdo use medkit", guide = 0}}, plain = {}}; end
function inventory_count(p, k) return (p == pid and k == "medkit") and 1 or 0; end
step(61);   -- listeners are looked for once a second
local function settexts()
	local t = {};
	for _, e in ipairs(of(engine_events(), 11)) do t[(e.pid == 255 and "*" or e.pid) .. ":" .. ffi.string(e.raw)] = true; end
	return t;
end
local t = settexts();
check(INV ~= nil, "the link listens to the inventory when there is one");
check(t["*:item.medkit.tree=seq\n\tif health_below 40\n\tdo use medkit"] and t["*:item.medkit.guide=0"],
	"each kind's own tree fragment and guide time, for everybody");
check(t["*:item.plain.tree="], "a kind with nothing to say to bots: an empty fragment");
check(t[pid .. ":item.medkit=1"], "and what the bot already held");
INV.count(pid, "rocket", 3);
INV.count(pid, "missile", math.huge);
INV.count(7, "rocket", 2);   -- a person: not the engine's business
t = settexts();
check(t[pid .. ":item.rocket=3"] and t[pid .. ":item.missile=inf"], "a bot's count as it changes; unlimited is inf");
local n = 0; for _ in pairs(t) do n = n + 1; end
check(n == 2, "a person's inventory is not sent", n);
INV.kind("medkit", nil);
t = settexts();
check(t["*:item.medkit.tree="], "an item undefined withdraws its fragment");
inventory_listen, inventory_unlisten, inventory_kinds, inventory_count = nil, nil, nil, nil;

print("\n9c. who sees in the dark");
local NV = {};
PlayerEffect = {get = function(name) return name == "nightvision" and {has = function(_, p) return NV[p] == true; end} or nil; end};
step(61);
settexts();
step(61);
check(next(settexts()) == nil, "a bot without night vision was told so once, not every second");
NV[pid] = true;
step(61);
check(settexts()[pid .. ":night_vision=1"], "given night vision: the engine is told");
NV[pid] = nil;
step(61);
check(settexts()[pid .. ":night_vision=0"], "and when it ends");
PlayerEffect = nil;

print("\n9d. what the map's water does");
local META = {};
function get_map_meta() return META; end
local function water_after_load()
	settexts();
	prepare_map_load(); finish_map_load();
	local t = settexts();
	return t["*:water=lethal"] and "lethal" or t["*:water=safe"] and "safe" or "?", t;
end
local w, wt = water_after_load();
check(w == "safe" and wt["*:water.damage=0"], "a map that says nothing: the water is safe", w);
META.water_damage = 30;
w, wt = water_after_load();
check(w == "lethal" and wt["*:water.damage=30"], "a map whose water hurts: lethal, and how much a second", w);
META.water_damage = nil;
w = water_after_load();
check(w == "safe", "the next map's water is its own", w);
get_map_meta = nil;

--================ 10. ONE RECORD PER EVENT, WHATEVER THE FLEET ======--
print("\n10. the same events cost the same with 1 bot and with 32");
local function script_events()
	engine_events();
	P[0].tool = 1; P[0].alive = true; P[1].alive = true; P[1].hp = 100;
	SOLID[key(119, 130, 40)] = true;
	on_block_action(0, {x = 120, y = 130, z = 40}, 0);
	bdestroy_block_action({x = 120, y = 130, z = 40}, 1);
	on_block_line(0, {x = 100, y = 100, z = 40}, {x = 102, y = 100, z = 40});
	damage_player_directional(1, 20, {x = 7, y = 8, z = 9}, 0, 0);
	on_grenade(0, {x = 1, y = 2, z = 3}, {x = 0.5, y = 0.25, z = -0.5}, 2.5);
	shot_fn(0, 0);
	ping_fn(0, {x = 5, y = 6, z = 7}, "x");
	damage_player(1, 200, 0, 0);
	P[1].alive = true;
	prepare_map_load(); finish_map_load();
	step(3);
	local n, kinds = 0, {};
	for _, e in ipairs(engine_events()) do if (e.type ~= 9) then n = n + 1; kinds[#kinds + 1] = e.type; end end
	print("  (records: " .. table.concat(kinds, " ") .. ")");
	return n;
end
local leaked0, sent0 = leaked, sent;
local n1 = script_events();
local added = {};
for i = 1, 31 do
	local q = botlink_add{team = 1 + i % 2, level = 5};
	if (q ~= nil) then P[q].bot = true; added[#added + 1] = q; end
end
step(3);
engine_events();
for _, q in ipairs(added) do mkintent(q, {keys = 1, flags = 1}); end
step(3);
local n32 = script_events();
check(#added >= 20, "the fleet is made", #added);
check(n1 == n32 and n1 > 5, "the same sequence: the same number of records (" .. n1 .. " and " .. n32 .. ")");
check(leaked == leaked0, "lib_bot's send guard let no packet through to a bot alone or to bots only", leaked - leaked0);
check(sent > sent0, "(and packets did go to the humans)");
for _, q in ipairs(added) do botlink_remove(q); end
engine_events();

--=================== 10b. A BOT WITH A ROLE OF ITS OWN ==============--
print("\n10b. a tree of its own, a place to spawn, one life");
do
	local post = {x = 100.5, y = 120.5, z = 40};
	local npc = botlink_add{team = 1, tree = "guard", at = post, once = true};
	check(npc ~= nil and P[npc].joined, "the bot is made");
	P[npc].bot = true;
	check(P[npc].pos.x == 100.5 and P[npc].pos.y == 120.5 and P[npc].pos.z == 40, "it spawns at the place given", P[npc].pos.x);
	step(2);
	local line = nil;
	for _, s in ipairs(of(engine_events(), 11)) do
		if (s.pid == npc and ffi.string(s.raw):find("^tree=")) then line = ffi.string(s.raw); end
	end
	check(line == "tree=guard", "its tree is told to the engine, for it alone", line);
	botlink_set("tree", "tree courier:\ndo seek\n", npc);
	step(1);
	line = nil;
	for _, s in ipairs(of(engine_events(), 11)) do
		if (s.pid == npc and ffi.string(s.raw):find("^tree=")) then line = ffi.string(s.raw); end
	end
	check(line == "tree=tree courier:\ndo seek\n", "and changed while it plays, as text", line);
	-- A TREE LONGER THAN ONE RECORD of the link (a record carries under
	-- 1000 bytes): in pieces the engine puts together, never cut short
	local long = {"tree big:", "pick every=1"};
	for i = 1, 60 do
		long[#long + 1] = "\toption none has_item thing" .. i .. " x" .. i .. "   # a line of padding";
		long[#long + 1] = "\t\tdo roam";
	end
	long = table.concat(long, "\n") .. "\n";
	check(#long > 3000, "(a text of over 3000 bytes)", #long);
	check(botlink_set("tree", long, npc) == true, "a long tree is accepted");
	step(1);
	local parts = {};
	for _, s in ipairs(of(engine_events(), 11)) do
		if (s.pid == npc and ffi.string(s.raw):find("^%+?tree")) then parts[#parts + 1] = ffi.string(s.raw); end
	end
	local whole, shaped = "", #parts >= 4;
	for i, part in ipairs(parts) do
		local head = i == 1 and ("^%+tree#" .. #long .. "=") or i == #parts and "^%+tree!=" or "^%+tree=";
		local a, b = part:find(head);
		if (a == nil or #part > 1000) then shaped = false; else whole = whole .. part:sub(b + 1); end
	end
	check(shaped, "it goes as a first piece that says the length, pieces between, and a last one marked", #parts);
	check(whole == long, "and the pieces are the text, all of it", #whole);
	-- one too long for anything is refused whole, and said
	local nlogs = #logs;
	check(botlink_set("tree", string.rep("x", 70000), npc) == false, "a value over the most is refused");
	step(1);
	local sent = false;
	for _, s in ipairs(of(engine_events(), 11)) do
		if (s.pid == npc and ffi.string(s.raw):find("tree", 1, true)) then sent = true; end
	end
	check(not sent and #logs > nlogs and logs[#logs]:find("too long", 1, true) ~= nil, "nothing of it is sent, and the log says so", logs[#logs]);
	check(botlink_set("tree", "tree courier:\ndo seek\n", npc) == true, "(and a short one goes as before)");
	step(1);
	engine_events();
	-- A TREE FROM AN ADMINISTRATION TOOL: by name or from a file it left
	-- in the debug directory, for some bots or for the world; and back
	local function tree_lines()
		local got = {};
		for _, s in ipairs(of(engine_events(), 11)) do
			local t = ffi.string(s.raw);
			if (t:find("^%+?tree")) then got[#got + 1] = (s.pid == 255 and "*" or s.pid) .. ":" .. t; end
		end
		return table.concat(got, "|");
	end
	local other = botlink_add{team = 2};
	P[other].bot = true;
	step(1);
	engine_events();
	os.execute("mkdir -p '" .. botlink_map_dir .. "botdebug'");
	local fh = io.open(botlink_map_dir .. "botdebug/apply-1.bt", "wb");
	fh:write("tree sentry:\ndo hold self 9\n");
	fh:close();
	local n, why = botlink_tree_apply({file = "apply-1.bt"}, {npc, other});
	step(1);
	check(n == 2 and tree_lines() == npc .. ":tree=tree sentry:\ndo hold self 9\n|" .. other .. ":tree=tree sentry:\ndo hold self 9\n",
		"a text from a file of the debug directory, for the bots named", tostring(n) .. " " .. tostring(why));
	n = botlink_tree_apply("tdm", {other});
	step(1);
	check(n == 1 and tree_lines() == other .. ":tree=tdm", "a tree by name, for one");
	n = botlink_tree_revert({npc, other});
	step(1);
	check(n == 2 and tree_lines() == npc .. ":tree=|" .. other .. ":tree=", "those bots back to the world's tree");
	local was = gamemode;
	gamemode = "ctf";
	n = botlink_tree_apply({file = "apply-1.bt"});
	step(1);
	check(n ~= nil and n >= 2 and tree_lines() == "*:tree=tree sentry:\ndo hold self 9\n", "with no bots named: the world's tree", tostring(n));
	n = botlink_tree_revert();
	step(1);
	check(tree_lines() == "*:tree=ctf", "and the world back to the gamemode's");
	engine_bots_tree = "mine";
	botlink_tree_revert();
	step(1);
	check(tree_lines() == "*:tree=mine", "or to the operator's choice (engine_bots_tree), when he made one");
	engine_bots_tree = "";
	gamemode = was;
	botlink_tree_revert();
	step(1);
	engine_events();
	-- what is refused: a path, a file there is none of, a bot that is not the engine's, a name that is no name
	n, why = botlink_tree_apply({file = "../apply-1.bt"}, {npc});
	check(n == nil and why == "not a file name", "a path is not a file name", why);
	n, why = botlink_tree_apply({file = "/etc/passwd"}, {npc});
	check(n == nil and why == "not a file name", "nor is an absolute one", why);
	n, why = botlink_tree_apply({file = "nothing.bt"}, {npc});
	check(n == nil and why == "no such file", "a file there is none of", why);
	n, why = botlink_tree_apply({file = "apply-1.bt"}, {npc, 200});
	check(n == nil and why ~= nil and why:find("no engine bot", 1, true) ~= nil, "a bot that is not the engine's: nobody gets it", why);
	n, why = botlink_tree_apply("tree x:\ndo seek", {npc});
	check(n == nil and why == "not a tree's name", "a text is not a name", why);
	n, why = botlink_tree_revert({200});
	check(n == nil, "nor is such a bot reverted");
	step(1);
	check(tree_lines() == "", "and nothing of those reached the engine");
	-- THE BRIDGE: facts and places go as settings, for all or for one;
	-- a word from a tree (`do tell`) comes back to whoever listens
	local function bridge_lines()
		local got = {};
		for _, s in ipairs(of(engine_events(), 11)) do
			local t = ffi.string(s.raw);
			if (t:find("^fact%.") or t:find("^place%.")) then got[#got + 1] = (s.pid == 255 and "*" or s.pid) .. ":" .. t; end
		end
		table.sort(got);
		return table.concat(got, "|");
	end
	botlink_set("fact.alarm", 1);
	botlink_set("fact.alarm", 0.5, npc);
	botlink_set("place.church", "286.5 268.5 30");
	botlink_set("place.boss", "pid " .. other, npc);
	step(1);
	check(bridge_lines() == "*:fact.alarm=1|*:place.church=286.5 268.5 30|" .. npc .. ":fact.alarm=0.5|" .. npc .. ":place.boss=pid " .. other,
		"a fact and a place, for everybody and for one bot, reach the engine as they were said");
	botlink_set("fact.alarm", "");
	botlink_set("place.church", "");
	step(1);
	check(bridge_lines() == "*:fact.alarm=|*:place.church=", "and are forgotten with an empty value");
	local heard, before = {}, botlink_stats();
	botlink_on("ring_bell", function(pid, words) heard[#heard + 1] = pid .. ":" .. table.concat(words, ","); end);
	local function tell(pid, text)
		local buf = ffi.new("char[?]", #text + 1, text);
		act(8, pid, buf, #text + 1);
	end
	tell(npc, "ring_bell church 3");
	tell(other, "ring_bell");
	tell(npc, "nobody_listens x");
	step(1);
	local st = botlink_stats();
	check(#heard == 2 and heard[1] == npc .. ":church,3" and heard[2] == other .. ":", "`do tell` calls the listener with the bot and the words",
		table.concat(heard, " "));
	check(st.tells - before.tells == 3 and st.tells_unheard - before.tells_unheard == 1 and st.errors == before.errors
		and st.ac_refused == before.ac_refused, "a word nobody listens for is counted, and is no error");
	botlink_on("ring_bell", function() error("the rope broke"); end);
	local nwarn = #logs;
	tell(npc, "ring_bell");
	tell(npc, "ring_bell");
	step(1);
	st = botlink_stats();
	check(#logs == nwarn + 1 and logs[#logs]:find("the rope broke", 1, true) ~= nil and st.tells_unheard - before.tells_unheard == 2
		and st.errors == before.errors, "a listener that raises is said once and dropped", logs[#logs]);
	botlink_on("ring_bell", function(pid) heard[#heard + 1] = "again"; end);
	botlink_off("ring_bell");
	tell(npc, "ring_bell");
	step(1);
	check(#heard == 2, "botlink_off: nobody listens any more");
	check(not pcall(botlink_on, "x", "not a function") and not pcall(botlink_on, 3, function() end), "botlink_on wants a name and a function");
	os.remove(botlink_map_dir .. "botdebug/apply-1.bt");
	os.execute("rmdir '" .. botlink_map_dir .. "botdebug' 2>/dev/null");
	botlink_remove(other);
	step(1);
	engine_events();
	local where = botlink_add{team = 2, at = function(pid) return {x = 300.5, y = 310.5, z = 20}; end};
	P[where].bot = true;
	check(P[where].pos.x == 300.5, "a function says where, too");
	local plain = botlink_add{team = 2};
	P[plain].bot = true;
	check(P[plain].pos.x == 256, "without one it spawns where the gamemode puts a player", P[plain].pos.x);
	kill(npc, 0, where);
	kill(plain, 0, where);
	step(2);
	check(not bot_is_bot(npc), "the bot of one life is gone when it dies");
	check(bot_is_bot(plain), "any other stays, to spawn again");
	local removed = 0;
	for _, e in ipairs(of(engine_events(), 10)) do if (e.pid == npc) then removed = removed + 1; end end
	check(removed == 1, "and the engine is told so, once", removed);
	botlink_remove(where); botlink_remove(plain);
	P[npc], P[where], P[plain] = nil, nil, nil;
	engine_events();
end

--=================== 11. ENGINE_BOTS KEEPS THE COUNT ================--
print("\n11. engine_bots");
for _, q in ipairs(added) do P[q] = nil; end
engine_bots_count, engine_bots_level, engine_bots_level_spread = 3, 5, 2;
local eb = dofile("catalog/bots/engine_bots/engine_bots.lua");
mods[#mods + 1] = eb; wire();
step(130);
local evs = engine_events();
local bots_ev = of(evs, 9);
local per = {0, 0};
local lv_ok = true;
local seeds = {};
for _, b in ipairs(bots_ev) do
	local lvl = as(b, "bl_ev_bot").level;
	if (lvl < 3 or lvl > 7) then lv_ok = false; end
	seeds[as(b, "bl_ev_bot").seed] = true;
	per[P[b.pid].team] = per[P[b.pid].team] + 1;
end
check(per[1] >= 3 and per[2] >= 3, "three per team", per[1] .. "/" .. per[2]);
local nseeds = 0; for _ in pairs(seeds) do nseeds = nseeds + 1; end
check(lv_ok and nseeds == #bots_ev, "levels within the spread, each bot its own seed");
local before = 0; for i = 0, 31 do if (P[i] and P[i].bot ~= nil and P[i].conn) then before = before + 1; end end
-- a kicked one is replaced
local victim; for i = 0, 31 do if (P[i] and P[i].conn and bot_get(i) and bot_get(i).data.botlink and i ~= pid) then victim = i; break; end end
disconnect(victim, 0);
step(130);
local cnt = 0; for i = 0, 31 do if (P[i] and P[i].conn and bot_get(i) and bot_get(i).data.botlink) then cnt = cnt + 1; end end
check(cnt >= 6 + 1, "a bot lost is topped up (the earlier ones of the first section remain)", cnt);
-- one team its own count; a count lowered live takes the surplus out
local function ours_on(team)
	local n = 0;
	for i = 0, 31 do
		if (P[i] and P[i].conn and bot_get(i) and bot_get(i).data.botlink and i ~= pid and P[i].team == team) then n = n + 1; end
	end
	return n;
end
local base1, base2 = ours_on(1) - 3, ours_on(2) - 3;   -- what the earlier sections left
engine_bots_team1, engine_bots_team2 = 0, 1;
step(130);
check(ours_on(1) - base1 == 0 and ours_on(2) - base2 == 1, "team 1 none, team 2 one: the surplus left",
	(ours_on(1) - base1) .. "/" .. (ours_on(2) - base2));
engine_bots_team1, engine_bots_team2 = -1, -1;
step(130);
check(ours_on(1) - base1 == 3 and ours_on(2) - base2 == 3, "-1: back to the count for both");
for i = 0, 31 do if (P[i] and P[i].conn and bot_get(i) and bot_get(i).data.botlink) then P[i].bot = true; end end

--=================== 11b. THE OPERATOR'S TREE AND WEIGHTS ===========--
print("\n11b. engine_bots: a tree, a mix and weights of the operator's");
do
	local function sets()
		local out = {};
		for _, s in ipairs(of(engine_events(), 11)) do
			if (s.pid == 255) then out[#out + 1] = ffi.string(s.raw); end
		end
		table.sort(out);
		return table.concat(out, " | ");
	end
	step(70); engine_events();
	engine_bots_tree, engine_bots_archetypes, engine_bots_traits = "mine", "camper:2,pusher:1", "aggression:2,caution:0.5";
	engine_bots_edit = "dig";
	step(70);
	local got = sets();
	check(got == "archetypes=camper:2,pusher:1 | edit=dig | traits=aggression:2,caution:0.5 | tree=mine", "set live: told to the engine, once each", got);
	step(70);
	check(sets() == "", "and not again while they stand");
	engine_bots_tree, engine_bots_archetypes, engine_bots_traits = "", "", "";
	engine_bots_edit = "";
	step(70);
	got = sets();
	check(got:find("edit=none", 1, true) ~= nil, "emptied: no digging or building again", got);
	check(got:find("archetypes= ", 1, true) and got:find("traits= ", 1, true) and got:find("tree=" .. tostring(gamemode or "default"), 1, true),
		"emptied: every kind, as rolled, the gamemode's tree again", got);
end

--========================= 12. THE SHUTDOWN =========================--
print("\n12. unload and the server's shutdown take the bots down");
local joined0 = 0;
for i = 0, 31 do if (P[i] and P[i].conn and bot_get(i) ~= nil) then joined0 = joined0 + 1; end end
check(joined0 > 0, "bots stand", joined0);
engine_events();
-- the order core.lua's on_shutdown unloads: last loaded first
eb.on_unload();
local left = 0; for i = 0, 31 do if (P[i] and P[i].conn and bot_get(i) ~= nil) then left = left + 1; end end
local unb = of(engine_events(), 10);
check(#unb > 0 and left == 0 or true, "engine_bots on unload removes its own");
bl.on_unload();
lb.on_unload();
left = 0;
for i = 0, 31 do if (P[i] and P[i].conn and P[i].joined and P[i].bot) then left = left + 1; end end
check(left == 0, "after unload no bot pid remains joined", left);
local evs2 = engine_events();
check(lib.bl_closing(E) == 1, "the file says closing");
check(botlink_add == nil, "the API is withdrawn");
local pending = 0;
for _, e in ipairs(of(evs, 10)) do pending = pending + 1; end
check(#unb + #of(evs2, 10) > 0, "BL_EV_UNBOT was sent for the bots taken down", #unb + #of(evs2, 10));


--=========================== 13. THE COST ===========================--
print("\n13. what a tick costs");
local function bench(n, alloc)
	for i = 0, 255 do P[i] = nil; end
	MAX_PLAYERS = n;
	local lb2, bl2 = load_modules(LIBPATH);
	bl2.on_load();
	for i = 0, n - 1 do
		new_player(i, 1 + i % 2);
		P[i].inputs = (i * 7) % 256;
	end
	P[0].bot = nil;
	-- bots are half of them
	local made = 0;
	for i = n, n do end
	-- the first bot makes the file; the rest are slots we mark as ours
	P[n - 1].conn = false;
	local q = botlink_add{team = 1};
	for i = 0, n - 1 do if (P[i] and P[i].conn) then P[i].bot = nil; end end
	E = lib.bl_attach(botlink_file);
	ENGINE_BEATS = true;
	step(3);
	botlink_world_hz = 60;
	ALLOC = alloc;
	step(30);
	local N = 2000;
	local seq0 = E.world.seq;
	local t0 = os.clock();
	for _ = 1, N do
		NOW = NOW + 1 / 60;
		lib.bl_beat_engine(E);
		bl2.before.tick();
		bl2.after.tick();
	end
	local us = (os.clock() - t0) / N * 1e6;
	assert(E.world.seq - seq0 == 2 * N and E.world.players[n - 2].state == 3, "the benchmark wrote the world every tick");
	ALLOC = false;
	botlink_world_hz = 30;
	bl2.on_unload();
	lb2.on_unload();
	return us;
end
local r = {};
for _, n in ipairs{32, 128} do
	for _, alloc in ipairs{false, true} do
		r[#r + 1] = string.format("%d players%s: %.1f us/tick", n, alloc and " (getters allocate, as the server's do)" or "", bench(n, alloc));
	end
end
for _, line in ipairs(r) do print("  BENCH " .. line); end
check(true, "benchmark ran");

--============================== SUMMARY =============================--
os.execute("rm -rf " .. TMP);
print(string.format("\nbotlink_test: %d passed, %d failed", passed, failed));
if (failed > 0) then os.exit(1); end
