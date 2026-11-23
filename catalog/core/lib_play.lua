-- lib_play.lua -- A casual game that ends when its players have gone
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- Loaded only on a server set up by `play` (play_mode): a throwaway
-- container, run with docker run --rm, whose server is not restarted
-- when it exits -- so ending the server ends the container, and Docker
-- removes it and its volume. Nothing is left behind.
--
-- It ends:
--   * play_idle seconds after the last player leaves -- long enough to
--     reconnect, or to ride out a map change;
--   * play_wait seconds after start, if nobody ever joined.
--
-- Players are people: bots (lib_bot) do not keep a game alive. A player
-- still loading the map counts, so a slow join is not left behind.
--
-- The end is os.exit(0), which is what lsdctl's restart does too: the
-- server's on_shutdown unloads every module on the way out.
local mod = init_mod();

getcfg("play_idle", 60,
	"Seconds a play server waits after its last player leaves.");
getcfg("play_wait", 600,
	"Seconds a play server waits for its first player.");

-- checked once a second, which is plenty for minutes of patience
local CHECK = 1;

local started, next_check = nil, 0;
local had_players, empty_since = false, nil;

local function people()
	local n = 0;
	for i = 0, MAX_PLAYERS - 1 do
		if (is_connected(i) and not (bot_is_bot ~= nil and bot_is_bot(i))) then
			n = n + 1;
		end
	end
	return n;
end

-- What to do now, given the time and how many people are here: nil, or
-- the reason to stop. Pure, for the tests.
function play_should_stop(now, n)
	started = started or now;
	if (n > 0) then
		had_players, empty_since = true, nil;
		return nil;
	end
	if (had_players) then
		empty_since = empty_since or now;
		if (now - empty_since >= play_idle) then
			return "the last player left";
		end
	elseif (now - started >= play_wait) then
		return "nobody joined";
	end
	return nil;
end

function mod.after.tick()
	local now = get_time();
	if (now < next_check) then
		return;
	end
	next_check = now + CHECK;

	local why = play_should_stop(now, people());
	if (why ~= nil) then
		log("lib_play: %s -- the game is over", why);
		os.exit(0);
	end
end

return mod;
