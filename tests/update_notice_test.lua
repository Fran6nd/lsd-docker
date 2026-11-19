-- update_notice_test.lua -- admins told of a newer image as they log in
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/update_notice_test.lua      (from the repository root)
--
-- lib_update_notice against a stubbed server: what lsdctl update-check
-- wrote, which players hold the update_notice cap, and what is said.

package.path = "catalog/core/?.lua;" .. package.path;

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

local FILE = os.tmpname();
local function state(running, latest)
	local f = io.open(FILE, "w");
	f:write(string.format("running %s\nlatest %s\nchecked 2026-11-20T09:00:00Z\n", running, latest));
	f:close();
end

local CAPS = {};
local sent = {};
function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
	before={}, after={}, next={}, early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function pid_connected_table() return {}; end
function is_fakepid(pid) return pid >= 32; end
function has_cap(pid, cap) return CAPS[pid] == "all" or CAPS[pid] == cap; end
-- the real lib_l10n: server_msg hands each player the finished text
MAX_PLAYERS = 32;
PID_BROADCAST = 0x20000000;
local L = dofile("tests/support/l10n_env.lua").load{
	server_msg = function(pid, text) sent[#sent+1] = {pid, text}; end,
};
update_notice_file = FILE;

local mod = dofile("catalog/core/lib_update_notice.lua");

local function login(pid, caps)
	CAPS[pid] = caps;
	mod.after.on_cap_grant(pid, "login");
	mod.after.on_cap_grant(pid, caps);
	mod.after.tick();
end

print("\n1. what the check found");
os.remove(FILE);
check(update_notice() == nil, "no check yet: nothing to say");
state("2026.11.18.2", "2026.11.18.2");
check(update_notice() == nil, "up to date: nothing to say");
state("2026.11.18.2", "2026.11.20.1");
check(tostring(update_notice()):find("2026.11.20.1", 1, true), "newer: said, with the version");
state("2026.11.18.2", "2026.11.9.1");
check(update_notice() == nil, "compared as numbers: 11.9 is older than 11.18");
state("dev", "2026.11.20.1");
check(update_notice() == nil, "a development build is not told to update");
state("2026.11.18.2", "2026.11.20.1");
update_check = false;
check(update_notice() == nil, "update_check = False: nothing");
update_check = true;

print("\n2. who is told");
login(1, "login");
eq(#sent, 0, "a player who logs in without the cap is not told");
login(2, "all");
eq(#sent, 1, "an admin logging in is told");
eq(sent[1] and sent[1][1], 2, "that admin only");
check(sent[1] and sent[1][2]:find("lsd update", 1, true), "how to update", sent[1] and sent[1][2]);
mod.after.on_cap_grant(2, "jp");
mod.after.tick();
eq(#sent, 1, "once per connection");
login(3, "update_notice");
eq(#sent, 2, "the cap alone is enough");
mod.after.on_cap_grant(40, "all");
mod.after.tick();
eq(#sent, 2, "not the console");
CAPS[1] = "all";
mod.after.on_cap_grant(1, "admin");
mod.after.tick();
eq(sent[3] and sent[3][1], 1, "a player made admin later is told then");

os.remove(FILE);
L.clean(check);
print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
