-- rewards_test.lua -- lib_rewards: earning, spending, the pie
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/rewards_test.lua      (from the repository root)
--
-- Points from kills and captures, the cap, the menu and what each entry
-- gives, the pie's wedges shown only while affordable (and for the
-- night's alone at night), and effects that stop being everybody's.
package.path = "catalog/libs/player_effect/?.lua;catalog/tools/rewards/?.lua;" .. package.path;

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
local NOW = 100;
function get_time() return NOW; end
local TEAM = {[0] = 1, [1] = 1, [2] = 2};
local ALIVE = {[0] = true, [1] = true, [2] = true};
function get_team(p) return TEAM[p]; end
function is_alive(p) return ALIVE[p]; end
function is_connected() return true; end
function get_name(p) return "P" .. p; end
function piditer() local i = -1; return function() i = i + 1; if (i <= 2) then return i; end end; end
-- the real lib_l10n: what the player reads, not a stand-in for it
local L = dofile("tests/support/l10n_env.lua").load{};
L.pids = {0, 1, 2};
local chat = L.chat;
local function last() return chat[#chat]; end

local cmd;
function register_command(c) cmd = c; end
local pie;
function pie_menu_add(name, p) pie = p; end
function pie_menu_remove() pie = nil; end
local refreshed = {};
function pie_menu_refresh(pid) refreshed[#refreshed+1] = pid or "all"; end

local night = false;
function daytime_is_night() return night; end

local lib = dofile("catalog/libs/player_effect/lib_player_effect.lua");

-- the effects the menu offers, as small stand-ins on the real class
local triggered = {};
local function effect(name, trigger)
	local fx = PlayerEffect {name = name, warning = {en = name}, gun = (not trigger) and 0 or nil,
		trigger = trigger};
	fx.mod.on_load();
	return fx;
end
local rail = effect("railgun");
local rocket = effect("rocket", function(pid, o) triggered.rocket = o; return {}; end);
local air = effect("airstrike", function(pid, o) triggered.air = o; return o.pos or {x = 1, y = 1, z = 1}; end);
local kit = effect("medkit", function(pid, o) triggered.kit = o; if (triggered.full) then return nil; end return 40; end);
local heal = effect("area_heal", function() end);
local nv = effect("nightvision", function() end);
check(rail.everyone and nv.everyone, "effects start out everybody's");

local mod = dofile("catalog/tools/rewards/lib_rewards.lua");
mod.on_load();
check(not rail.everyone and not air.everyone and not nv.everyone,
	"the rewards take the effects they offer away from everybody");

local function kill(killer, victim, kt) mod.after.kill(victim, kt or 0, killer); end
local function run(...) cmd.func(0, {...}); end
local function wedge(i) return pie.slices[i]; end
local function visible()
	local out = {};
	for i, s in ipairs(pie.slices) do if (s.show(0)) then out[#out+1] = s.text; end end
	return out;
end

--============================= EARNING ==============================--
print("\n1. a point for every rewards_kills kills, across lives");
mod.after.tick();
check(pie ~= nil and pie.when == "alive" and #pie.slices == 6, "a pie of six wedges, for the living");
for i = 1, 9 do kill(0, 2); end
check(#chat == 0, "nine kills: nothing yet");
kill(0, 2);
check(last() and last().m:find("earned a reward") and last().to == PID_BROADCAST,
	"the tenth: a short global line");
check(chat[#chat-1].to == 0 and chat[#chat-1].a.points == 1, "and the player is told, privately");
check(refreshed[#refreshed] == 0, "the pie is refreshed for them");

print("\n2. kills that do not count");
local n = #chat;
for i = 1, 20 do kill(0, 1); end          -- teammate
for i = 1, 20 do kill(0, 0); end          -- suicide
for i = 1, 20 do kill(0, 2, 4); end       -- not a kill (a team change)
check(#chat == n, "teamkills, suicides and non-kills earn nothing");

print("\n3. the cap, and the count that waits at it");
for i = 1, 20 do kill(0, 2); end
check(#chat > n, "two more points");
n = #chat;
for i = 1, 30 do kill(0, 2); end
check(#chat == n, "at rewards_max (3) no more is earned");
mod.after.capture_intel(0);
check(#chat == n, "not by a capture either");

print("\n4. a capture is a point");
run("railgun");   -- spend one: 2 left
check(rail:has(0), "(spent one on the railgun)");
n = #chat;
mod.after.capture_intel(0);
check(chat[n+1] and chat[n+1].a.points == 3, "a capture earns rewards_capture");
gamemode = "tdm";
local k = #chat;
mod.after.capture_intel(0);
gamemode = "ctf";
check(#chat == k, "but not tdm's winning capture, which is not one");

--============================= SPENDING =============================--
print("\n5. /reward lists, /reward <name> spends");
L.reset();
run();
check(chat[1].m:find("you have") and chat[1].a.points == 3, "the list says the points held");
local lines = 0; for _, c in ipairs(chat) do if (c.m:find("/reward %(name)", 1, true)) then lines = lines + 1; end end
check(lines == 5, "and every reward on offer (night vision is not, by day)", lines);

print("\n6. what each reward gives");
for p in pairs({}) do end
rail:take(0);
run("railgun");
check(rail:has(0) and rail:stacks(0) == 1, "railgun: a grant, only for them");
check(not rail:has(1), "and nobody else");
local g = rail.grants[0][1];
check(g.death == true and g.ends > get_time() and g.ends <= get_time() + 30, "for 30 s or until death");
-- 2 points left
run("rocket", "5", "6", "7");
check(triggered.rocket ~= nil and triggered.rocket.pos.x == 5 and triggered.rocket.pos.z == 7,
	"rocket: fired at once, at the point aimed at, like the airstrike");
check(rocket:stacks(0) == 0, "no charges left on the gun");
-- 1 left; airstrike costs 2
L.reset();
run("airstrike", "10", "20", "30");
check(last().m:find("costs") and triggered.air == nil, "airstrike: refused for want of points");
mod.after.capture_intel(0);
run("airstrike", "10", "20", "30");
check(triggered.air ~= nil and triggered.air.pos.x == 10 and triggered.air.pos.z == 30,
	"airstrike: triggered at the point the pie sent");
mod.after.capture_intel(0);
local points_before = last();
triggered.full = true;
L.reset();
run("medkit");
check(last().m:find("no point spent"), "a trigger that does nothing (full health) is not paid for");
triggered.full = false;
run("medkit");
check(triggered.kit and triggered.kit.free == true, "medkit: triggered, free of kits");
ALIVE[0] = false;
mod.after.capture_intel(0);
run("area_heal");
check(last().m:find("living"), "the dead cannot spend");
ALIVE[0] = true;
run("area_heal");
check(heal:has(0) and not heal:has(1), "area heal: for them");
run("nope");
local said_no = false;
for _, c in ipairs(chat) do if (c.m:find("No such reward")) then said_no = true; end end
check(said_no, "an unknown name says so");

--============================== THE PIE =============================--
print("\n7. a wedge only while the player can afford it");
local pts = {};
-- start over: points back to zero by joining anew
mod.on_unload();
mod = dofile("catalog/tools/rewards/lib_rewards.lua");
mod.on_load();
mod.after.tick();
check(#visible() == 0, "no points, no wedge");
mod.after.capture_intel(0);
local v = visible();
check(#v == 4 and v[1] == "/reward railgun", "one point: the 1-point rewards", #v);
check(wedge(3).text == "/reward airstrike %h" and not wedge(3).show(0),
	"airstrike's wedge sends %h, and needs two");
mod.after.capture_intel(0);
check(wedge(3).show(0), "two points: it shows");
run("airstrike", "1", "2", "3");
check(#visible() == 0, "spent: the wedges vanish");
check(refreshed[#refreshed] == 0, "and the pie was refreshed");

print("\n8. a reward whose effect is not loaded is not offered");
mod.after.capture_intel(0);
PlayerEffect.get("medkit").mod.on_unload();
local texts = visible();
local has_kit = false;
for _, t in ipairs(texts) do if (t:find("medkit")) then has_kit = true; end end
check(not has_kit, "no medkit wedge");
L.reset();
run();
local listed = false;
for _, c in ipairs(chat) do if (c.a.name == "medkit") then listed = true; end end
check(not listed, "and not in /reward");

print("\n9. night vision: offered only at night");
local nvwedge = wedge(6);
check(nvwedge.text == "/reward nightvision", "its wedge");
mod.after.capture_intel(0);
check(not nvwedge.show(0), "by day: hidden");
L.reset();
run("nightvision");
check(last().m:find("only offered at night") and not nv:has(0), "by day: the command says it is for the night");
night = true;
check(nvwedge.show(0), "at night: shown");
run("nightvision");
check(nv:has(0), "at night: given");
local before = #refreshed;
NOW = NOW + 2;
mod.after.tick();
check(#refreshed > before, "the wedges are refreshed when day turns to night");
before = #refreshed;
NOW = NOW + 2;
night = false;
mod.after.tick();
check(#refreshed > before, "and when night turns to day");
check(nv:has(0), "and a granted night vision runs on");

print("\n10. everyone: the effects go back on unload, and rewards_exclusive = false leaves them alone");
mod.on_unload();
check(rail.everyone and air.everyone, "unloaded: everybody's again (their <id>_everyone)");
rewards_exclusive = false;
mod = dofile("catalog/tools/rewards/lib_rewards.lua");
mod.on_load();
check(rail.everyone, "rewards_exclusive = false: left as it was");

L.clean(check);
print(string.format("\n%d checks, %d failed", passed + failed, failed));
os.exit(failed == 0 and 0 or 1);
