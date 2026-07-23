-- bot_standard.lua -- Combat guard bots on lib_bot, a Lua port of
-- piqueserver's example_bot.py. Keeps guard_count fighters alive per
-- team; each one:
--   ROAM    -- no enemy in sight: march on the enemy tent
--   PURSUE  -- enemy seen but out of shoot range: sprint to close in
--   ENGAGE  -- enemy in range: stand, aim, fire, grenade up close
-- It shouts for help in team chat when hurt, and jumps/crouches/digs
-- its way out of being stuck. The aiming, spread/recoil shooting and
-- grenade ballistics are all lib_bot's; this is just the AI.
--
-- Command: /guards -- list each guard's HP and state.
--
-- DEPENDENCIES: lib_bot loaded first (config.lua does this), and a
-- tent gamemode (ctf) for the roam target. It never load()s its deps.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
require "lib_bulk_destroy"; -- global bdestroy_* for the dig-out stage

local mod = init_mod();

getcfg("guard_count", 5);         -- fighters per team
getcfg("guard_shoot_range", 24);  -- start shooting within this many blocks
getcfg("guard_grenade_range", 12);-- lob a grenade within this many blocks
getcfg("guard_grenade_cd", 5);    -- seconds between a guard's grenades
getcfg("guard_grenade_safe_r", 16);-- skip the grenade if a hostage is this close to the target
getcfg("guard_lowhp", 30);        -- shout for help below this HP

local STUCK_CHECK = 0.5;  -- seconds between progress checks
local STUCK_MOVE = 0.8;   -- blocks of horizontal progress that count as moving
local JUMP_GRACE = 1.0;   -- seconds to let a jump work before escalating
local CROUCH_DUR = 0.4;   -- seconds to hold crouch

local WEAPONS = {0, 1, 2}; -- rifle, smg, shotgun

-- hostages are non-combatants: identify them by the data tag their
-- script sets, so guards leave them alone whether or not hostage.lua
-- is loaded (no module dependency needed)
local function is_hostage(i)
	local b = bot_get(i);
	return b ~= nil and b.data.hostage == true;
end

-- any living hostage within `radius` of a point? grenade blast is
-- server-side and hits every enemy in range, so guards must not throw
-- one near a hostage -- the enemy tent (where a hostage waits) is
-- exactly where guards fight
local function hostage_near(pos, radius)
	local r2 = radius*radius;
	for i in piditer(PID_BROADCAST) do
		if (is_alive(i) and is_hostage(i)) then
			local p = get_position(i);
			if ((p.x-pos.x)^2 + (p.y-pos.y)^2 + (p.z-pos.z)^2 <= r2) then
				return true;
			end
		end
	end
	return false;
end

-- destroy the block ahead at the bot's level and the ones above/below
local function dig_forward(pid, p, iz)
	local o = get_orientation(pid);
	local h = math.sqrt(o.x*o.x + o.y*o.y);
	if (h < 0.001) then
		return;
	end
	local fx, fy = math.floor(p.x + o.x/h), math.floor(p.y + o.y/h);
	for _, fz in ipairs({iz, iz+1, iz-1}) do
		if (fz >= 0 and fz < 64) then
			bdestroy_block_action({x=fx, y=fy, z=fz}, 1);
		end
	end
	bdestroy_finish();
end

-- Every STUCK_CHECK seconds, if the bot made less than STUCK_MOVE
-- blocks of horizontal progress it is stuck, and escalates: jump (with
-- a 2-block lift for tall walls or to climb out of water), then crouch,
-- then dig. Returns (jump, crouch) for the caller's bot_walk.
local function try_unstick(pid, dt, d)
	d.jump_grace = math.max(0, (d.jump_grace or 0) - dt);
	d.crouch_rem = math.max(0, (d.crouch_rem or 0) - dt);

	d.stuck_timer = (d.stuck_timer or 0) + dt;
	if (d.stuck_timer < STUCK_CHECK) then
		return false, d.crouch_rem > 0;
	end
	d.stuck_timer = 0;

	local p = get_position(pid);
	local o = d.pos_check or p;
	local moved = math.sqrt((p.x-o.x)^2 + (p.y-o.y)^2);
	d.pos_check = p;

	if (moved >= STUCK_MOVE) then
		d.jump_tried = false; d.jump_grace = 0;
		d.crouch_rem = 0; d.crouch_tried = false;
		return false, false;
	end

	-- stuck; let an in-flight jump or crouch play out before escalating
	if (d.jump_grace > 0) then return false, false; end
	if (d.crouch_rem > 0) then return false, true; end

	-- z is down: iz-1 is head height, iz+2/iz+3 catch the floor below
	local ix, iy, iz = math.floor(p.x), math.floor(p.y), math.floor(p.z);
	local above_clear = not is_solid({x=ix, y=iy, z=iz-1});
	local on_ground = is_solid({x=ix, y=iy, z=iz+2}) or is_solid({x=ix, y=iy, z=iz+3});

	if (d.crouch_tried) then
		d.crouch_tried = false; d.jump_tried = false;
		dig_forward(pid, p, iz);
		return false, true; -- stay crouched while digging
	end

	if (above_clear and not d.jump_tried) then
		d.jump_tried = true; d.jump_grace = JUMP_GRACE;
		local o2 = get_orientation(pid);
		local hl = math.sqrt(o2.x*o2.x + o2.y*o2.y);
		if (not on_ground) then
			set_position(pid, {x=p.x, y=p.y, z=p.z-2}); -- swim up
		elseif (hl > 0.001) then
			local fx = math.floor(p.x + o2.x/hl);
			local fy = math.floor(p.y + o2.y/hl);
			if (is_solid({x=fx, y=fy, z=iz-1}) or is_solid({x=fx, y=fy, z=iz+1})) then
				set_position(pid, {x=p.x, y=p.y, z=p.z-2}); -- 2-block wall
			end
		end
		return true, false;
	end

	if (not on_ground) then
		d.jump_tried = false; -- airborne/swimming: crouch would sink it
		return false, false;
	end

	d.jump_tried = false;
	d.crouch_tried = true;
	d.crouch_rem = CROUCH_DUR;
	return false, true;
end

local function guard_think(pid)
	local d = bot_get(pid).data;
	local now = get_time();
	local dt = now - (d.last or now);
	d.last = now;
	if (dt <= 0) then dt = 1/60; end

	d.gren_cd = math.max(0, (d.gren_cd or 0) - dt);

	-- shout once when hurt, rearm the shout when patched up
	local hp = get_hp(pid);
	if (hp < guard_lowhp and not d.warned) then
		d.warned = true;
		on_chat(pid, get_name(pid).." is taking heavy fire!", 1);
	elseif (hp >= guard_lowhp) then
		d.warned = false;
	end

	local enemy, dist = bot_nearest_player(pid,
		{team=3-get_team(pid), visible=true, include_bots=true, reject=is_hostage});

	if (enemy == nil) then
		d.state = "roam";
		local tent = get_tentloc()[3 - get_team(pid)];
		if (tent == nil or bot_distance_to(pid, tent) < 3) then
			bot_stop(pid);
			return;
		end
		bot_look_horizontal(pid, tent);
		local jump, crouch = try_unstick(pid, dt, d);
		bot_walk(pid, {forward=true, sprint=true, jump=jump, crouch=crouch});
		return;
	end

	if (dist > guard_shoot_range) then
		d.state = "pursue";
		bot_look_horizontal(pid, enemy);
		local jump, crouch = try_unstick(pid, dt, d);
		bot_walk(pid, {forward=true, sprint=true, jump=jump, crouch=crouch});
		return;
	end

	d.state = "engage";
	local tpos = get_position(enemy);
	local on_target = bot_aim_at(pid, tpos, 0.25, 0.03);
	bot_stop(pid);

	-- fire before the grenade so the shot uses the enemy-aim, not the
	-- orientation bot_lob_grenade leaves pointing along the throw
	if (on_target) then
		bot_shoot(pid, {reject=is_hostage}); -- bullets pass through hostages
	end
	if (dist <= guard_grenade_range and d.gren_cd <= 0
	    and not hostage_near(tpos, guard_grenade_safe_r)) then
		if (bot_lob_grenade(pid, tpos, {accuracy=3, tolerance=6})) then
			d.gren_cd = guard_grenade_cd;
		end
	end
end

local function count_guards(team)
	local n = 0;
	for i in piditer(PID_BROADCAST) do
		local b = bot_get(i);
		if (b ~= nil and b.data.guard and b.team == team) then
			n = n + 1;
		end
	end
	return n;
end

-- top up to guard_count per team; a dead guard still counts (lib_bot
-- respawns it), so this never over-spawns
function mod.after.tick()
	for team=1,2 do
		local n = count_guards(team);
		if (n < guard_count) then
			bot_create{
				team = team,
				name = "Guard-"..get_team_name(team).."-"..n,
				gun = WEAPONS[math.random(#WEAPONS)],
				tool = "gun",
				think = guard_think,
				data = {guard=true},
			};
		end
	end
end

local function sweep_guards()
	-- collect first, then destroy: bot_destroy disconnects the slot,
	-- and mutating the player set mid-piditer would skip some
	local doomed = {};
	for i in piditer(PID_BROADCAST) do
		local b = bot_get(i);
		if (b ~= nil and b.data.guard) then
			doomed[#doomed+1] = i;
		end
	end
	for _, i in ipairs(doomed) do
		bot_destroy(i);
	end
end

local cmd = {name="guards", fakepid=true, desc="List guard bots, their HP and state."};
function cmd.func(pid)
	local any = false;
	for i in piditer(PID_BROADCAST) do
		local b = bot_get(i);
		if (b ~= nil and b.data.guard) then
			any = true;
			server_msg(pid, get_name(i)..": "..get_hp(i).." HP ("
				..(b.data.state or "spawning")..")");
		end
	end
	if (not any) then
		server_msg(pid, "No guard bots active.");
	end
end
register_command(cmd, mod);

function mod.on_load()
	if (bot_create == nil) then
		error("bot_standard needs lib_bot loaded first "
			.."(config.lua loads it, or: lsdctl load lib_bot bot_standard)", 0);
	end
	sweep_guards(); -- clear guards from a previous life; tick respawns them
end

function mod.on_unload()
	sweep_guards();
end

return mod;
