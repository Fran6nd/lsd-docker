-- player_properties_restock_test.lua -- a bot's restock refills what
-- Player Properties says of it
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/player_properties_restock_test.lua   (from the repository root)
--
-- lib_player_properties keeps every player's blocks and grenades itself
-- (the core has no getter for them) and tells the clients that agreed. A
-- bot's stock is told like anyone's. Its refill must not depend on a
-- packet sent TO the bot: none is ever made (lib_bot drops the core's
-- send_restock to a bot before any hook below it), so a bot restocked by
-- the core's restock -- a tent, babel's refill -- stayed as low as its
-- last build in every client's view.
--
-- Under upstream's core.lua (the real chains) with the real lib_bot.

package.path = "catalog/extensions/player_properties/?.lua;catalog/libs/bot/?.lua;" .. package.path;

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

--============================ THE STUBS =============================--

MAX_PLAYERS, SPECTATOR = 255, 256;
local SET = 0x20000000;
PID_BROADCAST = SET;
function PID_BROADCAST_EXCEPT(p) return 2 * SET + p; end
function PID_BROADCAST_TEAM(t) return 3 * SET + t - 1; end

local CONNECTED, JOINED, TEAM, PEER = {}, {}, {}, {};
function piditer(set)
	local list = {};
	for i = 0, MAX_PLAYERS - 1 do
		if (set == i or (set == PID_BROADCAST and CONNECTED[i])) then list[#list + 1] = i; end
	end
	local k = 0;
	return function() k = k + 1; return list[k]; end
end
function is_connected(pid) return CONNECTED[pid] == true; end
function is_joined(pid) return JOINED[pid] == true; end
function is_alive(pid) return JOINED[pid] == true; end
function get_team(pid) return TEAM[pid] or 1; end
function get_time() return 0; end
function get_hp() return 100; end
function get_mag_ammo() return 10; end
function get_reserve_ammo() return 50; end
function get_score() return 0; end
function get_inputs() return 0; end
function pid_connected_table(d)
	local t = {};
	for i = 0, MAX_PLAYERS - 1 do t[i] = d; end
	return t;
end
-- the person (pid 0) agreed to Player Properties
function ext_supported(pid, id) return PEER[pid] and 1 or nil; end
function ext_register() end
function ext_unregister() end
function masterlist_set_players() end
function masterlist_set_max_players() end
package.preload["lib_bulk_destroy"] = function() return true; end

local told = {};     -- the Player Properties packets the person was sent
server = {};
function server.assign_new_pid()
	for i = 0, 253 do if (not CONNECTED[i]) then return i; end end
	return MAX_PLAYERS;
end
function server.get_effective_max_players() return 255; end
function server.on_successful_connect(pid) CONNECTED[pid] = true; end
function server.on_join(pid, team) JOINED[pid], TEAM[pid] = true, team; end
function server.on_tool_change() end
function server.on_color_change() end
function server.spawn_player() end
function server.on_disconnect(pid) CONNECTED[pid], JOINED[pid] = nil, nil; end
-- main.c restock: the stock is full, and the player is told (send_restock(pid, pid))
function server.restock(pid) send_restock(pid, pid); end
function server.send_restock() end
function server.send_packet(pid, data)
	if (PEER[pid] and data:byte(1) == 64) then told[#told + 1] = data; end
	return 0;
end
function server.on_block_action() end
function server.tick() end

dofile("tests/support/core_env.lua").load();
function log() end

local function load_mod(name)
	local m = require(name);
	m.name = name;
	register(m);
	return m;
end

--============================= THE GAME =============================--

print("\n1. a bot builds, then is restocked by the core");
PEER[0] = true;
on_successful_connect(0);
on_join(0, 1, 0, "alice");

load_mod("lib_player_properties");
load_mod("lib_bot");
local bot = bot_create{team = 2, name = "bot"};
check(bot ~= nil, "the bot is in");

on_block_action(bot, {x = 1, y = 1, z = 1}, 0);   -- a block built: 49
on_block_action(bot, {x = 1, y = 2, z = 1}, 0);   -- 48
eq(select(1, player_properties_get_stock(bot)), 48, "two blocks built: 48 left");

restock(bot);
eq(select(1, player_properties_get_stock(bot)), 50, "restocked: 50 blocks again");
eq(select(2, player_properties_get_stock(bot)), 3, "and 3 grenades");

told = {};
tick();
local last;
for _, p in ipairs(told) do if (p:byte(3) == bot) then last = p; end end
eq(last and last:byte(5), 50, "and the person is told 50");

print("\n2. a person, refilled behind the hooks (infinite_blocks: server.restock)");
on_block_action(0, {x = 2, y = 1, z = 1}, 0);
eq(select(1, player_properties_get_stock(0)), 49, "one block built: 49");
server.restock(0);
eq(select(1, player_properties_get_stock(0)), 50, "refilled: 50");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
