-- command_ignore.lua -- Tranquility
-- upstream: lsd/scripts/command_ignore.lua fnv1a32 1d83030f (tests/overrides_test.lua)
local mod = init_mod();
-- Don't you think the name is a bit long?
cmd_ignore_ignored = nil;

function mod.on_load()
	cmd_ignore_ignored = pid_connected_table(function() return pid_connected_table(nil) end);
end

function mod.on_unload()
	cmd_ignore_ignored = nil;
end

-- TODO: make the desc clear that it only silences for you, not for all
local cmd = {name="ignore", usage="player", desc="Silence a player."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 1);
	local player = get_arg_pid("player", pid, cmd, argv[1]);
	cmd_ignore_ignored[pid][player] = not cmd_ignore_ignored[pid][player];
end
register_command(cmd, mod);

-- TODO: port mute to use send_chat?
function mod.send_chat(pid, msg, type, from)
	if (type == 2 or from < 0 or from >= MAX_PLAYERS) then
		mod.next.send_chat(pid, msg, type, from);
		return;
	end

	-- (lsd-docker, PATCHED) upstream sent a message to each id of a group,
	-- bots included, one call and one packet each. Nobody of the group
	-- ignoring the sender (nearly always): the group is sent whole, once.
	local function ignored(i)
		return cmd_ignore_ignored[i] ~= nil and cmd_ignore_ignored[i][from];
	end
	local whole = true;
	for i in (people_in or piditer)(pid) do
		if (ignored(i)) then
			whole = false;
			break;
		end
	end
	if (whole) then
		mod.next.send_chat(pid, msg, type, from);
		return;
	end

	for i in (people_in or piditer)(pid) do
		if (not ignored(i)) then
			mod.next.send_chat(i, msg, type, from);
		end
	end
end

return mod;
