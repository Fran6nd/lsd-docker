-- babel_test.lua -- babel_plus: the spawn colour and the camper marks
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
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

PID_BROADCAST = 0x20000000;   -- PID_SET_FLAG(1), as state.h
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
local LOGGED = {};
function log(fmt, ...) LOGGED[#LOGGED+1] = string.format(fmt, ...); end

dofile("catalog/libs/stairs/lib_stairs.lua");          -- its stairs (the gamemode requires it)
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

print("\nN. what babel keeps, said to the one question every edit answers (may_edit_block)");
babel_width, babel_height, babel_z = 100, 32, 1;
mod.next.may_edit_block = function() return true; end
local may = mod.may_edit_block;
-- platform: x 206..305, y 240..271, at z 1
check(not may(0, {x = 250, y = 250, z = 1}, 1), "the platform: nobody breaks it");
check(not may(nil, {x = 250, y = 250, z = 1}, 1), "nor does the world's effect, nor a script");
check(may(2, {x = 250, y = 250, z = 2}, 1), "the block under it is another matter");
check(not may(2, {x = 250, y = 250, z = 2}, 0) and not may(2, {x = 250, y = 250, z = 0}, 0),
	"but nobody builds above or below it");
check(not may(2, {x = 205, y = 250, z = 1}, 0) and may(2, {x = 205, y = 239, z = 1}, 0),
	"nor beside it, but for the corners");
check(may(nil, {x = 250, y = 250, z = 1}, 0), "a script builds the platform where it likes (its rebuild, its paintings)");
check(may(0, {x = 250, y = 250, z = 4}, 1), "further off the platform: yes");
-- team 1's tower area x 128..225, team 2's x 287..383 (y 240..271)
check(not may(0, {x = 150, y = 250, z = 40}, 1), "team 1 breaks nothing in its own tower area");
check(may(2, {x = 150, y = 250, z = 40}, 1), "team 2 breaks team 1's tower: that is the game");
check(not may(2, {x = 150, y = 250, z = 40}, 0), "and builds nothing in it");
check(may(0, {x = 150, y = 250, z = 40}, 0), "team 1 builds there");
check(not may(nil, {x = 150, y = 250, z = 40}, 1) and not may(nil, {x = 300, y = 250, z = 40}, 1),
	"the world's own effects break neither team's area");
check(may(nil, {x = 50, y = 50, z = 40}, 1), "and anything outside them");
function has_cap(pid, cap) return pid == 0 and cap == "no_babel_protect"; end
check(may(0, {x = 150, y = 250, z = 40}, 1), "a player with the no_babel_protect cap breaks his own team's area");
has_cap = nil;
mod.next.may_edit_block = function() return false; end
check(not may(0, {x = 50, y = 50, z = 40}, 1), "and what another script protects stays protected (the chain goes on)");

print("\nB. engine bots: each team's stair, told through the bridge -- only when there are bots");
do
	local SETS = {};
	local BUILT = {};
	local INTEL = {x = 256, y = 256, z = 1};
	local function k3(x, y, z) return x .. "," .. y .. "," .. z; end
	function is_solid(p) return p.z >= 50 or BUILT[k3(p.x, p.y, p.z)] == true; end
	function get_1intel_loc() return INTEL; end
	function botlink_set(key, value, pid) SETS[#SETS + 1] = {key, tostring(value), pid}; return true; end
	local ALIVE_LINK, BOTS = false, {};
	function botlink_alive() return ALIVE_LINK; end
	function bot_get(pid) return BOTS[pid] and {data = {botlink = true}} or nil; end
	local function last(key, pid)
		for i = #SETS, 1, -1 do
			if (SETS[i][1] == key and SETS[i][3] == pid) then return SETS[i][2]; end
		end
	end
	local function sets_of(key)
		local n = 0;
		for _, e in ipairs(SETS) do if (e[1] == key) then n = n + 1; end end
		return n;
	end
	reset();
	run(5);
	eq(#SETS, 0, "no engine bots: nothing is told, nothing asked of the link");
	ALIVE_LINK = true;
	run(10);
	eq(#SETS, 0, "a link but no engine bot among the players: still nothing");
	BOTS[0], BOTS[2] = true, true;
	run(15);
	eq(last("edit", nil), "all", "edit=all, for a tower is built");
	eq(sets_of("edit"), 1, "said once");
	eq(last("zone", nil), "206 240 305 271; 128 240 225 271 nodig team 1; 128 240 225 271 nobuild team 2; "
		.. "287 240 383 271 nodig team 2; 287 240 383 271 nobuild team 1",
		"one zone list: the platform for everybody; each tower area undug by its team and unbuilt by the other");
	eq(sets_of("zone"), 1, "said once");
	-- team 1's stair: step k at (205 - k, 240, 2 + k), down to the ground at 50
	-- each team's, once for the team: the world's "<name>@<team>"
	-- a stair is a blueprint: each step and the voxel under it, from the
	-- ground up (the lowest step's riser is the ground)
	eq(string.sub(last("blueprint.stair@1", nil), 1, 41), "158 255 49; 159 255 49; 159 255 48; 160 2",
		"team 1's stair, from its lowest step (on the platform's middle row, clear)");
	eq(string.sub(last("blueprint.stair@2", nil), 1, 23), "353 255 49; 352 255 49;", "team 2's: the mirror of it");
	eq(select(2, string.gsub(last("blueprint.stair@1", nil), ";", "")), 2 * 48 - 2, "48 steps, each with its riser but the lowest");
	eq(last("fact.stair_done@1", nil), "0", "not done");
	eq(last("place.intel", nil), "256.00 256.00 -1.25", "the intel where it lies, for everybody");
	eq(last("blueprint.stair", 0), nil, "nothing for one bot: a bot reads its team's");
	eq(string.sub(last("blueprint.widen@1", nil), 1, 11), "158 256 49;", "the second row, beside the first, from its lowest block (the row up: as clear)");
	eq(last("fact.widen@1", nil), "1", "a second row to build");
	eq(last("blueprint.prop@1", nil), nil, "no props laid out by the script: the bots link the stair themselves (`brace`)");
	eq(last("fact.breach@2", nil), "0", "nothing of team 1's to break");
	-- team 1 builds its three lowest steps
	BUILT[k3(158, 255, 49)], BUILT[k3(159, 255, 48)], BUILT[k3(160, 255, 47)] = true, true, true;
	run(16);
	eq(sets_of("blueprint.stair@1"), 1, "the stair, as it was: not said again");
	eq(last("place.stair_top@1", nil), "160.50 255.50 44.75", "the top of what is built");
	eq(last("fact.breach@2", nil), "1", "team 2 is told team 1's stair is worth breaking");
	eq(last("place.breach@2", nil), "160.50 255.50 47.50",
		"where it is weakest: the step held by nothing but the stair (the two under it stand on the ground)");
	eq(last("fact.breach@1", nil), "0", "team 1: nothing of team 2's to break");
	-- a link stands beside that step (a column from the ground up to its
	-- level, as `brace` lays one): nothing left held by the stair alone
	BUILT[k3(160, 254, 49)], BUILT[k3(160, 254, 48)], BUILT[k3(160, 254, 47)] = true, true, true;
	run(17);
	eq(last("place.breach@2", nil), "158.50 255.50 49.50", "linked: team 2 is pointed at its foot");
	INTEL = 2;
	run(18);
	eq(last("place.intel", nil), "pid 2", "the intel: the man who carries it (who that is, the engine reads from the world)");
	-- the whole stair
	for k = 0, 47 do BUILT[k3(205 - k, 255, 2 + k)] = true; end
	run(19);
	eq(last("fact.stair_done@1", nil), "1", "team 1's stair reaches the platform");
	-- something in the way of the middle row (a tree in team 1's own
	-- area, which it may not break): the next clear row instead
	BUILT = {};
	BUILT[k3(180, 255, 25)] = true;          -- over the step at (180, 255, 27)
	mod.before.finish_map_load();
	run(20);
	eq(string.sub(last("blueprint.stair@1", nil), 1, 11), "158 254 49;", "a tree on the middle row: the stair on the next row out, clear");
	eq(string.sub(last("blueprint.stair@2", nil), 1, 11), "353 255 49;", "team 2's row is clear: its own as it was");
	-- RAIDERS: team 1's stair built three steps up, then one cut by team
	-- 2: it gets a second stair, apart from the first; the first stays as
	-- it was (mended where cut)
	local first = last("blueprint.stair@1", nil);
	BUILT[k3(158, 254, 49)], BUILT[k3(159, 254, 48)], BUILT[k3(160, 254, 47)] = true, true, true;
	run(21);
	BUILT[k3(159, 254, 48)] = nil;
	run(22);
	check(last("blueprint.stair@1", nil) == first, "cut: the first stair as it was");
	local second = last("blueprint.stair2@1", nil);
	check(second ~= nil and second ~= "" and not string.find(second, " 254 ", 1, true)
		and not string.find(second, " 253 ", 1, true) and not string.find(second, " 255 ", 1, true),
		"and a second stair for the team, a row apart at least", second and string.sub(second, 1, 24));
	check(string.find(table.concat(LOGGED, "\n"), "was cut", 1, true) ~= nil, "said in the log, with why");
	-- a bot builds: its blocks are given back (infinite_blocks refills
	-- players behind the botlink's count)
	local restocked = {};
	function restock(pid) restocked[#restocked + 1] = pid; end
	function get_hp() return 70; end
	function get_mag_ammo() return 3; end
	function get_reserve_ammo() return 20; end
	local hp_set, ammo_set;
	function set_hp(pid, hp) hp_set = hp; end
	function set_ammo(pid, m, r) ammo_set = m .. "/" .. r; end
	mod.after.on_block_action(0, {x = 1, y = 1, z = 1}, 0);
	mod.after.on_block_action(1, {x = 1, y = 1, z = 1}, 0);
	eq(#restocked, 1, "a bot that builds is restocked; a person is not");
	eq(hp_set, 70, "its health as it was");
	eq(ammo_set, "3/20", "its ammunition as it was");
end

print("\nC. the kinds of stair (lib_stairs): each climbable, built support first, its top where asked");
do
	local function flat(x, y) return 50; end        -- the ground's top at z 50 everywhere
	local function key(c) return c.x .. "," .. c.y .. "," .. c.z; end
	local top = {x = 205, y = 255, z = 2};
	local spec = {top = top, dx = -1, rows = {255, 256}, ground = flat};
	for _, kind in ipairs(stair_kinds()) do
		local st, why = stair_lay(kind, spec);
		check(st ~= nil, kind .. ": laid on flat ground", why);
		if (st ~= nil) then
			local cells, climb, room, support, onmap = {}, true, true, true, true;
			for _, c in ipairs(st.cells) do cells[key(c)] = true; end
			-- floors: each beside the last, at most a voxel up, air for a body over it
			for i, p in ipairs(st.steps) do
				local q = st.steps[i - 1];
				if (q ~= nil and (math.abs(p.x - q.x) + math.abs(p.y - q.y) ~= 1 or q.z - p.z > 1 or q.z - p.z < 0)) then
					climb = false;
				end
				for z = p.z - 3, p.z - 1 do
					if (cells[key({x = p.x, y = p.y, z = z})]) then room = false; end
				end
			end
			-- support first: each cell touches the ground or one put before it
			local put = {};
			for _, c in ipairs(st.cells) do
				local ok = c.z + 1 >= 50;
				for _, d in ipairs({{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}) do
					if (put[key({x = c.x + d[1], y = c.y + d[2], z = c.z + d[3]})]) then ok = true; end
				end
				if (not ok) then support = false; end
				put[key(c)] = true;
				if (c.x >= 206 and c.x <= 305 and c.y >= 240 and c.y <= 271) then onmap = false; end
			end
			local last = st.steps[#st.steps];
			check(climb, kind .. ": each floor beside the last, at most one voxel up");
			check(room, kind .. ": three voxels of air over every floor");
			check(support, kind .. ": every voxel touches the ground or one put before it");
			check(last.x == top.x and last.y == top.y and last.z == top.z, kind .. ": its top where asked");
			check(onmap, kind .. ": nothing on or round the platform");
			print(string.format("    %s: %d floors, %d voxels to build, %d more to widen it", kind, #st.steps, #st.cells, #st.widen));
			if (kind == "tapered") then
				-- one run a level: the cells of a level come together, a straight line
				local levels, runs = {}, true;
				for i, c in ipairs(st.cells) do
					local n = st.cells[i + 1];
					if (n ~= nil and n.z == c.z and (n.x - c.x ~= 1 or n.y ~= c.y)) then runs = false; end
					if (levels[c.z] == "done") then runs = false; end
					if (n == nil or n.z ~= c.z) then levels[c.z] = "done"; end
				end
				check(runs, "tapered: each level one straight line, laid once");
			end
			if (kind == "switchback" or kind == "spiral") then
				local far = 0;
				for _, c in ipairs(st.cells) do far = math.max(far, top.x - c.x); end
				check(far <= 5, kind .. ": in a few columns from the platform's edge (" .. far .. ")");
			end
		end
	end
	local _, why = stair_lay("switchback", {top = top, dx = -1, rows = {255}, ground = flat});
	check(why ~= nil, "a switchback with no second row: not laid, and why", why);
end

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
