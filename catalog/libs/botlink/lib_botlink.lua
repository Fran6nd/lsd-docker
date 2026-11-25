-- lib_botlink.lua -- The server's side of the link to the bot engine
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- The engine (botd, another process) decides what the bots do; this is
-- how it sees the game and how its decisions reach it. Everything goes
-- through one memory-mapped file whose layout is bot/link/botlink.h --
-- the header is the contract and is read, not copied, at load.
--
--   world    rewritten whole after every tick (who is where, the score,
--            the intel and the tents, night)
--   events   pushed as they happen: blocks, kills, hurts, shots, grenades,
--            pings, a map, a bot made or removed, settings, orders
--   intents  one per bot, read before every tick: keys, aim, tool, trigger
--   actions  drained before every tick, bounded: blocks, lines, grenades,
--            commands, colour, log, pings
--
-- The server stays the authority. An intent is keys held, as a client's
-- would be; an action goes through the same chains a player's does, as
-- that bot (on_block_action, on_block_line, on_grenade, on_hit,
-- handle_command), after the checks the packet validator would make for
-- a client (it is not in the chain, so they are made here).
--
-- API (globals, defined whether or not the link works; they do nothing
-- when it does not):
--   botlink_add{team=, level=, gun=, name=, seed=,
--               tree=, at=, once=} -> pid | nil
--        `tree`: the behaviour tree this one bot runs instead of the
--        gamemode's -- a built-in tree's name, or the text of one
--        (bot/TREES.md) -- which is how a mode gives a bot a role of its
--        own: a guard, a courier, a boss. Changed at any time with
--        botlink_set("tree", name_or_text, pid).
--        `at`: where it spawns, a position {x=, y=, z=} or a
--        function(pid) -> position | nil, asked at every spawn; without
--        it (or on nil) the bot spawns where the gamemode puts a player.
--        `once`: one life -- when it dies it leaves the server.
--   botlink_remove(pid)
--   botlink_set(key, value [, pid])      -- a rule or setting, for all or one bot
--        A value of any length up to 60000 bytes (a tree's text): sent
--        in pieces when it is over a record, never cut short. -> true,
--        or false (and a line in the log) for one that is too long.
--   botlink_tree_apply(tree, pids | nil) -> how many bots, | nil, why
--        a tree for some bots (their own) or, with no pids, for the
--        world. `tree` is a name, or {file = "<name>.bt"}: a text an
--        administration tool left in <botlink_map_dir>botdebug/ (the
--        name alone, letters digits _ and -: no path is taken).
--   botlink_tree_revert(pids | nil) -> how many
--        those bots back to the world's tree; with no pids, the world
--        back to engine_bots_tree, else the gamemode's.
--   botlink_set("fact.<name>", number [, pid])   a fact a tree reads
--        (`if fact <name> [min]`, `option <trait> fact <name>`), for
--        every bot or one; "" forgets it
--   botlink_set("place.<name>", "x y z" | "pid <n>" [, pid])   a place a
--        tree names `@<name>`: a point, or where that player is; ""
--        forgets it
--   botlink_on(name, function(pid, words) end), botlink_off(name)
--        what a tree's `do tell <name> [words...]` calls
--   botlink_order(pid, {order=, pos=, target=, secs=})
--   botlink_alive() -> is an engine attached and beating
--   botlink_stats() -> counters (dropped actions, refused ones, ...)
--
-- THE FILE IS MADE ON THE FIRST botlink_add, not at load: a server with
-- no bots configured has none. It is closed (marked closing, bots taken
-- out) when this module unloads, which core.lua's on_shutdown does for
-- every module -- so a stop, a reload and the restart a gamemode switch
-- makes all go the one way.
--
-- WHAT THE SERVER'S LUA CANNOT TELL US, and what is done instead:
--   * blocks and grenades a player carries: no getter. Counted here for
--     the bots (50 and 3 at spawn and restock, one off per block built
--     or grenade thrown, one back per block dug); other players' are
--     written as 0.
--   * who damaged someone: not in set_hp. The damage_player and
--     damage_player_directional calls are watched and the set_hp that
--     lands inside them is attributed; a set_hp from a script (a fall,
--     drowning, a mode) has by = BL_NO_PLAYER and "from" = the victim.
--   * collapses: the core's map_cull removes floating voxels in C, tells
--     Lua nothing, and tells a client nothing under the OpenSpades cull
--     personality. The engine runs the same cull on its own copy of the
--     map from the BLOCK events (core/cull.c).
--   * a spade hit on a player: silent by design, no sound event.
--   * footsteps: no event; the engine derives them from the world.
--   * who scoped: C's mouse bit 2 is real for bots too (set through
--     on_mouse_input); bit 1 is never set for a bot, because that would
--     arm the engine's own fire estimator on top of lib_bot's shot.
local mod = init_mod();

local ffi = require("ffi");
local bit = require("bit");
local band, bor = bit.band, bit.bor;

getcfg("botlink_header", "botlink.h", "The link's header (its path, or a name looked for beside the scripts).");
getcfg("botlink_lib", "libbotlink.so", "The link's library (its path, or a name looked for beside the scripts).");
getcfg("botlink_file", "/dev/shm/lsd-botlink", "The file shared with the bot engine.");
getcfg("botlink_threads", 1, "Threads the bot engine's route planner runs on, read when botd starts (0: half the cores, at most 4).");
getcfg("botlink_stale", 2, "Seconds of engine silence after which every bot stands still.");
getcfg("botlink_map_dir", (os.getenv("LSD_DATA") or "/data") .. "/rw/", "Where the map the engine loads is written.");
getcfg("botlink_world_hz", 30, "Times a second the world is written for the engine (1 to 60); everything else is per tick.");
getcfg("botlink_actions_per_tick", 64, "Most engine actions applied in one tick.");
getcfg("botlink_reach", 5, "Blocks a bot may build or dig away from its eye.");
getcfg("botlink_build_secs", 0.1, "Seconds between a bot's blocks.");
getcfg("botlink_line_secs", 0.5, "Seconds between a bot's lines.");
getcfg("botlink_dig_secs", 0.25, "Seconds between a bot's digs.");
getcfg("botlink_dig3_secs", 1.0, "Seconds between a bot's 3x digs.");

local NO_PLAYER = 255;

local L, f = nil, nil;     -- the library, and the file once made
local inert_why = nil;     -- why nothing works, once known
local w, players, intents; -- views into f
local attached, frozen = false, false;
local engine_seen = 0;      -- the engine_pid of the engine attached last
local last_move, beat_last = -1e9, ffi.new("uint32_t[1]");
local tick_n, wcount, map_seq, map_file_n = 0, 0, 1, 0;
local loading = false;
local acting = nil;        -- the bot whose action is being applied

local stats = {ev_dropped = 0, ac_dropped = 0, ac_refused = 0, attaches = 0, actions = 0, errors = 0,
	tells = 0, tells_unheard = 0};
local tell_handlers = {};  -- name -> function(pid, args), for a tree's `do tell <name> ...`

local ours = {};           -- pid -> {level=, gun=, seed=, team=}
local life, blocks, grenades = {}, {}, {};
local firing, scoped = {}, {};
local next_block, ping_at = {}, {};
local lastori = {};        -- pid -> {x,y,z} last applied
local present, seen = {}, {};
local settings, psettings, orders = {}, {}, {};
local leaving = {};        -- one-life bots that died, taken out at the next tick
local nslots = 0;
for i = 0, 255 do
	life[i], blocks[i], grenades[i] = 0, 0, 0;
	next_block[i], ping_at[i], seen[i] = 0, -1e9, -1;
end

local function warn(fmt, ...)
	log("lib_botlink: " .. fmt, ...);
end

--============================ LOADING ===============================--

local function slurp(path)
	local fh = io.open(path, "rb");
	if (fh == nil) then return nil; end
	local s = fh:read("*a");
	fh:close();
	return s;
end

local function dirs(name)
	if (string.find(name, "/", 1, true)) then
		return {name};
	end
	local data = os.getenv("LSD_DATA") or "/data";
	return {"./" .. name, "scripts/" .. name, "exec/" .. name, data .. "/" .. name,
		"/opt/botd/" .. name, "/usr/local/lib/botlink/" .. name,
		"/usr/local/include/" .. name, "/usr/lib/" .. name};
end

local make_buffers; -- below

local function load_link()
	if (not pcall(ffi.typeof, "bl_file")) then
		local src;
		for _, p in ipairs(dirs(botlink_header)) do
			src = slurp(p);
			if (src ~= nil) then break; end
		end
		if (src == nil) then
			return "header " .. botlink_header .. " not found";
		end
		src = string.gsub(src, "[^\n]*", function(l)
			if (string.match(l, "^%s*#")) then return ""; end
		end);
		local ok, err = pcall(ffi.cdef, src);
		if (not ok) then return "header: " .. tostring(err); end
	end

	local lib, err;
	for _, p in ipairs(dirs(botlink_lib)) do
		local ok, r = pcall(ffi.load, p);
		if (ok) then lib = r; break; end
		err = r;
	end
	if (lib == nil and not string.find(botlink_lib, "/", 1, true)) then
		local ok, r = pcall(ffi.load, botlink_lib);
		if (ok) then lib = r; end
	end
	if (lib == nil) then
		return "library " .. botlink_lib .. " not loaded: " .. tostring(err);
	end

	local ok, good = pcall(lib.bl_layout_ok);
	if (not ok or good ~= 1) then
		return "the header and the library disagree on the layout";
	end
	L = lib;
	make_buffers();
	return nil;
end

-- The file, made on the first request for a bot.
local function open_file()
	if (f ~= nil) then return true; end
	if (L == nil) then return false; end
	local file = L.bl_create(botlink_file);
	if (file == nil) then
		inert_why = "cannot create " .. botlink_file;
		warn("inert: %s", inert_why);
		L = nil;
		return false;
	end
	f = file;
	w, players, intents = f.world, f.world.players, f.intents;
	nslots = math.min(MAX_PLAYERS or 32, 256);
	beat_last[0] = f.header.engine_beat;
	attached, frozen, last_move = false, false, -1e9;
	warn("link up at %s", botlink_file);
	return true;
end

--============================= EVENTS ===============================--

local rec_buf = ffi.new("uint8_t[?]", 1024);
-- made once the header is known (see make_buffers)
local ev_block, ev_line, ev_kill, ev_hurt, ev_sound, ev_grenade, ev_ping, ev_bot, ev_order, ev_map;
local ac_block, ac_line, ac_grenade, ac_ping, ac_u32, rec, PSIZE;

make_buffers = function()
	ev_block, ev_line, ev_kill = ffi.new("bl_ev_block"), ffi.new("bl_ev_line"), ffi.new("bl_ev_kill");
	ev_hurt, ev_sound, ev_grenade = ffi.new("bl_ev_hurt"), ffi.new("bl_ev_sound"), ffi.new("bl_ev_grenade");
	ev_ping, ev_bot, ev_order, ev_map = ffi.new("bl_ev_ping"), ffi.new("bl_ev_bot"), ffi.new("bl_ev_order"), ffi.new("bl_ev_map");
	ac_block, ac_line = ffi.cast("bl_ac_block *", rec_buf + 4), ffi.cast("bl_ac_line *", rec_buf + 4);
	ac_grenade, ac_ping = ffi.cast("bl_ac_grenade *", rec_buf + 4), ffi.cast("bl_ac_ping *", rec_buf + 4);
	ac_u32, rec = ffi.cast("uint32_t *", rec_buf + 4), ffi.cast("bl_record *", rec_buf);
	PSIZE = ffi.sizeof("bl_player");
end

local function push(kind, pid, payload, n, force)
	if (f == nil or not (attached or force)) then return; end
	if (L.bl_push(f.events, kind, pid, payload, n) == 0) then
		stats.ev_dropped = stats.ev_dropped + 1;
	end
end

local function push_text(kind, pid, text, force)
	text = string.sub(text, 1, 1000);
	push(kind, pid, text, #text + 1, force);
end

-- A SETTING, whatever its length. One record carries under 1000 bytes,
-- and a behaviour tree's text is often longer: such a value goes in
-- pieces the engine puts together again -- "+key#<total>=..." first,
-- "+key=..." between, "+key!=..." last -- and takes only when
-- every one came (bot/core/engine.c, SETTINGS). Never cut short: a tree
-- that lost its end would still be a tree, and a wrong one.
local SET_PIECE, SET_MAX = 900, 60000;
local function push_setting(pid, key, value)
	value = tostring(value);
	if (#key + #value + 1 <= 1000) then
		push_text(11, pid, key .. "=" .. value);
		return;
	end
	local at, first = 1, true;
	while (#value - at + 1 > SET_PIECE) do
		push_text(11, pid, "+" .. key .. (first and ("#" .. #value) or "") .. "="
			.. string.sub(value, at, at + SET_PIECE - 1));
		at, first = at + SET_PIECE, false;
	end
	push_text(11, pid, "+" .. key .. "!=" .. string.sub(value, at));
end

local function color_int(c)
	if (c == nil) then return 0; end
	return c.r * 65536 + c.g * 256 + c.b;
end

-- pid of whoever a block call is by: the bot being applied for, else the
-- pid if it is a player, else the server
local function resolve_by(from)
	if (acting ~= nil) then return acting; end
	if (from ~= nil and from >= 0 and from < (MAX_PLAYERS or 32) and from < 255
	    and is_connected(from)) then
		return from;
	end
	return NO_PLAYER;
end

local function sound(pid, x, y, z, kind)
	local s = ev_sound;
	s.pos.x, s.pos.y, s.pos.z, s.kind = x, y, z, kind;
	push(6, pid, s, 16);
end

local function block_event(pos, type, from)
	local by = resolve_by(from);
	local e = ev_block;
	e.x, e.y, e.z, e.action, e.by = pos.x, pos.y, pos.z, type, by;
	e.color = type == 0 and color_int(get_map_block_color(pos)) or 0;
	push(2, by, e, 12);
	if (by ~= NO_PLAYER or type == 3) then
		sound(by, pos.x + 0.5, pos.y + 0.5, pos.z + 0.5,
			type == 0 and 3 or type == 3 and 5 or 2);
	end
end

-- Hooked in `late`, the chain just above the implementation: what reaches
-- here is what the server really did, after every module that swallows or
-- changes it (protections, effects) has had its say.
local rm_called, rm_told = false, false;

function mod.late.block_action_rm(pos, type, from)
	rm_called = true;
	local mask = mod.late.next.block_action_rm(pos, type, from);
	if (f ~= nil and attached and not loading and mask ~= 0) then
		rm_told = true;
		block_event(pos, type, from);
	end
	return mask;
end

function mod.late.block_action(pos, type, from)
	if (f == nil or not attached or loading) then
		return mod.late.next.block_action(pos, type, from);
	end
	rm_called, rm_told = false, false;
	mod.late.next.block_action(pos, type, from);
	if (type == 0) then
		block_event(pos, 0, from);
	elseif (not rm_called) then
		-- C reached its own block_action_rm without passing the chain
		block_event(pos, type, from);
	elseif (type == 3 and not rm_told) then
		-- a blast that took no block still made a noise
		local by = resolve_by(from);
		sound(by, pos.x + 0.5, pos.y + 0.5, pos.z + 0.5, 5);
	end
end

function mod.late.block_line(start, stop, from)
	mod.late.next.block_line(start, stop, from);
	if (f == nil or not attached or loading) then return; end
	local by = resolve_by(from);
	local e = ev_line;
	e.x1, e.y1, e.z1, e.x2, e.y2, e.z2, e.by = start.x, start.y, start.z, stop.x, stop.y, stop.z, by;
	e.color = by ~= NO_PLAYER and color_int(get_block_color(by)) or color_int(get_map_block_color(stop));
	push(3, by, e, 20);
	sound(by, stop.x + 0.5, stop.y + 0.5, stop.z + 0.5, 3);
end

function mod.late.kill(pid, ktype, killer)
	local was = f ~= nil and attached and is_alive(pid);
	mod.late.next.kill(pid, ktype, killer);
	if (was) then
		local e = ev_kill;
		e.killer = (killer ~= nil and killer >= 0 and killer < (MAX_PLAYERS or 32)) and killer or NO_PLAYER;
		e.kind = ktype or 0;
		push(4, pid, e, 4);
	end
	-- a bot of one life leaves; not from inside the kill, whose chain
	-- other scripts are still in
	if (ours[pid] ~= nil and ours[pid].once) then
		leaving[#leaving + 1] = pid;
	end
end

-- Hurt: the damage calls say who and from where; the set_hp inside them
-- is the moment it lands.
local dmg_pid, dmg_by, dmg_pos = nil, NO_PLAYER, nil;

local function hurt(pid, hp)
	if (f == nil or not attached) then return; end
	local old = get_hp(pid);
	if (hp >= old) then return; end
	local e = ev_hurt;
	if (dmg_pid == pid) then
		e.by = dmg_by;
		local src = dmg_pos;
		if (src == nil and dmg_by ~= NO_PLAYER) then src = get_position(dmg_by); end
		if (src == nil) then src = get_position(pid); end
		e.from.x, e.from.y, e.from.z = src.x, src.y, src.z;
	else
		e.by = NO_PLAYER;
		local src = get_position(pid);
		e.from.x, e.from.y, e.from.z = src.x, src.y, src.z;
	end
	e.hp = hp < 0 and 0 or hp > 255 and 255 or hp;
	push(5, pid, e, 16);
end

function mod.late.set_hp(pid, hp)
	hurt(pid, hp);
	mod.late.next.set_hp(pid, hp);
end

function mod.late.set_hp_directional(pid, hp, pos)
	if (dmg_pid ~= pid) then
		dmg_pid, dmg_by, dmg_pos = pid, NO_PLAYER, pos;
		hurt(pid, hp);
		dmg_pid = nil;
	else
		dmg_pos = pos;
		hurt(pid, hp);
	end
	mod.late.next.set_hp_directional(pid, hp, pos);
end

local function damaged(pid, by, pos, fn, ...)
	local op, ob, ox = dmg_pid, dmg_by, dmg_pos;
	dmg_pid = pid;
	dmg_by = (by ~= nil and by >= 0 and by < (MAX_PLAYERS or 32)) and by or NO_PLAYER;
	dmg_pos = pos;
	fn(...);
	dmg_pid, dmg_by, dmg_pos = op, ob, ox;
end

function mod.late.damage_player(pid, hp, type, damager)
	damaged(pid, damager, nil, mod.late.next.damage_player, pid, hp, type, damager);
end

function mod.late.damage_player_directional(pid, hp, pos, type, damager)
	damaged(pid, damager, pos, mod.late.next.damage_player_directional, pid, hp, pos, type, damager);
end

local function grenade_event(pid, pos, vel, fuse)
	if (ours[pid] ~= nil and grenades[pid] > 0) then grenades[pid] = grenades[pid] - 1; end
	if (f == nil or not attached) then return; end
	local e = ev_grenade;
	e.pos.x, e.pos.y, e.pos.z = pos.x, pos.y, pos.z;
	e.vel.x, e.vel.y, e.vel.z = vel.x, vel.y, vel.z;
	e.fuse = fuse;
	push(7, pid, e, 28);
end

function mod.after.on_grenade(pid, pos, vel, fuse)
	grenade_event(pid, pos, vel, fuse);
end

function mod.after.spawn_grenade(pid, team, pos, vel, fuse)
	grenade_event(pid, pos, vel, fuse);
end

local function ping_event(pid, pos, reason)
	local e = ev_ping;
	e.pos.x, e.pos.y, e.pos.z = pos.x, pos.y, pos.z;
	ffi.fill(e.reason, 64, 0);
	ffi.copy(e.reason, string.sub(tostring(reason or ""), 1, 63));
	push(8, pid, e, 76);
end

local function on_shot(pid, gun)
	if (f == nil or not attached) then return; end
	local p = get_position(pid);
	sound(pid, p.x, p.y, p.z, 1);
end

-- WHAT A BOT HOLDS, and what each item is for (lib_inventory, when it is
-- there). The engine knows no item by name: it is told each bot's count
-- of each kind ("item.<kind>=<n>", "inf" for unlimited), and each kind's
-- own fragment of behaviour tree ("item.<kind>.tree=<text>", written by
-- whoever defined the item) with how long to keep aiming after using it
-- ("item.<kind>.guide=<secs>"). Sent as settings, so an engine that
-- attaches late is told them all again.
local function item_count(pid, key, n)
	if (ours[pid] ~= nil) then
		botlink_set("item." .. key, n == math.huge and "inf" or tostring(n or 0), pid);
	end
end

local function item_kind(key, def)
	local bot = def and def.bot;
	botlink_set("item." .. key .. ".tree", bot and tostring(bot.tree or "") or "");
	botlink_set("item." .. key .. ".guide", bot and tostring(tonumber(bot.guide) or 0) or "0");
end

-- WHO SEES IN THE DARK. Night vision is a player effect a bot may hold
-- (a reward, a gamemode's gift); at night it decides what the bot can
-- see at all, so the engine is told: "night_vision=1|0" for each bot,
-- when it changes. Looked at once a second: a grant ends by its own
-- clock, with nothing to hook.
local nv_told = {};
local function sync_night_vision()
	local fx = PlayerEffect ~= nil and PlayerEffect.get("nightvision") or nil;
	for pid in pairs(ours) do
		local has = (fx ~= nil and fx:has(pid)) and "1" or "0";
		if (nv_told[pid] ~= has) then
			nv_told[pid] = has;
			botlink_set("night_vision", has, pid);
		end
	end
end

-- listeners are re-registered if their library was reloaded under us
local shot_with, ping_with, inv_with = nil, nil, nil;
local function hook_listeners()
	if (inventory_listen ~= nil and inv_with ~= inventory_listen) then
		inventory_listen("botlink", {count = item_count, kind = item_kind});
		inv_with = inventory_listen;
		-- what was defined, and held, before this was listening
		for key, def in pairs(inventory_kinds()) do
			item_kind(key, def);
			for pid in pairs(ours) do
				item_count(pid, key, inventory_count(pid, key));
			end
		end
	end
	if (shot_listen ~= nil and shot_with ~= shot_listen) then
		shot_listen("botlink", on_shot);
		shot_with = shot_listen;
	end
	if (teamplay_listen_ping ~= nil and ping_with ~= teamplay_listen_ping) then
		teamplay_listen_ping("botlink", function(pid, pos, reason)
			if (f ~= nil and attached) then ping_event(pid, pos, reason); end
		end);
		ping_with = teamplay_listen_ping;
	end
end

--========================== MAP, BOTS, SETTINGS =====================--

local map_warned = false;
local announce; -- below

local function send_map()
	if (f == nil or loading or dump_vxl == nil) then return; end
	map_file_n = map_file_n + 1;
	local path = string.format("%sbotlink-map-%d.vxl", botlink_map_dir, map_file_n);
	local fh = io.open(path .. ".new", "wb");
	if (fh == nil) then
		if (not map_warned) then
			map_warned = true;
			warn("cannot write the map to %s: the engine will have none", botlink_map_dir);
		end
		return;
	end
	for dat in dump_vxl() do fh:write(dat); end
	fh:close();
	os.rename(path .. ".new", path);
	if (map_file_n > 2) then
		os.remove(string.format("%sbotlink-map-%d.vxl", botlink_map_dir, map_file_n - 2));
	end
	local e = ev_map;
	e.map_seq = map_seq;
	ffi.fill(e.path, 256, 0);
	ffi.copy(e.path, string.sub(path, 1, 255));
	push(1, NO_PLAYER, e, 260);
end

function mod.after.prepare_map_load()
	loading = true;
end

-- WHAT THIS MAP'S WATER DOES. On some maps wading costs health every
-- second (the map's own `water_damage`, applied by water_damage.lua);
-- on most it costs nothing. A bot should not have to drown to find out:
-- the engine is told with each map, as settings -- "water=lethal|safe",
-- which its route planner obeys, and "water.damage=<health a second>".
local function tell_water()
	local meta = get_map_meta ~= nil and get_map_meta() or nil;
	local dmg = meta ~= nil and tonumber(meta.water_damage) or 0;
	if (dmg == nil or dmg < 0) then dmg = 0; end
	botlink_set("water", dmg > 0 and "lethal" or "safe");
	botlink_set("water.damage", tostring(dmg));
end

function mod.after.finish_map_load()
	loading = false;
	map_seq = map_seq + 1;
	tell_water();
	-- the bots stay; a bot's body is a new one after the map (spawn)
	if (f ~= nil and attached) then
		send_map();
		for pid in pairs(ours) do announce(pid); end
	end
end

announce = function(pid)
	local o = ours[pid];
	if (o == nil) then return; end
	local e = ev_bot;
	e.level, e.gun, e.seed = o.level, o.gun, o.seed;
	push(9, pid, e, 8);
end

local function send_settings()
	for k, v in pairs(settings) do
		push_setting(NO_PLAYER, k, v);
	end
	for pid, t in pairs(psettings) do
		for k, v in pairs(t) do
			push_setting(pid, k, v);
		end
	end
end

local function push_order(pid, o)
	local e = ev_order;
	e.pos.x, e.pos.y, e.pos.z = o.x, o.y, o.z;
	e.order, e.target, e.secs = o.order, o.target, o.secs;
	push(12, pid, e, 20);
end

-- An engine arrived (or came back): it knows nothing, so say it all.
local function resync()
	stats.attaches = stats.attaches + 1;
	send_map();
	for pid in pairs(ours) do announce(pid); end
	send_settings();
	for pid, o in pairs(orders) do push_order(pid, o); end
	-- whatever it left behind in the actions is for a mind that is gone
	local n = 0;
	while (n < 100000 and L.bl_pop(f.actions, rec_buf) ~= 0) do n = n + 1; end
end

local ORDERS = {none = 0, ["goto"] = 1, hunt = 2, follow = 3, hold = 4};

function botlink_add(opts)
	if (not open_file()) then return nil; end
	opts = opts or {};
	if (opts.team ~= 1 and opts.team ~= 2) then
		error("botlink_add: team must be 1 or 2", 2);
	end
	local seed = opts.seed or math.random(1, 2147483646);
	local level = math.max(1, math.min(10, math.floor(opts.level or 5)));
	local gun = opts.gun or math.random(0, 2);
	local at = opts.at;
	local name = opts.name or string.format("Bot%d", seed % 1000);
	local pid = bot_create{
		team = opts.team,
		name = name,
		gun = gun, tool = "gun",
		spawn_at = type(at) == "function" and at
			or type(at) == "table" and function() return at; end or nil,
		data = {botlink = true},
	};
	if (pid == nil) then return nil; end
	ours[pid] = {level = level, gun = gun, seed = seed, team = opts.team, once = opts.once == true};
	blocks[pid], grenades[pid] = 50, 3;
	announce(pid);
	-- its name, for a person watching it think (the engine does nothing else with it)
	botlink_set("name", (string.gsub(string.sub(tostring(name), 1, 30), "[%c=]", " ")), pid);
	if (opts.tree ~= nil) then
		botlink_set("tree", opts.tree, pid);
	end
	return pid;
end

function botlink_remove(pid)
	local o = ours[pid];
	if (o == nil) then return; end
	ours[pid] = nil;
	psettings[pid], orders[pid], lastori[pid], nv_told[pid] = nil, nil, nil, nil;
	push(10, pid, nil, 0, true);
	if (bot_destroy ~= nil) then bot_destroy(pid); end
end

function botlink_set(key, value, pid)
	if (#tostring(key) > 60 or #tostring(value) > SET_MAX) then
		-- said, and nothing kept or sent: the old value stands
		log("botlink_set: %s is too long a %s (%d bytes; the most is %d): ignored",
			string.sub(tostring(key), 1, 60), #tostring(key) > 60 and "name" or "value",
			#tostring(value), SET_MAX);
		return false;
	end
	if (pid == nil) then
		settings[key] = value;
	else
		psettings[pid] = psettings[pid] or {};
		psettings[pid][key] = value;
	end
	if (f ~= nil) then
		push_setting(pid or NO_PLAYER, key, value);
	end
	return true;
end

-- A TREE FROM AN ADMINISTRATION TOOL (lsdctl bots apply, and whatever
-- editor comes to stand on it): for some bots or for the world, live.
-- The tool has compiled the text already (bttree --check) and says here
-- only which file of the debug directory holds it -- never a path: the
-- name is checked, and the directory is this module's own setting. The
-- console that reaches this is the admin's: applying a tree is an admin
-- action, and a tree, though not code, decides what commands a bot runs
-- (`do use <item>`).
local function tree_pids(pids)
	local list = {};
	for _, pid in ipairs(pids or {}) do
		if (ours[pid] == nil) then return nil, "no engine bot has the id " .. tostring(pid); end
		list[#list + 1] = pid;
	end
	return list;
end

function botlink_tree_apply(tree, pids)
	local text = tree;
	if (type(tree) == "table") then
		local name = tostring(tree.file or "");
		if (not string.match(name, "^[%w_%-]+%.bt$")) then
			return nil, "not a file name";
		end
		local fh = io.open(botlink_map_dir .. "botdebug/" .. name, "rb");
		if (fh == nil) then return nil, "no such file"; end
		text = fh:read(60001);
		fh:close();
		if (text == nil or #text == 0 or #text > 60000) then return nil, "empty, or too long"; end
	elseif (type(tree) ~= "string" or not string.match(tree, "^[%w_%-%.]+$")) then
		return nil, "not a tree's name";
	end
	if (pids == nil) then
		botlink_set("tree", text);
		local n = 0;
		for _ in pairs(ours) do n = n + 1; end
		return n;
	end
	local list, why = tree_pids(pids);
	if (list == nil) then return nil, why; end
	for _, pid in ipairs(list) do botlink_set("tree", text, pid); end
	return #list;
end

function botlink_tree_revert(pids)
	if (pids == nil) then
		local own = rawget(_G, "engine_bots_tree");
		botlink_set("tree", (own ~= nil and tostring(own) ~= "") and tostring(own) or tostring(gamemode or "default"));
		local n = 0;
		for _ in pairs(ours) do n = n + 1; end
		return n;
	end
	local list, why = tree_pids(pids);
	if (list == nil) then return nil, why; end
	for _, pid in ipairs(list) do botlink_set("tree", "", pid); end
	return #list;
end

-- A WORD FROM A BOT'S TREE: `do tell <name> [words...]` in a tree calls
-- the function given here for that name, with the bot and the words
-- (strings, three at most). What the function does is the script's: this
-- is how a tree does something the engine has no word for -- ring a
-- bell, open a door, score a point. One handler a name (the last given);
-- one that raises is logged and dropped. A tell nobody listens for is
-- counted (botlink_stats().tells_unheard) and is not an error.
function botlink_on(name, fn)
	if (type(name) ~= "string" or type(fn) ~= "function") then
		error("botlink_on(name, function(pid, words) ... end)", 2);
	end
	tell_handlers[name] = fn;
end

function botlink_off(name)
	tell_handlers[name] = nil;
end

function botlink_order(pid, t)
	if (ours[pid] == nil) then return; end
	local o = type(t.order) == "number" and t.order or ORDERS[string.lower(tostring(t.order or "none"))] or 0;
	local p = t.pos or {x = 0, y = 0, z = 0};
	local rec = {order = o, target = t.target or NO_PLAYER, secs = t.secs or 0, x = p.x, y = p.y, z = p.z};
	orders[pid] = rec;
	if (f ~= nil) then push_order(pid, rec); end
end

function botlink_alive()
	return f ~= nil and attached;
end

function botlink_stats()
	local t = {};
	for k, v in pairs(stats) do t[k] = v; end
	t.attached, t.inert = attached, inert_why;
	return t;
end

function mod.after.on_disconnect(pid)
	if (ours[pid] ~= nil) then
		ours[pid] = nil;
		psettings[pid], orders[pid], lastori[pid] = nil, nil, nil;
		push(10, pid, nil, 0, true);
	end
	firing[pid], scoped[pid] = nil, nil;
end

local function reset_body(pid)
	life[pid] = (life[pid] + 1) % 4294967296;
	blocks[pid], grenades[pid] = 50, 3;
	if (ours[pid] ~= nil) then
		firing[pid], scoped[pid] = nil, nil;
		next_block[pid] = 0;
		if (bot_get ~= nil and bot_get(pid) ~= nil) then bot_stop(pid); end
	end
end

function mod.after.spawn_player(pid)
	reset_body(pid);
end

function mod.after.restock(pid)
	blocks[pid], grenades[pid] = 50, 3;
end

--============================== THE WORLD ===========================--

local MAGS = {[0] = 10, [1] = 30, [2] = 6};

local function fill_player(pid, p)
	present[pid] = true;
	local isbot = ours[pid] ~= nil;
	local flags = isbot and 1 or 0;

	if (not is_alive(pid)) then
		p.state = is_joined(pid) and 2 or 1;
		local t = get_team(pid);
		p.team = (t == 1 or t == 2) and t or 0;
		p.flags, p.keys, p.hp, p.life = flags, 0, 0, life[pid];
		return;
	end

	p.state = 3;
	local t = get_team(pid);
	p.team = (t == 1 or t == 2) and t or 0;
	p.tool, p.gun = get_tool(pid), get_gun(pid);
	local hp = get_hp(pid);
	p.hp = hp < 0 and 0 or hp > 255 and 255 or hp;
	p.mag, p.reserve = get_mag_ammo(pid), get_reserve_ammo(pid);
	p.blocks, p.grenades = blocks[pid], grenades[pid];

	local keys = get_inputs(pid);
	p.keys = band(keys, 255);
	if (band(keys, 32) ~= 0) then flags = flags + 2; end
	if (band(keys, 128) ~= 0) then flags = flags + 4; end
	if (is_airborne(pid)) then flags = flags + 8; end
	if (is_wading(pid)) then flags = flags + 16; end
	if (flashlight_get ~= nil and flashlight_get(pid)) then flags = flags + 32; end
	local m = get_mouse_inputs(pid);
	if (isbot) then
		if (firing[pid]) then flags = flags + 64; end
		if (band(m, 2) ~= 0) then flags = flags + 128; end
	else
		if (band(m, 1) ~= 0) then flags = flags + 64; end
		if (band(m, 2) ~= 0) then flags = flags + 128; end
	end
	p.flags, p.life = flags, life[pid];

	local v = get_position(pid);
	p.pos.x, p.pos.y, p.pos.z = v.x, v.y, v.z;
	v = get_orientation(pid);
	p.ori.x, p.ori.y, p.ori.z = v.x, v.y, v.z;
	v = get_velocity(pid);
	p.vel.x, p.vel.y, p.vel.z = v.x, v.y, v.z;
end

local function fill_object(o, v)
	if (type(v) == "table") then
		o.pos.x, o.pos.y, o.pos.z, o.holder, o.present = v.x, v.y, v.z, NO_PLAYER, 1;
	elseif (type(v) == "number" and v >= 0 and v < nslots) then
		local pp = players[v].pos;
		o.pos.x, o.pos.y, o.pos.z, o.holder, o.present = pp.x, pp.y, pp.z, v, 1;
	else
		o.present, o.holder = 0, NO_PLAYER;
	end
end

local function write_body()
	wcount = wcount + 1;
	w.tick, w.time, w.map_seq = tick_n, get_time(), map_seq;
	w.night = (daytime_is_night ~= nil and daytime_is_night()) and 1 or 0;
	w.score[0], w.score[1] = get_team_score(1), get_team_score(2);
	w.max_score = get_max_score();

	for pid in piditer(PID_BROADCAST) do
		if (pid < nslots) then
			fill_player(pid, players[pid]);
			seen[pid] = wcount;
		end
	end
	for pid = 0, nslots - 1 do
		if (seen[pid] ~= wcount and present[pid]) then
			ffi.fill(players[pid], PSIZE, 0);
			present[pid] = nil;
		end
	end

	local il, tl = get_intelloc(), get_tentloc();
	for t = 1, 2 do
		fill_object(w.intel[t - 1], il[t]);
		fill_object(w.tent[t - 1], tl[t]);
	end
end

local next_world = 0;

local function write_world(force)
	local now = get_time();
	if (not force and now + 1e-4 < next_world) then return; end
	local hz = math.max(1, math.min(60, botlink_world_hz));
	next_world = next_world + 1 / hz;
	if (next_world < now) then next_world = now + 1 / hz; end
	L.bl_world_begin(f);
	local ok, err = pcall(write_body);
	L.bl_world_end(f);
	if (not ok) then
		stats.errors = stats.errors + 1;
		if (stats.errors <= 3) then warn("writing the world failed: %s", tostring(err)); end
	end
end

--============================== INTENTS =============================--

local scratch = {x = 0, y = 0, z = 0};

local function set_mouse2(pid, on)
	if (scoped[pid] == on) then return; end
	scoped[pid] = on;
	on_mouse_input(pid, on and 2 or 0);
end

local function trigger(pid)
	local tool = get_tool(pid);
	if (tool == 2) then
		if (get_reload_time(pid) ~= 0) then return; end
		local mag = get_mag_ammo(pid);
		if (mag <= 0) then return; end
		if (bot_shoot(pid) ~= false) then
			set_ammo(pid, mag - 1, get_reserve_ammo(pid));
			local p = get_position(pid);
			sound(pid, p.x, p.y, p.z, 1);
		end
	elseif (tool == 0) then
		local r = bot_melee(pid);
		if (r == false) then
			-- nothing to hit: dig what the swing meets
			local a, o = get_position(pid), get_orientation(pid);
			local hit = raycast(a, {x = a.x + o.x * 3.5, y = a.y + o.y * 3.5, z = a.z + o.z * 3.5}, true);
			if (hit ~= nil) then
				acting = pid;
				if (bot_dig_block(hit.x, hit.y, hit.z, pid)) then
					bdestroy_finish();
					blocks[pid] = math.min(50, blocks[pid] + 1);
				end
				acting = nil;
			end
		end
	end
end

local function apply_intent(pid)
	local it = intents[pid];
	if (band(it.flags, 1) == 0 or it.life ~= life[pid]) then return; end

	bot_keys(pid, it.keys);

	local o = it.ori;
	local ox, oy, oz = o.x, o.y, o.z;
	local len2 = ox * ox + oy * oy + oz * oz;
	if (len2 > 0.25 and len2 < 4) then
		local l = lastori[pid];
		if (l == nil) then
			l = {0, 0, 0};
			lastori[pid] = l;
		end
		if (l[1] ~= ox or l[2] ~= oy or l[3] ~= oz) then
			l[1], l[2], l[3] = ox, oy, oz;
			scratch.x, scratch.y, scratch.z = ox, oy, oz;
			bot_look_toward(pid, scratch);
		end
	end

	local tool = it.tool;
	if (tool <= 3 and tool ~= get_tool(pid)) then
		bot_set_tool(pid, tool);
	end

	if (flashlight_set ~= nil) then
		local want = band(it.flags, 2) ~= 0;
		if (flashlight_get(pid) ~= want) then flashlight_set(pid, want); end
	end

	if (band(it.flags, 4) ~= 0 and get_tool(pid) == 2 and get_reload_time(pid) == 0
	    and get_reserve_ammo(pid) > 0 and get_mag_ammo(pid) < (MAGS[get_gun(pid)] or 10)) then
		on_reload(pid);
	end

	set_mouse2(pid, band(it.mouse, 2) ~= 0);
	local fire = band(it.mouse, 1) ~= 0;
	firing[pid] = fire or nil;
	if (fire) then trigger(pid); end
end

local function freeze_bots()
	for pid in pairs(ours) do
		if (bot_get(pid) ~= nil) then
			bot_stop(pid);
			firing[pid] = nil;
			if (scoped[pid]) then set_mouse2(pid, false); end
		end
	end
end

--============================== ACTIONS =============================--

local posbuf = {x = 0, y = 0, z = 0};
local posbuf2 = {x = 0, y = 0, z = 0};

local function in_map(x, y, z)
	return x >= 0 and x < 512 and y >= 0 and y < 512 and z >= 0 and z < 62;
end

local function neighbours(x, y, z)
	return bot_solid(x - 1, y, z) or bot_solid(x + 1, y, z) or bot_solid(x, y - 1, z)
		or bot_solid(x, y + 1, z) or bot_solid(x, y, z - 1) or bot_solid(x, y, z + 1);
end

local function within_reach(pid, x, y, z)
	local p = get_position(pid);
	local dx, dy, dz = p.x - (x + 0.5), p.y - (y + 0.5), p.z - (z + 0.5);
	return dx * dx + dy * dy + dz * dz <= botlink_reach * botlink_reach;
end

-- WHAT A PLAYER COULD DO FROM THERE. LSd checks a client's block action
-- for little more than "in the map, solid or not, a neighbour, blocks
-- left" (funcs_packetrecv.c): no reach, no line of sight -- a client can
-- only point at what it sees, and that is the whole of the rule. A bot
-- has no client, so the rule is made here: a block goes in the air cell
-- in front of a FACE of a solid voxel that faces the bot's eye, with a
-- clear line from the eye to that face's middle (the cell it goes in
-- excepted, air anyway); a dig takes a voxel one of whose faces is open
-- to the air, faces the eye and is in its clear sight. So no block hung
-- under the floor the bot stands on: nobody can aim at that.
local FACES = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};

-- the eye to (px, py, pz) through air; the cell (sx, sy, sz) is not looked at
local function clear_line(e, px, py, pz, sx, sy, sz)
	local dx, dy, dz = px - e.x, py - e.y, pz - e.z;
	local len = math.sqrt(dx * dx + dy * dy + dz * dz);
	local n = math.max(1, math.ceil(len / 0.1));
	for i = 0, n - 1 do
		local t = i / n;
		local cx, cy, cz = math.floor(e.x + dx * t), math.floor(e.y + dy * t), math.floor(e.z + dz * t);
		if (not (cx == sx and cy == sy and cz == sz) and bot_solid(cx, cy, cz)) then return false; end
	end
	return true;
end

-- a face of a solid neighbour of the air cell (x, y, z) that faces the
-- eye and that the eye sees: a build there is a player's
local function sees_build(e, x, y, z)
	for _, d in ipairs(FACES) do
		if (bot_solid(x + d[1], y + d[2], z + d[3])) then
			local px, py, pz = x + 0.5 + 0.5 * d[1], y + 0.5 + 0.5 * d[2], z + 0.5 + 0.5 * d[3];
			-- the eye on the cell's side of the face
			if ((e.x - px) * -d[1] + (e.y - py) * -d[2] + (e.z - pz) * -d[3] > 0
			    and clear_line(e, px, py, pz, x, y, z)) then
				return true;
			end
		end
	end
	return false;
end

-- a face of the solid voxel (x, y, z) open to the air, facing the eye, seen
local function sees_dig(e, x, y, z)
	for _, d in ipairs(FACES) do
		if (not bot_solid(x + d[1], y + d[2], z + d[3])) then
			local px, py, pz = x + 0.5 + 0.5 * d[1], y + 0.5 + 0.5 * d[2], z + 0.5 + 0.5 * d[3];
			if ((e.x - px) * d[1] + (e.y - py) * d[2] + (e.z - pz) * d[3] > 0
			    and clear_line(e, px, py, pz, x, y, z)) then
				return true;
			end
		end
	end
	return false;
end

local function do_block(pid)
	local x, y, z, act = ac_block.x, ac_block.y, ac_block.z, ac_block.action;
	if (not in_map(x, y, z) or act > 2) then return false; end
	local now = get_time();
	if (now < next_block[pid]) then return false; end
	if (not within_reach(pid, x, y, z)) then return false; end
	local tool = get_tool(pid);
	posbuf.x, posbuf.y, posbuf.z = x, y, z;

	if (act == 0) then
		if (tool ~= 1 or blocks[pid] <= 0 or bot_solid(x, y, z) or not neighbours(x, y, z)
		    or not sees_build(get_position(pid), x, y, z)) then return false; end
		next_block[pid] = now + botlink_build_secs;
		blocks[pid] = blocks[pid] - 1;
		on_block_action(pid, posbuf, 0);
		return true;
	end

	if (tool ~= 0 or not bot_solid(x, y, z) or not sees_dig(get_position(pid), x, y, z)) then return false; end
	-- told no before the swing, not after: the filter would refuse it
	-- silently, and the engine would count a dig that never was
	if (may_edit_block ~= nil and not may_edit_block(pid, posbuf, 1)) then return false; end
	next_block[pid] = now + (act == 1 and botlink_dig_secs or botlink_dig3_secs);
	if (act == 1) then blocks[pid] = math.min(50, blocks[pid] + 1); end
	on_block_action(pid, posbuf, act);
	return true;
end

local function do_line(pid)
	local x1, y1, z1, x2, y2, z2 = ac_line.x1, ac_line.y1, ac_line.z1, ac_line.x2, ac_line.y2, ac_line.z2;
	if (not in_map(x1, y1, z1) or not in_map(x2, y2, z2)) then return false; end
	local now = get_time();
	if (now < next_block[pid] or get_tool(pid) ~= 1) then return false; end
	local n = 1 + math.abs(x2 - x1) + math.abs(y2 - y1) + math.abs(z2 - z1);
	if (n > blocks[pid] or not within_reach(pid, x1, y1, z1)) then return false; end
	if (not neighbours(x1, y1, z1) or bot_solid(x2, y2, z2) or not neighbours(x2, y2, z2)) then return false; end
	-- the line's start is a placement a player could make (where the drag
	-- begins); the rest is the line tool's
	if (not sees_build(get_position(pid), x1, y1, z1)) then return false; end
	next_block[pid] = now + botlink_line_secs;
	blocks[pid] = blocks[pid] - n;
	posbuf.x, posbuf.y, posbuf.z = x1, y1, z1;
	posbuf2.x, posbuf2.y, posbuf2.z = x2, y2, z2;
	on_block_line(pid, posbuf, posbuf2);
	return true;
end

local function finite3(x, y, z)
	return x == x and y == y and z == z and math.abs(x) < 1e9 and math.abs(y) < 1e9 and math.abs(z) < 1e9;
end

local function do_grenade(pid)
	local vx, vy, vz, fuse = ac_grenade.vel.x, ac_grenade.vel.y, ac_grenade.vel.z, ac_grenade.fuse;
	if (grenades[pid] <= 0 or not finite3(vx, vy, vz) or not (fuse >= 0 and fuse <= 3)) then return false; end
	local len = math.sqrt(vx * vx + vy * vy + vz * vz);
	if (len < 1e-6) then return false; end
	on_orientation(pid, {x = vx / len, y = vy / len, z = vz / len});
	on_grenade(pid, get_position(pid), {x = vx, y = vy, z = vz}, fuse);
	return true;
end

local function payload_text(n)
	local len = n - 4;
	if (len <= 0) then return ""; end
	local s = ffi.string(rec_buf + 4, len);
	return (string.match(s, "^[^%z]*"));
end

-- the ping labels of the running gamemode, as lib_callouts reads them
local function label_for(text)
	local function load(name)
		local ok, s = pcall(require, "callouts." .. name);
		return ok and type(s) == "table" and s or nil;
	end
	local name = tostring(gamemode or "");
	local set = string.match(name, "^[%w_]+$") and name ~= "default" and load(name) or nil;
	local list = set and set.pings or (load("default") or {}).pings or {};
	local low = string.lower(text);
	for _, p in ipairs(list) do
		if (p.label ~= nil and p.label.en ~= nil
		    and (string.lower(p.label.en) == low or p.key == low)) then
			return p.label;
		end
	end
	return text;
end

local function do_ping(pid)
	if (teamplay_ping == nil) then return false; end
	local x, y, z = ac_ping.pos.x, ac_ping.pos.y, ac_ping.pos.z;
	if (not finite3(x, y, z) or x < 0 or x > 512 or y < 0 or y > 512 or z < 0 or z > 64) then return false; end
	local now = get_time();
	if (now - ping_at[pid] < (teamplay_ping_interval or 1)) then return false; end
	ping_at[pid] = now;

	local text = ffi.string(ac_ping.reason);
	local pos = {x = x, y = y, z = z};
	local reason = label_for(text);
	if (teamplay_relay_pings ~= false) then
		for i in (people_in or piditer)(PID_BROADCAST_TEAM(get_team(pid))) do
			if (ours[i] == nil) then
				teamplay_ping(i, pos, {from = pid, reason = reason});
			end
		end
	end
	if (attached) then ping_event(pid, pos, text); end
	return true;
end

local function drain_actions()
	local n = 0;
	local max = botlink_actions_per_tick;
	while (n < max) do
		local size = L.bl_pop(f.actions, rec_buf);
		if (size == 0) then break; end
		n = n + 1;
		stats.actions = stats.actions + 1;
		local kind, pid = rec.type, rec.pid;

		local ok_pid = ours[pid] ~= nil and is_alive(pid);
		if (not ok_pid) then
			stats.ac_dropped = stats.ac_dropped + 1;
		else
			acting = pid;
			local ok, res = pcall(function()
				if (kind == 1) then return do_block(pid);
				elseif (kind == 2) then return do_line(pid);
				elseif (kind == 3) then return do_grenade(pid);
				elseif (kind == 4) then
					local text = payload_text(size);
					if (handle_command ~= nil) then handle_command(pid, text, true); end
					return true;
				elseif (kind == 5) then
					local c = ac_u32[0];
					bot_set_block_color(pid, {r = band(bit.rshift(c, 16), 255),
						g = band(bit.rshift(c, 8), 255), b = band(c, 255)});
					return true;
				elseif (kind == 6) then
					log("botlink: #%d: %s", pid, payload_text(size));
					return true;
				elseif (kind == 7) then return do_ping(pid);
				elseif (kind == 8) then
					-- a word from the bot's tree (`do tell <name> ...`): for
					-- whoever listens for that name; nobody is not an error
					local words = {};
					for w in string.gmatch(payload_text(size), "%S+") do words[#words + 1] = w; end
					local name = table.remove(words, 1);
					local h = name ~= nil and tell_handlers[name] or nil;
					stats.tells = stats.tells + 1;
					if (h == nil) then
						stats.tells_unheard = stats.tells_unheard + 1;
						return true;
					end
					local good, why = pcall(h, pid, words);
					if (not good) then
						-- one that raises is said once and let go, as a listener of the inventory is
						tell_handlers[name] = nil;
						warn("the handler of tell %s failed and is dropped: %s", tostring(name), tostring(why));
					end
					return true;
				end
				return false;
			end);
			acting = nil;
			if (not ok) then
				stats.errors = stats.errors + 1;
				if (stats.errors <= 5) then warn("action %d from #%d failed: %s", kind, pid, tostring(res)); end
			elseif (not res) then
				stats.ac_refused = stats.ac_refused + 1;
			end
		end
	end
end

--============================== THE TICK ============================--

function mod.before.tick()
	if (f == nil) then return; end
	if (#leaving > 0) then
		local gone = leaving;
		leaving = {};
		for _, pid in ipairs(gone) do
			if (ours[pid] ~= nil and ours[pid].once) then botlink_remove(pid); end
		end
	end
	tick_n = tick_n + 1;
	local now = get_time();
	if (L.bl_alive(f.header.engine_beat, beat_last) == 1) then last_move = now; end
	local was = attached;
	attached = (now - last_move) < botlink_stale;
	-- AN ENGINE IS NEW when it comes after a silence, or when another
	-- process took the file without one (the container starts botd again
	-- at once, within botlink_stale): either way it knows nothing
	local engine = f.header.engine_pid;
	local other = attached and was and engine ~= engine_seen;
	if (attached) then engine_seen = engine; end

	if (attached and (not was or other)) then
		frozen = false;
		hook_listeners();
		resync();
		write_world(true);
	elseif (not attached and not frozen) then
		frozen = true;
		freeze_bots();
	end
	if (not attached) then return; end

	for pid in pairs(ours) do
		if (is_alive(pid)) then apply_intent(pid); end
	end
	drain_actions();
end

function mod.after.tick()
	if (f == nil) then return; end
	L.bl_beat_server(f);
	if (attached) then
		write_world(false);
		if (tick_n % 60 == 0) then
			hook_listeners();
			sync_night_vision();
		end
	end
end

--============================= LIFECYCLE ============================--

function mod.on_load()
	local why = load_link();
	if (why ~= nil) then
		inert_why = why;
		warn("inert, the server runs without bots: %s", why);
		return;
	end
	-- the tree the bots run is named after the gamemode; the engine falls
	-- back to its default tree for a mode it has none for. A gamemode that
	-- brings its own says so itself: botlink_set("tree", <name or text>).
	if (settings.tree == nil and gamemode ~= nil) then
		botlink_set("tree", tostring(gamemode));
	end
	hook_listeners();
end

-- Also what the server's shutdown runs (core.lua's on_shutdown unloads
-- every module, last loaded first, so lib_bot is still there to take the
-- slots down).
function mod.on_unload()
	local pids = {};
	for pid in pairs(ours) do pids[#pids + 1] = pid; end
	for _, pid in ipairs(pids) do botlink_remove(pid); end

	if (shot_unlisten ~= nil) then shot_unlisten("botlink"); end
	if (inventory_unlisten ~= nil) then inventory_unlisten("botlink"); end
	if (teamplay_unlisten_ping ~= nil) then teamplay_unlisten_ping("botlink"); end

	if (f ~= nil) then
		L.bl_shutdown(f);
		L.bl_close(f);
		f = nil;
	end
	attached = false;
	for _, name in ipairs({"botlink_add", "botlink_remove", "botlink_set", "botlink_order",
	                       "botlink_alive", "botlink_stats"}) do
		_G[name] = nil;
	end
end

return mod;
