-- lib_inventory.lua -- What a player holds, used by command or by pie
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- An ITEM is a command: a kind of item is a label and the command line
-- it runs, and using one runs that command as the player who holds it.
-- Scripts define the kinds and hand items out; players use them
--
--   /inv                    what they hold: "1) Rocket x3  2) Medkit x1"
--   /inv <number|name>      use one (an aimed one is sent the point
--                           under the crosshair, as the pie does)
--
-- or from the pie menu: an Inventory pie (as many as it takes, six
-- wedges each) with a wedge per kind held, labelled with how many --
-- "Rocket x3", "x∞" for an unlimited one -- each player seeing their
-- own counts.
--
-- API (globals):
--   inventory_define(key, {label = {en=}, command = "reward rocket",
--                          aim = true, order = 10, bot = {...}})
--        a kind of item; `command` without its slash; `aim`: the use is
--        sent the point aimed at (x y z) after it; `order` sorts the list;
--        `bot`: when a bot should use it, see BOTS below
--   inventory_undefine(key)
--   inventory_give(pid, key [, n])      n defaults to 1; math.huge: unlimited
--   inventory_take(pid, key [, n])      -> how many were taken
--   inventory_set(pid, key, n)          exactly n (0: none, math.huge: unlimited)
--   inventory_count(pid, key)           -> how many (math.huge: unlimited)
--   inventory_use(pid, key [, pos])     -> true if one was used
--   inventory_using(pid)                -> the key being used, while its
--        command runs: a command that is also typed by hand tells the two
--        apart with it (rewards: typed, /reward rocket uses an item)
--   inventory_keep()                    called by an item's command that
--        did nothing (a medkit at full health): the item is not used up
--   inventory_kinds()                   -> {key = {label=, command=, aim=,
--        order=, bot=}}: every kind there is (a copy)
--   inventory_listen(name, {count = fn(pid, key, n), kind = fn(key, def)})
--        told of every change: a player's count of a kind (n; math.huge
--        for unlimited), and a kind defined or -- def nil -- undefined.
--        Registering a name again replaces it. inventory_unlisten(name)
--
-- BOTS. A bot holds items like anybody, and uses them by the same
-- command. WHEN it should is the item's to say, since only whoever made
-- the item knows what it is for:
--
--   bot = {tree = "seq\n\tif health_below 40\n\tdo use medkit",
--          guide = 0}
--
-- `tree` is a fragment of behaviour tree, in the bot engine's text
-- (bot/core/bt.h, its words in bot/core/vocab.h), tried by any bot that
-- holds the item, wherever its gamemode's tree says `tree items`.
-- `guide`: seconds the bot keeps its aim on the target after using it (a
-- guided missile). This module only carries it: lib_botlink listens
-- (inventory_listen) and tells the engine what each bot holds and what
-- each item's fragment is.
--
-- An item is used up after its command ran, unless it kept it. Items
-- last until the player leaves.
local mod = init_mod();

local MAX_WEDGES = 6;
local INFINITE = math.huge;

local kinds = {};     -- key -> {label, command, aim, order}
local held = pid_connected_table();   -- pid -> {key = count}
local using = nil;    -- {pid, key, keep} while an item's command runs

local empty_msg = {en = "Your inventory is empty."};
local head_msg = {en = "Your inventory -- use one with /inv <number>, or the pie menu:"};
local none_msg = {en = "You have none of that."};

local function bag(pid)
	if (type(held[pid]) ~= "table") then
		held[pid] = {};
	end
	return held[pid];
end

local function refresh(pid)
	if (pie_menu_refresh ~= nil) then
		pie_menu_refresh(pid);
	end
end

-- whoever follows the inventory (inventory_listen); one that raises is
-- dropped, as lib_shot_detect does with its own
local listeners = {};
local function tell(what, ...)
	for name, l in pairs(listeners) do
		if (l[what] ~= nil) then
			local ok, err = pcall(l[what], ...);
			if (not ok) then
				listeners[name] = nil;
				log("lib_inventory: listener %s raised, dropped: %s", name, tostring(err));
			end
		end
	end
end

-- a player's count of a kind changed
local function changed(pid, key)
	refresh(pid);
	local b = held[pid];
	tell("count", pid, key, type(b) == "table" and b[key] or 0);
end

function inventory_count(pid, key)
	local b = held[pid];
	return type(b) == "table" and b[key] or 0;
end

-- the kinds, in their order
local function sorted()
	local out = {};
	for key, k in pairs(kinds) do out[#out+1] = {key = key, kind = k}; end
	table.sort(out, function(a, b)
		local oa, ob = a.kind.order or 100, b.kind.order or 100;
		if (oa ~= ob) then return oa < ob; end
		return a.key < b.key;
	end);
	return out;
end

-- the kinds a player holds, in order
local function holding(pid)
	local out = {};
	for _, e in ipairs(sorted()) do
		if (inventory_count(pid, e.key) > 0) then out[#out+1] = e; end
	end
	return out;
end

-- "Rocket x3", in the player's language
local function label_for(pid, key)
	local k = kinds[key];
	local n = inventory_count(pid, key);
	local name = k and (l10n_str ~= nil and l10n_str(pid, k.label) or k.label.en) or key;
	return name .. " x" .. (n == INFINITE and "∞" or tostring(n));
end

--============================== THE PIE =============================--

local pie_in = false;

local function pies()
	local out, slices = {}, nil;
	for _, e in ipairs(sorted()) do
		if (slices == nil or #slices == MAX_WEDGES) then
			slices = {};
			out[#out+1] = {id = #out == 0 and "inventory" or ("inventory" .. (#out + 1)),
				theme = {en = "Inventory"}, when = "alive", slices = slices};
		end
		local key = e.key;
		slices[#slices+1] = {
			text = "/inv " .. key .. (e.kind.aim and " %h" or ""),
			label = function(pid) return label_for(pid, key); end,
			show = function(pid) return inventory_count(pid, key) > 0; end,
		};
	end
	return out;
end

local function republish()
	if (pie_menu_add == nil) then
		pie_in = false;
		return;
	end
	pie_in = true;
	if (next(kinds) == nil) then
		pie_menu_remove("inventory");
	else
		pie_menu_add("inventory", pies(), 25);
	end
end

--============================== THE API =============================--

function inventory_define(key, def)
	assert(type(key) == "string" and string.match(key, "^[%w_]+$"), "inventory_define: a key of letters, digits, _");
	assert(type(def) == "table" and type(def.label) == "table" and type(def.command) == "string",
		"inventory_define: {label = {en = ...}, command = ...}");
	kinds[key] = {label = def.label, command = (string.gsub(def.command, "^/", "")),
		aim = def.aim == true, order = tonumber(def.order),
		bot = type(def.bot) == "table" and def.bot or nil};
	republish();
	tell("kind", key, kinds[key]);
end

function inventory_undefine(key)
	if (kinds[key] == nil) then
		return;
	end
	kinds[key] = nil;
	republish();
	tell("kind", key, nil);
end

function inventory_kinds()
	local out = {};
	for key, k in pairs(kinds) do out[key] = k; end
	return out;
end

function inventory_listen(name, l)
	assert(type(name) == "string" and type(l) == "table", "inventory_listen(name, {count=, kind=})");
	listeners[name] = l;
end

function inventory_unlisten(name)
	listeners[name] = nil;
end

function inventory_give(pid, key, n)
	n = n or 1;
	local b = bag(pid);
	b[key] = (b[key] or 0) + n;
	changed(pid, key);
	return b[key];
end

function inventory_take(pid, key, n)
	n = n or 1;
	local have = inventory_count(pid, key);
	if (have == INFINITE) then
		return n;
	end
	local took = math.min(have, n);
	if (took > 0) then
		local b = bag(pid);
		b[key] = have - took;
		if (b[key] <= 0) then b[key] = nil; end
		changed(pid, key);
	end
	return took;
end

function inventory_set(pid, key, n)
	local b = bag(pid);
	b[key] = (n ~= nil and n > 0) and n or nil;
	changed(pid, key);
end

function inventory_using(pid)
	return using ~= nil and using.pid == pid and using.key or nil;
end

function inventory_keep()
	if (using ~= nil) then
		using.keep = true;
	end
end

function inventory_use(pid, key, pos)
	local k = kinds[key];
	if (k == nil or inventory_count(pid, key) <= 0 or using ~= nil) then
		return false;
	end
	local line = k.command;
	if (k.aim and pos ~= nil) then
		line = string.format("%s %.2f %.2f %.2f", line, pos.x, pos.y, pos.z);
	end
	using = {pid = pid, key = key, keep = false};
	local ok, err = pcall(handle_command, pid, line, true);
	local keep = using.keep;
	using = nil;
	if (not ok) then
		log("lib_inventory: %s for #%d raised: %s", key, pid, tostring(err));
		return false;
	end
	if (not keep) then
		inventory_take(pid, key, 1);
	end
	return not keep;
end

--============================== /inv ================================--

local function position(argv, from)
	local x, y, z = tonumber(argv[from]), tonumber(argv[from+1]), tonumber(argv[from+2]);
	if (x and y and z) then
		return {x = x, y = y, z = z};
	end
end

local cmd = {name = {"inv", "inventory"}, usage = "[number|name] [x y z]",
	desc = "Your inventory: /inv lists it, /inv <number|name> uses one."};
function cmd.func(pid, argv)
	local have = holding(pid);
	if (argv[1] == nil) then
		if (#have == 0) then
			l10n_send_chat(pid, empty_msg);
			return;
		end
		l10n_send_chat(pid, head_msg);
		local parts = {};
		for i, e in ipairs(have) do
			parts[#parts+1] = i .. ") " .. label_for(pid, e.key);
		end
		server_msg(pid, table.concat(parts, "  "));
		return;
	end
	local pick = tonumber(argv[1]);
	local key = pick and have[pick] and have[pick].key or string.lower(argv[1]);
	if (kinds[key] == nil or inventory_count(pid, key) <= 0) then
		l10n_send_chat(pid, none_msg);
		return;
	end
	inventory_use(pid, key, position(argv, 2));
end
register_command(cmd, mod);

function mod.after.tick()
	if (pie_menu_add ~= nil and not pie_in and next(kinds) ~= nil) then
		republish();
	elseif (pie_menu_add == nil) then
		pie_in = false;
	end
end

function mod.on_unload()
	if (pie_menu_remove ~= nil) then
		pie_menu_remove("inventory");
	end
	for _, name in ipairs({"inventory_define", "inventory_undefine", "inventory_give",
		"inventory_take", "inventory_set", "inventory_count", "inventory_kinds",
		"inventory_listen", "inventory_unlisten", "inventory_use", "inventory_using", "inventory_keep"}) do
		_G[name] = nil;
	end
end

return mod;
