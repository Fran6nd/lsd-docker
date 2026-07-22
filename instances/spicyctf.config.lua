-- config.lua -- Lua script executed on server start
-- Pass the -c option on the command line to use a
-- different path for the config file
--
-- Common settings can be overridden from the environment
-- (see .env / docker-compose.yml): LSD_NAME, LSD_MAPS, LSD_GAMEMODE
-- masterlist caps the name at 31 chars, so "server" is dropped from
-- "Fran6nd's Spicy CTF server under LSd"
masterlist_name = "Fran6nd's Spicy CTF under LSd"

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
Welcome to [Spicy CTF] on [LSd].
Grab the enemy intel and run it back to your tent to score.
The catch: the guns are spiced. Shotguns lob grenades and rifles
are railguns. Have fun and expect some chaos.
]]
load "motd"

tips = {
	"Objective: steal the enemy intel and return it to your tent.",
	"Spicy: every shotgun blast drops a grenade pellet -- mind the splash.",
	"Spicy: rifles are railguns, they pierce blocks and leave a tracer.",
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
tip_frequency = 5*60
load "tip_spam"

-- one random shotgun pellet per shot explodes (scripts.local/)
load "shotgun_are_grenade_launchers"

-- rifles pierce 5 blocks and leave a tracer trail (scripts.local/)
load "rifle_is_a_rail_gun"

-- player-driven kick votes: /votekick <player>, /y to vote (scripts.local/)
load "votekick"

-- Plain CTF (this is the spicyctf instance -- same scripts as hostage,
-- minus the hostage gamemode). Load the base gamemode and lib_bot, each
-- exactly once. "hostage" folds onto ctf, so guard against it here too.
-- Also try "arena", "babel".
local gamemode = os.getenv("LSD_GAMEMODE") or "ctf"
if (gamemode == "hostage") then gamemode = "ctf" end
load(gamemode)
-- random spawn around the team tent; BEFORE lib_bot so lib_bot's bot
-- spawn_at stays outermost, while real players fall through to the
-- random tent spawn
load "tentspawns"
load "lib_bot"
-- combat guard bots, 5 per team (scripts.local/) -- disabled for now;
-- uncomment to bring them back (./lsdctl spicyctf load lib_bot bot_standard)
-- load "bot_standard"
