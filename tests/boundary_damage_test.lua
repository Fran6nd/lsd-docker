-- boundary_damage_test.lua -- a map's boundary, written as the web writes it
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/boundary_damage_test.lua      (from the repository root)
--
-- catalog/overrides/boundary_damage.lua against upstream's own
-- lib_pyscrape, on map .txt files as they come from the map sites.
local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what);
	else failures = failures + 1; print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or "")); end
end

function init_mod() return {impl = {}, after = {}, before = {}, next = {}, late = {}, early = {}, xearly = {}}; end
function log() end
PID_BROADCAST = 0x20000000;
function pid_spawn_table() return {}; end
local scrape = dofile("lsd/scripts/lib_pyscrape.lua");
local mod = dofile("catalog/overrides/boundary_damage.lua");

local function parse(text)
	local meta = {};
	mod.after.pyscrape_ext(scrape, text, meta);
	return meta.boundary_damage;
end

print("\n1. what maps on the web have");
local multi = [[
name = 'CheonggyecheonStream'
extensions = {
    'boundary_damage' :
    {
        'left' : 140,
        'right' : 371,
        'top' : 221,
        'bottom' : 277,
        'damage' : 30
    }
}
]];
local b = parse(multi);
check(b and b.left == 140 and b.right == 371 and b.top == 221 and b.bottom == 277 and b.damage == 30,
	"the block over several lines is read whole");
local one = "name = 'x'\nextensions = {\n    'boundary_damage' : {'left': 10, 'right': 500, 'top': 20, 'bottom': 490, 'damage': 5},\n}\n";
b = parse(one);
check(b and b.left == 10 and b.bottom == 490 and b.damage == 5, "on one line, as upstream read it");
local half = "extensions = {\n    'boundary_damage' : {'left': 10, 'right': 500},\n}\n";
check(parse(half) == nil, "an incomplete one is none at all");
check(parse("name = 'plain'\n") == nil, "a map without one: none");

print("\n2. the tick never stops on a broken one");
local meta = {boundary_damage = {left = 1}};
function get_map_meta() return meta; end
function get_time() return 0; end
function piditer() return function() end; end
check(pcall(mod.after.tick), "a boundary missing its edges ends nobody's tick");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
