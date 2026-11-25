-- l10n_env.lua -- the REAL lib_l10n for a host-side test
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   local L = dofile("tests/support/l10n_env.lua").load{};
--
-- Loads catalog/overrides/lib_l10n.lua against a stubbed LSd and sets
-- the globals the catalog scripts call -- l10n_msg, l10n_msgn, l10n_str,
-- l10n_text, l10n_send_chat, l10n_get_str_pid/lang, server_msg and
-- send_chat -- so a test sees exactly the text a player reads, and a
-- stub can no longer be more forgiving than the real thing (a plain
-- {en = ...} table once reached players as "table: 0x...").
--
-- Everyone reads English. Call after the test has set PID_BROADCAST
-- and MAX_PLAYERS (32 when unset). Returns
--
--   L.sent   {{pid=, text=, kind="server"|"chat"}, ...}  what reached a
--            player: one entry per recipient, as the C would send it
--   L.chat   {{to=, m=, a=, text=}, ...}  one per l10n_send_chat call:
--            the English template, its arguments, and the finished
--            text (the first recipient's)
--   L.pids   the connected pids a broadcast reaches (default 0..3)
--   L.matches(set, pid)  optional: whether a group other than the broadcast reaches pid
--   L.reset()  forget both, in place
--   L.clean(check)   one check that no line a player got holds a
--            "table: 0x" or an unfilled %(placeholder)
--
-- opts.dir: a directory of <lang>/*.po, and every client a ZeroSpades that
-- gets them. L.unload() removes what was installed.
--
-- opts.server_msg(pid, text) / opts.send_chat(pid, text, type, from)
-- also see every finished line (a last argument tells one sent by
-- l10n_send_chat from a direct server_msg), for a test with its own recorder.

package.path = "catalog/core/?.lua;" .. package.path;

local M = {};

function M.load(opts)
	opts = opts or {};
	local L = {sent = {}, chat = {}, pids = {0, 1, 2, 3}};
	local max = _G.MAX_PLAYERS or 32;
	local broadcast = _G.PID_BROADCAST or 0x20000001;
	local env = setmetatable({MAX_PLAYERS = max, PID_BROADCAST = broadcast}, {__index = _G});

	function env.init_mod()
		return {impl = {before = {}, after = {}, next = {}}, late = {before = {}, after = {}, next = {}},
			before = {}, after = {}, next = {}, early = {before = {}, after = {}, next = {}},
			xearly = {before = {}, after = {}, next = {}}};
	end
	function env.getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
	-- as pid_tables.lua: pids 0..MAX_PLAYERS-1 hold the default
	function env.pid_connected_table(d)
		local t = {default = d};
		for i = 0, max - 1 do t[i] = d; end
		return t;
	end
	function env.is_fakepid(pid) return pid >= max and pid < 0x20000000; end
	-- with opts.dir, every client is a ZeroSpades the gate lets translate
	-- (l10n_set_lang then picks the language, the .po files are opts.dir's)
	function env.get_client_msg()
		return opts.dir and "Darwin | ZeroSpades 0.0.9 b3432453 (arm64)" or "";
	end
	if (opts.dir) then
		_G.l10n_dir = opts.dir;
		-- lfs over the shell, as the image's lfs.so is not on the host
		package.loaded.lfs = {
			attributes = function(p)
				local ok = os.execute("test -d '" .. p .. "'");
				return (ok == 0 or ok == true) and "directory" or nil;
			end,
			dir = function(p)
				local t = {};
				for n in io.popen("ls '" .. p .. "'"):lines() do t[#t+1] = n; end
				local i = 0;
				return function() i = i + 1; return t[i]; end;
			end,
		};
	end
	function env.get_client_ext_language() return ""; end
	function env.log() end
	-- as piditer in lua.c: a broadcast reaches the connected players, a
	-- single pid reaches only itself, and only if it is under MAX_PLAYERS
	function env.piditer(pid)
		local list = {};
		for _, p in ipairs(L.pids) do
			if (pid == broadcast or pid == p or (L.matches ~= nil and L.matches(pid, p))) then
				list[#list+1] = p;
			end
		end
		local i = 0;
		return function() i = i + 1; return list[i]; end;
	end

	local chunk = assert(loadfile("catalog/overrides/lib_l10n.lua"));
	setfenv(chunk, env);
	local mod = chunk();
	mod.next.l10n_get_lang = mod.impl.l10n_get_lang;

	-- what the lib defines as globals, now ours
	local installed = {};
	for k, v in pairs(env) do
		if (type(k) == "string" and k:find("^l10n_") and type(v) == "function") then
			_G[k] = v;
			installed[#installed+1] = k;
		end
	end
	if (opts.dir) then mod.on_load(); end
	_G.l10n_get_lang = mod.l10n_get_lang;
	_G.l10n_get_str_lang = mod.impl.l10n_get_str_lang;
	_G.l10n_get_str_pid = mod.impl.l10n_get_str_pid;
	_G.l10n_log = mod.impl.l10n_log;
	-- the LSd globals the test did not stub itself
	for _, k in ipairs({"piditer", "is_fakepid"}) do
		if (_G[k] == nil) then _G[k] = env[k]; end
	end
	_G.l10n_lang_changed = function() end;

	local via_l10n = false;   -- inside l10n_send_chat
	mod.xearly.next.server_msg = function(pid, text)
		L.sent[#L.sent+1] = {pid = pid, text = text, kind = "server", via_l10n = via_l10n};
		if (opts.server_msg) then opts.server_msg(pid, text, via_l10n); end
	end
	mod.xearly.next.send_chat = function(pid, text, kind, from)
		L.sent[#L.sent+1] = {pid = pid, text = text, kind = "chat", via_l10n = via_l10n};
		if (opts.send_chat) then opts.send_chat(pid, text, kind, from, via_l10n); end
	end
	_G.server_msg = mod.xearly.server_msg;
	_G.send_chat = mod.xearly.send_chat;

	-- l10n_send_chat is the real one; this only notes what it was given
	local real_send = mod.impl.l10n_send_chat;
	_G.l10n_send_chat = function(to, m, a)
		local n = #L.sent;
		via_l10n = true;
		local ok, err = pcall(real_send, to, m, a);
		via_l10n = false;
		if (not ok) then error(err, 0); end
		L.chat[#L.chat+1] = {to = to, m = type(m) == "table" and m.en or m, a = a or {},
			text = L.sent[n+1] and L.sent[n+1].text};
	end

	-- lines already seen to be bad, kept across reset()
	local bad;
	local function scan()
		for _, e in ipairs(L.sent) do
			if (type(e.text) ~= "string" or e.text:find("table: 0x", 1, true)
			    or e.text:find("%%%(")) then
				bad = bad or tostring(e.text);
			end
		end
	end

	-- forget what was sent, in place (a test may hold L.sent / L.chat)
	function L.reset()
		scan();
		for _, t in ipairs({L.sent, L.chat}) do
			for i = #t, 1, -1 do t[i] = nil; end
		end
	end

	-- covers every line since load, resets included
	-- take the globals back out, for a test that runs without lib_l10n after
	function L.unload()
		for _, k in ipairs(installed) do _G[k] = nil; end
		for _, k in ipairs({"l10n_get_lang", "l10n_get_str_lang", "l10n_get_str_pid", "l10n_log",
			"l10n_lang_changed", "l10n_send_chat", "server_msg", "send_chat", "l10n_default_lang",
			"l10n_clients", "l10n_log_lang", "l10n_dir"}) do
			_G[k] = nil;
		end
	end

	function L.clean(check)
		scan();
		check(bad == nil, "every line a player got is text: no table: 0x, no unfilled %(name)", bad);
	end

	return L;
end

return M;
