return Extension {
	title = "Player Limit",
	summary = "Up to 255 players; a client that cannot take more than 32 watches, told to update.",
	module = "lib_player_limit",
	ext_id = 192,
	order = 10,
	-- 255 seats by default. Above 32, a client without the extension is
	-- outdated: it watches from spectator, is told to update, and is
	-- never shown a player id it cannot hold (lib_player_limit; required
	-- there whatever this says). Up to 32 seats every client copes, and
	-- nothing is asked of anyone.
	policy = function(v)
		return (tonumber(v.player_limit_max) or 255) > 32 and "required" or "applied";
	end,
	questions = {
		{key = "player_limit_max", type = "number", default = 255, min = 1, max = 255,
			ask = "Seats, bots included (255: every player id; 32 or fewer: every client plays, none needs Player Limit)?"},
	},
}
