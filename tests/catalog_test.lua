-- catalog_test.lua -- the catalog, its classes, and settings file edits
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/catalog_test.lua      (from the repository root)
--
-- Reads the real catalog/ directory, so a manifest that does not load,
-- names an unknown field, or depends on something loading after it
-- fails here rather than on a live server.

package.path = "catalog/core/?.lua;" .. package.path;

local C = require "catalog";
local F = require "settings_format";

local failures, checks = 0, 0;

local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then
		print("  PASS " .. what);
	else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end

local function eq(got, want, what)
	check(got == want, what, string.format("got %s, want %s",
		tostring(got), tostring(want)));
end

local function index_of(list, x)
	for i, v in ipairs(list) do if (v == x) then return i; end end
end

local reader = {
	exists = function(p)
		local r = os.execute("test -e '" .. p .. "'");
		return r == 0 or r == true;
	end,
	dirs = function(p)
		local t = {};
		for n in io.popen("cd '" .. p .. "' && for d in */; do [ -d \"$d\" ] && echo \"${d%/}\"; done"):lines() do
			t[#t+1] = n;
		end
		local i = 0;
		return function() i = i + 1; return t[i]; end;
	end,
	loadfile = loadfile,
};

local cat = C.open({"catalog"}, reader);

print("\n1. every manifest loads");
check(#cat.errors == 0, "no manifest errors", table.concat(cat.errors, "; "));
check(#cat.list >= 30, "the whole catalog is read", #cat.list);

print("\n2. every entry is one category class, and ships its module");
for _, e in ipairs(cat.list) do
	local classes = 0;
	for _, c in ipairs(C.CATEGORIES) do
		if (e:is_a(c.class)) then classes = classes + 1; end
	end
	check(classes == 1 and e:is_a(C.Script), e.id .. " is a Script of one category");

	if (not e.upstream) then
		for _, m in ipairs(e:load_modules()) do
			local f = io.open(e.dir .. "/" .. m .. ".lua");
			if (f == nil) then
				-- a gamemode's base may be upstream's (hostage rides ctf)
				f = io.open("lsd/scripts/" .. m .. ".lua");
			end
			check(f ~= nil, e.id .. " ships " .. m .. ".lua");
			if (f) then f:close(); end
		end
	end
	for _, d in ipairs(e:dependencies()) do
		check(cat:find(d) ~= nil, e.id .. " depends on a real entry: " .. d);
	end
end

print("\n3. the classes are abstract where they should be");
check(not pcall(C.Script, {title = "x"}), "Script itself cannot be instantiated");
check(not pcall(C.Tool, {titel = "typo"}), "an unknown manifest field is refused");
check(not pcall(C.Tool, {title = 3}), "a mistyped manifest field is refused");
check(not pcall(C.Effect, {title = "x"}), "Effect itself cannot be instantiated");

print("\n3b. effects come in two kinds, and player effects share one class");
for _, id in ipairs({"railgun", "grenade_shotgun", "pinning_smg"}) do
	check(cat:get(id) and cat:get(id):is_a(C.PlayerEffect), id .. " is a PlayerEffect");
end
check(cat:get("the_fall") and cat:get("the_fall"):is_a(C.WorldEffect), "the_fall is a WorldEffect");
for _, e in ipairs(cat:of_class(C.Effect)) do
	check(e:is_a(C.PlayerEffect) ~= e:is_a(C.WorldEffect), e.id .. " is exactly one kind of effect");
end
for _, e in ipairs(cat:of_class(C.PlayerEffect)) do
	check(index_of(e:dependencies(), "player_effect") ~= nil,
		e.id .. " pulls in lib_player_effect by its category");
	for _, m in ipairs(e:load_modules()) do
		local f = io.open(e.dir .. "/" .. m .. ".lua");
		local src = f and f:read("*a") or "";
		if (f) then f:close(); end
		check(src:find("PlayerEffect%s*{") and not src:find("init_mod%s*%("),
			m .. " is built on PlayerEffect, not init_mod");
		check(not src:find("mod%.on_load") and not src:find("mod%.on_unload")
			and not src:find("mod%.after%.on_join"),
			m .. " leaves on_load, on_unload and on_join to the class");
		check(src:find('name = "' .. e.id .. '"', 1, true),
			m .. " is named by its catalog id, " .. e.id);
	end
end
-- what a gamemode requires is how it plays with an effect; a manifest
-- for a mode that does exists only here
local mode = C.Gamemode({id = "rail_ctf", base = "ctf", requires = {"railgun"}});
cat.entries.rail_ctf = mode; cat.list[#cat.list+1] = mode;
local rp = cat:plan({}, "rail_ctf");
local rmods = {};
for _, m in ipairs(rp.phases.libs) do rmods[m] = "libs"; end
for _, m in ipairs(rp.phases.effects) do rmods[m] = "effects"; end
eq(rmods.rifle_is_a_rail_gun, "effects", "a gamemode's required effect loads, in the effects phase");
eq(rmods.lib_player_effect, "libs", "and brings lib_player_effect, as a library");
eq(rmods.lib_shot_detect, "libs", "and its own requirements");
cat.entries.rail_ctf = nil; table.remove(cat.list);

print("\n4. every gamemode, with every listed script, has a load order");
local all = {};
for _, e in ipairs(cat.list) do
	if (e.listed and not e:is_a(C.Gamemode)) then all[#all+1] = e.id; end
end
for _, g in ipairs(cat:of_class(C.Gamemode)) do
	local ok, err = pcall(cat.plan, cat, all, g.id);
	check(ok, g.id .. " plans with everything installed", err);
end

print("\n5. the order honours the constraints");
local plan = cat:plan({"flashlight", "guards", "railgun", "headless"}, "hostage");
local order = {};
for _, p in ipairs(C.PHASES) do
	if (p == "spawns") then order[#order+1] = "tentspawns"; end
	for _, m in ipairs(plan.phases[p]) do order[#order+1] = m; end
end
local function before(a, b, what)
	local ia, ib = index_of(order, a), index_of(order, b);
	check(ia ~= nil and ib ~= nil and ia < ib, what,
		table.concat(order, " "));
end
before("lib_ext", "lib_flashlight", "lib_ext before the extensions");
before("lib_shot_detect", "rifle_is_a_rail_gun", "shot detection before the railgun");
before("lib_player_effect", "rifle_is_a_rail_gun", "the PlayerEffect class before the railgun");
before("ctf", "tentspawns", "the gamemode before the spawns");
before("tentspawns", "lib_bot", "the spawns before the bots");
before("lib_bot", "hostage", "lib_bot before hostage, its rider");
before("lib_bot", "lib_headless", "lib_bot before lib_headless");
before("lib_flashlight", "bot_standard", "the flashlight before the guards that carry it");
check(index_of(order, "lib_ext_policy") ~= nil, "ext_policy comes with any extension");

print("\n6. dependencies close, and an unknown gamemode is refused");
local closed = cat:closure({"esp_demo"});
local ids = {};
for _, e in ipairs(closed) do ids[e.id] = true; end
check(ids.teamplay and ids.ext and ids.ext_policy, "esp_demo pulls in teamplay, ext and ext_policy");
check(not pcall(cat.plan, cat, {}, "dd"), "dd is not a gamemode");
local p2 = cat:plan({"no_such_script"}, "ctf");
eq(#p2.missing, 1, "a missing script is reported, not fatal");

print("\n7. presets and setup without a terminal");
local fl = cat:get("flashlight");
local quiet = {choose = function(_, _, _, d) return d; end,
	ask = function(_, _, cur) return cur; end};
local v, preset = fl:setup(quiet, {}, {preset = "night_vision", policy = "required"});
eq(preset, "night_vision", "the asked-for preset is used");
eq(v.flashlight_visibility, "self", "night vision hides other players' lights");
eq(v.flashlight_green, 255, "and is green");
v = fl:setup(quiet, {}, {preset = "disco", policy = "applied"});
eq(v.flashlight_colors, "random", "disco gives everybody a random colour");
check(not pcall(fl.setup, fl, quiet, {}, {preset = "nope"}), "an unknown preset is refused");

print("\n8. editing the settings file");
local text = [[
# header
name = "x"

# ---- flashlight ----  Flashlight
flashlight_red = 1
]];
local t2 = F.set(text, "port", 1234);
local a, b = string.find(t2, "port = 1234", 1, true), string.find(t2, "# ---- flashlight", 1, true);
check(a ~= nil and a < b, "a server setting goes above the sections", t2);
local t3 = F.set(t2, "flashlight_red", 9);
check(string.find(t3, "flashlight_red = 9", 1, true) and not string.find(t3, "= 1\n", 1, true),
	"an existing key is replaced in place", t3);
local t4 = F.set(t3, "motd", {"one, with a comma", "two"});
eq(F.parse(t4).motd[1], "one, with a comma", "a list round-trips through the file");
local t5 = F.remove_section(t4, "flashlight");
check(not string.find(t5, "flashlight", 1, true), "a section is removed whole", t5);
local t6 = F.add_section(t5, "votekick", "Vote kick", {"votekick_ratio = 0.6"});
eq(F.parse(t6).votekick_ratio, 0.6, "and one is added");
check(not string.find(t6, "\n\n\n", 1, true), "never two blank lines running", t6);
eq(F.parse(F.set("", "s", 'quote " and \\ and\nnewline')).s,
	'quote " and \\ and\nnewline', "awkward strings round-trip");
local m = F.parse(F.set("", "p", {[0x32] = "required", [48] = "applied"},
	{notes = {[0x32] = "Flashlight"}})).p;
eq(m[0x32], "required", "a map with notes round-trips");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
