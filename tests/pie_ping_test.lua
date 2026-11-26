-- pie_ping_test.lua -- a pie wedge's ping, from its text to a team-mate's packet
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/pie_ping_test.lua      (from the repository root)
--
-- For every gamemode that has callouts (and the default pings of the
-- rest), in every language a wedge has: the text lib_callouts hands the
-- pie menu, with the %h a client fills in with the point under its
-- crosshair, is run as the /pingmark command it is -- on a server with a
-- fleet of bots, under the real lib_bot (whose people_in picks who a
-- team's ping is for), the real lib_teamplay and lib_callouts, over a
-- stub of the core that makes its sets the way lua.c and main.c do
-- (PID_BROADCAST_TEAM holds a team less one, which get_team says plain).
-- It asserts what reaches each client: a Ping packet for the pinger and
-- the team-mate, none for the other team, nothing addressed to a bot.
local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what) else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end

bit = require("bit");
MAX_PLAYERS = 255;
local SET = 0x20000000;
PID_BROADCAST = SET;
function PID_BROADCAST_TEAM(t) return 3 * SET + t - 1; end     -- as lua.c
function PID_BROADCAST_EXCEPT(p) return 2 * SET + p; end
local NOW = 100;
function get_time() return NOW; end
function log() end
function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
	before={}, after={}, next={}, early={before={},after={},next={}},
	xearly={before={},after={},next={}}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function pid_connected_table(v)
	return setmetatable({}, {__index = function() return v; end});
end
pid_joined_table = pid_connected_table;
function get_team_color() return {r = 0, g = 0, b = 0}; end

--=============================== the stub core ===============================--
-- teams as the core has them: 0 and 1 inside, get_team 1 and 2 outside
local CONNECTED, TEAM, EYE = {}, {}, {};
local PERSON = {};
local RECEIVED = {};      -- pid -> the packets that reached it
function is_connected(p) return CONNECTED[p] == true; end
function is_joined(p) return CONNECTED[p] == true; end
function is_alive(p) return CONNECTED[p] == true; end
function get_team(p) return TEAM[p]; end
function get_position(p) return EYE[p]; end
function get_orientation(p) return {x = 1, y = 0, z = 0}; end
function raycast(a, b)               -- a wall at x = 105.5: the last empty voxel before it
	if (b.x > 105.5) then return {x = 105, y = 100, z = 30}; end
	return nil;
end
function get_ipaddr(p) return PERSON[p] and 1 or 0; end
local function pid_matches(set, i)
	local flags, data = math.floor(set / SET), set % SET;
	if (flags == 1) then return CONNECTED[i] == true; end
	if (flags == 2) then return CONNECTED[i] == true and i ~= data; end
	if (flags == 3) then return CONNECTED[i] == true and TEAM[i] - 1 == data; end
	return set == i;
end
local ALL = {};
function piditer(set)
	local n, hit = 0, {};
	for i = 0, MAX_PLAYERS - 1 do
		if (set < MAX_PLAYERS and set == i or set >= MAX_PLAYERS and pid_matches(set, i)) then
			hit[#hit + 1] = i;
		end
	end
	return function() n = n + 1; return hit[n]; end
end
local TO_BOT = 0;
function send_packet(set, data)
	for i = 0, MAX_PLAYERS - 1 do
		if (pid_matches(set, i)) then
			if (PERSON[i]) then
				RECEIVED[i][#RECEIVED[i] + 1] = data;
			else
				TO_BOT = TO_BOT + 1;
			end
		end
	end
end
function send_packet_flags(set, data) return send_packet(set, data); end
function send_chat() end
function l10n_send_chat() end
function send_usage() end
function ext_supported(p, id) return PERSON[p] and 1 or nil; end

local registered = {};
function register_command(c) registered[c.name] = c; end

-- the people: 0 pings, 1 is his team-mate, 2 is on the other team; every
-- other seat is a bot, which lib_bot never hears of as a connect
package.path = "catalog/libs/callouts/?.lua;" .. package.path;
package.preload["lib_bulk_destroy"] = function() return true; end
local bot = dofile("catalog/libs/bot/lib_bot.lua");
local function join(p, team, person)
	CONNECTED[p], TEAM[p], PERSON[p], EYE[p] = true, team, person, {x = 100, y = 100, z = 30};
	RECEIVED[p] = {};
	if (person) then bot.xearly.before.on_successful_connect(p); end
end
join(0, 1, true); join(1, 1, true); join(2, 2, true);
for i = 3, 60 do join(i, 1 + i % 2, false); end

--================================== loading ==================================--
local sliced = {};
function pie_menu_add() end
function pie_menu_slice(name, slices) sliced[name] = slices; end
function pie_menu_remove() end
function l10n_languages() return {"fr", "es", "zh", "ru"}; end
function l10n_get_str_lang(lang, m) return m[lang] or m.en; end
dofile("catalog/extensions/teamplay/lib_teamplay.lua");
function teamplay_supported(p) return PERSON[p] == true; end
local callouts = dofile("catalog/libs/callouts/lib_callouts.lua");

local function ls(dir)
	local out = {};
	for f in io.popen("ls " .. dir):lines() do out[#out + 1] = (f:gsub("%.lua$", "")); end
	return out;
end

local PING = 112;
local function pings_of(p) 
	local n = 0;
	for _, d in ipairs(RECEIVED[p]) do
		if (string.byte(d, 1) == PING) then n = n + 1; end
	end
	return n;
end

-- what a pie wedge sends, run the way commands.lua runs a chat line: the
-- command, then the rest split on whitespace
local function wedge(text, pid)
	local words = {};
	for w in string.gmatch(text, "%S+") do words[#words + 1] = w; end
	local c = registered[string.sub(table.remove(words, 1), 2)];
	c.func(pid, words);
end

local modes = ls("catalog/libs/callouts/callouts");
modes[#modes + 1] = "editor";            -- none of its own: the default pings
for _, mode in ipairs(modes) do
	print("\n" .. mode);
	package.loaded["callouts." .. mode] = nil;
	gamemode = mode;
	sliced = {};
	callouts.on_unload();
	callouts.on_load();
	local slices = sliced.callouts_pings;
	if (slices == nil) then
		print("  (no pings)");
	else
		for _, sl in ipairs(slices) do
			for lang, text in pairs(sl.text) do
				NOW = NOW + 2;
				for p = 0, 2 do RECEIVED[p] = {}; end
				TO_BOT = 0;
				wedge((string.gsub(text, "%%h", "105.00 100.00 30.00")), 0);
				local what = string.format("%s/%s %q", mode, lang, text);
				check(pings_of(0) == 1 and pings_of(1) == 1, what .. ": the pinger and his team-mate are shown it",
					pings_of(0) .. "," .. pings_of(1));
				check(pings_of(2) == 0, what .. ": the other team is not");
				check(TO_BOT == 0, what .. ": no bot was sent one");
			end
		end
	end
end

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
