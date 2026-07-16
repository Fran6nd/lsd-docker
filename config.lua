-- config.lua -- Lua script executed on server start
-- Pass the -c option on the command line to use a
-- different path for the config file
--
-- Common settings can be overridden from the environment
-- (see .env / docker-compose.yml): LSD_NAME, LSD_MAPS, LSD_GAMEMODE
masterlist_name = os.getenv("LSD_NAME") or "untitled LSd server"

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

-- Don't load masterlist if you don't want your server to be public
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
This server runs LSd.
Remind the server operator to put something more useful in here.
]]
load "motd"

tips = {
	"This is a worthless tip.",
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

-- Also try "arena", "babel"
load(os.getenv("LSD_GAMEMODE") or "ctf")
