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

-- Which maps rotate, and in what order.
--
-- By default: every map installed in this server's own folder, in name
-- order. Dropping a .vxl in puts it into rotation and deleting the file
-- takes it out, with nothing to keep in step by hand -- the folder is
-- the single source of truth. (map_queue.lua carries a
-- "TODO: list dirs in lua?" for exactly this.)
--
-- LSD_MAPS overrides that with an explicit whitespace-separated list,
-- for when the order matters or only some of the installed maps should
-- play. Parsed here rather than passed straight through: upstream
-- map_queue.lua splits only on newlines and tabs, so spaces would end up
-- inside a single name.
--
-- The path is the container's, which is always /lsd/maps whatever the
-- host directory behind it is (see LSD_MAPS_DIR).
local function queue_from_env()
	local env = os.getenv("LSD_MAPS")
	if (env == nil) then return nil end

	local q = {}
	for m in string.gmatch(env, "%S+") do table.insert(q, m) end
	return #q > 0 and q or nil
end

local function queue_from_folder()
	local ok, lfs = pcall(require, "lfs")
	if (not ok) then return nil end

	local q = {}
	local scan = pcall(function()
		for f in lfs.dir("maps") do
			local name = string.match(f, "^(.+)%.vxl$")
			if (name) then table.insert(q, name) end
		end
	end)
	if (not scan) then return nil end

	table.sort(q)
	return #q > 0 and q or nil
end

-- left nil if both come up empty, so map_queue.lua's own default applies
map_queue = queue_from_env() or queue_from_folder()

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
It is night here, and it does not get light. Press F for your torch.
Your client must support the Flashlight and Daytime extensions to play.
]]
load "motd"

tips = {
	"Press F for your flashlight. It is the only light there is.",
	"Ping what you cannot describe: your team sees the marker.",
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


-- aosprotocol extension negotiation (scripts.local/). Owns packet 60 and
-- announces every extension below in ONE ExtensionInfo, which is what
-- the protocol allows. Must be loaded before any of them.
load "lib_ext"

-- Player Limit (id 192 v1, packetless): this server may use the whole
-- player id range, and id 255 is the server's and never a player.
player_limit_max = 255
load "lib_player_limit"

-- Message Types (id 193 v1, packetless): four more chat types on top of
-- the base three. Worth more here than anywhere -- it is what makes the
-- "your client is outdated" alert an alert, on the one server where
-- being outdated actually stops you playing.
load "lib_message_types"

-- WHAT A MISSING EXTENSION COSTS, and on this server two of them cost
-- everything: a client without Flashlight or without Daytime and
-- Weather is held in spectator, told what it is missing, and told again
-- every ext_policy_warn_interval until it updates.
--
-- Which is not gatekeeping for its own sake. This map is played in the
-- dark, and the dark only exists for a client that draws it: one
-- without Daytime and Weather sees a black sky over a FULLY LIT world,
-- because nothing in base 0.75 can scale its lighting. That client is
-- not playing the same game -- it is playing the easy version of it,
-- and seeing everyone the rest cannot. And without Flashlight it has no
-- way to light anything, nor to be seen lighting it.
--
-- So the two travel together, and on this server they are the price of
-- entry. Everything else stays recommended.
--
-- Levels are names, not the EXT_* constants: those are globals the
-- module creates when it loads, and this runs first.
ext_policy_default = "recommended"
ext_policy = {
	[0x33] = "required",   -- Daytime and Weather
	[0x32] = "required",   -- Flashlight
}
load "lib_ext_policy"

-- Daytime and Weather (id 0x33 v1, packet 0x73): day or night, and in
-- v1 that is the whole of it. NIGHT here, permanently -- full darkness:
-- nothing lights the world and the sky is black. It is the entire point
-- of the server.
daytime_night = true
load "lib_daytime"

-- Flashlight (id 0x32 v1, packet 0x72): a carried light every client
-- draws, with OpenSpades' legacy beam -- reach 60, a 90 degree cone, a
-- warm 255/179/128. Dynamic lights are not scaled by night, so this
-- burns at full strength against a black world: here it is not a
-- flourish, it is the only light there is. The F key switches it; the
-- client asks and the server relays.
load "lib_flashlight"

-- Teamplay (id 48 v1, packet 112): server-driven ESP marks, client
-- pings, and which way north is. Pings matter in the dark.
load "lib_teamplay"

-- Damage Markers (id 0x20 v1, packet 0x60): every hit tells whoever
-- landed it how much it took off. Useful when you cannot see what you
-- shot at.
load "lib_damage_markers"

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
