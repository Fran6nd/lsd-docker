-- hostage: free yours from their tent, keep theirs
return {
	theme = {en = "Orders"},
	callouts = {
		{key = "escort", label = {en = "Escort"},
			say = {en = "I have our hostage -- escort us home!"}},
		{key = "loose", label = {en = "Hostage loose"}, ping = true,
			say = {en = "Their hostage is loose here -- catch it!"}},
		{key = "guard", label = {en = "Guard prisoner"},
			say = {en = "Guard the prisoner at our tent!"}},
		{key = "enemy", label = {en = "Enemy here"}, ping = true,
			say = {en = "Enemy here!"}},
		{key = "rescue", label = {en = "Rescue"},
			say = {en = "Go free our hostage!"}},
		{key = "cover", label = {en = "Cover me"},
			say = {en = "Cover me!"}},
	},
	-- the Mark pie, for players whose client shows Teamplay pings
	pings = {
		{key = "hostage", label = {en = "Hostage here"}},
		{key = "enemy", label = {en = "Enemy"}},
		{key = "escort", label = {en = "Escort"}},
		{key = "defend", label = {en = "Defend"}},
	},
};
