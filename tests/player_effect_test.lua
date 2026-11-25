-- player_effect_test.lua -- the PlayerEffect class, and the effects on it
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/player_effect_test.lua      (from the repository root)
--
-- lib_player_effect against a stubbed server: what the class does on
-- load, unload and join, its helpers, and that each player effect in
-- the catalog builds on it and loads.

package.path = "catalog/libs/player_effect/?.lua;"
	.. "catalog/effects/player/railgun/?.lua;"
	.. "catalog/effects/player/grenade_shotgun/?.lua;"
	.. "catalog/effects/player/pinning_smg/?.lua;"
	.. "catalog/effects/player/area_heal/?.lua;"
	.. "catalog/effects/player/area_hurt/?.lua;"
	.. "catalog/effects/player/medkit/?.lua;"
	.. package.path;

local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what) else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end
local function eq(got, want, what)
	check(got == want, what, string.format("got %s, want %s", tostring(got), tostring(want)));
end

-- the stubbed server: pid 0 and 1 on team 1, pid 2 on team 2
local TEAM = {[0] = 1, [1] = 1, [2] = 2};
local TOOL = {[0] = 2, [1] = 2, [2] = 0};
local GUN = {[0] = 0, [1] = 1, [2] = 0};
local ALIVE = {[0] = true, [1] = true, [2] = true};
local said, listeners = {}, {};

MAX_PLAYERS = 32;
PID_BROADCAST = 0x20000000;   -- PID_SET_FLAG(1), as state.h
function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
	before={}, after={}, next={}, early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function is_alive(pid) return ALIVE[pid]; end
function get_team(pid) return TEAM[pid]; end
function get_tool(pid) return TOOL[pid]; end
function get_gun(pid) return GUN[pid]; end
function pid_spawn_table() return {}; end
function piditer() local i = -1; return function() i = i + 1; if (i <= 2) then return i; end end; end
function shot_listen(name, fn) listeners[name] = fn; end
function shot_unlisten(name) listeners[name] = nil; end
NOW = 10;
function get_time() return NOW; end
function pid_connected_table() return {default = nil}; end
POS = {};
function get_position(pid) return POS[pid] or {x = 1, y = 2, z = 3}; end
HP = {};
function get_hp(pid) return HP[pid] or 100; end
function set_hp(pid, hp) HP[pid] = hp; end
DAMAGED, MARKERS, CHAT, CMDS = {}, {}, {}, {};
-- LSd's: set_hp(hp - amount), clamped at 0 and not above (main.c); and
-- lib_damage_markers shows the amount to the damager, a negative one as
-- a heal
function damage_player(pid, amount, ktype, by)
	DAMAGED[#DAMAGED+1] = {pid = pid, amount = amount, by = by};
	HP[pid] = math.max(0, (HP[pid] or 100) - amount);
	if (by ~= pid) then damage_markers_show(by, pid, amount); end
end
function damage_markers_show(viewer, target, amount)
	MARKERS[#MARKERS+1] = {viewer = viewer, target = target, amount = amount};
	return true;
end
-- the real lib_l10n: server_msg and l10n_send_chat deliver finished text
local L = dofile("tests/support/l10n_env.lua").load{
	server_msg = function(pid, text, via_l10n)
		if (via_l10n) then CHAT[#CHAT+1] = {pid, text}; else said[#said+1] = {pid, text}; end
	end,
};
function register_command(cmd) CMDS[type(cmd.name) == "table" and cmd.name[1] or cmd.name] = cmd; end
function get_orientation() return {x = 1, y = 0, z = 0}; end
package.loaded.lib_bulk_destroy = true;

pe_mod = require "lib_player_effect";
local PE = PlayerEffect;

print("\n1. the class refuses a bad spec");
check(not pcall(PE, {name = "x", gun = 0}), "a warning is required");
check(not pcall(PE, {gun = 0, warning = {en = "x"}}), "a name is required");
check(not pcall(PE, {name = "x", warning = {en = "x"}}), "a gun is required");
check(not pcall(PE, {name = "x", gun = 0, warning = {en = "x"}, tipp = "typo"}), "an unknown field is refused");
check(not pcall(PE, {name = "x", gun = "rifle", warning = {en = "x"}}), "a mistyped field is refused");
check(not pcall(PE, {name = "x", gun = 0, warning = "x"}), "a warning is a message, {en = ...}");
check(not pcall(PE, {name = "x", gun = 0, warning = {fr = "x"}}), "with its English");

print("\n2. load, join and unload");
tips = {"a stock tip"};
local shots, loads, unloads = {}, 0, 0;
local fx = PE {
	name = "odd", gun = PE.GUN_RIFLE, warning = {en = "warning: here rifles are odd."}, tip = {en = "Spicy: odd rifles."},
	on_shot = function(pid) shots[#shots+1] = pid; end,
	load = function() loads = loads + 1; end,
	unload = function() unloads = unloads + 1; end,
};
local mod = fx.mod;
mod.name = "odd_rifles";
mod.on_load();
mod.on_load(); -- a reload
eq(#tips, 2, "the tip is added once, however often it loads");
eq(l10n_str(0, tips[2]), "Spicy: odd rifles.", "and it is this effect's tip");
eq(loads, 2, "the effect's own load runs after the class's");
check(listeners.odd_rifles ~= nil, "shots are heard under the module's name");
listeners.odd_rifles(0, PE.GUN_RIFLE);
listeners.odd_rifles(1, PE.GUN_SMG);
eq(#shots, 1, "only this effect's gun reaches on_shot");
check(PE.get("odd") == fx, "a loaded effect is found by name");
eq(shots[1], 0, "with the shooter");
mod.after.on_join(2);
eq(said[1] and said[1][2], "warning: here rifles are odd.", "a joining player is warned");
mod.on_unload();
eq(#tips, 1, "unloading takes the tip out");
eq(listeners.odd_rifles, nil, "and stops listening");
eq(unloads, 1, "and runs the effect's own unload");
tips = nil;
check(pcall(mod.on_load) and pcall(mod.on_unload), "no tip_spam is fine");

print("\n3. helpers");
check(fx:holding(0), "holding: alive with the rifle in hand");
check(not fx:holding(1), "not holding: another gun");
check(not fx:holding(2), "not holding: the rifle, but not in hand");
check(fx:hostile(0, 2) and not fx:hostile(0, 1), "hostile: the other team only");
fall_is_hostile = function() return true; end
check(fx:hostile(0, 1), "hostile: the_fall's answer when it is running");
fall_is_hostile = nil;

print("\n3b. giving the effect to a player");
local fxmod = fx.mod;
fxmod.on_load();
fx.everyone = false;
said = {};
fxmod.after.on_join(2);
eq(#said, 0, "nobody is warned of an effect that is not everybody's");
check(not fx:has(0), "without a grant, nobody has it");
listeners.odd_rifles(0, PE.GUN_RIFLE);
eq(#shots, 1, "and their shots do not reach on_shot");
check(not fx:holding(0), "nor do they count as holding it");

NOW = 10;
fx:give(0, {ms = 500});
check(fx:has(0) and fx:holding(0), "500 ms: has it");
NOW = 10.4; check(fx:has(0), "still at 400 ms");
NOW = 10.5; check(not fx:has(0), "gone at 500 ms");
eq(fx.grants[0], nil, "and its grant is dropped");

NOW = 0;
fx:give(0, {minutes = 2});
NOW = 119; check(fx:has(0), "2 minutes: has it at 119 s");
NOW = 120; check(not fx:has(0), "gone at 120 s");

NOW = 0;
fx:give(0, {secs = 10});
fx:give(0, {secs = 100});
eq(fx:stacks(0), 1, "giving again replaces");
NOW = 50; check(fx:has(0), "with the new one's time");
NOW = 0;
fx:take(0);
fx:give(0, {secs = 10});
fx:give(0, {secs = 100, stack = true});
eq(fx:stacks(0), 2, "stack: both live");
NOW = 50; eq(fx:stacks(0), 1, "the shorter one runs out on its own");
check(fx:has(0), "and the longer one still holds");
NOW = 100; check(not fx:has(0), "until it runs out too");

NOW = 0;
fx:give(0, {death = true});
fx:give(1, {death = true});
local keep = fx:give(0, {map = true, stack = true});
NOW = 1e9; check(fx:has(0), "until death: no time limit");
pe_mod.after.kill(0);
eq(fx:stacks(0), 1, "death ends the death grant only");
check(fx:has(1), "and only the dead player's");
pe_mod.after.load_map();
check(not fx:has(0), "a new map ends the map grant");
check(fx:has(1), "and leaves the death grant");

NOW = 0;
fx:give(2, {secs = 5, death = true});
pe_mod.after.kill(2);
check(not fx:has(2), "time and death: whichever comes first (death)");
fx:give(2, {secs = 5, death = true});
NOW = 5; check(not fx:has(2), "time and death: whichever comes first (time)");

NOW = 0;
local a = fx:give(2, {stack = true});
fx:give(2, {stack = true});
eq(fx:stacks(2), 2, "no limit: until taken");
fx:take(2, a); eq(fx:stacks(2), 1, "take one grant back");
fx:take(2); check(not fx:has(2), "or all of them");

fx.everyone = true;
check(fx:has(2), "everyone: has it without a grant");
fxmod.on_unload();
check(PE.get("odd") == nil, "an unloaded effect is no longer found");

print("\n4. without lib_shot_detect, an effect that wants shots refuses to load");
local saved = shot_listen; shot_listen = nil;
local ok, err = pcall(fx.mod.on_load);
check(not ok and tostring(err):find("lib_shot_detect"), "it says what is missing", err);
shot_listen = saved;

print("\n5. every player effect in the catalog loads on the class");
for _, m in ipairs({"rifle_is_a_rail_gun", "shotgun_are_grenade_launchers",
                    "smg_is_incapacitating", "area_heal", "area_hurt", "medkit"}) do
	local ok2, emod = pcall(require, m);
	check(ok2 and type(emod) == "table", m .. " builds", emod);
	if (ok2) then
		emod.name = m;
		check(pcall(emod.on_load), m .. " loads");
		check(type(emod.after.on_join) == "function", m .. " warns on join");
		check(pcall(emod.on_unload), m .. " unloads");
	end
end

print("\n6. effects with a trigger");
check(not pcall(PE, {name = "x", warning = {en = "x"}}), "an effect is about a gun, or has a trigger");
-- 0 and 1 on team 1, 2 on team 2; 0 at the origin, 1 three blocks off,
-- 2 four blocks off
POS = {[0] = {x = 0, y = 0, z = 0}, [1] = {x = 3, y = 0, z = 0}, [2] = {x = 0, y = 4, z = 0}};
for _, m in ipairs({"area_heal", "area_hurt", "medkit"}) do
	local emod = package.loaded[m];
	emod.name = m;
	emod.on_load();
end
local heal = PE.get("area_heal");
local hurt = PE.get("area_hurt");
local kit = PE.get("medkit");
check(heal and hurt and kit, "all three are found by name");

HP = {[0] = 100, [1] = 50, [2] = 50}; MARKERS = {};
eq(heal:trigger(0), 1, "area_heal: the teammate in range is healed");
eq(HP[1], 55, "by area_heal_amount");
eq(HP[2], 50, "the enemy in range is not");
eq(MARKERS[1] and MARKERS[1].amount, -5, "dealt as negative damage: the healer sees a heal marker");
eq(MARKERS[1] and MARKERS[1].viewer, 0, "shown to the healer");
eq(heal:trigger(0, {radius = 2}), 0, "a radius from the gamemode: nobody that close");
heal:trigger(0, {amount = 100});
eq(HP[1], 100, "never past full");
MARKERS = {}; DAMAGED = {};
eq(heal:trigger(0), 0, "nobody hurt: nobody healed");
eq(#DAMAGED, 0, "nothing dealt");
eq(#MARKERS, 1, "but the healer still sees one marker: the effect is working");
eq(MARKERS[1] and MARKERS[1].target, 1, "over the teammate in range, not the enemy");
eq(MARKERS[1] and MARKERS[1].amount, -5, "the heal they would get with nothing left");
eq(HP[1], 100, "and their health is unchanged");

HP = {[0] = 100, [1] = 100, [2] = 100}; DAMAGED = {};
eq(hurt:trigger(0), 1, "area_hurt: the enemy in range is hit");
eq(DAMAGED[1] and DAMAGED[1].pid, 2, "the enemy");
eq(DAMAGED[1] and DAMAGED[1].by, 0, "dealt as the player, for the kill and the marker");
eq(HP[1], 100, "the teammate is not");
eq(hurt:trigger(0, {radius = 3}), 0, "a radius from the gamemode: the enemy is out of it");

ALIVE[0] = false;
eq(heal:trigger(0), nil, "a dead player triggers nothing");
ALIVE[0] = true;

print("\n6b. on its own, every <name>_every seconds");
HP = {[0] = 100, [1] = 50, [2] = 50};
area_heal_every, area_hurt_every, medkit_every = 2, 0, 0;
heal.everyone = true;
NOW = 100;
pe_mod.after.tick();
eq(HP[1], 50, "nothing on the first tick: the clock starts");
NOW = 101;
pe_mod.after.tick();
eq(HP[1], 50, "nothing before the interval");
NOW = 102;
pe_mod.after.tick();
eq(HP[1], 55, "the interval passed: everybody with it triggers it");
heal.everyone = false;
NOW = 104;
pe_mod.after.tick();
eq(HP[1], 55, "nobody has it: nothing");
heal:give(1);
HP[0], HP[1] = 50, 50;
NOW = 106;
pe_mod.after.tick();
eq(HP[0], 55, "given to 1 alone: 1 heals those near 1");
eq(HP[1], 50, "and nobody heals 1, who alone has it");
area_heal_every = 0;
heal.everyone = true;

print("\n6c. the medkit");
medkit_heal, medkit_quantity = 40, 1;
HP = {[1] = 50}; CHAT = {};
eq(kit:trigger(1), 40, "a kit gives medkit_heal back");
eq(HP[1], 90, "up to 90");
eq(kit:trigger(1), nil, "medkit_quantity a life: none left");
check(CHAT[#CHAT] and CHAT[#CHAT][2]:find("used all your medkits", 1, true), "and is told");
eq(kit:trigger(1, {free = true}), 10, "a gamemode's free kit still heals, to full");
package.loaded.medkit.after.spawn_player(1);
HP[1] = 30;
CMDS.medkit.func(1);
eq(HP[1], 70, "/m uses one after a respawn restocked it");
kit.everyone = false;
CHAT = {};
CMDS.medkit.func(1);
check(CHAT[1] and CHAT[1][2]:find("no medkit here", 1, true), "/m without the effect: told so");
kit.everyone = true;

print("\nN. effects break blocks through one door, as their owner");
local BROKE, FINISHED, AS = {}, 0, nil;
function edit_as(who, fn, ...)
	AS = {who = who};
	local r = fn(...);
	AS.done = true;
	return r;
end
function bdestroy_block_action(p, t) BROKE[#BROKE+1] = {p = p, t = t, who = AS and AS.who, inside = AS ~= nil and not AS.done}; end
function bdestroy_finish() FINISHED = FINISHED + 1; end
PE.break_blocks(0, {{x = 10.7, y = 5, z = 20}, {x = 13, y = 5, z = 20},
	{x = 11, y = 5, z = 62}, {x = -1, y = 5, z = 20}}, 3);
eq(#BROKE, 2, "every block on the map above the floor goes to the engine's bulk destroy");
eq(BROKE[1] and BROKE[1].p.x, 10, "at whole-block coordinates");
eq(BROKE[1] and BROKE[1].t, 3, "with the type asked for");
check(BROKE[1] and BROKE[1].inside and BROKE[2].inside, "inside the owner's edits (edit_as): the filter asks, not the effect");
eq(BROKE[1] and BROKE[1].who, 0, "for the effect's owner");
eq(FINISHED, 1, "the bulk destroy is finished once");
BROKE = {};
PE.break_blocks(nil, {{x = 13, y = 5, z = 20}}, 1);
eq(BROKE[1] and BROKE[1].who, nil, "the world's own: for nobody");

L.clean(check);
print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
