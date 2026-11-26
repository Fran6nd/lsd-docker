-- range_teams_test.lua -- the range: nobody but its targets on team 2
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/range_teams_test.lua      (from the repository root)
--
-- The mode in the core's own hook chain (lsd/scripts/core.lua: register,
-- the five chains, before/after), as a server runs it: upstream's
-- team_balance and command_switch loaded before it, as the tools phase
-- loads them, and what reaches the bottom of the chain -- the C core's
-- on_join and on_switch -- recorded. Every way a person can ask for team
-- 2 is tried: the join, the client's team change, from the spectators,
-- /switch, team_balance moving a joiner; and a bot of the range's on
-- team 2 must still get there. (A plain mod.on_join next to a
-- mod.after.on_join is lost to core.lua's process_before_after; a stub
-- chain does not show that, which is why this test runs the real one.)
local passed, failed = 0, 0;
local function check(ok, what)
	if (ok) then passed = passed + 1; print("  PASS " .. what);
	else failed = failed + 1; print("  FAIL " .. what); end
end

--============================= THE CORE =============================--
MAX_PLAYERS = 64;
PID_BROADCAST = 0x20000000;
local L = dofile("tests/support/l10n_env.lua").load{};
L.pids = {0, 1, 2, 3, 10};

local players = {};   -- pid -> {team =, gun =, joined =}
local bots = {};      -- pid -> lib_bot's entry
local core = {};      -- what reached the C core: {name, pid, team, gun}

function piditer()
	local list = {};
	for pid in pairs(players) do list[#list + 1] = pid; end
	table.sort(list);
	local k = 0;
	return function() k = k + 1; return list[k]; end
end
function is_connected(pid) return players[pid] ~= nil; end
function is_joined(pid) return players[pid] ~= nil and players[pid].joined; end
function get_team(pid) return players[pid].team; end
function get_next_team(pid) return players[pid].team; end
function get_gun(pid) return players[pid].gun; end
function get_next_gun(pid) return players[pid].gun; end
function get_name(pid) return "P" .. pid; end
function get_team_name(team) return ({"Blue", "Green"})[team]; end
function get_map_meta() return {}; end
function objgrav(p) return p; end
function drop_move_intel() end
function move_tent() end
function masterlist_set_gamemode() end
local commands = {};
function register_command(cmd) commands[cmd.name] = cmd; end
function cmd_assert(pid, cmd, ok) assert(ok); end
function get_arg_pid_opt(name, pid, cmd, arg) return arg ~= nil and tonumber(arg) or nil; end

-- lib_bot's: a bot is registered before the join it fires
function bot_is_bot(pid) return bots[pid] ~= nil; end
function bot_get(pid) return bots[pid]; end
function bot_create() end
function bot_destroy() end

-- the C core's on_join/on_switch (funcs_event.c): the team is the player's
server = {};
function server.on_join(pid, team, gun, name)
	core[#core + 1] = {"on_join", pid, team, gun};
	players[pid].team, players[pid].gun, players[pid].joined = team, gun, true;
end
function server.on_switch(pid, team, gun)
	core[#core + 1] = {"on_switch", pid, team, gun};
	players[pid].team, players[pid].gun = team, gun;
end

dofile("tests/support/core_env.lua").load();
SPECTATOR = 256;   -- lua.c's
function log() end

local function load_mod(path)
	local m = dofile(path);
	m.name = path:match("([^/]+)%.lua$");
	register(m);
	return m;
end
load_mod("lsd/scripts/team_balance.lua");
load_mod("lsd/scripts/command_switch.lua");
load_mod("catalog/gamemodes/range/range.lua");

--============================= HELPERS ==============================--
local function connect(pid) players[pid] = {team = SPECTATOR, gun = 0, joined = false}; end
local function reset() for k in pairs(core) do core[k] = nil; end L.reset(); end
local function told(pid)
	for _, c in ipairs(L.chat) do
		if (c.to == pid and c.text == "Green is the targets' team: every player is on Blue here.") then
			return true;
		end
	end
	return false;
end
local function last_core() return core[#core]; end

--============================= CHECKS ===============================--
print("\n1. joining");
connect(0);
reset();
on_join(0, 2, 1, "P0");
check(#core == 1 and last_core()[1] == "on_join" and last_core()[3] == 1 and last_core()[4] == 1,
	"a person joining on team 2 is put on team 1 with his gun");
check(told(0), "and told why: team 2 is the targets'");

connect(1);
reset();
on_join(1, 1, 0, "P1");
check(last_core()[3] == 1 and not told(1), "joining on team 1: team 1, and nothing said");

connect(2);
reset();
on_join(2, SPECTATOR, 0, "P2");
check(last_core()[3] == SPECTATOR and not told(2), "joining as a spectator: a spectator");

print("\n2. the client's team change");
reset();
on_switch(0, 2, 1);
check(#core == 0 and players[0].team == 1, "on team 1 with the same gun, asking for team 2: nothing changes");
check(told(0), "and told why");
reset();
on_switch(0, 2, 2);
check(#core == 1 and last_core()[3] == 1 and last_core()[4] == 2,
	"asking for team 2 with another gun: the gun changes, the team stays 1");
reset();
on_switch(2, 2, 0);
check(#core == 1 and last_core()[3] == 1 and players[2].team == 1 and told(2),
	"a spectator asking for team 2 comes in on team 1, told why");
reset();
on_switch(2, SPECTATOR, 0);
check(last_core()[3] == SPECTATOR and not told(2), "going to the spectators: allowed");
on_switch(2, 1, 0);

print("\n3. /switch");
reset();
commands.switch.func(1, {"1", "2"});
check(players[1].team == 1 and (#core == 0 or last_core()[3] == 1) and told(1),
	"/switch to team 2 leaves the player on team 1, told why");
reset();
commands.switch.func(1, {"1"});
check(players[1].team == 1 and told(1), "/switch to the other team: the same");

print("\n4. team_balance");
-- whatever the mode told it, team_balance moving people to the smaller
-- side is not a way onto team 2
team_balance_max_diff = 0;
connect(3);
reset();
on_join(3, 1, 0, "P3");
check(last_core()[3] == 1 and players[3].team == 1, "a joiner team_balance would move to team 2 is on team 1");

print("\n5. the range's own bots");
connect(10);
bots[10] = {team = 2, data = {range_target = 1}};
reset();
on_join(10, 2, 0, "Target");
check(last_core()[3] == 2 and players[10].team == 2, "a target joins team 2");
reset();
on_switch(10, 2, 0);
check(players[10].team == 2, "and stays there");
check(not told(10), "a bot is told nothing");

L.clean(check);
print(string.format("\n%d passed, %d failed", passed, failed));
os.exit(failed == 0 and 0 or 1);
