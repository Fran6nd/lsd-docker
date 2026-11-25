-- command_secspec.lua -- Sneak into spectator and pretend to be AFK
-- upstream: lsd/scripts/command_secspec.lua fnv1a32 c63e1329 (tests/overrides_test.lua)
-- TODO: can (SHOULD?) team chat be routed to spectators too?
local mod = init_mod();
local spectating = pid_joined_table(false);

local function unspec(pid)
	local pos = get_position(pid);
	pos.z = pos.z + 2;

	spectating[pid] = false;

	send_spawn_player(pid, pos, get_gun(pid), get_team(pid), get_name(pid), pid);

	if (is_alive(pid)) then
		send_orientation(pid, get_orientation(pid));
		-- TODO: send_set_hp()
		set_hp(pid, get_hp(pid));
		send_reload(pid, get_mag_ammo(pid), get_reserve_ammo(pid), pid);
		-- TODO: abuse "features" to set block count
	else
		-- TODO: add *other* get_spawn_time()
		send_kill(pid, 0, 4, pid, pid);
	end
end

local function spec(pid)
	local pos = get_position(pid);
	pos.z = pos.z + 2;

	send_spawn_player(pid, pos, get_gun(pid), SPECTATOR, get_name(pid), pid);
	spectating[pid] = true;
end

local cmd = {name={"secspec", "pubovl"}, caps="secspec", desc="Stick yourself into spectator without anybody else knowing."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0);

	if (spectating[pid]) then
		unspec(pid);
	else
		spec(pid);
	end
end
register_command(cmd, mod);

function mod.on_unload()
	for i in piditer(PID_BROADCAST) do
		if (spectating[i]) then
			unspec(i);
		end
	end
end

-- (lsd-docker, PATCHED) upstream sent to each id of the group, bots
-- included. Only a spectating player is kept from hearing of himself: when
-- it is not him that is spoken of, the group goes whole, once.
function mod.send_spawn_player(pid, pos, gun, team, name, from)
	-- TODO: pid_matches?
	if (not spectating[from]) then
		mod.next.send_spawn_player(pid, pos, gun, team, name, from);
		return;
	end
	for i in (people_in or piditer)(pid) do
		if (i ~= from) then
			mod.next.send_spawn_player(i, pos, gun, team, name, from);
		end
	end
end

-- TODO: handle score/general desync caused by ignoring kills
function mod.send_kill(pid, spawndelta, type, killer, from)
	if (not spectating[from]) then
		mod.next.send_kill(pid, spawndelta, type, killer, from);
		return;
	end
	for i in (people_in or piditer)(pid) do
		if (i ~= from) then
			mod.next.send_kill(i, spawndelta, type, killer, from);
		end
	end
end

-- TODO: send_set_hp()

return mod;
