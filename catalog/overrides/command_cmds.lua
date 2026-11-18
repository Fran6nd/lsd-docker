-- command_cmds.lua -- List available commands
--
-- Upstream's, with every command's description in the reader's language:
-- print_cmd takes the player it is for, and a description is looked up
-- as a lib_l10n message in the "command" context, the context
-- dev/l10n.lua extracts every desc = "..." under. /apropos therefore
-- searches what the player reads. Re-apply onto upstream's copy after
-- dev/bump-lsd.sh (see catalog/overrides/README).
local mod = init_mod();

getcfg("cmds_pagesize", 5);

-- TODO: should "Unknown command" from commands.lua be merged with this?
local unknown_cmd_msg = {
	en="Command not found."
};

local help_cmds_msg = {
	en="Were you looking for /commands?"
};

local function sort_cmds(x, y)
	return (x.name[1] or x.name) < (y.name[1] or y.name);
end

local function print_cmd(cmd, pid)
	local name = cmd.name[1] or cmd.name;
	local description = cmd.desc;

	if (type(description) == "string" and l10n_get_str_pid ~= nil) then
		description = l10n_get_str_pid(pid, {en = description, ctx = "command"});
	end
	local invocation = cmd.usage;

	if (invocation) then
		name = name .. " " .. invocation;
	end

	if (description) then
		name = name .. " -- " .. description;
	end

	return name;
end

function mod.impl.can_see_command(pid, cmd)
	return not is_fakepid(pid) or cmd.fakepid;
end

local function gen_cmdlist(pid)
	local list = {};

	for key, val in pairs(commands) do
		if (can_see_command(pid, val) and (val.name[1] or val.name) == key) then
			table.insert(list, val);
		end
	end

	table.sort(list, sort_cmds);
	return list;
end

local cmd = {name={"cmds", "commands"}, fakepid=true, usage="[page]", desc="Print an alphabetically ordered list of all commands."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv <= 1);
	local page = get_arg_num_finite_opt("page", pid, cmd, argv[1]);
	local list = gen_cmdlist(pid);

	if (page) then
		local start = 1+(page-1)*cmds_pagesize;

		if (start < 1) then
			for _, val in ipairs(list) do
				server_msg(pid, print_cmd(val, pid));
			end
			return;
		end

		for i=start,start+cmds_pagesize-1 do
			if (i > #list) then
				break;
			end
			server_msg(pid, print_cmd(list[i], pid));
		end

		return;
	end

	local line = "";
	local pfx = "";

	-- Limit line length to 80-ish chars
	for i,cmd in ipairs(list) do
		line = line..pfx..(cmd.name[1] or cmd.name);
		pfx = ", ";

		if (#line >= 75) then
			if (i ~= #list) then
				line = line..",";
			end

			server_msg(pid, line);

			line = "";
			pfx = "";
		end
	end

	server_msg(pid, line);
end
register_command(cmd, mod);

local cmd = {name="apropos", fakepid=true, usage="pattern", desc="Filter through the list of commands. Does not parse arguments."};
function cmd.func(pid, argv, msg)
	local pattern = string.sub(msg, 9);
	local list = gen_cmdlist(pid);

	for _, val in ipairs(list) do
		local str = print_cmd(val, pid);

		if (string.find(str, pattern)) then
			server_msg(pid, str);
		end
	end
end
register_command(cmd, mod);

-- TODO: should /help display usage for unseen commands? their existence can be confirmed by just attempting to run it, but /help denies it
local cmd = {name={"help", "man"}, fakepid=true, usage="command", desc="Display the invocation and description of a command."};
function cmd.func(pid, argv)
	local val = commands.help;

	if (#argv == 1) then
		val = commands[string.lower(argv[1])];
	end

	-- TODO: show aliases
	if (val ~= nil and can_see_command(pid, val)) then
		server_msg(pid, print_cmd(val, pid));
	else
		l10n_send_chat(pid, unknown_cmd_msg);
	end

	if (#argv == 0) then
		l10n_send_chat(pid, help_cmds_msg);
	end
end
register_command(cmd, mod);

return mod;
