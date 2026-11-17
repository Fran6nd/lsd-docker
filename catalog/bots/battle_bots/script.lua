return Bot {
	title = "Battle bots",
	summary = "Skilled bots with human-like aim that play the objective.",
	module = "advanced_battle_bot",
	questions = {
		{key = "abb_count", type = "number", default = 4, min = 0, max = 64,
			ask = "Battle bots per team"},
	},
}
