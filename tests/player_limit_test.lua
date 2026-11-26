-- player_limit_test.lua -- seats, and what an outdated client is sent
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
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
local TEAM = {};
-- as main.c's pid_matches, over the connected ids below MAX_PLAYERS
-- (lua.c do_piditer): a fake pid (255 and up, under the set flags)
-- matches nobody, so it is never iterated
local function pid_matches(set, pid)
	local flags, data = math.floor(set / 0x20000000), set % 0x20000000;
	if (flags == 1) then return CONNECTED[pid] == true; end
	if (flags == 2) then return CONNECTED[pid] == true and pid ~= data; end
	if (flags == 3) then return CONNECTED[pid] == true and TEAM[pid] == data; end
	if (flags == 4) then
		return pid ~= math.floor(data / 256) and CONNECTED[pid] == true and TEAM[pid] ~= data % 256;
	end
	return set == pid;
end
function piditer(set)
	local list = {};
	for i = 0, MAX_PLAYERS - 1 do
		if (pid_matches(set, i)) then list[#list+1] = i; end
	end
	local n = 0;
	return function() n = n + 1; return list[n]; end
end
function bot_is_bot(pid) return BOTS[pid] == true; end
function is_connected(pid) return CONNECTED[pid] == true; end
-- lib_bot's people_in: piditer without the bots
function people_in(set)
	local it = piditer(set);
	return function()
		local i = it();
		while (i ~= nil and BOTS[i]) do i = it(); end
		return i;
	end
end
function get_ipaddr(pid) return BOTS[pid] and 0 or 1; end
function ext_supported(pid, id) return SPEAKS[pid] and id == 192 and 1 or nil; end
function ext_replied(pid) return REPLIED[pid] == true; end
function ext_register() end

local SENT = {};
local function reset()
	SENT = {};
	CONNECTED, BOTS, SPEAKS, REPLIED, TEAM = {}, {}, {}, {}, {};
	NOW = 0;
	player_limit_max = 64;
end
local function load()
	package.loaded.lib_player_limit = nil;
	local max = player_limit_max;
	player_limit_queue_max = nil;
	local mod = dofile("catalog/extensions/player_limit/lib_player_limit.lua");
	player_limit_max = max;
	mod.late.next.send_packet = function(pid, data) SENT[#SENT+1] = {pid, data, true}; return 1; end
	mod.late.next.send_packet_unreliable = function(pid, data) SENT[#SENT+1] = {pid, data, false}; return 1; end
	mod.on_load();    -- as register() does, with whoever is connected
	return mod;
end
local function ch(...) return string.char(...); end

local mod = load();
local F = mod.filter;

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

print("\n2. outdated, own id below 32 (here 7): itself and nobody else");
eqb(F.outdated(ch(3, 7, 0, 0), 7), ch(3, 7, 0, 0), "its own input kept, as itself");
eq(F.outdated(ch(3, 5, 0, 0), 7), nil, "input of #5 dropped: another player, low or not");
eq(F.outdated(ch(3, 40, 0, 0), 7), nil, "input of #40 dropped");
eq(F.outdated(ch(9, 3, 0, 0, 2) .. "x", 7), nil, "existing player #3 dropped");
eq(F.outdated(ch(12, 50, 0, 0) .. "x", 7), nil, "create player #50 dropped");
eqb(F.outdated(ch(12, 7, 0, 255) .. "x", 7), ch(12, 7, 0, 255) .. "x", "its own create player (spectator) kept");
eqb(F.outdated(ch(17, 255, 3) .. "hi", 7), ch(17, 255, 3) .. "hi", "message from 255 kept");
eqb(F.outdated(ch(17, 0, 2) .. "hi", 7), ch(17, 0, 2) .. "hi", "system chat from 0 kept");
eqb(F.outdated(ch(17, 40, 2) .. "hi", 7), ch(17, 0, 2) .. "hi", "system chat from #40 kept, said by 0");
eq(F.outdated(ch(17, 5, 0) .. "hi", 7), nil, "player chat from #5 dropped");
eq(F.outdated(ch(17, 33, 0) .. "hi", 7), nil, "player chat from #33 dropped");
eq(F.outdated(ch(16, 3, 4, 0, 5), 7), nil, "kill feed between others dropped");
eq(F.outdated(ch(16, 3, 7, 0, 5), 7), nil, "a kill it made of somebody else dropped");
eqb(F.outdated(ch(16, 7, 255, 0, 5), 7), ch(16, 7, 255, 0, 5), "its own death by the server kept");
eq(F.outdated(ch(2) .. string.rep("w", 10 * 24), 7), nil, "world update dropped, even a short one");
eq(F.outdated(ch(20, 40), 7), nil, "player left #40 dropped");
eq(F.outdated(ch(13, 3, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0), 7), nil, "block action by #3 dropped");
eqb(F.outdated(ch(18, 1, 2, 3, 4), 7), ch(18, 1, 2, 3, 4), "map start names nobody: kept");
eqb(F.outdated(ch(19, 9, 9, 9), 7), ch(19, 9, 9, 9), "map chunk kept");
eqb(F.outdated(ch(27, 0, 1, 2, 3), 7), ch(27, 0, 1, 2, 3), "fog kept");
eqb(F.outdated(ch(0x60, 7, 20), 7), ch(0x60, 7, 20), "damage marker on itself kept");
eq(F.outdated(ch(0x60, 3, 20), 7), nil, "damage marker on #3 dropped");
eq(F.outdated(ch(0x72, 0, 45, 1), 7), nil, "flashlight light of #45 dropped");
eqb(F.outdated(ch(0x72, 2, 255, 1, 2, 3, 4, 5, 6), 7), ch(0x72, 2, 255, 1, 2, 3, 4, 5, 6), "flashlight config for 255 kept");
eqb(F.outdated(ch(0x72, 1, 255, 255, 255, 255, 255, 255), 7), ch(0x72, 1, 128), "flashlight bitmap: only its own bit, in place");
eqb(F.outdated(ch(0x72, 1, 0, 0, 0, 0, 0, 0), 7), ch(0x72, 1, 0), "flashlight bitmap: not lit stays 0");
eq(F.outdated(ch(0x70, 2, 60, 0, 0), 7), nil, "teamplay mark on #60 dropped");
eqb(F.outdated(ch(0x70, 0, 1, 0, 0), 7), ch(0x70, 0, 1, 0, 0), "teamplay config names nobody: kept");
eqb(F.outdated(ch(0x71, 7), 7), ch(0x71, 7), "pie menu kept");
eqb(F.outdated(ch(0x73, 7), 7), ch(0x73, 7), "daytime kept");
eq(F.outdated(ch(0x76, 0, 70, 1), 7), nil, "edit mode of #70 dropped");
eqb(F.outdated(ch(0x43, 1, 3, 1, 7, 1, 5, 2), 7), ch(0x43, 1, 7, 1), "silent list keeps only itself");
eq(F.outdated(ch(0x43, 1, 40, 1), 7), nil, "silent list with nothing left dropped");
eq(F.outdated(ch(0x40, 0, 40, 1, 1, 1, 1, 1, 0, 0, 0, 0), 7), nil, "player properties of #40 dropped");
eq(F.outdated(ch(0x7f, 1, 2), 7), nil, "unknown extension packet dropped");
eq(F.outdated(ch(0x40, 9, 1, 2), 7), nil, "unknown sub-packet dropped");

-- every packet a 0.75 server sends that names a player, from every id:
-- none ever reaches an outdated client naming an id of 32 or more
local worst = 0;
for _, real in ipairs({0, 7, 31, 32, 40, 254}) do
	for pkt = 0, 127 do
		for _, who in ipairs({0, 5, 31, 32, 99, 200, 254}) do
			local out = F.outdated(ch(pkt, who, who, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), real);
			local ids = out and F.ids_in(out);
			for _, e in ipairs(ids or {}) do
				if (e.id ~= 255 and e.id > worst) then worst = e.id; end
			end
			if (out and pkt == 2) then worst = 999; end
		end
	end
end
check(worst < 32, "no packet of any kind, to any outdated client, names an id of 32 or more", worst);

print("\n3. outdated, own id 32 or more (here 40): itself as 1");
eqb(F.outdated(ch(3, 40, 1), 40), ch(3, 1, 1), "its own input is rewritten to 1");
eq(F.outdated(ch(3, 5, 1), 40), nil, "another player's input dropped");
eq(F.outdated(ch(3, 1, 1), 40), nil, "the real #1's input dropped: there is one 1, itself");
eq(F.outdated(ch(2) .. string.rep("w", 24), 40), nil, "world update dropped");
eqb(F.outdated(ch(17, 0, 2) .. "hi", 40), ch(17, 0, 2) .. "hi", "system chat from 0 kept");
eqb(F.outdated(ch(17, 40, 2) .. "hi", 40), ch(17, 1, 2) .. "hi", "system chat naming itself rewritten");
eq(F.outdated(ch(17, 5, 0) .. "hi", 40), nil, "player chat from another dropped");
eqb(F.outdated(ch(17, 255, 3) .. "hi", 40), ch(17, 255, 3) .. "hi", "message from 255 kept");
eqb(F.outdated(ch(16, 40, 255, 0, 5), 40), ch(16, 1, 255, 0, 5), "its own death by the server rewritten");
eq(F.outdated(ch(16, 40, 3, 0, 5), 40), nil, "killed by somebody else: dropped");
eqb(F.outdated(ch(18, 1, 2, 3, 4), 40), ch(18, 1, 2, 3, 4), "map start kept");
eqb(F.outdated(ch(0x60, 40, 9), 40), ch(0x60, 1, 9), "damage marker on itself rewritten");
eq(F.outdated(ch(0x60, 3, 9), 40), nil, "damage marker on another dropped");
eqb(F.outdated(ch(0x43, 1, 3, 1, 40, 2), 40), ch(0x43, 1, 1, 2), "silent list keeps only itself, as 1");
eqb(F.outdated(ch(0x72, 1, 0, 0, 0, 0, 0, 1), 40), ch(0x72, 1, 2), "flashlight bitmap: its bit moves to 1");
eqb(F.outdated(ch(0x72, 1, 255, 255, 255, 255, 255, 0), 40), ch(0x72, 1, 0), "flashlight bitmap: not lit stays 0");
eq(F.outdated(ch(0x7f, 1, 2), 40), nil, "unknown extension packet dropped");

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
local o = F.outdated(s, 40);
eqb(o:sub(2, 2), ch(1), "own id rewritten to 1");
eq(o:byte(36), 0, "both holders hidden: flags cleared");
eqb(o:sub(37, 48), string.rep("T", 12), "intel 0 back at its own tent");
eqb(o:sub(49, 60), string.rep("U", 12), "intel 1 back at its own tent");
eq(#o, 84, "length kept");

local mine = state(0, 2, ch(40) .. string.rep("\0", 11), ground);
o = F.outdated(mine, 40);
eq(o:byte(36), 2, "the holder is itself: flag kept");
eq(o:byte(37), 1, "and named as 1");

local lowstate = state(0, 3, ch(5) .. string.rep("\0", 11), ch(50) .. string.rep("\0", 11));
lowstate = lowstate:sub(1, 1) .. ch(7) .. lowstate:sub(3);
o = F.outdated(lowstate, 7);
eq(o:byte(2), 7, "own id below 32 untouched");
eq(o:byte(36), 0, "a low holder is somebody else too: hidden");
eqb(o:sub(37, 48), string.rep("T", 12), "its intel at its tent");

local tc = state(1, 3, ch(50) .. string.rep("\0", 11), ground);
o = F.outdated(tc:sub(1, 1) .. ch(7) .. tc:sub(3), 7);
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
eq(#to(7), 0, "outdated #7 does not get input of #5");
eq(#to(40), 0, "outdated #40 does not get another player's input");
eq(#to(41), 1, "a 192 client does");
SENT = {};

mod.late.send_packet(PID_BROADCAST, ch(3, 50, 7));
eq(#to(7), 0, "outdated #7 does not get #50");
eq(#to(40), 0, "outdated #40 does not get #50");
eq(#to(41), 1, "a 192 client does");
eq(#to(9), 0, "a bot is sent nothing: it has no client");
eqb(to(41)[1][2], ch(3, 50, 7), "unchanged to the 192 client");
SENT = {};

mod.late.send_packet(PID_BROADCAST, ch(3, 40, 7));
eqb(to(40)[1][2], ch(3, 1, 7), "outdated #40 gets itself as 1");
eqb(to(41)[1][2], ch(3, 40, 7), "192 client gets 40");
SENT = {};

mod.late.send_packet_unreliable(PID_BROADCAST, ch(2) .. string.rep("w", 45 * 24));
eq(#to(7), 0, "no world update to outdated #7");
eq(#to(40), 0, "none to outdated #40");
eq(#to(41) == 1 and #to(41)[1][2] or 0, 1 + 45 * 24, "whole to the 192 client");
SENT = {};

mod.late.send_packet(PID_BROADCAST, ch(17, 0, 2) .. "Your client is outdated");
eq(#to(7), 1, "the system line reaches outdated #7");
eq(#to(40), 1, "and outdated #40");

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
eq(#SENT, 2, "grace over, no 192: the queue goes through the outdated filter");
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
REPLIED[7], SPEAKS[7] = true, true;
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
REPLIED[7], SPEAKS[7] = true, true;
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

print("\n7. seats: 255 by default, the floor, withholding");
reset();
player_limit_max = nil;
local REG = {};
local DISABLED = false;
function ext_register(name, id, version, ready, title, floor) REG = {id = id, title = title, floor = floor}; end
function ext_is_disabled(id) return DISABLED and id == 192; end
package.loaded.lib_player_limit = nil;
mod = dofile("catalog/extensions/player_limit/lib_player_limit.lua");
mod.late.next.send_packet = function(pid, data) SENT[#SENT+1] = {pid, data, true}; return 1; end
mod.late.next.send_packet_unreliable = function(pid, data) SENT[#SENT+1] = {pid, data, false}; return 1; end
mod.on_load();
eq(player_limit_max, 255, "player_limit_max defaults to 255");
eq(mod.get_effective_max_players(), 255, "every id: 0 to 254");
eq(REG.id, 192, "registered as extension 192");
eq(REG.floor and REG.floor(), "required", "required above 32 seats, whatever the policy");
player_limit_max = 300;
eq(mod.get_effective_max_players(), 255, "clamped to 255");
player_limit_max = 0;
eq(mod.get_effective_max_players(), 1, "and to 1");
player_limit_max = 32;
eq(mod.get_effective_max_players(), 32, "lowered by the operator: 32");
eq(REG.floor(), nil, "at 32 nothing is asked of anyone");
player_limit_max = 255;
DISABLED = true;
eq(mod.get_effective_max_players(), 32, "withheld (disabled): 32 seats");
eq(REG.floor(), nil, "and no floor: disabled stays disabled");
CONNECTED[40] = true;
SENT = {};
mod.late.send_packet(PID_BROADCAST, ch(3, 40, 7));
eqb(SENT[1] and SENT[1][2], ch(3, 40, 7), "withheld: nothing filtered");
DISABLED = false;
ext_is_disabled = nil;

print("\n8. one clock: lib_ext_policy's, when it is there");
reset();
player_limit_max = 255;
CONNECTED[44] = true;
local DECIDED = false;
function ext_policy_decided(pid) return DECIDED; end
mod = load();
mod.late.next.send_packet = function(pid, data) SENT[#SENT+1] = {pid, data, true}; return 1; end
mod.late.next.send_packet_unreliable = function(pid, data) SENT[#SENT+1] = {pid, data, false}; return 1; end
mod.after.on_successful_connect(44);
mod.late.send_packet(44, ch(15, 44) .. string.rep("s", 82));
mod.late.send_packet(44, ch(9, 3, 0) .. "x");
NOW = 60;
mod.after.tick();
eq(#SENT, 0, "long past its own fallback, still held: ext_policy has not decided");
DECIDED = true;
NOW = 61;
mod.after.tick();
eq(#SENT, 1, "decided without 192: what names only itself is sent");
eq(SENT[1] and SENT[1][2]:byte(2), 1, "its StateData, as player 1");
ext_policy_decided = nil;

print("\n9. not a seat: the console, a fake pid, the broadcast sets");
reset();
player_limit_max = 255;
CONNECTED[3], CONNECTED[7], CONNECTED[40], CONNECTED[41] = true, true, true, true;
TEAM[3], TEAM[7], TEAM[40], TEAM[41] = 0, 1, 0, 1;
REPLIED[7], REPLIED[40] = true, true;
SPEAKS[3], SPEAKS[41], REPLIED[3], REPLIED[41] = true, true, true, true;
mod = load();
mod.late.next.send_packet = function(pid, data) SENT[#SENT+1] = {pid, data, true}; return 1; end
mod.late.next.send_packet_unreliable = function(pid, data) SENT[#SENT+1] = {pid, data, false}; return 1; end
NOW = 100;
for _, fake in ipairs({255, 256, 0x1fffffff}) do
	SENT = {};
	mod.late.send_packet(fake, ch(17, 0, 2) .. "door placed");
	eq(#SENT, 1, string.format("to %d (console, fake pid): sent once", fake));
	eq(SENT[1] and SENT[1][1], fake, "addressed to it, down the chain");
	eqb(SENT[1] and SENT[1][2], ch(17, 0, 2) .. "door placed", "untouched");
	SENT = {};
	mod.late.send_packet_unreliable(fake, ch(3, 40, 1));
	eq(#SENT, 1, string.format("to %d unreliable, naming #40: untouched too", fake));
end
local function got() local t = {}; for _, e in ipairs(SENT) do t[e[1]] = (t[e[1]] or 0) + 1; end return t; end
SENT = {};
mod.late.send_packet(0x60000000 + 0, ch(3, 3, 1));        -- PID_BROADCAST_TEAM(0)
local g = got();
check(g[3] == 1 and g[40] == nil and g[7] == nil and g[41] == nil,
	"team 0: the 192 client #3 gets it, outdated #40 is not shown #3");
SENT = {};
mod.late.send_packet(0x40000000 + 3, ch(17, 0, 2) .. "x");   -- PID_BROADCAST_EXCEPT(3)
g = got();
check(g[3] == nil and g[7] == 1 and g[40] == 1 and g[41] == 1, "all but #3, each once");
SENT = {};
mod.late.send_packet(0x80000000 + 41 * 256 + 0, ch(17, 0, 2) .. "x");   -- EXCEPT_TEAM_AND_PLAYER(0, 41)
g = got();
check(g[7] == 1 and g[41] == nil and g[3] == nil and g[40] == nil, "except team 0 and #41: only #7");

print("\n10. the anon pid is a seat, never 255");
reset();
player_limit_max = 255;
mod = load();
local CORE_ANON = 255;
mod.next.get_anon_pid = function() return CORE_ANON; end
eq(mod.get_anon_pid(), 254, "the core says 255 (just past 255 seats): the highest free seat instead");
CONNECTED[254], CONNECTED[253] = true, true;
eq(mod.get_anon_pid(), 252, "the highest free one");
for i = 0, 254 do CONNECTED[i] = true; end
eq(mod.get_anon_pid(), 255, "none free at all: the core's answer stands");
CORE_ANON = 32;
eq(mod.get_anon_pid(), 32, "at 32 seats the core's own (32) stands");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
