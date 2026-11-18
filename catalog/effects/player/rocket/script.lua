-- Rockets: a streak of blocks flies where the player aims and explodes.
return PlayerEffect {
	title = "Rockets",
	summary = "Shots fire rockets: a fiery trail of blocks, then an explosion that hurts the enemies near it.",
	module = "rocket",
	requires = {"shot_detect", "blast"},
	questions = {
		{key = "rocket_speed", type = "number", default = 2, min = 0.5, max = 8,
			ask = "Rocket speed, in blocks per tick"},
		{key = "rocket_radius", type = "number", default = 3, min = 1, max = 8,
			ask = "Explosion radius, in blocks (damage reaches twice as far)"},
		{key = "rocket_damage", type = "number", default = 90, min = 1, max = 255,
			ask = "Damage at the centre of the explosion"},
		{key = "rocket_range", type = "number", default = 150, min = 10, max = 700,
			ask = "How far a rocket flies, in blocks"},
	},
}
