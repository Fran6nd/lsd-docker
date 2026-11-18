-- flashlight_test.lua -- what each viewer is told, under each visibility
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/flashlight_test.lua      (from the repository root)
--
-- lib_flashlight against a stubbed server: three connected players on
-- two teams, every packet it sends captured. The spec requires Light
-- and Light State to tell every client every light; hiding a light is
-- done with a per-viewer Light Config of Reach 0 and Cone 0.

package.path = "lsd/scripts/?.lua;" .. package.path;

local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what) else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end

-- the stubbed server
local PLAYERS = {0, 1, 2};
local TEAM = {[0] = 1, [1] = 1, [2] = 2};
local sent, ready;

local function setup(visibility)
	sent = {};
	for k in pairs(package.loaded) do
		if (k == "lib_flashlight") then package.loaded[k] = nil; end
	end
	MAX_PLAYERS = 255; PID_BROADCAST = 255;
	flashlight_visibility = visibility;
	flashlight_colors = nil; flashlight_send_default = nil;
	function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
		before={}, after={}, next={}, early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
	function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
	function log() end
	function pid_connected_table(d) return setmetatable({}, {__index = function() return d; end}); end
	function piditer() local i = 0; return function() i = i + 1; return PLAYERS[i]; end; end
	function send_packet(pid, data) sent[#sent+1] = {to = pid, data = data}; end
	function ext_supported() return 1; end
	function ext_register(_, _, _, on_ready) ready = on_ready; end
	function get_team(pid) return TEAM[pid]; end
	function get_time() return 0; end
	local mod = dofile("catalog/extensions/flashlight/lib_flashlight.lua");
	mod.on_load();
	return mod;
end

-- The Light Config viewer was last sent for target: {reach, cone, ...}.
local function config(viewer, target)
	local got;
	for _, p in ipairs(sent) do
		local b = {string.byte(p.data, 1, -1)};
		if (p.to == viewer and b[1] == 0x72 and b[2] == 2 and b[3] == target) then
			got = {reach = b[4], cone = b[5], r = b[6], g = b[7], b = b[8]};
		end
	end
	return got;
end

local function state_to(viewer)
	local got;
	for _, p in ipairs(sent) do
		local b = {string.byte(p.data, 1, -1)};
		if (p.to == viewer and b[1] == 0x72 and b[2] == 1) then got = b[3]; end
	end
	return got;
end

print("\n1. visibility all: the default beam, nothing hidden");
setup("all");
flashlight_set(2, true);
sent = {};
ready(1);
local d = config(1, 255);
check(d ~= nil and d.reach == 60, "the default beam goes to id 255");
check(config(1, 2) == nil, "and no per-player config is needed");
check(state_to(1) == 4, "Light State says #2 is lit", state_to(1));

print("\n2. visibility self (night vision)");
setup("self");
flashlight_set(0, true); flashlight_set(2, true);
sent = {};
ready(1);
d = config(1, 255);
check(d ~= nil and d.reach == 0 and d.cone == 0, "the viewer's default beam gives no light");
check(config(1, 0).reach == 0 and config(1, 2).reach == 0, "every other player is named dark");
check(config(1, 1).reach > 0, "the viewer's own beam is real");
check(state_to(1) == 5, "Light State still tells every light, as the spec requires", state_to(1));
sent = {};
flashlight_set(2, false);
check(#sent == 3, "a Light is relayed to every client", #sent);

print("\n3. visibility team");
local m = setup("team");
TEAM[2] = 2;
sent = {};
ready(0);
check(config(0, 1).reach > 0, "a teammate's beam is real");
check(config(0, 2).reach == 0, "an enemy's beam gives no light");
TEAM[2] = 1;
sent = {};
m.after.spawn_player(2);   -- a team change arrives as a spawn
check(config(0, 2) ~= nil and config(0, 2).reach > 0,
	"after #2 joins the team, #0 is sent #2's real beam");
check(config(2, 0) ~= nil and config(2, 0).reach > 0,
	"and #2 is sent #0's");
TEAM[2] = 2;

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
