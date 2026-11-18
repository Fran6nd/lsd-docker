-- ffa: nobody has a team, so callouts are said to everybody
return {
	theme = {en = "Say"},
	global = true,
	callouts = {
		{key = "gg", label = {en = "Good game"}, say = {en = "gg"}},
		{key = "nice", label = {en = "Nice shot"}, say = {en = "Nice shot!"}},
		{key = "truce", label = {en = "Truce?"}, say = {en = "Truce?"}},
		{key = "come", label = {en = "Come on"}, say = {en = "Come at me!"}},
		{key = "ouch", label = {en = "Ouch"}, say = {en = "Ouch!"}},
		{key = "camper", label = {en = "Camper"}, ping = true,
			say = {en = "Camper over there!"}},
	},
	-- no team to ping for
	pings = {},
};
