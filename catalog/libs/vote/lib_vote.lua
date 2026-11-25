-- lib_vote.lua -- the vote players start and agree to with one command
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- /va (vote_map) and /votepeace (vote_peace) are the same vote: anyone
-- types the command to start it, others type it to agree, a majority of
-- the people playing carries it -- one player alone carries it at once --
-- and it lapses after a while. This is that, once; each script keeps what
-- the vote is FOR, its command and its messages. (/votekick is not one of
-- them: it has a target, its own yes command and a floor of voters.)
--
--   vote_new{started = msg, voted = msg, already = msg, failed = msg,
--            passed = function(pid) end}  -> a vote
--        the messages are {en = "..."} tables the script owns (so its
--        translations stay beside it); started and voted are given
--        name, have and need. `passed` is called when the vote carries:
--        it says so and does the thing.
--   vote:ask(pid, ratio, timeout)
--        pid's voice: starts the vote if none is open (told to everyone),
--        else adds to it. ratio: the fraction of the players past which it
--        carries; timeout: seconds it stays open.
--   vote:is_open()
--   vote_voters() -> how many people can vote: joined, not a bot or the
--        console
--
-- A vote is for the map it was started on: a new map drops it.
local mod = init_mod();

local all = {};   -- every vote made, to lapse and to drop

function vote_voters()
	local n = 0;
	for i in piditer(PID_BROADCAST) do
		if (is_joined(i) and not is_fakepid(i) and not (bot_is_bot ~= nil and bot_is_bot(i))) then
			n = n + 1;
		end
	end
	return n;
end

local Vote = {};
Vote.__index = Vote;

function vote_new(spec)
	local v = setmetatable({spec = spec, open = nil}, Vote);
	all[#all+1] = v;
	return v;
end

function Vote:is_open()
	return self.open ~= nil;
end

function Vote:ask(pid, ratio, timeout)
	local o = self.open;
	if (o ~= nil) then
		if (o.voters[pid]) then
			l10n_send_chat(pid, self.spec.already);
			return;
		end
		o.voters[pid] = true;
		o.count = o.count + 1;
		if (o.count >= o.need) then
			self.open = nil;
			self.spec.passed(pid);
		else
			l10n_send_chat(PID_BROADCAST, self.spec.voted, {name = get_name(pid), have = o.count, need = o.need});
		end
		return;
	end

	local n = math.max(1, vote_voters());
	local need = math.min(n, math.floor(n * ratio) + 1);
	if (need <= 1) then
		self.spec.passed(pid);
		return;
	end
	self.open = {voters = {[pid] = true}, count = 1, need = need, deadline = get_time() + timeout};
	l10n_send_chat(PID_BROADCAST, self.spec.started, {name = get_name(pid), have = 1, need = need});
end

function mod.after.tick()
	local now = get_time();
	for _, v in ipairs(all) do
		if (v.open ~= nil and now >= v.open.deadline) then
			v.open = nil;
			l10n_send_chat(PID_BROADCAST, v.spec.failed);
		end
	end
end

function mod.after.load_map()
	for _, v in ipairs(all) do v.open = nil; end
end

return mod;
