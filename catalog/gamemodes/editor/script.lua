-- Building a map: a session of its own, not a game. Every player
-- builds; the layout it makes runs in every other gamemode.
return Gamemode {
	title = "Editor",
	summary = "Build a map and its doors, elevators and permissions; /save it.",
	module = "editor",
	-- the tools are in the pie menu
	requires = {"unrestricted_blocks", "infinite_blocks", "pie_menu"},
}
