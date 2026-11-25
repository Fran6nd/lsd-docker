-- range: one team, targets, the clock
return {
	theme = {en = "Say"},
	callouts = {
		{key = "nice", label = {en = "Nice shot"},
			say = {en = "Nice shot!"}},
		{key = "turn", label = {en = "Your turn"},
			say = {en = "Your turn!"}},
		{key = "watch", label = {en = "Watch this"},
			say = {en = "Watch this!"}},
		{key = "beat", label = {en = "Beat that"},
			say = {en = "Beat that!"}},
		{key = "gg", label = {en = "Good game"},
			say = {en = "gg"}},
	},
	-- the Mark pie, for players whose client shows Teamplay pings
	pings = {
		{key = "target", label = {en = "Target"}},
	},
};
