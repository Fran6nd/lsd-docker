-- The Pie Menu protocol extension: the server decides what is on the
-- ring a player opens around the crosshair.
return Extension {
	title = "Pie Menu",
	summary = "A server-chosen pie menu: quick chat, pings and player commands.",
	module = "lib_pie_menu",
	ext_id = 0x31,
	-- A client without it keeps its own menu, or has none; it loses a
	-- convenience and nothing it needs, so it is not told off for it.
	policy = "applied",
	presets = {
		{name = "default",
			summary = "the server's menu: pie_menu from the settings if set, "
				.. "else a built-in one from the commands this server has",
			values = {pie_menu_mode = "server"}},
		{name = "none",
			summary = "no pie menu at all; the client's own is switched off too",
			values = {pie_menu_mode = "none"}},
		{name = "client",
			summary = "send nothing: every client keeps its own menu",
			values = {pie_menu_mode = "client"}},
	},
}
