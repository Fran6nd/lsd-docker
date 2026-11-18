-- Hurts the enemies near a player: on its own every few seconds, or
-- when a gamemode sets it off.
return PlayerEffect {
	title = "Area hurt",
	summary = "Enemies near a player take damage, dealt as that player.",
	module = "area_hurt",
	questions = {
		{key = "area_hurt_radius", type = "number", default = 6, min = 1, max = 64,
			ask = "Radius, in blocks"},
		{key = "area_hurt_amount", type = "number", default = 5, min = 1, max = 100,
			ask = "Damage dealt each time"},
		{key = "area_hurt_every", type = "number", default = 2, min = 0, max = 600,
			ask = "Seconds between hits on its own (0: only when a gamemode sets it off)"},
	},
}
