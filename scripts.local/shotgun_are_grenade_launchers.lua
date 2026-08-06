-- shotgun_are_grenade_launchers.lua -- Shotgun pellets are grenades
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- One random pellet per shot detonates a grenade where it lands.
--
-- The client never reports where pellets hit the world (spread is
-- client-side RNG; the server only sees player hits and block
-- destroys), so the chosen pellet is simulated here: jitter the aim
-- direction by the shotgun's spread, raycast it, boom.
--
-- Knowing that a shell was fired at all is lib_shot_detect's job, not this
-- one's -- it is the same problem the railgun script has, and it is
-- harder than it looks. Load lib_shot_detect before this.
local mod = init_mod();

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
	local vox = raycast(start, stop, true);
	local tmap = sgl_range;
	if (vox ~= nil) then
		local dx = vox.x+0.5-start.x;
		local dy = vox.y+0.5-start.y;
		local dz = vox.z+0.5-start.z;
		tmap = math.sqrt(dx*dx + dy*dy + dz*dz);
	end

	-- the map raycast only sees voxels, so a pellet aimed at an enemy
	-- would sail through them and burst on whatever is behind: check
	-- the ray against enemy bodies and burst at the first one clipped
	local tbody = nil;
	for i in piditer(PID_BROADCAST) do
		if (i ~= pid and is_alive(i) and get_team(i) ~= get_team(pid)) then
			local q = get_position(i);
			local wx, wy, wz = q.x-start.x, q.y-start.y, q.z-start.z;
			local t = wx*dir.x + wy*dir.y + wz*dir.z;
			if (t > 0.5 and t < tmap and (tbody == nil or t < tbody)
			    and wx*wx + wy*wy + wz*wz - t*t < 1.44) then
				tbody = t;
			end
		end
	end

	local at;
	if (tbody ~= nil) then
		-- burst just short of the body, in open air next to it
		at = {
			x = start.x + dir.x*(tbody-0.5),
			y = start.y + dir.y*(tbody-0.5),
			z = start.z + dir.z*(tbody-0.5),
		};
	elseif (vox ~= nil) then
		at = {x=vox.x+0.5, y=vox.y+0.5, z=vox.z+0.5};
	else
		return; -- the live pellet flew off into the sky
	end
	local still = {x=0, y=0, z=0};

	-- the shooter's copy of the grenade is attributed to the anon pid:
	-- clients decrement their own grenade stock when they receive a
	-- grenade packet naming themselves, and this gun eats shells, not
	-- grenades
	local idx = register_grenade(pid, get_team(pid), at, still, 0);
	send_grenade(PID_BROADCAST_EXCEPT(pid), at, still, 0, pid);
	send_grenade(pid, at, still, 0, get_anon_pid());

	local hp = get_hp(pid);
	detonate_grenade(idx);

	-- close-range self-damage net, in case the engine's detonation
	-- spared the shooter (KillType 3 = grenade)
	if (is_alive(pid) and get_hp(pid) == hp) then
		local p = get_position(pid);
		local d2 = (p.x-at.x)^2 + (p.y-at.y)^2 + (p.z-at.z)^2;
		if (d2 < 256) then
			damage_player_directional(pid, 4096/math.max(d2, 1), at, 3, pid);
		end
	end
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

-- One shell, one live pellet, whoever worked out that a shell was fired.
--
-- The swallowing hooks above are why lib_shot_detect watches from the xearly
-- chain: they take a pellet's hit and its block destroy out of the chain
-- entirely, and those two packets are the only proof a shell was fired
-- that survives a sprinting player.
function mod.on_load()
	if (shot_listen == nil) then
		error("shotgun_are_grenade_launchers needs lib_shot_detect loaded first "
			.."(config.lua loads it, or: lsdctl load lib_shot_detect "
			.."shotgun_are_grenade_launchers)", 0);
	end

	shot_listen("shotgun_are_grenade_launchers", function(pid, gun)
		if (gun == 2) then
			explode_pellet(pid);
		end
	end);
end

function mod.on_unload()
	if (shot_unlisten ~= nil) then
		shot_unlisten("shotgun_are_grenade_launchers");
	end
end

return mod;
