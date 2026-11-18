-- Rides on ctf: its tents, spawns and restock, the intel parked out of
-- play, and every kill a point.
return Gamemode {
	title = "Team deathmatch",
	summary = "Two teams; every kill scores, first to the kill limit wins.",
	base = "ctf",
	rider = "tdm",
	questions = {
		{key = "tdm_kills", type = "number", default = 50, min = 1, max = 1000,
			ask = "Kills a team needs to win"},
	},
}
