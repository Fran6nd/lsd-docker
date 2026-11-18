-- callouts_test.lua -- lib_callouts: its pies, and pings only through Teamplay
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
package.path = "catalog/libs/callouts/?.lua;" .. package.path;

local passed, failed = 0, 0;
local function check(ok, what)
	if (ok) then passed = passed + 1; print("  PASS " .. what);
	else failed = failed + 1; print("  FAIL " .. what); end
end

--============================= STUBS ================================--
function init_mod() return {after = {}, before = {}, next = {}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function pid_connected_table(d) return setmetatable({}, {__index = function() return d; end}); end
function log() end
PID_BROADCAST = -1;
function piditer() local i = -1; return function() i = i + 1; if (i < 3) then return i; end end; end
local teams = {[0] = 1, [1] = 1, [2] = 2};
function get_team(pid) return teams[pid]; end
local now = 100;
function get_time() return now; end
function l10n_msg(m) return m; end
function l10n_str(_, m) return m.en; end

local chat, said = {}, {};
function send_chat(to, line, kind, from) chat[#chat+1] = {to = to, line = line, from = from}; end
function l10n_send_chat(to, m) said[#said+1] = {to = to, m = m}; end

local added, sliced = {}, {};
function pie_menu_add(name, pie, order) added[name] = pie; end
function pie_menu_slice(name, slices, order) sliced[name] = slices; end
function pie_menu_remove(name) added[name], sliced[name] = nil, nil; end

local supported = {[0] = true};
function teamplay_supported(pid) return supported[pid] == true; end
TEAMPLAY_REFUSED = {sight = {en = "You can only ping what you are looking at."}};
local requests, refuse = {}, nil;
function teamplay_request_ping(pid, pos, reason)
	requests[#requests+1] = {pid = pid, pos = pos, reason = reason};
	return refuse;
end

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
check(pings[2].pie.id == "mark" and pings[2].text == "/callout ping intel %h",
	"into the Mark pie, sending /callout ping <key> %h");
check(pings[1].show(0) == true and pings[1].show(1) == false,
	"shown only to a client with Teamplay");

print("\n2. a ping goes through Teamplay's rules, with its label as reason");
run("ping", "intel", "10", "20", "30");
local r = requests[#requests];
check(#requests == 1 and r.pid == 0 and r.pos.x == 10 and r.pos.z == 30
	and r.reason.en == "Intel here", "teamplay_request_ping(pid, pos, label)");
check(#chat == 0, "and no chat");
refuse = "sight";
run("ping", "intel", "10", "20", "30");
check(said[#said] and said[#said].m == TEAMPLAY_REFUSED.sight, "a refusal is said back");
refuse = nil;
local n = #requests;
run("ping", "intel");
check(#requests == n and said[#said].m.en == "Nothing to ping there.",
	"no position: nothing sent, the player told");
run("ping", "nope", "1", "2", "3");
check(#requests == n, "an unknown ping key is ignored");

print("\n3. a callout about a place: chat to the team, the marker checked");
run("enemy", "1", "2", "3");
check(#chat == 2 and chat[1].to == 0 and chat[2].to == 1, "said to the team only");
check(#requests == n + 1 and requests[n + 1].reason.en == "Enemy here",
	"its marker through teamplay_request_ping");
local c = #chat;
run("enemy", "1", "2", "3");
check(#chat == c, "callouts_gap holds the next one back");

print("\n4. a gamemode without pings of its own gets the default ones");
mod.on_unload();
gamemode = "editor";
package.loaded["callouts.ctf"] = nil;
mod = dofile("catalog/libs/callouts/lib_callouts.lua");
mod.on_load();
check(added.callouts == nil, "no callouts pie");
check(sliced.callouts_pings ~= nil and sliced.callouts_pings[1].text == "/callout ping enemy %h",
	"the default pings");

print("\n5. ffa: pings = {} means none");
mod.on_unload();
gamemode = "ffa";
mod = dofile("catalog/libs/callouts/lib_callouts.lua");
mod.on_load();
check(added.callouts ~= nil and sliced.callouts_pings == nil, "a callouts pie, no pings");

print(string.format("\n%d checks, %d failed", passed + failed, failed));
os.exit(failed == 0 and 0 or 1);
