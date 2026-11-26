-- hit_judge_test.lua -- lib_bot judges a bot's bullet on the server's body
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/hit_judge_test.lua      (from the repository root)
--
-- LSd judges no hit itself (clients do), so a bot's bullet is judged in
-- lib_bot (ray_hits_player, exported as bot_hit_part). Its body must be
-- the one the server moves (lsd/src/demoncore.c): 0.45 over the eye (the
-- reported position) to the feet, 2.25 under it standing and 1.35
-- crouched (the eye 0.9 lower, the feet where they were).
--
-- 1. THE PIN. The geometry is LSd's: lib_bot names, in its FIXME, the
--    demoncore functions it was read from by a checksum of their text,
--
--      -- lsd: src/demoncore.c <function> fnv1a32 <8 hex digits>
--
--    and this test fails the moment one of them is not that text any
--    more (an LSd update, dev/bump-lsd.sh). Then: read what changed, make
--    lib_bot's judge and bot/tests/brain_sim.h's bs_ray_hits match it,
--    and write the checksums this test prints into those lines.
-- 2. THE JUDGE. Shots level with each height of a standing and a
--    crouched man, from the side: the part each one hits, or none.
local bit = require("bit");

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

-- FNV-1a, 32 bits (as tests/overrides_test.lua)
local function fnv1a32(data)
	local h = 0x811c9dc5;
	for i = 1, #data do
		h = bit.bxor(h, data:byte(i)) % 0x100000000;
		h = bit.tobit((h * 0x193) % 0x100000000 + bit.lshift(h, 24) % 0x100000000);
	end
	return bit.tohex(h);
end
assert(fnv1a32("a") == "e40c292c" and fnv1a32("foobar") == "bf9cf968", "fnv1a32 itself");

local function slurp(path)
	local f = io.open(path, "rb");
	if (f == nil) then return nil; end
	local s = f:read("*a");
	f:close();
	return s;
end

-- a C function's text: from the line that defines it (its name and an
-- open parenthesis at the start of a line's declaration, not a ';'
-- prototype) to the first line that is a lone closing brace
local function c_function(src, name)
	local lines, out, inside = {}, {}, false;
	for l in (src .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l; end
	for i, l in ipairs(lines) do
		if (not inside and l:match("^[%w_ %*]*%f[%w_]" .. name .. "%(") and not l:match(";%s*$")) then
			inside = true;
		end
		if (inside) then
			out[#out + 1] = l;
			if (l == "}") then return table.concat(out, "\n"); end
		end
	end
	return nil;
end

print("1. lib_bot's judge names the LSd code its body is read from");
local LIB = "catalog/libs/bot/lib_bot.lua";
local lib = assert(slurp(LIB), LIB);
local core = slurp("lsd/src/demoncore.c");
local pins = 0;
if (core == nil) then
	print("  (lsd/src/demoncore.c not here: the submodule is not checked out; pins skipped)");
else
	for file, name, sum in lib:gmatch("%-%- lsd: src/(%S+) (%S+) fnv1a32 (%S+)") do
		pins = pins + 1;
		eq(file, "demoncore.c", name .. ": in demoncore.c");
		local text = c_function(core, name);
		check(text ~= nil, name .. ": still in lsd/src/demoncore.c",
			"gone: see the FIXME (WORK.md item 35) at lib_bot's ray_hits_player");
		if (text ~= nil) then
			check(fnv1a32(text) == sum, name .. ": LSd's code is the one the judge was made from",
				"now fnv1a32 " .. fnv1a32(text) .. ": LSd changed it -- see the FIXME at lib_bot's "
				.. "ray_hits_player and brain_sim.h's bs_ray_hits, make both match, then write that");
		end
	end
	check(pins >= 4, "the four functions are pinned", pins .. " pins");
end
check((slurp("bot/tests/brain_sim.h") or ""):find("tests/hit_judge_test.lua", 1, true) ~= nil,
	"brain_sim.h's bs_ray_hits points at this test");

print("2. a shot level with each height of a standing and a crouched man");
-- just what lib_bot asks to load and to judge
MAX_PLAYERS = 255;
PID_BROADCAST = 0x20000000;
function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
	before={}, after={}, next={}, early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function log() end
function get_time() return 0; end
function pid_connected_table() return {}; end
function piditer() return function() return nil; end end
package.preload["lib_bulk_destroy"] = function() return true; end
dofile(LIB);
assert(type(bot_hit_part) == "function", "lib_bot exports bot_hit_part");

local EYE, INPUTS = {x = 100.5, y = 100.5, z = 40}, 0;
function get_position() return EYE; end
function get_inputs() return INPUTS; end
function raycast() return nil; end          -- open ground

-- from 20 to the west, level, passing `dz` under his eye
local function part(dz, crouched)
	INPUTS = crouched and 32 or 0;
	return bot_hit_part({x = EYE.x - 20, y = EYE.y, z = EYE.z + dz}, {x = 1, y = 0, z = 0}, 7, 128) or "miss";
end
local STAND = {{-0.7, "miss"}, {-0.4, "head"}, {0.1, "head"}, {0.5, "torso"}, {1.0, "torso"},
	{1.2, "limb"}, {2.2, "limb"}, {2.4, "miss"}};
local CROUCH = {{-0.7, "miss"}, {-0.4, "head"}, {0.1, "head"}, {0.4, "torso"}, {0.7, "limb"},
	{1.3, "limb"}, {1.5, "miss"}, {2.0, "miss"}};
for _, c in ipairs(STAND) do eq(part(c[1], false), c[2], string.format("standing, %.1f under the eye", c[1])); end
for _, c in ipairs(CROUCH) do eq(part(c[1], true), c[2], string.format("crouched, %.1f under the eye", c[1])); end
-- across: 0.45 round his axis
INPUTS = 0;
eq(bot_hit_part({x = EYE.x - 20, y = EYE.y + 0.4, z = EYE.z + 0.5}, {x = 1, y = 0, z = 0}, 7, 128), "torso", "0.4 aside: on him");
eq(bot_hit_part({x = EYE.x - 20, y = EYE.y + 0.5, z = EYE.z + 0.5}, {x = 1, y = 0, z = 0}, 7, 128), nil, "0.5 aside: past him");
-- a wall between
function raycast(a) return {x = a.x + 5, y = a.y, z = a.z}; end
eq(part(0.5, false), "miss", "a wall between: no hit");

print(string.format("%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
