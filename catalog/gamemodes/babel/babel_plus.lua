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
--   place.stair, place.stair_top, place.stair_foot, place.widen,
--   place.prop, place.breach    each team's, as the world's "<name>@<team>"
--   fact.stair_done, fact.stair_high, fact.widen, fact.prop, fact.breach
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
local bots_next, bots_told = 0, false;
local stairs = {};          -- team -> {steps = {{x, y, z}...} bottom first, foot = {x, y, z}}

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

-- the top of the GROUND in a column: of the solid run that goes down to
-- the bottom of the map (a tree, a rock arch or a floating island over
-- it is not ground: a stair that started on one could not be got to)
local function ground_at(x, y)
	local z = 62;
	while (z > 0 and is_solid({x = x, y = y, z = z - 1})) do z = z - 1; end
	if (not is_solid({x = x, y = y, z = 62})) then return 63; end
	return z;
end

-- each team's stair: step k at (corner x -/+ k, edge row, babel_z + 1 + k)
-- from the top (k = 0, a step up from the platform's level) down to the
-- step that rests on the ground
-- One team's stair along row y, from the top down to the ground, and how
-- many voxels in its way: in a step's cell or the three over it (where a
-- body stands) and not the ground under the last step. A stair runs
-- through the team's own protected area, where babel_protect lets nobody
-- break his own team's blocks: what is in the way there stays in the way.
local function stair_on_row(team, y)
	local x0 = team == 1 and 255 - babel_width / 2 or 256 + babel_width / 2;
	local dir = team == 1 and -1 or 1;
	local steps, blocked = {}, 0;
	for k = 0, 61 - babel_z do
		local x, z = x0 + dir * k, babel_z + 1 + k;
		if (x < 1 or x > 510) then break; end
		local g = ground_at(x, y);
		table.insert(steps, 1, {x = x, y = y, z = z});
		for zz = z - 3, z do
			if (zz >= 0 and zz < g and is_solid({x = x, y = y, z = zz})) then blocked = blocked + 1; end
		end
		if (z >= g - 1) then break; end
	end
	local b = steps[1];
	return {steps = steps, foot = {x = b.x + dir, y = y, z = ground_at(b.x + dir, y)}}, blocked;
end

-- Each team's stair on the row beside the platform that has nothing in
-- its way, the nearest the platform's middle row first; on the one with
-- the least, if none is clear. Not the platform's two edge rows: the
-- protected areas' borders are painted on them (babel_protect).
local function lay_stairs()
	stairs = {};
	for team = 1, 2 do
		local best, least = nil, math.huge;
		local y0, y1 = 256 - babel_height / 2 + 1, 255 + babel_height / 2 - 1;
		for i = 0, y1 - y0 do
			-- out from the middle row: 0, +1, -1, +2, ...
			local y = math.floor((y0 + y1) / 2) + (i % 2 == 0 and i / 2 or -(i + 1) / 2);
			if (y >= y0 and y <= y1) then
				local st, blocked = stair_on_row(team, y);
				if (blocked < least) then best, least = st, blocked; end
				if (blocked == 0) then break; end
			end
		end
		-- beside it, a second row to WIDEN it (the side with less in its
		-- way, inside the rows a stair may take) and, on the other side,
		-- the row its PROPS rise on
		local y = best.steps[1].y;
		local up = y + 1 <= y1 and select(2, stair_on_row(team, y + 1)) or math.huge;
		local down = y - 1 >= y0 and select(2, stair_on_row(team, y - 1)) or math.huge;
		best.wide_y = up <= down and y + 1 or y - 1;
		best.prop_y = 2 * y - best.wide_y;
		stairs[team] = best;
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
-- built from the bottom, how many built
local function stair_state(team)
	local st = stairs[team];
	local nextp, top, n = nil, nil, 0;
	for _, p in ipairs(st.steps) do
		if (is_solid(p)) then
			n = n + 1;
			if (nextp == nil) then top = p; end
		elseif (nextp == nil) then
			nextp = p;
		end
	end
	return nextp, top, n;
end

-- THE STAIR AS BOTS BUILD IT is a band two voxels deep: each step and the
-- voxel under it (its riser), face to face with the next column's. Dug
-- anywhere it holds only by its foot, and all above the cut falls (the
-- server's cull). Two ways to make it hold:
--   WIDEN: the same band on the row beside it, a block at a time (put_at),
--     bottom first: a block dug from one row leaves the other holding it.
--   PROP: a pillar from the ground beside a column, up to its step's
--     level (where it meets the step face to face), built standing on it
--     as it rises (build_at on its next block): a cut drops no more than
--     the stretch up to the next prop. The next prop goes under the
--     middle of the longest stretch with none -- a cut's worst, halved.
-- The other team's stair is broken where it is weakest: in the middle of
-- its longest stretch without a prop (the engine's dig_weakest picks the
-- block there whose removal drops the most).

-- one row's band, bottom first: {x, y, z} cells under the ground left out
local function band(st, y)
	local cells = {};
	for _, p in ipairs(st.steps) do
		local g = ground_at(p.x, y);
		if (p.z + 1 < g) then cells[#cells + 1] = {x = p.x, y = y, z = p.z + 1}; end
		if (p.z < g) then cells[#cells + 1] = {x = p.x, y = y, z = p.z}; end
	end
	return cells;
end

local function first_missing(cells)
	for _, c in ipairs(cells) do
		if (not is_solid(c)) then return c; end
	end
end

-- a prop's cells beside the step p, from the ground up to the step's level
local function prop_cells(st, p)
	local cells = {};
	for z = ground_at(p.x, st.prop_y) - 1, p.z, -1 do
		cells[#cells + 1] = {x = p.x, y = st.prop_y, z = z};
	end
	return cells;
end

-- the step in the middle of the longest stretch of the stair as built
-- that is held by nothing but the stair below it (a step is held when its
-- riser stands on the ground, or a whole prop stands beside it; one not
-- built yet is no part of it); nil when there is none
local function weakest_stretch(st)
	local best, run, from = 0, 0, nil;
	local mid = nil;
	for i, p in ipairs(st.steps) do
		local held = not is_solid(p) or p.z + 2 >= ground_at(p.x, p.y) or first_missing(prop_cells(st, p)) == nil;
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
	local s = {};
	for team = 1, 2 do
		local nextp, top, n = stair_state(team);
		s[team] = {nextp = nextp, top = top, n = n, total = #stairs[team].steps};
	end
	local il = get_1intel_loc ~= nil and get_1intel_loc() or nil;
	local intel = type(il) == "number" and ("pid " .. il)
		or type(il) == "table" and point(il.x, il.y, il.z - 2.25) or "";
	botlink_set("place.intel", intel);
	-- where it is put back (babel's putback: the platform's middle)
	botlink_set("place.intel_home", point(256.5, 256.5, babel_z - 2.25));
	for team = 1, 2 do
		local me, them, st = s[team], s[other(team)], stairs[team];
		tell_team(team, "place.stair", me.nextp and eye(me.nextp) or eye(st.steps[#st.steps]));
		tell_team(team, "place.stair_top", me.top and eye(me.top) or eye(st.foot));
		tell_team(team, "place.stair_foot", eye(st.foot));
		tell_team(team, "fact.stair_done", me.nextp == nil and 1 or 0);
		tell_team(team, "fact.stair_high", me.total > 0 and me.n / me.total or 0);
		-- ours: the next block of the second row, and of the next prop
		local w = first_missing(band(st, st.wide_y));
		tell_team(team, "place.widen", w and block(w) or "");
		tell_team(team, "fact.widen", w and 1 or 0);
		local weak = weakest_stretch(st);
		local pc = weak and first_missing(prop_cells(st, weak)) or nil;
		tell_team(team, "place.prop", pc and eye(pc) or "");
		tell_team(team, "fact.prop", pc and 1 or 0);
		-- theirs: where it is weakest (its foot, if every stretch is held)
		local ts = stairs[other(team)];
		local at = weakest_stretch(ts) or ts.steps[1];
		tell_team(team, "place.breach", block(at));
		tell_team(team, "fact.breach", them.n >= 3 and 1 or 0);
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
end

function mod.on_load()
	if (teamplay_listen_ready ~= nil) then
		teamplay_listen_ready("babel_plus", on_ready);
	end
end

return mod;
