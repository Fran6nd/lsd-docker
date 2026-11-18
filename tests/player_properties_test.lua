-- player_properties_test.lua -- Player Properties and Kick Reason, stubbed
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/player_properties_test.lua      (from the repository root)
--
-- lib_player_properties and lib_kick_reason against a stubbed server:
-- the bytes of the 12-byte packet, who is told what and when, and that a
-- kick with a reason sends its message first and disconnects a tick
-- later, while a client that did not agree is kicked at once.

package.path = "catalog/extensions/player_properties/?.lua;"
	.. "catalog/extensions/kick_reason/?.lua;" .. package.path;

local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what) else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end
local function eq(got, want, what)
	check(got == want, what, string.format("got %s, want %s",
		tostring(got), tostring(want)));
end
local function hex(s)
	return (string.gsub(s, ".", function(c)
		return string.format("%02x ", string.byte(c)); end));
end

--============================ THE STUBS =============================--

MAX_PLAYERS, PID_BROADCAST, SPECTATOR = 255, 255, 256;
function init_mod()
	local function t() return {before = {}, after = {}, next = {}}; end
	local m = t();
	m.impl, m.late, m.early, m.xearly = t(), t(), t(), t();
	return m;
end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function pid_connected_table(d)
	local t = {};
	for i = 0, MAX_PLAYERS - 1 do t[i] = d; end
	return t;
end
function log() end

local P = {};        -- pid -> {team=, hp=, mag=, reserve=, score=}
local agreed = {};   -- pid -> {ext id -> true}
local sent = {};     -- {to, data}
local clock = 0;
function get_time() return clock; end
function piditer()
	local ids = {};
	for pid in pairs(P) do ids[#ids+1] = pid; end
	table.sort(ids);
	local i = 0;
	return function() i = i + 1; return ids[i]; end;
end
function is_joined(pid) return P[pid] ~= nil; end
function get_team(pid) return P[pid].team; end
function get_hp(pid) return P[pid].hp; end
function get_mag_ammo(pid) return P[pid].mag; end
function get_reserve_ammo(pid) return P[pid].reserve; end
function get_score(pid) return P[pid].score; end
function ext_supported(pid, id)
	return agreed[pid] and agreed[pid][id] and 1 or nil;
end
local registered = {};
function ext_register(name, id, version, ready) registered[id] = ready; end
function ext_unregister(id) registered[id] = nil; end
function send_packet(to, data) sent[#sent+1] = {to = to, data = data}; end
function send_chat(to, msg, type, from)
	sent[#sent+1] = {to = to, chat = msg, type = type, from = from};
end

--========================= PLAYER PROPERTIES ========================--

print("\n1. Player Properties");

local pp = require "lib_player_properties";
pp.on_load();

local pkt = player_properties_encode(3, 100, 50, 3, 10, 50, 7);
eq(#pkt, 12, "the packet is 12 bytes");
eq(hex(pkt), "40 00 03 64 32 03 0a 32 07 00 00 00 ",
	"[64][0][pid][hp][blocks][grenades][mag][reserve][LE score]");
eq(hex(player_properties_encode(1, 300, -4, 0, 0, 0, 0x01020304)),
	"40 00 01 ff 00 00 00 00 04 03 02 01 ",
	"bytes clamp rather than wrap; the score is little-endian");
eq(string.sub(player_properties_encode(0, 0, 0, 0, 0, 0, -5), 9),
	"\0\0\0\0", "a negative score clamps to 0");

P[0] = {team = 1, hp = 100, mag = 10, reserve = 50, score = 0};
P[1] = {team = 2, hp = 100, mag = 6, reserve = 48, score = 2};
P[2] = {team = SPECTATOR, hp = 100, mag = 0, reserve = 0, score = 0};
agreed[0] = {[0] = true};

sent = {};
registered[0](0);
eq(#sent, 2, "a client that agrees is told about every player on a team");

sent = {};
pp.after.tick();
eq(#sent, 2, "the first tick describes both team players");
sent = {};
pp.after.tick();
eq(#sent, 0, "nothing changed, nothing sent");

P[1].hp = 40;
pp.after.tick();
eq(#sent, 1, "one HP change, one packet");
eq(sent[1] and string.byte(sent[1].data, 3), 1, "about the player who changed");
eq(sent[1] and string.byte(sent[1].data, 4), 40, "carrying the new HP");
eq(sent[1] and sent[1].to, 0, "to the client that agreed, and no other");

sent = {};
pp.xearly.before.on_grenade(1);
pp.xearly.before.on_block_line(1, {x = 0, y = 0, z = 0}, {x = 2, y = 1, z = 0});
pp.after.tick();
eq(sent[1] and string.byte(sent[1].data, 6), 2, "a grenade thrown is one fewer");
eq(sent[1] and string.byte(sent[1].data, 5), 46, "a line of four blocks is four fewer");

sent = {};
pp.after.send_restock(1, 1);
pp.after.tick();
eq(sent[1] and string.byte(sent[1].data, 5), 50, "a restock refills blocks");
eq(sent[1] and string.byte(sent[1].data, 6), 3, "and grenades");

pp.on_unload();
eq(player_properties_encode, nil, "unloading takes the API back out");

--============================ KICK REASON ===========================--

print("\n2. Kick Reason");

local kr = require "lib_kick_reason";
kr.on_load();
local gone = {};
kr.late.next.disconnect = function(pid, reason) gone[#gone+1] = pid; end

agreed[0] = {[194] = true};
agreed[1] = nil;
sent, clock = {}, 100;

kr.late.disconnect(1, 2);
eq(#gone, 1, "a client that did not agree is kicked at once");
eq(#sent, 0, "and told nothing");

gone = {};
kr.late.disconnect(0, 2);
eq(#gone, 0, "a client that agreed is not kicked yet");
eq(sent[1] and sent[1].chat, "Kicked", "it is sent the reason");
eq(sent[1] and sent[1].type, 2, "as CHAT_SYSTEM");
eq(sent[1] and sent[1].from, 255, "from player 255");

kr.after.tick();
eq(#gone, 0, "not before the delay");
clock = clock + kick_reason_delay;
kr.after.tick();
eq(#gone, 1, "but after it");

gone, kick_reason_delay = {}, 0;
kr.late.disconnect(0, 1);
kr.after.tick();
eq(#gone, 0, "never in the tick it was asked for, even with no delay");
kr.after.tick();
eq(#gone, 1, "but the tick after");
kick_reason_delay = 0.3;

gone, sent = {}, {};
kick_reason_set(0, "Teamkilling");
kr.late.disconnect(0, 2);
eq(sent[1] and sent[1].chat, "Teamkilling", "a text a script set wins over the code");

gone, sent = {}, {};
kr.after.on_disconnect(0);
kr.late.disconnect(0, 0);
eq(#sent, 0, "code 0 is no reason, and sends none");
eq(#gone, 1, "so it disconnects at once");

kr.on_unload();
eq(kick_reason_set, nil, "unloading takes the API back out");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
