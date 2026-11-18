-- The Player Properties protocol extension (id 0). Applied by default:
-- a client without it loses other players' stats from its scoreboard
-- and nothing else, which is not worth nagging anybody about.
return Extension {
	title = "Player Properties",
	summary = "Tells clients every player's HP, blocks, grenades, ammo and score.",
	module = "lib_player_properties",
	ext_id = 0,
	policy = "applied",
}
