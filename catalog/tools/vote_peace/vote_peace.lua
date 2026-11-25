-- vote_peace.lua -- /votepeace: the players vote a peace, and another vote ends it
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- /votepeace starts a vote, as /va does (lib_vote: a majority of the
-- people playing carries it, one player alone at once, and it lapses after
-- vote_peace_timeout). A vote that carries TOGGLES the peace: no peace,
-- peace begins; at peace, it ends. Everyone is told. /peace says which it
-- is. Without peace nothing here does anything.
--
-- AT PEACE no damage is done by a player, nor by anything a player did:
-- bullets, the spade, grenades, a rocket, an airstrike, a missile, a
-- railgun, an area that hurts, a bot's shot. Only the damage that is
-- a fall's -- KillTypeFall: a fall, wading in water that kills, the map's
-- boundary -- still counts: that is the map's rule, not a player's, and a
-- parkour course or a map whose water kills stays what it was. Healing
-- (a medkit, an area that heals: damage below zero) works as ever.
--
-- It is decided in ONE place: the last of the damage chain, ahead of the
-- core, where the damage a script wanted is what is about to be applied.
-- A script that answers a hit itself before that (the range's targets
-- count a hit and take none, the editor's) is left to: it is not damage
-- to a player, and it never gets this far.
--
-- A player who joins at peace is told. The peace ends with the map: a new
-- map, a new round -- the vote is theirs to make again.
--
-- THE BOTS know it: the engine is told fact.peace (1) -- the shipped trees
-- stand the war down on it: no fights, no grenades, no items used on
-- anyone -- and fire=hold, the server's rule that no shot is fired
-- (bot/TREES.md). Both are forgotten at the peace's end. They are sent
-- only where there are engine bots (lib_botlink answers botlink_set).
local mod = init_mod();

getcfg("vote_peace_ratio", 0.5, "Fraction of the players past which a /votepeace vote carries.");
getcfg("vote_peace_timeout", 60, "Seconds a /votepeace vote stays open.");

local KILL_FALL = 4;     -- KillType, protocol.h

local on_msg = {en = "Peace: nobody can hurt anybody. /votepeace to end it."};
local off_msg = {en = "Peace is over: damage is back."};
local ended_by_map_msg = {en = "New map: peace is over, damage is back."};
local started_msg = {en = "%(name) wants to change the peace (a vote): type /votepeace to agree (%(have)/%(need))."};
local voted_msg = {en = "%(name) agrees to change the peace (%(have)/%(need))."};
local already_msg = {en = "You already voted on the peace."};
local failed_msg = {en = "The vote on the peace failed."};
local welcome_msg = {en = "Peace is on: nobody can hurt anybody. /votepeace to end it."};
local status_on_msg = {en = "Peace is on: nobody can hurt anybody. /votepeace to vote it over."};
local status_off_msg = {en = "No peace: /votepeace to vote one."};

local peace = false;

-- for other scripts, and the tests
function peace_active()
	return peace;
end

--================================ DAMAGE =============================--

-- The last word before the core. Damage to a player is a positive hp;
-- below zero is healing, and passes.
function mod.late.damage_player(pid, hp, type, damager)
	if (peace and hp > 0 and type ~= KILL_FALL) then
		return;
	end
	return mod.late.next.damage_player(pid, hp, type, damager);
end

function mod.late.damage_player_directional(pid, hp, pos, type, damager)
	if (peace and hp > 0 and type ~= KILL_FALL) then
		return;
	end
	return mod.late.next.damage_player_directional(pid, hp, pos, type, damager);
end

--================================= BOTS ==============================--

-- What the engine was last told, and by which botlink_set: a library
-- reloaded under us (a new function) is a new engine to tell.
local told_with, told = nil, false;

local function tell_bots()
	if (botlink_set == nil) then
		told_with, told = nil, false;
		return;
	end
	if (told_with ~= botlink_set) then
		told_with, told = botlink_set, false;
	end
	if (told ~= peace) then
		told = peace;
		botlink_set("fact.peace", peace and 1 or "");
		botlink_set("fire", peace and "hold" or "");
	end
end

--================================ THE VOTE ===========================--

local function set_peace(on, msg)
	peace = on;
	l10n_send_chat(PID_BROADCAST, msg);
	tell_bots();
end

local vote = vote_new{
	started = started_msg, voted = voted_msg, already = already_msg, failed = failed_msg,
	passed = function()
		set_peace(not peace, peace and off_msg or on_msg);
	end,
};

local cmd = {name = {"votepeace", "vpeace"},
	desc = "Vote for a peace, where nobody can hurt anybody -- or, at peace, to end it."};
function cmd.func(pid)
	vote:ask(pid, vote_peace_ratio, vote_peace_timeout);
end
register_command(cmd, mod);

local status = {name = "peace", desc = "Say whether there is peace (nobody can hurt anybody)."};
function status.func(pid)
	l10n_send_chat(pid, peace and status_on_msg or status_off_msg);
end
register_command(status, mod);

--================================ EVENTS =============================--

function mod.after.on_join(pid)
	if (peace and not is_fakepid(pid) and not (bot_is_bot ~= nil and bot_is_bot(pid))) then
		l10n_send_chat(pid, welcome_msg);
	end
end

-- the engine is told again when it comes late, or is replaced
function mod.after.tick()
	tell_bots();
end

-- a vote is for one map (lib_vote drops it), and so is a peace
function mod.after.load_map()
	if (peace) then
		set_peace(false, ended_by_map_msg);
	end
end

return mod;
