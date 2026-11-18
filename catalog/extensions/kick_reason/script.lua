-- The Kick Reason protocol extension (id 194). Applied by default: a
-- client without it is told why it was kicked the old way, by the
-- disconnect code, which is no reason to nag anybody.
return Extension {
	title = "Kick Reason",
	summary = "Tells a kicked or banned player why, in words, as they are disconnected.",
	module = "lib_kick_reason",
	ext_id = 194,
	policy = "applied",
}
