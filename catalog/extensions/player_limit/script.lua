return Extension {
	title = "Player Limit",
	summary = "More than 32 players, for the clients that can take it.",
	module = "lib_player_limit",
	ext_id = 192,
	order = 10,
	-- Up to 32 seats every client copes, and nothing is asked of anyone.
	-- Above, a client without the extension watches from spectator, and
	-- is never shown a player id it cannot hold (lib_player_limit).
	policy = function(v)
		return (tonumber(v.player_limit_max) or 32) > 32 and "required" or "applied";
	end,
	questions = {
		{key = "player_limit_max", type = "number", default = 32, min = 1, max = 255,
			ask = "How many players may the server seat (above 32, clients without Player Limit can only watch)?"},
	},
}
