-- vote_map_test.lua -- /va: the vote, the next map, and one from the web
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/vote_map_test.lua      (from the repository root)
local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what);
	else failures = failures + 1; print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or "")); end
end

--============================= STUBS ================================--
PID_BROADCAST = 0x20000000;
function init_mod() return {impl = {}, after = {}, before = {}, next = {}, late = {}, early = {}, xearly = {}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function log() end
local NOW = 100;
function get_time() return NOW; end
local JOINED = {[0] = true, [1] = true, [2] = true};
function is_joined(i) return JOINED[i] == true; end
function is_fakepid() return false; end
function get_name(i) return "P" .. i; end
local cmds = {};
function register_command(c) for _, n in ipairs(c.name) do cmds[n] = c; end end
local advanced, loaded = 0, {};
function load_map(n) loaded[#loaded+1] = n; end
gamemode = "babel";

-- the data folder: a temporary one
local DATA = os.tmpname(); os.remove(DATA); os.execute("mkdir -p " .. DATA .. "/rw");
local real_getenv = os.getenv;
os.getenv = function(k) if (k == "LSD_DATA") then return DATA; end return real_getenv(k); end

local L = dofile("tests/support/l10n_env.lua").load{};
L.pids = {0, 1, 2};
local mod = dofile("catalog/tools/vote_map/vote_map.lua");
-- the hook chain as LSd links it: advance_map is ours, then map_queue's
mod.next.advance_map = function() advanced = advanced + 1; end
function advance_map() return mod.advance_map(); end
local function va(pid) cmds.va.func(pid, {}); end
local function last() return L.chat[#L.chat] and L.chat[#L.chat].text or ""; end
local function exists(p) local f = io.open(p); if (f) then f:close(); return true; end return false; end
local function slurp(p) local f = io.open(p); local s = f and f:read("*a"); if (f) then f:close(); end return s; end
local function spit(p, s) local f = io.open(p, "w"); f:write(s); f:close(); end
local function tick(secs) NOW = NOW + (secs or 1); mod.after.tick(); end

--============================= CHECKS ===============================--
print("\n0. the first map, at start, is the rotation's even in random mode");
map_web_random = true;
advance_map();
check(advanced == 1, "a server cannot wait for the web before it has a map at all");
map_web_random = false;
advanced = 0;
mod.after.load_map();   -- the first map is playing

print("\n1. a majority carries it; until then it waits");
map_web_random = false;
va(0);
check(last():find("P0 wants the next map: type /va to agree %(1/2%)"), "the first /va starts it, saying how many", last());
va(0);
check(last() == "You already voted for the next map.", "one voice each");
check(advanced == 0, "not carried yet");
va(1);
check(advanced == 1, "the second of three carries it: the rotation's next (not random)");

print("\n2. it runs out");
va(2);
tick(vote_map_timeout + 1);
check(last() == "The vote for the next map failed.", "unanswered, it fails");
check(advanced == 1, "and nothing moves");

print("\n3. one alone carries it at once");
JOINED = {[0] = true};
va(0);
check(advanced == 2, "a single player's /va is the next map");

print("\n4. random maps: a new one from the web, through the entrypoint");
map_web_random = true;
va(0);
check(exists(DATA .. "/rw/map_request") and slurp(DATA .. "/rw/map_request") == "babel",
	"asks the entrypoint with a file holding the gamemode");
check(last() == "Fetching a new map from the web...", "and says so");
va(0);
check(last() == "A new map is already on its way.", "a /va meanwhile is told it is coming");
tick();
check(#loaded == 0 and advanced == 2, "nothing yet: the game plays on");
spit(DATA .. "/rw/map_result", "added babel_arena.vxl from hosting.dgd.cx, with its .txt\n");
tick();
check(loaded[1] == "babel_arena", "the answer's map is loaded", loaded[1]);
check(not exists(DATA .. "/rw/map_result"), "and the answer is cleared");

print("\n4b. random mode: every map change is a new map from the web, a round's end too");
os.remove(DATA .. "/rw/map_request");
advance_map();   -- as map_queue does at a game's end, or time_limit
check(exists(DATA .. "/rw/map_request") and advanced == 2, "the end of a round asks the web too, not the rotation");
advance_map();
check(advanced == 2, "a second change while one is on its way is that one");
spit(DATA .. "/rw/map_result", "added Iceland.vxl from hosting.dgd.cx\n");
tick();
check(loaded[2] == "Iceland", "and it is loaded when it comes", loaded[2]);

print("\n5. no map from the web: the rotation's next");
os.remove(DATA .. "/rw/map_request");
va(0);
spit(DATA .. "/rw/map_result", "lsdctl: no map could be had\n");
tick();
check(advanced == 3 and last() == "No new map could be had: on to the next one here.", "a failed fetch moves on here");
os.remove(DATA .. "/rw/map_request");
va(0);
tick(vote_map_fetch_secs + 1);
check(advanced == 4 and not exists(DATA .. "/rw/map_request"), "no answer in time: the rotation's next, the request withdrawn");

L.clean(check);
os.execute("rm -rf " .. DATA);
print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
