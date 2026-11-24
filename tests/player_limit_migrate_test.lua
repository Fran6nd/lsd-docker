-- player_limit_migrate_test.lua -- 32 seats by default became 255
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/player_limit_migrate_test.lua      (from the repository root)
--
-- `lsdctl init` on a settings file an older setup wrote: the seats it
-- wrote by itself (32, or the 254 before it, under its own question)
-- become 255 and Player Limit's policy follows (applied -> required); a
-- number chosen by hand stays, and so does a policy chosen by hand; and
-- once migrated, a 32 set afterwards is never taken for the old default.

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

local ASK32 = "# How many players may the server seat (above 32, clients without Player Limit can only watch)?";
local ASK254 = "# How many players may the server seat (above 32, an old client may mishandle high player ids)?";

-- A fresh server's settings with Player Limit's section as an older
-- setup wrote it (`ask`, `seats`) and its policy `policy`; then `init`,
-- and `after` (more lsdctl commands, then init again) if given.
local function migrate(ask, seats, policy, after)
	local dir = sh("mktemp -d"):gsub("%s+$", "");
	local env = string.format("LSD_HOME=%q LSD_DATA=%q ", HOME, dir);
	local ctl = env .. luajit .. " image/ctl/lsdctl.lua ";
	sh(ctl .. "setup --defaults");

	local f = io.open(dir .. "/settings", "rb");
	local text = f:read("*a");
	f:close();
	local n;
	text, n = text:gsub("(# %-%-%-%- player_limit %-%-%-%-[^\n]*\n)[^\n]*\nplayer_limit_max = %d+\n",
		function(head) return head .. ask .. "\nplayer_limit_max = " .. seats .. "\n"; end);
	check(n == 1, "(the old section is seeded)", text);
	text, n = text:gsub('192: "required"', '192: "' .. policy .. '"');
	check(n == 1, "(the old policy is seeded)");
	f = io.open(dir .. "/settings", "wb");
	f:write(text);
	f:close();

	local out = sh(ctl .. "init");
	for _, c in ipairs(after or {}) do
		sh(ctl .. c);
		sh(ctl .. "init");
	end
	local got = sh(ctl .. "get player_limit_max"):gsub("%s+$", "");
	local pol = sh(ctl .. "get ext_policy");
	f = io.open(dir .. "/settings", "rb");
	local file = f:read("*a");
	f:close();
	sh("rm -rf " .. dir);
	return got, string.match(pol, '192: *"(%a+)"'), file, out;
end

print("\n1. 32, written by the setup that defaulted to it");
local seats, pol, file, out = migrate(ASK32, 32, "applied");
check(seats == "255", "32 becomes 255", seats);
check(pol == "required", "applied (32's policy) becomes required (255's)", pol);
check(not string.find(file, ASK32, 1, true), "the old question is gone from the file");
check(string.find(out, "brought up to date", 1, true), "init says it changed the settings", out);

print("\n2. 254, from the setup before that");
seats, pol = migrate(ASK254, 254, "recommended");
check(seats == "255", "254 becomes 255", seats);
check(pol == "required", "recommended becomes 255's default, required", pol);

print("\n3. a number chosen by hand is kept");
seats, pol = migrate(ASK32, 48, "required");
check(seats == "48", "48 stays 48", seats);
check(pol == "required", "and its policy", pol);
seats, pol = migrate(ASK32, 16, "applied");
check(seats == "16", "16 stays 16", seats);
check(pol == "applied", "and its policy, applied", pol);

print("\n4. a policy chosen by hand is kept");
seats, pol = migrate(ASK32, 32, "disabled");
check(seats == "255", "the old default seats still move to 255", seats);
check(pol == "disabled", "disabled stays disabled (and then 32 seats are served)", pol);

print("\n5. once migrated, a 32 set on purpose stays 32");
seats, pol = migrate(ASK32, 32, "applied",
	{"set player_limit_max 32 --no-restart", "set ext_policy \"{192: 'applied'}\" --no-restart"});
check(seats == "32", "32 set after the migration is kept", seats);

print("\n6. a fresh server: nothing to do");
local dir = sh("mktemp -d"):gsub("%s+$", "");
local ctl = string.format("LSD_HOME=%q LSD_DATA=%q ", HOME, dir) .. luajit .. " image/ctl/lsdctl.lua ";
sh(ctl .. "setup --defaults");
out = sh(ctl .. "init");
check(not string.find(out, "brought up to date", 1, true), "init leaves a fresh file alone", out);
check(sh(ctl .. "get player_limit_max"):gsub("%s+$", "") == "255", "255 seats");
check(string.match(sh(ctl .. "get ext_policy"), '192: *"(%a+)"') == "required", "Player Limit required");
sh("rm -rf " .. dir);

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
