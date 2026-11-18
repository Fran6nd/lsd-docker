-- babel_plus.lua -- Babel as a real game: team-coloured blocks, camper marks
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Rides on babel, with babel_protect (which keeps builders out of the
-- enemy tower area, keeps them from breaking their own, and paints the
-- dashed lines around each area).
--
-- Everyone spawns holding their team's colour, so the first block they
-- place already belongs to the tower. The core resets the colour on
-- every spawn, hence the hook rather than a set on join.
--
-- A player who stands in the enemy's tower area or spawn and hardly
-- moves is outlined for the defending team, through Teamplay: building
-- is the only thing the area is for, and a camper there is either
-- sniping the builders or spawn-killing. The mark carries no accusation,
-- only the place. Clients without Teamplay see nothing and nothing is
-- sent to them (teamplay_mark skips them).
--
-- Positions are looked at about once a second, not every tick: the
-- thresholds are tens of seconds and blocks.
local mod = init_mod();

getcfg("babel_camp_marks", true,
	"Outline an enemy camping in your tower area or spawn, for Teamplay clients.");
getcfg("babel_camp_secs", 20, "Seconds barely moving in the enemy's tower area before being marked.");
getcfg("babel_spawn_secs", 15, "Seconds barely moving in the enemy's spawn before being marked.");
getcfg("babel_camp_move", 2, "Blocks a player must move to count as not camping.");
getcfg("tentspawns_radius", 20);

local camp_msg = {en = "Camping by your tower"};
local spawn_msg = {en = "In your spawn"};

local CHECK_EVERY = 1;  -- seconds

-- pid -> {area, anchor = {x, y}, since, defender, marked, reason}
local watch = {};
local next_check = 0;

local function other(team)
	return team == 1 and 2 or 1;
end

local function in_box(pos, a, b)
	return pos.x >= a.x and pos.x <= b.x and pos.y >= a.y and pos.y <= b.y;
end

-- Where `pos` is, as seen from `defender`: the spawn area (where
-- tentspawns puts them) wins over the tower area, since the two overlap
-- a little and a spawn camper is the worse of the two.
local function area_of(pos, defender)
	local tent = get_tentloc()[defender];
	if (tent ~= nil) then
		local r = tentspawns_radius;
		if (in_box(pos, {x = tent.x - r, y = tent.y - r},
		    {x = tent.x - 1 + r, y = tent.y - 1 + r})) then
			return "spawn";
		end
	end

	-- the zones come from babel_protect, so "your tower" is what it protects
	for _, zone in ipairs((babel_protect_zones or {})[defender] or {}) do
		if (in_box(pos, zone[1], zone[2])) then
			return "tower";
		end
	end
end

local function defenders(team)
	local out = {};
	for i in piditer(PID_BROADCAST) do
		if (get_team(i) == team) then
			out[#out+1] = i;
		end
	end
	return out;
end

local function send_mark(viewer, target, w)
	teamplay_mark(viewer, target, TEAMPLAY_FOREVER,
		{reason = w.reason, clear_on_respawn = true});
end

local function unmark(pid)
	local w = watch[pid];
	if (w ~= nil and w.marked) then
		for _, v in ipairs(defenders(w.defender)) do
			teamplay_clear(v, pid);
		end
	end
	watch[pid] = nil;
end

local function mark(pid, w)
	w.marked = true;
	for _, v in ipairs(defenders(w.defender)) do
		send_mark(v, pid, w);
	end
end

local function check(pid, now)
	local team = get_team(pid);
	if (not is_alive(pid) or (team ~= 1 and team ~= 2)) then
		unmark(pid);
		return;
	end

	local pos = get_position(pid);
	local defender = other(team);
	local area = area_of(pos, defender);
	local w = watch[pid];

	if (area == nil) then
		unmark(pid);
		return;
	end

	-- a different place, a different side, or far enough from where the
	-- clock started: start it over
	if (w == nil or w.area ~= area or w.defender ~= defender
	    or math.sqrt((pos.x - w.anchor.x)^2 + (pos.y - w.anchor.y)^2) >= babel_camp_move) then
		unmark(pid);
		watch[pid] = {
			area = area, defender = defender, since = now,
			anchor = {x = pos.x, y = pos.y}, marked = false,
			reason = area == "spawn" and spawn_msg or camp_msg,
		};
		return;
	end

	local secs = area == "spawn" and babel_spawn_secs or babel_camp_secs;
	if (not w.marked and now - w.since >= secs) then
		mark(pid, w);
	end
end

function mod.after.tick()
	if (not babel_camp_marks or teamplay_mark == nil) then
		return;
	end

	local now = get_time();
	if (now < next_check) then
		return;
	end
	next_check = now + CHECK_EVERY;

	for i in piditer(PID_BROADCAST) do
		check(i, now);
	end
end

function mod.after.spawn_player(pid)
	local team = get_team(pid);
	if (team == 1 or team == 2) then
		set_block_color(pid, get_team_color(team));
	end
end

function mod.after.kill(pid)
	unmark(pid);
end

function mod.after.after_player_destroy(pid)
	unmark(pid);
end

-- Teamplay is negotiated well after joining; a defender who arrives
-- late is told of the campers already marked. A map change drops every
-- mark on the clients, so the standing ones are forgotten with it.
local function on_ready(pid)
	local team = get_team(pid);
	for target, w in pairs(watch) do
		if (w.marked and w.defender == team) then
			send_mark(pid, target, w);
		end
	end
end

function mod.before.finish_map_load()
	watch = {};
	next_check = 0;
end

function mod.on_load()
	if (teamplay_listen_ready ~= nil) then
		teamplay_listen_ready("babel_plus", on_ready);
	end
end

return mod;
