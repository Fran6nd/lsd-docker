-- callouts_test.lua -- lib_callouts: its pies, and pings only through Teamplay
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
package.path = "catalog/libs/callouts/?.lua;" .. package.path;

local passed, failed = 0, 0;
local function check(ok, what, detail)
	if (ok) then passed = passed + 1; print("  PASS " .. what);
	else failed = failed + 1; print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or "")); end
end

--============================= STUBS ================================--
function init_mod() return {after = {}, before = {}, next = {}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function pid_connected_table(d) return setmetatable({}, {__index = function() return d; end}); end
function log() end
MAX_PLAYERS = 32;
PID_BROADCAST = 0x20000000;
local teams = {[0] = 1, [1] = 1, [2] = 2};
function get_team(pid) return teams[pid]; end
local now = 100;
function get_time() return now; end

-- the real lib_l10n: send_chat and l10n_send_chat deliver finished text,
-- as players read it (and so does piditer: the players 0..2 are connected)
local chat = {};
local L = dofile("tests/support/l10n_env.lua").load{
	send_chat = function(to, line, kind, from) chat[#chat+1] = {to = to, line = line, from = from}; end,
};
L.pids = {0, 1, 2};
local said = L.chat;

local added, sliced = {}, {};
function pie_menu_add(name, pie, order) added[name] = pie; end
function pie_menu_slice(name, slices, order) sliced[name] = slices; end
function pie_menu_remove(name) added[name], sliced[name] = nil, nil; end

local supported = {[0] = true};
function teamplay_supported(pid) return supported[pid] == true; end
-- any ping a callout made would land here: none may
local pinged = 0;
function teamplay_ping() pinged = pinged + 1; return true; end

local cmd;
function register_command(c) cmd = c; end

local function run(...) cmd.func(0, {...}); end

--============================= CHECKS ===============================--
print("\n1. ctf: a callouts pie, and its own pings in the Mark pie");
gamemode = "ctf";
local mod = dofile("catalog/libs/callouts/lib_callouts.lua");
mod.on_load();
check(added.callouts ~= nil, "the callouts pie is added");
local pings = sliced.callouts_pings;
check(pings ~= nil and #pings == 6, "six ping wedges");
check(pings[2].pie.id == "mark" and type(pings[2].text) == "table"
	and pings[2].text.en == "/pingmark %h Intel here",
	"into the Mark pie, as Teamplay's own /pingmark %h <reason>");
check(pings[1].show(0) == true and pings[1].show(1) == false,
	"shown only to a client with Teamplay");

print("\n2. a callout is words only: no position, no ping");
run("enemy");
check(#chat == 2 and chat[1].to == 0 and chat[2].to == 1, "said to the team only");
check(chat[1].line == "Enemy here!", "as text the player reads", chat[1].line);
check(pinged == 0, "and nothing pinged");
for _, sl in ipairs(added.callouts.slices) do
	check(not string.find(sl.text, "%h", 1, true), "the callout wedge " .. sl.text .. " sends no position");
end
local c = #chat;
run("enemy");
check(#chat == c, "callouts_gap holds the next one back");

print("\n4. a gamemode without pings of its own gets the default ones");
mod.on_unload();
gamemode = "editor";
package.loaded["callouts.ctf"] = nil;
mod = dofile("catalog/libs/callouts/lib_callouts.lua");
mod.on_load();
check(added.callouts == nil, "no callouts pie");
check(sliced.callouts_pings ~= nil and sliced.callouts_pings[1].text.en == "/pingmark %h Enemy",
	"the default pings");

print("\n5. ffa: pings = {} means none");
mod.on_unload();
gamemode = "ffa";
mod = dofile("catalog/libs/callouts/lib_callouts.lua");
mod.on_load();
check(added.callouts ~= nil and sliced.callouts_pings == nil, "a callouts pie, no pings");

L.clean(check);
print(string.format("\n%d checks, %d failed", passed + failed, failed));
os.exit(failed == 0 and 0 or 1);
