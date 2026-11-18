-- settings_format_test.lua -- the settings file parser, against fixtures
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/settings_format_test.lua      (from the repository root)
--
-- The parser is the part of a config system that has to be boring, and
-- it only stays boring if it is checked. Where a case exists because a
-- bug reached a live server, the comment says so.

package.path = "catalog/core/?.lua;" .. package.path;
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

local function parse(text)
	local warnings = {};
	local v = F.parse(text, function(n, msg)
		warnings[#warnings+1] = n .. ": " .. msg;
	end);
	return v, warnings;
end

print("\n1. scalars");
local v = parse([[
name = "a server"
other = 'single quoted'
flag_on = True
flag_off = False
flag_word = off
zero = 0
count = 300
hexy = 0x33
nothing = None
]]);
eq(v.name, "a server", "a double-quoted string");
eq(v.other, "single quoted", "a single-quoted string");
eq(v.flag_on, true, "True is true");
eq(v.flag_off, false, "False is false");
eq(v.flag_word, false, '"off" is false, not a truthy string');
eq(v.zero, 0, "0 is the number 0: guard_count = 0 is a count");
eq(v.count, 300, "a number");
eq(v.hexy, 0x33, "a hex number");
eq(v.nothing, nil, "None is unset");

print("\n2. quotes that contain awkward characters");
v = parse([[
name = "Fran6nd's Hallway At Night"
tagged = "running [LSd]."
hashed = "Server #1"
semi = "a; b"
]]);
-- lib_pyscrape's parse_str stops at the first quote of either kind
eq(v.name, "Fran6nd's Hallway At Night", "an apostrophe inside double quotes");
eq(v.tagged, "running [LSd].", "brackets inside a string do not unbalance it");
eq(v.hashed, "Server #1", "a # inside a string is not a comment");
eq(v.semi, "a; b", "nor is a ;");

print("\n3. lists");
v = parse([[
tips = [
	"Flat map, no cover, damage numbers on. Sight your guns in.",
	"Use /kill to die.",
]
one = ['only']
]]);
-- THE BUG: list items were split on the commas inside the strings
eq(#v.tips, 2, "two items, not one per comma");
eq(v.tips[1], "Flat map, no cover, damage numbers on. Sight your guns in.",
	"the commas inside an item are part of it");
eq(#v.one, 1, "a one-item list");

print("\n4. maps, tuples");
v = parse([[
ext_policy = {
	0x33: 'required',      # Daytime and Weather
	  48: 'recommended',   # Teamplay, pings, north
}
fog = (128, 232, 255)
]]);
eq(v.ext_policy[0x33], "required", "a hex key");
eq(v.ext_policy[48], "recommended", "a decimal key, its comment stripped");
eq(parse("p = {0: 'applied', 0x00: 'x'}\n").p[0] ~= nil, true,
	"extension id 0 is a key, not false");
eq(v.fog.g, 232, "a three-tuple is a colour");

print("\n5. escapes");
v = parse([[
two_lines = "first\nsecond"
quoted = "she said \"no\""
slashed = "C:\\path"
unknown = "keep \d verbatim"
awkward = ["a\"b, still one item", "second"]
]]);
eq(v.two_lines, "first\nsecond", "\\n is a newline");
eq(v.quoted, 'she said "no"', "an escaped quote does not end the string");
eq(v.slashed, "C:\\path", "\\\\ is one backslash");
eq(v.unknown, "keep \\d verbatim", "an unknown escape is left alone");
eq(#v.awkward, 2, "an escaped quote does not end a list item early");

print("\n6. a value spanning lines, then more");
v = parse([[
motd = [
	"line one",     # a comment inside an open value
	"line (two",
]
after = 5
]]);
eq(#v.motd, 2, "the value closes on its own bracket");
eq(v.motd[2], "line (two", "a bracket inside a string does not keep it open");
eq(v.after, 5, "and parsing carries on after it");

print("\n7. mistakes are reported, not swallowed");
local w;
v, w = parse([[
good = "fine"
broken = "unterminated
not an assignment
]]);
eq(v.good, "fine", "a good setting beside a bad one still applies");
eq(v.broken, nil, "the bad one is ignored");
eq(#w, 2, "and both bad lines are reported with their line numbers");

print("\n8. what is emitted reads back the same");
for _, x in ipairs({"plain", "it's", 'q"uote', "a\nb", 3, 0.5, true, false,
	{"x", "y, z"}, {[0x32] = "required"}, {r = 1, g = 2, b = 3}}) do
	local back = F.parse(F.assignment("k", x)).k;
	check(F.emit(back) == F.emit(x), "round trip: " .. F.emit(x));
end

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
