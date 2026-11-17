-- Reads the version handshake and tells lib_bot who is not a person.
return Tool {
	title = "Headless clients",
	summary = "Keeps headless bot clients (aosbot) out of the advertised player count.",
	module = "lib_headless",
	phase = "bots",
	requires = {"bot"},
}
