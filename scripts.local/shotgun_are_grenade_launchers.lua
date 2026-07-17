-- shotgun_are_grenade_launchers.lua -- One random shotgun pellet per
-- shot detonates a grenade where it lands.
--
-- The client never reports where pellets hit the world (spread is
-- client-side RNG; the server only sees player hits and block
-- destroys), so the chosen pellet is simulated here: jitter the aim
-- direction by the shotgun's spread, raycast it, boom.
local mod = init_mod();
local bit = require("bit");

getcfg("sgl_pellets", 8);     -- pellets per shell
getcfg("sgl_spread", 0.024);  -- 0.75 shotgun spread
getcfg("sgl_range", 128);     -- max pellet travel, in blocks

local function jitter(dir)
	return {
		x = dir.x + sgl_spread*(math.random()*2 - 1),
		y = dir.y + sgl_spread*(math.random()*2 - 1),
		z = dir.z + sgl_spread*(math.random()*2 - 1),
	};
end

local function explode_pellet(pid)
	local start = get_position(pid);

	-- model the shell: sgl_pellets directions, one of them is live
	local pellets = {};
	for i = 1, sgl_pellets do
		pellets[i] = jitter(get_orientation(pid));
	end
	local dir = pellets[math.random(sgl_pellets)];

	local stop = {
		x = start.x + dir.x*sgl_range,
		y = start.y + dir.y*sgl_range,
		z = start.z + dir.z*sgl_range,
	};

	-- air voxel just before the impacted one, so the explosion isn't
	-- born inside a wall (detonation LOS-checks its victims)
	local vox = raycast(start, stop, false);
	if (vox == nil) then
		return; -- the live pellet flew off into the sky
	end

	local at = {x=vox.x+0.5, y=vox.y+0.5, z=vox.z+0.5};
	detonate_grenade(spawn_grenade(pid, get_team(pid), at, {x=0, y=0, z=0}, 0));
end

function mod.after.on_join(pid)
	server_msg(pid, "warning: here shotguns are grenade launchers.");
end

-- pellets don't hurt players: only the grenade does damage
function mod.on_hit(pid, type, hitPlayer)
	if (is_alive(pid) and get_tool(pid) == 2 and get_gun(pid) == 2) then
		return;
	end
	mod.next.on_hit(pid, type, hitPlayer);
end

-- pellets do nothing to blocks: swallow gun-destroys from shotgun
-- holders and rebuild the block on the client that chewed it locally
function mod.on_block_action(pid, pos, type)
	if (type == 1 and is_alive(pid) and get_tool(pid) == 2 and get_gun(pid) == 2) then
		send_set_block_color(pid, get_map_block_color(pos), get_anon_pid());
		send_block_action(pid, pos, 0, get_anon_pid());
		return;
	end
	mod.next.on_block_action(pid, pos, type);
end

function mod.on_mouse_input(pid, bitmask)
	local oldinp = get_mouse_inputs(pid);
	mod.next.on_mouse_input(pid, bitmask);

	-- newly-pressed primary fire, holding the gun tool, with a shotgun
	if (bit.band(oldinp, 1) == 1 or bit.band(bitmask, 1) ~= 1) then
		return;
	end
	if (not is_alive(pid) or get_tool(pid) ~= 2 or get_gun(pid) ~= 2) then
		return;
	end

	explode_pellet(pid);
end

return mod;
