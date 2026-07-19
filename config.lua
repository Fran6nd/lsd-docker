-- config.lua -- Lua script executed on server start
-- Pass the -c option on the command line to use a
-- different path for the config file
--
-- Common settings can be overridden from the environment
-- (see .env / docker-compose.yml): LSD_NAME, LSD_MAPS, LSD_GAMEMODE
masterlist_name = "Fran6nd's LSd server under LSD"

-- whitespace-separated map names, e.g. LSD_MAPS="hallway pinpoint"
-- (parsed into a table here: upstream map_queue.lua only splits
-- strings on newlines/tabs, so spaces would end up inside one name)
local maps_env = os.getenv("LSD_MAPS")
if maps_env then
	map_queue = {}
	for m in string.gmatch(maps_env, "%S+") do
		table.insert(map_queue, m)
	end
else
	map_queue = {"hallway", "bridgewars", "pinpoint"}
end

set_team_name (1, "Blue")
set_team_color(1, {r=  0, g=  0, b=196})

set_team_name (2, "Green")
set_team_color(2, {r=  0, g=196, b=0  })

set_max_score(10);

fog = {r=128, g=232, b=255}
set_fog(fog);

load "group_deps"
load "group_commands"
load "group_moderation"
load "group_feature"

-- Don't load masterlist if you don't want your server to be public.
-- The upstream default only announces to the LSD author's masterlist;
-- master.buildandshoot.com is the official Build and Shoot list.
masterlist_remotes = {
	"66.135.15.57",
	"master.buildandshoot.com",
}
load "masterlist"

-- stdio_console wedges the whole server when stdin is a docker TTY or
-- closed pipe; the container sets LSD_NO_STDIO_CONSOLE=1 to skip it
-- (admin access there goes through sock_console in rw/)
if (os.getenv("LSD_NO_STDIO_CONSOLE") == nil) then
	load "stdio_console"
end
load "sock_console"

-- maptime is exposed by trashheap
load "trashheap"
register(maptime);

motd = [[
This server runs [LSd] from [totally not a burner].
It is meant to test this server and have fun.
You might see some weird stuff though as i like experimenting.
]]
load "motd"

tips = {
	"Tip: use smg to avoid injuring the hostage.",
	"Did you learn something new today?",
	"Use /kill to die.",
	function() for i in piditer(PID_BROADCAST) do
		server_msg(i, string.format(
			"Press the %s key to change team/gun.",
			get_client_char(i) == string.byte('o') and "L" or "comma/dot"
		));
	end end,
	"Block color won't change? Try the arrow keys and E.",
	"This is not Build and Shoot. This is ACE OF SPADES.",
	"Some day I'll add a /tutor"
}
tip_frequency = 5*60
load "tip_spam"

-- one random shotgun pellet per shot explodes (scripts.local/)
load "shotgun_are_grenade_launchers"

-- rifles pierce 5 blocks and leave a tracer trail (scripts.local/)
load "rifle_is_a_rail_gun"

-- Hostage rides on top of ctf (it uses ctf's tents and intel-based
-- scoring). Load the base gamemode and lib_bot FIRST, each exactly
-- once, then hostage -- it only *uses* their globals, never load()s
-- them, so nothing is registered twice. A double register makes a
-- hook's `next` point at itself and stack-overflows the tick chain.
-- Also try "arena", "babel" (hostage stays idle without tents).
local gamemode = os.getenv("LSD_GAMEMODE") or "ctf"
if (gamemode == "hostage") then gamemode = "ctf" end
load(gamemode)
load "lib_bot"
load "hostage"
