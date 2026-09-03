-- esp_demo.lua -- Aim at an enemy and your whole team sees them
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- A demonstration of lib_teamplay's ESP marks, and of nothing else.
-- Put your crosshair on an enemy and that enemy is outlined for your
-- entire team for esp_demo_seconds. Keep aiming and it stays; look away
-- and it fades on its own.
--
-- Walls count. You have to actually see somebody to paint them: the
-- crosshair has to be on them AND the line to them has to be clear. What
-- the mark then buys is the interesting half -- once painted, your team
-- keeps seeing them through cover for esp_demo_seconds, so the reveal
-- outlives the sighting. Spotting, not sonar; sweeping a crosshair
-- across a wall reveals nobody.
--
-- lib_teamplay is the only module this needs, and the guard is the usual
-- one: without it loaded this does nothing at all, and if a client
-- hasn't negotiated the extension teamplay_mark refuses on its behalf.
-- Everything else here is core API, so an instance can load the pair on
-- its own and have a working demo.
local mod = init_mod();

-- How long a mark lasts once painted. Fractions are fine: a duration is
-- a float on the wire, so 0.75 is as sayable as 3.
getcfg("esp_demo_seconds", 3);
getcfg("esp_demo_range", 128);    -- how far the aim ray reaches, in blocks
getcfg("esp_demo_radius", 1.0);   -- how near the ray must pass to count
-- How often to look at where everyone is pointing. The scan is the
-- cheap part; this is really the packet dial, since a target still
-- under the crosshair is re-marked every pass to restart its timer.
-- Keep it comfortably below esp_demo_seconds or marks will flicker.
getcfg("esp_demo_interval", 1);

-- demoncore clips a body from 1.35 above pos to 2.25 below, so sample
-- that span rather than treating a player as a point at their middle --
-- the same nine samples rifle_is_a_rail_gun.lua uses to decide a hit
local BODY_TOP = -1.35;
local BODY_STEP = 0.45;
local BODY_SAMPLES = 8;

local scan_at = 0;

-- Clear line from `eye` to `to`? raycast walks the voxels between them
-- and hands back the last empty one before whatever it hit, so a hit
-- nearer than the destination is a wall in the way and a hit at the
-- destination is the destination itself.
--
-- lib_bot's bot_can_see does the same eight lines, and this file
-- deliberately does not call it: the whole point of the demo is that it
-- needs lib_teamplay and nothing else. One raycast is not worth an
-- instance having to load the bot library to outline a player.
local function can_see(eye, to)
	local hit = raycast(eye, to, false);
	if (hit == nil) then
		return true;
	end

	local hd2 = (hit.x-eye.x)^2 + (hit.y-eye.y)^2 + (hit.z-eye.z)^2;
	local td2 = (to.x-eye.x)^2 + (to.y-eye.y)^2 + (to.z-eye.z)^2;
	return hd2 >= td2 - 1.0;
end

-- Is `looker` actually spotting `target` -- crosshair on them, and the
-- line to them clear? Both questions are asked of the same nine body
-- samples, in the order that costs least: the distance from a sample to
-- the aim ray is arithmetic on one vector, so it rejects the many, and
-- only a sample that survives it is worth a raycast through the map.
--
-- Per sample rather than per player, because a head over a wall is a
-- sighting. Testing the middle alone would miss it, and the samples run
-- top-down, so that head is the first thing asked about anyway.
local function is_spotted(looker, target)
	local eye = get_position(looker);
	local dir = get_orientation(looker);
	local p = get_position(target);
	local r2 = esp_demo_radius * esp_demo_radius;

	for k = 0, BODY_SAMPLES do
		local sz = p.z + BODY_TOP + k*BODY_STEP;
		local wx = p.x - eye.x;
		local wy = p.y - eye.y;
		local wz = sz - eye.z;
		local t = wx*dir.x + wy*dir.y + wz*dir.z;

		if (t > 0 and t < esp_demo_range) then
			local ox = wx - t*dir.x;
			local oy = wy - t*dir.y;
			local oz = wz - t*dir.z;

			if (ox*ox + oy*oy + oz*oz <= r2
			    and can_see(eye, {x=p.x, y=p.y, z=sz})) then
				return true;
			end
		end
	end

	return false;
end

-- Show `target` to everyone on `team`. Safe to call over a whole team,
-- bots included: teamplay_mark answers false for anybody who never
-- negotiated the extension, and a bot -- having no client behind it to
-- negotiate with, or to draw anything -- never has.
local function reveal(team, target)
	for i in piditer(PID_BROADCAST_TEAM(team)) do
		teamplay_mark(i, target, esp_demo_seconds, {
			-- who it is, rather than merely that somebody is there:
			-- spotting for your own team is worth the name. The client
			-- draws it out of its own player table, so it costs a flag
			-- bit and nothing on the wire -- and being a name rather
			-- than free text, it is the one the reader already sees on
			-- the scoreboard
			show_name = true,
			-- a mark outlives its target otherwise: without this it
			-- survives death and respawn, and three seconds of it would
			-- land on a player who has already got away and come back
			-- somewhere else
			clear_on_respawn = true,
		});
	end
end

function mod.after.tick()
	-- nothing to demonstrate without the extension module
	if (teamplay_mark == nil) then
		return;
	end

	local now = get_time();
	if (now - scan_at < esp_demo_interval) then
		return;
	end
	scan_at = now;

	for looker in piditer(PID_BROADCAST) do
		if (is_alive(looker)) then
			local team = get_team(looker);

			-- SPECTATOR is 256 and has no enemies; PID_BROADCAST_TEAM
			-- on it would be meaningless
			if (team == 1 or team == 2) then
				for target in piditer(PID_BROADCAST_EXCEPT_TEAM(team)) do
					if (is_alive(target)
					    and is_spotted(looker, target)) then
						reveal(team, target);
					end
				end
			end
		end
	end
end

return mod;
