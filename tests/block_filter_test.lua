-- block_filter_test.lua -- one question for every edit of the map
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/block_filter_test.lua      (from the repository root)
--
-- The real lib_block_filter between a small copy of the engine's block
-- paths (main.c: block_action, block_action_rm and its masks, the cull)
-- and the real protections of babel and parkour: whatever takes blocks --
-- a rocket, a missile, an airstrike, a grenade launcher's grenade, the
-- server's own grenade, a bot's dig, a script's bulk destroy, a player's
-- spade, a line of blocks -- is asked, block by block, and leaves what
-- the gamemode keeps standing while it takes the rest.
package.path = "catalog/libs/block_filter/?.lua;" .. package.path;

local passed, failed = 0, 0;
local function check(ok, what, detail)
	if (ok) then passed = passed + 1; print("  PASS " .. what);
	else failed = failed + 1; print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or "")); end
end

--============================== THE ENGINE ============================--
MAX_PLAYERS = 32;
PID_BROADCAST = 0x20000000;
local ANON = 254;
function get_anon_pid() return ANON; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function log() end
function get_time() return 100; end
function pid_connected_table(d) return setmetatable({}, {__index = function() return d; end}); end

local function hooks() return {before = {}, after = {}, next = {}}; end
function init_mod()
	local m = hooks();
	m.impl, m.late, m.early, m.xearly = hooks(), hooks(), hooks(), hooks();
	return m;
end

local solid = {};
local function k(x, y, z) return x .. "," .. y .. "," .. z; end
function is_solid(p) return solid[k(math.floor(p.x), math.floor(p.y), math.floor(p.z))] == true or p.z >= 62; end
local function put(x, y, z) solid[k(x, y, z)] = true; end

local culls, finished = 0, 0;
-- main.c's block_action_rm: what each type takes, and a mask that says so
local function engine_rm(pos, type, from)
	local took = 0;
	local function rm(x, y, z)
		if (solid[k(x, y, z)]) then solid[k(x, y, z)] = nil; took = took + 1; end
	end
	if (type == 1) then
		rm(pos.x, pos.y, pos.z);
	elseif (type == 2) then
		if (pos.z < 62) then rm(pos.x, pos.y, pos.z); end
		if (pos.z < 61) then rm(pos.x, pos.y, pos.z + 1); end
		if (pos.z > 0) then rm(pos.x, pos.y, pos.z - 1); end
	elseif (type == 3) then
		for dz = -1, 1 do for dy = -1, 1 do for dx = -1, 1 do
			if (pos.z + dz < 62 and pos.z + dz >= 0) then rm(pos.x + dx, pos.y + dy, pos.z + dz); end
		end end end
	end
	return took > 0 and (type * 2^30 + 1) or 0;
end
local function engine_cull() culls = culls + 1; end
local function engine_finish() finished = finished + 1; end
local function engine_block_action(pos, type, from)
	if (type == 0) then
		put(pos.x, pos.y, pos.z);
	else
		block_action_cull(pos, block_action_rm(pos, type, from));
		finish_cull();
	end
end
local function engine_block_line(a, b, from)
	for p in iter_block_line(a, b) do put(p.x, p.y, p.z); end
end
function iter_block_line(a, b)
	local list, i = {}, 0;
	local n = math.max(math.abs(b.x - a.x), math.abs(b.y - a.y), math.abs(b.z - a.z));
	for s = 0, n do
		list[#list+1] = {x = a.x + (b.x > a.x and s or (b.x < a.x and -s or 0)),
			y = a.y + (b.y > a.y and s or (b.y < a.y and -s or 0)), z = a.z};
	end
	return function() i = i + 1; return list[i]; end
end
block_action_cull, finish_cull = engine_cull, engine_finish;
block_action_rm, block_action, block_line = engine_rm, engine_block_action, engine_block_line;

-- bulk destroy, as upstream's lib_bulk_destroy
local queued = {};
function bdestroy_block_action(pos, type)
	local mask = block_action_rm(pos, type, get_anon_pid());
	if (mask ~= 0) then queued[#queued+1] = {pos, mask}; end
	return mask ~= 0;
end
function bdestroy_finish()
	for _, q in ipairs(queued) do block_action_cull(q[1], q[2]); end
	queued = {};
	finish_cull();
end
package.loaded["lib_bulk_destroy"] = true;

-- the player's own action, as main.c's on_block_action reaches it
local function player_action(pid, pos, type) block_action(pos, type, pid); end

--============================ THE FILTER, WIRED =======================--
-- hook chains as the core builds them: the later module sits in front
local function wire(mod, group, name, base_of)
	local tab = group == nil and mod or mod[group];
	if (tab[name] == nil) then return; end
	local below = _G[name] or base_of;
	tab.next[name] = below;
	_G[name] = tab[name];
end
local filter = dofile("catalog/libs/block_filter/lib_block_filter.lua");
for name, f in pairs(filter.impl) do if (type(f) == "function") then _G[name] = f; end end
for _, name in ipairs({"block_action_rm", "block_action", "block_line"}) do wire(filter, "early", name); end
local function protect(mod)
	wire(mod, nil, "may_edit_block");
end
-- a server of one gamemode: only its protection is in the chain
local function only(mod)
	may_edit_block = filter.impl.may_edit_block;
	protect(mod);
end

--============================ THE PLAYERS =============================--
-- 0 and 1: team 1; 2: team 2; 3: team 2, a bot
local TEAM = {[0] = 1, [1] = 1, [2] = 2, [3] = 2};
function get_team(pid) return TEAM[pid]; end
function is_joined(pid) return TEAM[pid] ~= nil; end
function is_alive(pid) return TEAM[pid] ~= nil; end
function is_connected(pid) return TEAM[pid] ~= nil; end
local POS = {};
function get_position(pid) return POS[pid] or {x = 0, y = 0, z = 0}; end
local ORI = {};
function get_orientation(pid) return ORI[pid] or {x = 0, y = 0, z = 1}; end
function get_name(pid) return "P" .. pid; end
function get_tool() return 2; end
function get_gun() return 0; end
function piditer() local i = -1; return function() i = i + 1; if (TEAM[i] ~= nil) then return i; end end; end
function damage_player() end
function shot_listen() end
function shot_unlisten() end
function teamplay_ping_all() end
function send_set_block_color() end
function send_block_action() end
function PID_BROADCAST_TEAM(t) return 3 * 0x20000000 + t; end
local L = dofile("tests/support/l10n_env.lua").load{};
L.pids = {0, 1, 2, 3};

--============================ THE EFFECTS =============================--
dofile("catalog/libs/player_effect/lib_player_effect.lua");
local blast = dofile("catalog/libs/blast/lib_blast.lua");
for name, f in pairs(blast.impl) do if (type(f) == "function") then _G[name] = f; end end
local function fly(n) for _ = 1, n do blast.after.tick(); end end
-- as the server answers (see rocket_test): the voxel hit, or the one before it
function raycast(a, b, last)
	if (a.z < 0) then return nil; end
	local before;
	for i = 0, 400 do
		local t = i / 400;
		local p = {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t};
		local v = {x = math.floor(p.x), y = math.floor(p.y), z = math.floor(p.z)};
		if (p.z >= 0 and is_solid(p)) then return last and before or v; end
		before = v;
	end
end
local rocket_mod = dofile("catalog/effects/player/rocket/rocket.lua");
rocket_mod.on_load();
local missile_mod = dofile("catalog/effects/player/missile/missile.lua");
missile_mod.on_load();
local PE = PlayerEffect;

--============================ THE GAMEMODES ===========================--
babel_width, babel_height, babel_z = 100, 32, 1;
babel_protect_zones = {
	{{{x = 128, y = 240}, {x = 225, y = 271}}},
	{{{x = 287, y = 240}, {x = 383, y = 271}}},
};
function get_tentloc() return {}; end
local babel = dofile("catalog/gamemodes/babel/babel_plus.lua");
protect(babel);

-- the map: babel's platform at z 1, x 206..305, y 240..271; a stair
-- under it (the unprotected blocks the crater should take)
local function platform()
	for x = 206, 305 do for y = 240, 271 do put(x, y, 1); end end
end
local function count_platform()
	local n = 0;
	for x = 206, 305 do for y = 240, 271 do if (solid[k(x, y, 1)]) then n = n + 1; end end end
	return n;
end
local PLATFORM = 100 * 32;
local function reset()
	solid = {};
	platform();
	culls, finished = 0, 0;
	POS = {[0] = {x = 250.5, y = 250.5, z = 0.5}};
	blast_clear();
end
-- a ball of blocks under the platform's middle: what a rocket may take
local function rubble(cx, cy, cz, r)
	for x = cx - r, cx + r do for y = cy - r, cy + r do for z = cz - r, cz + r do
		if (not solid[k(x, y, z)]) then put(x, y, z); end
	end end end
end
local function some_rubble_gone(cx, cy, cz)
	return not solid[k(cx, cy, cz)];
end

print("\n1. a rocket at babel's platform: it takes the rubble, never the platform");
reset();
rubble(250, 250, 3, 3);   -- z 0..6 around: the platform's own layer is z 1
for x = 247, 253 do for y = 247, 253 do put(x, y, 1); end end
rubble(250, 250, 6, 0);
-- rubble above and below the platform's layer, in the crater's reach
for z = 2, 5 do put(250, 250, z); put(251, 250, z); end
put(250, 250, 0);
ORI[0] = {x = 0, y = 0, z = 1};
POS[0] = {x = 250.5, y = 250.5, z = 0.2};
local fx = PE.get("rocket");
fx:trigger(0, {});
fly(8);
check(count_platform() == PLATFORM, "the platform is whole", count_platform());
check(not solid[k(250, 250, 2)] and not solid[k(250, 250, 3)],
	"and the rubble in the crater's reach is gone: the blast took the rest");

print("\n2. a missile, an airstrike's bomb, a plain blast: the same");
reset();
for z = 2, 5 do put(250, 250, z); put(251, 250, z); put(250, 251, z); end
local ms = PE.get("missile");
ms:trigger(0, {});
fly(40);
check(count_platform() == PLATFORM, "a missile: the platform is whole", count_platform());
reset();
for z = 2, 5 do put(250, 250, z); end
blast_fire(0, {x = 250.5, y = 250.5, z = 0.5}, {x = 0, y = 0, z = 1}, {speed = 2, radius = 4});
fly(10);
check(count_platform() == PLATFORM, "a bomb dropped on it: whole", count_platform());
check(not solid[k(250, 250, 4)], "and what is under it taken");
reset();
for z = 2, 6 do put(250, 250, z); end
blast_explode(0, {x = 250.5, y = 250.5, z = 1.5}, 3, 0);
check(count_platform() == PLATFORM, "a blast centred on it, as the world's: whole", count_platform());
blast_explode(nil, {x = 250.5, y = 250.5, z = 3.5}, 3, 0);
check(count_platform() == PLATFORM and not solid[k(250, 250, 4)], "and the world's own: whole, the rubble taken");

print("\n3. the server's own grenade, a launcher's, a spade, a bulk destroy: the same");
reset();
for z = 2, 4 do put(250, 250, z); end
block_action({x = 250, y = 250, z = 2}, 3, 0);
check(count_platform() == PLATFORM, "a grenade on the block under it: whole", count_platform());
check(not solid[k(250, 250, 2)] and not solid[k(250, 250, 3)],
	"but the blocks of its 3x3x3 that are not the platform's are taken");
block_action({x = 250, y = 250, z = 1}, 3, 0);
check(count_platform() == PLATFORM, "a grenade on the platform itself: whole");
block_action({x = 250, y = 250, z = 1}, 1, 0);
block_action({x = 250, y = 250, z = 1}, 2, 0);
player_action(0, {x = 251, y = 250, z = 1}, 1);
check(count_platform() == PLATFORM, "a player's own destroy, a spade: whole");
bdestroy_block_action({x = 250, y = 250, z = 1}, 1);
bdestroy_block_action({x = 252, y = 252, z = 1}, 3);
bdestroy_finish();
check(count_platform() == PLATFORM, "a script's bulk destroy: whole");
check(culls >= 0 and finished >= 1, "and the cull is finished");
-- nobody builds on it either, nor one beside it, but a script paints it
player_action(0, {x = 250, y = 250, z = 2}, 0);
check(not solid[k(250, 250, 2)], "a player's block just under it is refused");
solid[k(250, 250, 1)] = nil;
block_action({x = 250, y = 250, z = 1}, 0, ANON);
check(solid[k(250, 250, 1)], "the platform's own rebuild (a script's build) goes through");
block_line({x = 250, y = 244, z = 1}, {x = 250, y = 247, z = 1}, 0);
check(solid[k(250, 247, 1)] == true, "a line of blocks elsewhere is built");
block_line({x = 207, y = 244, z = 2}, {x = 207, y = 247, z = 2}, 0);
check(not solid[k(207, 247, 2)], "a line of a player's across the layer under the platform: refused whole");

print("\n4. a bot's dig, as lib_bot's bot_dig_block makes it (edit_as)");
reset();
put(250, 250, 3);
check(edit_as(3, bdestroy_block_action, {x = 250, y = 250, z = 1}, 1) == false and solid[k(250, 250, 1)],
	"at the platform: refused, and told so");
check(edit_as(3, bdestroy_block_action, {x = 250, y = 250, z = 3}, 1) == true and not solid[k(250, 250, 3)],
	"elsewhere: dug");
bdestroy_finish();

print("\n5. the tower areas: a team's own is its own to keep");
reset();
for x = 223, 228 do put(x, 250, 40); end
blast_explode(0, {x = 226.5, y = 250.5, z = 40.5}, 3, 0);   -- team 1's, zone x 128..225
check(solid[k(224, 250, 40)] and solid[k(225, 250, 40)], "team 1's rocket takes nothing of its own area");
check(not solid[k(226, 250, 40)] and not solid[k(227, 250, 40)], "and everything outside it");
reset();
for x = 223, 228 do put(x, 250, 40); end
TEAM[0] = 2;
blast_explode(0, {x = 226.5, y = 250.5, z = 40.5}, 3, 0);
TEAM[0] = 1;
check(not solid[k(224, 250, 40)] and not solid[k(225, 250, 40)], "team 2's rocket takes team 1's tower: that is the game");
reset();
for x = 223, 228 do put(x, 250, 40); end
edit_as(nil, bdestroy_block_action, {x = 224, y = 250, z = 40}, 3);
bdestroy_finish();
check(solid[k(224, 250, 40)] and solid[k(225, 250, 40)], "the world's own effects (the_fall) take neither team's tower");
reset();
player_action(0, {x = 350, y = 250, z = 40}, 0);
check(not solid[k(350, 250, 40)], "a player's block in the enemy's area: refused");
player_action(0, {x = 150, y = 250, z = 40}, 0);
check(solid[k(150, 250, 40)], "in his own: built");
player_action(0, {x = 150, y = 250, z = 40}, 1);
check(solid[k(150, 250, 40)], "and not broken by him");

print("\n6. what no gamemode keeps breaks as ever");
reset();
for x = 100, 106 do put(x, 100, 30); end
blast_explode(0, {x = 103.5, y = 100.5, z = 30.5}, 3, 0);
check(not solid[k(102, 100, 30)] and not solid[k(104, 100, 30)], "a rocket's crater far from anything kept");
player_action(0, {x = 100, y = 100, z = 30}, 1);
put(100, 100, 30);
player_action(0, {x = 100, y = 100, z = 30}, 1);
check(not solid[k(100, 100, 30)], "a player's own destroy");
player_action(0, {x = 100, y = 100, z = 30}, 0);
check(solid[k(100, 100, 30)], "a player's build");

print("\n7. the server's own work is not asked");
reset();
local asked = 0;
local counter = init_mod();
function counter.may_edit_block(who, pos, type)
	asked = asked + 1;
	return false;
end
protect(counter);
server_edit(function()
	block_action({x = 10, y = 10, z = 10}, 0, ANON);
	block_line({x = 10, y = 11, z = 10}, {x = 12, y = 11, z = 10}, ANON);
	block_action({x = 10, y = 10, z = 10}, 1, ANON);
end);
check(asked == 0 and not solid[k(10, 10, 10)] and solid[k(11, 11, 10)], "a structure drawn and taken down by the server: never asked");
block_action({x = 10, y = 12, z = 10}, 0, ANON);
check(asked == 1 and not solid[k(10, 12, 10)], "the same, not marked: asked, and refused here");
local ok, err = pcall(server_edit, function() error("boom"); end);
block_action({x = 10, y = 13, z = 10}, 0, ANON);
check(not ok and asked == 2, "a server_edit that fails does not leave the door open");
ok = pcall(edit_as, 0, function() error("boom"); end);
local who;
function counter.may_edit_block(w) who = w; return true; end
block_action({x = 10, y = 14, z = 10}, 0, ANON);
check(who == nil, "nor an edit_as that fails keep its owner");

print("\n8. the range's start wall, parkour's course, a map's door: kept by what they answer, against everything");
-- the real modules, loaded against whatever they only look up when they run
local function load_mode(path)
	setmetatable(_G, {__index = function() return function() end; end});
	local ok, m = pcall(dofile, path);
	setmetatable(_G, nil);
	assert(ok, m);
	return m;
end
local range = load_mode("catalog/gamemodes/range/range.lua");
only(range);
local WALL = {x0 = 100, x1 = 105, y0 = 100, y1 = 101, z0 = 40, z1 = 41};
reset();
for x = WALL.x0, WALL.x1 do for y = WALL.y0, WALL.y1 do for z = WALL.z0, WALL.z1 do put(x, y, z); end end end
local wall_n = 6 * 2 * 2;
local function wall_whole()
	local n = 0;
	for x = WALL.x0, WALL.x1 do for y = WALL.y0, WALL.y1 do for z = WALL.z0, WALL.z1 do
		if (solid[k(x, y, z)]) then n = n + 1; end
	end end end
	return n == wall_n;
end
blast_explode(0, {x = 102.5, y = 100.5, z = 40.5}, 3, 0);
check(wall_whole(), "a rocket at the start wall: it stands");
block_action({x = 102, y = 100, z = 40}, 3, 0);
check(wall_whole(), "the server's own grenade: it stands");
edit_as(3, bdestroy_block_action, {x = 102, y = 100, z = 40}, 1);
bdestroy_finish();
check(wall_whole(), "a bot's dig: it stands");
player_action(0, {x = 102, y = 100, z = 40}, 1);
check(wall_whole(), "a player's spade: it stands");

local parkour = load_mode("catalog/gamemodes/parkour/parkour.lua");
only(parkour);
reset();
for x = 0, 20 do put(x, 5, 30); end
blast_explode(0, {x = 10.5, y = 5.5, z = 30.5}, 3, 0);
block_action({x = 10, y = 5, z = 30}, 3, 0);
player_action(0, {x = 1, y = 5, z = 30}, 1);
local course = 0;
for x = 0, 20 do if (solid[k(x, 5, 30)]) then course = course + 1; end end
check(course == 21, "parkour's course: a rocket, a grenade, a spade take nothing");

package.path = "catalog/libs/map_layout/?.lua;" .. package.path;
local layout = load_mode("catalog/libs/map_layout/lib_map_layout.lua");
only(layout);
local we = require "map_layout.blocks";
reset();
for x = 300, 305 do put(x, 300, 30); we.guarded[we.key(x, 300, 30)] = 1; end
blast_explode(0, {x = 302.5, y = 300.5, z = 30.5}, 3, 0);
block_action({x = 302, y = 300, z = 30}, 3, 0);
edit_as(nil, bdestroy_block_action, {x = 301, y = 300, z = 30}, 1);
bdestroy_finish();
local door = 0;
for x = 300, 305 do if (solid[k(x, 300, 30)]) then door = door + 1; end end
check(door == 6, "a map's door: a rocket, a grenade, a script's destroy take nothing", door);
put(303, 301, 30);
block_action({x = 303, y = 301, z = 30}, 3, 0);
check(not solid[k(303, 301, 30)] and solid[k(303, 300, 30)], "and a grenade beside it takes what is not the door's");
-- its own drawing is the server's
we.fill({id = 1}, 310, 300, 30, 311, 300, 30, nil, true, nil, false);
check(solid[k(310, 300, 30)] and solid[k(311, 300, 30)], "the layout draws its own door: not asked");
we.fill({id = 1}, 310, 300, 30, 311, 300, 30, nil, false);
check(not solid[k(310, 300, 30)], "and takes it down");

print("\n9. what a refused edit did on the client is put back there -- a person's, not a bot's");
-- the range, parkour and the layout's own guard refuse a player's edit in
-- the late on_block_action and undo it on his client (map_layout.revert_*)
local sent = {};
function send_block_action(pid) sent[#sent+1] = pid; end
function send_set_block_color(pid) sent[#sent+1] = pid; end
function get_map_block_color() return {1, 2, 3}; end
function bot_is_bot(pid) return pid == 3; end
map_layout.revert_action(0, {x = 302, y = 300, z = 30}, 2);
map_layout.revert_line(0, {x = 1, y = 1, z = 40}, {x = 3, y = 1, z = 40});
check(#sent == 3 * 2 + 3 and sent[1] == 0, "a person's spade (3 blocks) and line (3): put back on his client", #sent);
sent = {};
map_layout.revert_action(3, {x = 302, y = 300, z = 30}, 2);
map_layout.revert_line(3, {x = 1, y = 1, z = 40}, {x = 3, y = 1, z = 40});
check(#sent == 0, "a bot has no client: nothing is sent to it", #sent);
bot_is_bot = nil;

print(string.format("\n%d checks, %d failed", passed + failed, failed));
os.exit(failed > 0 and 1 or 0);
