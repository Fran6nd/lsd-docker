-- lib_rewards.lua -- Rewards for kills and captures, in the inventory
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Under any gamemode: every rewards_kills kills a player makes (counted
-- across lives, from the map's start), and every intel capture
-- (rewards_capture), earns a REWARD: one of rewards_menu at random --
-- the costlier, the rarer -- put in the player's inventory (lib_inventory),
-- used from there like any item:
--
--   /inv                the inventory: "1) Rocket x2  2) Airstrike x1"
--   /inv <number|name>  use one -- or its wedge in the Inventory pie,
--                       labelled with how many
--   /reward rocket      the same, by the reward's name
--
-- A player holds at most rewards_max rewards; at the cap the kill count
-- waits, so the next one is a kill away once one is used.
--
-- Each reward is an inventory item whose command is /reward <name>: run
-- from the inventory it gives the effect; typed, it uses an item of the
-- player's, if they hold one -- never a free one. A reward that cannot
-- be used right now (a medkit at full health, night vision by day) is
-- not used up.
--
-- THE MENU is a setting, a list of
--
--   {effect = "railgun", cost = 1, label = {en = "Railgun"},
--    secs = 30, death = true}          -- given for 30 s, or until death
--   {effect = "medkit", cost = 1, trigger = true, opts = {free = true}}
--                                     -- set off at once, not kept
--   {effect = "airstrike", cost = 2, trigger = true, aim = true}
--                                     -- aim: takes the point aimed at
--   {effect = "nightvision", cost = 1, night = true, secs = 60}
--                                     -- night: usable only at night
--
-- `cost` is how rare it is: a reward of cost 2 comes up half as often as
-- one of cost 1. An effect that is not loaded is not handed out: effects
-- stay separately installable, so this offers whatever is there.
--
-- rewards_free (demo_reward): every reward, unlimited -- x∞ in the
-- inventory -- for everybody.
--
-- WHO ELSE HAS IT. A player effect is everybody's while its
-- <id>_everyone is true, which is its default: install the railgun and
-- every rifle is one. A reward the railgun is not worth that, so while
-- rewards_exclusive (the default) the effects of the menu are taken
-- away from everybody and are held only by those who earned them,
-- whatever <id>_everyone says. Put rewards_exclusive = false to leave
-- an effect that is on for everybody as it is (the rewards then add
-- nothing to it, but a trigger -- medkit, airstrike -- still works).
local mod = init_mod();

getcfg("rewards_kills", 10, "Kills (across lives, per map) for one reward.");
getcfg("rewards_capture", 1, "Rewards for an intel capture.");
getcfg("rewards_max", 3, "Most rewards a player can hold.");
getcfg("rewards_exclusive", true,
	"Effects offered as rewards are held only by those who earned them, "
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
	{effect = "grenade_launcher", cost = 1, trigger = true,
		label = {en = "Grenade launcher"}},
	{effect = "airstrike", cost = 2, trigger = true, aim = true,
		label = {en = "Airstrike"}},
	{effect = "medkit", cost = 1, trigger = true, opts = {free = true},
		label = {en = "Medkit"}},
	{effect = "area_heal", cost = 1, secs = 20,
		label = {en = "Area heal"}},
	{effect = "nightvision", cost = 1, secs = 60, night = true, death = true,
		label = {en = "Night vision"}},
}, "What a reward may be: a list of {effect, cost (how rare), label, secs | charges | trigger, death, night}.");

getcfg("rewards_free", false,
	"Every reward free and unlimited, for trying them out (demos).");

local INFINITE = math.huge;
local kills = pid_connected_table(0);

local earned_you = {en = "You earned: %(what). Use it with /inv, or the pie menu."};
local earned_all = {en = "%(name) earned a reward"};
local dead_msg = {en = "Rewards are for the living."};
local night_msg = {en = "%(what) is only for the night."};
local unknown_msg = {en = "No such reward. Your rewards are in your inventory: /inv."};
local failed_msg = {en = "%(what) could not be used right now; you keep it."};
local none_msg = {en = "You have no %(what): rewards come every %(kills) kills, and with every capture."};

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
			e.key = string.lower(tostring(e.name or e.effect));
			out[#out+1] = e;
		end
	end
	return out;
end

local function by_key(key)
	key = string.lower(key);
	for _, e in ipairs(menu()) do
		if (e.key == key) then
			return e;
		end
	end
end

local function is_night()
	return daytime_is_night ~= nil and daytime_is_night() == true;
end

-- is the reward there to be had at all: its effect loaded
local function offered(e)
	return PlayerEffect.get(e.effect) ~= nil;
end

local function say_what(pid, e)
	return l10n_str(pid, e.label);
end

-- each offered reward an inventory item, its command /reward <name>
local defined = {};
local function define_items()
	if (inventory_define == nil) then
		return;
	end
	for i, e in ipairs(menu()) do
		if (offered(e) and not defined[e.key]) then
			defined[e.key] = true;
			inventory_define(e.key, {label = e.label, command = "reward " .. e.key,
				aim = e.aim == true, order = i});
		elseif (not offered(e) and defined[e.key]) then
			defined[e.key] = nil;
			inventory_undefine(e.key);
		end
	end
end

--============================== EARNING =============================--

local function held(pid)
	local n = 0;
	for _, e in ipairs(menu()) do
		local c = inventory_count(pid, e.key);
		if (c ~= INFINITE) then n = n + c; end
	end
	return n;
end

-- one reward at random, the costlier the rarer; nil with none to give
local function draw()
	local pool, total = {}, 0;
	for _, e in ipairs(menu()) do
		if (offered(e)) then
			local w = 1 / math.max(1, tonumber(e.cost));
			pool[#pool+1] = {e = e, w = w};
			total = total + w;
		end
	end
	local r = math.random() * total;
	for _, p in ipairs(pool) do
		r = r - p.w;
		if (r <= 0) then return p.e; end
	end
	return pool[#pool] and pool[#pool].e;
end

local function award(pid, n)
	if (rewards_free) then
		return false; -- everybody holds everything already
	end
	local given = 0;
	for _ = 1, n do
		if (held(pid) >= rewards_max) then
			break;
		end
		local e = draw();
		if (e == nil) then
			break;
		end
		define_items();
		inventory_give(pid, e.key, 1);
		given = given + 1;
		l10n_send_chat(pid, earned_you, {what = e.label});
	end
	if (given > 0) then
		l10n_send_chat(PID_BROADCAST, earned_all, {name = get_name(pid)});
	end
	return given > 0;
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
	-- at the cap the count waits, so the next reward is one kill away
	-- once one is used, and not ten
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

--============================== USING ===============================--

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

-- the reward's effect, run as an inventory item: anything that stops it
-- keeps the item
local function apply(pid, e, pos)
	local fx = PlayerEffect.get(e.effect);
	local what = say_what(pid, e);
	local why;
	if (fx == nil) then
		why = {unknown_msg};
	elseif (not is_alive(pid)) then
		why = {dead_msg};
	elseif (e.night and not is_night()) then
		why = {night_msg, {what = what}};
	elseif (not give(pid, e, fx, pos)) then
		why = {failed_msg, {what = what}};
	end
	if (why ~= nil) then
		inventory_keep();
		l10n_send_chat(pid, why[1], why[2]);
	end
end

local cmd = {name = "reward", usage = "[name] [x y z]",
	desc = "Use one of your rewards (they are in your inventory: /inv)."};
function cmd.func(pid, argv)
	local e = argv[1] and by_key(argv[1]);
	if (e == nil) then
		l10n_send_chat(pid, unknown_msg);
		return;
	end
	local x, y, z = tonumber(argv[2]), tonumber(argv[3]), tonumber(argv[4]);
	local pos = x and y and z and {x = x, y = y, z = z} or nil;
	if (inventory_using(pid) == e.key) then
		apply(pid, e, pos);
	elseif (inventory_count(pid, e.key) > 0) then
		-- typed by hand: one of theirs, through the inventory
		inventory_use(pid, e.key, pos);
	else
		l10n_send_chat(pid, none_msg, {what = e.label, kills = rewards_kills});
	end
end
register_command(cmd, mod);

--============================== FREE ================================--

-- rewards_free: everybody holds every reward, unlimited -- whoever
-- joins too, within the second -- taken back when it is turned off
local was_free = false;
local function free_for(pid)
	for _, e in ipairs(menu()) do
		if (offered(e) and inventory_count(pid, e.key) ~= INFINITE) then
			inventory_give(pid, e.key, INFINITE);
		end
	end
end

local function sync_free()
	if (rewards_free) then
		for pid in piditer(PID_BROADCAST) do free_for(pid); end
	elseif (was_free) then
		for pid in piditer(PID_BROADCAST) do
			for _, e in ipairs(menu()) do
				if (inventory_count(pid, e.key) == INFINITE) then
					inventory_set(pid, e.key, 0);
				end
			end
		end
	end
	was_free = rewards_free == true;
end

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

local next_check = 0;

function mod.after.tick()
	local now = get_time();
	if (now >= next_check) then
		next_check = now + 1;
		claim();
		define_items();
		sync_free();
	end
end

function mod.on_load()
	claim();
	define_items();
end

function mod.on_unload()
	for key in pairs(defined) do
		if (inventory_undefine ~= nil) then inventory_undefine(key); end
	end
	defined = {};
	for name in pairs(taken) do
		local fx = PlayerEffect.get(name);
		if (fx ~= nil) then
			fx.everyone = _G[name .. "_everyone"] ~= false;
		end
	end
	taken = {};
end

return mod;
