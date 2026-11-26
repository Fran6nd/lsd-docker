-- bot_sends_test.lua -- nothing is ever sent to a bot, nor once for each
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/bot_sends_test.lua            (from the repository root)
--   luajit tests/bot_sends_test.lua --table    also prints the audit table
--
-- One simulated minute of a game, 100 bots and one person, under the
-- core's own hook chain (lsd/scripts/core.lua: register(), the five
-- chains, mod.next) with the real lib_bot and the scripts that a stub of
-- the C core can carry: upstream's command_ups, command_ignore,
-- command_secspec and purgatory (as the image runs them: the override if
-- catalog/overrides has one), lib_l10n, lib_message_types, lib_teamplay,
-- lib_callouts, lib_pie_menu, lib_silent_player, lib_player_limit, motd.
-- The stub core makes its sends the way funcs_send.c and main.c do, down
-- to the loops that walk every slot of a group and the sends of an event
-- to the player it is about (a spawn's restock, the HP of a hit), as
-- patches/lsd 0002 has them: the loops walk the slots with a peer, and a
-- send the core makes to one slot with none ends in C; its send_packet is
-- the end of the chain.
--
-- What it asserts, by script and by packet:
--   * no send was made at a bot (a pid), by a script or the core, and
--     lib_bot's guard fired 0 times: bot_guard_drops()
--   * no packet reached the end of the chain addressed to a bot
--   * the person was sent every spawn (a group's send_spawn_player goes
--     to the core whole)
--   * (informational, --table) which loops walked the bots of a group, and
--     the core's sends to a bot that ended in C
local WANT_TABLE = (arg ~= nil and arg[1] == "--table");
local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what) else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end
local function eq(got, want, what)
	check(got == want, what, string.format("got %s, want %s", tostring(got), tostring(want)));
end

bit = require("bit");
MAX_PLAYERS = 255;
local SET = 0x20000000;
PID_BROADCAST = SET;
function PID_BROADCAST_EXCEPT(p) return 2 * SET + p; end
function PID_BROADCAST_TEAM(t) return 3 * SET + t - 1; end   -- as lua.c: get_team says 1 and 2, the set holds 0 and 1
function PID_BROADCAST_EXCEPT_TEAM_AND_PLAYER(t, p) return 4 * SET + p * 256 + t - 1; end
function PID_BROADCAST_EXCEPT_TEAM(t) return 4 * SET + 255 * 256 + t - 1; end
SPECTATOR = 255;

local BOTS_N, TICKS = 100, 3600;       -- one minute at 60 a second
local NOW = 0;
function get_time() return NOW; end
function get_team_color() return {r = 0, g = 0, b = 0}; end
local LOGS = {};

--================================ the stub core ===============================--
local CONNECTED, JOINED, ALIVE, TEAM, NAME, QUIRK, HP = {}, {}, {}, {}, {}, {}, {};
local PERSON = {};     -- pid -> true: has a peer
local BOT_OF = {};     -- what the test itself knows of the bots
local C = {chat = 0};  -- what the stub core did

local function matches(set, i)
	local flags, data = math.floor(set / SET), set % SET;
	if (flags == 1) then return CONNECTED[i] == true; end
	if (flags == 2) then return CONNECTED[i] == true and i ~= data; end
	if (flags == 3) then return JOINED[i] == true and TEAM[i] - 1 == data; end
	if (flags == 4) then
		return i ~= math.floor(data / 256) and CONNECTED[i] == true
			and (not JOINED[i] or TEAM[i] - 1 ~= data % 256);
	end
	return set == i;
end
local pid_matches = matches;

-- the real piditer walks every slot (lua.c do_piditer) and yields bots
local VISITS = {};      -- "file:line" -> bots visited
local piditer_calls = 0;
local function where(level)
	for l = level, level + 12 do
		local info = debug.getinfo(l, "Sl");
		if (info == nil) then return "?"; end
		local src = info.short_src;
		if (not src:find("core.lua", 1, true) and not src:find("bot_sends_test", 1, true)
		    and src ~= "[C]") then
			return src .. ":" .. info.currentline;
		end
	end
	return "?";
end
function piditer(set)
	piditer_calls = piditer_calls + 1;
	local list = {};
	for i = 0, MAX_PLAYERS - 1 do
		if (matches(set, i)) then list[#list + 1] = i; end
	end
	local at = where(2);
	local n = 0;
	return function()
		n = n + 1;
		local i = list[n];
		if (i ~= nil and BOT_OF[i]) then VISITS[at] = (VISITS[at] or 0) + 1; end
		return i;
	end
end
function is_connected(pid) return CONNECTED[pid] == true; end
function is_joined(pid) return JOINED[pid] == true; end
function is_alive(pid) return ALIVE[pid] == true; end
function get_team(pid) return TEAM[pid] or 0; end
function get_name(pid) return NAME[pid] or "?"; end
function get_position(pid) return {x = 100 + pid, y = 100, z = 30}; end
function get_ipaddr(pid) return PERSON[pid] and 1 or 0; end
function is_fakepid(pid) return pid >= MAX_PLAYERS and pid < SET; end
local INPUTS = {};
function get_inputs(pid) return INPUTS[pid] or 0; end
function is_airborne() return false; end
function pid_connected_table(v)
	-- a function default makes a fresh value for each id, as the core's does
	return setmetatable({}, {__index = function(t, k)
		if (type(v) ~= "function") then return v; end
		local d = v();
		rawset(t, k, d);
		return d;
	end});
end
pid_joined_table = pid_connected_table;
function register_command() end
-- the one person is a client that speaks every extension (lib_ext's answers)
function ext_register() end
function ext_unregister() end
function ext_supported(pid, id) return PERSON[pid] and 1 or nil; end
function ext_replied(pid) return true; end
function get_fog() return {r = 10, g = 10, b = 10}; end
function set_fog() end
function masterlist_set_players() end
function masterlist_set_max_players() end
function has_cap() return false; end
function bot_resilence_stub() end

-- the packets, by the id the protocol gives them
local ID = {send_chat = 17, server_msg = 17, send_state = 15, send_state_ctf = 15,
	send_state_tc = 15, send_existing_player = 9, send_spawn_player = 12,
	send_kill = 16, send_block_action = 5, send_block_line = 6,
	send_set_block_color = 8, send_set_tool = 4, send_player_update = 2,
	send_orientation = 1, send_position = 0, send_reload = 28, send_restock = 23,
	send_intel_capture = 22, send_intel_pickup = 21, send_intel_drop = 20,
	send_disconnect = 20, send_move_object = 24, send_map_start = 18,
	send_fog = 27, send_move_input = 3, send_mouse_input = 3, send_grenade = 6,
	send_quirks = 192, send_quirks_off = 193};

local server = {};
_G.server = server;
-- patches/lsd 0002: pid_recipient(), the slots of a group that have a peer,
-- is what the core's loops that send walk; and lua.c hands the scripts' send
-- chain no send the core makes to one slot with no peer (SEND_TO_NOBODY):
-- `core.X` is the core calling st->f.X, the chain's top
local function pid_recipient(set, i) return PERSON[i] == true and pid_matches(set, i); end
local STOPPED = {};     -- name -> sends the core made at a bot, ended in C
local core = setmetatable({}, {__index = function(t, name)
	local f = function(pid, ...)
		if (pid < MAX_PLAYERS and not PERSON[pid]) then
			STOPPED[name] = (STOPPED[name] or 0) + 1;
			return 0;
		end
		return _G[name](pid, ...);
	end
	rawset(t, name, f);
	return f;
end});
local function pkt(name, ...)
	return string.char(ID[name] or 255) .. name;
end
-- the stub's typed sends: what funcs_send.c does, a packet through the chain
local function typed(name, unreliable)
	server[name] = function(pid, ...)
		return (unreliable and core.send_packet_unreliable or core.send_packet)(pid, pkt(name));
	end
end
for name in pairs(ID) do typed(name, name == "send_player_update"); end
function server.server_msg(pid, msg) return core.send_packet(pid, string.char(17) .. "server_msg"); end
function server.send_chat(pid, msg, ty, from) return core.send_packet(pid, string.char(17) .. "chat"); end
-- send_spawn_player: a walk of the slots that match, has_quirk each, SEND each
function server.send_spawn_player(pid, pos, gun, team, name, from)
	for i = 0, MAX_PLAYERS - 1 do
		if (pid_recipient(pid, i)) then
			has_quirk(i, 1);
			core.send_packet(i, string.char(12) .. "spawn");
		end
	end
end
function server.has_quirk(pid, q) return PERSON[pid] == true and QUIRK[pid] == true; end
function server.send_existing_player(pid, ...) return core.send_packet(pid, string.char(9) .. "existing"); end
function server.send_connected_players(pid)
	for i = 0, MAX_PLAYERS - 1 do
		if (JOINED[i]) then
			core.send_existing_player(pid, TEAM[i], 0, 0, 0, {}, NAME[i], i);
		end
	end
end
-- main.c demand_fingerprint: a handshake to each recipient that has not
-- made it (the person has), then the version request
function server.demand_fingerprint(pid)
	core.send_packet(pid, "\x22version");
end
function server.send_state(pid)
	core.send_connected_players(pid);
	demand_fingerprint(pid);
	core.send_state_ctf(pid);
end
function server.send_map(pid)
	core.send_map_start(pid, 1);
	core.send_packet(pid, string.char(19) .. "chunk");
	for i = 0, MAX_PLAYERS - 1 do
		if (pid_recipient(pid, i)) then core.send_state(i); end
	end
end
function server.get_effective_max_players() return 255; end
function server.get_anon_pid() return 254; end
function server.assign_new_pid()
	for i = 0, 253 do
		if (not CONNECTED[i]) then return i; end
	end
	return MAX_PLAYERS;
end
function server.on_successful_connect(pid)
	CONNECTED[pid] = true;
	core.send_map(pid);
end
function server.on_disconnect(pid)
	if (JOINED[pid]) then core.send_disconnect(PID_BROADCAST, pid); end
	CONNECTED[pid], JOINED[pid], ALIVE[pid] = nil, nil, nil;
end
function server.disconnect() end
function server.disconnect_now() end
function server.on_join(pid, team, gun, name)
	NAME[pid] = name;
	spawn_player(pid, {x = 0, y = 0, z = 0});
end
local SPAWNS = 0;
function server.spawn_player(pid)
	SPAWNS = SPAWNS + 1;
	JOINED[pid], ALIVE[pid], HP[pid] = true, true, 100;
	TEAM[pid] = TEAM[pid] or 1;
	core.send_spawn_player(PID_BROADCAST, {x = 0, y = 0, z = 0}, 0, TEAM[pid], NAME[pid] or "?", pid);
	core.send_restock(pid, pid);
	core.send_reload(pid, 10, 20, pid);
end
function server.get_spawn_position() return {x = 0, y = 0, z = 0}; end
function server.on_tool_change(pid, tool) core.send_set_tool(PID_BROADCAST_EXCEPT(pid), tool, pid); end
function server.on_color_change(pid, c) core.send_set_block_color(PID_BROADCAST_EXCEPT(pid), c, pid); end
function server.on_move_input(pid, mask)
	INPUTS[pid] = mask;
	core.send_move_input(PID_BROADCAST_EXCEPT(pid), mask, pid);
end
function server.on_orientation() end
function server.on_mouse_input(pid, m) core.send_mouse_input(PID_BROADCAST_EXCEPT(pid), m, pid); end
function server.set_position() end
function server.tick() end
function server.prepare_map_load() end
function server.finish_map_load()
	for i = 0, MAX_PLAYERS - 1 do JOINED[i], ALIVE[i] = nil, nil; end
	for i = 0, MAX_PLAYERS - 1 do
		if (pid_recipient(PID_BROADCAST, i)) then core.send_map(PID_BROADCAST); break; end
	end
end
function server.send_player_update(pid)
	local live = 0;
	for i = 0, MAX_PLAYERS - 1 do if (ALIVE[i]) then live = i + 1; end end
	return core.send_packet_unreliable(pid, string.char(2) .. string.rep("p", live * 24));
end
function server.player_msg(msg, ty, from)
	core.send_chat(ty == 0 and PID_BROADCAST or PID_BROADCAST_TEAM(TEAM[from]), msg, ty, from);
end
function server.kill(pid, ty, killer)
	ALIVE[pid] = false;
	core.send_kill(PID_BROADCAST, 0, ty, killer, pid);
end
-- main.c set_hp: the HP is told to the player it is about (SEND(pid, sh))
function server.set_hp(pid, hp)
	HP[pid] = math.max(0, hp);
	core.send_packet(pid, string.char(5) .. "hp");
end
-- main.c damage_player: through the set_hp chain, then a kill at 0
function damage_player(pid, dmg, ty, from)
	set_hp(pid, (HP[pid] or 100) - dmg);
	if (HP[pid] == 0) then kill(pid, ty, from); end
end
function server.set_block(pos, color, from)
	-- main.c set_block: a group sent whole, or for each slot a quirk asks it
	for i = 0, MAX_PLAYERS - 1 do
		if (pid_recipient(PID_BROADCAST, i) and has_quirk(i, 1)) then
			core.send_block_action(i, pos, 0, from);
		end
	end
end
function server.on_any_packet() end

-- the end of the chain: send_packet_flags (funcs_send.c)
local END = {to_bot = 0, to_person = 0, to_set = 0, bot_by = {}, bot_where = {}, person_by = {}};
local function terminal(pid, data, unreliable)
	if (pid < MAX_PLAYERS) then
		if (PERSON[pid]) then
			END.to_person = END.to_person + 1;
			local id = data:byte(1);
			END.person_by[id] = (END.person_by[id] or 0) + 1;
		else
			END.to_bot = END.to_bot + 1;
			local id = data:byte(1);
			END.bot_by[id] = (END.bot_by[id] or 0) + 1;
			local at = where(3);
			END.bot_where[at] = (END.bot_where[at] or 0) + 1;
		end
	elseif (pid >= SET) then
		END.to_set = END.to_set + 1;
	end
	return 0;
end
function server.send_packet(pid, data) return terminal(pid, data, false); end
function server.send_packet_unreliable(pid, data) return terminal(pid, data, true); end

--================================ the core's chains ===========================--
local saved_path, saved_cpath = package.path, package.cpath;
dofile("lsd/scripts/core.lua");
package.path, package.cpath = "catalog/core/?.lua;lsd/scripts/?.lua;catalog/overrides/?.lua;" .. saved_path, saved_cpath;
function log(fmt, ...) LOGS[#LOGS + 1] = string.format(fmt, ...); end
package.preload["lib_bulk_destroy"] = function() return true; end

-- as an image has them: the catalog's override of an upstream file, else upstream's
local function modfile(rel)
	local f = io.open("catalog/overrides/" .. rel .. ".lua", "r");
	if (f) then f:close(); return "catalog/overrides/" .. rel .. ".lua"; end
	return "lsd/scripts/" .. rel .. ".lua";
end
local LOADED = {};
local function load_mod(path)
	local m = dofile(path);
	assert(type(m) == "table", path .. " returned no module");
	m.name = path:match("([^/]+)%.lua$");
	register(m);
	LOADED[#LOADED + 1] = m.name;
	return m;
end

--================================ the counters ===============================--
local ENTRY = {bot = {}, person = 0, set = 0};   -- at the chain's top: by name
local BY_SCRIPT = {};     -- "file:line" -> sends made at a bot pid, at the top
local SEQ = {"send_packet", "send_packet_unreliable"};
for name in pairs(ID) do SEQ[#SEQ + 1] = name; end
SEQ[#SEQ + 1] = "server_msg";
-- loaded last: its xearly hooks are the first a send meets
local probe = init_mod();
for _, name in ipairs(SEQ) do
	probe.xearly[name] = function(pid, ...)
		if (pid < MAX_PLAYERS and not PERSON[pid]) then
			ENTRY.bot[name] = (ENTRY.bot[name] or 0) + 1;
			local at = where(3);
			BY_SCRIPT[at] = (BY_SCRIPT[at] or 0) + 1;
		elseif (pid >= SET) then
			ENTRY.set = ENTRY.set + 1;
		else
			ENTRY.person = ENTRY.person + 1;
		end
		return probe.xearly.next[name](pid, ...);
	end
end

--================================ the game ===================================--
-- the group's upstream scripts, loaded before any catalog script, as the image does
load_mod(modfile("purgatory"));
load_mod(modfile("command_ignore"));
load_mod(modfile("command_secspec"));
load_mod(modfile("command_ups"));
local lib_bot = load_mod("catalog/libs/bot/lib_bot.lua");
local function catalog(path)
	local ok, m = pcall(load_mod, path);
	if (not ok) then
		print("  (not carried by the stubs: " .. path .. ": " .. tostring(m):sub(1, 90) .. ")");
		return nil;
	end
	return m;
end
for _, path in ipairs{
	"catalog/overrides/lib_l10n.lua",
	"catalog/extensions/player_limit/lib_player_limit.lua",
	"catalog/extensions/silent_player/lib_silent_player.lua",
	"catalog/extensions/message_types/lib_message_types.lua",
	"catalog/extensions/teamplay/lib_teamplay.lua",
	"catalog/libs/callouts/lib_callouts.lua",
	"catalog/extensions/pie_menu/lib_pie_menu.lua",
	"catalog/extensions/night/lib_night.lua",
	"catalog/overrides/motd.lua",
} do catalog(path); end
register(probe);
io.stderr:write("\n");

print("\n1. the minute: " .. BOTS_N .. " bots, one person, " .. TICKS .. " ticks");
local person = 0;
PERSON[person] = true;
QUIRK[person] = true;
on_successful_connect(person);
on_join(person, 1, 0, "alice");
local made = 0;
for i = 1, BOTS_N do
	local pid = bot_create{team = 1 + i % 2, name = "bot" .. i,
		think = function(p) end};
	if (pid) then BOT_OF[pid] = true; made = made + 1; end
end
eq(made, BOTS_N, "the bots are in");
local bot_pids = {};
for pid in pairs(BOT_OF) do bot_pids[#bot_pids + 1] = pid; end
table.sort(bot_pids);

-- every Lua function entered during the minute, by file: the cost a
-- script pays, whoever asked for it
local CALLS, CALLS_BY = 0, {};
local function count_calls(on)
	if (not on) then debug.sethook(); return; end
	debug.sethook(function()
		local info = debug.getinfo(2, "S");
		if (info ~= nil and info.what == "Lua") then
			CALLS = CALLS + 1;
			local src = info.short_src;
			CALLS_BY[src] = (CALLS_BY[src] or 0) + 1;
		end
	end, "c");
end

local DRIVE_ERRORS = {};
local function drive(what, fn)
	local ok, err = xpcall(fn, function(e) return tostring(e); end);
	if (not ok) then DRIVE_ERRORS[#DRIVE_ERRORS + 1] = what .. ": " .. tostring(err):sub(1, 120); end
end

local function run_minute()
	for n = 1, TICKS do
		NOW = n / 60;
		-- a World Update for everybody
		send_player_update(PID_BROADCAST);
		-- what the bots do: keys, a block, a death and a respawn
		if (n % 30 == 0) then
			local b = bot_pids[(n / 30) % #bot_pids + 1];
			bot_walk(b, {forward = true});
		end
		if (n % 60 == 0) then
			local b = bot_pids[(n / 60) % #bot_pids + 1];
			set_block({x = 10, y = 10, z = 10}, {r = 1, g = 2, b = 3}, b);
		end
		if (n % 120 == 0) then
			local b = bot_pids[(n / 120) % #bot_pids + 1];
			if (ALIVE[b]) then kill(b, 0, person); end
		end
		-- the person's bullets: about 600 hits a minute on the bots
		if (n % 6 == 0) then
			local b = bot_pids[(n / 6) % #bot_pids + 1];
			if (ALIVE[b]) then damage_player(b, 25, 0, person); end
		end
		if (n % 300 == 0) then
			player_msg("hello", 0, person);
			player_msg("team", 1, person);
			server_msg(PID_BROADCAST, "a tip");
		end
		if (n % 600 == 0) then
			local at = {x = 50, y = 50, z = 30};
			drive("teamplay_ping_all", function() teamplay_ping_all(at, {reason = {en = "Here"}}); end);
			drive("teamplay_mark_all", function() teamplay_mark_all(5, 5, {}); teamplay_clear_all(5); end);
			drive("teamplay_send_config", function() teamplay_send_config(); end);
			drive("callouts_ping_team", function() callouts_ping_team(1, at, {en = "Here"}); end);
			drive("msg_send", function() msg_send(PID_BROADCAST, 1, "hello"); msg_send(PID_BROADCAST, 0, {en = "big"}); end);
			drive("l10n_send_chat", function() l10n_send_chat(PID_BROADCAST, {en = "hello %(a)"}, {a = 1}); end);
			drive("server_msg", function() server_msg(PID_BROADCAST, {en = "a tip"}); end);
			drive("send_fog", function() send_fog(PID_BROADCAST, {r = 1, g = 2, b = 3}); end);
			drive("pie_menu_add", function()
				pie_menu_add("probe", {when = "block", slices = {{text = "/a"}}}, 1);
			end);
			drive("flashlight", function()
				flashlight_announce_default();
				flashlight_set(bot_pids[1], true);
				flashlight_set(bot_pids[2], true);
			end);
		end
		if (n == 1800) then
			prepare_map_load();
			finish_map_load();
		end
		tick();
	end
end
if (WANT_TABLE) then count_calls(true); end
run_minute();
count_calls(false);

--================================ the report =================================--
local function sorted(t)
	local k = {};
	for key in pairs(t) do k[#k + 1] = key; end
	table.sort(k, function(a, b) return tostring(a) < tostring(b); end);
	return k;
end
local n_drops, by_name, drop_from = 0, {}, {};
if (bot_guard_drops ~= nil) then n_drops, by_name, drop_from = bot_guard_drops(); end
-- the core's own sends to the player an event is about are not a script's
local entry_bot_total = 0;
for name, v in pairs(ENTRY.bot) do
	entry_bot_total = entry_bot_total + v;
end
local visits_total = 0;
for _, v in pairs(VISITS) do visits_total = visits_total + v; end

if (WANT_TABLE) then
	print("\n   loaded: " .. table.concat(LOADED, " "));
	print("   at the top of the chain, sends made at a bot pid: " .. entry_bot_total);
	for _, k in ipairs(sorted(BY_SCRIPT)) do print(string.format("      %-60s %6d", k, BY_SCRIPT[k])); end
	for _, k in ipairs(sorted(ENTRY.bot)) do print(string.format("      by packet %-30s %6d", k, ENTRY.bot[k])); end
	print("   guard drops: " .. n_drops);
	for _, k in ipairs(sorted(by_name)) do
		print(string.format("      %-30s %6d  first from %s", k, by_name[k], drop_from[k]));
	end
	print("   the core's sends to a bot, ended in C (0002):");
	for _, k in ipairs(sorted(STOPPED)) do print(string.format("      %-30s %6d", k, STOPPED[k])); end
	print("   reached the end of the chain addressed to a bot: " .. END.to_bot);
	for _, k in ipairs(sorted(END.bot_where)) do print(string.format("      %-60s %6d", k, END.bot_where[k])); end
	print("   bots visited by piditer loops: " .. visits_total);
	for _, k in ipairs(sorted(VISITS)) do print(string.format("      %-60s %6d", k, VISITS[k])); end
	print("   Lua calls in the minute: " .. CALLS);
	for _, k in ipairs(sorted(CALLS_BY)) do
		if (CALLS_BY[k] >= 2000) then print(string.format("      %-60s %8d", k, CALLS_BY[k])); end
	end
	print(string.format("   sends reaching the end: %d to persons, %d to groups", END.to_person, END.to_set));
	for _, l in ipairs(LOGS) do print("   log: " .. l); end
end

print("\n2. what was sent");
eq(#DRIVE_ERRORS, 0, "the scripted events all ran", DRIVE_ERRORS[1]);
for _, e in ipairs(DRIVE_ERRORS) do print("    " .. e); end
eq(entry_bot_total, 0, "no send was made at a bot, by a script or the core");
eq(n_drops, 0, "the guard fired 0 times");
eq(END.to_bot, 0, "nothing reached the core addressed to a bot");
check(END.to_set > 0 and END.to_person > 0, "and the person was sent his share",
	END.to_set .. " group sends, " .. END.to_person .. " to him");
eq(END.person_by[12], SPAWNS, "the person was sent every spawn, his own and each bot's");

print("\n3. the broadcaster, and the guard for the script that does not use it");
local sets0, person0 = END.to_set, END.to_person;
local reached0 = ENTRY.set;
broadcast(PID_BROADCAST, "\x1bfog");
eq(END.to_set - sets0, 1, "broadcast: one call into the core for the group, whatever the bots");
broadcast(bot_pids[1], "\x1bfog");
broadcast(PID_BROADCAST_TEAM(7), "\x1bfog");
eq(END.to_set - sets0, 1, "a bot alone, or a group with no person in it: nothing is sent");
eq(ENTRY.set - reached0, 1, "and no call is made for them");
broadcast(person, "\x1bfog", true);
eq(END.to_person - person0, 1, "a person alone: sent");
local seen = {};
broadcast_each(PID_BROADCAST, function(i) seen[#seen + 1] = i; end);
eq(#seen, 1, "broadcast_each: fn for the person of the group, none of the 100 bots");

local n0 = bot_guard_drops();
for i in piditer(PID_BROADCAST) do send_fog(i, {r = 1, g = 2, b = 3}); end
local n1, by = bot_guard_drops();
eq(n1 - n0, BOTS_N, "a script that sends to each player is caught: one drop for each bot");
eq(by.send_fog, BOTS_N, "by the function it called");
for i in piditer(PID_BROADCAST) do
	if (BOT_OF[i]) then send_packet(i, "\x1bfog"); end
end
eq(END.to_bot, 0, "and nothing of it reached the core");
-- a send passed on by a wrapper that only hands the pid on (as lib_l10n's
-- l10n_send_chat does) is the caller's: the script that chose the bot
local pass_on = loadstring("return function(pid, s) server_msg(pid, s); end", "=lib_l10n (a wrapper)")();
pass_on(bot_pids[3], "a plain line");
local _, _, from = bot_guard_drops();
check(from.server_msg ~= nil and from.server_msg:find("bot_sends_test", 1, true) ~= nil,
	"a send passed on by lib_l10n is put down to the script that called it", from.server_msg);
for t = 1, 61 do NOW = NOW + 1; tick(); end
local told;
for _, l in ipairs(LOGS) do if (l:find("addressed to bots were dropped", 1, true)) then told = l; end end
check(told ~= nil and told:find("send_fog", 1, true) ~= nil and told:find("bot_sends_test", 1, true) ~= nil,
	"and said in the log once a minute, with the place it came from", told);

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
