-- advanced_battle_bot/config.lua -- tunables and difficulty, ported
-- from the header of tmp-bot-script-advanced.py (TDM + CTF scope).
--
-- Skill is the old CPU_LV: a 0..100 "level" plus a +/- spread, which
-- each bot rolls once into abb.skill in 0..1 (higher = sharper aim,
-- faster reactions, steadier hands). It drives the whole aim-error
-- (gosa) model in aim.lua.
local M = {};

getcfg("abb_count", 4);          -- fighters per team (old BOT_ADD_NUM)
getcfg("abb_skill", 27);         -- average level, 0..100 (old CPU_LV[1])
getcfg("abb_skill_var", 12);     -- +/- spread on the level (old CPU_LV[2])
getcfg("abb_mute", false);       -- silence bot chatter (old BOTMUTE)
getcfg("abb_ctf", true);         -- carry/return the intel in ctf/babel

getcfg("abb_shoot_range", 96);   -- open fire within this many blocks
getcfg("abb_grenade_range", 18); -- lob a grenade within this many blocks
getcfg("abb_grenade_cd", 4);     -- seconds between a bot's grenades
getcfg("abb_grenade_safe_r", 14);-- don't grenade with a friendly-target this close
getcfg("abb_lowhp", 40);         -- retreat/heal thoughts below this HP
getcfg("abb_giveup", 6);         -- seconds of no sight before dropping a target

-- roll a per-bot skill in 0..1 from the configured level and spread
function M.roll_skill()
	local lv = abb_skill + (math.random()*2 - 1) * abb_skill_var;
	if (lv < 5) then lv = 5; end
	if (lv > 100) then lv = 100; end
	return lv / 100;
end

return M;
