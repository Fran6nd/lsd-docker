-- engine_bots.lua -- Bots decided by the bot engine, kept at a count per team
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- Nothing here but how many: each bot's behaviour is the engine's, through
-- lib_botlink. Levels are drawn around engine_bots_level, each bot its own
-- seed. Brought to the count once a second, as the guards are -- topped
-- up, and taken down when the count is lowered live; a dead bot still
-- counts. One team may have its own count (engine_bots_team1/_team2):
-- a single bot on one side to try things against, a fleet on the other.
local mod = init_mod();

getcfg("engine_bots_count", 6, "Engine bots kept alive per team.");
getcfg("engine_bots_team1", -1, "Engine bots on team 1 (blue), when not engine_bots_count; -1: that count.");
getcfg("engine_bots_team2", -1, "Engine bots on team 2 (green), when not engine_bots_count; -1: that count.");
getcfg("engine_bots_level", 5, "Skill level (1 to 10) the engine bots are drawn around.");
getcfg("engine_bots_level_spread", 2, "How far a bot's level may fall from that, either way.");

local mine = {}; -- pid -> team

local function count(team)
	local n = 0;
	for pid, t in pairs(mine) do
		if (t == team) then n = n + 1; end
	end
	return n;
end

-- how many a team should have
local function wanted(team)
	local own = tonumber(team == 1 and engine_bots_team1 or engine_bots_team2);
	if (own ~= nil and own >= 0) then
		return math.floor(own);
	end
	return math.max(0, math.floor(tonumber(engine_bots_count) or 0));
end

local function draw_level()
	local s = engine_bots_level_spread;
	local l = engine_bots_level + math.random(-s, s);
	return math.max(1, math.min(10, l));
end

local next_count = 0;
function mod.after.tick()
	local now = get_time();
	if (now < next_count) then return; end
	next_count = now + 1;

	-- drop the ones the server took away (a kick, a reload of lib_bot)
	for pid in pairs(mine) do
		if (bot_is_bot == nil or not bot_is_bot(pid)) then mine[pid] = nil; end
	end

	for team = 1, 2 do
		local n, want = count(team), wanted(team);
		while (n < want) do
			local pid = botlink_add{team = team, level = draw_level(),
				seed = math.random(1, 2147483646)};
			if (pid == nil) then break; end
			mine[pid] = team;
			n = n + 1;
		end
		-- the count was lowered: the surplus leaves
		if (n > want) then
			for pid, t in pairs(mine) do
				if (n <= want) then break; end
				if (t == team) then
					botlink_remove(pid);
					mine[pid] = nil;
					n = n - 1;
				end
			end
		end
	end
end

function mod.on_unload()
	local pids = {};
	for pid in pairs(mine) do pids[#pids+1] = pid; end
	for _, pid in ipairs(pids) do
		if (botlink_remove ~= nil) then botlink_remove(pid); end
	end
	mine = {};
end

return mod;
