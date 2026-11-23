-- rewards_test.lua -- lib_rewards: earning, the inventory, using
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/rewards_test.lua      (from the repository root)
--
-- Rewards from kills and captures into the real lib_inventory, the cap,
-- what each reward gives when used, the ones kept when they cannot be
-- used, free mode, and effects that stop being everybody's.
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

local cmds = {};
function register_command(c)
	for _, n in ipairs(type(c.name) == "table" and c.name or {c.name}) do cmds[n] = c; end
end
-- commands.lua's: a line run as the player
function handle_command(pid, line)
	local argv = {};
	for w in string.gmatch(line, "%S+") do argv[#argv+1] = w; end
	local name = table.remove(argv, 1);
	cmds[name].func(pid, argv);
end
function pie_menu_add() end
function pie_menu_remove() end
function pie_menu_refresh() end

local night = false;
function daytime_is_night() return night; end

dofile("catalog/libs/player_effect/lib_player_effect.lua");
local inv = dofile("catalog/tools/inventory/lib_inventory.lua");

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
local nv = effect("nightvision", function() end);
check(rail.everyone and nv.everyone, "effects start out everybody's");

local mod = dofile("catalog/tools/rewards/lib_rewards.lua");
mod.on_load();
check(not rail.everyone and not air.everyone and not nv.everyone,
	"the rewards take the effects they offer away from everybody");

local KEYS = {"railgun", "rocket", "airstrike", "medkit", "nightvision"};
local function total(pid)
	local n = 0;
	for _, k in ipairs(KEYS) do n = n + inventory_count(pid, k); end
	return n;
end
local function empty(pid) for _, k in ipairs(KEYS) do inventory_set(pid, k, 0); end end
local function kill(killer, victim, kt) mod.after.kill(victim, kt or 0, killer); end
local function reward(...) cmds.reward.func(0, {...}); end

--============================= EARNING ==============================--
print("\n1. a reward for every rewards_kills kills, into the inventory");
for i = 1, 9 do kill(0, 2); end
check(#chat == 0 and total(0) == 0, "nine kills: nothing yet");
kill(0, 2);
check(total(0) == 1, "the tenth: one reward in the inventory");
check(last().to == PID_BROADCAST and last().text == "P0 earned a reward", "a short global line", last().text);
check(chat[#chat-1].to == 0 and chat[#chat-1].text:find("^You earned: %u"), "and the player is told which, by name",
	chat[#chat-1].text);
check(inventory_count(0, "missile") == 0 and inventory_count(0, "area_heal") == 0,
	"never one whose effect is not loaded");

print("\n2. kills that do not count");
local n = total(0);
for i = 1, 12 do kill(0, 1); end
for i = 1, 12 do kill(0, 0); end
for i = 1, 12 do kill(0, 2, 5); end
check(total(0) == n, "teammates, oneself, and deaths that are no kill");

print("\n3. the cap, and the count that waits at it");
for i = 1, 40 do kill(0, 2); end
check(total(0) == rewards_max, "no more than rewards_max held", total(0));
empty(0);
kill(0, 2);
check(total(0) == 1, "at the cap the count waited: one kill after using, the next reward");
mod.after.load_map();
for i = 1, 9 do kill(0, 2); end
check(total(0) == 1, "a new map starts the kill count again");

print("\n4. a capture earns one too, except tdm's winning one");
empty(0);
mod.after.capture_intel(0);
check(total(0) == rewards_capture, "a capture");
gamemode = "tdm";
mod.after.capture_intel(0);
check(total(0) == rewards_capture, "tdm's capture is the end of its game, not one");
gamemode = "ctf";

print("\n5. the costlier, the rarer");
local seen = {};
for _ = 1, 400 do
	empty(1);
	mod.after.capture_intel(1);
	for _, k in ipairs(KEYS) do if (inventory_count(1, k) > 0) then seen[k] = (seen[k] or 0) + 1; end end
end
empty(1);
check((seen.rocket or 0) > (seen.airstrike or 0) and (seen.airstrike or 0) > 0,
	"cost 2 comes up, and less often than cost 1", (seen.rocket or 0) .. " vs " .. (seen.airstrike or 0));

--============================== USING ===============================--
print("\n6. used from the inventory, each gives its effect");
empty(0);
inventory_give(0, "railgun"); inventory_give(0, "rocket"); inventory_give(0, "airstrike");
inventory_give(0, "medkit"); inventory_give(0, "nightvision");
cmds.inv.func(0, {"railgun"});
check(rail:has(0) and not rail:has(1) and inventory_count(0, "railgun") == 0, "railgun: a grant, theirs alone, the item used");
local g = rail.grants[0][1];
check(g.death == true and g.ends > get_time() and g.ends <= get_time() + 30, "for 30 s or until death");
cmds.inv.func(0, {"rocket", "5", "6", "7"});
check(triggered.rocket and triggered.rocket.pos.x == 5 and triggered.rocket.pos.z == 7 and inventory_count(0, "rocket") == 0,
	"rocket: fired at the point aimed at");
reward("airstrike", "10", "20", "30");
check(triggered.air and triggered.air.pos.x == 10 and inventory_count(0, "airstrike") == 0,
	"/reward <name>, typed: the same, through the inventory");
triggered.air = nil;
reward("airstrike", "10", "20", "30");
check(triggered.air == nil and last().text:find("You have no Airstrike"), "typed without one: nothing, and why", last().text);
reward("nope");
check(last().text:find("No such reward"), "an unknown name is said so");

print("\n7. a reward that cannot be used now is kept");
triggered.full = true;
cmds.inv.func(0, {"medkit"});
check(inventory_count(0, "medkit") == 1 and last().text == "Medkit could not be used right now; you keep it.",
	"a medkit at full health", last().text);
triggered.full = false;
cmds.inv.func(0, {"medkit"});
check(inventory_count(0, "medkit") == 0 and triggered.kit.free == true, "then used, with the menu's own options");
cmds.inv.func(0, {"nightvision"});
check(inventory_count(0, "nightvision") == 1 and not nv:has(0) and last().text == "Night vision is only for the night.",
	"night vision by day", last().text);
night = true;
cmds.inv.func(0, {"nightvision"});
check(nv:has(0) and inventory_count(0, "nightvision") == 0, "at night it works");
night = false;
inventory_give(0, "rocket");
ALIVE[0] = false;
triggered.rocket = nil;
cmds.inv.func(0, {"rocket"});
check(triggered.rocket == nil and inventory_count(0, "rocket") == 1 and last().text == "Rewards are for the living.",
	"dead: kept");
ALIVE[0] = true;

print("\n8. rewards_free: everybody holds every reward, unlimited");
rewards_free = true;
NOW = NOW + 2; mod.after.tick();
check(inventory_count(1, "rocket") == math.huge and inventory_count(2, "airstrike") == math.huge, "x\226\136\158 for everyone");
triggered.rocket = nil;
cmds.inv.func(1, {"rocket"});
check(triggered.rocket ~= nil and inventory_count(1, "rocket") == math.huge, "used, never used up");
local lines = #chat;
for i = 1, 10 do kill(1, 2); end
check(inventory_count(1, "rocket") == math.huge and #chat == lines, "nothing is earned, or announced, while all is free");
rewards_free = false;
NOW = NOW + 2; mod.after.tick();
check(total(1) == 0 and total(2) == 0, "turned off: taken back");

print("\n9. unloaded, effects are everybody's again and the items are gone");
mod.on_unload();
check(rail.everyone and air.everyone, "everyone's again");
inventory_give(0, "rocket");
local ok = pcall(cmds.inv.func, 0, {"rocket"});
check(ok and inventory_count(0, "rocket") == 1, "a reward's item is no longer a kind: nothing runs");

L.clean(check);
print(string.format("\n%d checks, %d failed", passed + failed, failed));
os.exit(failed == 0 and 0 or 1);
