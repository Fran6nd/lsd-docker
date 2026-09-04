-- lib_shot_detect.lua -- Works out when a player actually fired a bullet
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Scripts that replace what a bullet does -- railguns, exploding pellets
-- -- all need the same thing first: to know that a bullet happened, once
-- per bullet, for whoever fired it. The engine will not simply tell you.
-- This works out the answer once so that every such script can agree on
-- it instead of each growing its own half of it.
--
-- API (globals; register on load, drop on unload):
--   shot_listen(name, fn)   -- fn(pid, gun) once per shot. Registering
--                              the same name again replaces, so a
--                              hot-reload cannot leave two of you
--   shot_unlisten(name)
--   shot_last_time(pid)     -- when this pid was last credited, or 0
--
-- gun is 0 rifle, 1 smg, 2 shotgun -- filter on it yourself.
--
--============================ THE PROBLEM ============================--
--
-- Nothing in the protocol says "I fired". The server has two sources and
-- neither is sufficient alone.
--
-- CADENCE. The engine estimates firing from the held mouse bitmask:
-- on_mouse_input arms a timer (funcs_event.c:172), and tick() keeps
-- re-firing it every fireTime for as long as the bitmask still has bit 1
-- (main.c:807), calling before_estimated_fire each time. Correct while
-- the bitmask is correct -- and it often isn't:
--
--   * "no mouse inputs are ever reported when sprinting, or during
--     toolswitch delay" (apidoc/src/event:60). So the bitmask goes STALE
--     the moment a player sprints. Stale-off hides every shot they fire;
--     stale-on invents a shot every fireTime until they stop sprinting,
--     draining the engine's own ammo estimate as it goes -- which is how
--     a magazine reads empty while the real one is full.
--   * spawn_player zeroes both the timer and the bitmask (main.c:963).
--     A player who was holding the trigger through a respawn or a
--     teleport is still holding it, but their client has no change to
--     report, so nothing re-arms the timer. Every shot after that is
--     invisible to the cadence until they let go and press again.
--
-- PROOF. A Hit or a gun BlockAction is a client saying "my bullet landed
-- here". It cannot be a phantom -- the engine trusts these enough to
-- spend ammo on them (funcs_packetrecv.c:292 and :376 both decrement
-- maxMagAmmo) -- but it only exists when the bullet hit something. A
-- shot into open sky proves nothing.
--
--=========================== THE ANSWER =============================--
--
-- Take both, and let proof lead:
--
--   * proof credits a shot immediately, always.
--   * the cadence credits a shot unless something says not to trust it
--     (below).
--   * either way, at most one shot per weapon cycle, so a shotgun shell
--     arriving as eight separate pellet hits is one shot and not eight.
--
-- Both of those are evidence. Nothing here invents a shot, and an
-- earlier version of this file did: it ran its own cadence whenever
-- proof was recent and the engine's estimator had gone quiet, on the
-- reasoning that this meant "firing, but the estimator is broken". It
-- does not mean that. It is also exactly the state an ordinary single
-- shot leaves behind -- one bullet lands, the trigger is released, the
-- estimator stops -- so every shot that hit anything was followed by a
-- phantom one, a weapon cycle and a half later. Measured: one shot in,
-- two credits out, the second at +0.75s on a rifle and +1.5s on a
-- shotgun. For the scripts that listen here that is a free railgun
-- through the map, or a free grenade.
--
-- The lesson, in case it is tempting again: "proof arrived recently and
-- the estimator is quiet" cannot tell continued fire from a single shot,
-- because a single shot produces it. An uncounted bullet costs nothing;
-- an invented one fires a weapon nobody pulled.
--
-- The cadence is distrusted when:
--
--   * a reload is pending. on_mouse_input clears the reload the instant
--     a real trigger press starts a cycle (funcs_event.c:174), so a
--     cycle still running underneath a scheduled reload was not started
--     by anybody.
--   * the player is RUNNING. A player cannot shoot while running, so
--     every shot the cadence claims during one is invented -- and
--     running is exactly when the bitmask behind it went stale, which is
--     where the invention comes from. Both halves of that point the same
--     way: don't believe it.
--
--     Running is not the same as holding the sprint key. Run into a wall
--     and you are pinned there, not running, and you can shoot again --
--     so this asks the physics rather than the keyboard. Terminal speeds
--     out of demoncore.c's calc_acceleration are 0.325 sprinting, 0.25
--     walking, 0.075 crouched; pinned against something is nought.
--   * the magazine is out. Two readings, and they answer different
--     questions: get_max_mag_ammo only ever falls on proof, so zero
--     there means the bullets are provably spent; get_estimated_mag_ammo
--     falls on estimates too, so zero there means only "probably" -- and
--     recent proof overrules it, since a bullet that provably existed
--     proves the magazine wasn't empty.
--
-- LIMIT, stated plainly: a shot that both misses everything AND is fired
-- while the cadence is distrusted is invisible here, because it is
-- invisible to the server -- no packet, no timer, nothing to see. That
-- is the price of inventing nothing, and it is the right way round:
-- a missed count changes nothing, a phantom fires a weapon.
--
-- Everything else -- running, running into a wall and firing from it,
-- falling, wading, being teleported mid-burst, switching weapons, dying
-- mid-trigger -- is covered.
local mod = init_mod();
local bit = require("bit");

-- main.c:785 fireTime[], in seconds: the cycle the engine itself
-- estimates with, and the shortest gap there can be between two shots
local FIRE_TIME = {[0]=0.5, [1]=0.1, [2]=1.0};
local TOOL_GUN = 2;
local HIT_SPADE = 4;      -- get_hit_damage type 4; the rest are bullets
local DESTROY = 1;        -- send_block_action type 1
local SPRINT = 128;       -- send_move_input bit (apidoc/src/send:87)
local PKT_GUNRELOAD = 28; -- protocol.h:788

-- Evidence closer together than this fraction of a weapon cycle is one
-- shot. Under 1 because two real shots are a whole cycle apart and this
-- has to survive the jitter on top of that; well over the few
-- milliseconds that separate one shell's pellets.
getcfg("shot_dedup", 0.75);
-- How long a proven bullet vouches for the magazine: a bullet that
-- provably existed proves the magazine was not empty, whatever the
-- engine's estimate says. In weapon cycles.
getcfg("shot_proof_ttl", 2);
-- Whether the cadence may be trusted while a player is running. It is
-- exactly then that the bitmask behind it is stale, and a running player
-- cannot shoot anyway, so: no. Turn it on only for a client you know
-- both fires and reports mouse input while running.
getcfg("shot_trust_running", false);
-- Horizontal speed, in demoncore's own units, below which a player with
-- the sprint key down counts as pinned rather than running -- and so as
-- someone who can shoot after all. Well under a crouch (0.075) so that
-- nothing that is actually moving, even scraping along a wall, is
-- mistaken for stuck.
getcfg("shot_stuck_speed", 0.05);

-- Both reset on every spawn, which is what makes a respawn, a weapon
-- switch and a teleport-by-spawn_player all clean slates: fresh
-- magazine, nothing owed, nothing believed.
local last  = pid_spawn_table(0);  -- when we last credited a shot
local proof = pid_spawn_table(0);  -- when a bullet last provably existed

local listeners = {};

local function cycle_time(pid)
	return FIRE_TIME[get_gun(pid)] or FIRE_TIME[0];
end

-- Holding a gun, alive, and able to shoot it at all.
local function armed(pid)
	return is_alive(pid) and get_tool(pid) == TOOL_GUN;
end

-- Actually running, as opposed to merely holding the key. A player
-- pinned against an obstacle is not running and can shoot from there, so
-- the cadence is worth believing again -- see the RUNNING note above.
local function running(pid)
	if (bit.band(get_inputs(pid), SPRINT) == 0) then
		return false;
	end

	local v = get_velocity(pid);
	return math.sqrt(v.x*v.x + v.y*v.y) > shot_stuck_speed;
end

-- Could this player still have a bullet? get_max_mag_ammo is the hard
-- floor: it falls only on proof, so it never phantom-empties, and zero
-- there means the magazine is provably spent. The estimate is softer and
-- recent proof overrules it.
local function has_ammo(pid)
	if (get_max_mag_ammo(pid) == 0) then
		return false;
	end
	if (get_estimated_mag_ammo(pid) > 0) then
		return true;
	end
	return get_time() - proof[pid] <= cycle_time(pid)*shot_proof_ttl;
end

-- Credit pid with one shot, unless we already credited one inside this
-- weapon's cycle. Every path in this file ends here, so the one-shot-per
-- -cycle rule is enforced once rather than per source.
local function credit(pid)
	local now = get_time();

	if (now - last[pid] < cycle_time(pid)*shot_dedup) then
		return;
	end
	last[pid] = now;

	local gun = get_gun(pid);
	for name,fn in pairs(listeners) do
		-- a listener that throws is dropped rather than allowed to take
		-- the shot pipeline down with it -- same policy as lib_bot's
		-- think, and for the same reason
		local ok, err = pcall(fn, pid, gun);
		if (not ok) then
			listeners[name] = nil;
			log("lib_shot_detect: %s crashed on a shot, dropped: %s", name, tostring(err));
		end
	end
end

--============================== PROOF ===============================--
-- Both hooks are xearly observers on purpose. Modules that REPLACE what
-- a bullet does swallow these events without chaining -- shotgun pellets
-- neither hurt nor dig -- and a swallowed event never reaches anything
-- inside it. From the outermost chain we see them all, and we change
-- nothing, so nothing downstream can tell we were here.

local function proven(pid)
	if (not armed(pid)) then
		return;
	end
	proof[pid] = get_time();
	credit(pid);
end

function mod.xearly.before.on_hit(pid, type, hitPlayer)
	-- type 4 is the spade (apidoc/src/get_defaults:19); everything else
	-- is a bullet
	if (type ~= HIT_SPADE) then
		proven(pid);
	end
end

function mod.xearly.before.on_block_action(pid, pos, type)
	-- a destroy while holding the gun is a bullet: the engine's own
	-- validator only accepts type 1 from a gun and charges a round for
	-- it (funcs_packetrecv.c:374). armed() keeps the spade out.
	if (type == DESTROY) then
		proven(pid);
	end
end

--============================= CADENCE ==============================--

function mod.xearly.before.before_estimated_fire(pid)
	if (not armed(pid)) then
		return;
	end

	-- a cycle still turning under a scheduled reload was started by
	-- nobody: a real trigger press would have cleared the reload
	if (get_reload_time(pid) ~= 0) then
		return;
	end
	if (not shot_trust_running and running(pid)) then
		return;
	end
	if (not has_ammo(pid)) then
		return;
	end

	credit(pid);
end

-- Switching tools cancels the engine's cycle (funcs_event.c:194) and the
-- new tool is not a gun that has just fired, so nothing is owed.
function mod.after.on_tool_change(pid, tool)
	last[pid] = 0;
	proof[pid] = 0;
end

--=========================== STUCK RELOAD ===========================--
-- The same stale bitmask breaks reloading outright, and this is the only
-- place that knows enough to say so.
--
-- funcs_packetrecv.c:444 throws away a GunReload from anyone the server
-- believes is holding a mouse button. So once the bitmask has gone stale
-- with the trigger down -- a sprint, a toolswitch -- every reload that
-- player asks for is discarded, in silence. Their client plays the
-- animation it predicted locally and then waits for ammunition that is
-- never coming, which is what "the reload plays once and then I am stuck
-- for a whole reload" looks like from the inside. It does not clear
-- itself either: the same stale bit is still there next time.
--
-- A client that asks to reload is a client that is not holding the
-- trigger -- no client reloads mid-shot. So the request is the proof
-- that the bitmask is wrong. Clear it and honour the reload.
--
-- Clearing it is worth as much as the reload: it also stops the engine's
-- estimator inventing shots off that same bit, and stops everyone else
-- seeing the player's muzzle flashing forever.
function mod.after.on_crap_packet(pid, data)
	if (string.byte(data, 1) ~= PKT_GUNRELOAD) then
		return;
	end
	-- the only other thing that rejects a well-formed reload is not
	-- holding a gun, and that one deserves to be rejected
	if (not is_alive(pid) or get_tool(pid) ~= TOOL_GUN
	    or get_mouse_inputs(pid) == 0) then
		return;
	end

	on_mouse_input(pid, 0);
	on_reload(pid);
end

--============================ LISTENERS =============================--

function shot_listen(name, fn)
	if (type(name) ~= "string") then
		error("shot_listen: name required (use your module's name)", 2);
	end
	if (type(fn) ~= "function") then
		error("shot_listen: fn required", 2);
	end
	listeners[name] = fn;
end

function shot_unlisten(name)
	listeners[name] = nil;
end

function shot_last_time(pid)
	return last[pid];
end

-- Reloading this lib drops its listeners with it, so every module that
-- registered has to register again -- which is exactly what their own
-- on_load does. Reload them together:
--   ./lsdctl <instance> load lib_shot_detect rifle_is_a_rail_gun ...
function mod.on_unload()
	listeners = {};
end

return mod;
