-- config.lua -- Lua script executed on server start
-- Pass the -c option on the command line to use a
-- different path for the config file
--
-- Common settings can be overridden from the environment
-- (see .env / docker-compose.yml): LSD_NAME, LSD_MAPS, LSD_GAMEMODE
masterlist_name = os.getenv("LSD_NAME")

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

-- Public listing. The upstream default only announces to the LSD
-- author's masterlist; master.buildandshoot.com is the official Build
-- and Shoot list. LSD_MASTERLIST=0 keeps the server unlisted:
-- ./lsdctl <instance> masterlist off (delisting is not access control
-- though -- anyone who knows ip:port can still join).
--
-- The name and remotes are set even when the listing is off, on
-- purpose: getcfg only fills globals that are nil, so a later live
-- `load masterlist` would otherwise fall back to upstream's defaults.
masterlist_remotes = {
	"66.135.15.57",
	"master.buildandshoot.com",
}
if (os.getenv("LSD_MASTERLIST") ~= "0") then
	load "masterlist"
end

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
I recommend using ZeroSpades as client.
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

-- (spicy guns live on the spicyctf instance, not here: hostage keeps
-- vanilla weapons)

-- player-driven kick votes: /votekick <player>, /y to vote (scripts.local/)
load "votekick"

-- Hostage rides on top of ctf (it uses ctf's tents and intel-based
-- scoring). Load the base gamemode and lib_bot FIRST, each exactly
-- once, then hostage -- it only *uses* their globals, never load()s
-- them, so nothing is registered twice. A double register makes a
-- hook's `next` point at itself and stack-overflows the tick chain.
-- Also try "arena", "babel" (hostage stays idle without tents).
local gamemode = os.getenv("LSD_GAMEMODE") or "ctf"
if (gamemode == "hostage") then gamemode = "ctf" end
load(gamemode)
-- random spawn around the team tent; BEFORE lib_bot so lib_bot's bot
-- spawn_at (the hostage's enemy-tent post) stays outermost and wins,
-- while real players fall through to the random tent spawn
load "tentspawns"
-- the server list counts humans only: lib_bot keeps its bots (the
-- hostages, and bot_standard's guards) out of the advertised player
-- count and off the advertised capacity, since their slots aren't free
-- for humans either. Set false to advertise bots as players again.
bot_hide_from_masterlist = true
load "lib_bot"
load "hostage"
-- combat guard bots, 5 per team (scripts.local/) -- disabled for now;
-- uncomment to bring them back (./lsdctl load lib_bot hostage bot_standard)
-- load "bot_standard"

-- in-game map/component editor (scripts.local/). Loading it is inert on
-- its own: edit mode is console-gated (./lsdctl hostage edit on), it
-- pulls its own deps through require, and it restores each map's
-- maps/<map>.editor.json on load. Listed here so a restart keeps it --
-- a hot `./lsdctl hostage load world_editor` only lives in the running
-- server's Lua state and is lost the next time the container is recreated.
load "world_editor"
