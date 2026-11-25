-- tentspawns_test.lua -- catalog/overrides/tentspawns.lua: no spawn on a
-- slab in the sky (keidoro's one-voxel layer at the map's top)
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
function get_next_team() return 1; end
local TENT = {x = 100, y = 100, z = 40};
function get_tentloc() return {[1] = TENT}; end
local SOLID = {};                -- column "x,y" -> function(z) -> bool
local function col(f) SOLID = f; end
function is_solid(p) return SOLID(p.z); end
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

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
