return Bot {
	title = "Guards",
	summary = "Combat bots that roam, pursue and fight for each team.",
	module = "bot_standard",
	-- lit while alive, where the flashlight is installed
	after = {"flashlight"},
	questions = {
		{key = "guard_count", type = "number", default = 5, min = 0, max = 100,
			ask = "Guard bots per team"},
		{key = "guard_flashlight", type = "boolean", default = false,
			ask = "Guards carry a lit flashlight (needs the flashlight extension)?"},
	},
}
