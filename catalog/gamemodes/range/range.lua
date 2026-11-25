-- range.lua -- A shooting range: every target down, as fast as you can
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- ctf underneath, for the one team the protocol can show and a tent to
-- restock at; both intels are parked in corners and nobody picks one up.
--
-- THE GAME: every person is on team 1 -- nobody to shoot but the
-- targets, the server's own rule being that a team does not hurt
-- itself. Two ways to play, side by side:
--
--   THE STATIC RANGE. A person who steps into a lane's firing position
--   (a bay behind the line) has the lane: the clock starts COUNTDOWN
--   seconds later, and stops when every target of that lane has been hit
--   -- the static ones, the one on the rail and the one that blinks.
--   Every lane has the same targets at the same distances, so a time on
--   one is a time on any: one board. Leaving the bay before the end
--   voids the run (no walking up to the targets); stepping out and back
--   in is another run. One person a lane; several lanes at once.
--
--   THE IPSC COURSE, one shooter at a time. /ipsc joins the queue, as
--   does stepping onto the orange waiting area; the first in it is put
--   in the green start box when the course is free. The clock starts
--   when the shooter leaves the start box and stops in the blue end box
--   once every target of the course is hit (in the end box with targets
--   standing, the shooter is told how many and the clock runs on). Dead,
--   gone, out of the course or over IPSC_LIMIT seconds: the run is
--   abandoned and the next in the queue goes. Anybody else found inside
--   is sent to the waiting area, and so joins the queue.
--
-- A hit is a bullet that strikes a target (a body shot or a head shot;
-- not a spade or a grenade), counted once a run, and only for the run
-- the target belongs to. Times are told, each person's best is kept and
-- a record announced. /best lists them. Health and ammunition are made
-- full at the start of every run and after it. There is no score, no
-- winner and no end.
--
-- THE TARGETS are lib_bot bots on team 2 that never die and never move
-- of themselves: no think, no keys but the crouch of a crouched one, and
-- no part in the bot engine (nothing here asks lib_botlink for
-- anything). A target is data from the map (range_targets: its set, its
-- stance, its motion, the point it faces and its points; see
-- catalog/core/range_map.lua) and ONE CONTROLLER keeps all of them:
-- creates what is missing (a seat at a time, again a second later if
-- the server is full -- lib_bot gives a person a target's seat), puts
-- each where its motion says at this moment, and nothing else. Motions:
-- static (its one point), rail (back and forth between two points at a
-- steady pace) and blink (each point in turn, `param` seconds at each).
-- Where a target is is a function of the time alone, so every client
-- sees the same thing and a test can ask it.
--
-- IMMORTAL BY THE DAMAGE HOOK: a damage_player on a target is taken
-- here and goes no further -- its health never moves, it never dies or
-- falls. What a hit did is told to the one who landed it through
-- lib_damage_markers' own API (damage_markers_show), with the number the
-- hit was worth, as for a man: the floating number a Damage Markers
-- client draws. (The extension's automatic marker reads a hit that
-- applied nothing as no hit, which is right for every other veto, so
-- the mode says it itself.)
--
-- Targets are hidden from the score, the roster and the kill feed where
-- the client speaks Silent Player (lib_bot's silent options), spawn on
-- their own points and take no person's spawn.
--
-- NOBODY BUILDS OR DIGS, and grenades make no craters: the range is the
-- map's.
--
-- THE BEST TIMES are kept by name while the server runs -- through every
-- map restart, not a restart of the server -- and start over on another
-- range (lsdctl map course).
local mod = init_mod();

local COUNTDOWN = 3;      -- from stepping into a bay to the clock
local IPSC_LIMIT = 120;   -- seconds a shooter may hold the course
local SETTLE = 1;         -- after a teleport: the client's old position may still arrive
local SPREAD = 2;         -- how far from the spawn's middle a person is put
local LISTED = 5;         -- lines of /best, a board
local TOPUP_SECS = 1;     -- how often missing targets are made again

-- hidden everywhere a Silent Player client hides anything
local SILENT = {roster = true, presence = true, killfeed = true, stats = true};

local welcome_msg = {
	en = "Shooting range: step into a lane's firing position and hit every target of the lane as fast as you can; /ipsc queues you for the IPSC course, one shooter at a time. /best lists the best times.",
};
local lane_ready_msg = {en = "Lane %(lane): %(total) targets. The clock starts in %(secs) s."};
local go_msg = {en = "Go!"};
local lane_taken_msg = {en = "Lane %(lane) is in use."};
local hit_msg = {en = "Hit: %(n)/%(total)"};
local void_line_msg = {en = "Run void: you left the firing position."};
local void_died_msg = {en = "Run void: you died."};
local lane_best_msg = {en = "Every target down in %(time) s: your best on the static range!"};
local lane_done_msg = {en = "Every target down in %(time) s. Your best on the static range is %(best) s."};
local ipsc_best_msg = {en = "IPSC course in %(time) s: your best!"};
local ipsc_done_msg = {en = "IPSC course in %(time) s. Your best is %(best) s."};
local record_static_msg = {en = "%(name) holds the static range record: %(time) s"};
local record_ipsc_msg = {en = "%(name) holds the IPSC record: %(time) s"};
local queued_msg = {en = "You are number %(n) in the IPSC queue."};
local unqueued_msg = {en = "You left the IPSC queue."};
local on_course_msg = {en = "You are on the IPSC course."};
local busy_msg = {en = "The IPSC course is in use: you are number %(n) in the queue."};
local turn_msg = {
	en = "Your turn on the IPSC course: the clock starts when you leave the green start box and stops in the blue end box once every target is hit. %(limit) s at most.",
};
local all_down_msg = {en = "Every target hit: to the blue end box!"};
local standing_msg = {en = "Targets still standing: %(n)"};
local left_course_msg = {en = "IPSC run abandoned: you left the course."};
local too_long_msg = {en = "IPSC run abandoned: over %(limit) s."};
local died_course_msg = {en = "IPSC run abandoned: you died."};
local no_course_msg = {en = "This map has no IPSC course."};
local no_build_msg = {en = "No building or digging on the range."};
local one_team_msg = {en = "Everybody is on the same team here."};
local best_static_msg = {en = "Static range:"};
local best_ipsc_msg = {en = "IPSC course:"};
local best_line_msg = {en = "%(rank). %(name): %(time) s"};
local best_own_static_msg = {en = "Your best on the static range: %(time) s"};
local best_own_ipsc_msg = {en = "Your best on the IPSC course: %(time) s"};
local best_none_msg = {en = "No times yet."};

-- pid -> the run in hand:
--   {kind = "lane"|"ipsc", set =, lane =, total =, n =, hits = {k = true},
--    go = <the clock's start, for a lane>, since = <when the clock started>,
--    done = <a lane's, finished: held until the bay is left>,
--    deadline =, settle =, at_end =}
local runs = {};
local held = {};     -- target index -> the bot's pid
local queue = {};    -- pids, the first goes next
local shooter = nil; -- who is on the IPSC course
local on_pad = {};   -- pid -> standing on the waiting area at the last look
local told_taken = {};
local best = {static = {}, ipsc = {}};   -- board -> name -> seconds
local record = {};                       -- board -> seconds
local ran = nil;     -- the range the times were made on
local next_topup = 0;
local faults = 0;

local function range()
	return get_map_meta ~= nil and get_map_meta().range or nil;
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
	local x, y, z = string.match(str or "", "^%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)$");
	if (x ~= nil) then
		return {x = tonumber(x), y = tonumber(y), z = tonumber(z)};
	end
end

local function box(str)
	local x0, y0, x1, y1, z = string.match(str or "",
		"^%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)$");
	if (x0 ~= nil) then
		return {x0 = tonumber(x0), y0 = tonumber(y0), x1 = tonumber(x1), y1 = tonumber(y1), z = tonumber(z)};
	end
end

local STANCES = {stand = true, crouch = true};
local MOTIONS = {static = 1, rail = 2, blink = 1};   -- the points each needs at least

-- ('lane1', 'stand', 'rail', 2.5, (face), (p1), (p2)); nil if not one
local function target(str)
	local set, stance, motion, param, rest = string.match(str,
		"^%(%s*'([%w_]+)'%s*,%s*'(%a+)'%s*,%s*'(%a+)'%s*,%s*([%d%.]+)%s*,(.*)%)$");
	if (set == nil or not STANCES[stance] or MOTIONS[motion] == nil) then
		return nil;
	end
	local pts = {};
	for p in string.gmatch(rest, "%b()") do pts[#pts + 1] = point(p); end
	local face = table.remove(pts, 1);
	param = tonumber(param);
	if (face == nil or #pts < MOTIONS[motion] or (motion ~= "static" and not (param > 0))) then
		return nil;
	end
	return {set = set, stance = stance, motion = motion, param = param, face = face, points = pts};
end

local function tuples(scrape, str, name)
	local out = {};
	local s = scrape.get_ext(str, name);
	if (s ~= nil and string.match(s, "^%(.*%)$")) then
		for t in scrape.split_tupletuple(s) do out[#out + 1] = t; end
	end
	return out;
end

function mod.after.pyscrape_ext(scrape, str, meta)
	local spawn = point(scrape.get_ext(str, "range_spawn"));
	if (spawn == nil) then
		return;
	end
	local r = {seed = tonumber(scrape.get_ext(str, "range_seed")), spawn = spawn,
		lanes = {}, targets = {}, count = {}};
	for _, s in ipairs(tuples(scrape, str, "range_lanes")) do r.lanes[#r.lanes + 1] = box(s); end
	local area, start = box(scrape.get_ext(str, "range_ipsc")), box(scrape.get_ext(str, "range_ipsc_start"));
	local finish, wait = box(scrape.get_ext(str, "range_ipsc_end")), box(scrape.get_ext(str, "range_ipsc_wait"));
	if (area and start and finish and wait) then
		r.ipsc = {area = area, start = start, finish = finish, wait = wait};
	end
	for _, s in ipairs(tuples(scrape, str, "range_targets")) do
		local t = target(s);
		local lane = t and tonumber(string.match(t.set, "^lane(%d+)$"));
		-- a target of a set the map has: one of its lanes, or its course
		if (t ~= nil and ((lane ~= nil and r.lanes[lane] ~= nil) or (t.set == "ipsc" and r.ipsc ~= nil))) then
			r.targets[#r.targets + 1] = t;
			r.count[t.set] = (r.count[t.set] or 0) + 1;
		end
	end
	meta.range = r;
end

-- in a box of the map: over its columns, the feet on its floor
local function in_box(b, pos)
	return pos.x >= b.x0 and pos.x < b.x1 + 1 and pos.y >= b.y0 and pos.y < b.y1 + 1
		and pos.z < b.z and pos.z > b.z - 4;
end

-- the area of the course has no floor to speak of: any height in it
local function over(b, pos)
	return pos.x >= b.x0 and pos.x < b.x1 + 1 and pos.y >= b.y0 and pos.y < b.y1 + 1;
end

-- a standing body on the floor of a box's middle, or of a point
local function stand_on(p)
	return {x = p.x + 0.5, y = p.y + 0.5, z = p.z - 2.251};
end

local function middle(b)
	return stand_on({x = math.floor((b.x0 + b.x1) / 2), y = math.floor((b.y0 + b.y1) / 2), z = b.z});
end

--============================= THE TARGETS ==========================--

-- Where a target is at time `now`: the column (fractional on a rail)
-- and the z of the voxel under its feet.
local function range_target_at(t, now)
	if (t.motion == "rail") then
		local a, b = t.points[1], t.points[2];
		local dx, dy = b.x - a.x, b.y - a.y;
		local len = math.sqrt(dx * dx + dy * dy);
		if (len == 0) then
			return a;
		end
		local period = 2 * len / t.param;
		local f = (now % period) / period * 2;
		if (f > 1) then f = 2 - f; end
		return {x = a.x + dx * f, y = a.y + dy * f, z = a.z};
	elseif (t.motion == "blink") then
		return t.points[1 + math.floor(now / t.param) % #t.points];
	end
	return t.points[1];
end

-- the body there: its eye, standing or crouched, the feet a hair over
-- the floor as a spawn puts them (feet on the floor's very top are in
-- it, and the body is pushed a block up)
local function body(t, p)
	return {x = p.x + 0.5, y = p.y + 0.5, z = p.z - (t.stance == "crouch" and 1.351 or 2.251)};
end

local function target_index(pid)
	local b = bot_get ~= nil and bot_get(pid) or nil;
	return b ~= nil and b.data.range_target or nil;
end

local function face(pid, t)
	local f = t.face;
	local p = get_position(pid);
	bot_look_at(pid, {x = f.x + 0.5, y = f.y + 0.5, z = p.z});
end

local function name_of(r, t, k)
	local lane = tonumber(string.match(t.set, "^lane(%d+)$"));
	if (lane == nil) then
		-- its number on the course
		local n = 0;
		for i = 1, k do
			if (r.targets[i].set == t.set) then n = n + 1; end
		end
		return "IPSC " .. n;
	end
	if (t.motion ~= "static") then
		return "L" .. lane .. " " .. t.motion;
	end
	return string.format("L%d %dm", lane, r.lanes[lane].y0 - t.points[1].y);
end

-- the seat each target is in, made again if it is not
local function top_up(r, now)
	if (now < next_topup) then
		return;
	end
	next_topup = now + TOPUP_SECS;
	for k, t in ipairs(r.targets) do
		if (held[k] == nil) then
			local pid = bot_create{
				team = 2,
				name = name_of(r, t, k),
				tool = "spade",
				spawn_at = function(p)
					local i = target_index(p);
					local rr = range();
					local tt = rr ~= nil and i ~= nil and rr.targets[i] or nil;
					return tt ~= nil and stand_on(range_target_at(tt, get_time())) or nil;
				end,
				silent = SILENT,
				data = {range_target = k},
			};
			if (pid == nil) then
				return;   -- no seat, or the map is loading: in a second
			end
			held[k] = pid;
		end
	end
end

local function keep_targets(r, now)
	top_up(r, now);
	for k, pid in pairs(held) do
		local t = r.targets[k];
		if (t ~= nil and is_joined(pid)) then
			if (not is_alive(pid)) then
				-- at once, not after a respawn wait
				spawn_player(pid, stand_on(range_target_at(t, now)));
			elseif (t.motion == "rail") then
				-- a step along the track every tick: the steady pace
				bot_teleport(pid, body(t, range_target_at(t, now)));
			elseif (t.motion == "blink") then
				-- from one point to the next, and facing the line again
				local p = range_target_at(t, now);
				local b = bot_get(pid);
				if (b.data.at ~= p) then
					bot_teleport(pid, body(t, p));
					face(pid, t);
					b.data.at = p;
				end
			end
		end
	end
end

function mod.after.spawn_player(pid)
	local k = target_index(pid);
	local r = range();
	if (k == nil or r == nil or r.targets[k] == nil) then
		return;
	end
	local t = r.targets[k];
	bot_get(pid).data.at = nil;
	if (t.stance == "crouch") then bot_crouch(pid); else bot_stop(pid); end
	face(pid, t);
end

local function drop_targets(from)
	for k, pid in pairs(held) do
		if (k >= from) then
			held[k] = nil;
			bot_destroy(pid);
		end
	end
end

--============================== HITS ================================--

local finish;

local function count(pid, k)
	local r = runs[pid];
	local c = range();
	local t = c ~= nil and c.targets[k] or nil;
	if (r == nil or t == nil or r.since == nil or r.done or t.set ~= r.set or r.hits[k]) then
		return;
	end
	r.hits[k] = true;
	r.n = r.n + 1;
	tell(pid, hit_msg, {n = r.n, total = r.total});
	if (r.n == r.total) then
		if (r.kind == "lane") then
			finish(pid, r, get_time());
		else
			tell(pid, all_down_msg);
		end
	end
end

-- A target's damage stops here. The one who hit it is shown what the
-- hit was worth, and a bullet counts toward his run.
local function struck(pid, hp, type, damager)
	local k = target_index(pid);
	if (k == nil) then
		return false;
	end
	if (hp > 0 and damager ~= nil and damager ~= pid and damager >= 0 and damager < MAX_PLAYERS
	    and not is_bot(damager)) then
		if (damage_markers_show ~= nil) then
			damage_markers_show(damager, pid, hp);
		end
		if (type == 0 or type == 1) then   -- KillTypeWeapon, KillTypeHeadshot
			count(damager, k);
		end
	end
	return true;
end

function mod.damage_player(pid, hp, type, damager)
	if (struck(pid, hp, type, damager)) then
		return;
	end
	return mod.next.damage_player(pid, hp, type, damager);
end

function mod.damage_player_directional(pid, hp, pos, type, damager)
	if (struck(pid, hp, type, damager)) then
		return;
	end
	return mod.next.damage_player_directional(pid, hp, pos, type, damager);
end

--=============================== RUNS ===============================--

local function refill(pid)
	restock(pid);
	set_hp(pid, 100);
end

local function send_out(pid)
	if (is_alive(pid)) then
		set_position(pid, get_spawn_position(pid));
	end
end

function finish(pid, r, now)
	local time = now - r.since;
	local name = get_name(pid);
	local board = r.kind == "lane" and "static" or "ipsc";
	local old = best[board][name];
	log("range: %s, %s in %s s", name, board, secs(time));

	if (old == nil or time < old) then
		best[board][name] = time;
		tell(pid, board == "static" and lane_best_msg or ipsc_best_msg, {time = secs(time)});
	else
		tell(pid, board == "static" and lane_done_msg or ipsc_done_msg, {time = secs(time), best = secs(old)});
	end
	if (record[board] == nil or time < record[board]) then
		record[board] = time;
		l10n_send_chat(PID_BROADCAST, board == "static" and record_static_msg or record_ipsc_msg,
			{name = name, time = secs(time)});
	end

	refill(pid);
	if (r.kind == "lane") then
		r.done = true;
	else
		runs[pid], shooter = nil, nil;
		send_out(pid);
	end
end

local function queued_at(pid)
	for n, q in ipairs(queue) do
		if (q == pid) then return n; end
	end
end

local function unqueue(pid)
	local n = queued_at(pid);
	if (n ~= nil) then table.remove(queue, n); end
end

-- in the queue (if not already), and told where
local function enqueue(pid, msg)
	if (pid == shooter) then
		return;
	end
	local n = queued_at(pid);
	if (n == nil) then
		queue[#queue + 1] = pid;
		n = #queue;
	end
	-- the first with the course free goes in at once, and is told that
	if (shooter ~= nil or n > 1) then
		tell(pid, msg or queued_msg, {n = n});
	end
end

local function abandon(pid, msg, args)
	tell(pid, msg, args);
	runs[pid] = nil;
	if (shooter == pid) then
		shooter = nil;
	end
end

-- the first in the queue who can go, onto the course
local function let_in(r, now)
	while (shooter == nil and #queue > 0) do
		local pid = queue[1];
		if (not is_connected(pid) or get_team(pid) ~= 1) then
			table.remove(queue, 1);
		elseif (not is_alive(pid)) then
			return;   -- keeps the place; the course waits a moment
		else
			table.remove(queue, 1);
			shooter = pid;
			runs[pid] = {kind = "ipsc", set = "ipsc", total = r.count.ipsc or 0, n = 0, hits = {},
				deadline = now + IPSC_LIMIT, settle = now + SETTLE};
			set_position(pid, middle(r.ipsc.start));
			refill(pid);
			tell(pid, turn_msg, {limit = IPSC_LIMIT});
		end
	end
end

local function lane_at(r, pos)
	for k, b in ipairs(r.lanes) do
		if (in_box(b, pos)) then return k; end
	end
end

local function lane_holder(k)
	for pid, run in pairs(runs) do
		if (run.kind == "lane" and run.lane == k) then return pid; end
	end
end

local function look_lane(pid, r, pos, now)
	local run = runs[pid];
	local k = lane_at(r, pos);
	if (run ~= nil and run.kind == "lane") then
		if (k ~= run.lane) then
			if (not run.done) then tell(pid, void_line_msg); end
			runs[pid] = nil;
			run = nil;
		elseif (run.since == nil and now >= run.go) then
			run.since = run.go;
			tell(pid, go_msg);
		end
	end
	if (k == nil) then
		told_taken[pid] = nil;
	elseif (run == nil) then
		if (lane_holder(k) == nil) then
			local set = "lane" .. k;
			runs[pid] = {kind = "lane", set = set, lane = k, total = r.count[set] or 0, n = 0, hits = {},
				go = now + COUNTDOWN};
			told_taken[pid] = nil;
			refill(pid);
			tell(pid, lane_ready_msg, {lane = k, total = r.count[set] or 0, secs = COUNTDOWN});
		elseif (told_taken[pid] ~= k) then
			told_taken[pid] = k;
			tell(pid, lane_taken_msg, {lane = k});
		end
	end
end

local function look_ipsc(pid, r, pos, now)
	local I = r.ipsc;
	local run = runs[pid];
	if (pid == shooter) then
		if (now < run.settle) then
			return;
		elseif (not over(I.area, pos)) then
			abandon(pid, left_course_msg);
		elseif (now > run.deadline) then
			abandon(pid, too_long_msg, {limit = IPSC_LIMIT});
			send_out(pid);
		elseif (run.since == nil) then
			if (not in_box(I.start, pos)) then run.since = now; end
		elseif (in_box(I.finish, pos)) then
			if (run.n >= run.total) then
				finish(pid, run, now);
			elseif (not run.at_end) then
				run.at_end = true;
				tell(pid, standing_msg, {n = run.total - run.n});
			end
		else
			run.at_end = false;
		end
		return;
	end
	if (over(I.area, pos)) then
		-- not the shooter's: out, to the waiting area, and in the queue
		set_position(pid, middle(I.wait));
		on_pad[pid] = true;
		enqueue(pid, busy_msg);
		return;
	end
	local pad = in_box(I.wait, pos);
	if (pad and not on_pad[pid] and queued_at(pid) == nil) then
		enqueue(pid);
	end
	on_pad[pid] = pad or nil;
end

local function look(pid, r, now)
	if (is_bot(pid) or not is_alive(pid) or get_team(pid) ~= 1) then
		return;
	end
	local pos = get_position(pid);
	if (r.ipsc ~= nil) then
		look_ipsc(pid, r, pos, now);
	end
	if (pid ~= shooter) then
		look_lane(pid, r, pos, now);
	end
end

-- a fault with one player must not end the tick for every script after
-- this one
function mod.after.tick()
	local r = range();
	if (r == nil) then
		return;
	end
	local now = get_time();
	local ok, err = pcall(keep_targets, r, now);
	if (ok and r.ipsc ~= nil) then
		ok, err = pcall(let_in, r, now);
	end
	for pid in piditer(PID_BROADCAST) do
		if (not ok) then break; end
		ok, err = pcall(look, pid, r, now);
	end
	if (not ok) then
		faults = faults + 1;
		if (faults <= 3) then log("range: %s", tostring(err)); end
	end
end

--============================= SPAWNING =============================--

function mod.get_spawn_position(pid)
	local r = range();
	if (r == nil or is_bot(pid) or get_next_team(pid) == SPECTATOR) then
		return mod.next.get_spawn_position(pid);
	end
	return {
		x = r.spawn.x + 0.5 + math.random(-SPREAD, SPREAD),
		y = r.spawn.y + 0.5 + math.random(-SPREAD, SPREAD),
		z = r.spawn.z - 2.251,
	};
end

function mod.after.on_join(pid)
	if (not is_bot(pid)) then
		tell(pid, welcome_msg);
	end
end

-- dead, of anything: the run is over, and back at once (a target too,
-- should anything kill one)
function mod.after.kill(pid)
	if (range() == nil or not is_connected(pid) or not is_joined(pid) or is_alive(pid)) then
		return;
	end
	local run = runs[pid];
	if (run ~= nil) then
		if (run.kind == "ipsc") then
			abandon(pid, died_course_msg);
		else
			runs[pid] = nil;
			if (not run.done) then tell(pid, void_died_msg); end
		end
	end
	if (get_next_team(pid) ~= SPECTATOR) then
		spawn_player(pid, get_spawn_position(pid));
	end
end

function mod.after.on_disconnect(pid)
	runs[pid], on_pad[pid], told_taken[pid] = nil, nil, nil;
	unqueue(pid);
	if (shooter == pid) then
		shooter = nil;
	end
	for k, p in pairs(held) do
		if (p == pid) then held[k] = nil; end
	end
end

--============================== ONE TEAM ============================--

function mod.on_join(pid, team, gun, name)
	if (team ~= SPECTATOR and not is_bot(pid)) then
		team = 1;
	end
	return mod.next.on_join(pid, team, gun, name);
end

function mod.on_switch(pid, team, gun)
	if (team ~= SPECTATOR and team ~= 1 and not is_bot(pid)) then
		l10n_send_chat(pid, one_team_msg);
		team = 1;
		if (get_team(pid) == 1 and gun == get_gun(pid)) then
			return;
		end
	end
	return mod.next.on_switch(pid, team, gun);
end

-- not chaining is the veto: nobody gets an intel
function mod.pickup_intel(pid)
end

--=========================== NO BUILDING ============================--

function mod.on_block_action(pid, pos, type)
	l10n_send_chat(pid, no_build_msg);
end

function mod.on_block_line(pid, start, stop)
	l10n_send_chat(pid, no_build_msg);
end

-- a grenade's crater is the server's own block_action, by its thrower
function mod.block_action(pos, type, from)
	if (type == 3 and from ~= nil and from >= 0 and from < MAX_PLAYERS and is_joined(from)) then
		return;
	end
	return mod.next.block_action(pos, type, from);
end

--============================= COMMANDS =============================--

local ipsc_cmd = {name = "ipsc", desc = "Join the IPSC course's queue, or leave it."};
function ipsc_cmd.func(pid)
	local r = range();
	if (r == nil or r.ipsc == nil) then
		l10n_send_chat(pid, no_course_msg);
	elseif (pid == shooter) then
		l10n_send_chat(pid, on_course_msg);
	elseif (queued_at(pid) ~= nil) then
		unqueue(pid);
		l10n_send_chat(pid, unqueued_msg);
	else
		enqueue(pid);
	end
end
register_command(ipsc_cmd, mod);

local function board_lines(pid, board, header)
	local names = {};
	for name in pairs(best[board]) do names[#names + 1] = name; end
	table.sort(names, function(a, b)
		if (best[board][a] ~= best[board][b]) then return best[board][a] < best[board][b]; end
		return a < b;
	end);
	l10n_send_chat(pid, header);
	if (#names == 0) then
		l10n_send_chat(pid, best_none_msg);
	end
	for rank = 1, math.min(LISTED, #names) do
		l10n_send_chat(pid, best_line_msg, {rank = rank, name = names[rank], time = secs(best[board][names[rank]])});
	end
end

local best_cmd = {name = "best", fakepid = true, desc = "List the best times on the range and the IPSC course."};
function best_cmd.func(pid)
	board_lines(pid, "static", best_static_msg);
	board_lines(pid, "ipsc", best_ipsc_msg);
	if (not is_fakepid(pid)) then
		local name = get_name(pid);
		if (best.static[name] ~= nil) then l10n_send_chat(pid, best_own_static_msg, {time = secs(best.static[name])}); end
		if (best.ipsc[name] ~= nil) then l10n_send_chat(pid, best_own_ipsc_msg, {time = secs(best.ipsc[name])}); end
	end
end
register_command(best_cmd, mod);

--============================= LIFECYCLE ============================--

-- the tent to restock at on the plaza; everything else of ctf's in a
-- corner, on the ground
local function place(loaded)
	drop_move_intel(1, objgrav{x = 0.5, y = 0.5, z = 0});
	drop_move_intel(2, objgrav{x = 511.5, y = 511.5, z = 0});
	move_tent(2, objgrav{x = 0.5, y = 511.5, z = 0});
	local r = range();
	if (r == nil) then
		if (loaded) then log("range: this map names no range (range_spawn): one team, and nothing to shoot. `lsdctl gamemode range` generates one."); end
		return;
	end
	move_tent(1, objgrav{x = r.spawn.x + 0.5, y = r.spawn.y + 0.5, z = 0});
end

local function signature(r)
	if (r == nil) then return nil; end
	local t = r.targets[1];
	return string.format("%s %d %d %d %s", tostring(r.seed), r.spawn.x, r.spawn.y, #r.targets,
		t ~= nil and string.format("%d %d", t.points[1].x, t.points[1].y) or "-");
end

-- a new map: every run starts over and the queue empties; the targets
-- stay in their seats (lib_bot brings them back from the map change)
-- and go to their new places; the best times stay while the range is
-- the same one
function mod.after.finish_map_load()
	runs, queue, shooter, on_pad, told_taken = {}, {}, nil, {}, {};
	next_topup = 0;
	local r = range();
	drop_targets(r ~= nil and #r.targets + 1 or 1);
	place(true);
	local sig = signature(r);
	if (sig ~= nil and ran ~= nil and sig ~= ran) then
		best, record = {static = {}, ipsc = {}}, {};
	end
	ran = sig or ran;
end

-- a target of an earlier life of this script: its registry entry is
-- lib_bot's, so it is found by its tag
local function sweep()
	local doomed = {};
	for pid in piditer(PID_BROADCAST) do
		if (target_index(pid) ~= nil) then doomed[#doomed + 1] = pid; end
	end
	for _, pid in ipairs(doomed) do bot_destroy(pid); end
end

function mod.on_load()
	-- check, never load: an error here unregisters the script cleanly
	if (bot_create == nil) then
		error("range needs lib_bot loaded first (its script pulls lib_bot in; check with: lsdctl status)", 0);
	end
	masterlist_set_gamemode("range");
	-- one team is as unbalanced as teams get: team_balance, where it is
	-- installed, would move people to the targets' side
	team_balance_max_diff = math.huge;
	-- and one map: vote_map, in random mode, would fetch another from the web
	map_web_random = false;
	sweep();
	place();
end

function mod.on_unload()
	drop_targets(1);
end

return mod;
