return PlayerEffect {
	title = "Pinning SMG",
	summary = "SMG hits root their target in place, and the SMG never runs dry.",
	module = "smg_is_incapacitating",
	questions = {
		{key = "smg_freeze_secs", type = "number", default = 0.6, min = 0, max = 5,
			ask = "Seconds one SMG hit roots its target"},
	},
}
