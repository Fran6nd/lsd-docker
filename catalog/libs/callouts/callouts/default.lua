-- the pings of a gamemode that has none of its own (the editor,
-- upstream's modes): only pings, no callouts pie
return {
	pings = {
		{key = "enemy", label = {en = "Enemy"}},
		{key = "attack", label = {en = "Attack"}},
		{key = "defend", label = {en = "Defend"}},
		{key = "help", label = {en = "Need help"}},
		{key = "danger", label = {en = "Danger"}},
		{key = "go", label = {en = "Go here"}},
	},
	-- the Build pie (every mode's that says none of its own): a leader's
	-- order to the bots of his squad, a structure of the bot engine's
	builds = {
		{key = "mirador", label = {en = "Build mirador here"},
			tooltip = {en = "Your squad of bots builds a watchtower here"}},
		{key = "bunker", label = {en = "Build bunker here"},
			tooltip = {en = "Your squad of bots builds a bunker here"}},
	},
};
