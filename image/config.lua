-- config.lua -- The one config the server runs
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Nothing in here is a value. Values live in the settings file
-- (/data/settings), which `lsdctl` edits and an operator may edit by
-- hand; this file only decides the ORDER things happen in, and that
-- order is not a preference but a set of constraints that break the
-- server when broken:
--
--   the settings file before every getcfg, so the file's values win
--   upstream's groups, the console and the masterlist
--   the installed scripts, by phase (catalog.lua says which)
--   the gamemode, then tentspawns, then the bots, then its rider
--
-- Which scripts run is the settings file's `scripts` list and which
-- gamemode its `gamemode`; catalog.lua turns the two into modules in
-- order, pulling in what each one requires. A script that is installed
-- but missing from the catalog is reported and skipped, never fatal --
-- one broken script should cost that script, not the server.
--
-- LSd reads no environment and takes only -c and -p, so a Lua config
-- is the one thing the server loads. Pass -c to use another one.

--============================= SETTINGS =============================--

-- FIRST, before any module loads. Every value goes straight into its
-- global, and that is the whole mechanism: core.lua's getcfg fills a
-- global only when it is still nil, so a module declaring a setting the
-- way it always has finds the file's value already there and keeps it.
-- Nothing has to be told about this file.
--
-- A name the core itself already uses (modules, load, server...) is
-- refused: assigning it would break the module system, not configure it.
do
	local F = require "settings_format";
	local path = os.getenv("LSD_SETTINGS_FILE") or "settings";
	local f = io.open(path, "r");

	if (f == nil) then
		log("settings: no %s; every setting is its default", path);
	else
		local text = f:read("*a");
		f:close();

		local values = F.parse(text, function(n, msg)
			log("settings: %s:%d %s", path, n, msg);
		end);

		local count = 0;
		for k, v in pairs(values) do
			if (_G[k] ~= nil) then
				log("settings: %s: %q is a name the server itself uses; ignored",
					path, k);
			else
				_G[k] = v;
				count = count + 1;
			end
		end
		log("settings: %s, %d value(s)", path, count);
	end
end

-- name, port, listing, rotation, fog
load "lib_server"

getcfg("gamemode", "ctf",
	"Which gamemode runs. `lsdctl gamemode` lists them.");
getcfg("scripts", {},
	"Installed scripts, by catalog id. `lsdctl install` and "
		.."`lsdctl remove` keep this list.");

--============================== THE PLAN ============================--

-- The catalog lives beside the server (/lsd/catalog) and, for scripts
-- of the operator's own, on the data volume (/data/catalog). A later
-- root replaces an earlier one's entry of the same id.
local catalog = require "catalog";
local lfs = require "lfs";

getcfg("catalog_roots", {"catalog", "/data/catalog"},
	"Where script manifests are read from, in order.");

local cat = catalog.open(catalog_roots, catalog.lfs_reader(lfs));

for _, err in ipairs(cat.errors) do
	log("catalog: %s", err);
end

local installed = type(scripts) == "table" and scripts or {};
local plan = cat:plan(installed, gamemode);

for _, m in ipairs(plan.missing) do
	log("catalog: %s is installed but not in the catalog; skipped", m);
end

local names = {};
for _, e in ipairs(plan.entries) do names[#names+1] = e.id; end
log("config: gamemode %s; scripts: %s", plan.gamemode.id,
	#names > 0 and table.concat(names, ", ") or "none");

-- Load one phase's modules. A module that fails to load is logged and
-- skipped, for the same reason a missing one is.
local function load_phase(phase)
	for _, m in ipairs(plan.phases[phase]) do
		local ok, err = pcall(load, m);

		if (not ok) then
			log("config: %s failed to load, skipped: %s", m, tostring(err));
		end
	end
end

--=============================== SERVER =============================--

set_team_name (1, "Blue")
set_team_color(1, {r=  0, g=  0, b=196})
set_team_name (2, "Green")
set_team_color(2, {r=  0, g=196, b=0  })

getcfg("max_score", 10, "Captures needed to win a round.")
set_max_score(max_score);

-- lib_server declares `fog`; this is where it reaches the world
set_fog(fog);

getcfg("motd", nil,
	"Message of the day, shown on join. A list of lines.")
getcfg("tip_frequency", 5*60,
	"Seconds between tips. 0 stops them.")
getcfg("tips", nil,
	"Tips shown in rotation, as a list of lines. Empty uses the stock set.")

-- The stock tips. The last one is a function because the key to press
-- depends on the client, which a settings file cannot say.
if (tips == nil) then
	tips = {
		"Use /kill to die.",
		function() for i in piditer(PID_BROADCAST) do
			server_msg(i, string.format(
				"Press the %s key to change team/gun.",
				get_client_char(i) == string.byte('o') and "L" or "comma/dot"
			));
		end end,
		"Block color won't change? Try the arrow keys and E.",
		"This is not Build and Shoot. This is ACE OF SPADES.",
	}
end

if (type(motd) == "table") then
	motd = table.concat(motd, "\n") .. "\n";
elseif (motd == nil) then
	motd = "Welcome to " .. tostring(masterlist_name)
		.. ", running [LSd].\n";
end

load "group_deps"
load "group_commands"
load "group_moderation"
load "group_feature"

if (masterlist_enabled) then
	load "masterlist"
end

-- stdio_console wedges the server when stdin is a docker TTY or a
-- closed pipe; the container sets LSD_NO_STDIO_CONSOLE=1. lsdctl talks
-- to sock_console instead.
if (os.getenv("LSD_NO_STDIO_CONSOLE") == nil) then
	load "stdio_console"
end
load "sock_console"

-- maptime is exposed by trashheap and registered after it
load "trashheap"
if (maptime ~= nil) then
	register(maptime);
end

load "motd"
load "tip_spam"

--============================== SCRIPTS =============================--

load_phase("libs")
load_phase("effects")
load_phase("extensions")
load_phase("tools")
load_phase("gamemode")
load "tentspawns"
load_phase("spawns")
load_phase("bots")
load_phase("rider")
load_phase("late")
