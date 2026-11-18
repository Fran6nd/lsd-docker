-- babel: build a tower to the enemy's intel, and stop theirs
return {
	theme = {en = "Babel"},
	callouts = {
		{key = "digger", label = {en = "Digger!"}, ping = true,
			say = {en = "We have a digger at our tower -- stop them!"}},
		{key = "build", label = {en = "Help build"}, ping = true,
			say = {en = "Help me build here!"}},
		{key = "rush", label = {en = "Rush intel"},
			say = {en = "Rush their intel!"}},
		{key = "defend", label = {en = "Defend tower"},
			say = {en = "Defend our tower!"}},
		{key = "enemy", label = {en = "Enemy here"}, ping = true,
			say = {en = "Enemy here!"}},
		{key = "blocks", label = {en = "Break theirs"}, ping = true,
			say = {en = "Break their tower here!"}},
	},
};
