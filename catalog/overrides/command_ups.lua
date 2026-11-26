-- command_ups.lua -- Configure your WorldUpdate receive rate
-- upstream: lsd/scripts/command_ups.lua fnv1a32 460a94de (tests/overrides_test.lua)
-- TODO: autoconfigure based on RTT?

local mod = init_mod();

-- (lsd-docker, PATCHED) the rate a client starts at: upstream sent every
-- client 60 a second. 30 is what a client needs to see others move
-- smoothly, and half the bytes: with many players a World Update is
-- several KB, and at 60 a second a link with any jitter falls behind.
-- A player still raises or lowers their own with /ups.
local FREQS = {[60]=true, [30]=true, [20]=true, [15]=true, [12]=true, [10]=true};
getcfg("ups_default", 30, "World Updates a second a client starts at (60, 30, 20, 15, 12 or 10; each player may change theirs with /ups).");
local function start_rate()
	local f = tonumber(ups_default);
	return 60 / (FREQS[f] and f or 30);
end
local rate = pid_connected_table(start_rate);
local ctr = 0;

local freq_msg = {
	en="%(arg) should be one of {%(freqs)} (Hz)"
};

local current_freq_msg = {
	en="Current update rate: %(freq) Hz"
};

local valid_freqs = {[60]=true, [30]=true, [20]=true, [15]=true, [12]=true, [10]=true};
-- TODO: how to l10n format a list of ints?
local cmd = {name="ups", usage="[freq]", desc="Get/set the rate your client receives player position/orientation."};
function cmd.func(pid, argv)
	-- The _opt arg-get function is used to allow for a more useful usage message
	cmd_assert(pid, cmd, #argv <= 1);
	local freq = get_arg_num_finite_opt("freq", pid, cmd, argv[1]);

	if (freq == nil) then
		l10n_send_chat(pid, current_freq_msg, {freq=60/rate[pid]});
		return;
	end

	if (not valid_freqs[freq]) then
		send_usage(pid, cmd);
		l10n_send_chat(pid, freq_msg, {arg="freq", freqs="60, 30, 20, 15, 12, 10"});
		return;
	end

	rate[pid] = 60 / freq;
end
register_command(cmd, mod);

-- TODO: this assumes the server ticks at 60 Hz and that nobody else calls send_player_update. . .
function mod.send_player_update(pid)
	-- (lsd-docker, PATCHED) the people of the group only: upstream walked
	-- every id, a bot's too, 60 times a second (lib_bot's people_in)
	for i in (people_in or piditer)(pid) do
		if (ctr % rate[i] == 0) then
			mod.next.send_player_update(i);
		end
	end

	-- Modulo prevents double precision from doing its thing.
	-- (Though realistically get_time() would fail far before that)
	-- 2*2*3*5 works out with all the rates I bothered
	-- supporting.
	ctr = (ctr + 1) % 60;
end

return mod;
