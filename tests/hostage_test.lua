-- hostage_test.lua -- the hostage gamemode: which mind walks a hostage
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/hostage_test.lua      (from the repository root)
--
-- Loads catalog/gamemodes/hostage/hostage.lua against stubs of lib_bot,
-- lib_botlink, lib_l10n and the server. With no engine beating, the
-- hostages are lib_bot's (and nothing of the engine's is asked for); with
-- one, they are engine bots with the script's own tree, told what the
-- game's rules say -- held, freed, home, its rescuer dead -- and the mind
-- changes while a hostage waits at a tent, or at once, where it stands,
-- when the engine it had is gone. (What the engine does
-- with the tree: bot/tests/hostage_test.c.)

local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then
		print("  PASS " .. what);
	else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end
local function eq(got, want, what)
	check(got == want, what, string.format("got %q, want %q", tostring(got), tostring(want)));
end

--============================== STUBS ===============================--
local function hooks() return {before = {}, after = {}, next = {}}; end
function init_mod()
	local m = hooks();
	m.impl, m.late, m.early, m.xearly = hooks(), hooks(), hooks(), hooks();
	m.next.after_player_destroy = function() end;
	return m;
end
function getcfg(key, default) if (_G[key] == nil) then _G[key] = default; end end
PID_BROADCAST = 0x20000000;
function PID_BROADCAST_TEAM(t) return 0x60000000 + t; end

local NOW = 0;
function get_time() return NOW; end
local TENTS = {[1] = {x = 100, y = 256, z = 40}, [2] = {x = 400, y = 256, z = 40}};
function get_tentloc() return {[1] = TENTS[1], [2] = TENTS[2]}; end
function get_intelloc() return {}; end
function pickup_intel() end
function get_team_name(t) return t == 1 and "Blue" or "Green"; end
function get_team_color() return {r = 0, g = 0, b = 0}; end
function masterlist_set_gamemode() end
function register_command() end
function cmd_assert() end
function has_cap() return false; end
function server_msg() end
function send_chat() end
function l10n_send_chat() end
function l10n_get_str_pid() return ""; end
function l10n_msg(t) return t.en; end
function capture_intel() end
function get_team_score() return 0; end
function get_max_score() return 10; end
function spawn_player() end
function get_spawn_position() return {x = 0, y = 0, z = 0}; end
function get_ipaddr() return 1; end
function is_joined() return true; end
function get_name(pid) return "p" .. pid; end

-- the players: P[pid] = {team, pos, vel, alive, bot = lib_bot record}
local P = {};
local function player(pid, team, x, y)
	P[pid] = {team = team, pos = {x = x, y = y, z = 38}, vel = {x = 0, y = 0, z = 0}, alive = true};
end
function piditer()
	local ids = {};
	for pid in pairs(P) do ids[#ids + 1] = pid; end
	table.sort(ids);
	local i = 0;
	return function() i = i + 1; return ids[i]; end;
end
function people_in(set)
	local team = set - 0x60000000;
	local ids = {};
	for pid, p in pairs(P) do if (p.bot == nil and p.team == team) then ids[#ids + 1] = pid; end end
	local i = 0;
	return function() i = i + 1; return ids[i]; end;
end
function get_team(pid) return P[pid] and P[pid].team; end
function get_position(pid)
	local p = P[pid] and P[pid].pos or pid;     -- a pid, or a position given
	return {x = p.x, y = p.y, z = p.z};
end
function get_velocity(pid) local v = P[pid].vel; return {x = v.x, y = v.y, z = v.z}; end
function is_alive(pid) return P[pid] ~= nil and P[pid].alive; end
function is_airborne() return false; end

-- lib_bot
local CREATED, DESTROYED = {}, {};
local next_pid = 20;
function bot_create(t)
	local pid = next_pid;
	next_pid = next_pid + 1;
	local team = t.team;
	local at = t.spawn_at and t.spawn_at() or {x = 0, y = 0, z = 38};
	player(pid, team, at.x, at.y);
	P[pid].bot = {team = team, name = t.name, data = t.data or {}, think = t.think, spawn_at = t.spawn_at};
	CREATED[#CREATED + 1] = {pid = pid, lib = t.think ~= nil};
	return pid;
end
function bot_get(pid) return P[pid] and P[pid].bot; end
function bot_is_bot(pid) return P[pid] ~= nil and P[pid].bot ~= nil; end
function bot_destroy(pid) DESTROYED[#DESTROYED + 1] = pid; P[pid] = nil; mod_ref.after.on_disconnect(pid); end
function bot_distance_to(a, b)
	local p, q = P[a].pos, type(b) == "table" and b or P[b].pos;
	return math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2);
end
function bot_stop() end
function bot_crouch() end
function bot_look_at() end
function bot_walk() end
function bot_nearest_player() end
function bot_heal() end
function bot_teleport(pid, pos) P[pid].pos = {x = pos.x, y = pos.y, z = pos.z}; end

-- lib_botlink
local LINK_ALIVE = false;
local ADDED, REMOVED, SETS, ORDERS, TELLS = {}, {}, {}, {}, {};
function botlink_alive() return LINK_ALIVE; end
function botlink_add(t)
	local pid = bot_create{team = t.team, name = t.name, spawn_at = t.at, data = {botlink = true}};
	ADDED[#ADDED + 1] = {pid = pid, tree = t.tree};
	return pid;
end
function botlink_remove(pid) REMOVED[#REMOVED + 1] = pid; bot_destroy(pid); end
function botlink_set(key, value, pid) SETS[#SETS + 1] = {key, tostring(value), pid}; return true; end
function botlink_order(pid, o) ORDERS[#ORDERS + 1] = {pid = pid, order = o.order, target = o.target}; end
function botlink_on(name, fn) TELLS[name] = fn; end
function botlink_off(name) TELLS[name] = nil; end
local AMMO = {};
function get_mag_ammo(pid) return AMMO[pid] or 10; end
function get_reserve_ammo(pid) return AMMO[pid] or 50; end
function set_ammo(pid, m, r) AMMO[pid] = m + r; end

local function last_set(key, pid)
	for i = #SETS, 1, -1 do
		if (SETS[i][1] == key and SETS[i][3] == pid) then return SETS[i][2]; end
	end
end
local function sets_of(key, pid)
	local n = 0;
	for _, s in ipairs(SETS) do if (s[1] == key and s[3] == pid) then n = n + 1; end end
	return n;
end
local function last_order(pid)
	for i = #ORDERS, 1, -1 do if (ORDERS[i].pid == pid) then return ORDERS[i]; end end
end

--============================== THE TEST ============================--
mod_ref = dofile("catalog/gamemodes/hostage/hostage.lua");
local mod = mod_ref;
mod.on_load();
local function tick(n)
	for _ = 1, n or 1 do NOW = NOW + 1 / 60; mod.after.tick(); end
end
local function hostage_of(team)
	for pid, p in pairs(P) do
		if (p.bot and p.bot.data.hostage and p.team == team) then return pid; end
	end
end

print("\n1. no engine beating: lib_bot's hostages, and nothing asked of the engine");
tick();
eq(#CREATED, 2, "two hostages made");
check(CREATED[1].lib and CREATED[2].lib, "both lib_bot's, with its think");
eq(#ADDED, 0, "no engine bot added (nothing is started for a hostage)");
eq(#SETS + #ORDERS, 0, "nothing told to an engine");
local h1 = hostage_of(1);
eq(P[h1].pos.x, 400, "team 1's hostage held at the enemy tent");

print("\n2. an engine beats: made again as the engine's, while it waits at its post");
LINK_ALIVE = true;
tick();
eq(#DESTROYED, 2, "both lib_bot hostages let go (waiting at a tent, nobody leading)");
eq(#ADDED, 2, "two engine bots added");
check(ADDED[1].tree ~= nil and ADDED[1].tree:find("tree hostage_captive:", 1, true) ~= nil,
	"each with the script's own tree");
h1 = hostage_of(1);
check(h1 ~= nil and bot_get(h1).data.botlink and bot_get(h1).data.hostage, "tagged a hostage, and the engine's");
eq(P[h1].pos.x, 400, "at its post");
tick();
eq(AMMO[h1], 0, "unarmed: the server takes its rounds");
eq(last_set("fact.rescue", h1), "0", "held: no rescue");
eq(last_set("fact.lost", h1), "0", "held at a tent is not lost");
eq(last_set("fact.home", h1), "0", "not home");
tick(30);
eq(sets_of("fact.rescue", h1), 1, "told once, not every tick");
eq(last_order(h1), nil, "no order: nobody leads it");

print("\n3. freed: a man of its side, moving, comes within reach");
player(1, 1, 403, 256);
P[1].vel = {x = -0.1, y = 0, z = 0};
tick();
local o = last_order(h1);
check(o ~= nil and o.order == "follow" and o.target == 1, "ordered to follow him", o and o.order);
eq(last_set("fact.rescue", h1), "1", "a rescue");
eq(last_set("fact.home", h1), "0", "not home yet");

print("\n4. home: its man stands in its own tent");
P[1].pos = {x = 101, y = 256, z = 38};
P[h1].pos = {x = 104, y = 256, z = 38};
tick();
eq(last_set("fact.home", h1), "1", "told it is home: the last steps are its own");
check(TELLS.hostage_home ~= nil, "it listens for the tree's tell");
TELLS.hostage_home(h1, {});
eq(bot_get(h1).data.hero, 1, "the man who brought it is the hero");
eq(mod.rewards_capture_for(h1), 1, "its capture is his, for the rewards (not the hostage's)");
eq(mod.rewards_capture_for(1), 1, "anybody else's capture is his own");
-- an execution: the capture award_point makes is nobody's
local credit = "unasked";
local real_capture = capture_intel;
capture_intel = function(pid) credit = mod.rewards_capture_for(pid); end
player(2, 2, 104, 256);
mod.after.kill(h1, 0, 2);
eq(credit, nil, "an execution's capture: nobody's, for the rewards");
bot_get(h1).data.executing = nil;     -- as its own capture hook clears it
capture_intel = real_capture;
P[2] = nil;

print("\n5. the rescuer dies on the way");
P[1].pos = {x = 250, y = 256, z = 38};
P[h1].pos = {x = 253, y = 256, z = 38};
tick();
eq(last_set("fact.home", h1), "0", "away from home again");
P[1].alive = false;
tick();
o = last_order(h1);
check(o ~= nil and o.order == "none", "no man to follow", o and o.order);
eq(last_set("fact.rescue", h1), "0", "no rescue");
eq(last_set("fact.lost", h1), "1", "loose in the open: lost (it gets down and waits)");

print("\n6. the engine goes: back to lib_bot -- at a tent, or at once where it has no mind")
local function removed(pid)
	for _, r in ipairs(REMOVED) do if (r == pid) then return true; end end
	return false;
end
LINK_ALIVE = false;
local h2 = hostage_of(2);
tick();
check(removed(h2), "team 2's, waiting at its post: let go, to be made again");
check(bot_get(hostage_of(2)).think ~= nil and P[hostage_of(2)].pos.x == 100, "made again as lib_bot's, at its post");
-- team 1's is loose in the open (5.): an engine's bot with no engine
-- never moves again, so it cannot wait to reach a tent
check(removed(h1), "team 1's, loose in the open with no engine: let go at once");
local n1 = hostage_of(1);
check(n1 ~= nil and bot_get(n1).think ~= nil and not bot_get(n1).data.botlink, "made again as lib_bot's, with its think");
check(n1 ~= nil and P[n1].pos.x == 253, "where it stood, not back in the cage", n1 and P[n1].pos.x);

print("\n7. an engine comes back: a lib_bot hostage loose in the open keeps its mind")
LINK_ALIVE = true;
local before = #ADDED;
tick();
eq(#ADDED, before + 1, "team 2's, at its post: the engine's again");
eq(hostage_of(1), n1, "team 1's, loose and walkable by lib_bot: kept");
P[n1].pos = {x = 400, y = 256, z = 38};
tick(2);
check(hostage_of(1) ~= n1 and bot_get(hostage_of(1)).data.botlink, "at a tent, nobody leading: the engine's");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
