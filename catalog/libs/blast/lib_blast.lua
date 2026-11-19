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
--   blast_explode(owner, pos, radius, damage, hostile, self_ratio)
--        the explosion alone: the rocket's impact, usable without flying
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
local FLOOR = 60;        -- lowest z a 3x3x3 crater is centred on: the
                         -- water-level floor below it is not ours to break

-- the head's colours in turn: white-hot to red, so the streak flickers
local COLORS = {
	{r = 255, g = 235, b = 120},
	{r = 255, g = 160, b = 30},
	{r = 255, g = 90,  b = 10},
	{r = 210, g = 40,  b = 0},
};

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
	send_set_block_color(PID_BROADCAST, color, anon());
	send_block_action(PID_BROADCAST, p, 0, anon());
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
local function exposed(pos, p)
	if (raycast == nil) then
		return true;
	end
	return raycast(pos, {x = p.x, y = p.y, z = p.z + 0.5}, true) == nil;
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
function mod.impl.blast_explode(owner, pos, radius, damage, hostile, self_ratio)
	hostile = hostile or default_hostile;
	self_ratio = self_ratio or 0.33;
	local reach = radius * 2;

	crater(owner, pos, radius);

	for i in piditer(PID_BROADCAST) do
		if (is_alive(i) and (i == owner or hostile(owner, i))) then
			local p = get_position(i);
			local dx, dy, dz = p.x - pos.x, p.y - pos.y, p.z + 0.5 - pos.z;
			local d = math.sqrt(dx*dx + dy*dy + dz*dz);

			if (d < reach and exposed(pos, p)) then
				local amount = damage * (1 - d / reach);
				if (i == owner) then
					amount = amount * self_ratio;
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

function mod.impl.blast_fire(owner, pos, dir, o)
	o = o or {};
	local sign = function(n) return n < 0 and -1 or 1; end
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
		budget = 0, steps = 0, shown = {},
		vox = {x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z)},
		step = {x = sign(dir.x), y = sign(dir.y), z = sign(dir.z)},
		delta = {x = math.abs(1/dir.x), y = math.abs(1/dir.y), z = math.abs(1/dir.z)},
	};
	b.tmax = {
		x = (b.vox.x - pos.x + math.max(b.step.x, 0)) / dir.x,
		y = (b.vox.y - pos.y + math.max(b.step.y, 0)) / dir.y,
		z = (b.vox.z - pos.z + math.max(b.step.z, 0)) / dir.z,
	};
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
		blast_explode(b.owner, at, b.radius, b.damage, b.hostile, b.self_ratio);
	end
end

-- One voxel along the line. Answers false once the blast is over.
local function advance(b)
	local v, t, d, s = b.vox, b.tmax, b.delta, b.step;
	if (t.z <= t.x and t.z <= t.y) then
		v.z = v.z + s.z; t.z = t.z + d.z;
	elseif (t.x < t.y) then
		v.x = v.x + s.x; t.x = t.x + d.x;
	else
		v.y = v.y + s.y; t.y = t.y + d.y;
	end
	b.steps = b.steps + 1;

	-- off the map sideways or below: gone. Above it (a bomb starts at
	-- z 0) is not off the map.
	if (v.x < 0 or v.x > MAP or v.y < 0 or v.y > MAP or v.z > 63
	    or b.steps > b.range) then
		finish(b);
		return false;
	end
	local cell = {x = v.x, y = v.y, z = v.z};
	if (v.z >= 0 and is_solid(cell)) then
		finish(b, {x = v.x + 0.5, y = v.y + 0.5, z = v.z + 0.5});
		return false;
	end
	if (person_in(b, v)) then
		finish(b, {x = v.x + 0.5, y = v.y + 0.5, z = v.z + 0.5});
		return false;
	end

	-- drawn into air only, and not on the shooter's own nose
	if (b.steps > b.skip and v.z >= 0 and not touches_lit(cell)) then
		cell.at = tick_no;
		show(cell, COLORS[b.steps % #COLORS + 1]);
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
		local going = true;
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
	flying, dying, lit = {}, {}, {};
end

function mod.on_unload()
	blast_clear();
end

return mod;
