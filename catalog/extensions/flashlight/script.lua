-- The Flashlight protocol extension, with looks to pick from.
return Extension {
	title = "Flashlight",
	summary = "Server-controlled flashlights: the F key, beam shape and colour.",
	module = "lib_flashlight",
	ext_id = 0x32,
	-- a client without it has no light, and needs none by day
	policy = "applied",
	presets = {
		{name = "default",
			summary = "OpenSpades' warm white beam, seen by everybody",
			values = {
				flashlight_visibility = "all",
				flashlight_colors = "fixed",
				flashlight_red = 255, flashlight_green = 179, flashlight_blue = 128,
				flashlight_reach = 60, flashlight_cone = 90,
			}},
		{name = "night_vision",
			summary = "a green beam only its carrier sees: nobody spots your light",
			values = {
				flashlight_visibility = "self",
				flashlight_colors = "fixed",
				flashlight_red = 40, flashlight_green = 255, flashlight_blue = 64,
				flashlight_reach = 70, flashlight_cone = 100,
			}},
		{name = "disco",
			summary = "every player's beam a random colour, changing as they play",
			values = {
				flashlight_visibility = "all",
				flashlight_colors = "random",
				flashlight_reach = 60, flashlight_cone = 90,
			}},
	},
	questions = {
		{key = "flashlight_blast", type = "boolean", default = false,
			ask = "Make nearby grenade blasts shake beams into a flicker?"},
	},
}
