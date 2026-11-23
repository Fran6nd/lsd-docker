-- lib_update_notice.lua -- Tell admins, as they log in, of a newer image
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- `lsdctl update-check` asks the registry for the lsd-docker image's
-- published versions -- the entrypoint runs it every six hours -- and
-- writes what it found to update_notice_file:
--
--   running 2026.11.18.2
--   latest 2026.11.20.1
--   checked 2026-11-20T09:00:00Z
--
-- This module only reads that file, so nothing here waits on the
-- network. When a player gains the update_notice cap -- an admin logging
-- in has it, as admin is every cap -- and the file names a release newer
-- than the one running, they are told once for this connection, in
-- their language. Nobody else ever is.
--
-- It is about the lsd-docker image only: LSd itself is built into the
-- image, and moves only when a new image is released.
local mod = init_mod();

getcfg("update_check", true,
	"Check every six hours for a newer lsd-docker image, and tell admins "
		.. "as they log in. False stops both.");
getcfg("update_notice_file", "/data/rw/update-check");

local notice_msg = {en = "lsd-docker %(latest) is available; this server "
	.. "runs %(running). Update from the host: lsd update"};

-- pid -> true once told; cleared when they leave
local told = pid_connected_table();
-- pids whose caps changed since the last tick
local pending = {};

local function parts(v)
	local a, b, c, d = string.match(tostring(v), "^(%d+)%.(%d+)%.(%d+)%.(%d+)$");
	if (a == nil) then return nil; end
	return {tonumber(a), tonumber(b), tonumber(c), tonumber(d)};
end

local function newer(a, b)
	local x, y = parts(a), parts(b);
	if (x == nil or y == nil) then return false; end
	for i = 1, 4 do
		if (x[i] ~= y[i]) then return x[i] > y[i]; end
	end
	return false;
end

-- The notice, or nil when there is nothing newer (or no check yet).
function update_notice()
	if (update_check == false) then
		return nil;
	end
	local f = io.open(update_notice_file);
	if (f == nil) then
		return nil;
	end
	local text = f:read("*a");
	f:close();

	local st = {};
	for k, v in string.gmatch(text, "(%w+) ([^\n]+)") do st[k] = v; end
	if (not newer(st.latest, st.running)) then
		return nil;
	end
	return l10n_msg(notice_msg, {latest = st.latest, running = st.running});
end

-- A cap was granted: look once the grants of this tick are all in, since
-- /login grants "login" first and the account's caps after it.
function mod.after.on_cap_grant(pid, cap)
	if (not is_fakepid(pid) and not told[pid]) then
		pending[pid] = true;
	end
end

function mod.after.tick()
	if (next(pending) == nil) then
		return;
	end
	for pid in pairs(pending) do
		pending[pid] = nil;
		if (not told[pid] and has_cap(pid, "update_notice")) then
			told[pid] = true;
			local m = update_notice();
			if (m ~= nil) then
				server_msg(pid, m);
			end
		end
	end
end

return mod;
