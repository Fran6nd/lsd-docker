-- airstrike.lua -- Call in bombs on a point
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- The caller aims, and everybody is warned: a Teamplay ping on the spot
-- for the clients that show one, and a line in chat for the rest. A few
-- seconds later bombs fall out of the sky in a line across the target,
-- along the way the caller faces, a few blocks apart, one after the
-- other so the strike rolls. Each is a streak of fiery blocks coming
-- straight down (lib_blast, the rocket's own code) and explodes where it
-- meets ground or a living enemy of the caller's. It can be dodged, and
-- it can be turned on its caller: the shooter feels a third of it.
--
--   PlayerEffect.get("airstrike"):trigger(pid)                  -- where they aim
--   PlayerEffect.get("airstrike"):trigger(pid, {pos = {x=, y=, z=}})
--        -> the point, or nil when there was nowhere to aim at
--
-- "Where they aim" is a ray from the eye to the first block it meets, up
-- to AIM_RANGE blocks; the sky is not a target. Through the pie menu a
-- wedge may hand the point itself (%h, the point under the crosshair).
local strike; -- below

local fx = PlayerEffect {
	name = "airstrike",
	warning = {en = "warning: here airstrikes can be called in on you."},
	tip = {en = "An airstrike comes three seconds after the warning: run."},
	trigger = function(pid, opts)
		return strike(pid, opts);
	end,
};
local mod = fx.mod;

getcfg("airstrike_bombs", 5, "Bombs in a strike.");
getcfg("airstrike_delay", 3, "Seconds from the warning to the first bomb.");
getcfg("airstrike_radius", 4, "Blocks of terrain destroyed around each bomb; damage reaches twice as far.");
getcfg("airstrike_damage", 100, "Damage at the centre of each bomb, falling off with distance.");
getcfg("airstrike_spacing", 4, "Blocks between two bombs of a line.");
getcfg("airstrike_stagger", 0.2, "Seconds between one bomb and the next.");
getcfg("airstrike_speed", 1.5, "Blocks a bomb falls each tick.");
getcfg("airstrike_kill_radius", 5, "Blocks from a bomb's impact within which it kills outright.");
getcfg("airstrike_warn_radius", 40, "Players this close to the target get the warning across their screen.");

local AIM_RANGE = 400;
local MAP = 511;

-- {at = when, owner, x, y, dir}: bombs not yet dropped
local pending = {};

local warn_msg = {en = "%(name) called in an airstrike! Get out of there!"};
local no_target_msg = {en = "Aim at something to call an airstrike on it."};
local ping_msg = {en = "Airstrike!"};
local big_msg = {en = "AIRSTRIKE INCOMING -- TAKE COVER!"};

-- The first block along the aim, as a point; nil for the open sky.
local function aimed(pid)
	return blast_aim(pid, AIM_RANGE);
end

-- Everybody near the target -- whichever side -- gets it across the
-- middle of their screen (Message Types; plain system chat for a client
-- without it): a chat line scrolls by unread in a firefight.
local function warn_near(pos)
	local r2 = airstrike_warn_radius * airstrike_warn_radius;
	-- the people only: a bot has no screen to warn (lib_bot's people_in)
	for i in (people_in or piditer)(PID_BROADCAST) do
		local p = is_alive(i) and get_position(i);
		if (p) then
			local dx, dy = p.x - pos.x, p.y - pos.y;
			if (dx*dx + dy*dy <= r2) then
				if (msg_big ~= nil) then
					msg_big(i, big_msg);
				else
					l10n_send_chat(i, big_msg);
				end
			end
		end
	end
end

function strike(pid, opts)
	-- a player under the crosshair first (%h only lands on blocks): the
	-- bombs come down where they stand
	local a = aimed(pid);
	local pos = (a ~= nil and a.pid ~= nil) and a or opts.pos or a;
	if (pos == nil) then
		l10n_send_chat(pid, no_target_msg);
		return nil;
	end

	-- along the caller's facing, level: a line across the target
	local d = get_orientation(pid);
	local len = math.sqrt(d.x * d.x + d.y * d.y);
	local dir = len > 0.01 and {x = d.x / len, y = d.y / len, z = 0}
		or {x = 1, y = 0, z = 0};

	local delay = tonumber(opts.delay) or airstrike_delay;
	local n = tonumber(opts.bombs) or airstrike_bombs;
	local now = get_time();

	for i = 1, n do
		local off = (i - (n + 1) / 2) * airstrike_spacing;
		pending[#pending+1] = {
			at = now + delay + (i - 1) * airstrike_stagger,
			owner = pid,
			x = pos.x + dir.x * off, y = pos.y + dir.y * off,
			radius = tonumber(opts.radius), damage = tonumber(opts.damage),
		};
	end

	-- the warning: a ping where it will land, for whoever's client draws
	-- one, and the chat for everybody
	if (teamplay_ping_all ~= nil) then
		teamplay_ping_all(pos, {reason = ping_msg, secs = delay + 1,
			color = {b = 0, g = 0, r = 255}});
	end
	l10n_send_chat(PID_BROADCAST, warn_msg, {name = get_name(pid)});
	warn_near(pos);
	return pos;
end

local DOWN = {x = 0, y = 0, z = 1};

function mod.after.tick()
	if (#pending == 0) then
		return;
	end
	local now = get_time();
	local left = {};
	for _, b in ipairs(pending) do
		if (now < b.at) then
			left[#left+1] = b;
		elseif (b.x >= 0 and b.x <= MAP and b.y >= 0 and b.y <= MAP) then
			-- out of the sky: z 0 is the top of the map
			blast_fire(b.owner, {x = b.x, y = b.y, z = 0.5}, DOWN, {
				speed = airstrike_speed, range = 70, skip = 0, trail = 10,
				radius = b.radius or airstrike_radius,
				damage = b.damage or airstrike_damage,
				kill_radius = airstrike_kill_radius,
				hostile = function(a, t) return fx:hostile(a, t); end,
			});
		end
	end
	pending = left;
end

function mod.after.load_map()
	pending = {};
end

return mod;
