-- headless_ups_test.lua -- World Updates a second, with headless clients about
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/headless_ups_test.lua      (from the repository root)
--
-- command_ups (each client's /ups, 30 by default) and lib_headless (a
-- headless client gets headless_ups, 10 by default) both thin the World
-- Update the core sends each tick. Loaded as the image loads them --
-- command_ups with the upstream commands, lib_headless later, in the
-- bots phase -- under the core's own chains (lsd/scripts/core.lua), for
-- one second of ticks: every person gets his rate, a headless client
-- the lower of the two, whatever the number of clients.

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
local SET = 0x20000000;
PID_BROADCAST = SET;

local CONNECTED, HEADLESS = {}, {};
local GOT = {};
function piditer(set)
	local list = {};
	if (set == PID_BROADCAST) then
		for i = 0, MAX_PLAYERS - 1 do
			if (CONNECTED[i]) then list[#list + 1] = i; end
		end
	elseif (set < MAX_PLAYERS) then
		list[1] = set;
	end
	local n = 0;
	return function() n = n + 1; return list[n]; end
end
-- no bots here: lib_bot's people are everybody connected
people_in = piditer;
function bot_is_headless(pid) return HEADLESS[pid] == true; end
function bot_mark_nonhuman(pid, yes) HEADLESS[pid] = yes or nil; end
package.preload["lib_bot"] = function() return true; end
function pid_connected_table(v)
	return setmetatable({}, {__index = function() return v; end});
end
function register_command() end
function get_time() return 0; end

server = {};
-- the core's tick sends the World Update to everybody (main.c)
function server.send_player_update(pid)
	for i in piditer(pid) do GOT[i] = (GOT[i] or 0) + 1; end
end
function server.tick() send_player_update(PID_BROADCAST); end
dofile("tests/support/core_env.lua").load();
function log() end

local function load_mod(path)
	local m = dofile(path);
	m.name = path:match("([^/]+)%.lua$");
	register(m);
end
-- as the image: command_ups with the upstream commands (the catalog's
-- override of it if there is one), lib_headless in the bots phase
local f = io.open("catalog/overrides/command_ups.lua", "r");
if (f) then f:close(); end
load_mod(f and "catalog/overrides/command_ups.lua" or "lsd/scripts/command_ups.lua");
load_mod("catalog/tools/headless/lib_headless.lua");

local function second()
	GOT = {};
	for _ = 1, 60 do tick(); end
end

local DEFAULT = 60 / (60 / ups_default_rate);

for _, people in ipairs({1, 2, 3, 4}) do
	CONNECTED, HEADLESS = {}, {};
	for i = 0, people - 1 do CONNECTED[i] = true; end
	second();
	print(string.format("\n%d people, no headless client", people));
	for i = 0, people - 1 do
		eq(GOT[i] or 0, DEFAULT, "person #" .. i .. " gets " .. DEFAULT .. " a second");
	end
end

for _, people in ipairs({1, 2, 3}) do
	CONNECTED, HEADLESS = {}, {};
	for i = 0, people - 1 do CONNECTED[i] = true; end
	for i = people, people + 1 do CONNECTED[i] = true; HEADLESS[i] = true; end
	second();
	print(string.format("\n%d people, 2 headless clients", people));
	for i = 0, people - 1 do
		eq(GOT[i] or 0, DEFAULT, "person #" .. i .. " gets " .. DEFAULT .. " a second");
	end
	local want = math.min(DEFAULT, headless_ups);
	for i = people, people + 1 do
		eq(GOT[i] or 0, want, "headless #" .. i .. " gets " .. want .. " a second");
	end
end

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
