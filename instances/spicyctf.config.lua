-- config.lua -- Lua script executed on server start
-- Pass the -c option on the command line to use a
-- different path for the config file
--
-- Common settings can be overridden from the environment
-- (see .env / docker-compose.yml): LSD_NAME, LSD_MAPS, LSD_GAMEMODE
-- masterlist caps the name at 31 chars, so "server" is dropped from
-- "Fran6nd's Spicy CTF server under LSd"
masterlist_name = os.getenv("LSD_NAME")

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
Welcome to [Spicy CTF] on [LSd].
Grab the enemy intel and run it back to your tent to score.
The catch: the guns are spiced, and your first death drops you into
the Fall. Only a kill gets you out of it.
Have fun and expect some chaos.
I recommend using ZeroSpades as client.
]]
load "motd"

-- The weapon scripts loaded below add their own "Spicy:" lines to this
-- table as they load, so what the guns do is not described twice.
tips = {
	"Objective: steal the enemy intel and return it to your tent.",
	"The Fall: when you die you respawn falling down the central pit.",
	"Kill someone while falling and you are put back in the game, healed and restocked.",
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

-- Works out when a bullet was actually fired, for every gun, and hands
-- that one answer to both of the weapon scripts below -- neither of
-- which can tell on its own (see the file). Must be loaded before them.
-- (scripts.local/)
load "lib_shot_detect"

-- one random shotgun pellet per shot explodes (scripts.local/)
load "shotgun_are_grenade_launchers"

-- rifles pierce the whole map and leave a tracer trail (scripts.local/)
load "rifle_is_a_rail_gun"

-- the smg pins whoever it hits and never runs dry (scripts.local/)
load "smg_is_incapacitating"

-- aosprotocol's Teamplay extension (id 2 v1): lets the server outline a
-- player on a teammate's screen, lets clients ping the world, and lets
-- the server say a line to one player alone. Loading it only negotiates
-- -- nothing marks anybody yet, and no released client answers yet.
-- Harmless groundwork, and inert until one does. (scripts.local/)
load "lib_teamplay"

-- A demo of the ESP marks above: aim at an enemy and your whole team
-- sees them outlined for a few seconds. Inert without lib_teamplay, and
-- invisible to any client that hasn't negotiated it. (scripts.local/)
load "esp_demo"

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

-- The Fall: a central pit dug on every map load. Death is ordinary and
-- counts, but it respawns you falling down the pit instead of at your
-- tent, and only a kill buys you back out of it.
-- Needs lib_bot above it: it keeps four bots falling in the shaft as
-- targets, disguised as the enemy team to everyone. (scripts.local/)
load "the_fall"

-- in-game map/component editor (scripts.local/). Loading it is inert on
-- its own: edit mode is console-gated (./lsdctl spicyctf edit on), it
-- pulls its own deps through require, and it restores each map's
-- maps/<map>.editor.json on load. Listed here so a restart keeps it --
-- a hot `./lsdctl spicyctf load world_editor` only lives in the running
-- server's Lua state and is lost the next time the container is recreated.
load "world_editor"
