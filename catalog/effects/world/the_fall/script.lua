-- Uses lib_bot for the fallers, so it loads with the bots.
return WorldEffect {
	title = "The Fall",
	summary = "Die once and you fall down a shaft until you kill your way out.",
	module = "the_fall",
	phase = "late",
	requires = {"bot"},
	questions = {
		{key = "thefall_bots", type = "number", default = 4, min = 0, max = 32,
			ask = "Bots falling down the shaft for players to shoot"},
	},
}
