-- /votepeace: players vote a peace -- nobody can hurt anybody -- and vote it over.
return Tool {
	title = "Vote peace",
	summary = "/votepeace: players vote a peace where no player can hurt another, and vote it over; /peace says which it is. Bots stand down.",
	module = "vote_peace",
	requires = {"vote"},
	questions = {
		{key = "vote_peace_ratio", type = "number", default = 0.5, min = 0, max = 1,
			ask = "Fraction of the players past which a vote carries"},
	},
}
