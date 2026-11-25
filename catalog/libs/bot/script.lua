-- Server-side bots: creation, movement, aim, shooting, grenades.
return Library {
	title = "Bot library",
	summary = "Server-side bots that every bot script and hostage build on (lib_bot).",
	module = "lib_bot",
	-- a bot digs as itself: edit_as
	requires = {"block_filter"},
	-- after the gamemode and its spawns, which bots spawn into
	phase = "bots",
	questions = {
		{key = "bot_hide_from_masterlist", type = "boolean", default = true,
			ask = "Keep bots out of the player count the server lists see?"},
	},
}
