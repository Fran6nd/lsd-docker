-- fleet_sends_test.lua -- nothing is built, sent or walked for a bot
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/fleet_sends_test.lua      (from the repository root)
--
-- lib_bot's people_in (piditer without the bots), and the two upstream
-- scripts overridden to use it or to leave bots alone: command_ups (a
-- World Update per recipient: built for people only) and afkick (a
-- bot's inputs walked every player three times each).
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

MAX_PLAYERS = 255;
PID_BROADCAST = 0x20000000;
local CONNECTED = {};
local LOGS = {};
local NOW = 0;
function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
	before={}, after={}, next={}, early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function log(fmt, ...) LOGS[#LOGS+1] = string.format(fmt, ...); end
function get_time() return NOW; end
function pid_connected_table() return {}; end
function piditer(pid)
	if (pid == PID_BROADCAST) then
		local list = {};
		for i in pairs(CONNECTED) do list[#list+1] = i; end
		table.sort(list);
		local n = 0;
		return function() n = n + 1; return list[n]; end
	end
	local done = false;
	return function() if (done) then return nil; end done = true; return pid; end
end
function is_joined(pid) return CONNECTED[pid] == true; end
package.preload["lib_bulk_destroy"] = function() return true; end

-- lib_player_limit's get_effective_max_players, as the core asks it
local pl = dofile("catalog/extensions/player_limit/lib_player_limit.lua");
function get_effective_max_players() return pl.get_effective_max_players(); end
-- main.c's get_anon_pid: the slot just past the seats, if free
pl.next.get_anon_pid = function()
	local i = get_effective_max_players();
	if (i < MAX_PLAYERS and not CONNECTED[i]) then return i; end
	for j = 0, MAX_PLAYERS - 1 do if (not CONNECTED[j]) then return j; end end
	return MAX_PLAYERS;
end
function get_anon_pid() return pl.get_anon_pid(); end

-- the core: main.c's assign_new_pid, counting up to the seats; and the
-- connect/disconnect a bot goes through
server = {};
function server.assign_new_pid()
	for i = 0, get_effective_max_players() - 1 do
		if (not CONNECTED[i]) then return i; end
	end
	return MAX_PLAYERS;
end
function on_successful_connect(pid) CONNECTED[pid] = true; end
function on_join() end

local bot = dofile("catalog/libs/bot/lib_bot.lua");
bot.next.assign_new_pid = server.assign_new_pid;
function on_disconnect(pid)
	CONNECTED[pid] = nil;
	bot.after.on_disconnect(pid);
end
-- what a person's connect calls: the chain, lib_bot's hook on top
local function person_connects()
	local pid = bot.assign_new_pid();
	if (pid < MAX_PLAYERS) then CONNECTED[pid] = true; end
	return pid;
end
function is_connected(pid) return CONNECTED[pid] == true; end
local TEAM = {};
function get_team(pid) return TEAM[pid] or 0; end
PID_BROADCAST_TEAM = function(t) return 0x20000000 * 3 + t; end

local function list(it)
	local out = {};
	for i in it do out[#out + 1] = i; end
	table.sort(out);
	return table.concat(out, ",");
end

print("\n1. people_in: the recipients with a client behind them");
local made = 0;
for i = 1, 40 do if (bot_create{team = 1 + i % 2, name = "b" .. i, data = {botlink = true}}) then made = made + 1; end end
eq(made, 40, "40 bots");
local a, b = person_connects(), person_connects();
TEAM[a], TEAM[b] = 1, 2;
eq(list(people_in(PID_BROADCAST)), a .. "," .. b, "a broadcast: the two people, none of the 40 bots");
eq(list(people_in(PID_BROADCAST_TEAM(2))), tostring(b), "a team: its person only");
eq(list(people_in(0)), "", "a bot alone: nobody");
eq(list(people_in(a)), tostring(a), "a person alone: him");
eq(list(people_in(255)), "255", "the console's own pid goes as piditer takes it");

print("\n2. command_ups: a World Update for each person, none for a bot");
function register_command() end
function pid_connected_table(v) local t = {}; return setmetatable(t, {__index = function() return v; end}); end
local ups = dofile("catalog/overrides/command_ups.lua");
local sent = {};
ups.next.send_player_update = function(i) sent[#sent + 1] = i; end
ups.send_player_update(PID_BROADCAST);
table.sort(sent);
eq(table.concat(sent, ","), a .. "," .. b, "built for the two people only (it was 42 a tick)");

print("\n3. afkick: a bot's inputs walk nobody");
afkick_time_kick, afkick_time_warn, afkick_time_limbo = 1800, 1740, 120;
function get_inputs() return 0; end
bit = require("bit");
local walks = 0;
local real = piditer;
piditer = function(pid) if (pid == PID_BROADCAST) then walks = walks + 1; end return real(pid); end
local afk = dofile("catalog/overrides/afkick.lua");
afk.on_load();
afk.after.on_join(a);
walks = 0;
afk.after.on_join(0);
local first = walks;
for k = 1, 100 do afk.before.on_move_input(0, k % 2 == 0 and 1 or 2); afk.after.on_mouse_input(0); end
eq(walks, first, "100 inputs of a bot after its first: no walk over the players");
NOW = 1e6;
local kicked = {};
function disconnect(pid) kicked[#kicked + 1] = pid; end
function l10n_send_chat() end
function get_name() return "x"; end
afk.after.tick(); afk.after.tick(); afk.after.tick();
for _, k in ipairs(kicked) do check(not bot_is_bot(k), "a bot is never kicked as away", k); end
check(#kicked >= 1, "a person still is", #kicked);
piditer = real;

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
