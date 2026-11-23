-- Rewards for kills and captures: a random effect, kept in the inventory.
return Tool {
	title = "Rewards",
	summary = "Kills and captures earn a railgun, a rocket, an airstrike... kept in the inventory and used from /inv or the pie menu.",
	module = "lib_rewards",
	-- where a reward is kept and used from
	requires = {"inventory"},
	-- what it hands out, installed with it, so a default server offers
	-- something; rewards_exclusive keeps them for whoever earns them
	with = {"railgun", "rocket", "missile", "grenade_launcher", "airstrike", "medkit", "ammo_box", "area_heal", "nightvision"},
	questions = {
		{key = "rewards_enabled", type = "boolean", default = true,
			ask = "Rewards on (off: nothing is earned, and their effects stay nobody's)?"},
		{key = "rewards_free", type = "boolean", default = false,
			ask = "Every reward free and unlimited for everybody?"},
		{key = "rewards_kills", type = "number", default = 10, min = 1, max = 1000,
			ask = "Kills for one reward"},
		{key = "rewards_capture", type = "number", default = 1, min = 0, max = 10,
			ask = "Rewards for an intel capture"},
		{key = "rewards_max", type = "number", default = 3, min = 1, max = 20,
			ask = "Most rewards a player can hold"},
		{key = "rewards_exclusive", type = "boolean", default = true,
			ask = "Rewards are the only way to get the effects they offer (otherwise an effect that is on for everybody stays so)?"},
	},
}
