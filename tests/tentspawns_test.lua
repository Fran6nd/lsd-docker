-- tentspawns_test.lua -- catalog/overrides/tentspawns.lua: no spawn on a
-- slab in the sky (keidoro's one-voxel layer at the map's top), nor in the
-- sea at a cliff's foot, nor off the map
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/tentspawns_test.lua      (from the repository root)

local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what);
	else failures = failures + 1; print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or "")); end
end

function init_mod()
	local function s() return {before = {}, after = {}, next = {}}; end
	local m = s(); m.impl, m.late, m.early, m.xearly = s(), s(), s(), s();
	return m;
end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
SPECTATOR = 3;
local NEXT_TEAM = 1;
function get_next_team() return NEXT_TEAM; end
local TENT = {x = 100, y = 100, z = 40};
local TENTS = {[1] = TENT};
function get_tentloc() return TENTS; end
local SOLID = {};                -- column "x,y" -> function(z) -> bool
local function col(f) SOLID = f; end
-- as lua.c's is_solid (get_ivec3): a column off the map is an error, which
-- ends the whole get_spawn_position (the core then spawns by its own rule)
function is_solid(p)
	local x, y = math.floor(p.x), math.floor(p.y);
	if (x < 0 or x >= 512 or y < 0 or y >= 512) then
		error(string.format("ivec3 is out of bounds (x=%d, y=%d)", x, y));
	end
	return SOLID(p.z, p);
end
math.random = function(a, b) return a; end

local mod = dofile("catalog/overrides/tentspawns.lua");
local function spawn_z() return mod.get_spawn_position(1).z + 2.251; end

print("\n1. the ground: as upstream (the highest point)");
col(function(z) return z >= 40; end);
check(math.abs(spawn_z() - 40) < 1e-6, "on the ground at 40", spawn_z());

print("\n2. a one-voxel slab at the map's top, 39 voxels of air under it");
col(function(z) return z == 0 or z >= 40; end);
check(math.abs(spawn_z() - 40) < 1e-6, "not on the slab: on the ground under it", spawn_z());

print("\n3. two slabs, one over the other, both far up");
col(function(z) return z == 0 or z == 15 or z >= 40; end);
check(math.abs(spawn_z() - 40) < 1e-6, "under both", spawn_z());

print("\n4. what is left as it was");
col(function(z) return z == 32 or z >= 40; end);
check(math.abs(spawn_z() - 32) < 1e-6, "a roof 8 over the tent (a fall that does not hurt): on it", spawn_z());
col(function(z) return (z >= 20 and z <= 25) or z >= 40; end);
check(math.abs(spawn_z() - 20) < 1e-6, "a thick block far up (a building, not a thin layer): on it", spawn_z());
col(function(z) return z == 10 or z >= 16; end);
check(math.abs(spawn_z() - 10) < 1e-6, "a thin layer with only 5 of air under it: on it", spawn_z());

print("\n5. a tent on a cliff's edge: the square's half in the sea is drawn again (babel's islands)");
-- x under 100: the sea (the map's water at 63) at the cliff's foot; from 100 on, the island at 40
col(function(z, p) return p.x < 100 and z >= 63 or p.x >= 100 and z >= 40; end);
local sp = mod.get_spawn_position(1);
check(math.abs(sp.z + 2.251 - 40) < 1e-6 and sp.x >= 100, "not in the sea: on the island, at the tent's level",
	string.format("%.1f %.1f %.1f", sp.x, sp.y, sp.z + 2.251));
local draws, real = 0, math.random;
math.random = function(a, b) draws = draws + 1; return draws <= 4 and a or b; end
sp = mod.get_spawn_position(1);
check(sp.x >= 100 and math.abs(sp.z + 2.251 - 40) < 1e-6 and draws == 6,
	"a draw in the sea, then one on the island: taken (" .. draws / 2 .. " draws)");
math.random = real;

print("\n6. no land at the tent's level anywhere in the square: the tent's own column, after every draw");
-- the sea all round, a one-column rock at the tent
col(function(z, p) return (math.floor(p.x) == 100 and math.floor(p.y) == 100) and z >= 40 or z >= 63; end);
draws = 0;
math.random = function(a, b) draws = draws + 1; return a; end
sp = mod.get_spawn_position(1);
check(sp.x == 100.5 and sp.y == 100.5 and math.abs(sp.z + 2.251 - 40) < 1e-6,
	"on the tent's column, at its level", string.format("%.1f %.1f %.1f", sp.x, sp.y, sp.z + 2.251));
check(draws == 64, "after 32 draws", draws / 2);
math.random = real;

print("\n7. a tent nearer the map's edge than tentspawns_radius: no column off the map is drawn");
TENT.x, TENT.y = 5, 509;
col(function(z) return z >= 40; end);
local low, high = math.huge, -math.huge;
math.random = function(a, b) low = math.min(low, a); high = math.max(high, b); return a; end
local ok, got = pcall(mod.get_spawn_position, 1);
check(ok, "the spawn is drawn (not an error)", not ok and got or nil);
check(low >= 0 and high <= 511, "every draw within the map", low .. " to " .. high);
math.random = function(a, b) return b; end
ok, got = pcall(mod.get_spawn_position, 1);
check(ok and got.x < 512 and got.y < 512, "the far side of the square too", not ok and got or nil);
math.random = real;
TENT.x, TENT.y = 100, 100;

print("\n8. each team round its own tent");
TENTS[2] = {x = 400, y = 300, z = 40};
NEXT_TEAM = 2;
sp = mod.get_spawn_position(1);
check(math.abs(sp.x - 400) <= tentspawns_radius and math.abs(sp.y - 300) <= tentspawns_radius,
	"team 2 by tent 2", string.format("%.1f %.1f", sp.x, sp.y));
NEXT_TEAM = 1;
TENTS[2] = nil;

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
