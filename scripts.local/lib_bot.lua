-- lib_bot.lua -- Base API for server-side bots, so bot scripts read
-- as intent instead of protocol calls.
--
-- A bot is an ordinary player slot with no ENet peer: the C core
-- already sends packets for peerless players to /dev/null, runs full
-- demoncore physics for every joined+alive player, and broadcasts
-- them in WorldUpdate -- so to every client (and almost every script)
-- a bot is just a player. Bots are created by calling the same
-- chained events a real connection would fire (on_successful_connect,
-- on_join, on_move_input, ...), which is why other modules -- scores,
-- masterlist counts, kill feeds -- see them like humans.
--
-- API (all globals, pids are ordinary player pids):
--   bot_create{team=, name=, gun=, tool=, block_color=,
--              spawn_at=function(pid) -> pos|nil,
--              think=function(pid), data={}}      -> pid | nil
--   bot_destroy(pid)                 -- idempotent
--   bot_is_bot(pid) / bot_get(pid)   -- bot_get(pid).data is yours
--   bot_walk(pid, {forward=, back=, left=, right=, jump=, crouch=,
--                  sneak=, sprint=})  -- unset keys mean released
--   bot_stop(pid)                    -- release everything
--   bot_crouch(pid)                  -- stop and hold crouch
--   bot_look_toward(pid, dir)        -- unit vector
--   bot_look_at(pid, pos)            -- world position
--   bot_set_tool(pid, "spade"|"block"|"gun"|"grenade")
--   bot_set_block_color(pid, {r=,g=,b=})
--   bot_chat(pid, msg)
--   bot_teleport(pid, pos)
--   bot_heal(pid)
--   bot_distance_to(pid, pos_or_pid) -> dist
--   bot_nearest_player(pid, {team=, within=, include_bots=}) -> pid, dist | nil
--
-- The lib owns the lifecycle: spawn position (spawn_at is consulted
-- on every spawn, so respawns return there), per-tick think, input
-- reconciliation (on_move_input only fires on change; the jump key
-- auto-releases once airborne so it acts as one-shot), rejoining
-- after map-change limbo, an idle fidget so afkick sees life, and
-- destruction on unload/disconnect.
--
-- LIMITATIONS:
-- * Bots occupy real player slots: they count toward max players and
--   the masterlist player count, and a full server starves
--   bot_create (it returns nil; retry later).
-- * disconnect()/kick on a bot is a silent no-op -- no peer, so no
--   DISCONNECT event ever fires. Other modules kicking a bot leave
--   it in place; only bot_destroy()/on_disconnect() removes one.
-- * There is no client behind the slot: version/handshake/quirks
--   never arrive (mods keying on client identity see zeroes, RTT
--   reads 500), and since AoS hit detection is client-side, bots
--   never deal damage by "shooting" -- a bot script must raycast and
--   damage_player itself. Bots take damage normally: enemy clients
--   report hits on them like on anyone.
-- * Movement is straight-line demoncore physics at server tick rate:
--   no pathfinding, only the 1-block step-up and the jump key. Bots
--   drown, take water and fall damage, and get stuck on cliffs.
-- * Names are truncated to 15 bytes here because the C on_join
--   copies them unbounded.
-- * Reload this lib together with every script that uses it
--   (lsdctl load lib_bot hostage ...): reloading the lib alone
--   destroys the registry under its dependents' feet, which is also
--   why bot_destroy is idempotent.
local mod = init_mod();

getcfg("bot_fidget_secs", 45); -- idle keepalive period

local KEY = {up=1, down=2, left=4, right=8,
             jump=16, crouch=32, sneak=64, sprint=128};
local TOOL = {spade=0, block=1, gun=2, grenade=3};

local bots = {};    -- pid -> bot table
local ready = true; -- false while a map is loading

local function has_bit(bits, key)
	return bits % (2*key) >= key;
end

function bot_is_bot(pid)
	return bots[pid] ~= nil;
end

function bot_get(pid)
	return bots[pid];
end

local function bot_join(pid, b)
	-- tool and color ride the spawn_player hook below, which this
	-- triggers too
	on_join(pid, b.team, b.gun, b.name);
end

-- every (re)spawn resets tool and block color in the C core; put the
-- bot's own back
function mod.after.spawn_player(pid)
	local b = bots[pid];
	if (b ~= nil) then
		on_tool_change(pid, b.tool);
		if (b.block_color ~= nil) then
			on_color_change(pid, b.block_color);
		end
	end
end

function bot_create(opts)
	if (opts.team ~= 1 and opts.team ~= 2) then
		error("bot_create: team must be 1 or 2", 2);
	end
	if (type(opts.name) ~= "string") then
		error("bot_create: name required", 2);
	end
	if (opts.tool ~= nil and TOOL[opts.tool] == nil) then
		error("bot_create: unknown tool "..tostring(opts.tool), 2);
	end

	if (not ready) then
		return nil; -- map loading
	end

	local pid = server.assign_new_pid();
	if (pid >= MAX_PLAYERS) then
		return nil; -- server full
	end

	-- register before joining so spawn_at is consulted for the
	-- very first spawn already
	bots[pid] = {
		team = opts.team,
		name = string.sub(opts.name, 1, 15),
		gun = opts.gun or 0,
		tool = TOOL[opts.tool or "block"],
		block_color = opts.block_color,
		spawn_at = opts.spawn_at,
		think = opts.think,
		data = opts.data or {},
		want = 0,
		fidget = get_time(),
	};

	on_successful_connect(pid);
	bot_join(pid, bots[pid]);
	return pid;
end

function bot_destroy(pid)
	if (bots[pid] ~= nil) then
		-- the chained disconnect tells every module the "player"
		-- left; our own after-hook then drops the registry entry
		on_disconnect(pid);
	end
end

function bot_walk(pid, keys)
	local want = 0;

	if (keys.forward) then want = want + KEY.up;     end
	if (keys.back)    then want = want + KEY.down;   end
	if (keys.left)    then want = want + KEY.left;   end
	if (keys.right)   then want = want + KEY.right;  end
	if (keys.jump)    then want = want + KEY.jump;   end
	if (keys.crouch)  then want = want + KEY.crouch; end
	if (keys.sneak)   then want = want + KEY.sneak;  end
	if (keys.sprint)  then want = want + KEY.sprint; end

	bots[pid].want = want;
end

function bot_stop(pid)
	bots[pid].want = 0;
end

function bot_crouch(pid)
	bots[pid].want = KEY.crouch;
end

function bot_look_toward(pid, dir)
	on_orientation(pid, dir);
end

function bot_look_at(pid, pos)
	local p = get_position(pid);
	local dx, dy, dz = pos.x-p.x, pos.y-p.y, pos.z-p.z;
	local len = math.sqrt(dx*dx + dy*dy + dz*dz);

	if (len > 0.001) then
		on_orientation(pid, {x=dx/len, y=dy/len, z=dz/len});
	end
end

function bot_set_tool(pid, tool)
	bots[pid].tool = TOOL[tool] or tool;
	on_tool_change(pid, bots[pid].tool);
end

function bot_set_block_color(pid, color)
	bots[pid].block_color = color;
	on_color_change(pid, color);
end

function bot_chat(pid, msg)
	on_chat(pid, msg, 0);
end

function bot_teleport(pid, pos)
	set_position(pid, pos);
end

function bot_heal(pid)
	set_hp(pid, 100);
end

function bot_distance_to(pid, target)
	local a = get_position(pid);
	local b = type(target) == "number" and get_position(target) or target;
	local dx, dy, dz = a.x-b.x, a.y-b.y, a.z-b.z;

	return math.sqrt(dx*dx + dy*dy + dz*dz);
end

function bot_nearest_player(pid, opts)
	opts = opts or {};
	local best, bestdist = nil, opts.within or math.huge;

	for i in piditer(PID_BROADCAST) do
		if (i ~= pid and is_alive(i)
		    and (opts.include_bots or bots[i] == nil)
		    and (opts.team == nil or get_team(i) == opts.team)) then
			local d = bot_distance_to(pid, i);
			if (d < bestdist) then
				best, bestdist = i, d;
			end
		end
	end

	return best, best ~= nil and bestdist or nil;
end

function mod.get_spawn_position(pid)
	local b = bots[pid];
	if (b ~= nil and b.spawn_at ~= nil) then
		local pos = b.spawn_at(pid);
		if (pos ~= nil) then
			return pos;
		end
	end

	return mod.next.get_spawn_position(pid);
end

function mod.after.tick()
	if (not ready) then
		return;
	end

	for pid, b in pairs(bots) do
		if (not is_joined(pid)) then
			bot_join(pid, b); -- back from map-change limbo
		elseif (is_alive(pid)) then
			if (b.think ~= nil) then
				local status, err = pcall(b.think, pid);
				if (not status) then
					log("lib_bot: think for #%i crashed, disabling: %s",
						pid, tostring(err));
					b.think = nil;
				end
			end

			-- the jump key is one-shot: release it once it worked
			if (has_bit(b.want, KEY.jump) and is_airborne(pid)) then
				b.want = b.want - KEY.jump;
			end

			local send = b.want;

			-- idle bots flip their sneak key now and then so
			-- activity trackers (afkick) see a living player
			if (get_time() - b.fidget >= bot_fidget_secs) then
				send = has_bit(send, KEY.sneak)
					and send - KEY.sneak or send + KEY.sneak;
			end

			if (send ~= get_inputs(pid)) then
				on_move_input(pid, send);
				b.fidget = get_time();
			end
		end
	end
end

function mod.after.on_disconnect(pid)
	bots[pid] = nil;
end

function mod.after.prepare_map_load()
	ready = false;
end

function mod.after.finish_map_load()
	ready = true;
end

function mod.on_unload()
	for pid in pairs(bots) do
		bot_destroy(pid);
	end
end

return mod;
