-- advanced_battle_bot.lua -- Advanced battle bots, a Lua port of
-- tmp-bot-script-advanced.py (TDM + CTF scope) built on lib_bot.
--
-- Keeps abb_count fighters per team. Each bot has a rolled skill
-- (0..1) that drives a human-like aim-error model (see aim.lua), and a
-- brain that:
--   * flees an incoming grenade (with a skill-based chance of missing it)
--   * engages the nearest visible enemy: gosa-aims, fires on cadence,
--     grenades at close range
--   * pursues an enemy that is seen but out of range
--   * otherwise pushes the objective: in ctf/babel it fetches the enemy
--     intel and runs it home; elsewhere it marches on the enemy tent
--
-- The heavy lifting (LOS, spread/recoil shooting, grenade ballistics,
-- avoidance, lifecycle, respawn) is lib_bot's; this is the AI on top.
-- Chat, control-point/kabadi modes and the vsBOT difficulty ladder
-- from the original are not ported.
--
-- DEPENDENCIES: lib_bot loaded first; ctf (or babel) for the intel and
-- tents. Command: /abots -- list the bots, their skill and state.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local mod = init_mod();

local cfg = require "advanced_battle_bot.config";
local aim = require "advanced_battle_bot.aim";
local move = require "advanced_battle_bot.movement";

local WEAPONS = {0, 1, 2}; -- rifle, smg, shotgun

-- non-combatants (hostages) carry this tag; abb bots never shoot or
-- grenade near them, whether or not hostage.lua is loaded
local function is_noncombatant(i)
	local b = bot_get(i);
	return b ~= nil and b.data.hostage == true;
end

local function hostage_near(pos, radius)
	local r2 = radius*radius;
	for i in piditer(PID_BROADCAST) do
		if (is_alive(i) and is_noncombatant(i)) then
			local p = get_position(i);
			if ((p.x-pos.x)^2 + (p.y-pos.y)^2 + (p.z-pos.z)^2 <= r2) then
				return true;
			end
		end
	end
	return false;
end

-- where the objective wants this bot to go, or nil to just roam
local function objective_target(pid)
	local team = get_team(pid);
	local enemy = 3 - team;

	if (abb_ctf) then
		local intel = get_intelloc()[enemy]; -- my team scores the enemy intel
		if (type(intel) == "number") then
			if (intel == pid) then
				return get_tentloc()[team]; -- I carry it: run home
			end
			-- a teammate carries it: push up to the enemy base to cover
		elseif (type(intel) == "table") then
			return intel; -- dropped/at base: go grab it
		end
	end

	return get_tentloc()[enemy]; -- default push: the enemy tent
end

local function brain(pid)
	local b = bot_get(pid);
	local d = b.data;
	local now = get_time();
	local dt = now - (d.last or now);
	d.last = now;
	d.gren_cd = math.max(0, (d.gren_cd or 0) - dt);

	-- 1) survival: run from an incoming grenade (low skill sometimes
	-- fails to notice -- the old gre_ignore)
	local blast = bot_incoming_grenade(pid, {radius=12, ignore_chance=(1-d.skill)*0.35});
	if (blast ~= nil) then
		d.state = "flee";
		local p = get_position(pid);
		move.navigate(pid, d, {x=2*p.x-blast.x, y=2*p.y-blast.y, z=p.z}, now, dt);
		return;
	end

	local enemy, dist = bot_nearest_player(pid, {team=3-get_team(pid),
		visible=true, include_bots=true, reject=is_noncombatant});

	-- 2) engage: in range, stand and fight with the gosa aim
	if (enemy ~= nil and dist <= abb_shoot_range) then
		d.state = "engage";
		local on_target = aim.aim_at(pid, d.aim, d.skill, enemy);
		bot_stop(pid);

		if (on_target and bot_shoot(pid, {spread_mult=0.25, reject=is_noncombatant})) then
			aim.recoil(d.aim, d.skill); -- kick the aim after the shot
		end

		local tpos = get_position(enemy);
		if (dist <= abb_grenade_range and d.gren_cd <= 0
		    and not hostage_near(tpos, abb_grenade_safe_r)) then
			if (bot_lob_grenade(pid, tpos, {accuracy=3, tolerance=6})) then
				d.gren_cd = abb_grenade_cd;
			end
		end
		return;
	end

	-- 3) pursue: seen but far, close the distance
	if (enemy ~= nil) then
		d.state = "pursue";
		move.navigate(pid, d, get_position(enemy), now, dt);
		return;
	end

	-- 4) objective / roam
	d.state = abb_ctf and "objective" or "roam";
	local dest = objective_target(pid);
	if (dest == nil or bot_distance_to(pid, dest) < 3) then
		bot_stop(pid);
		return;
	end
	move.navigate(pid, d, dest, now, dt);
end

local function count_bots(team)
	local n = 0;
	for i in piditer(PID_BROADCAST) do
		local b = bot_get(i);
		if (b ~= nil and b.data.abb and b.team == team) then
			n = n + 1;
		end
	end
	return n;
end

function mod.after.tick()
	for team=1,2 do
		if (count_bots(team) < abb_count) then
			local d = {abb=true, aim={}, skill=cfg.roll_skill()};
			aim.reset(d.aim);
			bot_create{
				team = team,
				name = "ABot-"..get_team_name(team).."-"..count_bots(team),
				gun = WEAPONS[math.random(#WEAPONS)],
				tool = "gun",
				think = brain,
				data = d,
			};
		end
	end
end

local function sweep()
	local doomed = {};
	for i in piditer(PID_BROADCAST) do
		local b = bot_get(i);
		if (b ~= nil and b.data.abb) then
			doomed[#doomed+1] = i;
		end
	end
	for _, i in ipairs(doomed) do
		bot_destroy(i);
	end
end

local cmd = {name="abots", fakepid=true, desc="List advanced battle bots."};
function cmd.func(pid)
	local any = false;
	for i in piditer(PID_BROADCAST) do
		local b = bot_get(i);
		if (b ~= nil and b.data.abb) then
			any = true;
			server_msg(pid, string.format("%s: %d HP, skill %.2f (%s)",
				get_name(i), get_hp(i), b.data.skill, b.data.state or "spawning"));
		end
	end
	if (not any) then server_msg(pid, "No advanced battle bots active."); end
end
register_command(cmd, mod);

function mod.on_load()
	if (bot_create == nil) then
		error("advanced_battle_bot needs lib_bot loaded first", 0);
	end
	sweep();
end

function mod.on_unload()
	sweep();
end

return mod;
