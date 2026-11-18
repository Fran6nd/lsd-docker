return Extension {
	title = "Daytime and Weather",
	summary = "Day or night: by night only flashlights light the world.",
	module = "lib_daytime",
	ext_id = 0x33,
	-- by day it changes nothing; by night a client without it sees a
	-- black fog instead of real darkness, and is told so
	policy = function(v) return v.daytime_night == true and "recommended" or "applied"; end,
	presets = {
		{name = "day", summary = "ordinary daylight", values = {daytime_night = false}},
		{name = "night", summary = "full darkness; pair it with the flashlight",
			values = {daytime_night = true}},
	},
}
