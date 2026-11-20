-- tdm: every kill counts
return {
	theme = {en = "Orders"},
	callouts = {
		{key = "enemy", label = {en = "Enemy here"},
			say = {en = "Enemy here!"}},
		{key = "push", label = {en = "Push"},
			say = {en = "Push, all together!"}},
		{key = "hold", label = {en = "Hold here"},
			say = {en = "Hold this spot!"}},
		{key = "flank", label = {en = "Flank"},
			say = {en = "Flank them this way!"}},
		{key = "backup", label = {en = "Need backup"},
			say = {en = "I need backup!"}},
		{key = "back", label = {en = "Fall back"},
			say = {en = "Fall back!"}},
	},
	-- the Mark pie, for players whose client shows Teamplay pings
	pings = {
		{key = "enemy", label = {en = "Enemy"}},
		{key = "attack", label = {en = "Attack"}},
		{key = "defend", label = {en = "Defend"}},
		{key = "sniper", label = {en = "Sniper"}},
		{key = "go", label = {en = "Go here"}},
	},
};
