-- rocket_test.lua -- lib_blast, the rocket and the airstrike
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/rocket_test.lua      (from the repository root)
--
-- The trail of blocks (placed only into air, taken down only by itself,
-- all of it gone at the end), the explosion's damage falling off with
-- distance, charges, and the airstrike's warning and line of bombs.
package.path = "catalog/libs/player_effect/?.lua;catalog/libs/blast/?.lua;"
	.. "catalog/effects/player/rocket/?.lua;catalog/effects/player/airstrike/?.lua;"
	.. package.path;

local passed, failed = 0, 0;
local function check(ok, what, detail)
	if (ok) then passed = passed + 1; print("  PASS " .. what);
	else failed = failed + 1; print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or "")); end
end

--============================= STUBS ================================--
MAX_PLAYERS = 32;
PID_BROADCAST = 0x20000000;   -- PID_SET_FLAG(1), as state.h
function init_mod() return {impl = {}, after = {}, before = {}, next = {}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function pid_connected_table(d) return setmetatable({}, {__index = function() return d; end}); end
function log() end
package.loaded["lib_bulk_destroy"] = true;

local NOW = 100;
function get_time() return NOW; end
function get_anon_pid() return 254; end

-- the map: ground from z 50 down, and whatever the test adds
local solid, WALL_X, GROUND = {}, nil, 50;
local function key(p) return math.floor(p.x) .. "," .. math.floor(p.y) .. "," .. math.floor(p.z); end
function is_solid(p)
	return solid[key(p)] == true or p.z >= GROUND or (WALL_X ~= nil and p.x >= WALL_X);
end
-- as the SERVER answers, which is not as LSd's apidoc says: `last` true
-- gives the air voxel before the hit, false the solid one hit (measured
-- on a live server; the grenade shotgun relies on it too)
function raycast(a, b, last)
	local before;
	for i = 0, 400 do
		local t = i / 400;
		local p = {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t};
		local v = {x = math.floor(p.x), y = math.floor(p.y), z = math.floor(p.z)};
		if (p.z >= 0 and is_solid(p)) then
			if (last) then return before; end
			return v;
		end
		before = v;
	end
end

-- what the clients are told
local placed, removed, craters = {}, {}, 0;
local on_screen = {};
COLORS_SENT = 0;
function send_set_block_color() COLORS_SENT = COLORS_SENT + 1; end
function send_block_action(_, p, t)
	if (t == 0) then
		placed[#placed+1] = {x = p.x, y = p.y, z = p.z, solid_then = is_solid(p)};
		on_screen[key(p)] = true;
	else
		removed[#removed+1] = {x = p.x, y = p.y, z = p.z};
		on_screen[key(p)] = nil;
	end
end
function bdestroy_block_action(p, t)
	craters = craters + 1;
	for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
		solid[key({x = p.x + dx, y = p.y + dy, z = p.z + dz})] = nil;
	end end end
end
function bdestroy_finish() end

-- players: 0 the shooter (team 1), 1 and 2 enemies, 3 a teammate
local TEAM = {[0] = 1, [1] = 2, [2] = 2, [3] = 1};
local POS = {};
local ORI = {[0] = {x = 1, y = 0, z = 0}};
local ALIVE = {[0] = true, [1] = true, [2] = true, [3] = true};
function piditer() local i = -1; return function() i = i + 1; if (i <= 3) then return i; end end; end
function get_team(p) return TEAM[p]; end
function get_position(p) return POS[p] or {x = 0, y = 0, z = 0}; end
function get_orientation(p) return ORI[p]; end
function is_alive(p) return ALIVE[p]; end
function is_connected() return true; end
function get_name(p) return "P" .. p; end
function get_tool() return 2; end
function get_gun() return 0; end
local dmg = {};
function damage_player(p, n, kt, by) dmg[#dmg+1] = {pid = p, n = n, kt = kt, by = by}; end
-- the real lib_l10n: send_chat lines are what the players read
local L = dofile("tests/support/l10n_env.lua").load{};
L.pids = {0, 1, 2, 3};
local chat = L.chat;
local listeners = {};
function shot_listen(n, f) listeners[n] = f; end
function shot_unlisten(n) listeners[n] = nil; end
local pings = {};
function teamplay_ping_all(pos, o) pings[#pings+1] = {pos = pos, o = o}; end

dofile("catalog/libs/player_effect/lib_player_effect.lua");
local blast = dofile("catalog/libs/blast/lib_blast.lua");
for k, v in pairs(blast.impl) do _G[k] = v; end

local function ticks(n) for _ = 1, n do blast.after.tick(); end end
local function reset()
	placed, removed, dmg, pings, craters = {}, {}, {}, {}, 0;
	L.reset();
	on_screen, solid, WALL_X, GROUND = {}, {}, nil, 50;
	POS = {[0] = {x = 50.5, y = 50.5, z = 30.5}, [1] = {x = 300, y = 300, z = 30},
		[2] = {x = 300, y = 310, z = 30}, [3] = {x = 300, y = 320, z = 30}};
	blast_clear();
end

--============================= CHECKS ===============================--
print("\n1. the trail: into air only, taken down by itself, all of it at the end");
reset();
WALL_X = 120;
solid["110,50,30"] = nil;
blast_fire(0, {x = 100.5, y = 50.5, z = 30.5}, {x = 1, y = 0, z = 0}, {speed = 2});
ticks(3);
local mid = #placed;
check(mid > 0, "a streak is drawn while it flies");
local screen = 0; for _ in pairs(on_screen) do screen = screen + 1; end
check(screen <= 6 + 4, "and it is short, not the whole way", screen);
-- a player builds on a cell the streak occupies: not ours to send away
local victim = placed[2];
solid[key(victim)] = true;
ticks(40);
local all_air = true;
for _, p in ipairs(placed) do if (p.solid_then) then all_air = false; end end
check(all_air, "every block was placed into air");
check(craters > 0, "it exploded on the wall");
local gone = {};
for _, r in ipairs(removed) do gone[key(r)] = true; end
check(gone[key(victim)] == nil, "a block a player built on a trail cell is never removed");
local left = 0;
for _, p in ipairs(placed) do
	if (not gone[key(p)] and key(p) ~= key(victim)) then left = left + 1; end
end
check(left == 0, "every other trail block came down", left);
local fine = true;
local was = {}; for _, p in ipairs(placed) do was[key(p)] = true; end
for _, r in ipairs(removed) do if (not was[key(r)]) then fine = false; end end
check(fine, "only blocks the rocket placed were removed");

print("\n1b. no two trail blocks on screen share a face, whatever the path");
local function faces_shared()
	for k in pairs(on_screen) do
		local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)");
		x, y, z = tonumber(x), tonumber(y), tonumber(z);
		for _, d in ipairs({{1,0,0},{0,1,0},{0,0,1}}) do
			if (on_screen[(x+d[1]) .. "," .. (y+d[2]) .. "," .. (z+d[3])]) then return k; end
		end
	end
end
for _, dir in ipairs({{x = 1, y = 0, z = 0}, {x = 0.6, y = 0.5, z = 0.2}, {x = 0, y = 0, z = 1}}) do
	reset();
	WALL_X = 400;
	blast_fire(0, {x = 100.5, y = 50.5, z = 5.5}, dir, {speed = 2});
	local bad;
	for _ = 1, 25 do ticks(1); bad = bad or faces_shared(); end
	check(bad == nil and #placed > 0, string.format("path %.1f,%.1f,%.1f: never two blocks face to face",
		dir.x, dir.y, dir.z), bad);
end
reset();
WALL_X = 400;
blast_fire(0, {x = 100.5, y = 50.5, z = 30.5}, {x = 1, y = 0, z = 0}, {speed = 2});
ticks(6);
local n = 0; for _ in pairs(on_screen) do n = n + 1; end
check(n >= 2, "a straight rocket still shows a streak, every other block", n);

print("\n1d. the trail is cheap: packets queued behind it would delay the blast");
reset();
WALL_X = 160;   -- 60 cells of flight
COLORS_SENT = 0;
blast_fire(0, {x = 100.5, y = 50.5, z = 30.5}, {x = 1, y = 0, z = 0}, {speed = 2});
ticks(40);
check(COLORS_SENT <= 1, "one colour for the whole flight", COLORS_SENT);
check(#placed <= 60 / 3 + 1, "a block every third cell at most", #placed);

print("\n1c. an impact on the ground (z 62) still digs a crater");
reset();
GROUND = 62;
blast_fire(0, {x = 100.5, y = 50.5, z = 55.5}, {x = 0, y = 0, z = 1}, {speed = 2});
ticks(10);
check(craters > 0, "craters dug at ground level", craters);

print("\n2. it stops at a block in the way, and never draws on it");
reset();
solid["108,50,30"] = true;
WALL_X = 200;
blast_fire(0, {x = 100.5, y = 50.5, z = 30.5}, {x = 1, y = 0, z = 0}, {speed = 2});
ticks(30);
local past = false;
for _, p in ipairs(placed) do if (p.x >= 108) then past = true; end end
check(not past, "no block at or beyond the obstacle");
check(solid["108,50,30"] == nil, "the obstacle was blown away");
check(#removed == #placed, "trail cleaned up", #placed .. "/" .. #removed);

print("\n3. it unloads cleanly: blast_clear takes everything down at once");
reset();
WALL_X = 400;
blast_fire(0, {x = 100.5, y = 50.5, z = 30.5}, {x = 1, y = 0, z = 0}, {speed = 3});
ticks(6);
blast.on_unload();
local still = 0; for _ in pairs(on_screen) do still = still + 1; end
check(#placed > 0 and still == 0, "nothing left on anyone's screen");

print("\n4. it flies into a living enemy and explodes on them");
reset();
WALL_X = 400;
POS[1] = {x = 120, y = 50.5, z = 30.5};
blast_fire(0, {x = 100.5, y = 50.5, z = 30.5}, {x = 1, y = 0, z = 0}, {speed = 2, damage = 90, radius = 3});
ticks(30);
local d1;
for _, d in ipairs(dmg) do if (d.pid == 1) then d1 = d; end end
check(d1 ~= nil and d1.n >= 70 and d1.by == 0 and d1.kt == 3, "a near-direct hit hurts, credited to the shooter",
	d1 and d1.n);
local past2 = false;
for _, p in ipairs(placed) do if (p.x > 121) then past2 = true; end end
check(not past2, "it did not fly on through him");

print("\n5. explosion damage falls off with distance, teammates spared, cover respected");
reset();
POS[1] = {x = 50.5, y = 50.5, z = 29.5};   -- at the centre
POS[2] = {x = 53.5, y = 50.5, z = 29.5};   -- half the reach (radius 3, reach 6)
POS[3] = {x = 51.5, y = 50.5, z = 29.5};   -- a teammate right there
POS[0] = {x = 50.5, y = 56.5, z = 29.5};   -- the shooter, 6 away: out of reach
blast_explode(0, {x = 50.5, y = 50.5, z = 30.5}, 3, 100, nil, nil);
local by = {};
for _, d in ipairs(dmg) do by[d.pid] = d.n; end
check(by[1] ~= nil and by[1] >= 90, "at the centre: nearly all of it", by[1]);
check(by[2] ~= nil and by[2] > 35 and by[2] < 60, "half way out: about half", by[2]);
check(by[1] > by[2], "less with distance");
check(by[3] == nil, "a teammate takes none");
check(by[0] == nil, "out of reach: none");
reset();
POS[0] = {x = 51.5, y = 50.5, z = 29.5};
POS[1] = {x = 300, y = 300, z = 30};
blast_explode(0, {x = 50.5, y = 50.5, z = 30.5}, 3, 100, nil, nil);
check(dmg[1] and dmg[1].pid == 0 and dmg[1].n < 40, "the shooter takes a third", dmg[1] and dmg[1].n);
reset();
-- a thick wall between the blast and the man behind it
for x = 52, 55 do for z = 25, 35 do for y = 45, 55 do solid[x .. "," .. y .. "," .. z] = true; end end end
POS[1] = {x = 56.5, y = 50.5, z = 29.5};
blast_explode(0, {x = 50.5, y = 50.5, z = 30.5}, 3, 100, nil, nil);
local hurt1 = false;
for _, d in ipairs(dmg) do if (d.pid == 1) then hurt1 = true; end end
check(not hurt1, "no damage through a wall that stands");

print("\n5b. one-shot inside kill_radius, falloff beyond; never the owner");
reset();
local c = {x = 60.5, y = 60.5, z = 30};
POS[1] = {x = 62, y = 60.5, z = 29.5};   -- 1.5 blocks off
POS[2] = {x = 63.5, y = 60.5, z = 29.5}; -- 3 blocks off
POS[0] = {x = 61, y = 60.5, z = 29.5};   -- the owner, right there
blast_explode(0, c, 3, 50, nil, nil, 2);
local got = {};
for _, d in ipairs(dmg) do got[d.pid] = d.n; end
check(got[1] and got[1] >= 100, "within kill_radius (2): one shot", got[1]);
check(got[2] and got[2] < 50, "beyond it: the falloff", got[2]);
check(got[0] and got[0] < 50, "the owner is never one-shot by their own", got[0]);
reset();
POS[1] = {x = 120, y = 50.5, z = 30.5};
blast_fire(0, {x = 100.5, y = 50.5, z = 30.5}, {x = 1, y = 0, z = 0}, {speed = 2, damage = 30, kill_radius = 2});
WALL_X = 400; ticks(30);
local hit;
for _, d in ipairs(dmg) do if (d.pid == 1) then hit = d; end end
check(hit and hit.n >= 100, "a direct hit kills even a weak blast", hit and hit.n);

print("\n5c. a guided blast turns to follow the point its guide names");
reset();
WALL_X = 400;
local goal = {x = 100.5, y = 80.5, z = 30.5};
local gb = blast_fire(0, {x = 100.5, y = 50.5, z = 30.5}, {x = 1, y = 0, z = 0},
	{speed = 1, range = 300, guide = function() return goal; end});
ticks(2);
local y0 = gb.vox.y;
ticks(10);
check(gb.vox.y > y0 + 5 and math.abs(gb.vox.x - 100) <= 2,
	"fired along x, it flies to the guide's point along y", gb.vox.x .. "," .. gb.vox.y);
goal = {x = 140.5, y = gb.vox.y + 0.5, z = 30.5};
local x0 = gb.vox.x;
ticks(10);
check(gb.vox.x > x0 + 5, "and turns again when the point moves, in real time", gb.vox.x);
reset();
ORI[0] = {x = 1, y = 0, z = 0};
WALL_X = 130;
local a = blast_aim(0);
check(a and math.floor(a.x) == 130, "blast_aim: the first block along the aim", a and a.x);

print("\n5d. a guided blast that reaches its point in the air goes off there, not circling it");
reset();
WALL_X = 400;
local airpt = {x = 120.5, y = 50.5, z = 30.5};
local ab = blast_fire(0, {x = 100.5, y = 50.5, z = 30.5}, {x = 1, y = 0, z = 0},
	{speed = 1, range = 300, guide = function() return airpt; end});
ticks(30);
check(ab.done and craters > 0 and ab.vox.x >= 119 and ab.vox.x <= 121, "exploded at the point", ab.vox.x);

print("\n5e. every impact plays a grenade explosion for the clients, harmless");
reset();
local SENT = {};
local real_sg = send_grenade;
send_grenade = function(to, pos, vel, fuse, from) SENT[#SENT+1] = {to = to, pos = pos, fuse = fuse, from = from}; end
local reg0 = register_grenade;
local registered = 0;
register_grenade = function(...) registered = registered + 1; end
blast_explode(0, {x = 60.5, y = 60.5, z = 30}, 3, 50);
check(#SENT == 1 and SENT[1].to == PID_BROADCAST and SENT[1].fuse == 0 and SENT[1].from == get_anon_pid(),
	"a zero-fuse grenade to everyone, from nobody's stock");
check(registered == 0, "never registered: it does no damage of its own");
send_grenade, register_grenade = real_sg, reg0;

print("\n6. the rocket effect: charges, one a shot, a gap between");
reset();
WALL_X = 400;
local rmod = dofile("catalog/effects/player/rocket/rocket.lua");
rmod.on_load();
local rocket = PlayerEffect.get("rocket");
check(rocket ~= nil and listeners.rocket ~= nil, "loaded, listening for shots of any gun");
rocket.everyone = false;
local launched = 0;
local real_fire = blast_fire;
blast_fire = function(...) launched = launched + 1; return real_fire(...); end
local function shots() local n = launched; ticks(3); return launched > n; end
local function shot(gun) local n = launched; listeners.rocket(0, gun); return launched > n; end
check(not shot(0), "no charges, not everybody's: a shot is only a shot");
for _ = 1, 2 do rocket:give(0, {death = true, stack = true}); end
check(rocket:stacks(0) == 2, "two charges given");
NOW = NOW + 1;
check(shot(1), "a shot of the SMG fires a rocket");
check(rocket:stacks(0) == 1, "and uses one charge");
check(not shot(0) and rocket:stacks(0) == 1, "a second shot inside the gap costs nothing");
NOW = NOW + 1;
check(shot(2) and rocket:stacks(0) == 0, "the next one fires and uses the last");
NOW = NOW + 1;
check(not shot(0), "out of charges: the guns are guns again");
local n0 = launched;
check(rocket:trigger(0) ~= nil and launched == n0 + 1, "trigger fires one free");
local seen;
blast_fire = function(o, pos, dir, opts) seen = dir; return real_fire(o, pos, dir, opts); end
local eye = get_position(0);
rocket:trigger(0, {pos = {x = eye.x, y = eye.y + 10, z = eye.z}});
check(seen ~= nil and math.abs(seen.y - 1) < 1e-6 and math.abs(seen.x) < 1e-6,
	"given a point (the pie's %h), it flies straight at it, whatever the facing");
blast_fire = function(...) launched = launched + 1; return real_fire(...); end
rocket.everyone = true;
NOW = NOW + 1;
check(shot(0), "while it is everybody's, every shot is a rocket");
blast_fire = real_fire;

print("\n6b. the missile: launched at once, steered by its sender's live aim");
reset();
WALL_X = 400;
local mmod = dofile("catalog/effects/player/missile/missile.lua");
mmod.on_load();
local mis = PlayerEffect.get("missile");
local mb = mis:trigger(0, {});
check(mb ~= nil and mb.guide ~= nil and mb.kill_radius == 2, "a guided blast, one-shot within 2 blocks");
check(math.abs(mb.speed - 1.2) < 1e-9, "slower than a rocket, to be steered");
WALL_X = 130;
ORI[0] = {x = 1, y = 0, z = 0};
local g = mb.guide(mb);
check(g and math.floor(g.x) == 130, "it heads for the block under its sender's crosshair", g and g.x);
ALIVE[0] = false;
check(mb.guide(mb) == nil, "its sender dead: it flies straight on");
ALIVE[0] = true;
blast_clear();

print("\n6c. the grenade launcher: a real grenade, fused to go off where it lands");
reset();
-- the client's physics, near enough: gravity, and a "hit" on solid ground
function simulate_grenade_physics(pos, vel, dt)
	local v = {x = vel.x, y = vel.y, z = vel.z + dt};
	local p = {x = pos.x + v.x * dt * 32, y = pos.y + v.y * dt * 32, z = pos.z + v.z * dt * 32};
	return p, v, is_solid(p);
end
local GREN, SENT_GREN = {}, {};
function register_grenade(pid, team, pos, vel, fuse) GREN[#GREN+1] = {pid = pid, team = team, pos = pos, vel = vel, fuse = fuse}; return #GREN - 1; end
function send_grenade(to, pos, vel, fuse, from) SENT_GREN[#SENT_GREN+1] = {to = to, fuse = fuse, from = from}; end
function PID_BROADCAST_EXCEPT(pid) return -100 - pid; end
local glmod = dofile("catalog/effects/player/grenade_launcher/grenade_launcher.lua");
glmod.on_load();
local gl = PlayerEffect.get("grenade_launcher");
ORI[0] = {x = 1, y = 0, z = 0};
POS[0] = {x = 50.5, y = 50.5, z = 30.5};
local fuse = gl:trigger(0, {});
check(#GREN == 1 and GREN[1].pid == 0 and GREN[1].team == 1, "one grenade, the shooter's, on their team");
check(GREN[1].vel.x > 1.5 and GREN[1].pos.x > 51, "fired hard along the aim, from in front of the eye");
-- the same physics, run here
local function fly(g, until_fn)
	local p, v, t = {x = g.pos.x, y = g.pos.y, z = g.pos.z}, {x = g.vel.x, y = g.vel.y, z = g.vel.z}, 0;
	while (t < 6) do
		local hit; p, v, hit = simulate_grenade_physics(p, v, 1/60);
		if (hit) then return t, p, true; end
		t = t + 1/60;
		if (until_fn(p)) then return t, p, false; end
	end
end
local t40, p40 = fly(GREN[1], function(p) return math.abs(p.x - GREN[1].pos.x) >= 40; end);
check(math.abs(fuse - t40) < 1/60 + 1e-9, "nothing aimed at within 40 blocks: it goes off 40 blocks out", fuse .. " vs " .. t40);
-- a wall 20 blocks ahead, aimed at: it goes off by it, not at the landing
reset();
WALL_X = 75;
GREN, SENT_GREN = {}, {};
local f2 = gl:trigger(0, {});
local t2, q2 = fly(GREN[1], function(p) return p.x >= 74; end);
check(f2 > 0 and f2 <= t2 + 1/60 + 1e-9, "aimed at a wall in range: it goes off at the wall, where the crosshair is", f2 .. " vs " .. t2);
WALL_X = nil;
local own, others;
for _, g in ipairs(SENT_GREN) do
	if (g.to == 0) then own = g; elseif (g.to == PID_BROADCAST_EXCEPT(0)) then others = g; end
end
check(others and others.from == 0 and others.fuse == f2, "everyone else sees the shooter's grenade, same fuse");
check(own and own.from == get_anon_pid(), "the shooter's own copy is anonymous: it costs none of their grenades");
ORI[0] = {x = 0, y = 0, z = -1};   -- straight up, into the open sky
GREN = {};
check(gl:trigger(0, {}) <= grenade_launcher_max_fuse, "one that hits nothing goes off at the cap anyway");

print("\n7. the airstrike: a warning, then bombs in a line across the target");
reset();
NOW = 500;
local amod = dofile("catalog/effects/player/airstrike/airstrike.lua");
amod.on_load();
local air = PlayerEffect.get("airstrike");
local fired = {};
local real = blast_fire;
blast_fire = function(owner, pos, dir, o) fired[#fired+1] = {pos = pos, dir = dir, o = o}; return real(owner, pos, dir, o); end
ORI[0] = {x = 0, y = 1, z = 0};
local target = {x = 80.5, y = 70.5, z = 49.5};
local saved = {POS[0], POS[1], POS[2]};
POS[0] = {x = 200, y = 200, z = 30};   -- the caller, far off
POS[1] = {x = 85, y = 72, z = 48};     -- an enemy by the target
check(air:trigger(0, {pos = target}) == target, "trigger(pid, {pos}) answers the point");
POS[0], POS[1], POS[2] = saved[1], saved[2], saved[3];
check(#pings == 1 and pings[1].o.reason.en == "Airstrike!" and pings[1].pos == target,
	"a Teamplay ping on the target for everyone");
local all, big = nil, {};
for _, c in ipairs(chat) do
	if (c.to == PID_BROADCAST) then all = c; end
	if (c.text == "AIRSTRIKE INCOMING -- TAKE COVER!") then big[c.to] = true; end
end
check(all ~= nil, "and a chat line to all");
check(all and all.text == "P0 called in an airstrike! Get out of there!", "naming the caller", all and all.text);
check(big[1] and not big[0] and not big[2],
	"whoever is within airstrike_warn_radius of the target is warned across the screen; the far-off are not");
amod.after.tick();
check(#fired == 0, "nothing falls before the delay");
NOW = NOW + 3.05;
amod.after.tick();
check(#fired == 1, "the first bomb falls after the delay", #fired);
NOW = NOW + 2;
amod.after.tick();
check(#fired == 5, "five bombs in all", #fired);
local ys = {};
for _, f in ipairs(fired) do ys[#ys+1] = f.pos.y; end
table.sort(ys);
check(ys[1] == 62.5 and ys[5] == 78.5 and ys[3] == 70.5, "in a line along the caller's facing, 4 apart", table.concat(ys, ","));
check(fired[1].pos.x == 80.5 and fired[1].pos.z < 1 and fired[1].dir.z == 1,
	"each falls straight from the sky", fired[1].pos.x);
ticks(80);
check(craters > 0 and #placed > 0, "they draw a falling trail and explode");
local still2 = 0; for _ in pairs(on_screen) do still2 = still2 + 1; end
ticks(10);
still2 = 0; for _ in pairs(on_screen) do still2 = still2 + 1; end
check(still2 == 0, "and leave no block behind", still2);

print("\n8. aimed with no point given; nothing to aim at");
reset();
fired = {};
POS[0] = {x = 60.5, y = 60.5, z = 40.5};
ORI[0] = {x = 1, y = 0, z = 0};
WALL_X = 90;
local p = air:trigger(0, {});
check(p ~= nil and p.x == 90.5, "the first block along the aim", p and p.x);
WALL_X = nil;
ORI[0] = {x = 0, y = 0, z = -1};
check(air:trigger(0, {}) == nil, "aimed at the open sky: no strike");
blast_fire = real;

L.clean(check);
print(string.format("\n%d checks, %d failed", passed + failed, failed));
os.exit(failed == 0 and 0 or 1);
