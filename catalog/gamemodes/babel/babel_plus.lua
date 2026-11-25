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
--   zone=<platform> both        no route edits under or round the platform
--                               (babel refuses them there)
--   place.stair, place.stair_top, place.stair_foot, place.breach
--                               for each bot, its own team's
--   place.intel                 for everybody
--   fact.stair_done, fact.stair_high, fact.breach, fact.carrying
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
local function lay_stairs()
	local y = 256 - babel_height / 2;
	local x0 = {[1] = 255 - babel_width / 2, [2] = 256 + babel_width / 2};
	local dir = {[1] = -1, [2] = 1};
	stairs = {};
	for team = 1, 2 do
		local steps = {};
		for k = 0, 61 - babel_z do
			local x, z = x0[team] + dir[team] * k, babel_z + 1 + k;
			if (x < 1 or x > 510) then break; end
			local g = ground_at(x, y);
			table.insert(steps, 1, {x = x, y = y, z = z});
			if (z >= g - 1) then break; end
		end
		local b = steps[1];
		stairs[team] = {steps = steps, foot = {x = b.x + dir[team], y = y, z = ground_at(b.x + dir[team], y)}};
	end
end

local function eye(p) return string.format("%.1f %.1f %.1f", p.x + 0.5, p.y + 0.5, p.z - 2.25); end
local function block(p) return string.format("%.1f %.1f %.1f", p.x + 0.5, p.y + 0.5, p.z + 0.5); end

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

local function tell_bots()
	if (not bots_told) then
		bots_told = true;
		botlink_set("edit", "all");
		botlink_set("zone", string.format("%d %d %d %d", 256 - babel_width / 2, 256 - babel_height / 2,
			255 + babel_width / 2, 255 + babel_height / 2));
	end
	if (stairs[1] == nil) then lay_stairs(); end
	local s = {};
	for team = 1, 2 do
		local nextp, top, n = stair_state(team);
		s[team] = {nextp = nextp, top = top, n = n, total = #stairs[team].steps};
	end
	local il = get_1intel_loc ~= nil and get_1intel_loc() or nil;
	local intel = type(il) == "number" and ("pid " .. il)
		or type(il) == "table" and string.format("%.1f %.1f %.1f", il.x, il.y, il.z - 2.25) or "";
	-- the intel is the same for everybody: the world's place (a bot has
	-- room for 4 of its own, and the stair's take them)
	botlink_set("place.intel", intel);
	for pid in piditer(PID_BROADCAST) do
		local team = get_team(pid);
		if (engine_bot(pid) and (team == 1 or team == 2)) then
			local me, them, st = s[team], s[other(team)], stairs[team];
			botlink_set("place.stair", me.nextp and eye(me.nextp) or eye(st.steps[#st.steps]), pid);
			botlink_set("place.stair_top", me.top and eye(me.top) or eye(st.foot), pid);
			botlink_set("place.stair_foot", eye(st.foot), pid);
			botlink_set("fact.stair_done", me.nextp == nil and 1 or 0, pid);
			botlink_set("fact.stair_high", me.total > 0 and me.n / me.total or 0, pid);
			-- their stair, broken at its foot, falls whole
			local foot = stairs[other(team)].steps[1];
			botlink_set("place.breach", block(foot), pid);
			botlink_set("fact.breach", (them.n >= 3 and is_solid(foot)) and 1 or 0, pid);
			botlink_set("fact.carrying", il == pid and 1 or 0, pid);
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

--======================= EFFECTS BREAK NOTHING =======================--
-- A rocket's crater or a railgun is the server breaking blocks, which
-- babel.lua and babel_protect never see: they guard what PLAYERS do.
-- So the same rules again, at the gate every effect goes through
-- (PlayerEffect.break_blocks): the platform is never broken, and a
-- team's tower area is not broken by that team -- nor by the world's
-- own effects, which have no team. A grenade (type 3) reaches one block
-- around its centre, so it is kept that far off, as babel.lua does.
local function near_box(pos, a, b, m)
	return pos.x >= a.x - m and pos.x <= b.x + m and pos.y >= a.y - m and pos.y <= b.y + m;
end

function mod.may_break_block(owner, pos, type)
	local m = (type == 3) and 1 or 0;
	local ps = {x = 256 - babel_width/2, y = 256 - babel_height/2};
	local pe = {x = 255 + babel_width/2, y = 255 + babel_height/2};
	if (pos.z >= babel_z - m and pos.z <= babel_z + m and near_box(pos, ps, pe, m)) then
		return false;
	end
	local mine = owner ~= nil and get_team(owner) or nil;
	for team = 1, 2 do
		if (mine == nil or mine == team) then
			for _, zone in ipairs((babel_protect_zones or {})[team] or {}) do
				if (near_box(pos, zone[1], zone[2], m)) then
					return false;
				end
			end
		end
	end
	-- the end of the chain is lib_player_effect's yes; a server with bots
	-- and no effect has no lib_player_effect, and nothing below this
	local below = mod.next.may_break_block;
	return below == nil or below(owner, pos, type);
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
