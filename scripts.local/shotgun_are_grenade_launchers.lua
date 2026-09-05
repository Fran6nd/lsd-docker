-- shotgun_are_grenade_launchers.lua -- Shotgun pellets are grenades
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- One random pellet per shell detonates a grenade where it lands.
--
-- WHERE the pellets went is half known and half guessed, and the point
-- of this script is to prefer the known half. Spread is client-side RNG,
-- so the server is never told the eight directions -- but it IS told
-- where pellets landed, whenever one hit something: a Hit packet names
-- the player struck, a BlockAction names the block chewed. Those are
-- real impacts, and they are the ones a player actually aimed.
--
-- So a shell is assembled rather than invented: every impact the client
-- reported is a pellet, and only the shortfall -- the pellets that hit
-- nothing, or hit something too far away to report -- is simulated by
-- jittering the aim and raycasting.
--
-- Then exactly one pellet of the eight detonates. If any of them struck
-- a player, it is one of those: that is the one place the shooter
-- certainly hit, and a grenade that goes off on the wall behind a man
-- you just shot is the shell missing him. Otherwise the draw is over all
-- eight, and a simulated pellet that hit nothing makes the shell a miss.
--
-- That costs a beat: the client's impact packets arrive around the shot,
-- not before it, so a shell waits sgl_gather seconds to see what turns
-- up before it is resolved. Nothing else in the round trip is shorter.
--
-- Knowing that a shell was fired at all is lib_shot_detect's job, not this
-- one's -- it is the same problem the railgun script has, and it is
-- harder than it looks. Load lib_shot_detect before this.
local mod = init_mod();

getcfg("sgl_pellets", 8);     -- pellets per shell
getcfg("sgl_spread", 0.024);  -- 0.75 shotgun spread
getcfg("sgl_range", 128);     -- max pellet travel, in blocks
-- How long a fired shell waits for the client's impact reports before
-- being resolved. They arrive about a round trip after the shot and
-- within a few ms of each other; too short and real impacts are missed
-- and simulated over, too long and the burst visibly lags the trigger.
getcfg("sgl_gather", 0.1);

-- impacts the client has reported since the last shell was resolved, and
-- the shells waiting to be resolved. Both are cleared on spawn: a fresh
-- life owes nothing to the shot before it.
local impacts = pid_spawn_table();
local pending = pid_spawn_table();

-- A pellet landed somewhere the client can prove. What it struck does
-- matter: a pellet that found a man is worth more than one that found a
-- wall, and more again than one this script only guessed at, so the
-- burst is placed on the best of them rather than on any of them (see
-- resolve).
local function record_impact(pid, pos, onplayer)
	local list = impacts[pid];

	if (list == nil) then
		list = {};
		impacts[pid] = list;
	end
	list[#list+1] = {x=pos.x, y=pos.y, z=pos.z, onplayer=onplayer};
end

local function jitter(dir)
	return {
		x = dir.x + sgl_spread*(math.random()*2 - 1),
		y = dir.y + sgl_spread*(math.random()*2 - 1),
		z = dir.z + sgl_spread*(math.random()*2 - 1),
	};
end

-- Where one unreported pellet would have landed: jitter the aim by the
-- shotgun's spread and follow it. Returns nil when it hits nothing at
-- all, which is a pellet that flew off into the sky -- a real outcome,
-- and one that must stay possible or every shell would burst.
-- `from` is where the shooter stood and pointed when the trigger went,
-- captured then and passed in here -- never read live. By the time a
-- shell is resolved the client has applied its recoil and told us about
-- it, so the orientation the server holds is the kicked one, aimed above
-- where the player actually shot. Over sgl_range that is metres.
local function simulate_pellet(pid, from)
	local start = from.pos;
	local dir = jitter(from.dir);

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
		return nil; -- this pellet flew off into the sky
	end

	return at;
end

-- Burst one pellet, wherever it turned out to be.
local function burst(pid, at)
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

-- Pellets don't hurt players: only the grenade does damage. The hit is
-- still worth keeping, though -- it is the client telling us where one
-- pellet of the shell actually landed, which beats any guess we could
-- make about it.
function mod.on_hit(pid, type, hitPlayer)
	if (is_alive(pid) and get_tool(pid) == 2 and get_gun(pid) == 2) then
		record_impact(pid, get_position(hitPlayer), true);
		return;
	end
	mod.next.on_hit(pid, type, hitPlayer);
end

-- Pellets do nothing to blocks: swallow gun-destroys from shotgun
-- holders and rebuild the block on the client that chewed it locally.
-- Same as above, the destroy is kept first: it is a pellet's real
-- landing point, named by the only party that knows it.
function mod.on_block_action(pid, pos, type)
	if (type == 1 and is_alive(pid) and get_tool(pid) == 2 and get_gun(pid) == 2) then
		record_impact(pid, {x=pos.x+0.5, y=pos.y+0.5, z=pos.z+0.5});
		send_set_block_color(pid, get_map_block_color(pos), get_anon_pid());
		send_block_action(pid, pos, 0, get_anon_pid());
		return;
	end
	mod.next.on_block_action(pid, pos, type);
end

-- The shell, once its impacts have had time to arrive. Every reported
-- impact is a pellet; the shortfall is simulated. One of the eight is
-- then drawn and burst -- and it may be a simulated pellet that hit
-- nothing, in which case the shell is a clean miss and nothing happens.
local function resolve(pid, from)
	local shots = {};
	local onmen = {};
	local n = 0;

	for _,at in ipairs(impacts[pid] or {}) do
		if (n >= sgl_pellets) then
			break;
		end
		n = n + 1;
		shots[n] = at;
		if (at.onplayer) then
			onmen[#onmen+1] = at;
		end
	end

	-- only the missing ones
	while (n < sgl_pellets) do
		n = n + 1;
		shots[n] = simulate_pellet(pid, from); -- nil if it hit nothing
	end

	impacts[pid] = nil;

	-- One burst per shell, and where it goes is a matter of what is
	-- known rather than of luck. If any pellet of this shell struck a
	-- player, the client has told us the one place on the map that the
	-- shooter certainly hit, and the grenade belongs there -- landing it
	-- on a wall behind them instead, because the draw came up on some
	-- other pellet, is the shell missing a man it visibly hit.
	--
	-- With nobody struck there is nothing to prefer and the old draw
	-- stands: one of the eight, real impact or simulated, and a
	-- simulated pellet that hit nothing means the shell is a clean miss.
	local at;

	if (#onmen > 0) then
		at = onmen[math.random(#onmen)];
	else
		at = shots[math.random(sgl_pellets)];
	end

	if (at ~= nil) then
		burst(pid, at);
	end
end

function mod.after.tick()
	local now = get_time();

	for pid in piditer(PID_BROADCAST) do
		local shell = pending[pid];

		if (shell ~= nil and now - shell.at >= sgl_gather) then
			pending[pid] = nil;
			if (is_alive(pid)) then
				resolve(pid, shell);
			else
				impacts[pid] = nil;
			end
		end
	end
end

-- Advertise ourselves, rather than leaving it to whoever writes the
-- config. The script that changes a weapon is the thing that knows what
-- changed, so an instance gets the line by loading the script, and the
-- claim cannot drift from the code making it. tip_spam reads `tips` live
-- every tick, so appending is the whole of it; `tips` is nil on an
-- instance not running tip_spam, hence the guard. Taken out again on
-- unload, and taken out before being put in, so a reload leaves one.
local TIP = "Spicy: every shotgun blast drops a grenade pellet -- mind the splash.";

local function untip()
	if (tips == nil) then
		return;
	end
	for i = #tips, 1, -1 do
		if (tips[i] == TIP) then
			table.remove(tips, i);
		end
	end
end

-- One shell, one live pellet, whoever worked out that a shell was fired.
--
-- The swallowing hooks above are why lib_shot_detect watches from the xearly
-- chain: they take a pellet's hit and its block destroy out of the chain
-- entirely, and those two packets are the only proof a shell was fired
-- that survives a sprinting player.
function mod.on_load()
	untip();
	if (tips ~= nil) then
		tips[#tips+1] = TIP;
	end

	if (shot_listen == nil) then
		error("shotgun_are_grenade_launchers needs lib_shot_detect loaded first "
			.."(config.lua loads it, or: lsdctl load lib_shot_detect "
			.."shotgun_are_grenade_launchers)", 0);
	end

	-- a shell is not resolved here: it is queued, so that the client's
	-- impact reports have a moment to arrive before we decide what the
	-- pellets did (see sgl_gather)
	shot_listen("shotgun_are_grenade_launchers", function(pid, gun)
		if (gun == 2) then
			-- the aim is taken NOW, not when the shell is resolved: the
			-- recoil kick is on its way and would otherwise be what the
			-- pellets are traced along
			pending[pid] = {
				at = get_time(),
				pos = get_position(pid),
				dir = get_orientation(pid),
			};
		end
	end);
end

function mod.on_unload()
	untip();

	if (shot_unlisten ~= nil) then
		shot_unlisten("shotgun_are_grenade_launchers");
	end
end

return mod;
