-- demo_reward.lua -- Every reward, free and unlimited
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- A server to try the rewards on: everybody's inventory holds every
-- reward, unlimited (lib_rewards' rewards_free). Night vision still
-- waits for the night. Unloaded, rewards are earned again.
local mod = init_mod();

local hello = {en = "Rewards demo: every reward is yours, unlimited. Open the pie menu, or type /inv."};

function mod.after.on_join(pid)
	l10n_send_chat(pid, hello);
end

function mod.on_load()
	rewards_free = true;
end

function mod.on_unload()
	rewards_free = false;
end

return mod;
