-- One map, ext_policy, says what every extension costs a client that
-- lacks it; each Extension's setup writes its own entry.
return Library {
	title = "Extension policy",
	summary = "What a client missing an extension costs: nothing, a notice, or spectator.",
	module = "lib_ext_policy",
	-- an extension, by load position: after the two it can use to tell
	-- a client what it is missing, before the rest
	phase = "extensions",
	order = 30,
	after = {"player_limit", "message_types"},
	requires = {"ext"},
}
