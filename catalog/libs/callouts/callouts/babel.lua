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
		{key = "intel", label = {en = "Intel here"}},
	},
	-- the Build pie: no prefabs in babel, its building is the tower -- a
	-- stair: a leader (every person is one) pings the spot to reach (a
	-- platform's edge, a pillar's top), his squad of bots builds a stair
	-- from the ground up to it
	builds = {
		{key = "stairs", label = {en = "Build stairs here"},
			tooltip = {en = "Your squad of bots builds a stair up to here"}},
	},
};
