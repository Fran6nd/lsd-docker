-- arena: rounds of last team standing
return {
	theme = {en = "Orders"},
	callouts = {
		{key = "enemy", label = {en = "Enemy here"},
			say = {en = "Enemy here!"}},
		{key = "last", label = {en = "Last one"},
			say = {en = "Only one of them left!"}},
		{key = "regroup", label = {en = "Regroup"},
			say = {en = "Regroup here!"}},
		{key = "behind", label = {en = "Behind you"},
			say = {en = "Watch behind you!"}},
		{key = "sniper", label = {en = "Sniper"},
			say = {en = "Sniper there!"}},
		{key = "cover", label = {en = "Cover me"},
			say = {en = "Cover me!"}},
	},
	-- the Mark pie, for players whose client shows Teamplay pings
	pings = {
		{key = "enemy", label = {en = "Enemy"}},
		{key = "flank", label = {en = "Flank here"}},
		{key = "hold", label = {en = "Hold here"}},
		{key = "last", label = {en = "Last one here"}},
	},
};
