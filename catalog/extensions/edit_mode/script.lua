-- The Edit Mode protocol extension: lifted building limits, Block Batch.
--
-- "applied": a client without it plays normally and is never nagged.
-- It only costs that client anything while somebody is in edit mode,
-- and then lib_edit_mode itself benches it and says why.
return Extension {
	title = "Edit Mode",
	summary = "Map editing: no block limits, any reach, blocks in mid-air, Block Batch.",
	module = "lib_edit_mode",
	ext_id = 0x36,
	policy = "applied",
}
