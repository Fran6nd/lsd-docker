-- vote_peace_test.lua -- /votepeace: the vote toggles the peace, no damage at peace
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/vote_peace_test.lua      (from the repository root)
local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what);
	else failures = failures + 1; print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or "")); end
end

--============================= STUBS ================================--
PID_BROADCAST = 0x20000000;
function init_mod()
	return {impl = {}, after = {}, before = {}, next = {}, early = {}, xearly = {},
		late = {before = {}, after = {}, next = {}}};
end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function log() end
local NOW = 100;
function get_time() return NOW; end
local JOINED = {[0] = true, [1] = true, [2] = true};
function is_joined(i) return JOINED[i] == true; end
function is_fakepid(i) return i == 9; end
function get_name(i) return "P" .. i; end
local cmds = {};
function register_command(c) local n = c.name; if (type(n) ~= "table") then n = {n}; end for _, x in ipairs(n) do cmds[x] = c; end end

local L = dofile("tests/support/l10n_env.lua").load{};
L.pids = {0, 1, 2};
local lib = dofile("catalog/libs/vote/lib_vote.lua");
local mod = dofile("catalog/tools/vote_peace/vote_peace.lua");

-- the damage chain as the core has it: ours is the last word, and what
-- gets past it is applied (recorded here)
local applied = {};
mod.late.next.damage_player = function(pid, hp, type, damager) applied[#applied+1] = {pid, hp, type, damager}; end
mod.late.next.damage_player_directional = function(pid, hp, pos, type, damager) applied[#applied+1] = {pid, hp, type, damager}; end
function damage_player(...) return mod.late.damage_player(...); end
function damage_player_directional(...) return mod.late.damage_player_directional(...); end

local function votepeace(pid) cmds.votepeace.func(pid, {}); end
local function last() return L.chat[#L.chat] and L.chat[#L.chat].text or ""; end
local function tick(secs) NOW = NOW + (secs or 1); lib.after.tick(); mod.after.tick(); end

local ZERO = {x = 0, y = 0, z = 0};
-- every kind of damage a player or what a player did can deal, as the core
-- and the scripts send it: a bullet, a headshot, the spade, a grenade
-- (core and lib_blast), a rocket, an airstrike, a missile, a rail gun, an
-- area that hurts, a bot's shot -- by KillType, which they all share
local SOURCES = {
	{"a bullet", function() damage_player_directional(1, 33, ZERO, 0, 0); end},
	{"a headshot", function() damage_player_directional(1, 100, ZERO, 1, 0); end},
	{"the spade", function() damage_player_directional(1, 80, ZERO, 2, 0); end},
	{"a grenade", function() damage_player_directional(1, 60, ZERO, 3, 0); end},
	{"a rocket or an airstrike (lib_blast)", function() damage_player(1, 90, 3, 0); end},
	{"a rail gun", function() damage_player_directional(1, 255, ZERO, 0, 0); end},
	{"an area that hurts", function() damage_player(1, 10, 0, 0); end},
	{"one's own grenade", function() damage_player_directional(0, 50, ZERO, 3, 0); end},
	{"a bot's shot", function() damage_player_directional(1, 33, ZERO, 0, 9); end},
};
local function all_hit()
	local n = 0;
	for _, s in ipairs(SOURCES) do
		local before = #applied;
		s[2]();
		if (#applied == before + 1) then n = n + 1; end
	end
	return n;
end

--============================= CHECKS ===============================--
print("\n1. no peace: everything as it is");
check(peace_active() == false, "no peace at the start");
check(all_hit() == #SOURCES, "every damage is applied");
cmds.peace.func(0, {});
check(last() == "No peace: /votepeace to vote one.", "/peace says there is none", last());
mod.after.on_join(1);
check(not last():find("Peace is on"), "a joiner is told nothing");

print("\n2. a vote: a majority of three carries it");
votepeace(0);
check(last():find("P0 wants to change the peace %(a vote%): type /votepeace to agree %(1/2%)"), "started, with the count", last());
check(peace_active() == false, "not yet");
votepeace(0);
check(last() == "You already voted on the peace.", "one voice each");
votepeace(1);
check(peace_active() == true, "the second of three carries it");
check(last() == "Peace: nobody can hurt anybody. /votepeace to end it.", "everybody is told", last());

print("\n3. at peace, no damage from players");
applied = {};
check(all_hit() == 0, "none of: a bullet, a headshot, the spade, grenades, a rocket, an airstrike, a rail gun, an area, one's own grenade, a bot");
damage_player(1, -25, 0, 0);
check(#applied == 1, "healing still works (a medkit, an area that heals)");
damage_player(1, 20, 4, 1);
check(#applied == 2, "a fall, the water, the boundary (KillTypeFall) are the map's, and still hurt");

print("\n4. a joining player is told at peace, the state on demand");
mod.after.on_join(2);
check(last() == "Peace is on: nobody can hurt anybody. /votepeace to end it.", "a human joiner is warned", last());
local n = #L.chat;
mod.after.on_join(9);
check(#L.chat == n, "a bot or the console is not");
cmds.peace.func(0, {});
check(last():find("Peace is on"), "/peace says it is on", last());

print("\n5. a new vote ends it");
votepeace(2);
check(last():find("wants to change the peace"), "a vote at peace starts the same way", last());
votepeace(0);
check(peace_active() == false, "carried: the peace is over");
check(last() == "Peace is over: damage is back.", "told", last());
applied = {};
check(all_hit() == #SOURCES, "every damage is applied again");
mod.after.on_join(2);
check(last() == "Peace is over: damage is back.", "(a joiner is told nothing now)", last());

print("\n6. a vote that is not answered lapses; one player alone carries it");
votepeace(0);
tick(vote_peace_timeout + 1);
check(last() == "The vote on the peace failed." and peace_active() == false, "fails, nothing changes", last());
JOINED = {[0] = true};
votepeace(0);
check(peace_active() == true, "a lone player's /votepeace is the peace");
JOINED = {[0] = true, [1] = true, [2] = true};

print("\n6b. a voter who leaves takes his voice with him");
-- at peace (section 6); four people: three voices end it
JOINED = {[0] = true, [1] = true, [2] = true, [3] = true};
L.pids = {0, 1, 2, 3};
votepeace(0);
votepeace(1);
check(peace_active() == true and last():find("%(2/3%)"), "two of the three it needs", last());
JOINED[1] = nil;
lib.after.on_disconnect(1);
JOINED[1] = true;   -- somebody else, in his slot
votepeace(1);
check(last() ~= "You already voted on the peace." and peace_active() == true,
	"the newcomer in his slot has a voice of his own; the leaver's is gone", last());
votepeace(3);
check(peace_active() == false, "and three present carry it");
L.pids = {0, 1, 2};
JOINED = {[0] = true};
votepeace(0);
JOINED = {[0] = true, [1] = true, [2] = true};

print("\n7. a new map ends the peace");
mod.after.load_map();
check(peace_active() == false and last() == "New map: peace is over, damage is back.", "peace ends with the map", last());
n = #L.chat;
mod.after.load_map();
check(#L.chat == n, "and a map without peace says nothing");

print("\n8. the bots are told: fact.peace and fire=hold, forgotten at the end");
local sent = {};
function botlink_set(k, v) sent[#sent+1] = k .. "=" .. tostring(v); end
local first = botlink_set;
tick();
check(#sent == 0, "an engine with no peace is told nothing");
JOINED = {[0] = true};
votepeace(0);
check(sent[1] == "fact.peace=1" and sent[2] == "fire=hold" and #sent == 2, "peace: the fact and the rule", table.concat(sent, ","));
tick();
check(#sent == 2, "told once");
votepeace(0);
check(sent[3] == "fact.peace=" and sent[4] == "fire=" and #sent == 4, "over: both forgotten", table.concat(sent, ","));
votepeace(0);
sent = {};
function botlink_set(k, v) sent[#sent+1] = k .. "=" .. tostring(v); end
tick();
check(sent[1] == "fact.peace=1" and sent[2] == "fire=hold", "an engine that comes late (or anew) is told what stands", table.concat(sent, ","));
botlink_set = nil;
check(pcall(votepeace, 0), "no engine bots: nothing is sent, nothing breaks");
tick();
JOINED = {[0] = true, [1] = true, [2] = true};

L.clean(check);
print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
