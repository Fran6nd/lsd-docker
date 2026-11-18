-- An airstrike called in on a point: a warning, then bombs in a line.
return PlayerEffect {
	title = "Airstrike",
	summary = "Calls in bombs on the point the player aims at, after a warning everybody sees.",
	module = "airstrike",
	requires = {"blast"},
	questions = {
		{key = "airstrike_bombs", type = "number", default = 5, min = 1, max = 15,
			ask = "Bombs in a strike"},
		{key = "airstrike_delay", type = "number", default = 3, min = 0, max = 30,
			ask = "Seconds between the warning and the first bomb"},
		{key = "airstrike_radius", type = "number", default = 4, min = 1, max = 8,
			ask = "Explosion radius of each bomb, in blocks"},
		{key = "airstrike_damage", type = "number", default = 100, min = 1, max = 255,
			ask = "Damage at the centre of each bomb"},
	},
}
