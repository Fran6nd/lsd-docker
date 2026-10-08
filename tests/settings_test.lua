-- settings_test.lua -- the settings file parser, against fixtures
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/settings_test.lua
--
-- Runs on the host with no server: lib_settings needs four things from
-- LSd (init_mod, getcfg, log and lib_pyscrape) and they are stubbed
-- below, so the module under test is the real file rather than a copy
-- of its logic.
--
-- WHY THIS EXISTS. Two bugs reached four live servers before anybody
-- noticed, and both were in the parser:
--
--   * list items were split on every comma, quoted or not, so
--     "One flat plain, 512 by 512, and nothing to hide behind."
--     became three fragments, two with an unterminated quote. Every
--     motd and tip with a comma in it was quietly wrong.
--   * a list given to a setting whose module wants text was assigned
--     as a table, and the module read its first line only.
--
-- Neither was found by reading, and neither would have survived a test
-- like this one. The parser is the part of a config system that has to
-- be boring, and the only way it stays boring is if it is checked.
--
-- Each case states the input and what it should mean. Where a case
-- exists because of a real bug, the comment says so.

--============================ LSd STUBS =============================--

local logged = {};

function log(fmt, ...)
	logged[#logged+1] = string.format(fmt, ...);
end

function init_mod()
	return {
		impl   = {before={}, after={}, next={}},
		late   = {before={}, after={}, next={}},
		          before={}, after={}, next={} ,
		early  = {before={}, after={}, next={}},
		xearly = {before={}, after={}, next={}}
	};
end

-- core.lua's: fills a global only when it is nil, which is the whole
-- mechanism the settings file relies on.
function getcfg(key, default)
	if (_G[key] == nil) then
		_G[key] = default;
	end
end

package.path = "lsd/scripts/?.lua;" .. package.path;

--============================== HARNESS =============================--

local failures, checks = 0, 0;

local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then
		print(string.format("  PASS %s", what));
	else
		failures = failures + 1;
		print(string.format("  FAIL %s%s", what,
			detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end

local function eq(got, want, what)
	check(got == want, what,
		string.format("got %s, want %s", tostring(got), tostring(want)));
end

-- Run the module over a fixture and hand back what it put in the
-- globals. Each case gets a clean slate: the globals it sets, the log,
-- and lib_settings itself, so a value from one case cannot satisfy the
-- next.
local tmp = os.tmpname();
local lib;

local function load_settings(text, keys)
	for _, k in ipairs(keys or {}) do _G[k] = nil; end
	logged = {};

	local f = assert(io.open(tmp, "w"));
	f:write(text);
	f:close();

	settings_file = tmp;
	package.loaded["lib_settings"] = nil;
	lib = dofile("scripts.local/lib_settings.lua");
	lib.on_load();
end

local function logged_matching(pat)
	for _, line in ipairs(logged) do
		if (string.find(line, pat, 1, true)) then return line; end
	end
	return nil;
end

--=============================== CASES ==============================--

print("\n1. scalars");
load_settings([[
name = "a server"
other = 'single quoted'
flag_on = True
flag_off = False
flag_word = off
count = 300
hexy = 0x33
]], {"name","other","flag_on","flag_off","flag_word","count","hexy"});
eq(name, "a server", "a double-quoted string");
eq(other, "single quoted", "a single-quoted string");
eq(flag_on, true, "True is true");
eq(flag_off, false, "False is false");
eq(flag_word, false, '"off" is false, not a truthy string');
eq(count, 300, "a number");
eq(hexy, 0x33, "a hex number");

print("\n2. quotes that contain awkward characters");
load_settings([[
name = "Fran6nd's Hallway At Night"
tagged = "running [LSd]."
hashed = "Server #1"
semi = "a; b"
]], {"name","tagged","hashed","semi"});
-- lib_pyscrape's own parse_str stops at the first quote of either kind
-- and would give "Fran6nd" here.
eq(name, "Fran6nd's Hallway At Night", "an apostrophe inside double quotes");
eq(tagged, "running [LSd].", "brackets inside a string do not unbalance it");
eq(hashed, "Server #1", "a # inside a string is not a comment");
eq(semi, "a; b", "nor is a ;");

print("\n3. lists");
load_settings([[
tips = [
	"Flat map, no cover, damage numbers on. Sight your guns in.",
	"Damage numbers need a client that speaks the extension.",
	"Use /kill to die.",
]
one = ['only']
]], {"tips","one"});
-- THE BUG: these were split on the commas inside the strings.
eq(type(tips), "table", "a list is a table");
eq(#tips, 3, "three items, not one per comma");
eq(tips[1], "Flat map, no cover, damage numbers on. Sight your guns in.",
	"the commas inside an item are part of it");
eq(tips[3], "Use /kill to die.", "and the trailing comma adds no item");
eq(#one, 1, "a one-item list");

print("\n4. maps");
load_settings([[
ext_policy = {
	0x33: 'required',      # Daytime and Weather -- the dark itself
	0x32: 'required',      # Flashlight
	  48: 'recommended',   # Teamplay, pings, north
}
]], {"ext_policy"});
eq(type(ext_policy), "table", "a map is a table");
eq(ext_policy[0x33], "required", "a hex key");
eq(ext_policy[48], "recommended", "a decimal key");
eq(ext_policy[0x32], "required", "and a per-entry comment is stripped");

print("\n5. escapes");
load_settings([[
two_lines = "first\nsecond"
tabbed = "a\tb"
quoted = "she said \"no\""
slashed = "C:\\path"
unknown = "keep \d verbatim"
]], {"two_lines","tabbed","quoted","slashed","unknown"});
eq(two_lines, "first\nsecond", "\\n is a newline");
eq(tabbed, "a\tb", "\\t is a tab");
eq(quoted, 'she said "no"', "an escaped quote does not end the string");
eq(slashed, "C:\\path", "\\\\ is one backslash");
eq(unknown, "keep \\d verbatim", "an unknown escape is left alone");

print("\n6. escapes inside lists, where the splitter also has to see them");
load_settings([[
awkward = ["a\"b, still one item", "second"]
]], {"awkward"});
eq(#awkward, 2, "an escaped quote does not end an item early");
eq(awkward[1], 'a"b, still one item', "and the comma inside it still does not split");

print("\n7. a value spanning lines, with comments on them");
load_settings([[
motd = [
	"line one",     # a comment inside an open value
	"line two",
]
after = 5
]], {"motd","after"});
eq(#motd, 2, "the value closes on its own bracket");
eq(after, 5, "and parsing carries on after it");

print("\n8. mistakes are reported, not swallowed");
load_settings([[
good = "fine"
broken = "unterminated
]], {"good","broken"});
eq(good, "fine", "a good setting beside a bad one still applies");
eq(broken, nil, "the bad one is ignored");
check(logged_matching("unterminated quote") ~= nil,
	"and the log says which line and why",
	table.concat(logged, " | "));

print("\n9. a list where the module wants text");
-- THE OTHER BUG: motd.lua splits one string on newlines, so a list was
-- assigned whole and only its first line was ever seen.
load_settings([[
motd = ["one", "two", "three"]
]], {"motd"});
getcfg("motd", "a default string");
eq(type(motd), "string", "it becomes a string");
eq(motd, "one\ntwo\nthree", "joined with newlines, in order");

print("\n10. and a list where the module wants a list is untouched");
load_settings([[
tips = ["one", "two"]
]], {"tips"});
getcfg("tips", {});
eq(type(tips), "table", "still a table");
eq(#tips, 2, "with both items");

print("\n11. a value of the wrong type is reported");
load_settings([[
player_limit_max = "32"
]], {"player_limit_max"});
getcfg("player_limit_max", 255);
check(logged_matching("expects a number") ~= nil,
	"a string where a number belongs is named in the log",
	table.concat(logged, " | "));
eq(player_limit_max, "32", "...and used as written rather than replaced");

print("\n12. a reload shapes a list the way the first read did");
-- THE THIRD BUG, which reached a live server: settings_reload assigned
-- the parsed table straight to motd, and motd.lua's gmatch threw on
-- every join and every tick until the next restart.
load_settings([[
motd = ["one", "two"]
tips = ["a", "b"]
]], {"motd","tips"});
getcfg("motd", "a default string");
getcfg("tips", {});
local f = assert(io.open(tmp, "w"));
f:write('motd = ["one", "two", "three"]\ntips = ["a", "b", "c"]\n');
f:close();
settings_reload();
eq(motd, "one\ntwo\nthree", "a reloaded motd is still one string");
eq(type(tips), "table", "and a reloaded list setting is still a list");

print("\n13. so does a hot load of lib_settings itself");
-- The fresh copy never saw motd.lua's getcfg and motd.lua will not run
-- it again, so the global's current type is all there is to go on.
load_settings('motd = ["x", "y"]\n', {});
eq(motd, "x\ny", "a motd already a string stays one");

os.remove(tmp);

--============================== RESULT ==============================--

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
