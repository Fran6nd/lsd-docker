-- night_test.lua -- lib_night: what each viewer is told, under each
-- visibility; the sky; what the bot engine is told
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/night_test.lua      (from the repository root)
--
-- lib_night against a stubbed server: three connected players on
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
local sent, ready, readies;

local function setup(visibility, before_load)
	sent = {};
	readies = {};
	botlink_set = nil;
	MAX_PLAYERS = 255; PID_BROADCAST = 0x20000000;   -- PID_SET_FLAG(1), as state.h
	flashlight_visibility = visibility;
	flashlight_colors = nil; flashlight_send_default = nil;
	flashlight_cone = nil; flashlight_reach = nil; night_far = nil;
	daytime_night = nil;
	function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
		before={}, after={}, next={}, early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
	function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
	function log() end
	function pid_connected_table(d) return setmetatable({}, {__index = function() return d; end}); end
	-- as lua.c's piditer: a broadcast reaches the connected, a pid only itself
	function piditer(pid)
		local list = {};
		for _, p in ipairs(PLAYERS) do
			if (pid == PID_BROADCAST or pid == p) then list[#list+1] = p; end
		end
		local i = 0;
		return function() i = i + 1; return list[i]; end;
	end
	function send_packet(pid, data) sent[#sent+1] = {to = pid, data = data}; end
	function ext_supported() return 1; end
	function ext_register(_, id, _, on_ready) readies[id] = on_ready; end
	function ext_unregister(id) readies[id] = nil; end
	function get_fog() return {r = 10, g = 20, b = 30}; end
	function send_fog() end
	function get_team(pid) return TEAM[pid]; end
	function get_time() return 0; end
	if (before_load) then before_load(); end
	local mod = dofile("catalog/extensions/night/lib_night.lua");
	mod.on_load();
	ready = readies[0x32];
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

print("\n4. a private beam (night vision) under visibility all");
setup("all");
sent = {};
flashlight_private(0, {reach = 70, cone = 120, color = {r = 40, g = 255, b = 64}});
check(config(0, 0) ~= nil and config(0, 0).g == 255 and config(0, 0).reach == 70,
	"its carrier is sent the green beam");
check(config(1, 0).reach == 0 and config(2, 0).reach == 0,
	"everybody else is told it is dark");
sent = {};
ready(2);
check(config(2, 0) ~= nil and config(2, 0).reach == 0,
	"a client negotiating later is told it is dark too");
check(flashlight_get_private(0).reach == 70, "flashlight_get_private answers it");
sent = {};
flashlight_private(0, nil);
check(config(1, 0) ~= nil and config(1, 0).reach == 60,
	"ended, the others get the ordinary beam back");
check(config(0, 0).reach == 60 and flashlight_get_private(0) == nil,
	"and so does its carrier");

print("\n5. both extensions, one file");
local m5 = setup("all");
check(readies[0x32] ~= nil and readies[0x33] ~= nil, "both 0x32 and 0x33 are registered, each with its ready callback");
sent = {};
readies[0x33](1);
local sky = {string.byte(sent[#sent].data, 1, -1)};
check(sent[#sent].to == 1 and sky[1] == 0x73 and sky[2] == 0 and sky[3] == 208 and sky[4] == 2,
	"the Sky says day (720 minutes) to the client that negotiated");
daytime_set_night(true);
sky = {string.byte(sent[#sent].data, 1, -1)};
check(sky[1] == 0x73 and sky[3] == 0 and sky[4] == 0 and daytime_is_night() and daytime_daylight() == 0,
	"daytime_set_night switches it and tells everybody");
check(m5.on_any_packet(0, string.char(0x73, 0, 0, 0)) == 0, "a client's 0x73 is swallowed");
check(m5.on_any_packet(0, string.char(0x72, 1, 0)) == 0, "a client's Light State (0x72 sub 1) is swallowed");
local passed;
m5.next.on_any_packet = function() passed = true; return 7; end
check(m5.on_any_packet(0, string.char(0x10)) == 7 and passed, "other packets go down the chain");
check(m5.after.tick ~= nil and m5.after.finish_map_load ~= nil, "the hooks are merged, one each");
flashlight_set(0, true);
m5.after.finish_map_load();
check(flashlight_get(0) == false, "a map change puts every light out (flashlight's half of finish_map_load)");
m5.after.tick();
m5.on_unload();
check(readies[0x32] == nil and readies[0x33] == nil, "unloaded, both extensions are unregistered");
check(flashlight_set == nil and daytime_is_night == nil and flashlight_get_private == nil
	and daytime_announce == nil, "and every global of both is gone");

print("\n6. what the bot engine is told");
local told, order;
local function link()
	told, order = {}, {};
	botlink_set = function(k, v) told[k] = v; order[#order+1] = k; end
end
local mb = setup("all");
check(botlink_set == nil, "no botlink: nothing sent, no error (load)");
mb.after.tick();
check(next(told or {}) == nil, "no botlink: nothing sent, no error (tick)");
link();
mb.after.tick();
check(told["night.sight"] == "1", "night.sight is 1");
check(told["night.cone"] == "90" and told["night.reach"] == "60", "the beam's cone and reach, the defaults");
check(told["night.far"] == "192", "night.far is 1.5 x 128");
local tree = told["extra.night.tree"];
check(tree ~= nil and string.sub(tree, 1, 13) == "pick noise=0\n"
	and string.find(tree, "\toption none night_vision x10\n\t\tdo lamp off\n", 1, true)
	and string.find(tree, "\toption none hit_in_dark x10\n\t\tdo lamp on\n", 1, true)
	and string.find(tree, "\toption stealth night\n\t\tdo lamp off\n", 1, true)
	and string.find(tree, "\toption none night x1.2\n\t\tdo lamp on\n", 1, true),
	"the lamp behaviour, tab-indented", tree);
local n = #order;
mb.after.tick();
check(#order == n, "unchanged, nothing is sent again");
flashlight_cone = 120; flashlight_reach = 80;
mb.after.tick();
check(told["night.cone"] == "120" and told["night.reach"] == "80" and #order == n + 2,
	"a changed cone and reach are sent again, and only those", #order - n);
night_far = 150;
mb.after.tick();
check(told["night.far"] == "150", "night_far says otherwise");
-- botlink reloaded under it: a new botlink_set
link();
mb.after.tick();
check(told["night.sight"] == "1" and told["night.cone"] == "120" and told["extra.night.tree"] == tree,
	"a botlink that appears (or is reloaded) is sent everything");
mb.on_unload();
check(told["extra.night.tree"] == "" and told["night.sight"] == "0", "on unload the engine is told to forget it");

-- botlink loaded before this: sent at load (after: at the next tick, above)
told = {};
setup("all", function() botlink_set = function(k, v) told[k] = v; end; end);
check(told["night.sight"] == "1" and told["night.cone"] == "90", "botlink there already at load: sent at load");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
