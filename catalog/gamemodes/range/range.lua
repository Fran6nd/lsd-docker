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
--   in the green start box, behind the start wall, when the course is
--   free. The wall comes down -- the server takes its supports away and
--   every client sees it collapse -- once the course is READY: every
--   target of it standing in its place, nobody else inside, and
--   COUNTDOWN seconds given to the shooter. The clock starts as it falls
--   and stops in the blue end box once every target is down (in the end
--   box with targets standing, the shooter is told how many and the
--   clock runs on). Dead, gone, out of the course or over IPSC_LIMIT
--   seconds: the run is abandoned. Either way the course is made ready
--   for the next one at once -- its targets stood up again where they
--   were, the wall built again -- and then the next in the queue goes
--   in. Anybody else found inside is sent to the waiting area, and so
--   joins the queue.
--
-- A hit is a bullet that strikes a target (a body shot or a head shot;
-- not a spade or a grenade), counted once a run, and only for the run
-- the target belongs to. Times are told, each person's best is kept and
-- a record announced. /best lists them. Health and ammunition are made
-- full at the start of every run and after it. There is no score, no
-- winner and no end, and no rewards (gamemode_rewards, which lib_rewards
-- reads: nothing shot here is a kill).
--
-- THE TARGETS are lib_bot bots that never move of themselves: no think,
-- no keys but the crouch of a crouched one, and no part in the bot
-- engine (nothing here asks lib_botlink for anything). A target is data
-- from the map (range_targets: its set, its kind, its stance, its
-- motion, the point it faces and its points; see
-- catalog/core/range_map.lua) and ONE CONTROLLER keeps all of them:
-- creates what is missing (a seat at a time, again a second later if
-- the server is full -- lib_bot gives a person a target's seat), puts
-- each where its motion says at this moment, swaps back what has been
-- flipped long enough, stands up again what is dead, and nothing else. Motions: static (its
-- one point), rail (back and forth between two points at a steady pace)
-- and blink (each point in turn, `param` seconds at each). Where a
-- target is is a function of the time alone, so every client sees the
-- same thing and a test can ask it.
--
-- WHAT A HIT DOES is the target's KIND, and nothing else decides it.
-- NOTHING HERE IS EVER KILLED. What a target does when it is hit is
-- FLIP: it is moved to the map's holding cell (range_cell, a closed
-- room nobody sees into) and a STAND-IN, a bot of the shooter's own
-- team, stands in its exact place, pose and facing -- and follows its
-- motion. The shooter sees the target change colour, and nothing more.
-- Flipping back is the same swap the other way.
--
--   plate    (the lanes) every bullet flips it, for range_flip_secs
--            seconds (5): the hit counts, once a run, and a plate shot
--            again after it has flipped back flips again (the feedback)
--            without counting again
--   popper   (the course) the hit that counts flips it, until its set
--            is made ready for the next run: it reads as down
--   noshoot  (the course) one of the shooter's own team, standing among
--            the targets: a hit adds range_noshoot_penalty seconds to
--            the run's time, told at once; it never flips
--
-- The stand-ins: one for each target that can flip (40 plates and 10
-- poppers: 50 seats, on top of the 54 targets). A shared pool could not
-- be smaller in the worst case, which is every one of them flipped at
-- once (a plate flips for 5 s, eight a lane can be shot in that time
-- at a rifle's pace, five lanes at once, and a whole course down), and
-- it would need a rule for running dry. With one each there is none: a
-- stand-in is its target's, made with it. It is not a target: a hit on
-- it counts for nothing, costs nothing (it is no no-shoot) and does
-- nothing, and it never shoots (no think, a spade). Where a seat for
-- one is missing (the server is full) the target does not flip, the
-- hit counts and shows its marker, and the log says so: never an error.
--

-- Every hit on a target or a stand-in stops in the damage hook: its
-- health never moves. What it did is told to the one who landed it through
-- lib_damage_markers' own API (damage_markers_show), with the number the
-- hit was worth, as for a man: the floating number a Damage Markers
-- client draws. (The extension's automatic marker reads a hit that
-- applied nothing as no hit, which is right for every other veto, so
-- the mode says it itself.) A no-shoot is on the shooter's team, whose
-- hits the core drops before any damage: the late on_hit, the last word
-- before the core, sends those on to the damage hook as the core sends
-- an enemy's.
--
-- Targets are hidden from the score, the roster and the kill feed where
-- the client speaks Silent Player (lib_bot's silent options), spawn on
-- their own points and take no person's spawn; the engine never
-- respawns one (the controller does).
--
-- NOBODY BUILDS OR DIGS, and grenades make no craters: the range is the
-- map's, the start wall with it. An edit refused is put back on the
-- client that made it.
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
local VERSION = 3;        -- of the map's range metadata (range_map.lua's M.VERSION)

getcfg("range_noshoot_penalty", 10, "Seconds added to a run's time for each hit on a no-shoot.");
getcfg("range_flip_secs", 5, "Seconds a lane's plate stays flipped (a stand-in of the shooter's team in its place) after a hit.");

-- what a hit does to a target of each kind, from the data's `kind`: how
-- long it flips. "secs": range_flip_secs. "run": until its set is made
-- ready for the next run, and only for the run's own shooter. A kind
-- not here (the no-shoot) never flips.
local FLIP = {plate = "secs", popper = "run"};

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
	en = "Your turn on the IPSC course: the wall in front of you comes down when the course is ready, and the clock starts then. Every target down, then to the blue end box; each hit on a no-shoot (your own team) costs %(penalty) s. %(limit) s at most.",
};
local all_down_msg = {en = "Every target hit: to the blue end box!"};
local noshoot_msg = {en = "No-shoot hit: +%(penalty) s"};
local penalty_total_msg = {en = "%(raw) s + %(penalty) s penalty = %(time) s"};
local old_map_msg = {en = "range: this map's range was generated by an older version; lsdctl map course generates a new one."};
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
--    noshoots = <hits on no-shoots>,
--    go = <the clock's start for a lane, its earliest for the course>,
--    since = <when the clock started>,
--    done = <a lane's, finished: held until the bay is left>,
--    deadline =, settle =, at_end =}
local runs = {};
local held = {};     -- target index -> the bot's pid
local standin = {};  -- target index -> the pid of its stand-in
local flips = {};    -- target index -> {untill = <when it swaps back; nil: when its set is made ready>}
local queue = {};    -- pids, the first goes next
local shooter = nil; -- who is on the IPSC course
local on_pad = {};   -- pid -> standing on the waiting area at the last look
local told_taken = {};
local best = {static = {}, ipsc = {}};   -- board -> name -> seconds
local record = {};                       -- board -> seconds
local ran = nil;     -- the range the times were made on
local next_topup = 0;
local faults = 0;
local degraded = 0;  -- hits on a target with no stand-in to flip to

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

-- a penalty as it was set: 10, not 10.00
local function amount(t)
	return string.format("%g", t);
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

local KINDS = {plate = true, popper = true, noshoot = true};
local STANCES = {stand = true, crouch = true};
local MOTIONS = {static = 1, rail = 2, blink = 1};   -- the points each needs at least

-- ('lane1', 'plate', 'stand', 'rail', 2.5, (face), (p1), (p2)); nil if not one
local function target(str)
	local set, kind, stance, motion, param, rest = string.match(str,
		"^%(%s*'([%w_]+)'%s*,%s*'(%a+)'%s*,%s*'(%a+)'%s*,%s*'(%a+)'%s*,%s*([%d%.]+)%s*,(.*)%)$");
	if (set == nil or not KINDS[kind] or not STANCES[stance] or MOTIONS[motion] == nil) then
		return nil;
	end
	local pts = {};
	for p in string.gmatch(rest, "%b()") do pts[#pts + 1] = point(p); end
	local face = table.remove(pts, 1);
	param = tonumber(param);
	if (face == nil or #pts < MOTIONS[motion] or (motion ~= "static" and not (param > 0))) then
		return nil;
	end
	return {set = set, kind = kind, stance = stance, motion = motion, param = param, face = face, points = pts};
end

-- ((x0, y0, z0), (x1, y1, z1), (r, g, b)): the start wall's voxels and
-- colour; nil if not one
local function wall(str)
	local pts = {};
	for p in string.gmatch(string.match(str or "", "^%((.*)%)$") or "", "%b()") do pts[#pts + 1] = point(p); end
	local a, b, c = pts[1], pts[2], pts[3];
	if (#pts ~= 3 or c.x > 255 or c.y > 255 or c.z > 255) then
		return nil;
	end
	return {x0 = math.min(a.x, b.x), y0 = math.min(a.y, b.y), z0 = math.min(a.z, b.z),
		x1 = math.max(a.x, b.x), y1 = math.max(a.y, b.y), z1 = math.max(a.z, b.z),
		color = {r = c.x, g = c.y, b = c.z}};
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
	if (tonumber(scrape.get_ext(str, "range_version")) ~= VERSION) then
		l10n_log(old_map_msg);
		return;
	end
	local cell = box(scrape.get_ext(str, "range_cell"));
	if (cell == nil) then
		l10n_log(old_map_msg);
		return;
	end
	local r = {seed = tonumber(scrape.get_ext(str, "range_seed")), spawn = spawn, cell = cell,
		lanes = {}, targets = {}, count = {}};
	for _, s in ipairs(tuples(scrape, str, "range_lanes")) do r.lanes[#r.lanes + 1] = box(s); end
	local area, start = box(scrape.get_ext(str, "range_ipsc")), box(scrape.get_ext(str, "range_ipsc_start"));
	local finish, wait = box(scrape.get_ext(str, "range_ipsc_end")), box(scrape.get_ext(str, "range_ipsc_wait"));
	if (area and start and finish and wait) then
		-- the wall, if the map has one
		r.ipsc = {area = area, start = start, finish = finish, wait = wait,
			wall = wall(scrape.get_ext(str, "range_ipsc_wall"))};
	end
	for _, s in ipairs(tuples(scrape, str, "range_targets")) do
		local t = target(s);
		local lane = t and tonumber(string.match(t.set, "^lane(%d+)$"));
		-- a target of a set the map has: one of its lanes, or its course
		if (t ~= nil and ((lane ~= nil and r.lanes[lane] ~= nil) or (t.set == "ipsc" and r.ipsc ~= nil))) then
			r.targets[#r.targets + 1] = t;
			if (t.kind ~= "noshoot") then
				r.count[t.set] = (r.count[t.set] or 0) + 1;
			end
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

-- the target a stand-in stands in for
local function standin_index(pid)
	local b = bot_get ~= nil and bot_get(pid) or nil;
	return b ~= nil and b.data.range_standin or nil;
end

local function face(pid, t)
	local f = t.face;
	local p = get_position(pid);
	bot_look_at(pid, {x = f.x + 0.5, y = f.y + 0.5, z = p.z});
end

local function name_of(r, t, k)
	local lane = tonumber(string.match(t.set, "^lane(%d+)$"));
	if (lane == nil) then
		-- its number on the course, the no-shoots apart
		local n = 0;
		for i = 1, k do
			local u = r.targets[i];
			if (u.set == t.set and (u.kind == "noshoot") == (t.kind == "noshoot")) then n = n + 1; end
		end
		return (t.kind == "noshoot" and "No-shoot " or "IPSC ") .. n;
	end
	if (t.motion ~= "static") then
		return "L" .. lane .. " " .. t.motion;
	end
	return string.format("L%d %dm", lane, r.lanes[lane].y0 - t.points[1].y);
end

-- the floor of the holding cell's middle, as a point of a target is
local function cell_point(r)
	local c = r.cell;
	return {x = math.floor((c.x0 + c.x1) / 2), y = math.floor((c.y0 + c.y1) / 2), z = c.z};
end

-- Where the seat of a target (standin: false) or of its stand-in (true)
-- belongs at `now`: out on the range, where the target's motion has it,
-- when it is the one that shows -- the target while it is not flipped,
-- the stand-in while it is -- and in the holding cell when it is not.
local function station(r, k, is_standin, now)
	local t = r.targets[k];
	if ((flips[k] ~= nil) == is_standin) then
		return stand_on(range_target_at(t, now));
	end
	return stand_on(cell_point(r));
end

-- a seat of a target of the map: its bot, made again if it is not there
local function seat(r, k, t, is_standin)
	return bot_create{
		-- a no-shoot is one of the people's own, and so is a stand-in
		team = (is_standin or t.kind == "noshoot") and 1 or 2,
		-- the stand-in is the target's name: all that differs is the colour
		name = name_of(r, t, k),
		tool = "spade",
		spawn_at = function(p)
			local i = target_index(p) or standin_index(p);
			local rr = range();
			if (rr == nil or i == nil or rr.targets[i] == nil) then
				return nil;
			end
			return station(rr, i, standin_index(p) ~= nil, get_time());
		end,
		silent = SILENT,
		data = is_standin and {range_standin = k} or {range_target = k},
	};
end

-- every seat the map's targets need, the targets first
local function top_up(r, now)
	if (now < next_topup) then
		return;
	end
	next_topup = now + TOPUP_SECS;
	for k, t in ipairs(r.targets) do
		if (held[k] == nil) then
			held[k] = seat(r, k, t, false);
			if (held[k] == nil) then
				return;   -- no seat, or the map is loading: in a second
			end
		end
	end
	for k, t in ipairs(r.targets) do
		if (FLIP[t.kind] ~= nil and standin[k] == nil) then
			standin[k] = seat(r, k, t, true);
			if (standin[k] == nil) then
				return;
			end
		end
	end
end

-- The target and its stand-in change places: `to` (the stand-in when
-- flipping, the target when flipping back) takes the exact place, pose
-- and facing of `from`, which goes into the holding cell. The pose is
-- the seat's own, a crouch is a crouch in either. A rail's or a blink's
-- place is the one its motion has at this moment.
local function swap(r, k, to_standin, now)
	local t = r.targets[k];
	local to, from = held[k], standin[k];
	if (to_standin) then to, from = from, to; end
	local p = range_target_at(t, now);
	bot_teleport(to, body(t, p));
	bot_look_toward(to, get_orientation(from));
	bot_get(to).data.at = p;
	bot_teleport(from, body(t, cell_point(r)));
	bot_get(from).data.at = nil;
end

-- Can the pair swap now? Both made, joined and standing.
local function can_swap(k)
	local a, b = held[k], standin[k];
	return a ~= nil and b ~= nil and is_joined(a) and is_joined(b) and is_alive(a) and is_alive(b);
end

local function flip(r, k, t, now)
	if (flips[k] ~= nil) then
		return;
	end
	if (not can_swap(k)) then
		degraded = degraded + 1;
		if (degraded <= 3) then log("range: no stand-in for %s: it does not flip", name_of(r, t, k)); end
		return;
	end
	swap(r, k, true, now);
	flips[k] = {untill = FLIP[t.kind] == "secs" and now + range_flip_secs or nil};
end

local function unflip(r, k, now)
	if (flips[k] == nil) then
		return;
	end
	if (can_swap(k)) then
		swap(r, k, false, now);
	end
	flips[k] = nil;
end

-- one seat: stood up again if dead; out on the range it moves with its
-- target's motion
local function keep(r, k, pid, is_standin, now)
	local t = r.targets[k];
	if (t == nil or pid == nil or not is_joined(pid)) then
		return;
	end
	if (not is_alive(pid)) then
		-- at once, not after a respawn wait
		spawn_player(pid, station(r, k, is_standin, now));
	elseif ((flips[k] ~= nil) ~= is_standin) then
		return;   -- in the cell
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

local function keep_targets(r, now)
	top_up(r, now);
	for k, f in pairs(flips) do
		if (f.untill ~= nil and now >= f.untill) then
			unflip(r, k, now);
		end
	end
	for k, pid in pairs(held) do keep(r, k, pid, false, now); end
	for k, pid in pairs(standin) do keep(r, k, pid, true, now); end
end

function mod.after.spawn_player(pid)
	local k = target_index(pid);
	local is_standin = false;
	if (k == nil) then
		k, is_standin = standin_index(pid), true;
	end
	local r = range();
	if (k == nil or r == nil or r.targets[k] == nil) then
		return;
	end
	local t = r.targets[k];
	bot_get(pid).data.at = nil;
	if (t.stance == "crouch") then bot_crouch(pid); else bot_stop(pid); end
	-- a stand-in takes the facing of what it stands in for when it swaps in
	if (not is_standin) then face(pid, t); end
end

local function drop_targets(from)
	for _, seats in ipairs({held, standin}) do
		for k, pid in pairs(seats) do
			if (k >= from) then
				seats[k] = nil;
				flips[k] = nil;
				bot_destroy(pid);
			end
		end
	end
end

-- The engine never respawns a target or a stand-in: the controller does
-- (above). 0 is the documented "no respawn", and the only safe value:
-- this clk is not in seconds (see the_fall.lua).
function mod.get_spawn_time(pid)
	if (target_index(pid) ~= nil or standin_index(pid) ~= nil) then
		return 0;
	end
	return mod.next.get_spawn_time(pid);
end

-- a set's targets that were flipped for its run: back, where their
-- motion has them now
local function raise(r, set, now)
	for k, t in ipairs(r.targets) do
		if (t.set == set and flips[k] ~= nil and flips[k].untill == nil) then
			unflip(r, k, now);
		end
	end
end

--=========================== THE START WALL =========================--
-- Built and brought down by the server a block at a time, through the
-- block_action a player's edit takes, so the server's map and every
-- client's agree after each block (the batched path culls once at the
-- end and leaves clients' links stale: map_layout/blocks.lua).

local function each_voxel(w, f)
	for z = w.z1, w.z0, -1 do   -- the bottom layer first
		for y = w.y0, w.y1 do
			for x = w.x0, w.x1 do f(x, y, z); end
		end
	end
end

-- every voxel of it that is missing, bottom up, in its colour
local function build_wall(w)
	local anon = get_anon_pid();
	set_block_color(anon, w.color);
	each_voxel(w, function(x, y, z)
		local p = {x = x, y = y, z = z};
		if (not is_solid(p)) then block_action(p, 0, anon); end
	end);
end

-- Its supports go first: both ends, then the bottom row from the ends
-- inward. With the last of them the rest hangs on nothing: the server
-- culls it, and every client drops it as falling debris -- the wall
-- collapses. Whatever might still stand (a wall that touches something
-- else) is taken after.
local function collapse_wall(w)
	local anon = get_anon_pid();
	local function take(x, y, z)
		local p = {x = x, y = y, z = z};
		if (is_solid(p)) then block_action(p, 1, anon); end
	end
	local along_x = w.x1 - w.x0 >= w.y1 - w.y0;
	for z = w.z0, w.z1 do
		for t = (along_x and w.y0 or w.x0), (along_x and w.y1 or w.x1) do
			if (along_x) then take(w.x0, t, z); take(w.x1, t, z);
			else take(t, w.y0, z); take(t, w.y1, z); end
		end
	end
	local lo, hi = (along_x and w.x0 or w.y0) + 1, (along_x and w.x1 or w.y1) - 1;
	while (lo <= hi) do
		for _, a in ipairs(lo == hi and {lo} or {lo, hi}) do
			for t = (along_x and w.y0 or w.x0), (along_x and w.y1 or w.x1) do
				if (along_x) then take(a, t, w.z1); else take(t, a, w.z1); end
			end
		end
		lo, hi = lo + 1, hi - 1;
	end
	each_voxel(w, take);
end

--============================== HITS ================================--

local finish;

-- pid's run that a hit on target t is part of, while its clock runs
local function running(pid, t)
	local r = runs[pid];
	if (r == nil or r.since == nil or r.done or t.set ~= r.set) then
		return nil;
	end
	return r;
end

-- a no-shoot hit: the penalty, every hit
local function penalize(pid, t)
	local r = running(pid, t);
	if (r ~= nil) then
		r.noshoots = r.noshoots + 1;
		tell(pid, noshoot_msg, {penalty = amount(range_noshoot_penalty)});
	end
end

-- a target hit: counted once a run
local function count(pid, k, t)
	local r = running(pid, t);
	if (r == nil or r.hits[k]) then
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
-- hit was worth, and a bullet does what the target's kind says.
local function struck(pid, hp, type, damager)
	if (standin_index(pid) ~= nil) then
		return true;   -- not a target: nothing, and no no-shoot's penalty
	end
	local k = target_index(pid);
	if (k == nil) then
		return false;
	end
	local r = range();
	local t = r ~= nil and r.targets[k] or nil;
	if (t ~= nil and hp > 0 and damager ~= nil and damager ~= pid and damager >= 0
	    and damager < MAX_PLAYERS and not is_bot(damager)) then
		if (damage_markers_show ~= nil) then
			damage_markers_show(damager, pid, hp);
		end
		if (type == 0 or type == 1) then   -- KillTypeWeapon, KillTypeHeadshot
			if (t.kind == "noshoot") then
				penalize(damager, t);
			else
				-- the kind says whether it flips; a popper falls only to
				-- the run's own shooter, and every bullet flips a plate
				local how = FLIP[t.kind];
				if (how == "secs" or (how == "run" and running(damager, t) ~= nil)) then
					flip(r, k, t, get_time());
				end
				count(damager, k, t);
			end
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

-- A hit on a target of the shooter's own team (a no-shoot) is one the
-- core drops on its team test before any damage. Here in the late chain
-- -- after every script that replaces what a bullet does, the last word
-- before the core -- it is sent on to the damage hook above as the core
-- sends an enemy's (ffa.lua's mapping of the hit type), so every hit on
-- a target is decided in that one place. Still chained: the core drops
-- it, and anything below still sees the hit.
function mod.late.on_hit(pid, type, hitPlayer)
	if (target_index(hitPlayer) ~= nil and get_team(pid) == get_team(hitPlayer)) then
		damage_player_directional(hitPlayer, get_hit_damage(pid, type), get_position(pid),
			type == 4 and 2 or (type == 1 and 1 or 0), pid);
	end
	return mod.late.next.on_hit(pid, type, hitPlayer);
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

-- A run is over, however it ended: its set's poppers stand again, and
-- if it was the course's, the wall is built again -- the course ready
-- for the next shooter before he is let in.
local function end_run(pid)
	local run = runs[pid];
	runs[pid] = nil;
	local r = range();
	if (run ~= nil and r ~= nil) then
		raise(r, run.set, get_time());
	end
	if (shooter == pid) then
		shooter = nil;
		if (r ~= nil and r.ipsc ~= nil and r.ipsc.wall ~= nil) then
			build_wall(r.ipsc.wall);
		end
	end
end

-- the time is the clock's and the penalties', and both boards rank by it
function finish(pid, r, now)
	local raw = now - r.since;
	local penalty = r.noshoots * range_noshoot_penalty;
	local time = raw + penalty;
	local name = get_name(pid);
	local board = r.kind == "lane" and "static" or "ipsc";
	local old = best[board][name];
	log("range: %s, %s in %s s (%d no-shoot hits)", name, board, secs(time), r.noshoots);

	if (penalty > 0) then
		tell(pid, penalty_total_msg, {raw = secs(raw), penalty = amount(penalty), time = secs(time)});
	end

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
		send_out(pid);
		end_run(pid);
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
	end_run(pid);
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
				noshoots = 0, go = now + COUNTDOWN, settle = now + SETTLE};
			set_position(pid, middle(r.ipsc.start));
			refill(pid);
			tell(pid, turn_msg, {limit = IPSC_LIMIT, penalty = amount(range_noshoot_penalty)});
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
			end_run(pid);
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
				noshoots = 0, go = now + COUNTDOWN};
			told_taken[pid] = nil;
			refill(pid);
			tell(pid, lane_ready_msg, {lane = k, total = r.count[set] or 0, secs = COUNTDOWN});
		elseif (told_taken[pid] ~= k) then
			told_taken[pid] = k;
			tell(pid, lane_taken_msg, {lane = k});
		end
	end
end

-- The course is ready for a run: every target of the set standing (none
-- missing, none flipped), and nobody on it but the shooter.
local function ready(r, set)
	for k, t in ipairs(r.targets) do
		if (t.set == set) then
			local pid = held[k];
			if (pid == nil or not is_joined(pid) or not is_alive(pid) or flips[k] ~= nil) then
				return false;
			end
		end
	end
	for pid in piditer(PID_BROADCAST) do
		if (pid ~= shooter and not is_bot(pid) and is_joined(pid) and is_alive(pid)
		    and over(r.ipsc.area, get_position(pid))) then
			return false;
		end
	end
	return true;
end

local function look_ipsc(pid, r, pos, now)
	local I = r.ipsc;
	local run = runs[pid];
	if (pid == shooter) then
		if (now < run.settle) then
			return;
		elseif (not over(I.area, pos)) then
			abandon(pid, left_course_msg);
		elseif (run.since == nil) then
			-- behind the wall: it falls, and the clock starts, when all is ready
			if (now >= run.go and ready(r, run.set)) then
				if (I.wall ~= nil) then collapse_wall(I.wall); end
				run.since, run.deadline = now, now + IPSC_LIMIT;
				tell(pid, go_msg);
			end
		elseif (now > run.deadline) then
			send_out(pid);
			abandon(pid, too_long_msg, {limit = IPSC_LIMIT});
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

-- dead, of anything: the run is over, and back at once (a target is the
-- controller's: keep_targets)
function mod.after.kill(pid)
	if (range() == nil or not is_connected(pid) or not is_joined(pid) or is_alive(pid)
	    or target_index(pid) ~= nil or standin_index(pid) ~= nil) then
		return;
	end
	local run = runs[pid];
	if (run ~= nil) then
		if (run.kind == "ipsc") then
			abandon(pid, died_course_msg);
		else
			if (not run.done) then tell(pid, void_died_msg); end
			end_run(pid);
		end
	end
	if (get_next_team(pid) ~= SPECTATOR) then
		spawn_player(pid, get_spawn_position(pid));
	end
end

function mod.after.on_disconnect(pid)
	end_run(pid);
	on_pad[pid], told_taken[pid] = nil, nil;
	unqueue(pid);
	for _, seats in ipairs({held, standin}) do
		for k, p in pairs(seats) do
			if (p == pid) then seats[k] = nil; flips[k] = nil; end
		end
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

-- In the late chain, as map_layout's guard is: every observer above it
-- (lib_shot_detect's proof of a shot) still sees the edit. What the
-- client did of it already is put back on that client.
function mod.late.on_block_action(pid, pos, type)
	map_layout.revert_action(pid, pos, type);
	l10n_send_chat(pid, no_build_msg);
end

function mod.late.on_block_line(pid, start, stop)
	for p in iter_block_line(start, stop) do
		map_layout.revert(pid, p, 0);
	end
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
-- and their stand-ins stay in their seats (lib_bot brings them back from the map change)
-- and go to their new places; the best times stay while the range is
-- the same one
function mod.after.finish_map_load()
	runs, queue, shooter, on_pad, told_taken, flips = {}, {}, nil, {}, {}, {};
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
		if (target_index(pid) ~= nil or standin_index(pid) ~= nil) then doomed[#doomed + 1] = pid; end
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
	-- nothing shot here is a kill or a capture: lib_rewards gives nothing
	gamemode_rewards = false;
	sweep();
	place();
	-- loaded onto a range whose wall an earlier life of this left down
	local r = range();
	if (r ~= nil and r.ipsc ~= nil and r.ipsc.wall ~= nil) then
		build_wall(r.ipsc.wall);
	end
end

function mod.on_unload()
	local r = range();
	if (r ~= nil and r.ipsc ~= nil and r.ipsc.wall ~= nil) then
		build_wall(r.ipsc.wall);
	end
	drop_targets(1);
	gamemode_rewards = nil;
end

return mod;
