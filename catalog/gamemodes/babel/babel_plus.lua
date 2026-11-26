-- babel_plus.lua -- Babel as a real game: team-coloured blocks, camper marks
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
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
--
-- ENGINE BOTS (the bot engine, bot/; its tree is bot/trees/babel.bt).
-- Only when engine bots are playing -- botlink_alive(): the link file is
-- made by the first botlink_add and by nothing here -- this lays out each
-- team's STAIR to the platform and tells the bots, once a second, through
-- the bridge (bot/TREES.md section 13):
--   edit=all                    a tower is built (sent once)
--   zone=<platform> both; <each team's tower area> nodig for it and
--                               nobuild for the other (babel_protect)
--                               (babel refuses them there)
--   blueprint.stair, blueprint.widen   each team's
--                               structures, voxel by voxel from the ground
--                               up: the bots share them out a part each
--                               (`build_part`); said again only changed
--   place.stair_top, place.stair_foot, place.breach   each team's, as the
--                               world's "<name>@<team>"
--   fact.stair_done, fact.stair_high, fact.widen, fact.breach
--   place.intel, place.intel_home  for everybody (who carries it the engine
--                               reads from the world: `carrying_intel`)
-- The stair runs from the platform's corner side outward and down, one
-- column and one voxel a step, along the platform's near edge row: team 1
-- west of it, team 2 east -- inside each team's protected area, where
-- babel_protect keeps the other team from building and the team itself
-- from breaking it. Its lowest step stands on the ground; broken there by
-- the other team (they may), it falls whole. A bot that builds is given
-- its blocks back at once (infinite_blocks refills players past the
-- botlink's count). With no engine bots none of this runs: the mode is
-- the same mode for people, and the engine is never started for it.
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
	for i in (people_in or piditer)(PID_BROADCAST_TEAM(team)) do
		out[#out+1] = i;
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

--============================ ENGINE BOTS ============================--
local BOT_EVERY = 1;        -- seconds

-- A SECOND STAIR for a team with this many engine bots or more. About two
-- thirds of a team work on its stair until it is up (babel.bt's
-- babel_role: the builders, masons and runners, and the platform men, who
-- build as runners until then), so six put four on it: as many as one
-- stair keeps busy -- it grows at its top, a step and its riser at a time,
-- and along its second row. More wait their turn at the top; a second
-- stair puts them to work.
local SECOND_STAIR_BOTS = 6;

-- WHICH KIND. lib_stairs lays four: straight, tapered (a wedge of lines,
-- long at the bottom), switchback (in a few columns of the platform),
-- spiral (round a pillar, 3 by 3). The bots build only the STRAIGHT one
-- to the top yet: in the babel harness (blueresortbabel, 10 a side, 2
-- seeds, 10 minutes) the straight stairs were whole at 83 to 92 s, while
-- no tapered one was (a wedge of 381 voxels stalls at a level whose
-- stand the builders cannot reach), nor a spiral, and one switchback of
-- four (343 s). Until build_part lays those, a team is given straight
-- stairs: the first where a row has room, the least in its way else, and
-- its second (SECOND_STAIR_BOTS, or a cut) on another row apart from it
-- -- what makes a second sturdy is that it stands apart: one cut does not
-- drop both. Each list in the order a kind is preferred.
local FIRST_KINDS = {"straight"};
local STURDY_KINDS = {"straight"};

local bots_next, bots_told = 0, false;
-- team -> {[1] its stair, [2] its second or nil (lib_stairs' stairs, each
-- with `seen`: the steps seen built), second_tried: a second looked for}
local stairs = {};
-- the ground as it was when the stairs were first laid on this map, column
-- by column: a stair laid again (another kind, after a cut) keeps its
-- floors -- what the team built on the ground since would be ground to
-- ground_at, and the stair would shrink under the builders' hands
local laid_ground = {};

local function engine_bot(pid)
	local b = bot_get ~= nil and bot_get(pid) or nil;
	return b ~= nil and b.data ~= nil and b.data.botlink == true;
end

local function engine_bots_here()
	if (botlink_alive == nil or not botlink_alive()) then return false; end
	for i in piditer(PID_BROADCAST) do
		if (engine_bot(i)) then return true; end
	end
	return false;
end

local function team_bots(team)
	local n = 0;
	for i in piditer(PID_BROADCAST) do
		if (get_team(i) == team and engine_bot(i)) then n = n + 1; end
	end
	return n;
end

-- the top of the GROUND in a column: of the solid run that goes down to
-- the bottom of the map (a tree, a rock arch or a floating island over
-- it is not ground: a stair that started on one could not be got to)
local function ground_at(x, y)
	local z = 62;
	while (z > 0 and is_solid({x = x, y = y, z = z - 1})) do z = z - 1; end
	if (not is_solid({x = x, y = y, z = 62})) then return 63; end
	return z;
end

local function laid_ground_at(x, y)
	local k = y * 512 + x;
	if (laid_ground[k] == nil) then laid_ground[k] = ground_at(x, y); end
	return laid_ground[k];
end

-- the rows a stair's top may take: beside the platform, but not its two
-- edge rows (babel_protect paints the tower areas' borders on them); out
-- from the middle row: 0, +1, -1, +2, ...
local function stair_rows()
	local y0, y1 = 256 - babel_height / 2 + 1, 255 + babel_height / 2 - 1;
	local rows = {};
	for i = 0, y1 - y0 do
		local y = math.floor((y0 + y1) / 2) + (i % 2 == 0 and i / 2 or -(i + 1) / 2);
		if (y >= y0 and y <= y1) then rows[#rows + 1] = y; end
	end
	return rows, y0, y1;
end

-- what one team's stair is laid on (lib_stairs): its top a step up from
-- the platform's level at the platform's corner side -- team 1 west of
-- it, team 2 east --, running down and away from it, on the ground as it
-- was first laid; kept off the platform (babel refuses edits on and round
-- it), off the rows past those a stair may take, and out of the other
-- team's tower area (babel_protect: nobody builds there but its team)
local function stair_spec(team, y, y2, wide)
	local _, y0, y1 = stair_rows();
	local ps = {x = 256 - babel_width / 2, y = 256 - babel_height / 2};
	local pe = {x = 255 + babel_width / 2, y = 255 + babel_height / 2};
	local theirs = (babel_protect_zones or {})[other(team)] or {};
	return {
		top = {x = team == 1 and ps.x - 1 or pe.x + 1, y = y, z = babel_z + 1},
		dx = team == 1 and -1 or 1,
		rows = {y, y2},
		ground = laid_ground_at,
		wide = wide,
		refuse = function(x, y)
			local pos = {x = x, y = y};
			if (y < y0 or y > y1 or in_box(pos, ps, pe)) then return true; end
			for _, zone in ipairs(theirs) do
				if (in_box(pos, zone[1], zone[2])) then return true; end
			end
			return false;
		end,
	};
end

-- How many voxels are in a stair's way: solid, over the ground, in a
-- floor or the three voxels over it (where a body stands). A stair runs
-- through the team's own protected area, where babel_protect lets nobody
-- break his own team's blocks: what is in the way there stays in the way.
local function in_way(st)
	local n = 0;
	for _, p in ipairs(st.steps) do
		local g = laid_ground_at(p.x, p.y);
		for zz = p.z - 3, p.z do
			if (zz >= 0 and zz < g and is_solid({x = p.x, y = p.y, z = zz})) then n = n + 1; end
		end
	end
	return n;
end

-- the rows a stair takes, floors, voxels and what widens it
local function rows_of(st)
	local rows = {};
	for _, list in ipairs({st.steps, st.cells, st.widen}) do
		for _, c in ipairs(list) do rows[c.y] = true; end
	end
	return rows;
end

-- two stairs with a row at least between them, for the links of each
-- (`brace`: a column beside a step)
local function apart(a, b)
	local rb = rows_of(b);
	for y in pairs(rows_of(a)) do
		if (rb[y - 1] or rb[y] or rb[y + 1]) then return false; end
	end
	return true;
end

-- The first place clear for one of `kinds`, in their order, each on the
-- rows out from the middle (a switchback's second row on either side); a
-- row apart from `away`, another stair of the team, if given. None clear:
-- the one with the least in its way, the earlier on a tie. -> the stair
-- and how much is in its way, or nil.
local function find(team, kinds, away)
	local best, least = nil, math.huge;
	for _, kind in ipairs(kinds) do
		for _, y in ipairs(stair_rows()) do
			for _, side in ipairs(kind == "switchback" and {1, -1} or {0}) do
				local st = stair_lay(kind, stair_spec(team, y, side ~= 0 and y + side or nil));
				if (st ~= nil and (away == nil or apart(st, away))) then
					local n = in_way(st);
					if (n < least) then best, least = st, n; end
					if (n == 0) then return st, 0; end
				end
			end
		end
	end
	return best, least;
end

-- a straight stair WIDENED: its second row beside it, on the side with
-- less in its way (inside the rows a stair may take); the other side is
-- left for links
local function widened(team, st)
	local y = st.top.y;
	local _, y0, y1 = stair_rows();
	local function way(row)
		local s = row >= y0 and row <= y1 and stair_lay("straight", stair_spec(team, row)) or nil;
		return s ~= nil and in_way(s) or math.huge;
	end
	return stair_lay("straight", stair_spec(team, y, nil, way(y + 1) <= way(y - 1) and y + 1 or y - 1));
end

-- a team's stair laid (`which`: 1 its first, 2 its second), and said in
-- the log with why that kind
local function lay(team, which, st, why)
	st.seen = {};
	stairs[team][which] = st;
	log("babel: team %d's %s stair is %s, from row %d, %d voxels: %s", team,
		which == 1 and "first" or "second", st.kind, st.top.y, #st.cells, why);
end

local function first_stair(team)
	local st, n = find(team, FIRST_KINDS);
	if (st == nil) then
		log("babel: team %d: no room for a stair of any kind", team);
		return;
	end
	if (st.kind == "straight") then st = widened(team, st); end
	lay(team, 1, st, n > 0 and string.format("no place is clear, the least in its way (%d voxels)", n)
		or st.kind == "straight" and "its row is clear"
		or st.kind == "switchback" and "every row has something in a straight stair's way"
		or "neither a straight stair nor a switchback has a clear place");
end

-- looked for once a map: the room for it does not grow
local function second_stair(team, why)
	local t = stairs[team];
	t.second_tried = true;
	local st, n = find(team, STURDY_KINDS, t[1]);
	if (st == nil) then
		log("babel: team %d: no room for a second stair (%s)", team, why);
		return;
	end
	lay(team, 2, st, n > 0 and string.format("%s; the least in its way (%d voxels)", why, n) or why);
end

-- A CUT -- a step that was built is air: the other team broke it
-- (babel_protect lets nobody break his own) --: the team gets a second
-- stair, apart from the first, if it has none (the first is mended where
-- it was cut: build_part takes its missing parts again, from the bottom;
-- and linked where a cut drops the most: `brace`). With a second stair
-- for a growing team, the only time a team's stairs are laid again on a
-- map.
local function stair_cut(team)
	local t = stairs[team];
	if (t[2] == nil and not t.second_tried) then second_stair(team, "its stair was cut"); end
end

local function lay_stairs()
	stairs = {};
	for team = 1, 2 do
		stairs[team] = {};
		first_stair(team);
	end
end

-- A point for the bridge, written exactly: what is sent here is a voxel's
-- middle or an eye 2.25 over a floor, multiples of a quarter, which two
-- decimals write exactly -- one decimal would round a half, and LuaJIT
-- builds round a half differently (to even on one, away from zero on
-- another: the same server would tell the bots two places)
local function point(x, y, z) return string.format("%.2f %.2f %.2f", x, y, z); end
local function eye(p) return point(p.x + 0.5, p.y + 0.5, p.z - 2.25); end
local function block(p) return point(p.x + 0.5, p.y + 0.5, p.z + 0.5); end

-- what a stair is now: the next step to build (nil: whole), the highest
-- built from the bottom, how many built, and whether a step seen built is
-- gone (a cut: said once)
local function stair_state(st)
	local nextp, top, n, cut = nil, nil, 0, false;
	for i, p in ipairs(st.steps) do
		if (is_solid(p)) then
			st.seen[i] = true;
			n = n + 1;
			if (nextp == nil) then top = p; end
		else
			cut = cut or st.seen[i] == true;
			st.seen[i] = nil;
			if (nextp == nil) then nextp = p; end
		end
	end
	return nextp, top, n, cut;
end

-- a team's stairs as they are: its BEST, the furthest up (its first on a
-- tie), stands for the team -- its top, its foot, how far up; done when
-- any is whole; cut when any was
local function team_state(team)
	local s = {done = false, cut = false};
	for _, st in ipairs(stairs[team]) do
		local nextp, top, n, cut = stair_state(st);
		local high = n / #st.steps;
		if (s.st == nil or high > s.high) then s.st, s.top, s.n, s.high = st, top, n, high; end
		s.done = s.done or nextp == nil;
		s.cut = s.cut or cut;
	end
	return s;
end

-- THE STAIRS AS BOTS BUILD THEM are BLUEPRINTS (lib_stairs lays them out):
-- their voxels in the order they rest on each other, which the bots share
-- out a part each, so that the team spreads over them instead of chasing
-- one next block together. A straight stair is a band two voxels deep:
-- each step and the voxel under it, face to face with the next column's.
-- Dug anywhere it holds only by its foot, and all above the cut falls
-- (the server's cull). What makes each kind hold:
--   straight    WIDEN: the same band on the row beside it, bottom first: a
--     block dug from one row leaves the other holding it.
--   tapered     nothing more: every column of the wedge stands on the
--     ground, so a cut drops what was over it in that column and no more.
--   switchback  WIDEN: a pillar from the ground beside its outer landings,
--     on which every leg hangs at its outer end.
--   spiral      nothing more: its pillar, a part of it, holds the ring.
-- And for every kind, LINKS: a column from the ground beside a step, up to
-- its level (where it meets the step face to face): a cut drops no more
-- than the stretch up to the next link. The bots choose where themselves
-- (`brace stair`: where a cut would drop the most, by the server's own
-- collapse, a block line beside the middle of what would fall).
-- The other team's best stair is broken where it is weakest: in the
-- middle of its longest stretch held by nothing but the stair under it
-- (the engine's dig_weakest picks the block there whose removal drops the
-- most).

local function first_missing(cells)
	for _, c in ipairs(cells) do
		if (not is_solid(c)) then return c; end
	end
end

-- a step linked: a solid column from the ground up to its level beside it
-- (ground_at counts such a column as ground: its top is then at the
-- step's level or above) -- a link, a straight stair's second row, the
-- wedge's next column, a spiral's pillar, a switchback's
local function linked(p)
	return ground_at(p.x - 1, p.y) <= p.z or ground_at(p.x + 1, p.y) <= p.z
		or ground_at(p.x, p.y - 1) <= p.z or ground_at(p.x, p.y + 1) <= p.z;
end

-- the step in the middle of the longest stretch of the stair as built
-- that is held by nothing but the stair below it (a step is held when its
-- riser stands on the ground, or a link stands beside it; one not built
-- yet is no part of it); nil when there is none
local function weakest_stretch(st)
	local best, run, from = 0, 0, nil;
	local mid = nil;
	for i, p in ipairs(st.steps) do
		local held = not is_solid(p) or p.z + 2 >= ground_at(p.x, p.y) or linked(p);
		if (held) then
			run = 0;
		else
			if (run == 0) then from = i; end
			run = run + 1;
			if (run > best) then best, mid = run, st.steps[math.floor((from + i) / 2)]; end
		end
	end
	return mid;
end

-- for the bots of a team: the world's facts and places with "@<team>" at
-- the end, which a bot reads under the bare name (bot/TREES.md section 13)
local function tell_team(team, key, value)
	botlink_set(key .. "@" .. team, value);
end

-- a blueprint, "x y z; x y z; ...", said when it changed (a stair's band
-- is a kilobyte and more, a wedge ten: not again every second for
-- nothing); none, an empty text, which the engine takes as "forget it"
local told_blueprint = {};
local function tell_blueprint(team, name, cells)
	local parts = {};
	for i, c in ipairs(cells) do parts[i] = string.format("%d %d %d", c.x, c.y, c.z); end
	local key, text = "blueprint." .. name .. "@" .. team, table.concat(parts, "; ");
	if (told_blueprint[key] ~= text) then
		told_blueprint[key] = text;
		botlink_set(key, text);
	end
end

local function tell_bots()
	if (not bots_told) then
		bots_told = true;
		botlink_set("edit", "all");
		-- the platform (babel refuses edits under and round it), and
		-- babel_protect's rules, for each team's routes and hands: nothing
		-- broken in its own tower area, nothing built in the other's (a
		-- carrier home through its own area dug there, was refused, and
		-- dug again for an hour). One setting, the whole list.
		local zones = {string.format("%d %d %d %d", 256 - babel_width / 2, 256 - babel_height / 2,
			255 + babel_width / 2, 255 + babel_height / 2)};
		for team = 1, 2 do
			for _, z in ipairs((babel_protect_zones or {})[team] or {}) do
				zones[#zones + 1] = string.format("%d %d %d %d nodig team %d", z[1].x, z[1].y, z[2].x, z[2].y, team);
				zones[#zones + 1] = string.format("%d %d %d %d nobuild team %d", z[1].x, z[1].y, z[2].x, z[2].y, other(team));
			end
		end
		botlink_set("zone", table.concat(zones, "; "));
	end
	if (stairs[1] == nil) then lay_stairs(); end
	-- laid again: a team's stair cut, a team grown to keep two busy
	for team = 1, 2 do
		local t = stairs[team];
		if (t[1] ~= nil) then
			if (team_state(team).cut) then stair_cut(team); end
			if (t[2] == nil and not t.second_tried) then
				local n = team_bots(team);
				if (n >= SECOND_STAIR_BOTS) then
					second_stair(team, string.format("%d engine bots on the team, more than one stair keeps busy", n));
				end
			end
		end
	end
	local s = {};
	for team = 1, 2 do s[team] = team_state(team); end
	local il = get_1intel_loc ~= nil and get_1intel_loc() or nil;
	local intel = type(il) == "number" and ("pid " .. il)
		or type(il) == "table" and point(il.x, il.y, il.z - 2.25) or "";
	botlink_set("place.intel", intel);
	-- where it is put back (babel's putback: the platform's middle)
	botlink_set("place.intel_home", point(256.5, 256.5, babel_z - 2.25));
	for team = 1, 2 do
		local t, me, them = stairs[team], s[team], s[other(team)];
		if (me.st ~= nil) then
			tell_blueprint(team, "stair", t[1].cells);
			tell_blueprint(team, "stair2", t[2] ~= nil and t[2].cells or {});
			tell_team(team, "place.stair_top", me.top and eye(me.top) or eye(me.st.foot));
			tell_team(team, "place.stair_foot", eye(me.st.foot));
			tell_team(team, "fact.stair_done", me.done and 1 or 0);
			tell_team(team, "fact.stair_high", me.high);
			-- ours: what widens the first (the links where a cut would drop
			-- the most, the bots choose themselves: `brace stair`, by the
			-- server's own collapse)
			tell_blueprint(team, "widen", t[1].widen);
			tell_team(team, "fact.widen", first_missing(t[1].widen) and 1 or 0);
		end
		-- theirs: their best stair where it is weakest (its foot, if every
		-- stretch is held)
		if (them.st ~= nil) then
			tell_team(team, "place.breach", block(weakest_stretch(them.st) or them.st.steps[1]));
			tell_team(team, "fact.breach", them.n >= 3 and 1 or 0);
		end
	end
end

local function bots_tick(now)
	if (now < bots_next) then return; end
	bots_next = now + BOT_EVERY;
	if (engine_bots_here()) then tell_bots(); end
end

-- infinite_blocks refills a player behind the botlink's back; a bot's
-- count is the botlink's, refilled by a restock (its hook): the stair
-- is not rationed for bots either. Health and ammunition as they were.
local function refill_bot(pid)
	if (restock ~= nil and engine_bot(pid)) then
		local hp, mag, reserve = get_hp(pid), get_mag_ammo(pid), get_reserve_ammo(pid);
		restock(pid);
		set_hp(pid, hp);
		set_ammo(pid, mag, reserve);
	end
end

function mod.after.on_block_action(pid, pos, type)
	if (type == 0) then refill_bot(pid); end
end

function mod.after.on_block_line(pid, startp, endp)
	refill_bot(pid);
end

--=========================== WHAT BABEL KEEPS ==========================--
-- Babel's protections, said once, to the one question every edit answers
-- (lib_block_filter): so they hold for a player's spade, a grenade, a
-- bot's dig, a rocket, a railgun or a script alike. Upstream's babel and
-- babel_protect still refuse a player's own action, with their message.
--   * the platform is never broken, by anyone
--   * a team's tower area is not broken by that team (a player with the
--     no_babel_protect cap may), nor by the world's own effects, which
--     have no team -- the other team may: that is the game
--   * nobody builds on or beside the platform, nor in the other team's
--     tower area; a script (the platform's own rebuild, its paintings)
--     builds where it likes
local function within(pos, a, b, m)
	m = m or 0;
	return pos.x >= a.x - m and pos.x <= b.x + m and pos.y >= a.y - m and pos.y <= b.y + m;
end

local function zones_of(team)
	return (babel_protect_zones or {})[team] or {};
end

-- upstream babel's rule for a block built near the platform: its own
-- layer, within or one beside it but for the four corners; and the
-- layers just above and below it
local function platform_forbids_building(pos, ps, pe)
	if (pos.z == babel_z) then
		local corner = (pos.x == ps.x - 1 or pos.x == pe.x + 1)
			and (pos.y == ps.y - 1 or pos.y == pe.y + 1);
		return within(pos, ps, pe, 1) and not corner;
	end
	return math.abs(pos.z - babel_z) == 1 and within(pos, ps, pe);
end

function mod.may_edit_block(who, pos, type)
	local ps = {x = 256 - babel_width/2, y = 256 - babel_height/2};
	local pe = {x = 255 + babel_width/2, y = 255 + babel_height/2};
	local team = who ~= nil and get_team(who) or nil;
	if (type == 1) then
		if (pos.z == babel_z and within(pos, ps, pe)) then
			return false;
		end
		if (who == nil or has_cap == nil or not has_cap(who, "no_babel_protect")) then
			for t = 1, 2 do
				if (team == nil or team == t) then
					for _, zone in ipairs(zones_of(t)) do
						if (within(pos, zone[1], zone[2])) then
							return false;
						end
					end
				end
			end
		end
	elseif (who ~= nil) then
		if (platform_forbids_building(pos, ps, pe)) then
			return false;
		end
		for t = 1, 2 do
			if (team ~= t) then
				for _, zone in ipairs(zones_of(t)) do
					if (within(pos, zone[1], zone[2])) then
						return false;
					end
				end
			end
		end
	end
	-- what another script protects stays protected (the chain goes on)
	local below = mod.next.may_edit_block;
	return below == nil or below(who, pos, type);
end

function mod.after.tick()
	local now = get_time();
	bots_tick(now);
	if (not babel_camp_marks or teamplay_mark == nil) then
		return;
	end

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
	stairs, bots_next = {}, 0;     -- laid out again on the new map, when bots ask
	told_blueprint, laid_ground = {}, {};
end

function mod.on_load()
	if (teamplay_listen_ready ~= nil) then
		teamplay_listen_ready("babel_plus", on_ready);
	end
end

return mod;
