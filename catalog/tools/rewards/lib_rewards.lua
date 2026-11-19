-- lib_rewards.lua -- Reward points, spent on a player effect
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Under any gamemode: every rewards_kills kills a player makes (counted
-- across lives, from the map's start) earns a point, and so does an
-- intel capture (rewards_capture). A player holds at most rewards_max
-- points. They are spent on one of the rewards of rewards_menu:
--
--   /reward            what there is, and the points held
--   /reward railgun    spend the points it costs, get it
--
-- and from the pie menu, a pie with a wedge for each reward the player
-- can afford right now -- the others are not shown. An airstrike's
-- wedge sends the point under the crosshair (%h), so it lands where the
-- player looks.
--
-- THE MENU is a setting, a list of
--
--   {effect = "railgun", cost = 1, label = {en = "Railgun"},
--    secs = 30, death = true}          -- given for 30 s, or until death
--   {effect = "rocket", cost = 1, charges = 3, ...}
--                                     -- three charges, one a shot
--   {effect = "medkit", cost = 1, trigger = true, opts = {free = true}}
--                                     -- set off at once, not kept
--   {effect = "airstrike", cost = 2, trigger = true, aim = true}
--                                     -- aim: takes the %h point
--   {effect = "nightvision", cost = 1, night = true, secs = 60}
--                                     -- night: offered only at night
--
-- An effect that is not loaded is not offered: effects stay separately
-- installable, so this offers whatever is there.
--
-- WHO ELSE HAS IT. A player effect is everybody's while its
-- <id>_everyone is true, which is its default: install the railgun and
-- every rifle is one. A reward the railgun is not worth that, so while
-- rewards_exclusive (the default) the effects of the menu are taken
-- away from everybody and are held only by those who bought them,
-- whatever <id>_everyone says. Put rewards_exclusive = false to leave
-- an effect that is on for everybody as it is (the rewards then add
-- nothing to it, but a trigger -- medkit, airstrike -- still works).
local mod = init_mod();

getcfg("rewards_kills", 10, "Kills (across lives, per map) for one reward point.");
getcfg("rewards_capture", 1, "Reward points for an intel capture.");
getcfg("rewards_max", 3, "Most reward points a player can hold.");
getcfg("rewards_exclusive", true,
	"Effects offered as rewards are held only by those who bought them, "
	.. "even if their <id>_everyone setting is true.");
getcfg("rewards_menu", {
	{effect = "railgun", cost = 1, secs = 30, death = true,
		label = {en = "Railgun"}},
	-- fired at once, like the airstrike, at the point aimed at
	{effect = "rocket", cost = 1, trigger = true, aim = true,
		label = {en = "Rocket"}},
	-- steered by the buyer's aim for as long as it flies
	{effect = "missile", cost = 2, trigger = true, aim = true,
		label = {en = "Missile"}},
	{effect = "airstrike", cost = 2, trigger = true, aim = true,
		label = {en = "Airstrike"}},
	{effect = "medkit", cost = 1, trigger = true, opts = {free = true},
		label = {en = "Medkit"}},
	{effect = "area_heal", cost = 1, secs = 20,
		label = {en = "Area heal"}},
	{effect = "nightvision", cost = 1, secs = 60, night = true, death = true,
		label = {en = "Night vision"}},
}, "What reward points buy: a list of {effect, cost, label, secs | charges | trigger, death, night}.");

getcfg("rewards_free", false,
	"Every reward free and unlimited, for trying them out (demos).");

local MAX_WEDGES = 6;

local points = pid_connected_table(0);
local kills = pid_connected_table(0);

local earned_you = {en = "You earned a reward point (%(points)/%(max)). Spend it: /reward, or the pie menu."};
local earned_all = {en = "%(name) earned a reward"};
local list_head = {en = "Rewards -- you have %(points) point(s):"};
local list_line = {en = "  /reward %(name): %(label), %(cost) point(s)"};
local list_none = {en = "  Nothing is on offer here."};
local got_msg = {en = "You got: %(what). Points left: %(points)."};
local poor_msg = {en = "%(what) costs %(cost) point(s) and you have %(points)."};
local dead_msg = {en = "Rewards are for the living."};
local night_msg = {en = "%(what) is only offered at night."};
local unknown_msg = {en = "No such reward. Type /reward for the list."};
local failed_msg = {en = "%(what) could not be used right now; no point spent."};

--============================== THE MENU ============================--

-- the menu's entries that make sense, keyed by name
local function menu()
	local out = {};
	if (type(rewards_menu) ~= "table") then
		return out;
	end
	for _, e in ipairs(rewards_menu) do
		if (type(e) == "table" and type(e.effect) == "string"
		    and tonumber(e.cost) ~= nil and type(e.label) == "table") then
			e.key = tostring(e.name or e.effect);
			out[#out+1] = e;
		end
	end
	return out;
end

local function by_key(key)
	key = string.lower(key);
	for _, e in ipairs(menu()) do
		if (string.lower(e.key) == key) then
			return e;
		end
	end
end

local function is_night()
	return daytime_is_night ~= nil and daytime_is_night() == true;
end

-- is the reward on offer at all, to anybody, right now
local function offered(e)
	return PlayerEffect.get(e.effect) ~= nil and (not e.night or is_night());
end

local function affordable(e, pid)
	return offered(e) and (rewards_free or points[pid] >= tonumber(e.cost));
end

--============================== EARNING =============================--

local function refresh(pid)
	if (pie_menu_refresh ~= nil) then
		pie_menu_refresh(pid);
	end
end

local function award(pid, n)
	local was = points[pid];
	points[pid] = math.min(rewards_max, was + n);
	if (points[pid] == was) then
		return false;
	end
	l10n_send_chat(pid, earned_you, {points = points[pid], max = rewards_max});
	l10n_send_chat(PID_BROADCAST, earned_all, {name = get_name(pid)});
	refresh(pid);
	return true;
end

local function counts(pid, ktype, killer)
	if (killer == nil or killer == pid or not is_connected(killer)
	    or (ktype ~= nil and ktype >= 4)) then
		return false;
	end
	-- a free-for-all puts everybody on one team
	return get_team(killer) ~= get_team(pid) or tostring(gamemode) == "ffa";
end

function mod.after.kill(pid, ktype, killer)
	if (not counts(pid, ktype, killer)) then
		return;
	end
	kills[killer] = kills[killer] + 1;
	-- at the cap the count waits, so the next point is one kill away
	-- once one is spent, and not ten
	if (kills[killer] >= rewards_kills and award(killer, 1)) then
		kills[killer] = 0;
	end
end

function mod.after.capture_intel(pid)
	-- tdm ends its game with a capture that is not one
	if (tostring(gamemode) ~= "tdm" and rewards_capture > 0) then
		award(pid, rewards_capture);
	end
end

function mod.after.load_map()
	for pid in pairs(kills) do
		if (type(pid) == "number") then kills[pid] = 0; end
	end
end

--============================== SPENDING ============================--

local function say_what(pid, e)
	return l10n_str(pid, e.label);
end

local function give(pid, e, fx, pos)
	if (e.trigger) then
		local opts = {};
		for k, v in pairs(e.opts or {}) do opts[k] = v; end
		if (e.aim and pos ~= nil) then
			opts.pos = pos;
		end
		return fx:trigger(pid, opts) ~= nil;
	end

	local base = {stack = true, death = e.death, secs = tonumber(e.secs),
		minutes = tonumber(e.minutes), map = e.map};
	for _ = 1, tonumber(e.charges) or 1 do
		fx:give(pid, base);
	end
	return true;
end

local function spend(pid, e, pos)
	local what = say_what(pid, e);
	local fx = PlayerEffect.get(e.effect);

	if (fx == nil) then
		l10n_send_chat(pid, unknown_msg);
	elseif (not is_alive(pid)) then
		l10n_send_chat(pid, dead_msg);
	elseif (e.night and not is_night()) then
		l10n_send_chat(pid, night_msg, {what = what});
	elseif (not rewards_free and points[pid] < tonumber(e.cost)) then
		l10n_send_chat(pid, poor_msg, {what = what, cost = e.cost, points = points[pid]});
	elseif (not give(pid, e, fx, pos)) then
		l10n_send_chat(pid, failed_msg, {what = what});
	else
		if (not rewards_free) then
			points[pid] = points[pid] - tonumber(e.cost);
		end
		l10n_send_chat(pid, got_msg, {what = what, points = points[pid]});
		refresh(pid);
	end
end

local cmd = {name = "reward", usage = "[name]",
	desc = "Spend your reward points: /reward lists what you can get."};
function cmd.func(pid, argv)
	local e = argv[1] and by_key(argv[1]);
	if (e ~= nil) then
		local x, y, z = tonumber(argv[2]), tonumber(argv[3]), tonumber(argv[4]);
		spend(pid, e, x and y and z and {x = x, y = y, z = z} or nil);
		return;
	end
	if (argv[1] ~= nil) then
		l10n_send_chat(pid, unknown_msg);
	end

	l10n_send_chat(pid, list_head, {points = points[pid]});
	local any = false;
	for _, m in ipairs(menu()) do
		if (offered(m)) then
			any = true;
			l10n_send_chat(pid, list_line, {name = m.key, label = say_what(pid, m),
				cost = m.cost});
		end
	end
	if (not any) then
		l10n_send_chat(pid, list_none);
	end
end
register_command(cmd, mod);

--============================== THE PIE =============================--

-- A pie holds six wedges; a longer menu goes on in a second pie, a
-- third..., offered in the same contexts, right after the first. A pie
-- left with nothing affordable on it is not sent at all.
local function pies()
	local out, slices = {}, nil;
	for _, e in ipairs(menu()) do
		if (slices == nil or #slices == MAX_WEDGES) then
			slices = {};
			out[#out+1] = {id = #out == 0 and "rewards" or ("rewards" .. (#out + 1)),
				theme = {en = "Rewards"}, when = "alive", slices = slices};
		end
		slices[#slices+1] = {
			text = "/reward " .. e.key .. (e.aim and " %h" or ""),
			label = e.label,
			show = function(pid) return affordable(e, pid); end,
		};
	end
	return out;
end

local pie_in = false;
local was_night = false;
local next_check = 0;

-- the effects offered are not everybody's: see WHO ELSE HAS IT
local taken = {};
local function claim()
	if (not rewards_exclusive) then
		return;
	end
	for _, e in ipairs(menu()) do
		local fx = PlayerEffect.get(e.effect);
		if (fx ~= nil and fx.everyone) then
			fx.everyone = false;
			taken[e.effect] = true;
		end
	end
end

-- wedges come and go with the night; daytime_set_night is a plain
-- global, not a hook, so the change is looked for
function mod.after.tick()
	if (pie_menu_add ~= nil and not pie_in) then
		pie_in = true;
		pie_menu_add("rewards", pies(), 30);
	elseif (pie_menu_add == nil) then
		pie_in = false;
	end

	local now = get_time();
	if (now >= next_check) then
		next_check = now + 1;
		claim();
		local night = is_night();
		if (night ~= was_night) then
			was_night = night;
			refresh();
		end
	end
end

function mod.on_load()
	claim();
	was_night = is_night();
end

function mod.on_unload()
	if (pie_menu_remove ~= nil) then
		pie_menu_remove("rewards");
	end
	pie_in = false;
	for name in pairs(taken) do
		local fx = PlayerEffect.get(name);
		if (fx ~= nil) then
			fx.everyone = _G[name .. "_everyone"] ~= false;
		end
	end
	taken = {};
end

return mod;
