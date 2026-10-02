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
-- that one answer to the shotgun and rifle scripts below -- neither of
-- which can tell on its own (see the file). Must be loaded before them.
-- The smg script below needs none of it: it acts on landed bullets only,
-- which the client reports itself. (scripts.local/)
load "lib_shot_detect"

-- one random shotgun pellet per shot explodes (scripts.local/)
load "shotgun_are_grenade_launchers"

-- rifles pierce the whole map and leave a tracer trail (scripts.local/)
load "rifle_is_a_rail_gun"

-- the smg pins whoever it hits and never runs dry (scripts.local/)
load "smg_is_incapacitating"

-- aosprotocol extension negotiation (scripts.local/). Owns packet 60 and
-- announces every extension below in ONE ExtensionInfo, which is what the
-- protocol allows -- so each extension registers here rather than doing
-- its own handshake. Must be loaded before any of them.
load "lib_ext"

-- aosprotocol's Player Limit extension (id 192 v1, packetless): tells a
-- client this server may use the whole player id range, and that id 255
-- is the server's and never a player -- which is the reservation the
-- flashlight default beam below is addressed to. Announcing it does not
-- raise anything on its own: the cap is player_limit_max, below.
-- (scripts.local/)
--
-- Wide open: 255 is every id the protocol has, handed out as 0-254 with
-- 255 left to the server, which is the most the extension allows and
-- the most a masterlist byte can carry. The risk is the one the module
-- header spells out -- a pid is chosen when a client connects, before
-- the extension handshake, so a client that keeps a 32-slot array can
-- be handed pid 40 and do whatever it does about that. Drop this back
-- to 32 if old clients start falling over.
player_limit_max = 255
load "lib_player_limit"

-- aosprotocol's Message Types extension (id 193 v1, packetless): four
-- more chat types on top of the base three -- big and centre-screen, a
-- notice, a warning, an error -- so the server can say something a
-- player actually notices instead of another grey line that scrolls
-- away. Nothing sends one by itself; lib_ext_policy below uses them for
-- its warnings. Clients that have not negotiated it get the ordinary
-- system line, automatically. (scripts.local/)
load "lib_message_types"

-- What a MISSING extension costs a client (scripts.local/). Three
-- levels: EXT_APPLIED is silent, EXT_RECOMMENDED tells the player what
-- they are missing, EXT_REQUIRED holds them in spectator until they
-- update. Bots are exempt -- there is nothing on the other end of one
-- to ask -- so the Fall's fallers are unaffected.
--
-- RECOMMENDED for everything, for now. Nobody is kept out and nothing
-- is withheld; a client missing something is told once. Expect most
-- clients to be told they are missing most of these -- the specs are
-- days old -- and that is the point: when the warnings stop arriving
-- for a client you expected to be fine, that extension is worth
-- requiring. Not before.
--
-- Levels are written as names here, not as the EXT_* constants: those
-- are globals the module creates when it loads, and this runs first, so
-- `EXT_REQUIRED` would be nil and the entry would quietly vanish.
--
-- ext_policy names exceptions to the default, by extension id. The ones
-- this instance loads are 3 Silent Player, 0x20 Damage Markers,
-- 0x32 Flashlight, 48 Teamplay, 192 Player Limit, 193 Message Types --
-- e.g. ext_policy = { [0x32] = "required" }. Naming an id no module
-- here registered does nothing; the audit says so in the log at
-- startup.
ext_policy_default = "recommended"
ext_policy = {}
load "lib_ext_policy"

-- aosprotocol's Daytime and Weather extension (id 0x33 v1, packet
-- 0x73): day or night, and in v1 that is the whole of it -- there is no
-- clock, because moving the sun and its shadows is still too costly for
-- clients to draw. The CLIENT does the dark, and by night it is FULL
-- darkness: nothing lights the world and the sky is black.
--
-- NIGHT. The sky is dark and stays dark; set daytime_night = false
-- for day. On open ground the dark is most of the difficulty, and
-- the flashlight is how you deal with it.
--
-- A flashlight is then the ONLY light there is, and it burns as
-- brightly as by day. Which is what makes the flashlight above the
-- difference between playing and not, rather than decoration.
--
-- Clients that have not negotiated it get a black sky painted for them
-- per client (daytime_fog_fallback), which is the most base 0.75 can
-- say -- it cannot touch their lighting, so for them night is a black
-- horizon over a fully lit world.
daytime_night = true
load "lib_daytime"


-- aosprotocol's Teamplay extension (id 48 v1, packet 112): lets the
-- server outline a player on a teammate's screen, lets clients ping the
-- world, and tells clients which way north is. Loading it only
-- negotiates -- nothing marks anybody yet, and a client has to speak the
-- extension before any of it reaches a screen. (scripts.local/)
load "lib_teamplay"

-- aosprotocol's Damage Markers extension (id 0x20 v1, packet 0x60):
-- every hit tells whoever landed it how much it took off, and the
-- client floats the number over the man who took it. It hooks the
-- damage itself rather than any one weapon, so the rail's 255, the
-- shotgun's falloff, a grenade and a fall all count without any of the
-- spiced guns above knowing it exists. Clients that haven't negotiated
-- it see nothing, as before. (scripts.local/)
load "lib_damage_markers"

-- aosprotocol's Flashlight extension (id 0x32 v1, packet 0x72): a light
-- a player carries that EVERY client draws, not just its owner's. The
-- beam is OpenSpades' legacy flashlight to the number -- reach 60, a 90
-- degree cone, a warm 255/179/128 -- so it looks like the flashlight
-- players already know, and the F key still switches it: the client
-- asks and this relays, rather than lighting up locally. Off when dead
-- or spectating, and off again on every respawn -- so a player dropped
-- into the Fall switches it back on if they want the shaft lit on the
-- way down. The beam goes out once as the default config, so it covers
-- everybody including whoever joins next. (scripts.local/)
load "lib_flashlight"

-- aosprotocol's Silent Player extension (id 3 v1): lets the server keep
-- chosen player ids out of a client's scoreboard, player count, presence
-- notices, kill feed and stats, without changing anything about the
-- players themselves. Loading it does nothing on its own -- something has
-- to ask for an id to be hidden. lib_bot is what asks here, per bot, and
-- the Fall's fallers are the ones it asks about. Clients that have not
-- negotiated it see everybody as they always have. (scripts.local/)
load "lib_silent_player"

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
