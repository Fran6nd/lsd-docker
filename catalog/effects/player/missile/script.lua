-- A rocket its sender steers: it flies at whatever they aim at, live.
return PlayerEffect {
	title = "Guided missile",
	summary = "A slower rocket that follows its sender's aim in real time, like a laser-guided missile.",
	module = "missile",
	requires = {"blast"},
	questions = {
		{key = "missile_speed", type = "number", default = 1.2, min = 0.2, max = 4,
			ask = "Blocks a missile flies each tick (slower is easier to steer)"},
		{key = "missile_kill_radius", type = "number", default = 2, min = 0, max = 10,
			ask = "Blocks from the impact within which it kills outright"},
	},
}
