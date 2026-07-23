-- advanced_battle_bot/aim.lua -- the "gosa" (aim-error) model, ported
-- from new_gosa/late_gosa/tebure_gosa/moving_target_gosa. A bot never
-- aims perfectly: its aim carries a skill-scaled error that converges
-- toward the target but never fully settles (the "terminator fix"),
-- a gaussian hand tremor, a recoil kick on every shot, and a
-- skill-scaled lead on moving targets. Higher skill (0..1) = smaller
-- errors, tighter settle, less tremor.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local M = {};

local sin, cos, atan2, sqrt, pi = math.sin, math.cos, math.atan2, math.sqrt, math.pi;

local function gauss(sigma)
	local u1 = math.random(); if (u1 < 1e-12) then u1 = 1e-12; end
	return sigma * sqrt(-2*math.log(u1)) * cos(2*pi*math.random());
end

local function clamp(v, lo, hi)
	if (v < lo) then return lo; end
	if (v > hi) then return hi; end
	return v;
end

-- rotate a unit direction by yaw/pitch offsets (radians)
local function offset_dir(dir, dyaw, dpitch)
	local hlen = sqrt(dir.x*dir.x + dir.y*dir.y);
	local e = atan2(-dir.z, hlen) + dpitch;
	local a = atan2(dir.y, dir.x) + dyaw;
	local ch = cos(e);
	return {x=ch*cos(a), y=ch*sin(a), z=-sin(e)};
end

-- fresh aim-error state for a bot
function M.reset(a)
	a.ex = 0; a.ey = 0;       -- accumulated aim error, yaw/pitch radians
	a.tx = 0; a.ty = 0;       -- hand tremor
end

-- new_gosa: a shot kicks the aim (mostly upward), harder for low skill
function M.recoil(a, skill)
	local R = (1 - skill) * 0.08 * (0.6 + math.random());
	local th = math.random() * 2 * pi;
	a.ey = a.ey - math.abs(R * sin(th));  -- climb
	a.ex = a.ex + R * cos(th) * 0.5;      -- and drift sideways
end

-- Aim at `target` (a pid) this tick: set the bot's orientation to the
-- true direction perturbed by the running error, and return whether
-- the aim is tight enough to justify firing. `skill` is 0..1.
function M.aim_at(pid, a, skill, target)
	local me = get_position(pid);
	local tp = get_position(target);

	-- moving_target_gosa: lead the target's velocity, accurately for
	-- high skill, sloppily (and laggily) for low
	local v = get_velocity(target);
	local lead = 3.0 * skill + gauss((1 - skill) * 1.5);
	local aimx = tp.x + v.x * lead;
	local aimy = tp.y + v.y * lead;
	local aimz = tp.z + v.z * lead;
	local dx, dy, dz = aimx-me.x, aimy-me.y, aimz-me.z;
	local len = sqrt(dx*dx + dy*dy + dz*dz);
	if (len < 1e-6) then return true; end
	local dir = {x=dx/len, y=dy/len, z=dz/len};

	-- late_gosa: the error converges toward zero, faster for high skill
	local decay = 0.12 + skill * 0.55;
	a.ex = a.ex * (1 - decay);
	a.ey = a.ey * (1 - decay);
	-- terminator fix: a low-skill bot keeps a permanent jitter floor,
	-- so it still misses now and then like a person
	local floor = (1 - skill) * 0.012;
	a.ex = a.ex + (math.random()*2 - 1) * floor;
	a.ey = a.ey + (math.random()*2 - 1) * floor;

	-- tebure_gosa: gaussian hand tremor, bounded by skill
	local tlim = (1 - skill) * 0.05;
	a.tx = clamp(a.tx + gauss((1 - skill) * 0.006) - a.tx*0.02, -tlim, tlim);
	a.ty = clamp(a.ty + gauss((1 - skill) * 0.004) - a.ty*0.02, -tlim, tlim);

	on_orientation(pid, offset_dir(dir, a.ex + a.tx, a.ey + a.ty));

	local err = sqrt((a.ex+a.tx)^2 + (a.ey+a.ty)^2);
	return err < 0.015 + skill * 0.03;
end

return M;
