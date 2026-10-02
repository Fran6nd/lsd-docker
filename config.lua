-- config.lua -- The one config every instance runs
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- THIS FILE IS SHARED. Every instance's LSD_CONFIG_FILE points at it,
-- and nothing in it is specific to any one server. What differs lives
-- in that instance's settings file, which is the only file an operator
-- edits:
--
--   instances/<name>.settings     every value, and the module list
--   instances/<name>.env          docker plumbing: port, paths, volume
--
-- So there is no per-instance config.lua to keep four copies of in
-- step. That mattered: the four that used to exist had drifted, and two
-- of them had real bugs in the same six lines -- one loaded the hostage
-- module unconditionally so the setting could not switch it off, one
-- never loaded it at all so asking for it silently gave plain ctf.
--
-- WHY IT IS STILL LUA. LSd takes -c <path> and reads no environment at
-- all (main.c:1652-1672), so a Lua config is not optional; it is the
-- one thing the server loads. What IS optional is putting values in it,
-- and none are. This file decides nothing except the order things
-- happen in.
--
-- ORDER IS THE WHOLE JOB, and it cannot be data because it is not a
-- preference -- it is a set of constraints that break the server when
-- broken. lib_settings must precede every getcfg, lib_ext must precede
-- the extensions that register with it, the gamemode must precede
-- tentspawns and lib_bot, and a rider like hostage must follow lib_bot
-- so lib_bot's own spawn_at stays outermost. The `modules` list in the
-- settings file is ordered for that reason, and @gamemode marks the two
-- points the mode itself has to occupy.
--
-- Pass -c on the command line to use a different config path.

-- FIRST, before any getcfg anywhere: it applies the settings file to
-- the globals, and core.lua's getcfg then fills only what the file left
-- alone (core.lua:43-47). A value applied after a module has already
-- defaulted its global does nothing -- and a value that never arrives
-- falls back to the default silently, which is the one failure here
-- that looks like success. Watch the log line it prints.
load "lib_settings"

-- The settings that describe a server rather than a feature: its name,
-- whether it is listed, the map rotation, the fog. Declared in one
-- module instead of in every instance's config, which is how the
-- gamemode doc string came to be wrong in four places at once.
load "lib_instance"

-- Which gamemode runs, and what loading it actually entails. Refuses a
-- name it does not know rather than handing it to load(), where an
-- already-loaded module like `dd` succeeds and then overflows the tick
-- chain.
load "lib_gamemode"

set_team_name (1, "Blue")
set_team_color(1, {r=  0, g=  0, b=196})
set_team_name (2, "Green")
set_team_color(2, {r=  0, g=196, b=0  })

getcfg("max_score", 10, "Captures needed to win a round.")
set_max_score(max_score);

-- lib_instance declares `fog`; this is where it reaches the world.
set_fog(fog);

getcfg("motd", nil,
	"Message of the day, shown on join. A list of lines, since the "
		.."format has no multi-line string.")
getcfg("tip_frequency", 5*60,
	"Seconds between tips. 0 stops them.")
getcfg("tips", nil,
	"Tips shown in rotation, as a list of lines. Empty uses the stock "
		.."set below.")

-- The stock tips, used when the settings file names none. The last one
-- is a function rather than a line because the key to press depends on
-- the client, which is why `tips` cannot live wholly in a settings file
-- -- a list of strings can, and that is what the setting takes.
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

-- A list of lines is what a settings file can express; motd.lua wants
-- one string, so join them here.
if (type(motd) == "table") then
	motd = table.concat(motd, "\n") .. "\n";
elseif (motd == nil) then
	motd = "Welcome to " .. tostring(masterlist_name)
		.. ", running [LSd].\n";
end

-- stdio_console wedges the whole server when stdin is a docker TTY or a
-- closed pipe; the container sets LSD_NO_STDIO_CONSOLE=1 to skip it.
-- This is the one environment read left, and it is genuinely about the
-- container rather than about the server.
if (os.getenv("LSD_NO_STDIO_CONSOLE") == nil) then
	load "stdio_console"
end

--=============================== MODULES ============================--

-- Everything else, in the order the settings file gives. Two names are
-- not modules but positions:
--
--   @gamemode        the base mode, from the `gamemode` setting
--   @gamemode_extra  its rider, if it has one (hostage on ctf)
--
-- A name that is neither is loaded as a module. An unknown module name
-- fails here with its own name in the error, which is a better place to
-- find out than halfway through a round.
getcfg("modules", nil,
	"Modules to load, in order. @gamemode and @gamemode_extra mark "
		.."where the gamemode and its rider go.")

if (type(modules) ~= "table") then
	error("config.lua: this instance's settings file sets no `modules` "
		.."list, so the server would load nothing. See "
		.."templates/settings.", 0);
end

for _,name in ipairs(modules) do
	if (name == "@gamemode") then
		gamemode_base();
	elseif (name == "@gamemode_extra") then
		gamemode_extra();
	elseif (name == "masterlist") then
		-- listing is a setting, not a module decision
		if (masterlist_enabled) then
			load "masterlist"
		end
	else
		load(name);
	end
end

-- maptime is exposed by trashheap, which the module list loads; it has
-- to be registered after it and is not a module of its own.
if (maptime ~= nil) then
	register(maptime);
end
