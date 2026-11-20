-- babel: build a tower to the enemy's intel, and stop theirs
return {
	theme = {en = "Babel"},
	callouts = {
		{key = "digger", label = {en = "Digger!"},
			say = {en = "We have a digger at our tower -- stop them!"}},
		{key = "build", label = {en = "Help build"},
			say = {en = "Help me build here!"}},
		{key = "rush", label = {en = "Rush intel"},
			say = {en = "Rush their intel!"}},
		{key = "defend", label = {en = "Defend tower"},
			say = {en = "Defend our tower!"}},
		{key = "enemy", label = {en = "Enemy here"},
			say = {en = "Enemy here!"}},
		{key = "blocks", label = {en = "Break theirs"},
			say = {en = "Break their tower here!"}},
	},
	-- the Mark pie, for players whose client shows Teamplay pings
	pings = {
		{key = "enemy", label = {en = "Enemy"}},
		{key = "digger", label = {en = "Digger here"}},
		{key = "build", label = {en = "Build here"}},
		{key = "attack", label = {en = "Attack"}},
		{key = "tower", label = {en = "Defend the tower"}},
	},
};
