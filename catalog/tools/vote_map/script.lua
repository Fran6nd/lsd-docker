-- /va: players vote the map on; a server playing random maps gets a new
-- one from the web.
return Tool {
	title = "Vote map",
	summary = "/va: players vote to move to the next map -- a new random one from the web where the maps are picked at random.",
	module = "vote_map",
	requires = {"vote"},
	questions = {
		{key = "vote_map_ratio", type = "number", default = 0.5, min = 0, max = 1,
			ask = "Fraction of the players past which a vote carries"},
	},
}
