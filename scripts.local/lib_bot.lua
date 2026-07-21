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
--   bot_nearest_player(pid, {team=, within=, include_bots=, visible=, reject=}) -> pid, dist | nil
--
-- Combat (see the COMBAT section for the AoS math):
--   bot_can_see(pid, target)         -- line of sight to a pid or pos
--   bot_look_horizontal(pid, dest)   -- level gaze toward a pid or pos
--   bot_aim_at(pid, target, rate, tol) -> on_target  -- smooth turn
--   bot_shoot(pid, {range=, spread_mult=, reject=}) -> hits | false
--        fires the gun along the current aim with client-like spread,
--        recoil and cadence, and damages whoever the ray strikes
--   bot_lob_grenade(pid, target, {accuracy=1..4, tolerance=}) -> thrown
--        aims and throws; 1 = crude lob, 4 = searched + cooked
--   bot_grenade_solution(pid, target, accuracy) -> {vel=,fuse=,err=}|nil
--        the raw ballistics (virtual-tick sim over lsd's own physics)
--   bot_incoming_grenade(pid, {radius=, ignore_chance=}) -> pos | nil
--        nearest live enemy blast to flee, precomputed on each throw
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

getcfg("bot_fidget_secs", 45);      -- idle keepalive period
getcfg("bot_shoot_range", 128);     -- max bullet reach, in blocks
getcfg("bot_grenade_speed", 1.0);   -- throw speed (|vel|); a client's orientation throw is ~1
getcfg("bot_grenade_max_fuse", 3.0);-- longest fuse a bot will cook toward
getcfg("bot_grenade_danger_ttl", 6);-- forget a tracked live grenade after this long

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

-- opts: team=, within=, include_bots=, visible= (require line of sight),
-- reject=function(pid) skip a candidate when it returns true
function bot_nearest_player(pid, opts)
	opts = opts or {};
	local best, bestdist = nil, opts.within or math.huge;

	for i in piditer(PID_BROADCAST) do
		if (i ~= pid and is_alive(i)
		    and (opts.include_bots or bots[i] == nil)
		    and (opts.team == nil or get_team(i) == opts.team)
		    and (opts.reject == nil or not opts.reject(i))
		    and (not opts.visible or bot_can_see(pid, i))) then
			local d = bot_distance_to(pid, i);
			if (d < bestdist) then
				best, bestdist = i, d;
			end
		end
	end

	return best, best ~= nil and bestdist or nil;
end

--============================ COMBAT ============================--
-- lsd runs bullet hit-detection on the CLIENT, so a peerless bot deals
-- no bullet damage on its own -- we raycast and damage here, mirroring
-- the AoS spread/recoil/damage the client would apply. Grenades are the
-- opposite: the server detonates them and deals blast damage itself, so
-- a bot only has to compute a good throw and call on_grenade().

-- AoS weapon feel. spread/recoil are the client-side numbers (lsd has
-- none server-side); fire is the cadence lsd already enforces
-- (main.c fireTime); dmg mirrors get_hit_damage's dmgmap[gun][part].
local WEAPON = {
	[0] = {fire=0.5, spread=0.006, recoil=0.060, pellets=1,
	       dmg={head=100, torso=49, limb=33}}, -- rifle
	[1] = {fire=0.1, spread=0.012, recoil=0.018, pellets=1,
	       dmg={head=75,  torso=29, limb=18}}, -- smg
	[2] = {fire=1.0, spread=0.024, recoil=0.045, pellets=8,
	       dmg={head=37,  torso=27, limb=16}}, -- shotgun
};

-- demoncore clips a body from 1.35 above pos (head) to 2.25 below
-- (feet) with a 0.45 half-width; classify the hit by height
local BODY_TOP, BODY_BOTTOM, BODY_RADIUS = -1.35, 2.25, 0.45;

local function vlen(v) return math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z); end

local function normalize(v)
	local l = vlen(v);
	if (l < 1e-9) then return {x=0, y=0, z=0}; end
	return {x=v.x/l, y=v.y/l, z=v.z/l};
end

local function dir_to(from, to)
	return normalize({x=to.x-from.x, y=to.y-from.y, z=to.z-from.z});
end

-- add a random cube offset scaled by `spread` and renormalize -- the
-- same thing the AoS client does to a bullet's direction
local function apply_spread(dir, spread)
	return normalize({
		x = dir.x + (math.random()*2-1)*spread,
		y = dir.y + (math.random()*2-1)*spread,
		z = dir.z + (math.random()*2-1)*spread,
	});
end

-- rotate a direction: pitch up by `up` radians (z is down, so up is
-- -z) and yaw by `yaw` radians about vertical
local function aim_offset(dir, up, yaw)
	local hlen = math.sqrt(dir.x*dir.x + dir.y*dir.y);
	local e = math.atan2(-dir.z, hlen) + up;      -- new elevation
	local a = math.atan2(dir.y, dir.x) + yaw;      -- new heading
	local ch = math.cos(e);
	return {x=ch*math.cos(a), y=ch*math.sin(a), z=-math.sin(e)};
end

-- does the ray from `start` along `dir` strike enemy `tgt` before any
-- wall? returns the body part ("head"/"torso"/"limb") or nil
local function ray_hits_player(start, dir, tgt, range)
	local p = get_position(tgt);
	local w = {x=p.x-start.x, y=p.y-start.y, z=p.z-start.z};
	local t = w.x*dir.x + w.y*dir.y + w.z*dir.z; -- distance along ray to closest point
	if (t <= 0 or t > range) then return nil; end

	local c = {x=start.x+dir.x*t, y=start.y+dir.y*t, z=start.z+dir.z*t};
	local hd = math.sqrt((c.x-p.x)^2 + (c.y-p.y)^2); -- horizontal miss
	if (hd > BODY_RADIUS) then return nil; end

	local zrel = c.z - p.z;
	if (zrel < BODY_TOP or zrel > BODY_BOTTOM) then return nil; end

	-- wall in the way? raycast to the impact point; a solid nearer than
	-- the target blocks the shot
	local wall = raycast(start, c, false);
	if (wall ~= nil) then
		local wd2 = (wall.x-start.x)^2 + (wall.y-start.y)^2 + (wall.z-start.z)^2;
		if (wd2 < t*t*0.98) then return nil; end
	end

	if (zrel <= -0.7) then return "head";
	elseif (zrel >= 1.2) then return "limb";
	else return "torso"; end
end

-- clear line of sight from pid's eyes to a target (a pid or a pos)?
-- false when a wall sits nearer than the target
function bot_can_see(pid, target)
	local a = get_position(pid);
	local b = type(target) == "number" and get_position(target) or target;
	local hit = raycast(a, b, false);
	if (hit == nil) then
		return true;
	end
	local hd2 = (hit.x-a.x)^2 + (hit.y-a.y)^2 + (hit.z-a.z)^2;
	local td2 = (b.x-a.x)^2 + (b.y-a.y)^2 + (b.z-a.z)^2;
	return hd2 >= td2 - 1.0;
end

-- face a target (a pid or a pos) on the horizontal plane, gaze level
-- -- for walking without terrain slopes tilting the aim
function bot_look_horizontal(pid, dest)
	local p = get_position(pid);
	local d = type(dest) == "number" and get_position(dest) or dest;
	local dx, dy = d.x-p.x, d.y-p.y;
	local l = math.sqrt(dx*dx + dy*dy);
	if (l > 0.001) then
		on_orientation(pid, {x=dx/l, y=dy/l, z=0});
	end
end

-- turn smoothly toward a target (a fraction `rate` of the way each
-- call); returns true once within `tol` radians. This is the "aim".
function bot_aim_at(pid, target, rate, tol)
	local want = dir_to(get_position(pid), target);
	local cur = get_orientation(pid);
	rate = rate or 0.35;

	local blended = normalize({
		x = cur.x + (want.x-cur.x)*rate,
		y = cur.y + (want.y-cur.y)*rate,
		z = cur.z + (want.z-cur.z)*rate,
	});
	on_orientation(pid, blended);

	local dot = cur.x*want.x + cur.y*want.y + cur.z*want.z;
	return dot >= math.cos(tol or 0.05);
end

-- fire the equipped gun along the current aim, respecting cadence,
-- spread, recoil and (for a moving shooter) doubled spread. Damages
-- whoever the perturbed ray strikes. Returns hits, or false if the gun
-- is still cycling.
function bot_shoot(pid, opts)
	opts = opts or {};
	local b = bots[pid];
	local w = WEAPON[get_gun(pid)];
	local now = get_time();

	if (b == nil or w == nil or get_tool(pid) ~= TOOL.gun) then return false; end
	if (now - (b.lastfire or 0) < w.fire) then return false; end
	b.lastfire = now;

	local base = get_orientation(pid);
	local team = get_team(pid);
	local range = opts.range or bot_shoot_range;

	local v = get_velocity(pid);
	local moving = (v.x*v.x + v.y*v.y + v.z*v.z) > 0.0004;
	local spread = w.spread * (moving and 2 or 1) * (opts.spread_mult or 1);

	-- current recoil kick (climbs with sustained fire, decays in tick)
	local kick = b.recoil or 0;

	local hits = 0;
	for _=1, w.pellets do
		local dir = aim_offset(base, kick, (math.random()*2-1)*kick*0.5);
		dir = apply_spread(dir, spread);

		local best, bestpart, bestt;
		for i in piditer(PID_BROADCAST) do
			if (i ~= pid and is_alive(i) and get_team(i) ~= team
			    and (opts.reject == nil or not opts.reject(i))) then
				local part = ray_hits_player(get_position(pid), dir, i, range);
				if (part ~= nil) then
					local d = bot_distance_to(pid, i);
					if (best == nil or d < bestt) then
						best, bestpart, bestt = i, part, d;
					end
				end
			end
		end

		if (best ~= nil) then
			damage_player_directional(best, w.dmg[bestpart],
				get_position(pid), bestpart == "head" and 1 or 0, pid);
			hits = hits + 1;
		end
	end

	-- climb the recoil, and show the muzzle to clients for one tick
	b.recoil = kick + w.recoil;
	send_mouse_input(PID_BROADCAST, 1, pid);
	b.muzzle = now;

	return hits;
end

-- step lsd's own grenade physics for up to `fuse` seconds, tracking the
-- point of closest approach to `target` (nil = don't care). Returns the
-- detonation position, the time of closest approach (for cooking), and
-- the miss distance.
local function sim_grenade(startpos, vel, target, fuse)
	local pos = {x=startpos.x, y=startpos.y, z=startpos.z};
	local v = {x=vel.x, y=vel.y, z=vel.z};
	local dt, t = 1/60, 0;
	local best_d2, best_t = math.huge, fuse;

	while (t < fuse) do
		pos, v = simulate_grenade_physics(pos, v, dt);
		t = t + dt;
		if (target ~= nil) then
			local d2 = (pos.x-target.x)^2 + (pos.y-target.y)^2 + (pos.z-target.z)^2;
			if (d2 < best_d2) then best_d2, best_t = d2, t; end
		end
	end

	return pos, best_t, target and math.sqrt(best_d2) or 0;
end

-- Solve for a throw that lands a grenade on `target`, at one of four
-- accuracy tiers (1 = crude lob, 4 = searched + cooked). Returns
-- {vel=, fuse=, err=} or nil. Uses the real physics simulator, so it
-- respects walls and bounces for free.
function bot_grenade_solution(pid, target, accuracy)
	accuracy = accuracy or 3;
	local start = get_position(pid);
	local speed = bot_grenade_speed;
	local maxf = bot_grenade_max_fuse;

	local dx, dy = target.x-start.x, target.y-start.y;
	local hlen = math.sqrt(dx*dx + dy*dy);
	if (hlen < 1e-6) then return nil; end
	local hx, hy = dx/hlen, dy/hlen;

	-- tier 1: no search -- a fixed 35-degree lob straight at the target,
	-- deliberately sloppy and left uncooked
	if (accuracy <= 1) then
		local e = 0.6 + (math.random()*2-1)*0.25;
		local ch = math.cos(e);
		return {vel={x=hx*ch*speed, y=hy*ch*speed, z=-math.sin(e)*speed},
		        fuse=maxf, err=hlen};
	end

	-- tiers 2-4: sweep launch elevation and keep the best landing; finer
	-- sweeps and cooking at higher tiers
	local steps = ({[2]=8, [3]=18, [4]=36})[accuracy] or 18;
	local best;
	for i=0, steps do
		local e = -0.2 + (1.5 * i/steps);          -- slightly down .. ~85 up
		local ch, cz = math.cos(e), -math.sin(e);
		local vel = {x=hx*ch*speed, y=hy*ch*speed, z=cz*speed};
		local _, tclose, err = sim_grenade(start, vel, target, maxf);
		if (best == nil or err < best.err) then
			best = {vel=vel, fuse=tclose, err=err};
		end
	end

	if (best == nil) then return nil; end
	-- cook (detonate on arrival) only at tier 3+; tier 2 throws long-fused
	if (accuracy < 3) then best.fuse = maxf; end
	return best;
end

-- aim at, then throw a grenade at `target`. Returns true if a throw was
-- made (tier-1 always throws; higher tiers only if the solution lands
-- within `tolerance` blocks, default 4).
function bot_lob_grenade(pid, target, opts)
	opts = opts or {};
	local sol = bot_grenade_solution(pid, target, opts.accuracy);
	if (sol == nil) then return false; end
	if ((opts.accuracy or 3) > 1 and sol.err > (opts.tolerance or 4)) then
		return false; -- no good arc; don't waste the nade
	end

	on_orientation(pid, normalize(sol.vel));
	-- on_grenade registers it (server will detonate + blast) and shows
	-- it to everyone; team comes from the bot's own player slot
	on_grenade(pid, get_position(pid), sol.vel, sol.fuse);
	return true;
end

-- grenades the bot should fear: precomputed on throw (like AoS's
-- exp_position), pruned as they expire
local dangers = {}; -- list of {pos=, at=, team=}

function mod.after.on_grenade(pid, pos, vel, fuse)
	local land = sim_grenade(pos, vel, nil, fuse);
	dangers[#dangers+1] = {pos=land, at=get_time()+fuse, team=get_team(pid)};
end

-- nearest live enemy blast within `radius` (default 20) that threatens
-- pid, or nil. Pass ignore_chance (e.g. 0.1) to let bots be humanly
-- oblivious sometimes.
function bot_incoming_grenade(pid, opts)
	opts = opts or {};
	if (opts.ignore_chance and math.random() < opts.ignore_chance) then
		return nil;
	end

	local me = get_position(pid);
	local team = get_team(pid);
	local now = get_time();
	local radius = opts.radius or 20;
	local best, best_d2;

	for _, d in ipairs(dangers) do
		if (d.at > now and d.team ~= team) then
			local d2 = (me.x-d.pos.x)^2 + (me.y-d.pos.y)^2 + (me.z-d.pos.z)^2;
			if (d2 < radius*radius and (best == nil or d2 < best_d2)) then
				best, best_d2 = d.pos, d2;
			end
		end
	end

	return best;
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

-- drop tracked grenades whose fuse (plus slack) has passed
local function prune_dangers()
	local now = get_time();
	for i=#dangers,1,-1 do
		if (now - dangers[i].at > bot_grenade_danger_ttl) then
			table.remove(dangers, i);
		end
	end
end

function mod.after.tick()
	if (not ready) then
		return;
	end

	prune_dangers();

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

			-- recoil recovers between shots; release the one-tick muzzle
			if (b.recoil ~= nil and b.recoil > 0) then
				b.recoil = b.recoil * 0.8;
				if (b.recoil < 1e-4) then b.recoil = 0; end
			end
			if (b.muzzle ~= nil and get_time() - b.muzzle >= 0.05) then
				b.muzzle = nil;
				send_mouse_input(PID_BROADCAST, 0, pid);
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
