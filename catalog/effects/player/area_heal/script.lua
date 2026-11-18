-- Heals the teammates near a player: on its own every few seconds, or
-- when a gamemode sets it off.
return PlayerEffect {
	title = "Area heal",
	summary = "Teammates near a player get health back.",
	module = "area_heal",
	questions = {
		{key = "area_heal_radius", type = "number", default = 8, min = 1, max = 64,
			ask = "Radius, in blocks"},
		{key = "area_heal_amount", type = "number", default = 5, min = 1, max = 100,
			ask = "Health given each time"},
		{key = "area_heal_every", type = "number", default = 2, min = 0, max = 600,
			ask = "Seconds between heals on its own (0: only when a gamemode sets it off)"},
	},
}
