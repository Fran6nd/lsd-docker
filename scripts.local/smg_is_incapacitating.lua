-- smg_is_incapacitating.lua -- The SMG pins what it hits, and never runs dry
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Two changes to the SMG, and only the SMG.
--
-- EVERY BULLET PINS. A hit roots the man it lands on for
-- smg_freeze_secs, and each further hit renews it, so a burst holds him
-- where he stands. He is not disabled -- he can still turn, aim, shoot
-- back and reload -- he simply cannot go anywhere. The gun that hits ten
-- times a second is the one that can keep somebody still, which is why
-- it is this gun and not the other two.
--
-- Holding a man is entirely a matter of continuing to hit him: stop
-- shooting and he is walking again within smg_freeze_secs. That does
-- mean sustained fire holds a target for as long as it lasts, which is
-- the intended shape of the thing rather than an oversight -- turn
-- smg_freeze_secs down if it is too much.
--
-- THE MAGAZINE NEVER EMPTIES. Full stop, whether the bullets are landing
-- or going into a wall: the SMG is topped back up as it runs low and
-- never stops to reload. See the refill below for why it tops up early
-- rather than at zero.
--
-- NEITHER HALF ASKS WHEN A BULLET WAS FIRED, which is why this script
-- wants no lib_shot_detect. They dodge the question from opposite sides.
--
-- The pin does not need it because a pin is a consequence of a bullet
-- ARRIVING, and the client says so itself in a Hit packet: who was shot
-- is a thing the server is told, not a thing it has to work out.
--
-- The magazine does not need it because "the magazine is low" is not an
-- event at all, it is a fact about a player that is true right now and
-- stays true until something changes it. Watching for it in the tick
-- reads that fact directly. Firing off a detected shot was the long way
-- round: it inferred a shot in order to infer the count that the count
-- itself would have told us. A missed shot cost a missed refill; a
-- phantom one cost a wasted look. Neither can happen to a question that
-- is asked of the ammunition instead of the trigger, so this is both the
-- simpler code and the more reliable of the two.
--
-- HOW THE PIN WORKS, since "the server moves a player" is not obvious:
-- LSd lets a script drive somebody's position and clients honour it --
-- noclip.lua:67 flies a player that way and ridenade.lua:45 carries one
-- on a grenade. A pin is the same mechanism holding still instead of
-- moving. The target's own position reports are dropped meanwhile, so
-- the two are not arguing; they only arrive about once a second anyway
-- (apidoc/src/event:88), which is why the correction has to be sent
-- rather than merely believed.
local mod = init_mod();

-- Which gun this is about, and what a full one holds
-- (main.c:763,769 -- 30 rounds, 120 in reserve).
local GUN_SMG = 1;
local TOOL_GUN = 2;
local HIT_SPADE = 4;
local SMG_MAG = 30;
local SMG_RESERVE = 120;

getcfg("smg_freeze_secs", 0.6);   -- how long one bullet roots its target
-- How far a pinned player may be found from where they were pinned
-- before the pin is abandoned. A man fighting it drifts a fraction of a
-- block between corrections; anything on this scale is somebody else
-- having moved him -- a respawn, the Fall's recycle, an admin teleport --
-- and dragging him back would be this script overruling them.
getcfg("smg_freeze_slip", 4);
-- Refill when the magazine is down to this. Not at zero, deliberately:
-- at zero the client has already decided it is out and started its own
-- reload animation, and it is the round before that which keeps the gun
-- speaking. Higher costs more packets -- one per refill, not per shot.
getcfg("smg_refill_at", 10);

-- pid -> {at=<where they were pinned>, until_=<when it lapses>}. A
-- spawn table, so a respawn frees whoever was held: the man who comes
-- back is not the man who was pinned.
local frozen = pid_spawn_table();

--============================= THE PIN ==============================--

local function pin(target, secs)
	local p = get_position(target);

	frozen[target] = {
		at = {x=p.x, y=p.y, z=p.z},
		until_ = get_time() + secs,
	};
end

-- The target's own position updates are dropped while pinned, so that
-- the server is not talking itself out of the pin one packet later. Not
-- chaining is the whole of it: on_position's only job is to write what
-- the client claims into the server's idea of where they are.
function mod.on_position(pid, pos)
	if (frozen[pid] ~= nil) then
		return;
	end
	mod.next.on_position(pid, pos);
end

--=========================== THE MAGAZINE ===========================--

-- Top a man back up if he is running low. Idempotent and cheap on a full
-- magazine -- it is a comparison, and the packet only goes out when it
-- actually fires -- which is what lets the tick below simply ask this
-- every frame instead of waiting to be told a shot happened.
--
-- Reserve is topped up alongside the magazine because the magazine alone
-- would not survive a reload we did not beat: any path that empties the
-- gun where we are not looking -- an admin set_ammo, a script we do not
-- know about -- ends with the client reloading out of the reserve, and a
-- full one means that reload succeeds. Belt and braces on a gun whose
-- whole point is that it never stops.
--
-- get_mag_ammo being the lower of the engine's two counts is what makes
-- this safe to ask blind. The estimate can read low after a phantom
-- shot, so the error is always "refill a little early" -- which is the
-- state we wanted anyway. There is no reading that leaves the gun empty.
local function refill(pid)
	if (get_mag_ammo(pid) > smg_refill_at) then
		return;
	end
	set_ammo(pid, SMG_MAG, SMG_RESERVE);
end

--============================== THE TICK ============================--

-- Two jobs a frame: keep every SMG loaded, and hold every pinned player
-- (letting go of the ones whose time is up or whom somebody else moved).
--
-- The magazine is swept here rather than driven off a shot, because
-- "low" is a state and not an event -- see the header. Sixty passes a
-- second over the player list is nothing next to being right every time:
-- an SMG empties ten rounds a second, so the count cannot fall from
-- smg_refill_at to zero in under half a second however it is being
-- spent, and this looks thirty times in that window.
--
-- Ours is a plain after-tick, so anything loaded later gets the last
-- word on where a player is -- the Fall recycles its fallers this way,
-- and a pinned faller must still be recycled. The slip check below is
-- what stops us dragging him back out of the shaft next tick.
function mod.after.tick()
	local now = get_time();

	for pid in piditer(PID_BROADCAST) do
		-- the magazine. Guarded on the gun rather than on what is in
		-- hand: ammunition belongs to the gun, so a man who has switched
		-- to his spade mid-fight comes back to a full one.
		if (is_alive(pid) and get_gun(pid) == GUN_SMG) then
			refill(pid);
		end

		local f = frozen[pid];

		if (f ~= nil) then
			if (now >= f.until_ or not is_alive(pid)) then
				frozen[pid] = nil;
			else
				local p = get_position(pid);
				local dx, dy, dz = p.x-f.at.x, p.y-f.at.y, p.z-f.at.z;

				if (dx*dx + dy*dy + dz*dz
				    > smg_freeze_slip*smg_freeze_slip) then
					frozen[pid] = nil; -- somebody else moved him
				else
					set_position(pid, f.at);
				end
			end
		end
	end
end

--============================ THE TRIGGER ===========================--

-- A bullet arriving is the client's own report of it, and that is the
-- only thing this script listens to. It works out nothing for itself.
--
-- An after-hook: the damage is the engine's to do, and this only adds to
-- it. It also means a hit that something earlier in the chain threw away
-- -- dd.lua drops shots that come too fast -- never gets here, so a
-- refused bullet pins nobody.
function mod.after.on_hit(pid, type, hitPlayer)
	if (type == HIT_SPADE or not is_alive(pid) or not is_alive(hitPlayer)
	    or get_tool(pid) ~= TOOL_GUN or get_gun(pid) ~= GUN_SMG
	    or get_team(pid) == get_team(hitPlayer)) then
		return;
	end

	pin(hitPlayer, smg_freeze_secs);
end

function mod.after.on_join(pid)
	server_msg(pid, "warning: here the smg pins what it hits and never reloads.");
end

-- Advertise ourselves, rather than leaving it to whoever writes the
-- config. The script that changes a weapon is the thing that knows what
-- changed, so an instance gets the line by loading the script, and the
-- claim cannot drift from the code making it. tip_spam reads `tips` live
-- every tick, so appending is the whole of it; `tips` is nil on an
-- instance not running tip_spam, hence the guard. Taken out again on
-- unload, and taken out before being put in, so a reload leaves one.
local TIP = "Spicy: the SMG pins whoever it hits where they stand, and never reloads.";

local function untip()
	if (tips == nil) then
		return;
	end
	for i = #tips, 1, -1 do
		if (tips[i] == TIP) then
			table.remove(tips, i);
		end
	end
end

function mod.on_load()
	untip();
	if (tips ~= nil) then
		tips[#tips+1] = TIP;
	end

end

function mod.on_unload()
	untip();

	-- a pin is only maintained from the tick above, so unloading frees
	-- everybody by itself -- but the table is cleared anyway rather than
	-- left holding names nothing will ever look at again
	for i in piditer(PID_BROADCAST) do
		frozen[i] = nil;
	end
end

return mod;
