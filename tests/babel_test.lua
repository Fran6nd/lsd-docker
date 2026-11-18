-- babel_test.lua -- babel_plus: the spawn colour and the camper marks
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/babel_test.lua      (from the repository root)
--
-- Loads babel_plus against a stub of the LSd and Teamplay globals, moves
-- players about by hand and advances a fake clock, recording what it
-- asks Teamplay and the core for.

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

PID_BROADCAST = -1;
TEAMPLAY_FOREVER = math.huge;
-- 0, 1: team 1; 2, 3: team 2 (3 has no Teamplay); 4: spectator
local TEAM = {[0] = 1, [1] = 1, [2] = 2, [3] = 2, [4] = 3};
local POS, ALIVE, NOW = {}, {}, 0;
for i = 0, 4 do POS[i] = {x = 256, y = 256, z = 30}; ALIVE[i] = true; end
function get_team(pid) return TEAM[pid]; end
function get_position(pid) return POS[pid]; end
function is_alive(pid) return ALIVE[pid]; end
function get_time() return NOW; end
function get_tentloc() return {[1] = {x = 118, y = 256, z = 30}, [2] = {x = 394, y = 256, z = 30}}; end
function get_team_color(t) return t == 1 and {b = 1, g = 2, r = 3} or {b = 4, g = 5, r = 6}; end
function piditer()
	local i = -1;
	return function() i = i + 1; if (TEAM[i]) then return i; end end;
end

babel_protect_zones = {
	{{{x = 128, y = 240}, {x = 225, y = 271}}},
	{{{x = 287, y = 240}, {x = 383, y = 271}}},
};

local LOG, READY, COLORS = {}, nil, {};
function set_block_color(pid, c) COLORS[pid] = c; end
function teamplay_listen_ready(name, fn) READY = fn; end
function teamplay_mark(v, t, secs, o)
	if (v == 3) then return false; end
	LOG[#LOG+1] = {"mark", v, t, secs, o};
	return true;
end
function teamplay_clear(v, t) LOG[#LOG+1] = {"clear", v, t}; end

local mod = dofile("catalog/gamemodes/babel/babel_plus.lua");
mod.on_load();

local function count(kind, v, t)
	local n = 0;
	for _, e in ipairs(LOG) do
		if (e[1] == kind and (v == nil or e[2] == v) and (t == nil or e[3] == t)) then n = n + 1; end
	end
	return n;
end
local function find(kind, v, t)
	for _, e in ipairs(LOG) do
		if (e[1] == kind and e[2] == v and e[3] == t) then return e; end
	end
end
-- run the clock to `t`, a second at a time
local function run(t)
	while (NOW < t) do NOW = NOW + 1; mod.after.tick(); end
end
local function reset()
	LOG = {}; NOW = 0;
	mod.before.finish_map_load();
	for i = 0, 4 do POS[i] = {x = 256, y = 256, z = 30}; ALIVE[i] = true; end
end

print("\n1. spawning, holding the team's colour");
mod.after.spawn_player(0);
mod.after.spawn_player(2);
mod.after.spawn_player(4);
eq(COLORS[0].r, 3, "team 1 holds team 1's colour");
eq(COLORS[2].r, 6, "team 2 holds team 2's colour");
eq(COLORS[4], nil, "a spectator is left alone");

print("\n2. a team 2 player camping in team 1's tower area");
reset();
POS[2] = {x = 200, y = 255, z = 30};
run(19);
eq(count("mark"), 0, "nothing before babel_camp_secs");
run(21);
eq(count("mark", 0, 2), 1, "team 1 player 0 is told");
eq(count("mark", 1, 2), 1, "and player 1");
eq(count("mark", 2), 0, "the camper is not");
eq(count("mark", 4), 0, "nor the spectator");
local m = find("mark", 0, 2);
eq(m[5].reason.en, "Camping by your tower", "reason");
eq(m[5].clear_on_respawn, true, "cleared on respawn");
eq(m[4], TEAMPLAY_FOREVER, "until something clears it");
run(40);
eq(count("mark", 0, 2), 1, "not marked again every second");

print("\n3. moving a little does not reset the clock, moving enough does");
reset();
POS[2] = {x = 200, y = 255, z = 30};
run(10);
POS[2] = {x = 201, y = 255, z = 30};
run(21);
eq(count("mark", 0, 2), 1, "one block of fidgeting still counts");
POS[2] = {x = 205, y = 255, z = 30};
run(22);
eq(count("clear", 0, 2), 1, "walking off clears the mark");
run(41);
eq(count("mark", 0, 2), 1, "and the clock starts over");

print("\n4. leaving the area, dying, disconnecting");
reset();
POS[2] = {x = 200, y = 255, z = 30};
run(21);
POS[2] = {x = 300, y = 255, z = 30};
run(22);
eq(count("clear", 0, 2), 1, "leaving the area clears");
POS[2] = {x = 200, y = 255, z = 30};
run(44);
eq(count("mark", 0, 2), 2, "back in, marked again after the wait");
LOG = {};
mod.after.kill(2);
eq(count("clear", 1, 2), 1, "death clears");
reset();
POS[2] = {x = 200, y = 255, z = 30};
run(21);
mod.after.after_player_destroy(2);
eq(count("clear", 0, 2), 1, "a disconnect clears");

print("\n5. your own tower area, and the other side's, are not camping");
reset();
POS[2] = {x = 300, y = 255, z = 30};
POS[0] = {x = 200, y = 255, z = 30};
run(60);
eq(count("mark"), 0, "own area is no offence");

print("\n6. the enemy spawn: faster, with its own reason");
reset();
POS[2] = {x = 110, y = 256, z = 30};
run(14);
eq(count("mark"), 0, "not at 14 s");
run(16);
eq(count("mark", 0, 2), 1, "marked at babel_spawn_secs");
eq(find("mark", 0, 2)[5].reason.en, "In your spawn", "reason");
POS[0] = {x = 400, y = 256, z = 30};
run(40);
eq(count("mark", 2, 0), 1, "team 1 in team 2's spawn is marked for team 2");

print("\n7. a defender whose Teamplay negotiates late");
reset();
POS[2] = {x = 200, y = 255, z = 30};
run(21);
LOG = {};
READY(1);
eq(count("mark", 1, 2), 1, "is sent the standing mark");
READY(2);
eq(count("mark", 2), 0, "a viewer on the camper's own team is sent none");

print("\n8. babel_camp_marks off");
reset();
babel_camp_marks = false;
POS[2] = {x = 200, y = 255, z = 30};
run(60);
eq(count("mark"), 0, "nothing marked");
babel_camp_marks = true;

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
