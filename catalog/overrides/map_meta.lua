-- map_meta.lua -- Extract metadata from maps without executing arbitrary code
-- upstream: lsd/scripts/map_meta.lua fnv1a32 d4f2ed65 (tests/overrides_test.lua)
-- TODO: optional arbitrary code execution?
local mod = init_mod();
local scraper = require "lib_pyscrape";
local meta = {};

for k, v in pairs(scraper.mod) do
	mod[k] = v;
end

local next_up_msg_noauthor = {
	en="Next up: %(name)"
};

local next_up_msg_author = {
	en="Next up: %(name) by %(author)"
};

function mod.on_load()
	-- TODO: autoload metadata?
	meta = {};
end

function get_map_meta()
	return meta;
end

-- TODO: /load of this here "before" doesn't quite unregister the old one
-- TODO: plumb metadata into core masterlist
function mod.before.load_map(name)
	-- TODO: strip .lua? or put meta in .lua?
	-- TODO: return actually to-be loaded path?
	local file = io.open(string.gsub(name, "%.vxl$", "", 1)..".txt", "r");
	if (file == nil) then
		file = io.open("maps/"..string.gsub(name, "%.vxl$", "", 1)..".txt", "r");
	end
	if (file == nil) then
		meta = {};
		return;
	end

	meta = scraper.grep(file:read("*a"));

	-- TODO: do i need to validate/clamp any of this?
	if (meta.fog) then
		set_fog(meta.fog);
	else
		set_fog(fog);
	end

	if (meta.name) then
		local str;

		-- (lsd-docker, PATCHED) the people only (lib_bot's people_in): the
		-- name of the map is told to a client, not to a bot
		for i in (people_in or piditer)(PID_BROADCAST) do
			if (meta.author) then
				str = l10n_get_str_pid(i, next_up_msg_author, {name=meta.name, author=meta.author});
			else
				str = l10n_get_str_pid(i, next_up_msg_noauthor, {name=meta.name});
			end

			-- TODO: thanks to betterspades for making a 2nd standard that i have to support
			server_msg(i, "N% "..str);
		end
	end

	file:close();
end

-- TODO: only bother if successful -- maybe it should throw an error on fail?
function mod.after.load_map()
	if (meta.name) then
		-- TODO: truncate in lua.c and add potential for length extension?
		masterlist_set_map(string.sub(meta.name, 1, 20));
	end
end

-- TODO: don't depend on fmtval for this
local cmd = {name={"mapinfo", "mapname"}, fakepid=true, desc="Dump the current map's metadata."};
function cmd.func(pid)
	for x in string.gmatch(fmtval(meta), "[^\n]+") do
		server_msg(pid, x);
	end
end
register_command(cmd, mod);

return mod;
