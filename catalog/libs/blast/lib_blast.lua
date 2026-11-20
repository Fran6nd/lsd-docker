-- lib_blast.lua -- Flying blasts: a trail of blocks, then an explosion
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- The rocket and the airstrike's bombs are the same thing seen from two
-- places: something that moves a few blocks a tick along a straight
-- line, shows where it is, and explodes where it ends. This is that
-- thing, once, so each effect is only about who fires it and when.
--
-- API (globals):
--   blast_fire(owner, pos, dir, o)  -> the blast, in flight
--        owner   the player credited with the damage
--        pos     where it starts, dir the unit vector it flies along
--        o.speed    blocks a tick, fractions fine (default 2)
--        o.range    blocks it flies before it fizzles (default 150)
--        o.radius   blocks destroyed around the impact, and a damage
--                   reach of twice that (default 3)
--        o.damage   at the very centre; less with distance (default 90)
--        o.trail    blocks of streak behind the head (blast_trail)
--        o.hostile  function(owner, target) -> may owner hurt target;
--                   the team test where not given
--        o.self_ratio  the owner's share of damage near their own
--                   blast, 0.33 by default
--        o.skip     steps drawn only after this many, so a rocket does
--                   not paint the shooter's own screen (default 2)
--        o.kill_radius  blocks from the impact within which a hit is
--                   lethal -- a direct hit always is (default 0)
--        o.guide    function(b) -> a point, or nil: asked every tick,
--                   the blast turns to fly straight at that point (a
--                   missile following its owner's aim); nil flies on
--   blast_explode(owner, pos, radius, damage, hostile, self_ratio, kill_radius)
--        the explosion alone: the rocket's impact, usable without flying
--   blast_aim(pid [, range]) -> the first block along pid's aim, as a
--        point, or nil for the open sky
--   blast_clear()   every trail block taken down, every blast dropped
--
-- THE TRAIL is not in the map. Each step the head is shown with
-- send_block_action from the anonymous pid (the railgun's tracer does
-- the same) rather than block_action, which would put a real block in
-- the map: then "remove the one we placed" would have to guess whether
-- a block there is still ours or a player's by now. Sent only, the map
-- never changes; we place only where the server's map is air, take down
-- only the positions we placed, and only while the map there is still
-- air, so a block a player built on that cell afterwards is never sent
-- away. Everything shown is taken down when the blast ends, on unload
-- and on a map change.
--
-- A build and a destroy that clients get in the same frame are handled
-- in the wrong order (apidoc, send_block_action), leaving a phantom
-- block. So a block comes down no sooner than MIN_AGE ticks after it
-- went up, however short the trail or fast the head.
local mod = init_mod();
require "lib_bulk_destroy";

getcfg("blast_trail", 6,
	"Blocks of fiery streak behind a rocket or bomb.");

local MIN_AGE = 2;       -- ticks a trail block stays up at least
local KILL_GRENADE = 3;  -- KillType, protocol.h
local MAP = 511;
local SKY = 8;     -- blocks above the top of the map a blast is gone
local FLOOR = 60;        -- lowest z a 3x3x3 crater is centred on: the
                         -- water-level floor below it is not ours to break

-- THE TRAIL COSTS PACKETS, and they are reliable: a block shown is a
-- build and, later, a destroy, to every player -- plus a colour, when
-- the anonymous pid's colour has to change first. A streak drawn too
-- densely queues so many of them that the crater's own packets, sent
-- after, reach clients a second or two late: the blast seems to wait
-- after the impact. So one colour for all of it, sent only when it is
-- not already the anonymous pid's, and a block every TRAIL_EVERY cells
-- -- as the railgun's dashes -- not every other one.
local COLOR = {r = 255, g = 120, b = 20};
local TRAIL_EVERY = 3;
local sent_color = nil;

local tick_no = 0;
local flying = {};  -- blasts in flight
local dying = {};   -- {x, y, z, at}: trail blocks waiting to come down

local function anon() return get_anon_pid(); end

-- The trail blocks up right now, by "x,y,z". No two share a face: a
-- client lets go of blocks that hang from nothing when one next to them
-- is broken, so a streak of touching blocks would not vanish block by
-- block but drop from the sky in a piece. Blocks meeting at an edge or
-- a corner do not hold each other up, so the streak still reads as one.
local lit = {};

local function key(x, y, z) return x .. "," .. y .. "," .. z; end

local function touches_lit(p)
	local x, y, z = p.x, p.y, p.z;
	return lit[key(x+1, y, z)] or lit[key(x-1, y, z)] or lit[key(x, y+1, z)]
		or lit[key(x, y-1, z)] or lit[key(x, y, z+1)] or lit[key(x, y, z-1)]
		or lit[key(x, y, z)];
end

local function show(p, color)
	lit[key(p.x, p.y, p.z)] = true;
	-- another script may have changed the anonymous colour since, which
	-- the hooks below notice: then ours is sent again
	if (sent_color ~= color) then
		send_set_block_color(PID_BROADCAST, color, anon());
		sent_color = color;
	end
	send_block_action(PID_BROADCAST, p, 0, anon());
end

-- Whoever else changes the anonymous pid's colour -- the railgun's
-- tracer, map_layout, the_fall -- makes ours stale. Our own sends pass
-- through here too, and show() records its colour after them.
function mod.after.send_set_block_color(pid, color, from)
	if (from == anon()) then
		sent_color = nil;
	end
end

function mod.after.set_block_color(pid, color)
	if (pid == anon()) then
		sent_color = nil;
	end
end

local function hide(p)
	lit[key(p.x, p.y, p.z)] = nil;
	-- only while the server still says air: otherwise the cell is a
	-- player's now, and not ours to send away
	if (not is_solid(p)) then
		send_block_action(PID_BROADCAST, p, 1, anon());
	end
end

local function default_hostile(owner, target)
	return get_team(owner) ~= get_team(target);
end

--============================= EXPLOSION ============================--

-- Is the line from the blast to the player's body clear of blocks?
-- A wall between them is cover; no raycast to ask, no cover.
-- Nothing solid between the blast and the player. A raycast that starts
-- inside a solid voxel answers that very voxel -- every victim would be
-- behind a wall -- so a blast point inside one (an explosion handed in
-- by a caller) is moved a block toward the victim first; the blasts
-- that fly here already go off in the air on the surface.
local function exposed(pos, p)
	if (raycast == nil) then
		return true;
	end
	local to = {x = p.x, y = p.y, z = p.z + 0.5};
	local from = pos;
	if (is_solid({x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z)})) then
		local dx, dy, dz = to.x - pos.x, to.y - pos.y, to.z - pos.z;
		local len = math.sqrt(dx*dx + dy*dy + dz*dz);
		if (len <= 1) then
			return true;
		end
		from = {x = pos.x + dx / len, y = pos.y + dy / len, z = pos.z + dz / len};
	end
	return raycast(from, to, true) == nil;
end

local function crater(owner, pos, radius)
	local list = {};
	local r = math.floor(radius / 2) * 2;
	for dx = -r, r, 2 do
		for dy = -r, r, 2 do
			for dz = -r, r, 2 do
				local x, y, z = math.floor(pos.x) + dx, math.floor(pos.y) + dy,
					math.floor(pos.z) + dz;
				-- a centre deeper than FLOOR moves up to it, so an
				-- impact on the ground (z 61 or so on most maps)
				-- digs into it rather than leaving it untouched
				z = math.min(z, FLOOR);
				if (dx*dx + dy*dy + dz*dz <= radius*radius
				    and x >= 0 and x <= MAP and y >= 0 and y <= MAP
				    and z >= 0) then
					list[#list+1] = {x = x, y = y, z = z};
				end
			end
		end
	end
	-- through the class's one door, so nothing protected is broken
	PlayerEffect.break_blocks(owner, list, 3);
end

-- Damage falls away linearly from the centre to twice the radius. The
-- owner takes a share of it, teammates none, through-the-wall nothing.
-- Lethal: more than any health there is. damage_player clamps at 0.
local LETHAL = 255;

function mod.impl.blast_explode(owner, pos, radius, damage, hostile, self_ratio, kill_radius)
	hostile = hostile or default_hostile;
	self_ratio = self_ratio or 0.33;
	kill_radius = tonumber(kill_radius) or 0;
	local reach = math.max(radius * 2, kill_radius);

	crater(owner, pos, radius);

	-- the look and the sound of it: a grenade, fused to go off at once,
	-- sent to the clients only -- never registered, so it hurts nobody
	-- and breaks nothing more; the damage and the crater are ours. From
	-- the anonymous pid, which costs nobody one of their own grenades.
	if (send_grenade ~= nil) then
		send_grenade(PID_BROADCAST, pos, {x = 0, y = 0, z = 0}, 0, anon());
	end

	for i in piditer(PID_BROADCAST) do
		if (is_alive(i) and (i == owner or hostile(owner, i))) then
			local p = get_position(i);
			local dx, dy, dz = p.x - pos.x, p.y - pos.y, p.z + 0.5 - pos.z;
			local d = math.sqrt(dx*dx + dy*dy + dz*dz);

			if (d < reach and exposed(pos, p)) then
				local amount = damage * (1 - d / reach);
				if (i == owner) then
					-- never one-shot by one's own: the falloff, a share
					amount = amount * self_ratio;
				elseif (d <= kill_radius) then
					amount = LETHAL;
				end
				amount = math.max(1, math.floor(amount));
				-- the owner may be gone: then nobody gets the kill
				local by = (is_connected(owner) and owner) or i;
				damage_player(i, amount, KILL_GRENADE, by);
			end
		end
	end
end

--============================== FLYING ==============================--

local function sign(n) return n < 0 and -1 or 1; end

-- (Re)start the voxel walk from a point, along a unit vector.
local function aim_at(b, pos, dir)
	b.vox = {x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z)};
	b.step = {x = sign(dir.x), y = sign(dir.y), z = sign(dir.z)};
	b.delta = {x = math.abs(1/dir.x), y = math.abs(1/dir.y), z = math.abs(1/dir.z)};
	b.tmax = {
		x = (b.vox.x - pos.x + math.max(b.step.x, 0)) / dir.x,
		y = (b.vox.y - pos.y + math.max(b.step.y, 0)) / dir.y,
		z = (b.vox.z - pos.z + math.max(b.step.z, 0)) / dir.z,
	};
end

-- A guided blast: turn the head, at the centre of its voxel, to face
-- the point its guide names. Answers true when the head is there
-- already: a point in the air (a player, or a guide's own choosing) is
-- reached rather than hit, and the blast goes off there instead of
-- circling it, turning back every tick.
local function steer(b)
	local ok, t = pcall(b.guide, b);
	if (not ok or type(t) ~= "table" or tonumber(t.x) == nil) then
		return;
	end
	local from = {x = b.vox.x + 0.5, y = b.vox.y + 0.5, z = b.vox.z + 0.5};
	local dx, dy, dz = t.x - from.x, t.y - from.y, t.z - from.z;
	local len = math.sqrt(dx*dx + dy*dy + dz*dz);
	if (len < 1) then
		return true;
	end
	aim_at(b, from, {x = dx / len, y = dy / len, z = dz / len});
	return false;
end

local AIM_RANGE = 400;

-- A player body, as aimed at: the eye down to the feet (2.25 below,
-- z growing downward), and AIM_BODY blocks around that line -- a little
-- more than the hitbox, since aiming a blast is not aiming a rifle.
local AIM_BODY = 1.0;
local BODY_DOWN = 2.25;

-- The nearest living player but `pid` whose body the ray from `eye` along
-- `d` passes through, nearer than `limit`: their pid and the point on
-- their body the ray is closest to. The raycast sees blocks only.
local function player_on_ray(pid, eye, d, limit)
	local best, bt, bpt = nil, limit, nil;
	for i in piditer(PID_BROADCAST) do
		if (i ~= pid and is_alive(i)) then
			local e = get_position(i);
			-- where the ray passes nearest the body's middle
			local cx, cy, cz = e.x, e.y, e.z + BODY_DOWN / 2;
			local t = (cx - eye.x) * d.x + (cy - eye.y) * d.y + (cz - eye.z) * d.z;
			if (t > 0 and t < bt) then
				local qx, qy, qz = eye.x + d.x * t, eye.y + d.y * t, eye.z + d.z * t;
				local hx, hy = qx - cx, qy - cy;
				if (hx*hx + hy*hy <= AIM_BODY * AIM_BODY
				    and qz >= e.z - AIM_BODY / 2 and qz <= e.z + BODY_DOWN + AIM_BODY / 2) then
					best, bt = i, t;
					bpt = {x = cx, y = cy, z = math.max(e.z, math.min(e.z + BODY_DOWN - 0.5, qz))};
				end
			end
		end
	end
	return best, bpt;
end

function mod.impl.blast_aim(pid, range)
	local from = get_position(pid);
	local d = get_orientation(pid);
	if (from == nil or d == nil or raycast == nil) then
		return nil;
	end
	range = tonumber(range) or AIM_RANGE;
	local eye = from;
	local reach = range;
	-- Standing on the top level, the eye is above the map (z < 0), and a
	-- raycast that starts out there finds nothing, whatever it points at:
	-- start it where the aim comes into the map. Aimed up or level from
	-- up there, there is no block to hit -- but there may be a player.
	local cast = true;
	if (from.z < 0) then
		if (d.z <= 0.001) then
			cast = false;
		else
			local k = -from.z / d.z;
			from = {x = from.x + d.x * k, y = from.y + d.y * k, z = 0};
			range = range - k;
			cast = range > 0;
		end
	end
	-- `false`: the solid block hit. LSd's apidoc has the two the other
	-- way round; the server answers `true` with the air voxel BEFORE the
	-- hit (as the grenade shotgun relies on), which would aim a missile
	-- at a point in mid-air in front of the wall.
	local hit = cast and raycast(from, {x = from.x + d.x * range,
		y = from.y + d.y * range, z = from.z + d.z * range}, false) or nil;
	local block, limit = nil, reach;
	if (hit ~= nil) then
		block = {x = hit.x + 0.5, y = hit.y + 0.5, z = hit.z + 0.5};
		local bx, by, bz = block.x - eye.x, block.y - eye.y, block.z - eye.z;
		limit = math.sqrt(bx*bx + by*by + bz*bz);
	end
	-- a player in front of that block is what is aimed at: the raycast
	-- sees blocks only, and a missile kept on a man would fly at the
	-- wall behind him. The point is on his body; .pid says whose.
	local who, at = player_on_ray(pid, eye, d, limit);
	if (who ~= nil) then
		at.pid = who;
		return at;
	end
	return block;
end

function mod.impl.blast_fire(owner, pos, dir, o)
	o = o or {};
	local b = {
		owner = owner,
		speed = tonumber(o.speed) or 2,
		range = tonumber(o.range) or 150,
		radius = tonumber(o.radius) or 3,
		damage = tonumber(o.damage) or 90,
		trail = tonumber(o.trail) or blast_trail,
		skip = tonumber(o.skip) or 2,
		self_ratio = o.self_ratio,
		hostile = o.hostile or default_hostile,
		kill_radius = tonumber(o.kill_radius) or 0,
		guide = o.guide,
		budget = 0, steps = 0, shown = {},
	};
	aim_at(b, pos, dir);
	flying[#flying+1] = b;
	return b;
end

-- Take the blast's streak down, a block at a time as each comes of age
local function retire(b, all)
	local keep = all and 0 or b.trail;
	while (#b.shown > keep) do
		local s = b.shown[1];
		if (tick_no - s.at < MIN_AGE) then
			break;
		end
		table.remove(b.shown, 1);
		hide(s);
	end
end

-- Is a living enemy of the owner in the cell? The body is about 1.8
-- wide and 3.6 tall (demoncore, as the railgun reads it).
local function person_in(b, v)
	for i in piditer(PID_BROADCAST) do
		if (i ~= b.owner and is_alive(i) and b.hostile(b.owner, i)) then
			local p = get_position(i);
			if (math.abs(p.x - (v.x + 0.5)) <= 1.1 and math.abs(p.y - (v.y + 0.5)) <= 1.1
			    and v.z + 0.5 >= p.z - 1.35 and v.z + 0.5 <= p.z + 2.25) then
				return true;
			end
		end
	end
	return false;
end

local function finish(b, at)
	b.done = true;
	-- what is still shown comes down as it comes of age
	for _, s in ipairs(b.shown) do
		dying[#dying+1] = s;
	end
	b.shown = {};
	if (at ~= nil) then
		blast_explode(b.owner, at, b.radius, b.damage, b.hostile, b.self_ratio,
			b.kill_radius);
	end
end

-- One voxel along the line. Answers false once the blast is over.
local function advance(b)
	local v, t, d, s = b.vox, b.tmax, b.delta, b.step;
	-- the cell it is leaving: air, where it goes off if the next is solid
	local was = {x = v.x + 0.5, y = v.y + 0.5, z = v.z + 0.5};
	if (t.z <= t.x and t.z <= t.y) then
		v.z = v.z + s.z; t.z = t.z + d.z;
	elseif (t.x < t.y) then
		v.x = v.x + s.x; t.x = t.x + d.x;
	else
		v.y = v.y + s.y; t.y = t.y + d.y;
	end
	b.steps = b.steps + 1;

	-- off the map sideways or below: gone; and above it, once well clear
	-- of the top (a bomb starts just inside it, at z 0.5, and a shot from
	-- the top level starts a little above): gone, unseen, unexploded.
	if (v.x < 0 or v.x > MAP or v.y < 0 or v.y > MAP or v.z > 63
	    or v.z < -SKY or b.steps > b.range) then
		finish(b);
		return false;
	end
	local cell = {x = v.x, y = v.y, z = v.z};
	if (v.z >= 0 and is_solid(cell)) then
		-- on the surface, in the air it came through: inside the block,
		-- nobody standing on it or swimming over it would be in its
		-- line of sight (exposed), and it would hurt nobody
		finish(b, was);
		return false;
	end
	if (person_in(b, v)) then
		finish(b, {x = v.x + 0.5, y = v.y + 0.5, z = v.z + 0.5});
		return false;
	end

	-- drawn into air only, and not on the shooter's own nose
	if (b.steps > b.skip and v.z >= 0 and b.steps % TRAIL_EVERY == 0
	    and not touches_lit(cell)) then
		cell.at = tick_no;
		show(cell, COLOR);
		b.shown[#b.shown+1] = cell;
	end
	return true;
end

function mod.impl.blast_clear()
	for _, b in ipairs(flying) do
		for _, s in ipairs(b.shown) do hide(s); end
	end
	for _, s in ipairs(dying) do hide(s); end
	flying, dying, lit = {}, {}, {};
end

function mod.after.tick()
	tick_no = tick_no + 1;

	-- an explosion's hooks may fire more blasts: they join `flying`
	local current = flying;
	flying = {};
	for _, b in ipairs(current) do
		b.budget = b.budget + b.speed;
		if (b.guide ~= nil and b.steps > 0 and steer(b)) then
			finish(b, {x = b.vox.x + 0.5, y = b.vox.y + 0.5, z = b.vox.z + 0.5});
		end
		local going = not b.done;
		while (going and b.budget >= 1) do
			b.budget = b.budget - 1;
			going = advance(b);
		end
		if (not b.done) then
			retire(b);
			flying[#flying+1] = b;
		end
	end

	local left = {};
	for _, s in ipairs(dying) do
		if (tick_no - s.at >= MIN_AGE) then
			hide(s);
		else
			left[#left+1] = s;
		end
	end
	dying = left;
end

-- the clients reload the map, trail and all
function mod.after.load_map()
	flying, dying, lit, sent_color = {}, {}, {}, nil;
end

function mod.on_unload()
	blast_clear();
end

return mod;
