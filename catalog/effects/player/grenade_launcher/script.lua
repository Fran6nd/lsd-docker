-- A grenade fired hard along the aim, timed to go off where it lands.
return PlayerEffect {
	title = "Grenade launcher",
	summary = "Fires a grenade along the aim, fused to explode the moment it hits.",
	module = "grenade_launcher",
	questions = {
		{key = "grenade_launcher_speed", type = "number", default = 2, min = 0.5, max = 5,
			ask = "Launch speed (a full-strength throw is about 1)"},
	},
}
