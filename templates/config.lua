-- config.lua -- Template every new instance is created from
--
-- `lsdctl new <name>` copies this to instances/<name>.config.lua, which
-- is then that server's own to edit. Keep this file NEUTRAL: anything
-- specific to one server belongs in that server's copy, not here, or
-- every server created afterwards inherits it.
--
-- Settings that differ per instance come from its .env rather than being
-- written in: LSD_NAME, LSD_MAPS, LSD_GAMEMODE, LSD_MASTERLIST.
--
-- Pass -c on the command line to use a different config path.

-- The masterlist caps a name at 31 characters. The fallback is only for
-- running the server by hand outside docker, where nothing sets the env.
masterlist_name = os.getenv("LSD_NAME") or "LSd server"

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
Welcome to ]]..masterlist_name..[[, running [LSd].
Have fun.
]]
load "motd"

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
tip_frequency = 5*60
load "tip_spam"

-- player-driven kick votes: /votekick <player>, /y to vote (scripts.local/)
load "votekick"

-- In-game map editor: components (doors, elevators), spatial permissions
-- and the terrain tools. Inert until switched on from the console with
-- ./lsdctl <instance> edit on, so loading it costs a normal round
-- nothing. The group pulls in its dependencies.
load "group_world_editor"

-- Flavour, off by default -- uncomment per server that wants it:
-- one random shotgun pellet per shot explodes, and rifles pierce the
-- whole map leaving a tracer (both scripts.local/)
-- load "shotgun_are_grenade_launchers"
-- load "rifle_is_a_rail_gun"

-- The gamemode is whatever the instance asks for: ctf, arena, babel,
-- ffa, dd... plus "hostage" from scripts.local/, which is not a gamemode
-- of its own but rides on top of ctf (it uses ctf's tents and
-- intel-based scoring).
--
-- Load the base gamemode and lib_bot FIRST, each exactly once, and only
-- then hostage -- it only *uses* their globals, never load()s them, so
-- nothing is registered twice. A double register makes a hook's `next`
-- point at itself and stack-overflows the tick chain.
local gamemode = os.getenv("LSD_GAMEMODE") or "ctf"
local hostage = (gamemode == "hostage");
if (hostage) then gamemode = "ctf" end
load(gamemode)

-- random spawn around the team tent; BEFORE lib_bot so a bot's own
-- spawn_at stays outermost and wins, while real players fall through to
-- the random tent spawn
load "tentspawns"
load "lib_bot"
if (hostage) then
	load "hostage"
end

-- combat guard bots, 5 per team (scripts.local/) -- off by default:
-- ./lsdctl <instance> load bot_standard  to try them on a running server
-- load "bot_standard"
