-- tentspawns.lua -- Spawn randomly in an area around your team's tent
-- (catalog/overrides: upstream's, patched -- skip_sky_slabs)
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
-- player put there, person or bot, has no way down that does not kill
-- him (2026-11-25: bots stood on it for good). So: while the floor found
-- is a thin layer (3 voxels or fewer) with more than 9 voxels of air
-- under it (more than a fall that does not hurt) and is higher than the
-- tent by more than 9, the floor under it is taken instead. A roof, a
-- hill, a bridge near the tent's level is left as it was.
local function skip_sky_slabs(pos, tent_z)
	while (pos.z < 63 and tent_z ~= nil and tent_z - pos.z > 9) do
		local z = pos.z;
		while (z < 63 and is_solid({x = pos.x, y = pos.y, z = z})) do z = z + 1; end
		if (z - pos.z > 3) then return; end           -- not thin: a real structure
		local below = z;
		while (below < 64 and not is_solid({x = pos.x, y = pos.y, z = below})) do below = below + 1; end
		if (below >= 64 or below - z <= 9) then return; end   -- nothing under, or a fall that does not hurt
		pos.z = below;
	end
end

local function set_highest_point_spawn(pos, tent_z)
	set_highest_point(pos);
	if (pos.z < 63) then skip_sky_slabs(pos, tent_z); end

	if (pos.z == 63) then
		pos.z = 64;
	end

	pos.z = pos.z - 2.251;
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

	local pos = {
		x=math.random(math.floor(tentpos.x-tentspawns_radius), math.floor(tentpos.x-1+tentspawns_radius))+0.5,
		y=math.random(math.floor(tentpos.y-tentspawns_radius), math.floor(tentpos.y-1+tentspawns_radius))+0.5
	};

	set_highest_point_spawn(pos, tentpos.z);

	return pos;
end

return mod;
