-- vote_peace_default_test.lua -- /votepeace is there by default, in every game
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/vote_peace_default_test.lua      (from the repository root)
--
-- A new server has it installed; an older settings file is given it, once
-- (`lsdctl init`: removed by its owner afterwards, it stays removed); and
-- it loads, after its library, under every gamemode.

package.path = "catalog/core/?.lua;" .. package.path;
local C = require "catalog";

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

print("\n1. every gamemode loads it, its library first");
local reader = {
	exists = function(p) local r = os.execute("test -e '" .. p .. "'"); return r == 0 or r == true; end,
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
check(#cat.errors == 0, "the catalog loads", table.concat(cat.errors, "; "));
local function order(plan)
	local flat = {};
	for _, p in ipairs(C.PHASES) do
		for _, m in ipairs(plan.phases[p]) do flat[#flat+1] = m; end
	end
	return flat;
end
local function index_of(list, x) for i, v in ipairs(list) do if (v == x) then return i; end end end
local modes = 0;
for _, e in ipairs(cat.list) do
	if (e:is_a(C.Gamemode)) then
		modes = modes + 1;
		local flat = order(cat:plan({"vote_peace", "vote_map"}, e.id));
		local at, lib = index_of(flat, "vote_peace"), index_of(flat, "lib_vote");
		check(at ~= nil and lib ~= nil and lib < at, e.id .. ": vote_peace loads, after lib_vote", table.concat(flat, " "));
	end
end
check(modes >= 10, "all the gamemodes were looked at", modes);

print("\n2. a new server has it");
local function ctl(dir) return string.format("LSD_HOME=%q LSD_DATA=%q ", HOME, dir) .. luajit .. " image/ctl/lsdctl.lua "; end
local dir = sh("mktemp -d"):gsub("%s+$", "");
sh(ctl(dir) .. "setup --defaults");
local scripts = sh(ctl(dir) .. "get scripts");
check(scripts:find('"vote_peace"', 1, true) and scripts:find('"vote_map"', 1, true), "vote_peace is in the default scripts", scripts);
check(scripts:find('"vote"', 1, true), "with its library", scripts);
local out = sh(ctl(dir) .. "init");
check(not out:find("brought up to date", 1, true), "init leaves a new file alone", out);

print("\n3. an older server is given it, once");
local f = io.open(dir .. "/settings", "rb"); local text = f:read("*a"); f:close();
local old = text:gsub('\t"vote_peace",\n', ""):gsub('\t"vote",\n', ""):gsub("\n# %-%-%-%- vote_peace %-%-%-%-[^\n]*\n[^#]*", "\n");
old = old:gsub("defaults_offered = [^\n]*\n", "");
f = io.open(dir .. "/settings", "wb"); f:write(old); f:close();
check(not sh(ctl(dir) .. "get scripts"):find("vote_peace", 1, true), "(the old file has no vote_peace)");
out = sh(ctl(dir) .. "init");
check(out:find("brought up to date", 1, true), "init brings it up to date", out);
scripts = sh(ctl(dir) .. "get scripts");
check(scripts:find('"vote_peace"', 1, true) and scripts:find('"vote_map"', 1, true) and scripts:find('"votekick"', 1, true),
	"vote_peace is installed, the rest kept", scripts);

print("\n4. and left alone after that");
sh(ctl(dir) .. "remove vote_peace --no-restart");
check(not sh(ctl(dir) .. "get scripts"):find("vote_peace", 1, true), "an owner removes it");
out = sh(ctl(dir) .. "init");
check(not out:find("brought up to date", 1, true) and not sh(ctl(dir) .. "get scripts"):find("vote_peace", 1, true),
	"init does not put it back", out);
print("\n5. an older server set up again before it starts is given it too");
-- `docker run ... IMAGE setup` on an old volume runs no init first: the
-- full setup shows the newer default ticked, and records it as offered
-- only then
f = io.open(dir .. "/settings", "wb"); f:write(old); f:close();
sh(ctl(dir) .. "setup --defaults");
scripts = sh(ctl(dir) .. "get scripts");
check(scripts:find('"vote_peace"', 1, true) and scripts:find('"vote"', 1, true),
	"setup installs it, with its library", scripts);
check(sh(ctl(dir) .. "get defaults_offered"):find('"vote_peace"', 1, true), "and records it offered");
sh("rm -rf " .. dir);

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
