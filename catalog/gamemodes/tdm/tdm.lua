-- tdm.lua -- Team deathmatch, on ctf's ground
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- ctf underneath, for what a team game needs and the protocol only has
-- in ctf terms: the tents (spawns, restock), the team score the client
-- shows. The intel is not played: it is parked in a corner of the map
-- and nobody can pick it up.
--
-- Every kill of an enemy is a point for the killer's team; a team kill
-- or a suicide is nothing. The score is told in chat every
-- TELL_EVERY kills, and kill by kill near the end. The first team to
-- tdm_kills wins, through capture_intel's winning case -- the client's
-- own victory, then the next map, as a ctf win.
--
-- Why not the scoreboard? capture_intel is the only way to move the
-- team score from Lua, and it is a capture: the jingle and "captured
-- the intel" on every client, and 10 points to the player. Once a game,
-- at the win, that is the right thing; once a kill it is not.
local mod = init_mod();

getcfg("tdm_kills", 50, "Kills a team needs to win.");

local TELL_EVERY = 10;  -- kills between score lines
local CLOSE = 5;        -- the last kills, each told

local score_msg = {
	en = "%(blue) %(b) - %(g) %(green), first to %(limit) kills",
};
local win_msg = {
	en = "%(team) wins, %(b) - %(g)!",
};

-- team -> kills this game
local kills = {[1] = 0, [2] = 0};
local over = false;

local function tell()
	l10n_send_chat(PID_BROADCAST, score_msg, {
		blue = get_team_name(1), green = get_team_name(2),
		b = kills[1], g = kills[2], limit = tdm_kills,
	});
end

-- out of play: a corner, on the ground
local function park_intels()
	drop_move_intel(1, objgrav{x = 0.5, y = 0.5, z = 0});
	drop_move_intel(2, objgrav{x = 511.5, y = 511.5, z = 0});
end

-- not chaining is the veto: ctf's tick asks for every player who walks
-- over an intel, and nobody gets it
function mod.pickup_intel(pid)
end

function mod.after.kill(pid, ktype, killer)
	if (over or killer == nil or killer == pid or not is_connected(killer)) then
		return;
	end
	local team = get_team(killer);
	if (kills[team] == nil or team == get_team(pid)) then
		return;
	end

	kills[team] = kills[team] + 1;
	local n = kills[team];

	if (n >= tdm_kills) then
		over = true;
		l10n_send_chat(PID_BROADCAST, win_msg, {
			team = get_team_name(team), b = kills[1], g = kills[2],
		});
		capture_intel(killer, true);
	elseif (n % TELL_EVERY == 0 or tdm_kills - n <= CLOSE) then
		tell();
	end
end

local function reset()
	kills[1], kills[2] = 0, 0;
	over = false;
end

function mod.after.finish_map_load()
	reset();
	park_intels();
end

function mod.on_load()
	masterlist_set_gamemode("tdm");
	reset();
	park_intels();
end

return mod;
