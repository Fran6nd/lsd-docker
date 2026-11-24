-- ext_policy_test.lua -- the one path for an outdated client
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/ext_policy_test.lua      (from the repository root)
--
-- lib_ext_policy against a stubbed server: an extension's floor (Player
-- Limit required above 32 seats, whatever the policy says), the clock
-- that starts at the end of the map, the spectator gate, and what an
-- outdated client is told and how often.

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

local CONNECTED, BOTS, SPEAKS, REPLIED, JOINED = {}, {}, {}, {}, {};
local NOW = 1000;
local SAID = {};
local SWITCHED = {};
MAX_PLAYERS = 255;
SPECTATOR = 255;
PID_BROADCAST = 0x20000000;
function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
	before={}, after={}, next={}, early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function log() end
function get_time() return NOW; end
function pid_connected_table() return {}; end
function piditer(pid)
	if (pid == PID_BROADCAST) then
		local list = {};
		for i in pairs(CONNECTED) do list[#list+1] = i; end
		table.sort(list);
		local n = 0;
		return function() n = n + 1; return list[n]; end
	end
	local done = false;
	return function() if (done) then return nil; end done = true; return pid; end
end
function bot_is_bot(pid) return BOTS[pid] == true; end
function bot_is_nonhuman(pid) return BOTS[pid] == true; end
function get_ipaddr(pid) return BOTS[pid] and 0 or 1; end
function is_joined(pid) return JOINED[pid] == true; end
function on_switch(pid, team, gun) SWITCHED[#SWITCHED+1] = {pid, team, gun}; end

-- lib_ext's half: Player Limit registered, with its floor
local SEATS = 255;
ext_registry = {
	[192] = {name = "lib_player_limit", version = 1, title = "Player Limit",
		floor = function() return SEATS > 32 and "required" or nil; end},
	[0x60] = {name = "lib_damage_markers", version = 1, title = "Damage Markers"},
};
local OFF = {};
function ext_each(fn) for id, reg in pairs(ext_registry) do fn(id, reg); end end
function ext_supported(pid, id) return SPEAKS[pid] and SPEAKS[pid][id] and 1 or nil; end
function ext_replied(pid) return REPLIED[pid] == true; end
function ext_disable(id) if (OFF[id]) then return false; end OFF[id] = true; return true; end
function ext_enable(id) if (not OFF[id]) then return false; end OFF[id] = nil; return true; end

-- lib_l10n's l10n_msg: the English, interpolated
function l10n_msg(t, i)
	return (string.gsub(t.en, "%%%((%w+)%)", function(k) return tostring((i or {})[k]); end));
end
function server_msg(pid, text) SAID[#SAID+1] = {pid, text}; end

ext_policy = {[192] = "applied", [0x60] = "applied"};
local mod = dofile("catalog/libs/ext_policy/lib_ext_policy.lua");
local joined_team;
mod.next.on_join = function(pid, team) joined_team = team; end
mod.next.on_switch = function(pid, team) joined_team = team; end
mod.on_load();

print("\n1. the floor: Player Limit required above 32 seats, whatever the policy");
eq(ext_policy_of(192), EXT_REQUIRED, "255 seats, policy applied: required");
SEATS = 32;
eq(ext_policy_of(192), EXT_APPLIED, "32 seats: the policy, applied");
SEATS = 255;
eq(ext_policy_of(0x60), EXT_APPLIED, "an extension with no floor: its policy");
ext_policy[192] = "disabled";
eq(ext_policy_of(192), EXT_DISABLED, "a floor never overrides disabled");
ext_policy[192] = "recommended";
eq(ext_policy_of(192), EXT_REQUIRED, "nor lets recommended stand above 32 seats");
ext_policy[192] = "applied";
ext_registry[192].floor = function() error("boom"); end
eq(ext_policy_of(192), EXT_APPLIED, "a floor that throws is ignored");
ext_registry[192].floor = function() return SEATS > 32 and "required" or nil; end

print("\n2. the clock starts at the end of the map");
CONNECTED[40] = true;
-- connected, the map on its way: no clock yet
NOW = NOW + 120;
eq(ext_policy_decided(40), false, "two minutes into a download: not decided, it was never asked");
mod.after.demand_fingerprint(40);   -- the version request, end of map
NOW = NOW + ext_policy_grace - 1;
eq(ext_policy_decided(40), false, "inside the grace after the question: still waiting");
NOW = NOW + 2;
eq(ext_policy_decided(40), true, "grace over: silence is an answer");
CONNECTED[41] = true;
mod.after.demand_fingerprint(41);
REPLIED[41] = true;
eq(ext_policy_decided(41), true, "a reply decides at once");

print("\n3. the gate: an outdated client watches");
joined_team = nil;
mod.on_join(40, 0, 1, "old");
eq(joined_team, SPECTATOR, "no Player Limit: held in spectator");
SPEAKS[42], REPLIED[42], CONNECTED[42] = {[192] = 1}, true, true;
mod.on_join(42, 1, 1, "new");
eq(joined_team, 1, "speaks it: on the team asked for");
BOTS[43], CONNECTED[43] = true, true;
mod.on_join(43, 0, 1, "bot");
eq(joined_team, 0, "a bot is nobody's client: plays");
SEATS = 32;
CONNECTED[44] = true;
mod.after.demand_fingerprint(44);
REPLIED[44] = true;
mod.on_join(44, 0, 1, "old at 32");
eq(joined_team, 0, "at 32 seats an old client plays");
SEATS = 255;

print("\n4. what it is told, and how often");
SAID = {};
CONNECTED = {[40] = true};
NOW = NOW + 100;
mod.after.tick();
local function to(pid) local t = {}; for _, e in ipairs(SAID) do if (e[1] == pid) then t[#t+1] = e[2]; end end return t; end
eq(#to(40), 1, "told once on the sweep");
local line = to(40)[1] or "";
check(string.find(line, "outdated", 1, true) and string.find(line, "ZeroSpades", 1, true),
	"never answered: outdated, and what to install", line);
NOW = NOW + ext_policy_lockout_interval - 1;
mod.after.tick();
eq(#to(40), 1, "not again inside the lockout interval");
NOW = NOW + 2;
mod.after.tick();
eq(#to(40), 2, "again after it: always on its screen");
check(ext_policy_lockout_interval < ext_policy_warn_interval, "more often than the cosmetic reminder");

SAID = {};
CONNECTED = {[45] = true};
mod.after.demand_fingerprint(45);
REPLIED[45], SPEAKS[45] = true, {[0x60] = 1};
NOW = NOW + 1;
mod.after.tick();
line = to(45)[1] or "";
check(string.find(line, "outdated", 1, true) and string.find(line, "Player Limit", 1, true)
	and string.find(line, "ZeroSpades", 1, true), "answered without it: told what it lacks", line);

SAID = {};
CONNECTED = {[42] = true};
NOW = NOW + 100;
mod.after.tick();
eq(#to(42), 0, "a client that has it is told nothing");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
