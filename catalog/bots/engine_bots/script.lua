return Bot {
	title = "Engine bots",
	summary = "Bots whose every decision is the bot engine's, kept at a count per team.",
	module = "engine_bots",
	requires = {"botlink"},
	questions = {
		{key = "engine_bots_count", type = "number", default = 6, min = 0, max = 100,
			ask = "Engine bots per team"},
		{key = "engine_bots_level", type = "number", default = 5, min = 1, max = 10,
			ask = "Engine bots' skill level (1 to 10)"},
		{key = "engine_bots_level_spread", type = "number", default = 2, min = 0, max = 9,
			ask = "How far each bot's level may differ from that"},
	},
}
