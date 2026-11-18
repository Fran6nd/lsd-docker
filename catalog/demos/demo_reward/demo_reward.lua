-- demo_reward.lua -- Every reward, free and unlimited
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- A server to try the rewards on: every wedge of the Rewards pie is
-- shown to every living player, and spending costs nothing (lib_rewards'
-- rewards_free). Night vision still waits for the night. Unloaded, the
-- rewards cost their points again.
local mod = init_mod();

local hello = {en = "Rewards demo: every reward is free here. Open the pie menu, or type /reward."};

local function free(on)
	rewards_free = on;
	if (pie_menu_refresh ~= nil) then
		pie_menu_refresh();
	end
end

function mod.after.on_join(pid)
	l10n_send_chat(pid, hello);
end

function mod.on_load()
	free(true);
end

function mod.on_unload()
	free(false);
end

return mod;
