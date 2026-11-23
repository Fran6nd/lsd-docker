-- vote_map.lua -- /va: vote the map on
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- Anyone types /va to start a vote to move on to the next map, and
-- others type /va to agree. A majority of the people playing carries it
-- (vote_map_ratio) -- one person alone carries it at once, a casual game
-- being theirs to skip through. One vote at a time, gone after
-- vote_map_timeout.
--
-- WHERE THE NEXT MAP COMES FROM. On a server whose maps were picked at
-- random (map_web_random: `play ... random`, or the quick setup's
-- random rotation) it is a new random map from the web, from what the
-- map sources list for the game -- not a map seen before. Elsewhere it
-- is the rotation's next (map_queue's advance_map).
--
-- In random mode that holds for EVERY map change, not only /va's: the
-- end of a round, the time limit, an admin's /advance all go through
-- advance_map, which this hooks. The map being played goes on until the
-- new one is here. The first map, at start, is left to the rotation:
-- a server cannot wait for the web before it has a map at all.
--
-- The web is not the server's to reach: its sandbox forbids starting a
-- program, so it cannot run the download itself. It asks the container's
-- entrypoint with a file -- rw/map_request, holding the gamemode -- and
-- the entrypoint (map_helper) runs `lsdctl map web-random`, answering in
-- rw/map_result. Looked for once a second; the game plays on meanwhile.
-- No map within vote_map_fetch_secs, or none to be had: the rotation's
-- next instead.
local mod = init_mod();

getcfg("vote_map_ratio", 0.5, "Fraction of the players past which a /va vote carries.");
getcfg("vote_map_timeout", 60, "Seconds a /va vote stays open.");
getcfg("vote_map_fetch_secs", 60, "Seconds to wait for a new map from the web before taking the rotation's next.");
getcfg("map_web_random", false, "Maps are picked at random from the web: /va fetches a new one (set by lsdctl).");

local RW = (os.getenv("LSD_DATA") or "/data") .. "/rw/";
local REQUEST = RW .. "map_request";
local RESULT = RW .. "map_result";

local started_msg = {en = "%(name) wants the next map: type /va to agree (%(have)/%(need))."};
local voted_msg = {en = "%(name) wants the next map (%(have)/%(need))."};
local already_msg = {en = "You already voted for the next map."};
local passed_msg = {en = "The vote carried: on to the next map."};
local fetching_msg = {en = "Fetching a new map from the web..."};
local no_fetch_msg = {en = "No new map could be had: on to the next one here."};
local failed_msg = {en = "The vote for the next map failed."};
local busy_msg = {en = "A new map is already on its way."};

local vote = nil;     -- {voters = {pid = true}, count, need, deadline}
local fetch = nil;    -- {deadline, next_look}

-- people who can vote: joined, not a bot or the console
local function voters()
	local n = 0;
	for i in piditer(PID_BROADCAST) do
		if (is_joined(i) and not is_fakepid(i) and not (bot_is_bot ~= nil and bot_is_bot(i))) then
			n = n + 1;
		end
	end
	return n;
end

local function read(path)
	local f = io.open(path, "r");
	if (f == nil) then return nil; end
	local s = f:read("*a");
	f:close();
	return s;
end

local function write(path, s)
	local f = io.open(path, "w");
	if (f == nil) then return false; end
	f:write(s);
	f:close();
	return true;
end

-- the rotation's next: map_queue's advance_map, past our hook below
local function next_here()
	mod.next.advance_map();
end

-- a new map from the web: asked of the entrypoint, loaded when it comes
local function from_the_web()
	os.remove(RESULT);
	if (not write(REQUEST, tostring(gamemode or ""))) then
		log("vote_map: cannot write %s; the rotation's next instead", REQUEST);
		next_here();
		return;
	end
	l10n_send_chat(PID_BROADCAST, fetching_msg);
	local now = get_time();
	fetch = {deadline = now + vote_map_fetch_secs, next_look = now + 1};
end

-- Every map change. Random mode, once a map is playing: from the web --
-- one at a time, a second change while one is on its way being that one.
local playing = false;
function mod.advance_map()
	if (map_web_random ~= true or not playing) then
		return mod.next.advance_map();
	end
	if (fetch == nil) then
		from_the_web();
	end
end

local function next_map()
	advance_map();
end

local function cast(pid)
	if (vote.voters[pid]) then
		l10n_send_chat(pid, already_msg);
		return;
	end
	vote.voters[pid] = true;
	vote.count = vote.count + 1;
	if (vote.count >= vote.need) then
		vote = nil;
		l10n_send_chat(PID_BROADCAST, passed_msg);
		next_map();
	else
		l10n_send_chat(PID_BROADCAST, voted_msg, {name = get_name(pid), have = vote.count, need = vote.need});
	end
end

local cmd = {name = {"va", "votemap"},
	desc = "Vote to move on to the next map (a new one from the web where maps are random)."};
function cmd.func(pid)
	if (fetch ~= nil) then
		l10n_send_chat(pid, busy_msg);
		return;
	end
	if (vote ~= nil) then
		cast(pid);
		return;
	end
	local n = math.max(1, voters());
	local need = math.min(n, math.floor(n * vote_map_ratio) + 1);
	-- the starter's own voice, said once: in the start's line
	vote = {voters = {[pid] = true}, count = 1, need = need, deadline = get_time() + vote_map_timeout};
	if (vote.count >= need) then
		vote = nil;
		l10n_send_chat(PID_BROADCAST, passed_msg);
		next_map();
		return;
	end
	l10n_send_chat(PID_BROADCAST, started_msg, {name = get_name(pid), have = 1, need = need});
end
register_command(cmd, mod);

function mod.after.tick()
	local now = get_time();
	if (vote ~= nil and now >= vote.deadline) then
		vote = nil;
		l10n_send_chat(PID_BROADCAST, failed_msg);
	end
	if (fetch == nil or now < fetch.next_look) then
		return;
	end
	fetch.next_look = now + 1;
	local answer = read(RESULT);
	if (answer ~= nil) then
		os.remove(RESULT);
		fetch = nil;
		local name = string.match(answer, "added ([%w_.-]+)%.vxl");
		if (name ~= nil) then
			log("vote_map: loading %s, new from the web", name);
			load_map(name);
		else
			log("vote_map: no map from the web: %s", (string.gsub(answer, "%s+$", "")));
			l10n_send_chat(PID_BROADCAST, no_fetch_msg);
			next_here();
		end
	elseif (now >= fetch.deadline) then
		fetch = nil;
		os.remove(REQUEST);
		log("vote_map: no answer from the web in %d s", vote_map_fetch_secs);
		l10n_send_chat(PID_BROADCAST, no_fetch_msg);
		next_here();
	end
end

-- a vote is for this map: a new one starts afresh. The first map
-- loaded, the server is playing: map changes may wait for the web now.
function mod.after.load_map()
	vote = nil;
	playing = true;
end

return mod;
