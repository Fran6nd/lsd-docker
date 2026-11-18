-- editor/pies.lua -- The editor's tools, in the pie menu
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Three pies, added before the default layout's so a builder's first
-- flick is a tool: Select and Place when aiming at a block, Map anywhere.
-- Each wedge sends a command; %b is the block the player aims at, filled
-- in by the client (zerospades PieMenu.cpp ExpandPieText), so a corner
-- or a mark lands exactly where they look, with no click to pick it.
--
-- The usual sequence: Corner 1, Corner 2 (a box), then Fill, Remove or
-- Paint it -- or Door or Elevator, which take that box as theirs. An
-- elevator then wants the height it travels to: aim there, Mark here.
--
-- Spectators get them too (contexts "spectator"): flying is the natural
-- way to build, and a spectator's aim still names a block.
--
-- Slice 1 is the top, then clockwise. Labels are messages, translated in
-- this script's locales/<lang>.po.
return {
	{id = "edit_select", theme = {en = "Select"}, when = "block spectator",
	 slices = {
		{text = "/sel1 %b", label = {en = "Corner 1"},
			tooltip = {en = "Start the selection at the block you aim at"}},
		{text = "/sel2 %b", label = {en = "Corner 2"},
			tooltip = {en = "End the selection at the block you aim at"}},
		{text = "/selfill", label = {en = "Fill"},
			tooltip = {en = "Fill the selection with your colour"}},
		{text = "/unsel", label = {en = "Deselect"}},
		{text = "/selrm", label = {en = "Remove"},
			tooltip = {en = "Remove every block in the selection"}},
		{text = "/selpaint", label = {en = "Paint"},
			tooltip = {en = "Paint the selection's blocks in your colour"}},
	}},
	{id = "edit_place", theme = {en = "Place"}, when = "block spectator",
	 slices = {
		{text = "/place door up", label = {en = "Door, up"},
			tooltip = {en = "The selection becomes a door that opens upwards"}},
		{text = "/place door left", label = {en = "Door, aside"},
			tooltip = {en = "The selection becomes a door that slides aside"}},
		{text = "/marks %b", label = {en = "Mark here"},
			tooltip = {en = "Mark the block you aim at, e.g. an elevator's height"}},
		{text = "/delete", label = {en = "Delete"},
			tooltip = {en = "Un-place a door or elevator: then aim at it and click"}},
		{text = "/place elevator down", label = {en = "Lift, down"},
			tooltip = {en = "The selection becomes an elevator that goes down"}},
		{text = "/place elevator up", label = {en = "Lift, up"},
			tooltip = {en = "The selection becomes an elevator that goes up"}},
	}},
	{id = "edit_map", theme = {en = "Map"}, when = "block sky spectator",
	 slices = {
		{text = "/undo", label = {en = "Undo"},
			tooltip = {en = "Un-place the last door or elevator"}},
		{text = "/save", label = {en = "Save"},
			tooltip = {en = "Save the map and its layout"}},
		{text = "/noclip", label = {en = "Fly"},
			tooltip = {en = "Fly through everything, or stop"}},
		{text = "/components", label = {en = "Components"}},
		{text = "/chunks", label = {en = "Chunks"}},
		{text = "/place", label = {en = "Help"},
			tooltip = {en = "What can be placed, and how"}},
	}},
};
