-- Reward points for kills and captures, spent on a player effect of their choice.
return Tool {
	title = "Rewards",
	summary = "Kills and captures earn points to spend on a railgun, rockets, an airstrike... from /reward or the pie menu.",
	module = "lib_rewards",
	-- what it sells, installed with it, so a default server offers
	-- something; rewards_exclusive keeps them for whoever buys them
	with = {"railgun", "rocket", "airstrike", "medkit", "area_heal", "nightvision"},
	questions = {
		{key = "rewards_kills", type = "number", default = 10, min = 1, max = 1000,
			ask = "Kills for one reward point"},
		{key = "rewards_capture", type = "number", default = 1, min = 0, max = 10,
			ask = "Reward points for an intel capture"},
		{key = "rewards_max", type = "number", default = 3, min = 1, max = 20,
			ask = "Most points a player can hold"},
		{key = "rewards_exclusive", type = "boolean", default = true,
			ask = "Rewards are the only way to get the effects they offer (otherwise an effect that is on for everybody stays so)?"},
	},
}
