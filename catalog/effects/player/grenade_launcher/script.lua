-- A grenade fired hard along the aim, timed to go off where it is aimed.
return PlayerEffect {
	title = "Grenade launcher",
	summary = "Fires a grenade that explodes where you aim, up to 40 blocks away, or on whatever it hits first.",
	module = "grenade_launcher",
	-- blast_aim: the point under the crosshair
	requires = {"blast"},
	questions = {
		{key = "grenade_launcher_speed", type = "number", default = 2, min = 0.5, max = 5,
			ask = "Launch speed (a full-strength throw is about 1)"},
	},
}
