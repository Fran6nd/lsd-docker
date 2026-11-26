-- lib_callouts.lua -- What a team says to itself, from the pie menu
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- Every gamemode has the things its players need to tell each other --
-- in babel "we have a digger", in ctf "they have our intel" -- and
-- typing them mid-fight is what nobody does. So each gamemode gets a pie
-- of callouts (callouts/<gamemode>.lua), placed before the generic pies,
-- and every wedge is one command:
--
--   /callout <key>
--
-- which says the callout to the player's team, as the player's own team
-- chat -- in each teammate's language, which a wedge's text could not
-- be. A free-for-all says its callouts to everybody. A callout is words
-- only: a place is pinged, never called out.
--
-- PINGS are the other half: a wedge in the pie menu's Mark pie (aiming
-- at a block or an enemy) per ping, offered only to players whose client
-- speaks Teamplay -- nobody else would see the marker. Each one is
-- Teamplay's own command, as its specification has it:
--
--   /pingmark <x> <y> <z> [reason...]      sent as /pingmark %h <reason>
--
-- under the rules a client's own Ping packet is held to. The reason is
-- the ping's label in the language of whoever pings (the wedge's text is
-- a language map, picked per player). A gamemode that lists no pings
-- gets callouts/default.lua's (Enemy, Attack...).
--
-- The gamemode is the one running (the `gamemode` setting); a mode with
-- no callouts file gets no callouts, and the default pings. Every Gamemode requires this library, so
-- no gamemode -- upstream's included -- needs a line of its own.
--
-- A callouts file:
--
--   return {
--     theme = {en = "Babel"},          -- the pie's caption
--     global = false,                  -- true: said to everybody (ffa)
--     callouts = {                     -- six at most, slice 1 the top
--       {key = "digger", label = {en = "Digger!"},
--        say = {en = "We have a digger here!"}},
--       ...
--     },
--     pings = {                        -- the Mark pie, six at most
--       {key = "intel", label = {en = "Intel here"}},
--       ...
--     },
--     builds = {                       -- the Build pie, six at most:
--       ...                            -- default.lua's when not said,
--     },                               -- none with builds = {}
--   }
--
-- BUILD PINGS: the Build pie's wedges are pings too, through the same
-- /pingmark, "Build <structure> here" -- a structure the bot engine can
-- build (bot/structures/*.kv6: "mirador", "bunker"). The engine takes
-- one from a LEADER (every person on a team is one) as an order to his
-- squad of bots to build that structure there (bot/core/skill_build.c).
-- A ping's reason is in the pinger's language; callouts_canonical gives
-- the English label back, which is what lib_botlink tells the engine.
--
-- EVENT PINGS: the gamemode pings for its players on its own events,
-- again only to clients that speak Teamplay (callouts_event_pings).
-- The intel dropped (its carrier died or left, or /drop) is pinned for
-- both teams, and whoever carries it is marked for the team it belongs
-- to until it is dropped or captured. They hang off drop_intel,
-- pickup_intel and capture_intel, which every CTF-like mode calls (ctf,
-- onectf, babel, arena; hostage's flag-carrying bots are left out).
-- A mode with moments of its own calls callouts_ping_team(team, pos,
-- reason) -- hostage does, when its hostage is loose or being freed.
local mod = init_mod();

getcfg("callouts_gap", 1.5,
	"Seconds between two callouts from one player.");
getcfg("callouts_event_pings", true,
	"Ping the intel where it was dropped, and mark its carrier, for "
	.. "players whose client supports Teamplay.");
getcfg("callouts_event_secs", 10,
	"Seconds an event ping stays on screen.");

-- the callouts of the gamemode running, by key; nil if it has none
local set = nil;
local by_key = {};
-- its pings, or the default ones; its build pings, or the default ones
local pings, builds = {}, {};

local function load(name)
	local ok, s = pcall(require, "callouts." .. name);
	return ok and type(s) == "table" and s or nil;
end

local function load_set()
	set, by_key, pings, builds = nil, {}, {}, {};
	local name = tostring(gamemode or "");
	if (string.match(name, "^[%w_]+$") and name ~= "default") then
		set = load(name);
	end
	if (set ~= nil and set.callouts == nil) then
		set.callouts = {};
	end
	for _, c in ipairs(set and set.callouts or {}) do
		by_key[c.key] = c;
	end
	pings = set and set.pings or (load("default") or {}).pings or {};
	builds = set and set.builds or (load("default") or {}).builds or {};
end

-- A ping's reason, said in any language, as its English label (what the
-- bot engine reads); the reason itself if it is none of this mode's.
function callouts_canonical(reason)
	local text = string.lower(tostring(reason or ""));
	for _, list in ipairs({pings, builds}) do
		for _, p in ipairs(list) do
			if (p.label ~= nil and p.label.en ~= nil) then
				if (string.lower(p.label.en) == text) then return p.label.en; end
				if (l10n_languages ~= nil and l10n_get_str_lang ~= nil) then
					for _, lang in ipairs(l10n_languages()) do
						if (string.lower(l10n_get_str_lang(lang, p.label)) == text) then
							return p.label.en;
						end
					end
				end
			end
		end
	end
	return reason;
end

-- The pie: a wedge per callout.
local function pie()
	local slices = {};
	for i, c in ipairs(set.callouts) do
		slices[i] = {text = "/callout " .. c.key, label = c.label, tooltip = c.say};
	end
	return {id = "callouts", theme = set.theme, when = "alive", slices = slices};
end

-- The ping wedges, into the Mark pie (created where an operator's own
-- menu has none), each shown only to a client that speaks Teamplay.
local MARK = {id = "mark", theme = {en = "Mark"}, when = "block enemy"};

local function can_ping(pid)
	return teamplay_supported ~= nil and teamplay_supported(pid) == true;
end

-- /pingmark %h <reason>, the reason in each language there is: the
-- pie menu gives every player the text of their own.
local function ping_text(p)
	local t = {en = "/pingmark %h " .. p.label.en};
	if (l10n_languages ~= nil and l10n_get_str_lang ~= nil) then
		for _, lang in ipairs(l10n_languages()) do
			t[lang] = "/pingmark %h " .. l10n_get_str_lang(lang, p.label);
		end
	end
	return t;
end

local function ping_slices(list, pie)
	local out = {};
	for i, p in ipairs(list) do
		out[i] = {pie = pie, slot = i, text = ping_text(p),
			label = p.label, tooltip = p.tooltip, show = can_ping};
	end
	return out;
end

-- the Build pie: aiming at a block, where the structure goes
local BUILD = {id = "build", theme = {en = "Build"}, when = "block"};

-- in the pie menu whenever there is one, as the editor does it
local pie_in = false;

local function add_pie()
	if (pie_menu_add ~= nil and not pie_in) then
		pie_in = true;
		if (set ~= nil and #set.callouts > 0) then
			pie_menu_add("callouts", pie(), 20);
		end
		if (#pings > 0) then
			pie_menu_slice("callouts_pings", ping_slices(pings, MARK), 10);
		end
		if (#builds > 0) then
			pie_menu_slice("callouts_builds", ping_slices(builds, BUILD), 10);
		end
	elseif (pie_menu_add == nil) then
		pie_in = false;
	end
end

function mod.after.tick()
	add_pie();
end

local last = pid_connected_table(0);

--=========================== EVENT PINGS ============================--

local OUR_DROP   = {en = "Our intel is here"};
local THEIR_DROP = {en = "Their intel is here"};
local THE_DROP   = {en = "The intel is here"};
local HAS_OUR    = {en = "Has our intel"};
local HAS_THE    = {en = "Has the intel"};

local function events_on()
	return callouts_event_pings and teamplay_ping ~= nil;
end

-- the intel events of the modes that carry it themselves, not hostage's
-- bots, whose flag never changes hands
local function intel_mode()
	return events_on() and tostring(gamemode) ~= "hostage";
end

-- ping everyone on a team, who can see it (global: modes call it)
function callouts_ping_team(team, pos, reason)
	if (not events_on()) then return; end
	for i in (people_in or piditer)(PID_BROADCAST_TEAM(team)) do
		teamplay_ping(i, pos, {reason = reason, secs = callouts_event_secs});
	end
end

local function finite(v)
	return v ~= nil and v.x ~= nil and math.abs(v.x) < math.huge
		and math.abs(v.y) < math.huge and math.abs(v.z) < math.huge;
end

-- the intel's owners are the carrier's enemies; onectf's belongs to nobody
function mod.after.drop_intel(pid, pos)
	if (not intel_mode()) then return; end
	-- onectf hides the second intel by dropping it at infinity
	pos = finite(pos) and pos or get_position(pid);
	local carrier = get_team(pid);
	local neutral = tostring(gamemode) == "onectf";
	for i in (people_in or piditer)(PID_BROADCAST) do
		local t = get_team(i);
		if (t == 1 or t == 2) then
			teamplay_ping(i, pos, {secs = callouts_event_secs,
				reason = neutral and THE_DROP or (t == carrier and THEIR_DROP or OUR_DROP)});
			teamplay_clear(i, pid);
		end
	end
end

function mod.after.pickup_intel(pid)
	if (not intel_mode()) then return; end
	local carrier = get_team(pid);
	local reason = tostring(gamemode) == "onectf" and HAS_THE or HAS_OUR;
	for i in (people_in or piditer)(PID_BROADCAST) do
		local t = get_team(i);
		if ((t == 1 or t == 2) and t ~= carrier) then
			teamplay_mark(i, pid, TEAMPLAY_FOREVER,
				{reason = reason, clear_on_respawn = true});
		end
	end
end

function mod.after.capture_intel(pid)
	if (not intel_mode()) then return; end
	for i in (people_in or piditer)(PID_BROADCAST) do
		teamplay_clear(i, pid);
	end
end


local cmd = {name = "callout", usage = "<key>",
	desc = "Say a gamemode callout to your team (the pie menu sends these)."};
function cmd.func(pid, argv)
	local c = argv[1] and by_key[string.lower(argv[1])];
	if (c == nil) then
		return;
	end

	local now = get_time();
	if (now - last[pid] < callouts_gap) then
		return;
	end
	last[pid] = now;

	local team = get_team(pid);
	local everybody = set.global == true;

	-- the player's own chat, team or global, in each reader's language
	-- (one send to the group: lib_l10n makes it a send for each reader)
	send_chat(everybody and PID_BROADCAST or PID_BROADCAST_TEAM(team),
		l10n_msg(c.say), everybody and 0 or 1, pid);
end
register_command(cmd, mod);

function mod.on_load()
	load_set();
	add_pie();
end

function mod.on_unload()
	if (pie_menu_remove ~= nil) then
		pie_menu_remove("callouts");
		pie_menu_remove("callouts_pings");
		pie_menu_remove("callouts_builds");
	end
	pie_in = false;
end

return mod;
