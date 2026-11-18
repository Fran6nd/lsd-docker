-- Rides on ctf, scores like tdm, and plays the guard bots through a
-- day that turns to night and back.
return Gamemode {
	title = "Bots",
	summary = "Team deathmatch against and alongside guard bots, day then night then day.",
	base = "ctf",
	rider = "bots",
	requires = {"daytime", "flashlight"},
	-- installed with the mode but loaded after its rider, which only sets
	-- what the guards read
	with = {"guards"},
	questions = {
		{key = "tdm_kills", type = "number", default = 50, min = 1, max = 1000,
			ask = "Kills a team needs to win"},
		{key = "guard_count", type = "number", default = 6, min = 0, max = 100,
			ask = "Guard bots per team"},
		{key = "bots_day_secs", type = "number", default = 240, min = 10, max = 3600,
			ask = "Seconds of day"},
		{key = "bots_night_secs", type = "number", default = 180, min = 10, max = 3600,
			ask = "Seconds of night"},
	},
}
