-- edit_mode_test.lua -- Block Batch parsing, and who is sent what
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/edit_mode_test.lua      (from the repository root)
--
-- lib_edit_mode against a stubbed server: a small map, three or four
-- connected clients, the send chain captured. The bytes are checked
-- against the spec (extensions/edit-mode.md); the rest is the rule that
-- a client which did not negotiate is never sent an edit it would apply
-- differently.

local bit = require("bit");

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

local function le32(v)
	return string.char(bit.band(v, 255), bit.band(bit.rshift(v, 8), 255),
		bit.band(bit.rshift(v, 16), 255), bit.band(bit.rshift(v, 24), 255));
end
local function batch(pid, action, blocks)
	local s = string.char(0x76, 1, pid, action);
	for _, b in ipairs(blocks) do s = s .. le32(b[1]) .. le32(b[2]) .. le32(b[3]); end
	return s;
end
local function baction(pid, type, x, y, z)
	return string.char(13, pid, type) .. le32(x) .. le32(y) .. le32(z);
end

--========================== THE STUB SERVER ==========================--

local PLAYERS, NEG, REPLIED, TEAM, JOINED, ALIVE;
local map, sent, now, ready, mod, switched, said;

local function key(p) return p.x .. "," .. p.y .. "," .. p.z; end

local function setup()
	package.loaded["lib_edit_mode"] = nil;
	map, sent, now, switched, said = {}, {}, 100, {}, {};
	PLAYERS = {0, 1, 2};
	NEG = {[0] = true, [1] = true, [2] = false};      -- #2 is a vanilla client
	REPLIED = {[0] = true, [1] = true, [2] = true};
	TEAM = {[0] = 1, [1] = 2, [2] = 1};
	JOINED = {[0] = true, [1] = true, [2] = true};
	ALIVE = {[0] = true, [1] = true, [2] = true};

	MAX_PLAYERS = 32; PID_BROADCAST = 0x20000000; SPECTATOR = 256;
	QUIRK_OS_BACTION_CULL = 6;
	for _, k in ipairs({"edit_mode_batch_max", "edit_mode_legacy",
	    "edit_mode_grace", "edit_mode_grace_joined", "edit_mode_queue_max"}) do
		_G[k] = nil;
	end

	function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
		before={}, after={}, next={}, early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
	function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
	function log() end
	function pid_connected_table(d) return setmetatable({}, {__index = function() return d; end}); end
	function piditer(b)
		if (b ~= PID_BROADCAST) then
			local done = false;
			return function() if (done) then return nil; end done = true; return b; end;
		end
		local i = 0;
		return function() i = i + 1; return PLAYERS[i]; end;
	end
	function ext_supported(pid) return NEG[pid] and 1 or nil; end
	function ext_replied(pid) return REPLIED[pid]; end
	function ext_register(_, id, _, on_ready) ready = on_ready; end
	function get_time() return now; end
	function get_ipaddr() return 1; end
	function is_connected() return true; end
	function is_joined(pid) return JOINED[pid]; end
	function is_alive(pid) return ALIVE[pid]; end
	function get_team(pid) return TEAM[pid]; end
	function get_gun() return 0; end
	function get_name(pid) return "p" .. pid; end
	function get_anon_pid() return 32; end
	function has_quirk() return true; end
	function server_msg(pid, m) said[#said+1] = {to = pid, text = m}; end
	function disconnect(pid) said[#said+1] = {to = pid, text = "KICK"}; end
	function on_switch(pid, team) switched[#switched+1] = {pid = pid, team = team}; TEAM[pid] = team; end
	function on_color_change() end
	function is_solid(p) return map[key(p)] == true; end

	-- the send chain: global send_packet is the top, our late hook, then
	-- the "C" end that records what reaches each client
	function send_packet(pid, data) return mod.late.send_packet(pid, data); end
	local function wire(pid, data)
		for i in piditer(pid) do sent[#sent+1] = {to = i, data = data}; end
		return 0;
	end
	function send_block_action(pid, p, type, from) send_packet(pid, baction(from, type, p.x, p.y, p.z)); end

	-- the engine's block functions, as far as they matter here
	function block_action_rm(p, type, from)
		if (not map[key(p)]) then return 0; end
		map[key(p)] = nil;
		send_block_action(PID_BROADCAST, p, type, from);
		return bit.bor(bit.lshift(type, 30), 0x20000000, 1);
	end
	function block_action(p, type, from)
		if (type == 0) then
			map[key(p)] = true;
			send_block_action(PID_BROADCAST, p, 0, from);
		else
			block_action_cull(p, block_action_rm(p, type, from));
			finish_cull();
		end
	end
	function block_action_cull(p, m) return mod.block_action_cull(p, m); end
	function finish_cull() end

	mod = dofile("catalog/extensions/edit_mode/lib_edit_mode.lua");
	mod.late.next.send_packet = wire;
	mod.next.block_action_cull = function() CULLED = true; end
	mod.next.on_any_packet = function() return 1; end   -- the engine refuses
	mod.next.on_switch = function(pid, team) on_switch(pid, team); end
	mod.next.on_join = function() end
	mod.on_load();
	return mod;
end

local function to(pid, id)
	local n = 0;
	for _, s in ipairs(sent) do
		if (s.to == pid and (id == nil or string.byte(s.data, 1) == id)) then n = n + 1; end
	end
	return n;
end

--============================== BYTES ================================--

print("\n1. Block Batch, as the spec draws it");
local P = setup().pure;
local b = P.parse_batch(batch(7, 0, {{1, 2, 3}, {511, 511, 62}}), 100);
check(b ~= nil and b.action == 0 and #b.blocks == 2, "a build of two blocks parses");
eq(b.blocks[2].z, 62, "z 62 is a block an edit-mode player may name");
b = P.parse_batch(batch(7, 1, {{0, 0, 63}, {-1, 0, 0}, {512, 0, 0}, {5, 5, 5}}), 100);
eq(#b.blocks, 1, "z 63, negative and out-of-map blocks are dropped, not the batch");
eq(select(2, P.parse_batch(batch(7, 2, {{1, 1, 1}}), 100)), "reserved action",
	"action 2 is reserved: the whole batch goes");
eq(select(2, P.parse_batch(batch(7, 0, {}), 100)), "empty", "no blocks: dropped");
eq(select(2, P.parse_batch(batch(7, 0, {{1, 1, 1}, {2, 2, 2}}), 1)), "too big",
	"more than the server accepts: dropped");
eq(select(2, P.parse_batch(batch(7, 0, {{1, 1, 1}}) .. "x", 100)), "malformed",
	"a ragged length is not a batch");
local enc = P.encode_batch(3, 1, {{x = 1, y = 2, z = 3}});
eq(#enc, 4 + 12, "4 + 12 n bytes");
eq(enc, batch(3, 1, {{1, 2, 3}}), "LE ints, x then y then z");
eq(P.i32(le32(-5), 1), -5, "a negative LE int reads back negative");

print("\n2. a batch is judged a block at a time against the map");
local m = {};
local kept = P.filter_batch(0, {{x=1,y=1,z=1}, {x=1,y=1,z=1}, {x=2,y=2,z=2}},
	function(p) return m[key(p)] == true; end,
	function(p) return p.x ~= 2; end,
	function(p) m[key(p)] = true; return true; end);
eq(#kept, 1, "a block named twice is built once; a vetoed block is dropped");

--=========================== EDIT PACKETS ============================--

print("\n3. what edit mode lifts, and what it keeps");
local solid = function(p) return p.z == 40; end
check(P.edit_packet_ok(0, baction(0, 0, 10, 10, 62), solid), "build at z 62, in mid-air");
check(not P.edit_packet_ok(0, baction(0, 0, 10, 10, 63), solid), "never z 63");
check(not P.edit_packet_ok(0, baction(1, 0, 10, 10, 5), solid), "only under the sender's own id");
check(not P.edit_packet_ok(0, baction(0, 0, 10, 10, 40), solid), "no build onto a solid block");
check(not P.edit_packet_ok(0, baction(0, 3, 10, 10, 40), solid), "no grenade action");
check(P.edit_packet_ok(0, baction(0, 2, 10, 10, 40), solid), "a spade on a block");
local line = string.char(14, 0) .. le32(0)..le32(0)..le32(0) .. le32(511)..le32(511)..le32(61);
check(P.edit_packet_ok(0, line, solid), "a Block Line of any length");
check(P.edit_packet_ok(0, string.char(8, 0, 1, 2, 3), solid), "a spectator's Set Colour");

--============================ THE SERVER =============================--

print("\n4. Edit Mode goes to every negotiated client, never to a vanilla one");
setup();
sent = {};
check(edit_mode_set(0, true), "edit mode on for #0");
check(to(0, 0x76) == 1 and to(1, 0x76) == 1, "#0 and #1 are told");
eq(to(2, 0x76), 0, "#2 is not");
local d = sent[1].data;
eq(d, string.char(0x76, 0, 0, 1), "[0x76][0][pid][state]");
check(edit_mode_any() and edit_mode_get(0), "edit_mode_any and edit_mode_get agree");
check(switched[1] ~= nil and switched[1].pid == 2 and switched[1].team == SPECTATOR,
	"the vanilla client is made a spectator at once");
check(said[1] ~= nil and said[1].to == 2, "and told why");
eq(select(2, edit_mode_set(2, true)), "unsupported", "a vanilla client cannot be put in edit mode");

print("\n5. while anybody edits, a vanilla client gets no Block Action");
sent = {};
mod.late.send_packet(PID_BROADCAST, baction(1, 0, 3, 3, 3));
check(to(0, 13) == 1 and to(1, 13) == 1, "negotiated clients get it");
eq(to(2, 13), 0, "the vanilla one does not");
mod.after.tick();
now = now + 1;
edit_mode_set(0, false);
mod.after.tick();
sent = {};
mod.late.send_packet(PID_BROADCAST, baction(1, 0, 4, 4, 4));
eq(to(2, 13), 0, "having missed one, it stays out after edit mode ends");
mod.after.send_map_start(PID_BROADCAST, 0);
now = now + 1;
mod.after.tick();
check(switched[#switched].pid == 2 and switched[#switched].team == 1,
	"a Map Start lets it back, onto its old team");
sent = {};
mod.late.send_packet(PID_BROADCAST, baction(1, 0, 4, 4, 4));
eq(to(2, 13), 1, "and it is sent blocks again");

print("\n6. no edits while it sat out: back in play when edit mode ends");
setup();
edit_mode_set(0, true);
now = now + 1;
edit_mode_set(0, false);
mod.after.tick();
check(switched[#switched].pid == 2 and switched[#switched].team == 1, "released onto its team");

print("\n7. a Block Batch: applied once, sent once, to negotiated clients only");
setup();
edit_mode_set(1, true);
sent = {};
map[key({x=5,y=5,z=5})] = true;
eq(mod.on_any_packet(1, batch(1, 0, {{1,1,1}, {5,5,5}, {2,2,62}, {3,3,63}})), 0,
	"the batch is consumed");
check(map["1,1,1"] and map["2,2,62"] and not map["3,3,63"], "built, z 62 included, z 63 not");
eq(to(0, 13) + to(1, 13) + to(2, 13), 0, "no per-block Block Action went out");
eq(to(0, 0x76), 1, "#0 gets one batch");
eq(to(1, 0x76), 1, "the sender gets it too");
eq(to(2, 0x76), 0, "the vanilla client never gets a batch");
local got;
for _, s in ipairs(sent) do if (s.to == 0) then got = s.data; end end
eq(got, batch(1, 0, {{1,1,1}, {2,2,62}}), "only the blocks the map took, under the sender's id");
sent = {};
mod.on_any_packet(0, batch(0, 1, {{1,1,1}}));
eq(#sent, 0, "a batch from a player not in edit mode is dropped");
check(map["1,1,1"], "and changes nothing");
mod.on_any_packet(1, batch(1, 1, {{1,1,1}, {9,9,9}}));
check(not map["1,1,1"], "a destroy batch removes its blocks");
for _, s in ipairs(sent) do if (s.to == 0) then got = s.data; end end
eq(got, batch(1, 1, {{1,1,1}}), "air is not destroyed twice");

print("\n8. nothing falls while anybody edits");
setup();
CULLED = false;
block_action_cull({x=1,y=1,z=1}, bit.bor(bit.lshift(1, 30), 0x20000000, 1));
check(CULLED, "without edit mode the engine culls");
edit_mode_set(0, true);
CULLED = false;
block_action_cull({x=1,y=1,z=1}, bit.bor(bit.lshift(1, 30), 0x20000000, 1));
check(not CULLED, "with it, nothing is culled");

print("\n9. an edit-mode player's packets the engine would refuse");
eq(mod.on_any_packet(0, baction(0, 0, 50, 50, 62)), 0, "a mid-air z 62 build is sane");
eq(mod.on_any_packet(1, baction(1, 0, 50, 50, 30)), 1, "not for a player out of edit mode");
ALIVE[0] = false; TEAM[0] = SPECTATOR;
eq(mod.on_any_packet(0, string.char(8, 0, 9, 9, 9)), 0, "a spectator's Set Colour, relayed");
eq(mod.on_any_packet(0, baction(0, 0, 50, 50, 63)), 1, "z 63 is still refused");

print("\n10. a spade covering z 62");
setup();
edit_mode_set(0, true);
map["7,7,61"] = true; map["7,7,62"] = true;
sent = {};
mod.next.block_action = function() error("should not reach the engine"); end
mod.block_action({x=7,y=7,z=61}, 2, 0);
check(not map["7,7,61"] and not map["7,7,62"], "both blocks go, z 62 included");
eq(to(1, 13), 1, "one Block Action goes out");
for _, s in ipairs(sent) do if (s.to == 1) then got = s.data; end end
eq(got, baction(0, 2, 7, 7, 61), "and it is the spade itself");

print("\n11. a client still connecting is held, not dropped");
setup();
PLAYERS[4] = 3; NEG[3] = false; REPLIED[3] = false; JOINED[3] = false; ALIVE[3] = false;
mod.after.on_successful_connect(3);
edit_mode_set(0, true);
sent = {};
mod.late.send_packet(PID_BROADCAST, baction(0, 0, 3, 3, 3));
mod.on_any_packet(0, batch(0, 0, {{8,8,8}}));
eq(to(3), 0, "#3 is sent nothing yet");
NEG[3] = true; REPLIED[3] = true;
ready(3);
local seq = {};
for _, s in ipairs(sent) do if (s.to == 3) then seq[#seq+1] = string.byte(s.data, 1) .. ":" .. string.byte(s.data, 2); end end
eq(table.concat(seq, " "), "118:0 13:0 118:1",
	"on negotiating: the Edit Mode, the Block Action and the batch, in order");

setup();
PLAYERS[4] = 3; NEG[3] = false; REPLIED[3] = false; JOINED[3] = false; ALIVE[3] = false;
mod.after.on_successful_connect(3);
edit_mode_set(0, true);
mod.late.send_packet(PID_BROADCAST, baction(0, 0, 3, 3, 3));
REPLIED[3] = true;   -- answered, without Edit Mode
sent = {};
mod.after.tick();
eq(to(3, 13), 0, "a client that turns out not to speak it never gets the held block");
edit_mode_set(0, false);
now = now + 1;
mod.after.tick();
sent = {};
mod.late.send_packet(PID_BROADCAST, baction(1, 0, 4, 4, 4));
eq(to(3, 13), 0, "and has missed it, so stays out");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
