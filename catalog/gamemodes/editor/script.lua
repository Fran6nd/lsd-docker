-- Building a map: a session of its own, not a game. Every player
-- builds; the layout it makes runs in every other gamemode.
return Gamemode {
	title = "Editor",
	summary = "Build a map and its doors, elevators and permissions; /save it.",
	module = "editor",
	requires = {"unrestricted_blocks", "infinite_blocks"},
	settings = {editor_edit_mode = "off"},
}
