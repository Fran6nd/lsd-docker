-- lib_callouts.lua -- What a team says to itself, from the pie menu
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Every gamemode has the things its players need to tell each other --
-- in babel "we have a digger", in ctf "they have our intel" -- and
-- typing them mid-fight is what nobody does. So each gamemode gets a pie
-- of callouts (callouts/<gamemode>.lua), placed before the generic pies,
-- and every wedge is one command:
--
--   /callout <key> [x y z]
--
-- which says the callout to the player's team, as the player's own team
-- chat -- in each teammate's language, which a wedge's text could not
-- be -- and, for a callout about a place, drops a Teamplay ping where
-- the player aims (%h), labelled, for teammates whose client shows
-- pings. A free-for-all says its callouts to everybody.
--
-- The gamemode is the one running (the `gamemode` setting); a mode with
-- no callouts file gets none. Every Gamemode requires this library, so
-- no gamemode -- upstream's included -- needs a line of its own.
--
-- A callouts file:
--
--   return {
--     theme = {en = "Babel"},          -- the pie's caption
--     global = false,                  -- true: said to everybody (ffa)
--     callouts = {                     -- six at most, slice 1 the top
--       {key = "digger", label = {en = "Digger!"},
--        say = {en = "We have a digger here!"}, ping = true},
--       ...
--     },
--   }
local mod = init_mod();

getcfg("callouts_gap", 1.5,
	"Seconds between two callouts from one player.");

-- the callouts of the gamemode running, by key; nil if it has none
local set = nil;
local by_key = {};

local function load_set()
	set, by_key = nil, {};
	local name = tostring(gamemode or "");
	if (not string.match(name, "^[%w_]+$")) then
		return;
	end
	local ok, s = pcall(require, "callouts." .. name);
	if (not ok or type(s) ~= "table") then
		return;
	end
	set = s;
	for _, c in ipairs(s.callouts or {}) do
		by_key[c.key] = c;
	end
end

-- The pie: a wedge per callout; one about a place sends where the
-- player aims (%h, filled in by the client).
local function pie()
	local slices = {};
	for i, c in ipairs(set.callouts) do
		slices[i] = {text = "/callout " .. c.key .. (c.ping and " %h" or ""),
			label = c.label, tooltip = c.say};
	end
	return {id = "callouts", theme = set.theme, when = "alive", slices = slices};
end

-- in the pie menu whenever there is one, as the editor does it
local pie_in = false;

local function add_pie()
	if (set == nil) then
		return;
	end
	if (pie_menu_add ~= nil and not pie_in) then
		pie_menu_add("callouts", pie(), 20);
		pie_in = true;
	elseif (pie_menu_add == nil) then
		pie_in = false;
	end
end

function mod.after.tick()
	add_pie();
end

local last = pid_connected_table(0);

local function is_person(i)
	return not (bot_is_bot ~= nil and bot_is_bot(i));
end

local cmd = {name = "callout", usage = "<key> [x y z]",
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
	local pos;
	if (c.ping and #argv >= 4) then
		local x, y, z = tonumber(argv[2]), tonumber(argv[3]), tonumber(argv[4]);
		if (x and y and z) then
			pos = {x = x, y = y, z = z};
		end
	end

	-- the player's own chat, team or global, in each reader's language
	local line = l10n_msg(c.say);
	for i in piditer(PID_BROADCAST) do
		if (is_person(i) and (everybody or get_team(i) == team)) then
			send_chat(i, line, everybody and 0 or 1, pid);
			if (pos ~= nil and teamplay_ping ~= nil) then
				teamplay_ping(i, pos, {from = pid, reason = l10n_str(i, c.label)});
			end
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
	end
	pie_in = false;
end

return mod;
