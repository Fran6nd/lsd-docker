-- ammo_box.lua -- A resupply on the spot
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- trigger(pid) restocks the player where they stand, as walking to
-- their tent would: ammunition, blocks, grenades and health (the
-- server's own restock). It does nothing on its own -- a gamemode or a
-- reward sets it off -- and refuses the dead.
local fx = PlayerEffect {
	name = "ammo_box",
	warning = {en = "Ammo boxes resupply you on the spot."},
	every = 0,
	trigger = function(pid)
		if (not is_alive(pid)) then
			return nil;
		end
		restock(pid);
		return true;
	end,
};

return fx.mod;
