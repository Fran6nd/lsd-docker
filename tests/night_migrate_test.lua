-- night_migrate_test.lua -- daytime and flashlight became night
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/night_migrate_test.lua      (from the repository root)
--
-- `lsdctl init` on a settings file from when they were two scripts: the
-- installed list names night in the place of the first of them, the two
-- sections are one with every value kept, ext_policy is left as it was
-- (it is keyed by protocol extension id) -- and what a server with only
-- one of them had is just as well served.

local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what) else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end

local function sh(cmd)
	local p = io.popen(cmd .. " 2>&1");
	local out = p:read("*a");
	p:close();
	return out;
end

local luajit = arg[-1] or "luajit";
local HOME = sh("pwd"):gsub("%s+$", "");

-- A data folder holding `extra` (old sections, and the list) after a
-- fresh server's own settings, which are then migrated.
local function migrate(scripts_from, scripts_to, extra, policy)
	local dir = sh("mktemp -d"):gsub("%s+$", "");
	local env = string.format("LSD_HOME=%q LSD_DATA=%q ", HOME, dir);
	local ctl = env .. luajit .. " image/ctl/lsdctl.lua ";
	sh(ctl .. "setup --defaults");
	if (policy) then sh(ctl .. "set ext_policy \"" .. policy .. "\""); end

	local f = io.open(dir .. "/settings", "rb");
	local text = f:read("*a");
	f:close();
	-- the list: night out, what the old server had in; its section gone
	text = text:gsub('\t"night",\n', scripts_to);
	text = text:gsub("\n# %-%-%-%- night %-%-%-%-[^\n]*\n.-\n\n", "\n\n");
	text = text:gsub("\n# %-%-%-%- night %-%-%-%-[^\n]*\n[^#]*$", "\n");
	f = io.open(dir .. "/settings", "wb");
	f:write(text .. "\n" .. extra);
	f:close();
	check(scripts_from == nil or string.find(text, scripts_from, 1, true), "(the old file is as seeded)", text);

	local out = sh(ctl .. "init");
	f = io.open(dir .. "/settings", "rb");
	local after = f:read("*a");
	f:close();
	local got = sh(ctl .. "get scripts");
	local pol = sh(ctl .. "get ext_policy");
	sh("rm -rf " .. dir);
	return after, got, pol, out;
end

print("\n1. both installed");
local after, scripts, pol = migrate('"daytime"', '\t"daytime",\n\t"flashlight",\n', [[
# ---- daytime ----  Daytime and Weather, extension
daytime_night = True
daytime_resync = 60

# ---- flashlight ----  Flashlight, extension
flashlight_red = 200
flashlight_reach = 75
]], "{48: 'recommended', 0x33: 'required'}");
check(string.find(scripts, '"night"', 1, true) and not string.find(scripts, "daytime", 1, true)
	and not string.find(scripts, '"flashlight"', 1, true), "night instead of the two", scripts);
check(string.find(scripts, '"message_types", "night", "pie_menu"', 1, true),
	"in the place they held, the rest in order", scripts);
check(not string.find(after, "---- daytime", 1, true) and not string.find(after, "---- flashlight", 1, true),
	"the old sections are gone", after);
local sect = string.match(after, "# %-%-%-%- night %-%-%-%-[^\n]*\n(.*)$") or "";
check(string.find(sect, "daytime_night = True", 1, true) and string.find(sect, "daytime_resync = 60", 1, true)
	and string.find(sect, "flashlight_red = 200", 1, true) and string.find(sect, "flashlight_reach = 75", 1, true),
	"every value is in night's section", sect);
check(string.find(pol, '51: "required"', 1, true) and string.find(pol, '48: "applied"', 1, true)
	and string.find(pol, '50: "applied"', 1, true), "ext_policy: chosen kept, the other extension given its default", pol);

print("\n2. only the flashlight installed");
after, scripts = migrate(nil, '\t"flashlight",\n', [[
# ---- flashlight ----  Flashlight, extension
flashlight_cone = 100
]]);
check(string.find(scripts, '"night"', 1, true) and not string.find(scripts, '"flashlight"', 1, true),
	"night instead", scripts);
check(string.find(after, "flashlight_cone = 100", 1, true) and not string.find(after, "---- flashlight", 1, true),
	"its value is in night's section", after);

print("\n3. already night: nothing changes");
after, scripts = migrate(nil, '\t"night",\n', "# ---- night ----  Night, extension\nflashlight_cone = 111\n");
check(string.find(after, "flashlight_cone = 111", 1, true), "night's own section stays", after);

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
