-- grenades_teleport_to_eol_fall.lua -- A bottomless pit at map centre,
-- and grenades that fling their victims down it.
--
-- A cylindrical shaft (diameter 25) is carved from the top of the map to
-- the bottom every time a map loads -- the map files on disk are never
-- touched, the hole is dug at runtime. Nobody can build inside it.
--
-- Hand-thrown grenades lose all their natural blast damage. Instead, when
-- one goes off, every player within the blast radius (any team, and the
-- thrower too if they're close enough) is teleported over the shaft and
-- left to plummet down it. The fatal landing at the bottom is rewritten
-- into the thrower's grenade kill, so the drop counts for them.
local mod = init_mod();
require "lib_bulk_destroy";

-- centre + size of the shaft. Map is 512x512, z runs 0 (sky) .. 63
-- (floor); 256 is the centre used by the stock apoc/babel scripts.
getcfg("gteof_center_x", 256);
getcfg("gteof_center_y", 256);
getcfg("gteof_diameter", 25);
-- how close to a detonation a player must be to get flung down the pit
getcfg("gteof_blast_radius", 8);

local CX = gteof_center_x;
local CY = gteof_center_y;
local R  = gteof_diameter / 2;
local R2 = R * R;
local BLAST2 = gteof_blast_radius * gteof_blast_radius;

-- z 0..62 is carved; z 63 is left as the floor they splat onto
local DIG_Z_BOTTOM = 62;
-- where a caught player is dropped in: the top of the shaft
local DROP_Z = 1;
-- grenade physics tick, matching the engine's 60 Hz
local STEP = 1/60;
-- KillType/HurtType: <4 credits the killer; 3 = grenade, 4 = fall
local KILL_GRENADE = 3;
local KILL_FALL = 4;

local no_build_msg = "You can't build in the pit.";

-- (wx, wy) are continuous world coords; test a voxel with its centre,
-- i.e. in_zone(x + 0.5, y + 0.5)
local function in_zone(wx, wy)
	local dx = wx - CX;
	local dy = wy - CY;
	return dx*dx + dy*dy <= R2;
end

-- carve the shaft: destroy every solid voxel in the cylinder, top to
-- bottom. block_action_rm (via bdestroy_block_action) no-ops on air, so
-- a column that's already clear costs nothing but the scan.
local function clear_hole()
	local lo_x = math.max(0,   math.floor(CX - R));
	local hi_x = math.min(511, math.ceil (CX + R));
	local lo_y = math.max(0,   math.floor(CY - R));
	local hi_y = math.min(511, math.ceil (CY + R));
	for x = lo_x, hi_x do
		for y = lo_y, hi_y do
			if (in_zone(x + 0.5, y + 0.5)) then
				for z = 0, DIG_Z_BOTTOM do
					bdestroy_block_action({x=x, y=y, z=z}, 3);
				end
			end
		end
	end
	bdestroy_finish();
end

-- pending grenade detonations: {x, y, z, t, thrower}
local pending = {};
-- players currently plummeting down the pit: victims[pid] = thrower pid.
-- Their fatal fall landing is rewritten into the thrower's grenade kill.
local victims = {};

-- Dig on every map load, while the map is still "loading" so the change
-- rides along inside the map that's about to be sent -- no per-block
-- packets. This is the requested "hole is made on map loading".
function mod.before.finish_map_load()
	pending = {};
	victims = {};
	clear_hole();
end

-- Also carve the map that's already up when this module is (re)loaded,
-- but only when nobody's connected (server start): with players on, the
-- thousands of per-block updates would swamp them, so we let the next
-- map load handle it instead.
function mod.on_load()
	for _ in piditer(PID_BROADCAST) do return; end
	clear_hole();
end

-- No building inside the shaft: refuse the placement (never call next, so
-- the server never applies it). Same early-hook pattern as babel_protect.
function mod.early.on_block_action(pid, pos, type)
	if (type == 0 and in_zone(pos.x + 0.5, pos.y + 0.5)) then
		server_msg(pid, no_build_msg);
		return;
	end
	mod.early.next.on_block_action(pid, pos, type);
end

-- ... and the line-building tool: refuse the whole line if it clips the pit
function mod.early.on_block_line(pid, startp, endp)
	for pos in iter_block_line(startp, endp) do
		if (in_zone(pos.x + 0.5, pos.y + 0.5)) then
			server_msg(pid, no_build_msg);
			return;
		end
	end
	mod.early.next.on_block_line(pid, startp, endp);
end

-- walk the grenade forward through its fuse to find where it detonates
local function detonation_pos(pos, vel, fuse)
	local t = 0;
	while (t < fuse) do
		pos, vel = simulate_grenade_physics(pos, vel, STEP);
		t = t + STEP;
	end
	return pos;
end

-- the blast goes off at (bx,by,bz): everyone within the blast radius --
-- any team, and the thrower if they're in it too -- is teleported over
-- the shaft to fall in. The kill lands when they hit the bottom (see the
-- kill hook below), credited to the thrower.
local function detonate(bx, by, bz, thrower)
	for i in piditer(PID_BROADCAST) do
		if (is_alive(i)) then
			local p = get_position(i);
			local dx, dy, dz = p.x - bx, p.y - by, p.z - bz;
			if (dx*dx + dy*dy + dz*dz < BLAST2) then
				set_position(i, {x=CX, y=CY, z=DROP_Z});
				victims[i] = thrower;
			end
		end
	end
end

-- fire queued detonations once their fuse has run out
function mod.tick()
	local now = get_time();
	local i = 1;
	while (i <= #pending) do
		local g = pending[i];
		if (now >= g.t) then
			detonate(g.x, g.y, g.z, g.thrower);
			table.remove(pending, i);
		else
			i = i + 1;
		end
	end
	mod.next.tick();
end

-- A player we flung into the pit has hit the bottom: the engine is about
-- to log a fall suicide. Rewrite it into the thrower's grenade kill so
-- the drop counts for them. Any other death just clears the tracking.
function mod.kill(pid, type, killer)
	local thrower = victims[pid];
	if (thrower ~= nil) then
		victims[pid] = nil;
		if (type == KILL_FALL) then
			mod.next.kill(pid, KILL_GRENADE, thrower);
			return;
		end
	end
	mod.next.kill(pid, type, killer);
end

-- stop tracking anyone who leaves or respawns before the fall finishes them
function mod.after.on_disconnect(pid)
	victims[pid] = nil;
end

function mod.after.spawn_player(pid)
	victims[pid] = nil;
end

-- A MANUALLY thrown grenade (bots spawn grenades directly, bypassing this
-- hook). We never call mod.next.on_grenade, so the grenade is never
-- registered for the engine's own detonation -- that strips ALL of its
-- natural blast damage. We still show it flying, then queue our own pit
-- detonation for when its fuse runs out.
function mod.on_grenade(pid, pos, vel, fuse)
	send_grenade(PID_BROADCAST_EXCEPT(pid), pos, vel, fuse, 0);
	local d = detonation_pos(pos, vel, fuse);
	table.insert(pending, {x=d.x, y=d.y, z=d.z, t=get_time() + fuse, thrower=pid});
end

function mod.after.on_join(pid)
	server_msg(pid, "warning: here a grenade flings everyone near it down the central pit.");
end

return mod;
