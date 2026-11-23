-- inventory_test.lua -- lib_inventory: items that are commands
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/inventory_test.lua      (from the repository root)
local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what);
	else failures = failures + 1; print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or "")); end
end

--============================= STUBS ================================--
PID_BROADCAST = 0x20000000;
function init_mod() return {impl = {}, after = {}, before = {}, next = {}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function pid_connected_table(d) return setmetatable({}, {__index = function() return d; end}); end
function log() end
local L = dofile("tests/support/l10n_env.lua").load{};
L.pids = {0, 1};

local cmds = {};
function register_command(c) for _, n in ipairs(c.name) do cmds[n] = c; end end
-- commands.lua's: the line run as the player
local ran, keep_next, fail_next = {}, false, false;
function handle_command(pid, line)
	ran[#ran+1] = {pid = pid, line = line, using = inventory_using(pid)};
	if (fail_next) then fail_next = false; error("boom"); end
	if (keep_next) then keep_next = false; inventory_keep(); end
end
local pies, refreshed = nil, {};
function pie_menu_add(name, p) pies = p; end
function pie_menu_remove() pies = nil; end
function pie_menu_refresh(pid) refreshed[#refreshed+1] = pid; end

local mod = dofile("catalog/tools/inventory/lib_inventory.lua");
local function inv(pid, ...) cmds.inv.func(pid, {...}); end
local function said(pid)
	for i = #L.sent, 1, -1 do if (L.sent[i].pid == pid) then return L.sent[i].text; end end
end

--============================= CHECKS ===============================--
print("\n1. kinds of items, and holding them");
inv(0);
check(said(0) == "Your inventory is empty.", "nothing held: said so");
inventory_define("rocket", {label = {en = "Rocket"}, command = "/reward rocket", aim = true, order = 1});
inventory_define("medkit", {label = {en = "Medkit"}, command = "reward medkit", order = 2});
check(pies ~= nil and #pies == 1 and #pies[1].slices == 2 and pies[1].when == "alive", "an Inventory pie, a wedge per kind");
inventory_give(0, "rocket", 3);
inventory_give(0, "medkit");
check(inventory_count(0, "rocket") == 3 and inventory_count(0, "medkit") == 1 and inventory_count(1, "rocket") == 0,
	"given to one player, counted for them alone");
check(refreshed[#refreshed] == 0, "their pie is refreshed");

print("\n2. the count shows: x3 in the list and on the wedge");
inv(0);
check(said(0) == "1) Rocket x3  2) Medkit x1", "/inv lists them, numbered and counted", said(0));
local w = pies[1].slices[1];
check(w.label(0) == "Rocket x3" and w.text == "/inv rocket %h", "the wedge: its count, and the aim for an aimed item", w.label(0));
check(pies[1].slices[2].text == "/inv medkit", "no aim for one that takes none");
check(w.show(0) and not w.show(1), "shown only to who holds one");

print("\n3. using one runs its command as the player, and uses it up");
inv(0, "1", "10", "20", "30");
check(ran[1] and ran[1].pid == 0 and ran[1].line == "reward rocket 10.00 20.00 30.00", "by number, the aimed point sent on", ran[1] and ran[1].line);
check(ran[1].using == "rocket" and inventory_using(0) == nil, "the command can tell it runs as an item; not afterwards");
check(inventory_count(0, "rocket") == 2, "one fewer");
inv(0, "medkit");
check(ran[2].line == "reward medkit" and inventory_count(0, "medkit") == 0, "by name; the last one gone");
check(not pies[1].slices[2].show(0), "and its wedge with it");
inv(0, "medkit");
check(#ran == 2 and said(0) == "You have none of that.", "none left: nothing runs");
inv(1, "rocket");
check(#ran == 2, "nor for a player who holds none");

print("\n4. a command that did nothing keeps the item; one that raises too");
keep_next = true;
check(inventory_use(0, "rocket") == false and inventory_count(0, "rocket") == 2, "inventory_keep: not used up");
fail_next = true;
check(inventory_use(0, "rocket") == false and inventory_count(0, "rocket") == 2 and inventory_using(0) == nil,
	"a command that raises: kept, and the inventory is not left mid-use");

print("\n5. unlimited, set, take");
inventory_give(1, "rocket", math.huge);
check(pies[1].slices[1].label(1) == "Rocket x∞", "an unlimited item reads x∞");
inventory_use(1, "rocket");
check(inventory_count(1, "rocket") == math.huge, "and is never used up");
inventory_set(1, "rocket", 0);
check(inventory_count(1, "rocket") == 0, "inventory_set takes it back");
check(inventory_take(0, "rocket", 5) == 2 and inventory_count(0, "rocket") == 0, "take: no more than there is");

print("\n6. more than six kinds run onto a second pie");
for i = 1, 6 do inventory_define("k" .. i, {label = {en = "K" .. i}, command = "x"}); end
check(#pies == 2 and #pies[1].slices == 6 and #pies[2].slices == 2 and pies[1].id ~= pies[2].id, "eight kinds: six and two");
inventory_undefine("k1");
check(#pies[2].slices == 1, "a kind undefined leaves the pie");

L.clean(check);
mod.on_unload();
check(inventory_give == nil and pies == nil, "unloaded: its globals and its pie are gone");
print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
