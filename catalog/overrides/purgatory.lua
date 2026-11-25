-- purgatory.lua -- Send banned players to the shadow realm
-- upstream: lsd/scripts/purgatory.lua fnv1a32 35dcb4b8 (tests/overrides_test.lua)
-- TODO: extract old work on this from stick2
local mod = init_mod();
-- TODO: a lot

getcfg("purgatory_msg", [[
You've been banned D:
Appeal at https://nsa.gov/
]]);

local function send_map_chunk(pid, data)
	send_packet(pid, "\x13"..data);
end

local function send_state_tc(pid)
	send_packet(pid, "\x0f\x00\x7f\x7f\x7f\x00\x00\x00\x00\x00\x00"..string.rep('\0', 20).."\x01\x00");
	send_packet(pid, "\x09\x00\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
end

local sendanyway = false;
-- TODO: iterator
-- TODO: make unreliable a flag instead of func?
-- TODO: should the number be removed from send_packet
-- (lsd-docker, PATCHED) Upstream split EVERY packet, a broadcast too, into
-- one send for each id of the group: with a fleet of bots, 230 calls and
-- 230 packets made for each packet the server sends. Nobody being in
-- purgatory is the rule: then the group is sent whole, once, and the core
-- hands it to the peers. Only a group with someone in purgatory is taken
-- apart, and then only the people of it (lib_bot's people_in).
local function in_purgatory(i)
	return has_cap(i, "badcap:purgatory");
end

local function someone_jailed(pid)
	if (sendanyway) then
		return false;
	end
	for i in (people_in or piditer)(pid) do
		if (in_purgatory(i)) then
			return true;
		end
	end
	return false;
end

function mod.send_packet(pid, data)
	-- TODO: set banned AFTER connect and packet-sending?
	if (not someone_jailed(pid)) then
		return mod.next.send_packet(pid, data);
	end
	for i in (people_in or piditer)(pid) do
		if (not in_purgatory(i)) then
			mod.next.send_packet(i, data);
		end
	end
	return 0;
end

-- TODO: handle cap drop gracefully
function mod.send_packet_unreliable(pid, data)
	if (not someone_jailed(pid)) then
		return mod.next.send_packet_unreliable(pid, data);
	end
	for i in (people_in or piditer)(pid) do
		if (not in_purgatory(i)) then
			mod.next.send_packet_unreliable(i, data);
		end
	end
	return 0;
end

function send_to_purgatory(pid)
	-- TODO: set joined to false, after_destroy and boot
	local head = send_packet;
	sendanyway = true;
	send_map_start(pid, 11);
	send_map_chunk(pid, "\x78\xda\x63\xb0\xb3\x01\x00\x00\xbb\x00\x7b");
	-- TODO: predefined colors?
	-- TODO: {{pos={x,y,z}, team=0},}
	send_state_tc(pid, 0, {"", ""}, {{r=0, g=0, b=0}, {r=0, g=0, b=0}}, {r=127, g=127, b=127}, {});
	-- TODO: reorganize args
	--send_player(0, SPECTATOR, 0, 0, 0, {r=0, g=0, b=0}, "");
	for line in string.gmatch(purgatory_msg, "([^\n]+)") do
		server_msg(pid, line);
	end
	sendanyway = false;
end

function mod.after.on_cap_grant(pid, cap)
	-- TODO: should it check against cap or use has_cap?
	if (cap == "badcap:purgatory") then
		send_to_purgatory(pid);
	end
end

-- function mod.send_packet(...)
-- 	return mod.next.send_packet(...);
-- end

-- TODO: overridable is_connected which makes all functions, even send_packet, pretend the player isn't there?
-- (though that sounds like a terrible idea. . .)
-- TODO: prevent sending packets here
-- TODO: error if loaded with no module? put commands into the module?
function mod.on_any_connect(pid)
	-- TODO: need to ensure ban_caps.lua has synced caps first
	-- TODO: make mod.after_ban_caps or some much better name
	if (not has_cap(pid, "badcap:purgatory")) then
		if (pid == MAX_PLAYERS - 1) then
			-- Boot banned players to make room for important players
			-- TODO: disconnect_now? (with on_disconnect handling?)
			for x,y in ipairs(banned) do
				disconnect(x, 1);
				break;
			end
		end

		mod.next.on_any_connect(pid);
		return;
	end

	-- TODO: handle this (disconnecting when server too full) nicer
	-- TODO: this doesn't actually work if pid == MAX_PLAYERS, definitely should handle nicer
	-- TODO: what about players who get purgatoried mid-game? they don't get kicked
	if (pid >= MAX_PLAYERS) then
		callchain_impl.on_any_connect[#callchain_impl.on_any_connect](pid);
		return;
	end
end

-- TODO: add function to ban player, and make it disconnect the player if server full
-- TODO: allow overprovisioning connections?

function mod.on_any_packet(pid, data)
	if (has_cap(pid, "badcap:purgatory")) then
		-- TODO: is there a better way to do this than returning 1? (not returning a val at all?)
		return 1;
	end

	return mod.next.on_any_packet(pid, data);
end

return mod;
