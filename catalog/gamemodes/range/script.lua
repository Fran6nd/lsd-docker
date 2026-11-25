-- Rides on ctf for the one team the protocol can show and a tent to
-- restock at; the intels are parked out of play. The range is the map's
-- own: lsdctl generates it with the mode (catalog/core/range_map.lua).
-- Its targets are lib_bot bots, not the bot engine's; the floating
-- numbers over a hit target are Damage Markers'.
return Gamemode {
	title = "Shooting range",
	summary = "One team against targets: a static range from 5 to 50 m, and an IPSC course one shooter at a time behind a start wall, its targets dropping when hit and no-shoots costing time; every target down as fast as you can.",
	base = "ctf",
	rider = "range",
	requires = {"bot", "damage_markers"},
}
