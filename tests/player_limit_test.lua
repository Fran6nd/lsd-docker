-- player_limit_test.lua -- what an old client is sent above 32 players
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/player_limit_test.lua      (from the repository root)
--
-- lib_player_limit's outgoing filter, against a stubbed server: the
-- pure filters, then the send hooks with their wait queue.

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

local function hex(s)
	if (s == nil) then return "nil"; end
	return (s:gsub(".", function(c) return string.format("%02x", c:byte()); end));
end
local function eqb(got, want, what)
	check(got == want, what, "got " .. hex(got) .. ", want " .. hex(want));
end

local CONNECTED, BOTS, SPEAKS, REPLIED = {}, {}, {}, {};
local NOW = 0;
MAX_PLAYERS = 255;
PID_BROADCAST = 0x20000000;   -- PID_SET_FLAG(1), as state.h
function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
	before={}, after={}, next={}, early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function log() end
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
	-- as lua.c's do_piditer: only pids under MAX_PLAYERS, so a fake pid
	-- (get_anon_pid, 255 and up) is never iterated
	local done = pid >= MAX_PLAYERS;
	return function() if (done) then return nil; end done = true; return pid; end
end
function bot_is_bot(pid) return BOTS[pid] == true; end
function get_ipaddr(pid) return BOTS[pid] and 0 or 1; end
function ext_supported(pid, id) return SPEAKS[pid] and id == 192 and 1 or nil; end
function ext_replied(pid) return REPLIED[pid] == true; end
function ext_register() end

local SENT = {};
local function reset()
	SENT = {};
	CONNECTED, BOTS, SPEAKS, REPLIED = {}, {}, {}, {};
	NOW = 0;
	player_limit_max = 64;
end
local function load()
	package.loaded.lib_player_limit = nil;
	local max = player_limit_max;
	player_limit_grace, player_limit_queue_max = nil, nil;
	local mod = dofile("catalog/extensions/player_limit/lib_player_limit.lua");
	player_limit_max = max;
	mod.late.next.send_packet = function(pid, data) SENT[#SENT+1] = {pid, data, true}; return 1; end
	mod.late.next.send_packet_unreliable = function(pid, data) SENT[#SENT+1] = {pid, data, false}; return 1; end
	return mod;
end
local function ch(...) return string.char(...); end

local mod = load();
local F = mod.filter;
local WU_MAX = 1 + 32 * 24;

print("\n1. at 32 seats or fewer: straight through");
reset();
player_limit_max = 32;
CONNECTED[40] = true;
mod.late.send_packet(PID_BROADCAST, ch(3, 40, 0));
eq(#SENT, 1, "next called once, whatever the recipients");
eq(SENT[1][1], PID_BROADCAST, "with the original (broadcast) pid");
eqb(SENT[1][2], ch(3, 40, 0), "and the original data");
mod.late.send_packet_unreliable(5, ch(2) .. string.rep("x", 50 * 24));
eq(#SENT, 2, "unreliable too");
eq(#SENT[2][2], 1 + 50 * 24, "untouched");
eq(SENT[2][3], false, "and still unreliable");

print("\n2. low: an old client with id < 32");
eqb(F.low(ch(3, 5, 0, 0)), ch(3, 5, 0, 0), "input of #5 kept");
eq(F.low(ch(3, 40, 0, 0)), nil, "input of #40 dropped");
eqb(F.low(ch(17, 255, 0) .. "hi"), ch(17, 255, 0) .. "hi", "chat from 255 kept");
eqb(F.low(ch(17, 0, 2) .. "hi"), ch(17, 0, 2) .. "hi", "system chat from 0 kept");
eq(F.low(ch(17, 33, 0) .. "hi"), nil, "chat from #33 dropped");
eq(F.low(ch(16, 3, 40, 0, 5)), nil, "kill with a killer >= 32 dropped");
eq(F.low(ch(16, 40, 3, 0, 5)), nil, "kill of a victim >= 32 dropped");
eqb(F.low(ch(16, 3, 4, 0, 5)), ch(16, 3, 4, 0, 5), "kill of two low ids kept");
eqb(F.low(ch(16, 3, 255, 0, 5)), ch(16, 3, 255, 0, 5), "kill by the server kept");
local wu = ch(2) .. string.rep("w", 40 * 24);
eq(#F.low(wu), WU_MAX, "world update cut to 32 players");
eq(#F.low(ch(2) .. string.rep("w", 10 * 24)), 1 + 240, "short world update kept");
eq(F.low(ch(20, 40)), nil, "player left #40 dropped");
eqb(F.low(ch(18, 1, 2, 3, 4)), ch(18, 1, 2, 3, 4), "map start names nobody: kept");
eqb(F.low(ch(19, 9, 9, 9)), ch(19, 9, 9, 9), "map chunk kept");
eqb(F.low(ch(0x60, 3, 20)), ch(0x60, 3, 20), "damage marker on #3 kept");
eq(F.low(ch(0x60, 50, 20)), nil, "damage marker on #50 dropped");
eq(F.low(ch(0x72, 0, 45, 1)), nil, "flashlight light of #45 dropped");
eqb(F.low(ch(0x72, 2, 255, 1, 2, 3, 4, 5, 6)), ch(0x72, 2, 255, 1, 2, 3, 4, 5, 6), "flashlight config for 255 kept");
eqb(F.low(ch(0x72, 1, 1, 2, 3, 4, 5, 6)), ch(0x72, 1, 1, 2, 3, 4), "flashlight bitmap cut to 32 players");
eq(F.low(ch(0x70, 2, 60, 0, 0)), nil, "teamplay mark on #60 dropped");
eqb(F.low(ch(0x70, 0, 1, 0, 0)), ch(0x70, 0, 1, 0, 0), "teamplay config names nobody: kept");
eqb(F.low(ch(0x71, 7)), ch(0x71, 7), "pie menu kept");
eqb(F.low(ch(0x73, 7)), ch(0x73, 7), "daytime kept");
eq(F.low(ch(0x76, 0, 70, 1)), nil, "edit mode of #70 dropped");
eqb(F.low(ch(0x43, 1, 3, 1, 40, 1, 5, 2)), ch(0x43, 1, 3, 1, 5, 2), "silent list keeps only low ids");
eq(F.low(ch(0x43, 1, 40, 1)), nil, "silent list with nothing left dropped");
eq(F.low(ch(0x40, 0, 40, 1, 1, 1, 1, 1, 0, 0, 0, 0)), nil, "player properties of #40 dropped");
eq(F.low(ch(0x7f, 1, 2)), nil, "unknown extension packet dropped");
eq(F.low(ch(0x40, 9, 1, 2)), nil, "unknown sub-packet dropped");

print("\n3. alias: an old client with id >= 32 (here 40)");
eqb(F.alias(ch(3, 40, 1), 40), ch(3, 1, 1), "its own input is rewritten to 1");
eq(F.alias(ch(3, 5, 1), 40), nil, "another player's input dropped");
eq(F.alias(ch(2) .. string.rep("w", 24), 40), nil, "world update dropped");
eqb(F.alias(ch(17, 0, 2) .. "hi", 40), ch(17, 0, 2) .. "hi", "system chat from 0 kept");
eqb(F.alias(ch(17, 40, 2) .. "hi", 40), ch(17, 1, 2) .. "hi", "system chat naming itself rewritten");
eq(F.alias(ch(17, 5, 0) .. "hi", 40), nil, "player chat from another dropped");
eqb(F.alias(ch(17, 255, 3) .. "hi", 40), ch(17, 255, 3) .. "hi", "message from 255 kept");
eqb(F.alias(ch(16, 40, 255, 0, 5), 40), ch(16, 1, 255, 0, 5), "its own death by the server rewritten");
eq(F.alias(ch(16, 40, 3, 0, 5), 40), nil, "killed by somebody else: dropped");
eqb(F.alias(ch(18, 1, 2, 3, 4), 40), ch(18, 1, 2, 3, 4), "map start kept");
eqb(F.alias(ch(0x60, 40, 9), 40), ch(0x60, 1, 9), "damage marker on itself rewritten");
eq(F.alias(ch(0x60, 3, 9), 40), nil, "damage marker on another dropped");
eqb(F.alias(ch(0x43, 1, 3, 1, 40, 2), 40), ch(0x43, 1, 1, 2), "silent list keeps only itself, as 1");
eqb(F.alias(ch(0x72, 1, 0, 0, 0, 0, 0, 1), 40), ch(0x72, 1, 2), "flashlight bitmap: its bit moves to 1");
eqb(F.alias(ch(0x72, 1, 255, 255, 255, 255, 255, 0), 40), ch(0x72, 1, 0), "flashlight bitmap: not lit stays 0");
eq(F.alias(ch(0x7f, 1, 2), 40), nil, "unknown extension packet dropped");

print("\n4. StateData and the intel holders");
local function state(mode, flags, a, b)
	local head = ch(15, 40) .. string.rep("\1", 3) .. string.rep("\2", 6)
		.. string.rep("A", 10) .. string.rep("B", 10) .. ch(mode);
	assert(#head == 32);
	local ctf = ch(3, 4, 10, flags) .. a .. b .. string.rep("T", 12) .. string.rep("U", 12);
	return head .. ctf;
end
local held = ch(50) .. string.rep("\0", 11);
local ground = string.rep("g", 12);
local s = state(0, 3, held, ch(60) .. string.rep("\0", 11));
eq(#s, 84, "built a 84 byte StateData");
local o = F.alias(s, 40);
eqb(o:sub(2, 2), ch(1), "alias: own id rewritten to 1");
eq(o:byte(36), 0, "alias: both holders hidden: flags cleared");
eqb(o:sub(37, 48), string.rep("T", 12), "alias: intel 0 back at its own tent");
eqb(o:sub(49, 60), string.rep("U", 12), "alias: intel 1 back at its own tent");
eq(#o, 84, "alias: length kept");

local mine = state(0, 2, ch(40) .. string.rep("\0", 11), ground);
o = F.alias(mine, 40);
eq(o:byte(36), 2, "alias: the holder is itself: flag kept");
eq(o:byte(37), 1, "alias: and named as 1");

local lowstate = state(0, 3, ch(5) .. string.rep("\0", 11), ch(50) .. string.rep("\0", 11));
lowstate = lowstate:sub(1, 1) .. ch(7) .. lowstate:sub(3);
o = F.low(lowstate);
eq(o:byte(2), 7, "low: own id untouched");
eq(o:byte(36), 2, "low: a low holder stays, a high holder is hidden (bit 0 cleared)");
eq(o:byte(37), 5, "low: low holder id kept");
eqb(o:sub(49, 60), string.rep("U", 12), "low: hidden intel at its tent");

local tc = state(1, 3, ch(50) .. string.rep("\0", 11), ground);
o = F.low(tc:sub(1, 1) .. ch(7) .. tc:sub(3));
eq(o:byte(36), 3, "a non-CTF state is left alone");

print("\n5. the hooks, and the wait queue");
reset();
player_limit_max = 64;
CONNECTED[7], CONNECTED[40], CONNECTED[41], CONNECTED[9] = true, true, true, true;
SPEAKS[41], REPLIED[41] = true, true;
BOTS[9] = true;
REPLIED[7], REPLIED[40] = true, true;
mod = load();
mod.late.next.send_packet = function(pid, data) SENT[#SENT+1] = {pid, data, true}; return 1; end
mod.late.next.send_packet_unreliable = function(pid, data) SENT[#SENT+1] = {pid, data, false}; return 1; end

local function to(pid) local t = {}; for _, e in ipairs(SENT) do if (e[1] == pid) then t[#t+1] = e; end end return t; end

mod.late.send_packet(PID_BROADCAST, ch(3, 5, 7));
eq(#to(7), 1, "low client gets input of #5");
eq(#to(40), 0, "alias client does not get another player's input");
SENT = {};

mod.late.send_packet(PID_BROADCAST, ch(3, 50, 7));
eq(#to(7), 0, "low client does not get #50");
eq(#to(40), 0, "alias client does not get #50");
eq(#to(41), 1, "a 192 client does");
eq(#to(9), 1, "a bot does");
eqb(to(41)[1][2], ch(3, 50, 7), "unchanged to the 192 client");
SENT = {};

mod.late.send_packet(PID_BROADCAST, ch(3, 40, 7));
eqb(to(40)[1][2], ch(3, 1, 7), "alias client gets itself as 1");
eqb(to(41)[1][2], ch(3, 40, 7), "192 client gets 40");
SENT = {};

mod.late.send_packet_unreliable(PID_BROADCAST, ch(2) .. string.rep("w", 45 * 24));
eq(#to(7), 1, "world update to the low client");
eq(#to(7) == 1 and #to(7)[1][2] or 0, WU_MAX, "cut to 32 players");
eq(to(7)[1][3], false, "still unreliable");
eq(#to(40), 0, "none to the alias client");
eq(#to(41) == 1 and #to(41)[1][2] or 0, 1 + 45 * 24, "whole to the 192 client");

print("\n  the wait queue");
reset();
player_limit_max = 64;
CONNECTED[44] = true;
mod = load();
mod.late.next.send_packet = function(pid, data) SENT[#SENT+1] = {pid, data, true}; return 1; end
mod.late.next.send_packet_unreliable = function(pid, data) SENT[#SENT+1] = {pid, data, false}; return 1; end
mod.after.on_successful_connect(44);

mod.late.send_packet(44, ch(60, 1, 2, 3));
eq(#SENT, 1, "a packet naming nobody (ExtInfo) is sent at once");
SENT = {};
mod.late.send_packet(44, ch(12, 44, 0));
mod.late.send_packet(44, ch(3, 5, 1));
mod.late.send_packet(44, ch(3, 44, 1));
mod.late.send_packet_unreliable(44, ch(2) .. string.rep("w", 24));
mod.late.send_packet(44, ch(19, 1, 2));
eq(#SENT, 1, "player packets held, unreliable one dropped, map chunk sent");
eqb(SENT[1][2], ch(19, 1, 2), "the map chunk went");
SENT = {};

NOW = 5;
mod.after.tick();
eq(#SENT, 0, "still waiting inside the grace");

-- it turns out to speak 192
SPEAKS[44], REPLIED[44] = true, true;
NOW = 6;
mod.after.tick();
eq(#SENT, 3, "speaks 192: the queue is sent");
eqb(SENT[1][2], ch(12, 44, 0), "unchanged");
eqb(SENT[2][2], ch(3, 5, 1), "in order");
eqb(SENT[3][2], ch(3, 44, 1), "all of it");
SENT = {};
NOW = 7;
mod.after.tick();
eq(#SENT, 0, "and only once");

-- it turns out not to
reset();
player_limit_max = 64;
CONNECTED[44] = true;
mod = load();
mod.late.next.send_packet = function(pid, data) SENT[#SENT+1] = {pid, data, true}; return 1; end
mod.late.next.send_packet_unreliable = function(pid, data) SENT[#SENT+1] = {pid, data, false}; return 1; end
mod.after.on_successful_connect(44);
mod.late.send_packet(44, ch(12, 44, 0));
mod.late.send_packet(44, ch(3, 5, 1));
mod.late.send_packet(44, ch(3, 44, 1));
NOW = 11;
mod.after.tick();
eq(#SENT, 2, "grace over, no 192: the queue goes through the alias filter");
eqb(SENT[1][2], ch(12, 1, 0), "its own id as 1");
eqb(SENT[2][2], ch(3, 1, 1), "others dropped, itself kept");
SENT = {};

-- ordering: a client that answers is flushed before the next packet
reset();
player_limit_max = 64;
CONNECTED[7] = true;
mod = load();
mod.late.next.send_packet = function(pid, data) SENT[#SENT+1] = {pid, data, true}; return 1; end
mod.late.next.send_packet_unreliable = function(pid, data) SENT[#SENT+1] = {pid, data, false}; return 1; end
mod.after.on_successful_connect(7);
mod.late.send_packet(7, ch(3, 2, 1));
REPLIED[7] = true;
mod.late.send_packet(7, ch(3, 3, 1));
eq(#SENT, 2, "a send after the answer flushes the queue first");
eqb(SENT[1][2], ch(3, 2, 1), "queued one first");
eqb(SENT[2][2], ch(3, 3, 1), "then the new one");

print("\n  the queue cap");
reset();
player_limit_max = 64;
CONNECTED[7] = true;
mod = load();
mod.late.next.send_packet = function(pid, data) SENT[#SENT+1] = {pid, data, true}; return 1; end
mod.late.next.send_packet_unreliable = function(pid, data) SENT[#SENT+1] = {pid, data, false}; return 1; end
player_limit_queue_max = 3;
mod.after.on_successful_connect(7);
for i = 1, 10 do mod.late.send_packet(7, ch(3, 2, i)); end
REPLIED[7] = true;
NOW = 1;
mod.after.tick();
eq(#SENT, 3, "no more than the cap is held");

print("\n6. bots are never filtered");
reset();
player_limit_max = 64;
CONNECTED[45] = true;
BOTS[45] = true;
mod = load();
mod.late.next.send_packet = function(pid, data) SENT[#SENT+1] = {pid, data, true}; return 1; end
mod.late.next.send_packet_unreliable = function(pid, data) SENT[#SENT+1] = {pid, data, false}; return 1; end
mod.late.send_packet(45, ch(3, 50, 1));
eq(#SENT, 1, "a bot is sent packets naming high ids");
eqb(SENT[1][2], ch(3, 50, 1), "unchanged");
mod.late.send_packet_unreliable(45, ch(2) .. string.rep("w", 45 * 24));
eq(#SENT[2][2], 1 + 45 * 24, "and the whole world update");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
