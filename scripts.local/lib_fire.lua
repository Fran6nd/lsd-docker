-- lib_fire.lua -- One reliable "that was a shot", for every gun
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Scripts that replace what a bullet does -- railguns, exploding pellets
-- -- all need the same thing first: to know that a bullet happened, once
-- per bullet, for whoever fired it. The engine will not simply tell you.
-- This works out the answer once so that every such script can agree on
-- it instead of each growing its own half of it.
--
-- API (globals; register on load, drop on unload):
--   fire_listen(name, fn)   -- fn(pid, gun) once per shot. Registering
--                              the same name again replaces, so a
--                              hot-reload cannot leave two of you
--   fire_unlisten(name)
--   fire_shot_time(pid)     -- when this pid was last credited, or 0
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
--   * when proof keeps arriving while the cadence has gone quiet, the
--     cadence is broken (sprinting, or never re-armed after a teleport)
--     and this module runs its own in its place, for as long as the
--     proof keeps coming.
--
-- The cadence is distrusted when:
--
--   * a reload is pending. on_mouse_input clears the reload the instant
--     a real trigger press starts a cycle (funcs_event.c:174), so a
--     cycle still running underneath a scheduled reload was not started
--     by anybody.
--   * the player is sprinting, which is precisely when the bitmask
--     driving it is stale. Their real shots still arrive as proof.
--   * the magazine is out. Two readings, and they answer different
--     questions: get_max_mag_ammo only ever falls on proof, so zero
--     there means the bullets are provably spent; get_estimated_mag_ammo
--     falls on estimates too, so zero there means only "probably" -- and
--     recent proof overrules it, since a bullet that provably existed
--     proves the magazine wasn't empty.
--
-- LIMIT, stated plainly: a shot fired while sprinting that hits nothing
-- at all is invisible here, because it is invisible to the server. There
-- is no packet for it and no timer running. Everything else -- running,
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
local FIRE = 1;           -- get_mouse_inputs bit 1 is primary

-- Evidence closer together than this fraction of a weapon cycle is one
-- shot. Under 1 because two real shots are a whole cycle apart and this
-- has to survive the jitter on top of that; well over the few
-- milliseconds that separate one shell's pellets.
getcfg("fire_dedup", 0.75);
-- How long a proven bullet vouches for the magazine, and for the trigger
-- still being held. In weapon cycles, so an smg forgets in a tenth of a
-- second and a shotgun takes a couple.
getcfg("fire_proof_ttl", 2);
-- Cycles of silence from the engine's estimator, while proof keeps
-- arriving, before this module decides the estimator is broken and takes
-- the cadence over itself.
getcfg("fire_takeover_after", 1.5);
-- Whether the cadence may be trusted while a player sprints. It is
-- exactly then that the bitmask behind it is stale, so: no. Turn it on
-- only for a client you know reports mouse input while sprinting -- and
-- expect invented shots from every client that doesn't.
getcfg("fire_trust_sprint", false);

-- All three reset on every spawn, which is what makes a respawn, a
-- weapon switch and a teleport-by-spawn_player all clean slates: fresh
-- magazine, nothing owed, nothing believed.
local last  = pid_spawn_table(0);  -- when we last credited a shot
local proof = pid_spawn_table(0);  -- when a bullet last provably existed
local est   = pid_spawn_table(0);  -- when the engine last estimated one

local listeners = {};

local function fire_time(pid)
	return FIRE_TIME[get_gun(pid)] or FIRE_TIME[0];
end

-- Holding a gun, alive, and able to shoot it at all.
local function armed(pid)
	return is_alive(pid) and get_tool(pid) == TOOL_GUN;
end

local function sprinting(pid)
	return bit.band(get_inputs(pid), SPRINT) ~= 0;
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
	return get_time() - proof[pid] <= fire_time(pid)*fire_proof_ttl;
end

-- Credit pid with one shot, unless we already credited one inside this
-- weapon's cycle. Every path in this file ends here, so the one-shot-per
-- -cycle rule is enforced once rather than per source.
local function credit(pid)
	local now = get_time();

	if (now - last[pid] < fire_time(pid)*fire_dedup) then
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
			log("lib_fire: %s crashed on a shot, dropped: %s", name, tostring(err));
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
	est[pid] = get_time();

	-- a cycle still turning under a scheduled reload was started by
	-- nobody: a real trigger press would have cleared the reload
	if (get_reload_time(pid) ~= 0) then
		return;
	end
	if (not fire_trust_sprint and sprinting(pid)) then
		return;
	end
	if (not has_ammo(pid)) then
		return;
	end

	credit(pid);
end

-- The engine's estimator has gone quiet while the client is plainly
-- still shooting -- it is sprinting, or spawn_player zeroed the timer
-- mid-burst and no client is going to re-report a button it never
-- released. Proof alone would only catch the bullets that hit
-- something, so between them we run the cycle ourselves, and stop as
-- soon as the proof does.
function mod.after.tick()
	local now = get_time();

	for pid in piditer(PID_BROADCAST) do
		if (armed(pid)) then
			local cycle = fire_time(pid);

			if (now - proof[pid] <= cycle*fire_proof_ttl
			    and now - est[pid] > cycle*fire_takeover_after
			    and has_ammo(pid)) then
				credit(pid);
			end
		end
	end
end

-- Switching tools cancels the engine's cycle (funcs_event.c:194) and the
-- new tool is not a gun that has just fired, so nothing is owed.
function mod.after.on_tool_change(pid, tool)
	last[pid] = 0;
	proof[pid] = 0;
	est[pid] = 0;
end

--============================ LISTENERS =============================--

function fire_listen(name, fn)
	if (type(name) ~= "string") then
		error("fire_listen: name required (use your module's name)", 2);
	end
	if (type(fn) ~= "function") then
		error("fire_listen: fn required", 2);
	end
	listeners[name] = fn;
end

function fire_unlisten(name)
	listeners[name] = nil;
end

function fire_shot_time(pid)
	return last[pid];
end

-- Reloading this lib drops its listeners with it, so every module that
-- registered has to register again -- which is exactly what their own
-- on_load does. Reload them together:
--   ./lsdctl <instance> load lib_fire rifle_is_a_rail_gun ...
function mod.on_unload()
	listeners = {};
end

return mod;
