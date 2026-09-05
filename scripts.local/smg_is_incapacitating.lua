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
-- THE MAGAZINE NEVER EMPTIES WHILE YOU ARE HITTING. Every bullet the
-- client reports landing on somebody tops the gun back up as it runs
-- low, so a man who keeps connecting never stops to reload. See the
-- refill below for why it tops up early rather than at zero.
--
-- BOTH OF THOSE COME OFF THE SAME EVIDENCE, and off nothing else: a Hit
-- packet from the shooter's own client. This script asks no one when a
-- bullet was fired and does not guess -- the two questions it needs
-- answered ("did a bullet land, and on whom") are the two the client
-- already answers on the wire, so a hit is the whole of its input. That
-- is why it wants no lib_shot_detect: the estimator exists for effects
-- that have to fire on a bullet which hits nothing at all, and neither
-- of these is one. Bullets that miss are simply not this script's
-- business, and the reserve below is what keeps them from mattering.
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

-- Hold every pinned player, and let go of the ones whose time is up or
-- who somebody else has moved.
--
-- Ours is a plain after-tick, so anything loaded later gets the last
-- word on where a player is -- the Fall recycles its fallers this way,
-- and a pinned faller must still be recycled. The slip check below is
-- what stops us dragging him back out of the shaft next tick.
function mod.after.tick()
	local now = get_time();

	for pid in piditer(PID_BROADCAST) do
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

--=========================== THE MAGAZINE ===========================--

-- Reserve is topped up alongside the magazine on purpose, and it is what
-- makes the miss case harmless. This runs on landed bullets only, so a
-- man spraying at terrain still empties his magazine and still reloads
-- like anybody else -- but he reloads out of a reserve that was full the
-- last time he hit something, so he never actually runs out of ammunition.
-- Hitting buys you the pause; the reserve is there either way.
local function refill(pid)
	if (get_mag_ammo(pid) > smg_refill_at) then
		return;
	end
	set_ammo(pid, SMG_MAG, SMG_RESERVE);
end

--============================= TRIGGERS =============================--

-- The one door in. Everything this script does is decided here, from the
-- shooter's own Hit packet and from nothing else.
--
-- An after-hook: the damage is the engine's to do, and this only adds to
-- it. It also means a hit that something earlier in the chain threw away
-- -- dd.lua drops shots that come too fast -- never gets here, so a
-- refused bullet neither pins anybody nor pays for a magazine.
function mod.after.on_hit(pid, type, hitPlayer)
	-- not a bullet, or not out of the gun this script is about
	if (type == HIT_SPADE or not is_alive(pid)
	    or get_tool(pid) ~= TOOL_GUN or get_gun(pid) ~= GUN_SMG) then
		return;
	end

	-- A reported hit is a round that left the barrel, whoever it found,
	-- so the magazine is paid for before asking anything about the
	-- target: a man laying into a teammate is still firing his gun, and
	-- one whose target died on that very bullet has still earned it.
	refill(pid);

	if (is_alive(hitPlayer) and get_team(pid) ~= get_team(hitPlayer)) then
		pin(hitPlayer, smg_freeze_secs);
	end
end

function mod.after.on_join(pid)
	server_msg(pid, "warning: here the smg pins what it hits, and keeps hitting it loaded.");
end

-- Advertise ourselves, rather than leaving it to whoever writes the
-- config. The script that changes a weapon is the thing that knows what
-- changed, so an instance gets the line by loading the script, and the
-- claim cannot drift from the code making it. tip_spam reads `tips` live
-- every tick, so appending is the whole of it; `tips` is nil on an
-- instance not running tip_spam, hence the guard. Taken out again on
-- unload, and taken out before being put in, so a reload leaves one.
local TIP = "Spicy: the SMG pins whoever it hits where they stand -- and keep landing bullets and it never reloads.";

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
