-- event_pings_test.lua -- lib_callouts' intel and hostage pings
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/event_pings_test.lua      (from the repository root)
--
-- Loads lib_callouts against a stub of the LSd and Teamplay globals and
-- calls the hooks it hangs off drop_intel, pickup_intel and
-- capture_intel, recording the pings and marks it asks Teamplay for.

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

local function hooks() return {before = {}, after = {}, next = {}}; end
function init_mod()
	local m = hooks();
	m.impl, m.late, m.early, m.xearly = hooks(), hooks(), hooks(), hooks();
	return m;
end
function getcfg(key, default)
	if (_G[key] == nil) then _G[key] = default; end
end
function pid_connected_table(default)
	return setmetatable({}, {__index = function() return default; end});
end
function register_command() end

PID_BROADCAST = 0x20000000;   -- PID_SET_FLAG(1), as state.h
TEAMPLAY_FOREVER = math.huge;
local TEAM = {[0] = 1, [1] = 2, [2] = 1, [3] = 2, [4] = 3};   -- 4: spectator
function get_team(pid) return TEAM[pid]; end
function get_position(pid) return {x = 7, y = 8, z = 9}; end
function PID_BROADCAST_TEAM(t) return 3 * 0x20000000 + t; end
function piditer(set)
	local i = -1;
	return function()
		while (true) do
			i = i + 1;
			if (TEAM[i] == nil) then return nil; end
			if (set == nil or set < 3 * 0x20000000 or set == PID_BROADCAST_TEAM(TEAM[i])) then return i; end
		end
	end;
end

local LOG = {};
function teamplay_ping(v, pos, o) LOG[#LOG+1] = {"ping", v, pos, o}; return true; end
function teamplay_mark(v, t, secs, o) LOG[#LOG+1] = {"mark", v, t, secs, o}; return true; end
function teamplay_clear(v, t) LOG[#LOG+1] = {"clear", v, t}; end

gamemode = "ctf";
local mod = dofile("catalog/libs/callouts/lib_callouts.lua");

local function reset() LOG = {}; end
local function find(kind, v)
	for _, e in ipairs(LOG) do
		if (e[1] == kind and e[2] == v) then return e; end
	end
end
local function count(kind)
	local n = 0;
	for _, e in ipairs(LOG) do if (e[1] == kind) then n = n + 1; end end
	return n;
end

print("\n1. ctf: intel dropped by a team 1 carrier (pid 0)");
reset();
mod.after.drop_intel(0, {x = 1, y = 2, z = 3});
eq(count("ping"), 4, "pinged all four players on a team, not the spectator");
eq(find("ping", 2)[4].reason.en, "Their intel is here", "its own team: their intel");
eq(find("ping", 1)[4].reason.en, "Our intel is here", "the owners: our intel");
eq(find("ping", 1)[3].x, 1, "at the drop position");
eq(find("ping", 4), nil, "the spectator is not pinged");
check(find("clear", 1) ~= nil, "the carrier's mark is cleared");

print("\n2. an infinite position (onectf's hidden intel) falls back");
reset();
mod.after.drop_intel(0, {x = math.huge, y = math.huge, z = math.huge});
eq(find("ping", 1)[3].x, 7, "to the carrier's own position");

print("\n3. pickup marks the carrier for the owners only");
reset();
mod.after.pickup_intel(0);
eq(count("mark"), 2, "two owners marked");
check(find("mark", 1) ~= nil and find("mark", 3) ~= nil, "pids 1 and 3 (team 2)");
eq(find("mark", 1)[3], 0, "the carrier is the target");
eq(find("mark", 1)[5].reason.en, "Has our intel", "with its reason");
eq(find("mark", 1)[5].clear_on_respawn, true, "cleared on respawn");
eq(find("mark", 1)[4], TEAMPLAY_FOREVER, "until cleared");

print("\n4. capture clears the mark");
reset();
mod.after.capture_intel(0);
eq(count("clear"), 5, "cleared for every viewer");

print("\n5. onectf: neutral wording");
gamemode = "onectf";
reset();
mod.after.drop_intel(0, {x = 1, y = 2, z = 3});
eq(find("ping", 1)[4].reason.en, "The intel is here", "same line for both teams");
eq(find("ping", 2)[4].reason.en, "The intel is here", "(other team)");
reset();
mod.after.pickup_intel(0);
eq(find("mark", 1)[5].reason.en, "Has the intel", "mark says the intel");

print("\n6. hostage: no intel events, but the team ping works");
gamemode = "hostage";
reset();
mod.after.drop_intel(0, {x = 1, y = 2, z = 3});
mod.after.pickup_intel(0);
eq(#LOG, 0, "bot flag never pings");
callouts_ping_team(2, {x = 5, y = 5, z = 5}, {en = "x"});
eq(count("ping"), 2, "team 2 pinged");
eq(find("ping", 1)[4].reason.en, "x", "with the reason");

print("\n7. switched off");
callouts_event_pings = false;
gamemode = "ctf";
reset();
mod.after.drop_intel(0, {x = 1, y = 2, z = 3});
mod.after.pickup_intel(0);
mod.after.capture_intel(0);
callouts_ping_team(1, {x = 1, y = 1, z = 1}, {en = "x"});
eq(#LOG, 0, "nothing sent");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
