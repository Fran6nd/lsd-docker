-- motd.lua -- Send a blob of text to players when they join
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- Upstream's, with the lines in each player's language: `motd` is a
-- string of lines, or a list whose lines are each a string or a language
-- map, {en: "Welcome", fr: "Bienvenue"} (see lib_l10n). %(server) in a
-- line is the server's name.
local mod = init_mod();
getcfg("motd", "Server owner forgot to set the motd, oh no");

local function lines()
	if (type(motd) == "table" and not l10n_is_map(motd)) then
		return motd;
	end
	if (type(motd) ~= "string") then
		return {motd};
	end
	local out = {};
	for line in string.gmatch(motd, "([^\n]+)") do
		out[#out+1] = line;
	end
	return out;
end

local function send_motd(pid)
	local args = {server = tostring(masterlist_name or "")};
	for _, line in ipairs(lines()) do
		server_msg(pid, l10n_text(line, args));
	end
end

-- TODO: first join only -- on_initial_join
function mod.after.on_join(pid)
	send_motd(pid);
end

function mod.after.on_fakepid_connect(pid)
	send_motd(pid);
end

return mod;
