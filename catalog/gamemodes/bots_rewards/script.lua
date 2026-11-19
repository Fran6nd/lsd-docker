-- The bots mode with every reward free: rockets, missiles, airstrikes and
-- the rest, as often as you like. The rider is bots' own; demo_reward
-- is what makes the rewards free.
return Gamemode {
	title = "Bots, unlimited rewards",
	summary = "Team deathmatch with guard bots, day and night, and every reward free and unlimited.",
	base = "ctf",
	rider = "bots",
	requires = {"daytime", "flashlight", "rewards", "demo_reward"},
	with = {"guards"},
	questions = {
		{key = "tdm_kills", type = "number", default = 50, min = 1, max = 1000,
			ask = "Kills a team needs to win"},
		{key = "guard_count", type = "number", default = 6, min = 0, max = 100,
			ask = "Guard bots per team"},
	},
}
