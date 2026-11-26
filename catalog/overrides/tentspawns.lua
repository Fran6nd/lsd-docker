-- tentspawns.lua -- Spawn randomly in an area around your team's tent
-- upstream: lsd/scripts/tentspawns.lua fnv1a32 2a44cb01 (tests/overrides_test.lua)
local mod = init_mod();

getcfg("tentspawns_radius", 20);

local function set_highest_point(pos)
	for z=0,63 do
		pos.z = z;

		if (is_solid(pos)) then
			return;
		end
	end

	pos.z = 64;
end

-- PATCHED (lsd-docker): not on a SLAB IN THE SKY. The highest point of
-- a column can be a thin floating layer far above the tent -- keidoro's
-- one-voxel slab at the map's very top, over 36 voxels of air -- and a
-- player put there, person or bot, has no way down that does not hurt
-- or kill him (2026-11-25: bots stood on it for good). So the floor
-- under such a layer is taken instead: a layer
--   * no thicker than a body (BODY): a slab, not the solid mass of a
--     hill or a building -- those reach down to something one can walk
--     or climb along, a slab hangs in the air;
--   * with more than a safe drop of air under it (SAFE_DROP): stepping
--     off it hurts;
--   * higher than the tent by more than a safe drop: from a roof, a hill
--     or a bridge within that of the tent's level, the way to the tent
--     is a drop that does not hurt, so it is left as it was.
-- The two numbers are the game's own:
--   BODY       a player standing is 3 voxels tall (his eye 2.25 over
--              the floor: the 2.251 below)
--   SAFE_DROP  the highest drop fall_damage.lua charges nothing for: its
--              get_fall_damage, demoncore's gravity until the speed
--              passes FALL_DAMAGE_VELOCITY (0.58), is 0 up to 9 voxels
--              and 1 at 10 (and 113, a death, at 20)
local BODY = 3;
local SAFE_DROP = 9;
local function skip_sky_slabs(pos, tent_z)
	while (pos.z < 63 and tent_z ~= nil and tent_z - pos.z > SAFE_DROP) do
		local z = pos.z;
		while (z < 63 and is_solid({x = pos.x, y = pos.y, z = z})) do z = z + 1; end
		if (z - pos.z > BODY) then return; end                 -- not a slab
		local below = z;
		while (below < 64 and not is_solid({x = pos.x, y = pos.y, z = below})) do below = below + 1; end
		if (below >= 64 or below - z <= SAFE_DROP) then return; end   -- nothing under, or a safe drop
		pos.z = below;
	end
end

local function set_highest_point_spawn(pos, tent_z)   -- PATCHED (lsd-docker): tent_z
	set_highest_point(pos);
	if (pos.z < 63) then skip_sky_slabs(pos, tent_z); end   -- PATCHED (lsd-docker)

	if (pos.z == 63) then
		pos.z = 64;
	end

	pos.z = pos.z - 2.251;
end

-- PATCHED (lsd-docker): ON LAND NEAR THE TENT'S LEVEL. A tent on a
-- cliff's edge (babel's islands: tents at the outer edges, the sea twenty
-- voxels under) puts half the square of tentspawns_radius in the sea at
-- the cliff's foot: a man there has no way up (2026-11-26: 28 of 60 bots
-- in the water within two minutes, and the notches leave_water dug held
-- some of them for good). A place is drawn again until it is LAND -- not
-- the sea, the map's water at z 63 -- whose floor is no lower than the
-- tent's by more than SAFE_DROP (from the tent, a drop that does not hurt
-- gets there, and the way back is the slope that made it) and no higher
-- than it by more than SAFE_DROP either (a hill one walks up); SPAWN_DRAWS
-- draws at most, then the tent's own column, which is always land at its
-- level. With half the square bad, 32 draws miss with a chance of one in
-- four billion.
local SPAWN_DRAWS = 32;
local function near_tent_land(pos, tent_z)
	local floor = pos.z + 2.251;        -- the floor the eye was put over
	return floor < 63 and (tent_z == nil or math.abs(floor - tent_z) <= SAFE_DROP);
end

function mod.get_spawn_position(pid)
	local team = get_next_team(pid);

	if (team == SPECTATOR) then
		return mod.next.get_spawn_position(pid);
	end

	-- TODO: just pass in team to get_tentloc(), not this table-returning crap
	local tentpos = get_tentloc()[team];
	if (tentpos == nil) then
		return mod.next.get_spawn_position(pid);
	end

	local pos;
	for _ = 1, SPAWN_DRAWS do                    -- PATCHED (lsd-docker): on land near the tent's level
		pos = {
			x=math.random(math.floor(tentpos.x-tentspawns_radius), math.floor(tentpos.x-1+tentspawns_radius))+0.5,
			y=math.random(math.floor(tentpos.y-tentspawns_radius), math.floor(tentpos.y-1+tentspawns_radius))+0.5
		};

		set_highest_point_spawn(pos, tentpos.z);   -- PATCHED (lsd-docker): the tent's level
		if (near_tent_land(pos, tentpos.z)) then return pos; end
	end
	pos = {x = math.floor(tentpos.x) + 0.5, y = math.floor(tentpos.y) + 0.5};
	set_highest_point_spawn(pos, tentpos.z);

	return pos;
end

return mod;
