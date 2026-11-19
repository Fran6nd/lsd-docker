-- map_layout_test.lua -- the layout's pure parts: its file, its permissions
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/map_layout_test.lua      (from the repository root)
--
-- map_layout's JSON (the <map>.editor.json format) and its permission
-- chunks, which need no server; the components and the guards are
-- driven end to end by dev/smoke.sh, against a real one.

package.path = "catalog/libs/map_layout/?.lua;" .. package.path;

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

-- chunks asks the team only when a perm names one
local TEAM = {[0] = 1, [1] = 2};
function get_team(pid) return TEAM[pid]; end

local J = require "map_layout.json";
local chunks = require "map_layout.chunks";
local areas = require "map_layout.areas";

print("\n1. the layout file's JSON");
local doc = {default_perm = "rw", readonly = false, chunks = {},
	components = {{id = 1, kind = "door", x = 10, y = 20, perm = "rw:1",
		color = {r = 1, g = 2, b = 3}, name = 'a "quoted"\nline'}}};
local back = J.decode(J.encode(doc));
eq(back.default_perm, "rw", "a string round-trips");
eq(back.readonly, false, "a false round-trips");
eq(back.components[1].color.g, 2, "nested tables round-trip");
eq(back.components[1].name, 'a "quoted"\nline', "quotes and newlines round-trip");
eq(#back.chunks, 0, "an empty list round-trips");
eq(J.encode({b = 1, a = 2}), '{\n  "a": 2,\n  "b": 1\n}', "keys sorted: a stable file");
eq(J.decode("[1.5, -2]")[1], 1.5, "numbers");
check(not pcall(J.decode, '{"a": "unfinished'), "an unfinished string raises, not loops");
check(not pcall(J.decode, "{oops}"), "nonsense raises");

print("\n2. permissions");
eq(chunks.format_perm(chunks.parse_perm("rw:2")), "rw:2", "rw:<team> round-trips");
eq(chunks.parse_perm("ro").mode, "ro", "ro");
eq(chunks.parse_perm("nonsense"), nil, "anything else is refused");

chunks.reset();
chunks.set_default(chunks.parse_perm("rw"));
check(chunks.can_write(0, 5, 5, 5), "the open map: anybody");
chunks.add({area = areas.box(0, 0, 0, 9, 9, 9), perm = chunks.parse_perm("rw:1"), name = "base"});
check(chunks.can_write(0, 5, 5, 5), "a team-1 chunk: team 1 may");
check(not chunks.can_write(1, 5, 5, 5), "and team 2 may not");
check(chunks.can_write(1, 20, 20, 5), "outside it, the default again");
chunks.set_default(chunks.parse_perm("ro"));
check(not chunks.can_write(0, 20, 20, 5), "a read-only default holds outside every chunk");

local saved = J.decode(J.encode(chunks.serialize()));
chunks.reset();
chunks.set_default(chunks.parse_perm("rw"));
chunks.deserialize(saved);
check(not chunks.can_write(1, 5, 5, 5), "chunks survive the layout file");

print("\n3. shapes");
check(areas.contains(areas.box(0, 0, 0, 4, 4, 4), 2, 2, 2), "a box holds its inside");
check(not areas.contains(areas.box(0, 0, 0, 4, 4, 4), 5, 2, 2), "and not its outside");
check(areas.contains(areas.cylinder(10, 10, 3, 0, 20), 12, 10, 15), "a cylinder");
check(not areas.contains(areas.sphere(0, 0, 0, 2), 2, 2, 2), "a sphere is round");

print("\n4. who stands in an area");
-- 0 and 1 play, 2 is a SPECTATOR (256 in LSd, not 255; the stub says it is
-- alive so only the team can keep it out), 3 is out of the box
SPECTATOR = 256;
PID_BROADCAST = 0x20000000;
local TEAMS = {[0] = 1, [1] = 2, [2] = SPECTATOR, [3] = 1};
local POS = {[0] = {x = 2, y = 2, z = 2}, [1] = {x = 3, y = 3, z = 3},
	[2] = {x = 1, y = 1, z = 1}, [3] = {x = 90, y = 90, z = 2}};
function get_team(pid) return TEAMS[pid]; end
function get_position(pid) return POS[pid]; end
function is_joined() return true; end
function is_alive() return true; end
function piditer(b)
	local i = -1;
	return function() i = i + 1; if (i <= 3 and (b == PID_BROADCAST or b == i)) then return i; end end;
end
local box = areas.box(0, 0, 0, 9, 9, 9);
local in_box = areas.players_in(box);
eq(table.concat(in_box, ","), "0,1", "players_in: the players inside, not a spectator");
check(areas.any_player_in(box, function(i) return i == 1; end), "any_player_in: a player");
check(not areas.any_player_in(box, function(i) return i == 2; end), "but never a spectator");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
