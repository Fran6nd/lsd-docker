-- lib_server.lua -- The settings that describe the server, not a feature
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Its name, its port, whether it is listed, which maps rotate, which
-- masterlists to publish to, the fog. Every script owns its own
-- settings; these belong to the server itself, so they are declared
-- here, once, and the settings file's server section sets them.
--
-- masterlist_remotes and map_queue are getcfg keys upstream
-- (masterlist.lua, map_queue.lua). Declaring them here, before those
-- modules load, is what lets the settings file set them at all.
--
-- API (globals):
--   server_map_queue()   -> the rotation to play, from map_rotation or
--                           by listing the map folder. nil leaves
--                           map_queue.lua's own default alone.
local mod = init_mod();

-- Read by the container's entrypoint, which passes it to the server as
-- -p; declared here so the settings file may set it, and so it is not
-- reported as a setting nothing reads.
getcfg("port", 32887,
	"UDP port the server listens on and announces. Changing it needs "
		.."the container recreated with the new port published.");
getcfg("masterlist_name", "LSd server",
	"Server name shown in the server lists. The masterlist caps it at "
		.."31 characters.");
getcfg("masterlist_enabled", true,
	"Announce this server to the public server lists. Delisting is not "
		.."access control: anyone who knows ip:port can still join.");
-- Every server list known to be live, so a server is found wherever
-- players look. Kept here rather than written into each settings file,
-- so an image that learns of another list announces to it on update.
getcfg("masterlist_remotes", {"66.135.15.57", "master.buildandshoot.com"},
	"Server lists to announce to; default is every known one. "
		.."66.135.15.57 is LSd's author's; master.buildandshoot.com is "
		.."Build and Shoot's.");
getcfg("map_rotation", nil,
	"Maps to play, space separated, in the order given. Empty plays "
		.."every .vxl in the map folder, in name order.");
getcfg("map_random", false,
	"Play the maps in a random order -- the first one too -- reshuffled "
		.."each time round, never the same map twice in a row.");
getcfg("fog", {r = 128, g = 232, b = 255},
	"Fog colour, which in Ace of Spades is also the sky. Written "
		.."(r, g, b). A map's own metadata overrides it per map.");

--============================== ROTATION ============================--

-- The rotation named by the setting, if it names one.
--
-- Parsed here rather than handed straight to map_queue.lua, which
-- splits only on newlines and tabs -- a space-separated list would end
-- up inside a single map name.
local function from_setting()
	if (type(map_rotation) ~= "string") then
		return nil;
	end

	local q = {};
	for m in string.gmatch(map_rotation, "%S+") do
		q[#q+1] = m;
	end

	return #q > 0 and q or nil;
end

-- Otherwise: whatever .vxl files are installed, in name order. The
-- folder is then the single source of truth -- drop a map in and it
-- plays, delete it and it stops, with nothing to keep in step by hand.
-- (map_queue.lua carries a "TODO: list dirs in lua?" for exactly this.)
--
-- lfs is built into the image (exec/lfs.so) and reached through
-- core.lua's cpath, but it is pcall'd because a natively built LSd may
-- not have it -- in which case the rotation falls through to
-- map_queue.lua's own default rather than failing to start.
--
-- The path is relative to the server: in the container, maps/ is the
-- data volume's maps folder.
local function from_folder()
	local ok, lfs = pcall(require, "lfs");

	if (not ok) then
		return nil;
	end

	local q = {};
	local scanned = pcall(function()
		for f in lfs.dir("maps") do
			local name = string.match(f, "^(.+)%.vxl$");

			if (name) then
				q[#q+1] = name;
			end
		end
	end);

	if (not scanned or #q == 0) then
		return nil;
	end

	table.sort(q);
	return q;
end

function server_map_queue()
	return from_setting() or from_folder();
end

--============================= LIFECYCLE ============================--

-- Applied at load, which is early enough: the masterlist module is
-- loaded after this and reads masterlist_name in its own on_load.
function mod.on_load()
	local q = server_map_queue();

	-- left alone if both come up empty, so map_queue.lua's own default
	-- applies rather than an empty rotation
	if (q ~= nil) then
		map_queue = q;
	end
	-- map_queue.lua's shuffle: at the first map and at every wrap
	if (map_random == true) then
		map_queue_shuffle = true;
	end

	log("lib_server: %q, %s, %d map(s)", tostring(masterlist_name),
		masterlist_enabled and "listed" or "unlisted",
		q ~= nil and #q or 0);
end

-- Everything this module put in the global table, taken back out again.
--
-- Unloading a module does not undo its globals -- the functions keep
-- working, closed over the state of a module nothing is calling any
-- more -- and consumers test these names to find out whether the thing
-- is available at all. Left behind, they answer yes forever and every
-- such guard becomes dead code.
--
-- The list is exhaustive on purpose: a name added to the API above and
-- forgotten here outlives its own module, and goes on answering for it.
local EXPORTS = {
	"server_map_queue",
};

function mod.on_unload()
	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
