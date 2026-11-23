-- A green light only its carrier sees: the F key, for the players who
-- have it. Drawn by the night script (its flashlight), which must be installed.
return PlayerEffect {
	title = "Night vision",
	summary = "F lights a green beam only its carrier sees (needs the night script).",
	module = "nightvision",
	questions = {
		{key = "nightvision_reach", type = "number", default = 70, min = 1, max = 255,
			ask = "Blocks the green light reaches"},
		{key = "nightvision_cone", type = "number", default = 120, min = 1, max = 179,
			ask = "Width of the light, in degrees"},
		{key = "nightvision_only", type = "boolean", default = false,
			ask = "Only players with night vision may switch a light on?"},
	},
}
