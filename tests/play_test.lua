-- play_test.lua -- when a casual game ends
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/play_test.lua      (from the repository root)
--
-- lib_play's decision, against a stubbed clock and player count, and
-- its tick against a stubbed server: who counts as a player, and that
-- the end is os.exit.

package.path = "catalog/core/?.lua;" .. package.path;

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

local CONNECTED, BOTS = {}, {};
local NOW = 0;
MAX_PLAYERS = 32;
function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
	before={}, after={}, next={}, early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function log() end
function get_time() return NOW; end
function is_connected(pid) return CONNECTED[pid] == true; end
function bot_is_bot(pid) return BOTS[pid] == true; end

local function fresh()
	package.loaded.lib_play = nil;
	play_idle, play_wait = nil, nil;
	return dofile("catalog/core/lib_play.lua");
end

print("\n1. nobody comes");
fresh();
eq(play_should_stop(0, 0), nil, "at start, nobody yet: wait");
eq(play_should_stop(599, 0), nil, "still within play_wait");
eq(play_should_stop(600, 0), "nobody joined", "play_wait passed: over");

print("\n2. players come and go");
fresh();
eq(play_should_stop(0, 0), nil, "start");
eq(play_should_stop(30, 2), nil, "two players");
eq(play_should_stop(700, 1), nil, "one left: play goes on, play_wait no longer matters");
eq(play_should_stop(800, 0), nil, "the last one leaves: the grace begins");
eq(play_should_stop(840, 1), nil, "a reconnect within it: still on");
eq(play_should_stop(900, 0), nil, "gone again: the grace starts over");
eq(play_should_stop(959, 0), nil, "not quite play_idle");
eq(play_should_stop(960, 0), "the last player left", "play_idle after the last one: over");

print("\n3. the tick: people count, bots do not, and the end is os.exit");
local mod = fresh();
local exited;
local real_exit = os.exit;
os.exit = function(code) exited = code; end
CONNECTED = {[0] = true, [5] = true};
BOTS = {[5] = true};
NOW = 10; mod.after.tick();
CONNECTED = {[5] = true};          -- the person left; the bot stays
NOW = 20; mod.after.tick();
NOW = 79; mod.after.tick();
eq(exited, nil, "a bot alone does not keep it going, but the grace holds");
NOW = 81; mod.after.tick();
eq(exited, 0, "after play_idle, the server exits cleanly");
os.exit = real_exit;

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
