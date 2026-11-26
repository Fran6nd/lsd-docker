-- core_env.lua -- upstream's lsd/scripts/core.lua (the hook chains) for a host-side test
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   server = {};  function server.on_join(...) ... end   -- the C core's, optional
--   dofile("tests/support/core_env.lua").load();
--
-- Gives core.lua the server's globals it reaches while it loads, then
-- loads it: register(), init_mod(), getcfg(), the five chains, and the
-- `server` table as the impl chain's bottom. What a test defines in
-- `server` before the call is what the chain ends in.
--
-- The globals are given before the load and not after because the load
-- itself may use them: core.lua seeds math.random from the system
-- (math.randomseed()), and a LuaJIT whose randomseed wants a number --
-- Ubuntu's apt luajit 2.1.0-beta3 does, a current 2.1 does not -- makes
-- that pcall fail, and core.lua logs it through log(), whose colours
-- are the teams' (get_team_color).
--
-- core.lua sets package.path/cpath for the server's own layout; the
-- test's are put back. log() is core.lua's (to stderr); a test that
-- wants it quiet or recorded redefines it after the load.
local M = {};

function M.load()
	server = server or {};
	get_team_color = get_team_color or function() return {r = 0, g = 0, b = 0}; end
	on_shutdown = on_shutdown or function() end
	local path, cpath = package.path, package.cpath;
	dofile("lsd/scripts/core.lua");
	package.path, package.cpath = path, cpath;
end

return M;
