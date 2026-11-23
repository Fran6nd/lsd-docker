-- The server's side of the link to the bot engine (a second process).
return Library {
	title = "Bot engine link",
	summary = "Shares the world with the bot engine and applies what it decides (lib_botlink).",
	module = "lib_botlink",
	-- with lib_bot, which it drives
	phase = "bots",
	requires = {"bot"},
}
