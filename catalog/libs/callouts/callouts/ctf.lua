-- ctf: take their intel home, keep ours
return {
	theme = {en = "Orders"},
	callouts = {
		{key = "enemy", label = {en = "Enemy here"}, ping = true,
			say = {en = "Enemy here!"}},
		{key = "cover", label = {en = "I have intel"},
			say = {en = "I have their intel -- cover me!"}},
		{key = "stolen", label = {en = "Intel stolen"},
			say = {en = "They took our intel -- get it back!"}},
		{key = "defend", label = {en = "Defend base"},
			say = {en = "Defend our base!"}},
		{key = "sniper", label = {en = "Sniper"}, ping = true,
			say = {en = "Sniper there!"}},
		{key = "push", label = {en = "Push"},
			say = {en = "Push forward, go for their intel!"}},
	},
};
