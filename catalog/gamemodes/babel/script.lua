-- Upstream's babel, protected towers, and our camping marks on top.
return Gamemode {
	title = "Babel",
	summary = "Both teams build one tower to the intel in the sky; the enemy's tower area is off limits.",
	base = "babel",
	rider = "babel_plus",
	-- infinite_blocks: a tower is built, not rationed
	requires = {"babel_protect", "teamplay", "infinite_blocks"},
}
