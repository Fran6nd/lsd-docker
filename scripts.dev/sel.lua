-- sel.lua -- Perform bulk place/destroy operations on selections
require "lib_l10n";
require "lib_bulk_destroy";
local bit = require("bit");
local mod = init_mod();

local sel         = pid_joined_table(nil);
local sel_start   = pid_joined_table(nil);
local sel_end     = pid_joined_table(nil);
local sel_shape   = pid_joined_table("cube");
local sel_shapefn = pid_joined_table(function() return function() return bit.band(bit.bxor(bit.bxor(x, y), z), 1) == 1; end; end);
local sel_noise   = pid_joined_table(0);

-- true while /sel is picking: it aims, /sel1 and /sel2 still use a block
-- action, and swallowing applies only to the former
local sel_pick    = pid_joined_table(false);
local sel_mouse   = pid_joined_table(0);

getcfg("sel_pick_range", 160);

local sel_begin_msg = {
	en="Beginning selection."
};

local sel_begin_start_msg = {
	en="Beginning selection start."
};

local sel_begin_end_msg = {
	en="Beginning selection end."
};

local sel_start_done_msg = {
	en="Selection started at {x=%(x), y=%(y), z=%(z)}."
};

local sel_end_done_msg = {
	en="Selection ended at {x=%(x), y=%(y), z=%(z)}."
};

local sel_unbegan_msg = {
	en="Begin a selection first."
};

local sel_unstarted_msg = {
	en="Start the selection first."
};

local sel_unended_msg = {
	en="End the selection first."
};

-- TODO: automatically determine shapes
local invalid_shape_msg = {
	en="shape should be one of the following: cube, box, sphere, cylinderx, cylindery, cylinderz, fn"
};

local invalid_dir_msg = {
	en="%(arg) should be one of the following: x, -x, +x, y, -y, +y, z, -z, +z"
};

local missing_component_msg = {
	en="Swizzle must map all of x, y and z"
};

local pick_not_hit_msg = {
	en="Nothing that way to pick. Aim at a block."
};

local cast_not_hit_msg = {
	en="Couldn't find any block in that cast. You're certain you're not looking at the sky?"
};

local shapes = {
	cube=true,
	box=true,
	sphere=true,
	cylinderx=true,
	cylindery=true,
	cylinderz=true,
	fn=true
};

local function in_shape(pos, start, endp, shape, pid)
	if (shape == "cube") then
		return true;
	end

	if (shape == "box") then
		return pos.x == start.x or pos.x == endp.x or
		       pos.y == start.y or pos.y == endp.y or
		       pos.z == start.z or pos.z == endp.z;
	end

	if (shape == "sphere" or string.find(shape, "^cylinder"))then
		-- TODO: fix sphere-on-a-wall not doing anything
		local radius = {
			x=(endp.x-start.x)/2,
			y=(endp.y-start.y)/2,
			z=(endp.z-start.z)/2,
		};

		local ctr = {
			x=start.x+radius.x,
			y=start.y+radius.y,
			z=start.z+radius.z
		};

		local diff = {
			x=pos.x-ctr.x,
			y=pos.y-ctr.y,
			z=pos.z-ctr.z,
		};

		if (shape == "sphere") then
			return (diff.x*diff.x) / (radius.x*radius.x) + (diff.y*diff.y) / (radius.y*radius.y) + (diff.z*diff.z) / (radius.z*radius.z) <= 1;
		elseif (shape == "cylinderx") then
			return (diff.y*diff.y) / (radius.y*radius.y) + (diff.z*diff.z) / (radius.z*radius.z) <= 1;
		elseif (shape == "cylindery") then
			return (diff.x*diff.x) / (radius.x*radius.x) + (diff.z*diff.z) / (radius.z*radius.z) <= 1;
		else
			return (diff.x*diff.x) / (radius.x*radius.x) + (diff.y*diff.y) / (radius.y*radius.y) <= 1;
		end
	end

	if (shape == "fn") then
		local env = {
			x=pos.x-start.x,
			y=pos.y-start.y,
			z=pos.z-start.z,
			size={x=endp.x-start.x+1, y=endp.y-start.y+1, z=endp.z-start.z+1},
			bit={
				tobit=bit.tobit,
				tohex=bit.tohex,
				bnot=bit.bnot,
				band=bit.band,
				bor=bit.bor,
				bxor=bit.bxor,
				lshift=bit.lshift,
				rshift=bit.rshift,
				arshift=bit.arshift,
				rol=bit.rol,
				ror=bit.ror,
				bswap=bit.bswap
			},
			math={
				abs=math.abs,
				acos=math.acos,
				asin=math.asin,
				atan=math.atan,
				atan2=math.atan2,
				ceil=math.ceil,
				cos=math.cos,
				cosh=math.cosh,
				deg=math.deg,
				exp=math.exp,
				floor=math.floor,
				fmod=math.fmod,
				frexp=math.frexp,
				huge=math.huge,
				ldexp=math.ldexp,
				log=math.log,
				log10=math.log10,
				max=math.max,
				min=math.min,
				modf=math.modf,
				pi=math.pi,
				pow=math.pow,
				rad=math.rad,
				random=math.random,
				sin=math.sin,
				sinh=math.sinh,
				sqrt=math.sqrt,
				tan=math.tan,
				tanh=math.tanh
			}
		};
		setfenv(sel_shapefn[pid], env);

		local status, err = pcall(sel_shapefn[pid]);
		if (status == false) then
			server_msg(pid, "pcall: "..tostring(err));
			return false;
		end

		return not not err;
	end
end

-- Arm the two-corner pick; mod.on_mouse_input takes it from there.
local function begin_sel(pid)
	sel[pid] = 0;
	sel_pick[pid] = true;
	sel_start[pid] = nil;
	sel_end[pid] = nil;
	l10n_send_chat(pid, sel_begin_msg);
end

-- Arm a selection for another script. It should say in its own words what
-- the selection is for, since the player did not ask for one.
function mod.impl.sel_begin(pid)
	begin_sel(pid);
end

-- A corner given as numbers names the block containing the point, so
-- fractional coordinates floor rather than being refused.
local function corner_arg(pid, cmd, argv, i)
	return {
		x=math.floor(get_arg_num_range("x", pid, cmd, argv[i],     0, 511)),
		y=math.floor(get_arg_num_range("y", pid, cmd, argv[i + 1], 0, 511)),
		z=math.floor(get_arg_num_range("z", pid, cmd, argv[i + 2], 0, 63)),
	};
end

local cmd = {name="sel", caps="sel", usage="[x y z [x y z]]",
             desc="Select a box, by aiming at its corners or by naming them."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0 or #argv == 3 or #argv == 6);

	-- no arguments: both corners come from aiming, as before
	if (#argv == 0) then
		begin_sel(pid);
		return;
	end

	-- read both before storing either: get_arg_num_range aborts on a bad
	-- number, and a half-given box must not half-replace the old one
	local a = corner_arg(pid, cmd, argv, 1);
	local b = (#argv == 6) and corner_arg(pid, cmd, argv, 4) or nil;

	sel_start[pid] = a;
	l10n_send_chat(pid, sel_start_done_msg, a);

	if (b == nil) then
		-- one corner named, the other still to be picked
		sel[pid] = 1;
		sel_pick[pid] = true;
		sel_end[pid] = nil;
		l10n_send_chat(pid, sel_begin_end_msg);
		return;
	end

	sel[pid] = nil;
	sel_pick[pid] = false;
	sel_end[pid] = b;
	l10n_send_chat(pid, sel_end_done_msg, b);
end
register_command(cmd, mod);

local cmd = {name={"selstart", "sel1"}, caps="sel", usage="[x y z]", desc="Set the start of a selection."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0 or #argv == 3);

	if (#argv == 0) then
		sel[pid] = -1;
		sel_pick[pid] = false;
		sel_start[pid] = nil;
		l10n_send_chat(pid, sel_begin_start_msg);
	else
		sel[pid] = nil;
		sel_pick[pid] = false;
		sel_start[pid] = {
			-- TODO: unhardcode map dimensions
			x=math.floor(get_arg_num_range("x", pid, cmd, argv[1], 0, 511)),
			y=math.floor(get_arg_num_range("y", pid, cmd, argv[2], 0, 511)),
			z=math.floor(get_arg_num_range("z", pid, cmd, argv[3], 0, 63))
		};
		l10n_send_chat(pid, sel_start_done_msg, sel_start[pid]);
	end
end
register_command(cmd, mod);

local cmd = {name="sel1c", caps="sel", desc="Raycast the start of a selection."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0);

	-- TODO: only not dead?
	-- TODO: make cast prettier?
	local pos = get_position(pid);
	local ori = get_orientation(pid);
	local castpos = raycast(pos, {x=pos.x+ori.x*512, y=pos.y+ori.y*512, z=pos.z+ori.z*512}, false);

	if (castpos == nil) then
		l10n_send_chat(pid, cast_not_hit_msg);
		return;
	end

	sel[pid] = nil;
	sel_pick[pid] = false;
	sel_start[pid] = castpos;
	l10n_send_chat(pid, sel_start_done_msg, sel_start[pid]);
end
register_command(cmd, mod);

local cmd = {name="sel1h", caps="sel", desc="Set the start of a selection to your head's position."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0);

	local pos = get_position(pid);
	pos.z = math.max(0, pos.z);

	sel[pid] = nil;
	sel_pick[pid] = false;
	sel_start[pid] = {x=math.floor(pos.x), y=math.floor(pos.y), z=math.floor(pos.z)};
	l10n_send_chat(pid, sel_start_done_msg, sel_start[pid]);
end
register_command(cmd, mod);

local cmd = {name={"selend", "sel2"}, caps="sel", usage="[x y z]", desc="Set the end of a selection."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0 or #argv == 3);

	if (#argv == 0) then
		sel[pid] = 1;
		sel_pick[pid] = false;
		sel_end[pid] = nil;
		l10n_send_chat(pid, sel_begin_end_msg);
	else
		sel[pid] = nil;
		sel_pick[pid] = false;
		sel_end[pid] = {
			x=math.floor(get_arg_num_range("x", pid, cmd, argv[1], 0, 511)),
			y=math.floor(get_arg_num_range("y", pid, cmd, argv[2], 0, 511)),
			z=math.floor(get_arg_num_range("z", pid, cmd, argv[3], 0, 63))
		};
		l10n_send_chat(pid, sel_end_done_msg, sel_end[pid]);
	end
end
register_command(cmd, mod);

local cmd = {name="sel2c", caps="sel", desc="Raycast the end of a selection."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0);

	-- TODO: dedup sel1c/sel2c?
	local pos = get_position(pid);
	local ori = get_orientation(pid);
	local castpos = raycast(pos, {x=pos.x+ori.x*512, y=pos.y+ori.y*512, z=pos.z+ori.z*512}, false);

	if (castpos == nil) then
		l10n_send_chat(pid, cast_not_hit_msg);
		return;
	end

	sel[pid] = nil;
	sel_pick[pid] = false;
	sel_end[pid] = castpos;
	l10n_send_chat(pid, sel_end_done_msg, sel_end[pid]);
end
register_command(cmd, mod);

local cmd = {name="sel2h", caps="sel", desc="Set the end of a selection to your head's position."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0);

	local pos = get_position(pid);
	pos.z = math.max(0, pos.z);

	sel[pid] = nil;
	sel_pick[pid] = false;
	sel_end[pid] = {x=math.floor(pos.x), y=math.floor(pos.y), z=math.floor(pos.z)};
	l10n_send_chat(pid, sel_end_done_msg, sel_end[pid]);
end
register_command(cmd, mod);

-- TODO: unsel -> selstop?
local cmd = {name="unsel", caps="sel", desc="Stop a selection."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0);

	sel[pid] = nil;
	sel_pick[pid] = false;
	sel_start[pid] = nil;
	sel_end[pid] = nil;
end
register_command(cmd, mod);

local cmd = {name={"selshape", "selsh"}, caps="sel", usage="shape", desc="Change selection shape."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 1);

	if (shapes[argv[1]] == nil) then
		send_usage(pid, cmd);
		l10n_send_chat(pid, invalid_shape_msg);
		return;
	end

	sel_shape[pid] = argv[1];
end
register_command(cmd, mod);

local cmd = {name={"selshapefn", "selshfn"}, caps="sel", usage="lua", desc="Change \"fn\" selection shape. Does not parse args."};
function cmd.func(pid, argv, msg)
	-- Sure hope nobody runs this without LuaJIT.
	local func, err = loadstring(string.sub(msg, 6, 6) == "a" and string.sub(msg, 11, -1) or string.sub(msg, 8, -1), "t");

	if (func == nil) then
		server_msg(pid, "loadstring: "..tostring(err));
		return;
	end

	sel_shapefn[pid] = func;
end
register_command(cmd, mod);

local cmd = {name={"selnoise", "selns"}, caps="sel", usage="noise", desc="Change selection noise."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 1);
	sel_noise[pid] = math.floor(get_arg_num_range("noise", pid, cmd, argv[1], 0, math.huge));
end
register_command(cmd, mod);

local function require_sel(pid)
	if (sel_start[pid] == nil or sel_end[pid] == nil) then
		if (sel[pid] == nil and sel_start[pid] == nil and sel_end[pid] == nil) then
			l10n_send_chat(pid, sel_unbegan_msg);
		elseif (sel_start[pid] == nil) then
			l10n_send_chat(pid, sel_unstarted_msg);
		else
			l10n_send_chat(pid, sel_unended_msg);
		end

		cmd_exit();
	end
end

local function set_noised_color(pid, clr)
	local noise = math.random(-sel_noise[pid], sel_noise[pid]);
	for chan,val in pairs(clr) do
		clr[chan] = math.min(math.max(val + noise, 0), 255);
	end
	set_block_color(get_anon_pid(), clr);
end

local cmd = {name="selrep", caps="sel", desc="Fill and replace a box."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0);
	require_sel(pid);

	-- TODO: remove and just use the per-block set_color?
	if (sel_noise[pid] == 0) then
		set_block_color(get_anon_pid(), get_block_color(pid));
	end

	for z=sel_start[pid].z, sel_end[pid].z, sel_start[pid].z > sel_end[pid].z and -1 or 1 do
		for y=sel_start[pid].y, sel_end[pid].y, sel_start[pid].y > sel_end[pid].y and -1 or 1 do
			for x=sel_start[pid].x, sel_end[pid].x, sel_start[pid].x > sel_end[pid].x and -1 or 1 do
				local pos = {x=x, y=y, z=z};
				if (in_shape(pos, sel_start[pid], sel_end[pid], sel_shape[pid], pid)) then
					if (sel_noise[pid] ~= 0) then
						set_noised_color(pid, get_block_color(pid));
					end
					block_action(pos, 0, get_anon_pid());
				end
			end
		end
	end
end
register_command(cmd, mod);

local cmd = {name={"selclobber", "selcb"}, caps="sel", desc="Clobber over everything in your selection to match the current shape."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0);
	require_sel(pid);

	-- TODO: remove and just use the per-block set_color?
	if (sel_noise[pid] == 0) then
		set_block_color(get_anon_pid(), get_block_color(pid));
	end

	for z=sel_start[pid].z, sel_end[pid].z, sel_start[pid].z > sel_end[pid].z and -1 or 1 do
		for y=sel_start[pid].y, sel_end[pid].y, sel_start[pid].y > sel_end[pid].y and -1 or 1 do
			for x=sel_start[pid].x, sel_end[pid].x, sel_start[pid].x > sel_end[pid].x and -1 or 1 do
				local pos = {x=x, y=y, z=z};
				if (in_shape(pos, sel_start[pid], sel_end[pid], sel_shape[pid], pid)) then
					if (sel_noise[pid] ~= 0) then
						set_noised_color(pid, get_block_color(pid));
					end
					block_action(pos, 0, get_anon_pid());
				else
					block_action(pos, 1, get_anon_pid());
				end
			end
		end
	end
end
register_command(cmd, mod);

local function linex(start, endp)
	for x=start.x,endp.x,50 do
		block_line({x=x, y=start.y, z=start.z}, {x=math.min(x+49, endp.x), y=endp.y, z=endp.z}, get_anon_pid());
	end
end

local function liney(start, endp)
	for y=start.y,endp.y,50 do
		block_line({x=start.x, y=y, z=start.z}, {x=endp.x, y=math.min(y+49, endp.y), z=endp.z}, get_anon_pid());
	end
end

local function linez(start, endp)
	for z=start.z,endp.z,50 do
		block_line({x=start.x, y=start.y, z=z}, {x=endp.x, y=endp.y, z=math.min(z+49, endp.z)}, get_anon_pid());
	end
end

-- True while a corner is still owed. A script acting on the same click
-- must stand aside while this holds.
function mod.impl.sel_pending(pid)
	return sel[pid] ~= nil;
end

-- The two corners, or nil while either is missing. Copies, so a caller
-- cannot move the selection by accident.
function mod.impl.sel_corners(pid)
	local a, b = sel_start[pid], sel_end[pid];
	if (a == nil or b == nil) then
		return nil;
	end
	return {x=a.x, y=a.y, z=a.z}, {x=b.x, y=b.y, z=b.z};
end

local function order(x1, x2)
	if (x1 <= x2) then
		return x1, x2;
	end

	return x2, x1;
end

local function iter_box(pid)
	local x1, x2 = order(sel_start[pid].x, sel_end[pid].x);
	local y1, y2 = order(sel_start[pid].y, sel_end[pid].y);
	local z1, z2 = order(sel_start[pid].z, sel_end[pid].z);

	for x=x1, x2, x1 > x2 and -1 or 1 do
		linez({x=x, y=y1, z=z1}, {x=x, y=y1, z=z2});
		linez({x=x, y=y2, z=z1}, {x=x, y=y2, z=z2});
	end

	for y=y1, y2, y1 > y2 and -1 or 1 do
		linex({x=x1, y=y, z=z1}, {x=x2, y=y, z=z1});
		linex({x=x1, y=y, z=z2}, {x=x2, y=y, z=z2});

		linez({x=x1, y=y, z=z1}, {x=x1, y=y, z=z2});
		linez({x=x2, y=y, z=z1}, {x=x2, y=y, z=z2});
	end
end

local cmd = {name="selfill", caps="sel", desc="Fill and do not replace a box."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0);
	require_sel(pid);

	local x1, x2 = order(sel_start[pid].x, sel_end[pid].x);

	if (sel_noise[pid] == 0) then
		set_block_color(get_anon_pid(), get_block_color(pid));
	end
	if (sel_shape[pid] == "cube" and sel_noise[pid] == 0) then
		for z=sel_start[pid].z, sel_end[pid].z, sel_start[pid].z > sel_end[pid].z and -1 or 1 do
			for y=sel_start[pid].y, sel_end[pid].y, sel_start[pid].y > sel_end[pid].y and -1 or 1 do
				linex({x=x1, y=y, z=z}, {x=x2, y=y, z=z});
			end
		end
	elseif (sel_shape[pid] == "box" and sel_noise[pid] == 0) then
		iter_box(pid);
	else
		-- TODO: iter_sphere
		for z=sel_start[pid].z, sel_end[pid].z, sel_start[pid].z > sel_end[pid].z and -1 or 1 do
			for y=sel_start[pid].y, sel_end[pid].y, sel_start[pid].y > sel_end[pid].y and -1 or 1 do
				for x=sel_start[pid].x, sel_end[pid].x, sel_start[pid].x > sel_end[pid].x and -1 or 1 do
					local pos = {x=x, y=y, z=z};
					if (in_shape(pos, sel_start[pid], sel_end[pid], sel_shape[pid], pid) and not is_solid(pos)) then
						if (sel_noise[pid] ~= 0) then
							set_noised_color(pid, get_block_color(pid));
						end
						block_action(pos, 0, get_anon_pid());
					end
				end
			end
		end
	end
end
register_command(cmd, mod);

local function do_rm(pid)
	-- TODO: range iter for single points, this is a mess
	if (sel_shape[pid] == "cube") then
		-- Destroy perimeter
		for z=sel_start[pid].z, sel_end[pid].z, sel_start[pid].z > sel_end[pid].z and -1 or 1 do
			for y=sel_start[pid].y, sel_end[pid].y, sel_start[pid].y > sel_end[pid].y and -1 or 1 do
				bdestroy_block_action({x=sel_start[pid].x, y=y, z=z}, 1);
				bdestroy_block_action({x=sel_end[pid].x, y=y, z=z}, 1);
			end
		end

		for z=sel_start[pid].z, sel_end[pid].z, sel_start[pid].z > sel_end[pid].z and -1 or 1 do
			for x=sel_start[pid].x, sel_end[pid].x, sel_start[pid].x > sel_end[pid].x and -1 or 1 do
				bdestroy_block_action({x=x, y=sel_start[pid].y, z=z}, 1);
				bdestroy_block_action({x=x, y=sel_end[pid].y, z=z}, 1);
			end
		end

		for y=sel_start[pid].y, sel_end[pid].y, sel_start[pid].y > sel_end[pid].y and -1 or 1 do
			for x=sel_start[pid].x, sel_end[pid].x, sel_start[pid].x > sel_end[pid].x and -1 or 1 do
				bdestroy_block_action({x=x, y=y, z=sel_start[pid].z}, 1);
				bdestroy_block_action({x=x, y=y, z=sel_end[pid].z}, 1);
			end
		end
		bdestroy_finish();

		-- Clean up after floating blocks
		for z=sel_start[pid].z, sel_end[pid].z, sel_start[pid].z > sel_end[pid].z and -1 or 1 do
			for y=sel_start[pid].y, sel_end[pid].y, sel_start[pid].y > sel_end[pid].y and -1 or 1 do
				for x=sel_start[pid].x, sel_end[pid].x, sel_start[pid].x > sel_end[pid].x and -1 or 1 do
					local pos = {x=x, y=y, z=z};
					if (is_solid(pos)) then
						block_action(pos, 1, get_anon_pid());
					end
				end
			end
		end

		return;
	end

	for z=sel_start[pid].z, sel_end[pid].z, sel_start[pid].z > sel_end[pid].z and -1 or 1 do
		for y=sel_start[pid].y, sel_end[pid].y, sel_start[pid].y > sel_end[pid].y and -1 or 1 do
			for x=sel_start[pid].x, sel_end[pid].x, sel_start[pid].x > sel_end[pid].x and -1 or 1 do
				local pos = {x=x, y=y, z=z};
				if (in_shape(pos, sel_start[pid], sel_end[pid], sel_shape[pid], pid)) then
					bdestroy_block_action(pos, 1);
				end
			end
		end
	end
	bdestroy_finish();
end

-- TODO: integrate bulk operations into core, and do it smartly
local cmd = {name="selrm", caps="sel", desc="Destroy a box."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0);
	require_sel(pid);

	do_rm(pid);
end
register_command(cmd, mod);

-- TODO: handle voxlap
local cmd = {name="selpaint", caps="sel", desc="Set color of all blocks in a box."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0);
	require_sel(pid);

	if (sel_noise[pid] == 0) then
		set_block_color(get_anon_pid(), get_block_color(pid));
	end
	for z=sel_start[pid].z, sel_end[pid].z, sel_start[pid].z > sel_end[pid].z and -1 or 1 do
		for y=sel_start[pid].y, sel_end[pid].y, sel_start[pid].y > sel_end[pid].y and -1 or 1 do
			for x=sel_start[pid].x, sel_end[pid].x, sel_start[pid].x > sel_end[pid].x and -1 or 1 do
				local pos = {x=x, y=y, z=z};
				if (in_shape(pos, sel_start[pid], sel_end[pid], sel_shape[pid], pid) and is_solid(pos)) then
					if (sel_noise[pid] ~= 0) then
						set_noised_color(pid, get_block_color(pid));
					end
					block_action(pos, 0, get_anon_pid());
				end
			end
		end
	end
end
register_command(cmd, mod);

local dirmap = {
	["-x"]={x=-1, y= 0, z= 0},
	["+x"]={x= 1, y= 0, z= 0},
	[ "x"]={x= 1, y= 0, z= 0},

	["-y"]={x= 0, y=-1, z= 0},
	["+y"]={x= 0, y= 1, z= 0},
	[ "y"]={x= 0, y= 1, z= 0},

	["-z"]={x= 0, y= 0, z=-1},
	["+z"]={x= 0, y= 0, z= 1},
	[ "z"]={x= 0, y= 0, z= 1},
};

local function get_player_dir(pid)
	local ori = get_orientation(pid);

	if (math.abs(ori.x) >= math.abs(ori.y) and math.abs(ori.x) >= math.abs(ori.z)) then
		return {x=ori.x<0 and -1 or 1, y=0, z=0};
	elseif (math.abs(ori.y) >= math.abs(ori.z)) then
		return {x=0, y=ori.y<0 and -1 or 1, z=0};
	end

	return {x=0, y=0, z=ori.z<0 and -1 or 1};
end

local function do_selcpy(cmd, pid, argv, is_solid, get_map_block_color, forceoff)
	cmd_assert(pid, cmd, #argv <= 2);

	-- TODO: use -3 z instead of 3 -z?
	local dir;
	local times = get_arg_num_finite_opt("times", pid, cmd, argv[1]) or 1;

	if (#argv == 2) then
		dir = dirmap[argv[2]];
		if (dir == nil) then
			send_usage(pid, cmd);
			l10n_send_chat(pid, invalid_dir_msg, {arg="direction"});
			return;
		end
	else
		dir = get_player_dir(pid);
	end

	require_sel(pid);

	local x1, x2 = order(sel_start[pid].x, sel_end[pid].x);
	local y1, y2 = order(sel_start[pid].y, sel_end[pid].y);
	local z1, z2 = order(sel_start[pid].z, sel_end[pid].z);

	local off = {x=0, y=0, z=0};
	for i=1,times do
		local offpremult = {
			x=(x2-x1+1)*dir.x,
			y=(y2-y1+1)*dir.y,
			z=(z2-z1+1)*dir.z
		}

		if (forceoff == nil) then
			off = {
				x=offpremult.x*i,
				y=offpremult.y*i,
				z=offpremult.z*i
			};
		else
			off = forceoff;
		end

		if (x1 + off.x < 0 or
		    x2 + off.x >= 512 or
		    y1 + off.y < 0 or
		    y2 + off.y >= 512 or
		    z1 + off.z < 0 or
		    z2 + off.z >= 64) then
			off = {
				x=offpremult.x*(i-1),
				y=offpremult.y*(i-1),
				z=offpremult.z*(i-1)
			};
			break;
		end

		for z=z1,z2 do
			for y=y1,y2 do
				for x=x1,x2 do
					local pos = {x=x, y=y, z=z};
					local newpos = {x=x+off.x, y=y+off.y, z=z+off.z};

					if (in_shape(pos, sel_start[pid], sel_end[pid], sel_shape[pid], pid)) then
						if (not is_solid(pos)) then
							-- TODO: make destroy optional
							-- TODO: make sure this doesn't allow gravity to be "helpful"
							-- TODO: bring gravitied blocks back from the dead if you have to
							block_action(newpos, 1, get_anon_pid());
						end
					end
				end
			end
		end

		for z=z1,z2 do
			for y=y1,y2 do
				for x=x1,x2 do
					local pos = {x=x, y=y, z=z};
					local newpos = {x=x+off.x, y=y+off.y, z=z+off.z};

					if (in_shape(pos, sel_start[pid], sel_end[pid], sel_shape[pid], pid)) then
						if (is_solid(pos)) then
							set_noised_color(pid, get_map_block_color(pos));
							block_action(newpos, 0, get_anon_pid());
						end
					end
				end
			end
		end
	end

	local min = {
		x=math.min(x1+off.x, x1),
		y=math.min(y1+off.y, y1),
		z=math.min(z1+off.z, z1)
	}

	local max = {
		x=math.max(x2, x2+off.x),
		y=math.max(y2, y2+off.y),
		z=math.max(z2, z2+off.z)
	}

	return min, max;
end

local cmd = {name="selcpy", caps="sel", usage="[times] [direction]", desc="Duplicate the selection in a direction a certain number of times."};
function cmd.func(pid, argv)
	do_selcpy(cmd, pid, argv, is_solid, get_map_block_color);
end
register_command(cmd, mod);

local cmd = {name="reselcpy", caps="sel", usage="[times] [direction]", desc="Duplicate the selection in a direction a certain number of times, then select the duplicated area."};
function cmd.func(pid, argv)
	sel_start[pid], sel_end[pid] = do_selcpy(cmd, pid, argv, is_solid, get_map_block_color);
end
register_command(cmd, mod);

local function do_selmv(pid, cmd, off)
	require_sel(pid);

	local area = {};
	for z=sel_start[pid].z, sel_end[pid].z, sel_start[pid].z > sel_end[pid].z and -1 or 1 do
		for y=sel_start[pid].y, sel_end[pid].y, sel_start[pid].y > sel_end[pid].y and -1 or 1 do
			for x=sel_start[pid].x, sel_end[pid].x, sel_start[pid].x > sel_end[pid].x and -1 or 1 do
				local pos = {x=x, y=y, z=z};
				if (is_solid(pos)) then
					local clr = get_map_block_color(pos);
					area[z+x*64+y*512*64] = bit.bor(clr.r, bit.bor(bit.lshift(clr.g, 8), bit.lshift(clr.b, 16)));
				end
			end
		end
	end

	do_rm(pid);

	-- TODO: bitmask api. . ???
	-- TODO: selclip/paste/save/load
	-- TODO: way to freeze arbitrary blocks in air?
	local function mv_is_solid(pos)
		return area[pos.z+pos.x*64+pos.y*512*64] ~= nil;
	end

	local function mv_get_map_block_color(pos)
		local ent = area[pos.z+pos.x*64+pos.y*512*64];
		return {r=bit.band(ent, 255), g=bit.band(bit.rshift(ent, 8), 255), b=bit.rshift(ent, 16)};
	end

	do_selcpy(cmd, pid, {1}, mv_is_solid, mv_get_map_block_color, off);

	-- Move players standing on selection
	local x1, x2 = order(sel_start[pid].x, sel_end[pid].x);
	local y1, y2 = order(sel_start[pid].y, sel_end[pid].y);
	local z1, z2 = order(sel_start[pid].z, sel_end[pid].z);

	for i in piditer(PID_BROADCAST) do
		-- TODO: conform to selshape?
		if (is_alive(i) and not is_airborne(i)) then
			local pos = get_position(i);
			if (
				pos.x >= x1 - 0.45 and
				pos.x < x2 + 1.45 and
				pos.y >= y1 - 0.45 and
				pos.y < y2 + 1.45 and

				pos.z >= z1 - 2.3 and
				pos.z < z2 - 0.3
			) then
				set_position(i, {x=pos.x+off.x, y=pos.y+off.y, z=pos.z+off.z});
			end
		end
	end

	-- TODO: wouldn't it be "easier" to set off to 0 and just
	-- use pre-off'd sel_start/end?
	sel_start[pid] = {
		x=sel_start[pid].x + off.x,
		y=sel_start[pid].y + off.y,
		z=sel_start[pid].z + off.z
	};

	sel_end[pid] = {
		x=sel_end[pid].x + off.x,
		y=sel_end[pid].y + off.y,
		z=sel_end[pid].z + off.z
	};
end

local function swiz_vec(vec, swiz, swizflip)
	vec = {
		x=vec[swiz.x],
		y=vec[swiz.y],
		z=vec[swiz.z]
	};

	for axis,_ in pairs(swizflip) do
		vec[axis] = -vec[axis];
	end

	return vec;
end

local function swiz_pos(pos, starts, start, swiz, swizsiz, swizflip)
	local swizpos = {
		x=pos[swiz.x]-starts[swiz.x],
		y=pos[swiz.y]-starts[swiz.y],
		z=pos[swiz.z]-starts[swiz.z]
	};

	-- Axes which shouldn't be flipped
	-- are set to nil, and not iterated
	for axis,_ in pairs(swizflip) do
		swizpos[axis] = swizsiz[axis]-swizpos[axis];
	end

	for axis,val in pairs(swizpos) do
		swizpos[axis] = start[axis] + val;
	end

	return swizpos;
end

-- TODO: merge with selmv?
local function do_selswiz(pid, cmd, swiz, swizflip)
	require_sel(pid);

	local x1, x2 = order(sel_start[pid].x, sel_end[pid].x);
	local y1, y2 = order(sel_start[pid].y, sel_end[pid].y);
	local z1, z2 = order(sel_start[pid].z, sel_end[pid].z);

	-- Technically off by one
	local starts = {x=x1, y=y1, z=z1};
	local ends = {x=x2, y=y2, z=z2};
	local selsiz = {
		x=x2-x1,
		y=y2-y1,
		z=z2-z1
	};

	local swizsiz = {
		x=ends[swiz.x]-starts[swiz.x],
		y=ends[swiz.y]-starts[swiz.y],
		z=ends[swiz.z]-starts[swiz.z]
	};

	local selctr = {
		x=x2-selsiz.x/2,
		y=y2-selsiz.y/2,
		z=z2-selsiz.z/2
	};

	start = {
		x=math.floor(selctr.x-swizsiz.x/2),
		y=math.floor(selctr.y-swizsiz.y/2),
		z=math.floor(selctr.z-swizsiz.z/2)
	};

	endp = {
		x=start.x+swizsiz.x,
		y=start.y+swizsiz.y,
		z=start.z+swizsiz.z
	};

	local area = {};
	for z=z1, z2 do
		for y=y1, y2 do
			for x=x1, x2 do
				local pos = {x=x, y=y, z=z};
				if (is_solid(pos)) then
					local clr = get_map_block_color(pos);
					local swizpos = swiz_pos(pos, starts, start, swiz, swizsiz, swizflip);

					area[swizpos.z+swizpos.x*64+swizpos.y*512*64] = bit.bor(clr.r, bit.bor(bit.lshift(clr.g, 8), bit.lshift(clr.b, 16)));
				end
			end
		end
	end

	do_rm(pid);

	sel_start[pid] = start;
	sel_end[pid] = endp;

	-- TODO: bitmask api. . ???
	-- TODO: selclip/paste/save/load
	-- TODO: way to freeze arbitrary blocks in air?
	local function mv_is_solid(pos)
		return area[pos.z+pos.x*64+pos.y*512*64] ~= nil;
	end

	local function mv_get_map_block_color(pos)
		local ent = area[pos.z+pos.x*64+pos.y*512*64];
		return {r=bit.band(ent, 255), g=bit.band(bit.rshift(ent, 8), 255), b=bit.rshift(ent, 16)};
	end

	do_selcpy(cmd, pid, {1}, mv_is_solid, mv_get_map_block_color, {x=0, y=0, z=0});

	-- Move players standing on selection (TODOTODO)
	for i in piditer(PID_BROADCAST) do
		-- TODO: conform to selshape?
		if (is_alive(i) and not is_airborne(i)) then
			local pos = get_position(i);
			if (
				pos.x >= x1 - 0.45 and
				pos.x < x2 + 1.45 and
				pos.y >= y1 - 0.45 and
				pos.y < y2 + 1.45 and

				pos.z >= z1 - 2.3 and
				pos.z < z2 - 0.3
			) then
				set_position(i, swiz_pos(pos, starts, start, swiz, {x=swizsiz.x+1, y=swizsiz.y+1, z=swizsiz.z+1}, swizflip));
				set_orientation(i, swiz_vec(get_orientation(i), swiz, swizflip));
			end
		end
	end
end

local cmd = {name="selmv", caps="sel", usage="x y z", desc="Move the selection, then select the moved area."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 3);

	-- TODO: modulo/validate??? what about z?
	local off = {
		x=math.floor(get_arg_num_finite("x", pid, cmd, argv[1])),
		y=math.floor(get_arg_num_finite("y", pid, cmd, argv[2])),
		z=math.floor(get_arg_num_finite("z", pid, cmd, argv[3]))
	};

	do_selmv(pid, cmd, off);
end
register_command(cmd, mod);

local cmd = {name="selmvd", caps="sel", usage="dist", desc="Move the selection dist blocks in the direction you're facing, then select the moved area."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 1);
	local dist = get_arg_num_finite("dist", pid, cmd, argv[1]);

	local off = get_player_dir(pid);
	off = {
		x=off.x*dist,
		y=off.y*dist,
		z=off.z*dist
	};

	do_selmv(pid, cmd, off);
end
register_command(cmd, mod);

local axismap = {
	     x="x",      y="y",      z="z",
	["+x"]="x", ["+y"]="y", ["+z"]="z",
	["-x"]="x", ["-y"]="y", ["-z"]="z"
};

local flipmap = {
	     x=nil,       y=nil,       z=nil,
	["+x"]=nil,  ["+y"]=nil,  ["+z"]=nil,
	["-x"]=true, ["-y"]=true, ["-z"]=true
};

local cmd = {name="selswiz", caps="sel", usage="x y z", desc="Swizzle the dimensions of the selection around to flip and rotate."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 3);

	local swiz = {
		x=axismap[argv[1]];
		y=axismap[argv[2]];
		z=axismap[argv[3]];
	};

	local swizflip = {
		x=flipmap[argv[1]];
		y=flipmap[argv[2]];
		z=flipmap[argv[3]];
	};

	local found = {};
	for _,axis in ipairs{"x", "y", "z"} do
		if (swiz[axis] == nil) then
			send_usage(pid, cmd);
			l10n_send_chat(pid, invalid_dir_msg, {arg=axis});
			return;
		end
		found[swiz[axis]] = true;
	end

	for _,axis in ipairs{"x", "y", "z"} do
		if (found[axis] == nil) then
			l10n_send_chat(pid, missing_component_msg);
			return;
		end
	end

	do_selswiz(pid, cmd, swiz, swizflip);
end
register_command(cmd, mod);

local function take_corner(pid, pos)
	if (sel[pid] <= 0) then
		sel_start[pid] = pos;
		l10n_send_chat(pid, sel_start_done_msg, pos);

		if (sel[pid] == -1) then
			-- TODO: use 0 instead of nil?
			sel[pid] = nil;
		else
			sel[pid] = 1;
		end
	else
		sel_end[pid] = pos;
		l10n_send_chat(pid, sel_end_done_msg, pos);
		sel[pid] = nil;
	end
end

-- Undo, for this one client, the change it has already drawn for itself:
-- swallowing the action server-side does not put the block back on their
-- screen. The colour is safe to read precisely because the block is still
-- solid here.
local function unbreak(pid, pos, type)
	if (type == 0) then
		send_block_action(pid, pos, 1, get_anon_pid());
		return;
	end
	if (is_solid(pos)) then
		send_set_block_color(pid, get_map_block_color(pos), get_anon_pid());
		send_block_action(pid, pos, 0, get_anon_pid());
	end
end

-- /sel1 and /sel2 still take their corner from the block action.
function mod.on_block_action(pid, pos, type)
	if (not sel_pick[pid] and type <= 1 and sel[pid]) then
		take_corner(pid, pos);
		return;
	end
	mod.next.on_block_action(pid, pos, type);
end

-- Picking a corner must not cost the map a block. This swallow sits in
-- the `late` chain rather than the default one so that scripts which
-- merely observe block actions still see them: refusing to break a block
-- does not mean the shot never happened, and a script animating gunfire
-- or correcting the engine's magazine estimate from it would otherwise
-- go blind for as long as a corner is outstanding. Dispatch runs
-- xearly -> early -> std -> late -> impl, so this is the last word before
-- the engine while everything above still runs.
function mod.late.on_block_action(pid, pos, type)
	if (not sel_pick[pid]) then
		mod.late.next.on_block_action(pid, pos, type);
		return;
	end

	unbreak(pid, pos, type);
	-- a spade swing takes the block above and below with it
	if (type == 2) then
		unbreak(pid, {x=pos.x, y=pos.y, z=pos.z-1}, type);
		unbreak(pid, {x=pos.x, y=pos.y, z=pos.z+1}, type);
	end
end

-- ...nor may a block line slip past.
function mod.late.on_block_line(pid, start, stop)
	if (not sel_pick[pid]) then
		mod.late.next.on_block_line(pid, start, stop);
		return;
	end
	for p in iter_block_line(start, stop) do
		send_block_action(pid, p, 1, get_anon_pid());
	end
end

-- Beware: the engine reports no mouse input while sprinting or during a
-- tool switch (see on_mouse_input), so a corner cannot be picked with
-- sprint held.
function mod.on_mouse_input(pid, bitmask)
	local held = bit.band(bitmask, 1) ~= 0;
	local pressed = held and bit.band(sel_mouse[pid], 1) == 0;
	sel_mouse[pid] = bitmask;

	-- Released, not "last corner landed": the input change and the block
	-- action of one click are separate packets in no fixed order, so
	-- clearing on the corner lets that click's action through.
	if (not held and sel[pid] == nil) then
		sel_pick[pid] = false;
	end

	if (pressed and sel_pick[pid] and sel[pid] ~= nil) then
		local from = get_position(pid);
		local ori = get_orientation(pid);
		local to = {x=from.x + ori.x*sel_pick_range,
		            y=from.y + ori.y*sel_pick_range,
		            z=from.z + ori.z*sel_pick_range};

		-- raycast() gives the voxel that was hit when `last` is false. It
		-- wraps x/y around the map, so a hit can still come back out of
		-- bounds vertically -- that is the virtual floor beneath the map,
		-- not a block anybody can select.
		local vox = raycast(from, to, false);
		if (vox ~= nil and (vox.z < 0 or vox.z > 63)) then
			vox = nil;
		end

		if (vox == nil) then
			l10n_send_chat(pid, pick_not_hit_msg);
		else
			take_corner(pid, vox);
		end
	end

	mod.next.on_mouse_input(pid, bitmask);
end

return mod;
