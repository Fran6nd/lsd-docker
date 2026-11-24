-- seats_test.lua -- who gets a player id when bots are many
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/seats_test.lua      (from the repository root)
--
-- lib_player_limit's seats (255 by default) under the core's
-- assign_new_pid, with lib_bot's bots in them: 32, 40, 100 and 254 bots
-- and a person still gets in, a bot giving way when every seat is
-- taken; a bot never makes another give way; engine_bots asked for more
-- than fits says so in the log, once.

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
local function fill(n, fleet)
	local got = 0;
	for i = 1, n do
		local pid = bot_create{team = 1 + i % 2, name = "b" .. i,
			data = fleet and {botlink = true} or nil};
		if (pid == nil) then break; end
		got = got + 1;
	end
	return got;
end
local function reset()
	for pid in pairs(CONNECTED) do
		if (bot_is_bot(pid)) then bot_destroy(pid); end
	end
	CONNECTED, LOGS = {}, {};
end

print("\n1. defaults: 255 seats, ids 0 to 254");
eq(player_limit_max, 255, "player_limit_max is 255 with nothing set");
eq(get_effective_max_players(), 255, "the core counts up to 255");

for _, n in ipairs({32, 40, 100}) do
	print(string.format("\n2. %d bots, then a person", n));
	reset();
	eq(fill(n, true), n, n .. " bots made");
	local pid = person_connects();
	eq(pid, n, "the person gets id " .. n);
	check(pid >= 32 or n < 32, "an id above 31: a client needs Player Limit for it");
	local bots = 0;
	for i in pairs(CONNECTED) do if (bot_is_bot(i)) then bots = bots + 1; end end
	eq(bots, n, "no bot had to leave");
end

print("\n3. every seat taken by bots: a bot gives way");
reset();
eq(fill(300, true), 255, "bots stop at 255, ids 0 to 254");
eq(server.assign_new_pid(), MAX_PLAYERS, "the core alone would turn a person away");
local pid = person_connects();
check(pid >= 0 and pid < 255, "the person gets an id", pid);
check(not bot_is_bot(pid), "and it is no longer a bot's");
eq(pid, 254, "the highest of the fleet gave way");
check(string.find(LOGS[#LOGS] or "", "gives way", 1, true), "said in the log", LOGS[#LOGS]);
eq(bot_create{team = 1, name = "again"}, nil, "a bot asking now finds no seat: bots never make bots give way");
pid = person_connects();
eq(pid, 253, "a second person: a second bot");

print("\n4. the fleet gives way before a gamemode's own bots");
reset();
player_limit_max = 4;
fill(2, false);   -- a hostage, say: ids 0, 1
fill(2, true);    -- engine bots: 2, 3
pid = person_connects();
eq(pid, 3, "an engine bot's seat");
pid = person_connects();
eq(pid, 2, "the other engine bot's");
pid = person_connects();
eq(pid, 1, "then any bot's");
pid = person_connects();
eq(pid, 0, "and the last");
eq(person_connects(), MAX_PLAYERS, "people alone fill it: full is full");

print("\n5. an operator's cap applies to bots and people together");
reset();
player_limit_max = 32;
eq(fill(40, true), 32, "32 seats: 32 bots");
pid = person_connects();
check(pid < 32, "a person still gets in, under 32", pid);
player_limit_max = 255;

print("\n6. engine_bots asked for more than fits: said once, then made up");
reset();
player_limit_max = 10;
local fleet = {};
function botlink_add(o)
	local pid = bot_create{team = o.team, name = "e", data = {botlink = true}};
	if (pid ~= nil) then fleet[pid] = true; end
	return pid;
end
function botlink_remove(pid) bot_destroy(pid); end
function botlink_set() end
gamemode = "tdm";
engine_bots_count = 8;
local eb = dofile("catalog/bots/engine_bots/engine_bots.lua");
LOGS = {};
NOW = 1;
eb.after.tick();
local n = 0;
for i in pairs(CONNECTED) do if (bot_is_bot(i)) then n = n + 1; end end
eq(n, 10, "16 asked for, 10 seats: 10 made");
local said = 0;
for _, l in ipairs(LOGS) do
	if (string.find(l, "16 bots asked for, 10 fit", 1, true)) then said = said + 1; end
end
eq(said, 1, "and the log says so");
NOW = 2;
eb.after.tick();
NOW = 3;
eb.after.tick();
said = 0;
for _, l in ipairs(LOGS) do
	if (string.find(l, "asked for", 1, true)) then said = said + 1; end
end
eq(said, 1, "once, not every second");
player_limit_max = 255;
NOW = 4;
eb.after.tick();
n = 0;
for i in pairs(CONNECTED) do if (bot_is_bot(i)) then n = n + 1; end end
eq(n, 16, "seats raised: all 16");
check(string.find(LOGS[#LOGS] or "", "all 16 bots in", 1, true), "and that is said too", LOGS[#LOGS]);

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
