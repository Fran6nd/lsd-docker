-- votekick.lua -- Player-driven kick votes.
--
-- Any in-game player can start a vote with /votekick <player>; others
-- add their voice with /y (or /votekick again). Reach the needed count
-- -- a majority of the humans present -- and the target is kicked. One
-- vote runs at a time and it expires after votekick_timeout.
--
-- Commands need no cap, so everyone can vote. Players holding the
-- "kick" cap (admins/mods) or "votekick_immune" can't be targeted, and
-- votekicks are refused below votekick_min_players so a near-empty
-- server can't gang up on one person.
local mod = init_mod();

getcfg("votekick_ratio", 0.5);      -- fraction of players past which a kick carries
getcfg("votekick_min_votes", 2);    -- never kick on fewer yes votes than this
getcfg("votekick_min_players", 3);  -- refuse votekicks below this many humans
getcfg("votekick_timeout", 60);     -- seconds a vote stays open

-- the single active vote, or nil
local vote = nil; -- {target, tname, voters={pid=true}, count, need, deadline}

local started_msg = {
	en="%(starter) started a votekick against %(target)! Type /y to vote (%(have)/%(need)).",
	fr="%(starter) lance un votekick contre %(target) ! Tapez /y pour voter (%(have)/%(need)).",
};
local voted_msg = {
	en="%(voter) voted to kick %(target) (%(have)/%(need)).",
	fr="%(voter) a vote pour exclure %(target) (%(have)/%(need)).",
};
local kicked_msg = {
	en="%(target) was votekicked.",
	fr="%(target) a ete exclu par vote.",
};
local failed_msg = {
	en="The votekick against %(target) failed.",
	fr="Le votekick contre %(target) a echoue.",
};
local already_voted_msg = {
	en="You already voted.", fr="Vous avez deja vote.",
};
local no_vote_msg = {
	en="No votekick is in progress -- start one with /votekick <player>.",
	fr="Aucun votekick en cours -- lancez-en un avec /votekick <joueur>.",
};
local not_enough_msg = {
	en="Not enough players for a votekick.",
	fr="Pas assez de joueurs pour un votekick.",
};
local self_msg = {
	en="You can't votekick yourself.", fr="Vous ne pouvez pas vous auto-exclure.",
};
local protected_msg = {
	en="%(target) can't be votekicked.", fr="%(target) ne peut pas etre exclu par vote.",
};

-- humans who can vote: joined, real (a peerless slot is a bot/console)
local function eligible_voters()
	local n = 0;
	for i in piditer(PID_BROADCAST) do
		if (is_joined(i) and not is_fakepid(i) and get_ipaddr(i) ~= 0) then
			n = n + 1;
		end
	end
	return n;
end

-- add pid's yes vote to the running tally; kick when it carries
local function cast(pid)
	if (vote.voters[pid]) then
		l10n_send_chat(pid, already_voted_msg);
		return;
	end
	vote.voters[pid] = true;
	vote.count = vote.count + 1;

	if (vote.count >= vote.need) then
		l10n_send_chat(PID_BROADCAST, kicked_msg, {target=vote.tname});
		local target = vote.target;
		vote = nil;
		disconnect(target, 2);
	else
		l10n_send_chat(PID_BROADCAST, voted_msg, {voter=get_name(pid),
			target=vote.tname, have=vote.count, need=vote.need});
	end
end

local cmd = {name={"votekick", "vk"}, usage="player",
             desc="Start (or add your voice to) a vote to kick a player."};
function cmd.func(pid, argv)
	-- a vote already runs? this is just another yes voice
	if (vote ~= nil) then
		cast(pid);
		return;
	end

	cmd_assert(pid, cmd, #argv == 1);
	local target = get_arg_pid("player", pid, cmd, argv[1]);

	local eligible = eligible_voters();
	if (eligible < votekick_min_players) then
		l10n_send_chat(pid, not_enough_msg);
		return;
	end
	if (target == pid) then
		l10n_send_chat(pid, self_msg);
		return;
	end
	if (has_cap(target, "kick") or has_cap(target, "votekick_immune")) then
		l10n_send_chat(pid, protected_msg, {target=get_name(target)});
		return;
	end

	local need = math.floor(eligible * votekick_ratio) + 1;
	if (need < votekick_min_votes) then need = votekick_min_votes; end
	if (need > eligible) then need = eligible; end

	vote = {target=target, tname=get_name(target), voters={}, count=0,
	        need=need, deadline=get_time()+votekick_timeout};

	l10n_send_chat(PID_BROADCAST, started_msg, {starter=get_name(pid),
		target=vote.tname, have=0, need=need});
	cast(pid); -- the starter's own vote
end
register_command(cmd, mod);

local cmd = {name={"y", "yes"}, desc="Vote yes on the current votekick."};
function cmd.func(pid)
	if (vote == nil) then
		l10n_send_chat(pid, no_vote_msg);
		return;
	end
	cast(pid);
end
register_command(cmd, mod);

-- drop a vote if its target leaves on their own
function mod.after.on_disconnect(pid)
	if (vote ~= nil and vote.target == pid) then
		vote = nil;
	end
end

-- expire a stale vote
function mod.after.tick()
	if (vote ~= nil and get_time() >= vote.deadline) then
		l10n_send_chat(PID_BROADCAST, failed_msg, {target=vote.tname});
		vote = nil;
	end
end

return mod;
