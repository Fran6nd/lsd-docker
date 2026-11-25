-- parkour.lua -- One team against the clock, on a course over the sea
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- ctf underneath, for the tent a client draws and the bots know as their
-- base. Both intels are parked in a corner and nobody can pick one up.
--
-- THE GAME: everybody is on team 1 -- nobody to shoot, the server's own
-- rule being that a team does not hurt itself. A run is from the start
-- platform to the tent at the end of the course. The clock starts when a
-- runner leaves the start platform and stops at the tent; the time is
-- told, the runner's best is kept, and the runner is put back at the
-- start. /best lists the best times. There is no score, no winner and no
-- end: the game goes on as long as the server does.
--
-- THE COURSE is the map's: its metadata names the start, the tent and
-- the checkpoints (parkour_start, parkour_tent, parkour_checkpoints:
-- catalog/core/parkour_map.lua writes them, lsdctl generates the map
-- with the mode). On a map without them there is no course, and the
-- mode is one team and nothing else; the log says so.
--
-- FALLING is dying: the map's water kills (its own water_damage, which
-- upstream's water_damage.lua applies and lib_botlink tells the bots, so
-- their routes never enter it). Whoever dies, of anything, is back at
-- once at the last checkpoint reached, and the clock runs on. Going back
-- to the start platform starts the clock again.
--
-- NOBODY BUILDS OR DIGS: a bridge over a gap is not a run, and a hole in
-- the course is everybody's problem.
--
-- THE BEST TIMES are kept by name for as long as the server runs --
-- through every map restart, not through a restart of the server (the
-- catalog has no store to keep them in). They are a course's: another
-- course (lsdctl map course) starts them over.
--
-- THE BOTS need nothing from here: their tree (bot/trees/parkour.bt) is
-- "go to our base", and the base is the tent.
local mod = init_mod();

local START_HALF = 4.5;   -- the start platform, from its middle (parkour_map's PLAZA)
local SPREAD = 2;         -- how far from a platform's middle a runner is put
local LISTED = 5;         -- lines of /best

local welcome_msg = {
	en = "Parkour: run to the tent at the end of the course, as fast as you can. The water kills. /best lists the best times.",
};
local finish_msg = {en = "Finished in %(time) s. Your best is %(best) s."};
local finish_best_msg = {en = "Finished in %(time) s: your best time!"};
local record_msg = {en = "%(name) holds the record: %(time) s"};
local checkpoint_msg = {en = "Checkpoint %(n) of %(total)"};
local no_build_msg = {en = "No building or digging on the course."};
local one_team_msg = {en = "Everybody runs on the same team here."};
local best_line_msg = {en = "%(rank). %(name): %(time) s"};
local best_own_msg = {en = "Your best: %(time) s"};
local best_none_msg = {en = "Nobody has finished the course yet."};

-- pid -> {since = <when the clock started, or nil>, at = <checkpoints reached>}
local run = {};
-- name -> seconds
local best = {};
local record = nil;
local ran = nil;   -- the course they were run on
local faults = 0;

local function course()
	return get_map_meta ~= nil and get_map_meta().parkour or nil;
end

local function is_bot(pid)
	return bot_is_bot ~= nil and bot_is_bot(pid);
end

local function tell(pid, msg, args)
	if (not is_bot(pid)) then
		l10n_send_chat(pid, msg, args);
	end
end

local function secs(t)
	return string.format("%.2f", t);
end

--============================== THE MAP =============================--

local function point(str)
	local x, y, z = string.match(str or "", "%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)");
	if (x ~= nil) then
		return {x = x + 0.5, y = y + 0.5, z = tonumber(z)};
	end
end

function mod.after.pyscrape_ext(scrape, str, meta)
	local start = point(scrape.get_ext(str, "parkour_start"));
	local tent = point(scrape.get_ext(str, "parkour_tent"));
	if (start == nil or tent == nil) then
		return;
	end
	local checkpoints = {};
	for p in string.gmatch(scrape.get_ext(str, "parkour_checkpoints") or "", "%([%d%s,]+%)") do
		checkpoints[#checkpoints + 1] = point(p);
	end
	meta.parkour = {start = start, tent = tent, checkpoints = checkpoints};
end

-- the tent at the end; everything else of ctf's in a corner, on the ground
local function place(loaded)
	drop_move_intel(1, objgrav{x = 0.5, y = 0.5, z = 0});
	drop_move_intel(2, objgrav{x = 511.5, y = 511.5, z = 0});
	local c = course();
	if (c == nil) then
		if (loaded) then log("parkour: this map names no course (parkour_start, parkour_tent): one team, and nothing to run. `lsdctl gamemode parkour` generates one."); end
		return;
	end
	move_tent(1, objgrav{x = c.tent.x, y = c.tent.y, z = 0});
	move_tent(2, objgrav{x = 0.5, y = 511.5, z = 0});
end

-- not chaining is the veto: ctf's tick asks for every player who walks
-- over an intel, and nobody gets it
function mod.pickup_intel(pid)
end

local function on_platform(pos, p, half)
	return math.abs(pos.x - p.x) <= half and math.abs(pos.y - p.y) <= half
		and pos.z < p.z and pos.z > p.z - 6;
end

--============================= SPAWNING =============================--

function mod.get_spawn_position(pid)
	local c = course();
	if (c == nil or get_next_team(pid) == SPECTATOR) then
		return mod.next.get_spawn_position(pid);
	end
	local r = run[pid];
	local p = r ~= nil and c.checkpoints[r.at] or c.start;
	return {
		x = p.x + math.random(-SPREAD, SPREAD),
		y = p.y + math.random(-SPREAD, SPREAD),
		z = p.z - 2.251,
	};
end

function mod.after.spawn_player(pid)
	if (run[pid] == nil) then
		run[pid] = {at = 0};
		tell(pid, welcome_msg);
	end
end

-- dead, of anything: back at once, where get_spawn_position says
function mod.after.kill(pid)
	if (course() ~= nil and is_connected(pid) and is_joined(pid) and not is_alive(pid)
	    and get_next_team(pid) ~= SPECTATOR) then
		spawn_player(pid, get_spawn_position(pid));
	end
end

function mod.after.on_disconnect(pid)
	run[pid] = nil;
end

--============================== ONE TEAM ============================--

function mod.on_join(pid, team, gun, name)
	if (team ~= SPECTATOR) then
		team = 1;
	end
	return mod.next.on_join(pid, team, gun, name);
end

function mod.on_switch(pid, team, gun)
	if (team ~= SPECTATOR and team ~= 1) then
		l10n_send_chat(pid, one_team_msg);
		team = 1;
		if (get_team(pid) == 1 and gun == get_gun(pid)) then
			return;
		end
	end
	return mod.next.on_switch(pid, team, gun);
end

--=========================== NO BUILDING ============================--

function mod.on_block_action(pid, pos, type)
	l10n_send_chat(pid, no_build_msg);
end

function mod.on_block_line(pid, start, stop)
	l10n_send_chat(pid, no_build_msg);
end

-- The course is nobody's to edit: not by a player's grenade, not by an
-- effect's blast, not by a script -- the one question every edit answers
-- to (lib_block_filter) is no. The server's own is never asked.
function mod.may_edit_block(who, pos, type)
	return false;
end

--=============================== RUNS ===============================--

local function finish(pid, r, c, now)
	local time = now - r.since;
	local name = get_name(pid);
	local old = best[name];
	log("parkour: %s finished in %s s", name, secs(time));

	if (old == nil or time < old) then
		best[name] = time;
		tell(pid, finish_best_msg, {time = secs(time)});
	else
		tell(pid, finish_msg, {time = secs(time), best = secs(old)});
	end
	if (record == nil or time < record) then
		record = time;
		l10n_send_chat(PID_BROADCAST, record_msg, {name = name, time = secs(time)});
	end

	r.at, r.since = 0, nil;
	spawn_player(pid, get_spawn_position(pid));
end

local function look(pid, c, now)
	if (not is_alive(pid) or get_team(pid) ~= 1) then
		return;
	end
	local r = run[pid];
	if (r == nil) then
		r = {at = 0};
		run[pid] = r;
	end
	local pos = get_position(pid);

	-- on the start platform the clock is not running
	if (on_platform(pos, c.start, START_HALF)) then
		r.since, r.at = nil, 0;
		return;
	end
	if (r.since == nil) then
		r.since = now;
	end

	if (tent_in_range(get_position(pid), get_tentloc()[1])) then
		finish(pid, r, c, now);
		return;
	end
	for k = #c.checkpoints, r.at + 1, -1 do
		if (on_platform(pos, c.checkpoints[k], START_HALF)) then
			r.at = k;
			tell(pid, checkpoint_msg, {n = k, total = #c.checkpoints});
			break;
		end
	end
end

-- a fault with one runner must not end the tick for every script after
-- this one
function mod.after.tick()
	local c = course();
	if (c == nil) then
		return;
	end
	local now = get_time();
	for pid in piditer(PID_BROADCAST) do
		local ok, err = pcall(look, pid, c, now);
		if (not ok) then
			faults = faults + 1;
			if (faults <= 3) then log("parkour: %s", tostring(err)); end
		end
	end
end

--=============================== /best ==============================--

local cmd = {name = "best", fakepid = true, desc = "List the best times on the parkour course."};
function cmd.func(pid)
	local names = {};
	for name in pairs(best) do names[#names + 1] = name; end
	table.sort(names, function(a, b)
		if (best[a] ~= best[b]) then return best[a] < best[b]; end
		return a < b;
	end);
	if (#names == 0) then
		l10n_send_chat(pid, best_none_msg);
		return;
	end
	for rank = 1, math.min(LISTED, #names) do
		l10n_send_chat(pid, best_line_msg, {rank = rank, name = names[rank], time = secs(best[names[rank]])});
	end
	local own = not is_fakepid(pid) and best[get_name(pid)] or nil;
	if (own ~= nil) then
		l10n_send_chat(pid, best_own_msg, {time = secs(own)});
	end
end
register_command(cmd, mod);

--============================= LIFECYCLE ============================--

-- a new map: everybody starts over; the best times stay while the
-- course is the same one
function mod.after.finish_map_load()
	run = {};
	place(true);
	local c = course();
	local sig = c ~= nil and string.format("%d %d %d %d %d", c.start.x, c.start.y, c.tent.x, c.tent.y, c.tent.z) or nil;
	if (sig ~= nil and ran ~= nil and sig ~= ran) then
		best, record = {}, nil;
	end
	ran = sig or ran;
end

function mod.on_load()
	masterlist_set_gamemode("parkour");
	-- one team is as unbalanced as teams get: team_balance, where it is
	-- installed, would send every third runner to the other side
	team_balance_max_diff = math.huge;
	-- and one map: vote_map, in random mode, would fetch another from the web
	map_web_random = false;
	place();
end

return mod;
