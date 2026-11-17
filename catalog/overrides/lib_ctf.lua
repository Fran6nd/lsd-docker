-- lib_ctf.lua -- Bucket of functions for implementing CTF-like gamemodes
local mod = init_mod();

getcfg("lib_ctf_tent_radius",  3);
getcfg("lib_ctf_tent_bottom",  1);
getcfg("lib_ctf_tent_top",    -4);

getcfg("lib_ctf_intel_radius", 3);
getcfg("lib_ctf_intel_bottom", 1);
getcfg("lib_ctf_intel_top",   -4);

function mod.impl.objgrav(pos)
	local new = {x=pos.x, y=pos.y, z=pos.z};

	new.z = math.max(0, new.z);

	-- TODO: not a very nice-looking construction. . .
	if (new.z >= 64) then
		new.z = 63;
		if (not is_solid(new)) then
			new.z = 64;
			return new;
		end
	end

	-- PATCHED (lsd-docker): the clamped copy, not pos. An object at
	-- z=64 over a solid bottom voxel reaches here with pos.z still 64,
	-- and get_floor(pos) panics the server: "ivec3 is out of bounds".
	new.z = get_floor(new);
	if (new.z < 64) then
		new.z = get_col_top(new);
	end

	return new;
end

local function gravitate_thing(move, team, loc)
	local new = objgrav(loc);

	if (new.z ~= loc.z) then
		move(team, new);
	end
end

function mod.impl.gravitate_intel(team, loc)
	return gravitate_thing(move_intel, team, loc); end

function mod.impl.gravitate_tent(team, loc)
	return gravitate_thing(move_tent,  team, loc); end

function mod.impl.gravitate_intels()
	local locs = get_intelloc();

	for team, loc in pairs(locs) do
		-- TODO: too much of a pain in the ass to use num/tbl/nil
		-- loc, just use tbl/nil and num/nil *separately*
		if (type(loc) == "table") then
			gravitate_intel(team, loc);
		end
	end
end

function mod.impl.gravitate_tents()
	local locs = get_tentloc();

	for team, loc in pairs(locs) do
		gravitate_tent(team, loc);
	end
end

local function length2(vec)
	return math.sqrt(vec.x*vec.x + vec.y*vec.y);
end

local function within_cylinder(pos, cylinderpos, radius, bottom, top)
	pos.x = pos.x - cylinderpos.x;
	pos.y = pos.y - cylinderpos.y;
	pos.z = pos.z - cylinderpos.z;

	if (length2(pos) > radius or pos.z < top or pos.z > bottom) then
		return false;
	end

	return true;
end

function mod.impl.tent_in_range(player_pos, tent_pos)
	return player_pos ~= nil and tent_pos ~= nil and
		within_cylinder(
			player_pos, tent_pos,
			lib_ctf_tent_radius,
			lib_ctf_tent_bottom,
			lib_ctf_tent_top
		);
end

function mod.impl.intel_in_range(player_pos, intel_pos)
	return player_pos ~= nil and intel_pos ~= nil and
		within_cylinder(
			player_pos, intel_pos,
			lib_ctf_intel_radius,
			lib_ctf_intel_bottom,
			lib_ctf_intel_top
		);
end

function mod.impl.has_intel(pid)
	return get_intelloc()[(get_team(pid) == 1 and 2 or 1)] == pid;
end

-- TODO: probably polyfill core move_intel() to drop for voxlap
function mod.impl.drop_move_intel(team, pos)
	local loc = get_intelloc()[team];

	if (type(loc) == "number") then
		drop_intel(loc, pos);
	else
		move_intel(team, pos);
	end
end

function mod.impl.get_1intel_loc()
	local intelloc = get_intelloc();

	return intelloc[1] or intelloc[2];
end

function mod.impl.drop_1intel(pid, pos)
	local hide = {x=math.huge, y=math.huge, z=math.huge};

	drop_intel(pid, get_team(pid) == 2 and pos or hide);

	if (get_team(pid) == 1) then
		move_intel(1, pos);
	end
end

function mod.impl.move_1intel(pos)
	move_intel(1, pos);
	move_intel(2, {x=math.huge, y=math.huge, z=math.huge});
end

function mod.impl.pickup_1intel(pid)
	pickup_intel(pid);

	if (get_team(pid) == 1) then
		move_intel(1, {x=math.huge, y=math.huge, z=math.huge});
	end
end

-- TODO: handle this in core or something
function mod.impl.after_map_altered() end

function mod.after.block_action(pos, type)
	-- non-0 type is handled by finish_cull()
	if (type == 0) then
		after_map_altered();
	end
end

function mod.after.block_line()
	after_map_altered();
end

function mod.after.finish_cull()
	after_map_altered();
end

return mod;
