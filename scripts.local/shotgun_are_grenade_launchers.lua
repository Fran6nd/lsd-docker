-- shotgun_are_grenade_launchers.lua -- One random shotgun pellet per
-- shot detonates a grenade where it lands.
--
-- The client never reports where pellets hit the world (spread is
-- client-side RNG; the server only sees player hits and block
-- destroys), so the chosen pellet is simulated here: jitter the aim
-- direction by the shotgun's spread, raycast it, boom.
local mod = init_mod();

getcfg("sgl_pellets", 8);     -- pellets per shell
getcfg("sgl_spread", 0.024);  -- 0.75 shotgun spread
getcfg("sgl_range", 128);     -- max pellet travel, in blocks

-- the engine's magazine size for the shotgun (initialMagAmmo[2]); a
-- reload tops the mag off one shell at a time up to this
local SHELLS = 6;

-- when a real pellet of theirs last provably existed (block break or
-- player hit): the engine's mag estimate drains on *estimated* shots
-- and the estimator is sprint- and release-blind, so it can phantom
-- its way to an empty magazine while the real one is half full --
-- fresh evidence overrules it
local lastreal = pid_connected_table(0);

-- our own shell count, kept from real evidence instead of the engine's
-- blind timing estimate. one trigger-pull sprays a burst of pellets
-- that all land at once, and the fire rate caps real shells ~1s apart,
-- so a pellet landing more than half a second after the last counted
-- one marks a genuinely new shell. this drives reload sizing, so a
-- reload seats exactly the shells that were spent -- no more, no less
local mymag = pid_connected_table(SHELLS);
local lastshell = pid_connected_table(0);

local function count_shell(pid)
	if (get_time() - lastshell[pid] > 0.5) then
		mymag[pid] = math.max(mymag[pid] - 1, 0);
		lastshell[pid] = get_time();
	end
end

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
		lastreal[pid] = get_time();
		count_shell(pid);
		return;
	end
	mod.next.on_hit(pid, type, hitPlayer);
end

-- pellets do nothing to blocks: swallow gun-destroys from shotgun
-- holders and rebuild the block on the client that chewed it locally
function mod.on_block_action(pid, pos, type)
	if (type == 1 and is_alive(pid) and get_tool(pid) == 2 and get_gun(pid) == 2) then
		lastreal[pid] = get_time();
		count_shell(pid);
		send_set_block_color(pid, get_map_block_color(pos), get_anon_pid());
		send_block_action(pid, pos, 0, get_anon_pid());
		return;
	end
	mod.next.on_block_action(pid, pos, type);
end

-- The engine sizes a reload as (full mag - its ammo estimate) shells,
-- but that estimate is blind to shots fired while moving, so it drifts
-- from the client's real magazine and seats the wrong number of shells
-- -- too few (reload stalls mid-animation) or, if we forced it empty,
-- too many (a full reload after a single shot). Seat from our own
-- evidence-based count instead, so the shell-by-shell reload matches
-- exactly what was spent. The reload then tops the mag back to full.
function mod.after.on_reload(pid)
	if (is_alive(pid) and get_gun(pid) == 2) then
		set_ammo(pid, mymag[pid], get_reserve_ammo(pid));
		mymag[pid] = SHELLS;
	end
end

-- a fresh spawn comes with a full mag
function mod.after.spawn_player(pid)
	mymag[pid] = SHELLS;
end

-- the server estimates gun cycling from the held inputs (rifle 0.5s,
-- smg 0.1s, shotgun 1s) and calls this per estimated shot, so holding
-- the trigger keeps launching -- clients send nothing while held
function mod.after.before_estimated_fire(pid)
	if (not is_alive(pid) or get_gun(pid) ~= 2) then
		return;
	end
	-- the estimator is release-blind, so it keeps "firing" straight
	-- through a reload -- but a real trigger-press cancels the reload
	-- first, so any shot estimated while one is pending is a phantom.
	-- don't burst a grenade for it. (leave the mag alone: reload_player
	-- owns the count now, seeded from our evidence-based mymag, and any
	-- set_ammo here would race its send_reload packets and jump the
	-- client's shell-by-shell animation straight to full.)
	if (get_reload_time(pid) ~= 0) then
		return;
	end
	if (get_mag_ammo(pid) == 0 and get_time() - lastreal[pid] > 2) then
		return; -- estimated empty and no recent proof to the contrary
	end

	explode_pellet(pid);
end

return mod;
