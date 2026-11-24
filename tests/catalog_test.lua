-- catalog_test.lua -- the catalog, its classes, and settings file edits
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
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

print("\n3a. extension policies: what a client without one costs");
local pl = cat:get("player_limit");
eq(pl:default_policy({player_limit_max = 32}), "applied", "32 seats: nothing asked of anyone");
eq(pl:default_policy({player_limit_max = 64}), "required", "above 32: clients without it only watch");
eq(pl:default_policy({}), "required", "player_limit's default seats are 255: required");
eq(pl:default_policy({player_limit_max = 255}), "required", "255 seats: clients without it only watch");
local night = cat:get("night");
eq(night:default_policy({daytime_night = true}, 0x33), "recommended", "night: told about the dark");
eq(night:default_policy({}, 0x33), "applied", "by day: nothing to tell");
eq(night:default_policy({daytime_night = true}, 0x32), "applied", "the flashlight is applied, night or day");
eq(night:default_policy({}), "applied", "with no id, the first extension's");
eq(#night:ext_list(), 2, "night speaks two protocol extensions");
eq(#pl:ext_list(), 1, "an ordinary extension speaks one");
eq(pl:ext_list()[1].id, pl.ext_id, "and it is its ext_id");
for _, id in ipairs({"teamplay", "damage_markers", "message_types", "pie_menu"}) do
	eq(cat:get(id):default_policy({}), "applied", id .. " is applied");
end
-- Player Limit is the one exception, and on purpose (WORK.md: 255 players
-- by default): a client that cannot hold 33 players watches, told to
-- update. Nothing else keeps a client off a team on a default server.
for _, e in ipairs(cat:of_class(C.Extension)) do
	if (e.id ~= "player_limit") then
		check(e:default_policy({}) ~= "required", e.id .. ": no client turned away on a default server");
	end
end

print("\n3a'. each gamemode's callouts make a pie a client accepts");
do
	function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
		before={}, after={}, next={on_any_packet=function() end}, early={before={},after={},next={}},
		xearly={before={},after={},next={}}}; end
	function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
	function log() end
	function pid_connected_table() return {}; end
	local pm = dofile("catalog/extensions/pie_menu/lib_pie_menu.lua").codec;
	-- pings: at most six, own keys, an English label; a pie a client takes
	local function check_pings(pings, where)
		if (type(pings) ~= "table" or #pings > 6) then return false; end
		local slices, keys = {}, {};
		for i, p in ipairs(pings) do
			if (keys[p.key] or type(p.key) ~= "string" or not string.match(p.key, "^[%w_]+$")
			    or type(p.label) ~= "table" or type(p.label.en) ~= "string") then
				return false;
			end
			keys[p.key] = true;
			slices[i] = {text = "/pingmark %h " .. p.label.en, label = p.label};
		end
		return #pings == 0 or pcall(pm.normalize_pie,
			{theme = "Mark", when = "block enemy", slices = slices}, where);
	end
	local default = dofile("catalog/libs/callouts/callouts/default.lua");
	check(#default.pings > 0 and check_pings(default.pings, "default"),
		"the default pings make a Mark pie");
	for _, g in ipairs(cat:of_class(C.Gamemode)) do
		local f = io.open("catalog/libs/callouts/callouts/" .. g.id .. ".lua");
		if (f ~= nil) then
			f:close();
			local set = dofile("catalog/libs/callouts/callouts/" .. g.id .. ".lua");
			local slices, keys, ok_keys = {}, {}, true;
			for i, c in ipairs(set.callouts) do
				slices[i] = {text = "/callout " .. c.key,
					label = c.label, tooltip = c.say};
				if (keys[c.key] or type(c.say) ~= "table" or type(c.say.en) ~= "string") then
					ok_keys = false;
				end
				keys[c.key] = true;
			end
			check(#set.callouts >= 1 and #set.callouts <= 6, g.id .. ": one to six callouts");
			check(ok_keys, g.id .. ": each callout has its own key and an English line");
			local ok, err = pcall(pm.normalize_pie,
				{theme = set.theme, when = "alive", slices = slices}, g.id);
			check(ok, g.id .. ": its pie is one a client accepts", err);
			check(check_pings(set.pings, g.id), g.id .. ": its pings make a Mark pie");
		elseif (g.id ~= "editor") then
			check(false, g.id .. " has no callouts (catalog/libs/callouts/callouts/" .. g.id .. ".lua)");
		end
	end
end

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
-- Effects break blocks only through PlayerEffect.break_blocks, which
-- asks may_break_block -- the gate a gamemode's protections join
-- (babel's platform and towers). An effect or a bot, or a library one
-- needs, that broke blocks without asking it would slip past every one
-- of them: the only code that breaks blocks itself is code that asks
-- may_break_block first (PlayerEffect.break_blocks, bot_dig_block).
do
	local FORBIDDEN = {
		{"bdestroy_block_action%s*%(", "bdestroy_block_action"},
		{"[^%w_.:]block_action%s*%(", "block_action"},
		{"[^%w_.:]block_line%s*%(", "block_line"},
		{"set_solid%s*%(", "set_solid"},
	};
	local function lua_files(dir)
		local out = {};
		for f in io.popen("find '" .. dir .. "' -name '*.lua' ! -name script.lua | sort"):lines() do
			out[#out+1] = f;
		end
		return out;
	end
	local function offence(path)
		local f = io.open(path);
		local src = f:read("*a"); f:close();
		src = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "");
		if (src:find("may_break_block%s*%(")) then
			return nil;
		end
		for _, fb in ipairs(FORBIDDEN) do
			if (("\n" .. src):find(fb[1])) then return fb[2]; end
		end
	end
	local seen = {};
	local scanned = {};
	for _, e in ipairs(cat:of_class(C.Effect)) do scanned[#scanned+1] = e; end
	for _, e in ipairs(cat:of_class(C.Bot)) do scanned[#scanned+1] = e; end
	for _, e in ipairs(scanned) do
		local dirs = {e};
		for _, d in ipairs(cat:closure({e.id})) do
			if (d:is_a(C.Library) and d.id ~= "player_effect") then dirs[#dirs+1] = d; end
		end
		for _, d in ipairs(dirs) do
			for _, path in ipairs(lua_files(d.dir)) do
				if (not seen[path]) then
					seen[path] = true;
					local bad = offence(path);
					check(bad == nil, path .. " breaks no block without asking may_break_block",
						bad and ("calls " .. bad));
				end
			end
		end
	end
	check(seen["catalog/libs/bot/lib_bot.lua"] and seen["catalog/libs/blast/lib_blast.lua"],
		"the effects' and bots' sources were read, their libraries too");
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

print("\n3c. an operator's own catalog, as on the data volume");
local both = C.open({"catalog", "tests/fixtures/local_catalog"}, reader);
check(#both.errors == 0, "a second root loads", table.concat(both.errors, "; "));
local hello = both:get("hello");
check(hello ~= nil and hello.root == "tests/fixtures/local_catalog", "a new entry comes from it");
check(hello and hello.replaces == nil, "and replaces nothing");
local vk = both:get("votekick");
eq(vk and vk.title, "Votekick (ours)", "an entry of the same id wins over the image's");
eq(vk and vk.replaces and vk.replaces.dir, "catalog/tools/votekick", "and says what it replaced");
local n = 0;
for _, e in ipairs(both.list) do if (e.id == "votekick") then n = n + 1; end end
eq(n, 1, "listed once");
local lp = both:plan({"hello", "votekick"}, "ctf");
local mods = {};
for _, m in ipairs(lp.phases.tools) do mods[m] = true; end
check(mods.hello and mods.votekick, "both plan to load");

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
local plan = cat:plan({"night", "guards", "railgun", "headless"}, "hostage");
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
before("lib_ext", "lib_night", "lib_ext before the extensions");
before("lib_shot_detect", "rifle_is_a_rail_gun", "shot detection before the railgun");
before("lib_player_effect", "rifle_is_a_rail_gun", "the PlayerEffect class before the railgun");
before("ctf", "tentspawns", "the gamemode before the spawns");
before("tentspawns", "lib_bot", "the spawns before the bots");
before("lib_bot", "hostage", "lib_bot before hostage, its rider");
before("lib_bot", "lib_headless", "lib_bot before lib_headless");
before("lib_night", "bot_standard", "the flashlight before the guards that carry it");
check(index_of(order, "lib_ext_policy") ~= nil, "ext_policy comes with any extension");

-- bots: its rider loads before the guards it installs with it
local bp = cat:plan({}, "bots");
local bo = {};
for _, p in ipairs(C.PHASES) do
	for _, m in ipairs(bp.phases[p]) do bo[#bo+1] = m; end
end
check(index_of(bo, "bot_standard") ~= nil and index_of(bo, "lib_night") ~= nil, "bots brings the guards, and night: daytime and the flashlight");
check(index_of(bo, "bots") ~= nil and index_of(bo, "bots") < index_of(bo, "bot_standard"),
	"the bots rider loads before the guards", table.concat(bo, " "));

-- bots_rewards: the bots game with every reward free, all of it brought along
local br = cat:plan({}, "bots_rewards");
local bro = {};
for _, p in ipairs(C.PHASES) do for _, m in ipairs(br.phases[p]) do bro[#bro+1] = m; end end
check(index_of(bro, "lib_rewards") and index_of(bro, "demo_reward") and index_of(bro, "bot_standard")
	and index_of(bro, "missile") and index_of(bro, "airstrike") and index_of(bro, "bots"),
	"bots_rewards brings rewards, the demo, the guards, the effects and the bots rider", table.concat(bro, " "));

-- a library left installed by another gamemode is not loaded
local function loads(plan, m)
	for _, p in ipairs(C.PHASES) do
		for _, x in ipairs(plan.phases[p]) do if (x == m) then return true; end end
	end
	return false;
end
check(loads(cat:plan({"babel_protect", "babel", "votekick"}, "babel"), "babel_protect"),
	"babel loads babel_protect");
check(loads(cat:plan({}, "babel"), "infinite_blocks"), "babel brings infinite blocks: a tower is built, not rationed");
local left = cat:plan({"babel_protect", "babel", "votekick"}, "bots");
check(not loads(left, "babel_protect") and loads(left, "votekick"),
	"switched to bots, babel's babel_protect is not loaded; installed tools are");

print("\n6. dependencies close, and an unknown gamemode is refused");
local closed = cat:closure({"esp_demo"});
local ids = {};
for _, e in ipairs(closed) do ids[e.id] = true; end
check(ids.teamplay and ids.ext and ids.ext_policy, "esp_demo pulls in teamplay, ext and ext_policy");
check(not pcall(cat.plan, cat, {}, "dd"), "dd is not a gamemode");
local p2 = cat:plan({"no_such_script"}, "ctf");
eq(#p2.missing, 1, "a missing script is reported, not fatal");

print("\n7. presets and setup without a terminal");
local fl = cat:get("night");
local quiet = {choose = function(_, _, _, d) return d; end,
	ask = function(_, _, cur) return cur; end};
local v, preset = fl:setup(quiet, {}, {preset = "night_vision", policy = "required"});
eq(preset, "night_vision", "the asked-for preset is used");
eq(v.daytime_night, true, "night vision is a night preset");
eq(v.flashlight_visibility, "self", "night vision hides other players' lights");
eq(v.flashlight_green, 255, "and is green");
v = fl:setup(quiet, {}, {preset = "disco", policy = "applied"});
eq(v.flashlight_colors, "random", "disco gives everybody a random colour");
v = fl:setup(quiet, {}, {preset = "day"});
eq(v.daytime_night, false, "day is daylight");
eq(v.flashlight_visibility, "all", "with the default beam");
eq(fl:defaults().daytime_night, false, "the default preset is day");
check(fl:preset("night") and fl:preset("night").values.daytime_night == true, "night is darkness");

-- several protocol extensions: each is asked about, each gets its entry
local asked = {};
local ui = {choose = function(_, text, _, d) asked[#asked+1] = text; return d; end,
	ask = function(_, _, cur) return cur; end};
fl:setup(ui, {}, {preset = "night"});
local titles = {};
for _, t in ipairs(asked) do if (string.find(t, "client without", 1, true)) then titles[#titles+1] = t; end end
eq(#titles, 2, "the setup asks what a missing client costs, once per extension");
check(string.find(titles[1], "Daytime and Weather", 1, true) and string.find(titles[2], "Flashlight", 1, true),
	"each question names its extension", table.concat(titles, " | "));
local store, saved = {}, nil;
local fake = {get = function(_, k) return store[k]; end, set_policy = function(_, m) saved = m; end};
fl:setup(quiet, {}, {preset = "night", policy = "required"});
fl:on_install(fake);
eq(saved[0x33], "required", "--policy sets the first");
eq(saved[0x32], "required", "and the second");
fl:setup(quiet, {}, {preset = "night"});
store.ext_policy = {[0x32] = "disabled", [7] = "applied"};
fl:on_install(fake);
eq(saved[0x32], "applied", "a policy is the entry's default unless chosen");
eq(saved[7], "applied", "another extension's is left alone");
fl:on_remove(fake);
check(saved[0x32] == nil and saved[0x33] == nil and saved[7] == "applied", "removing clears both, and only those");
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
