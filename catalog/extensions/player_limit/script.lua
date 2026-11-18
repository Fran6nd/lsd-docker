return Extension {
	title = "Player Limit",
	summary = "More than 32 players, for the clients that can take it.",
	module = "lib_player_limit",
	ext_id = 192,
	order = 10,
	questions = {
		{key = "player_limit_max", type = "number", default = 254, min = 1, max = 255,
			ask = "How many players may the server seat (above 32, an old client may mishandle high player ids)?"},
	},
}
