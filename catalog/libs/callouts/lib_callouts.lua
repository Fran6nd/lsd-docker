-- lib_callouts.lua -- What a team says to itself, from the pie menu
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
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
--   }
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
-- its pings, or the default ones
local pings = {};

local function load(name)
	local ok, s = pcall(require, "callouts." .. name);
	return ok and type(s) == "table" and s or nil;
end

local function load_set()
	set, by_key, pings = nil, {}, {};
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

local function ping_slices()
	local out = {};
	for i, p in ipairs(pings) do
		out[i] = {pie = MARK, slot = i, text = ping_text(p),
			label = p.label, tooltip = p.tooltip, show = can_ping};
	end
	return out;
end

-- in the pie menu whenever there is one, as the editor does it
local pie_in = false;

local function add_pie()
	if (pie_menu_add ~= nil and not pie_in) then
		pie_in = true;
		if (set ~= nil and #set.callouts > 0) then
			pie_menu_add("callouts", pie(), 20);
		end
		if (#pings > 0) then
			pie_menu_slice("callouts_pings", ping_slices(), 10);
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
	for i in piditer(PID_BROADCAST) do
		if (get_team(i) == team) then
			teamplay_ping(i, pos, {reason = reason, secs = callouts_event_secs});
		end
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
	for i in piditer(PID_BROADCAST) do
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
	for i in piditer(PID_BROADCAST) do
		local t = get_team(i);
		if ((t == 1 or t == 2) and t ~= carrier) then
			teamplay_mark(i, pid, TEAMPLAY_FOREVER,
				{reason = reason, clear_on_respawn = true});
		end
	end
end

function mod.after.capture_intel(pid)
	if (not intel_mode()) then return; end
	for i in piditer(PID_BROADCAST) do
		teamplay_clear(i, pid);
	end
end

local function is_person(i)
	return not (bot_is_bot ~= nil and bot_is_bot(i));
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
	local line = l10n_msg(c.say);
	for i in piditer(PID_BROADCAST) do
		if (is_person(i) and (everybody or get_team(i) == team)) then
			send_chat(i, line, everybody and 0 or 1, pid);
		end
	end
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
	end
	pie_in = false;
end

return mod;
