return Extension {
	title = "Daytime and Weather",
	summary = "Day or night: by night only flashlights light the world.",
	module = "lib_daytime",
	ext_id = 0x33,
	presets = {
		{name = "day", summary = "ordinary daylight", values = {daytime_night = false}},
		{name = "night", summary = "full darkness; pair it with the flashlight",
			values = {daytime_night = true}},
	},
}
