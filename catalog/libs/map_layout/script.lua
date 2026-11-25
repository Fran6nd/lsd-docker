-- A map's doors, elevators and edit permissions, run in every gamemode.
-- Every Gamemode requires it; the editor gamemode makes the layouts.
return Library {
	title = "Map layout",
	summary = "Runs a map's doors, elevators and permissions (lib_map_layout).",
	module = "lib_map_layout",
	-- its doors draw as the server (server_edit) and keep others off them
	requires = {"block_filter"},
}
