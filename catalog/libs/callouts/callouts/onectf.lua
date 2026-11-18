-- onectf: one intel in the middle, both teams after it
return {
	theme = {en = "Orders"},
	callouts = {
		{key = "enemy", label = {en = "Enemy here"}, ping = true,
			say = {en = "Enemy here!"}},
		{key = "grab", label = {en = "Grab intel"},
			say = {en = "Grab the intel!"}},
		{key = "carrier", label = {en = "Stop carrier"},
			say = {en = "They have the intel -- stop the carrier!"}},
		{key = "cover", label = {en = "I have intel"},
			say = {en = "I have the intel -- cover me!"}},
		{key = "defend", label = {en = "Defend base"},
			say = {en = "Defend our base!"}},
		{key = "sniper", label = {en = "Sniper"}, ping = true,
			say = {en = "Sniper there!"}},
	},
	-- the Mark pie, for players whose client shows Teamplay pings
	pings = {
		{key = "enemy", label = {en = "Enemy"}},
		{key = "intel", label = {en = "Intel here"}},
		{key = "attack", label = {en = "Attack"}},
		{key = "defend", label = {en = "Defend"}},
		{key = "build", label = {en = "Build here"}},
		{key = "sniper", label = {en = "Sniper"}},
	},
};
