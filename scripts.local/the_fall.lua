-- the_fall.lua -- Die once, then fall until you kill your way out
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Death works normally here, exactly once. You are killed, the killer
-- gets their point and their line in the feed, and then you respawn --
-- not at your tent, but at the top of a bottomless shaft dug through the
-- middle of the map, at a random spot well clear of its walls, falling.
--
-- From there the only way out is to kill somebody. Do that and you are
-- healed, restocked and put back at your team's spawn, in the game
-- again. Nothing else gets you out. You never even reach the floor: a
-- few blocks short of it you are snatched back to the top, whole and
-- restocked, with clear air still under you -- no landing, no impact,
-- just the same drop again, over and over. Being shot by somebody else
-- falling beside you does kill you -- they earn the point, and they have
-- earned their way out if they were down here too -- but you respawn at
-- the top of the shaft, still falling, still owing a kill.
--
-- Bots ride the shaft permanently, on exactly the same terms: caught
-- short of the floor like everybody else, round and round. Each one
-- enters at its own height, redrawn every lap, so they never fall in
-- formation. A bullet does kill them, which is the entire reason they
-- are down there -- they are what a player shoots to buy their way out,
-- and the only thing that ever puts one on the ground.
--
-- And they are everyone's enemy: whatever side a faller is really on,
-- every client is told it is on the other side from them, so a Blue
-- player sees four Greens falling and a Green player sees the same four
-- as Blue. Nobody ever falls past a teammate they can't shoot. See the
-- DISGUISE section for what that takes -- it is not just cosmetic, since
-- the server's own damage rules still go by the real team.
--
-- The shaft is carved at runtime on every map load (the .vxl on disk is
-- never touched) and nobody can build inside it.
local mod = init_mod();
require "lib_bulk_destroy";

-- centre + size of the shaft. Map is 512x512, z runs 0 (sky) .. 63
-- (floor); 256 is the centre used by the stock apoc/babel scripts.
getcfg("thefall_center_x", 256);
getcfg("thefall_center_y", 256);
getcfg("thefall_diameter", 25);
-- how far in from the wall the nearest possible drop point is, so nobody
-- starts the fall scraping the rock
getcfg("thefall_edge_margin", 3);
-- bots permanently riding the shaft. Every one of them looks like an
-- enemy to everybody (see DISGUISE), so this is a flat total and the
-- side they are really on is an internal detail
getcfg("thefall_bots", 4);
-- seconds a SHOT bot lies there before being dropped in again, drawn
-- fresh each time. Only shooting one ever puts a bot on the ground; the
-- floor never does
getcfg("thefall_bot_delay_min", 1);
getcfg("thefall_bot_delay_max", 3);
-- how many blocks short of the shaft's floor a faller is snatched back
-- to the top. Big enough that the catch happens with clear air still
-- underneath -- a fall at terminal velocity covers about half a block
-- per tick, so this is several ticks of margin, not one
getcfg("thefall_floor_clearance", 5);
-- bots enter within this many blocks of the top, at a fresh random
-- height every lap, so their laps never fall into step (see bot_drop_pos)
getcfg("thefall_drop_spread", 24);

local CX = thefall_center_x;
local CY = thefall_center_y;
local R  = thefall_diameter / 2;
local R2 = R * R;
-- radius the drop points are picked inside: the shaft minus the margin,
-- floored at a point so a silly margin can't invert it
local DROP_R = math.max(R - thefall_edge_margin, 0.5);

-- z 0..62 is carved; z 63 is left as the floor at the bottom
local DIG_Z_BOTTOM = 62;
-- where a dropped player appears: the top of the shaft
local DROP_Z = 1;
-- and where the drop ends: anyone at or below this is close enough to
-- the floor to be caught and sent back up, still in mid-air
local CATCH_Z = DIG_Z_BOTTOM - thefall_floor_clearance;
-- KillType: 3 is a grenade, and 5 up is the bookkeeping behind a team or
-- gun change rather than a death anybody had
local KILL_GRENADE = 3;
local KILL_TEAMCHANGE = 5;
-- HitType, as the client reports it: 4 is the spade, 1 is a headshot
local HIT_MELEE = 4;
local HIT_HEAD = 1;
-- how far a blast reaches on each axis, and its damage at square
-- distance d2 -- main.c's detonate_grenade, mirrored in blast_fallers
local BLAST_REACH = 16;
local BLAST_SCALE = 4096;

local no_build_msg = "You can't build in the Fall.";

-- which PLAYERS are in the shaft. Set on death, cleared by the kill that
-- buys them out; while it is set the shaft itself can't kill them and
-- every respawn they get lands at the top of it. The bots live by the
-- same rules but are recognised by being fallers, not by this -- their
-- sentence never ends, so there is nothing to mark or clear.
local falling = pid_connected_table();
-- bots that were shot: redrop[pid] = when to drop the body in again.
-- Only ever set for a bot somebody killed, since nothing else in the
-- shaft can put one on the ground
local redrop = pid_connected_table();

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

local function is_faller(pid)
	local b = bot_get(pid);
	return b ~= nil and b.data.faller;
end

-- a random point in the shaft at height z, uniform over the disc of
-- radius DROP_R: the sqrt undoes the area bias a flat random radius has,
-- which would bunch everyone into the middle
local function drop_at(z)
	local ang = math.random() * 2 * math.pi;
	local rad = DROP_R * math.sqrt(math.random());

	return {x = CX + rad*math.cos(ang),
	        y = CY + rad*math.sin(ang),
	        z = z};
end

-- players always enter at the very top: the whole drop, every time
local function drop_pos()
	return drop_at(DROP_Z);
end

-- bots enter somewhere in the top thefall_drop_spread blocks instead.
-- That randomness is the ONLY thing keeping them out of formation now
-- that nothing in here lands: every lap is otherwise identical, so four
-- bots entering at the same height would fall as a block forever. A
-- different entry height is a different lap length, redrawn every time,
-- and they drift apart on their own with no packets spent on it.
local function bot_drop_pos()
	return drop_at(DROP_Z + math.random()*thefall_drop_spread);
end

-- back to the top, right now, whole. Nothing in the shaft ever dies of
-- the shaft, so this is a teleport and not a respawn -- see recycle().
local function drop_in(pid)
	return is_faller(pid) and bot_drop_pos() or drop_pos();
end

-- Dig on every map load, while the map is still "loading" so the change
-- rides along inside the map that's about to be sent -- no per-block
-- packets. Nobody's sentence survives a map: the shaft they were falling
-- down is gone, and the new one is dug from scratch.
function mod.before.finish_map_load()
	for i=0,MAX_PLAYERS-1 do
		falling[i] = nil;
		redrop[i] = nil;
	end
	clear_hole();
end

-- Also carve the map that's already up when this module is (re)loaded,
-- but only when nobody's connected (server start): with players on, the
-- thousands of per-block updates would swamp them, so we let the next
-- map load handle it instead.
local function carve_if_empty()
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

--============================= THE FALL =============================--

-- Drop a body back in from the top. Only ever needed for a bot that was
-- shot, since that is the one way anything in here actually dies.
-- spawn_player for what it hands back: alive, full HP, ammo, blocks,
-- grenades, and any scheduled respawn cancelled so nothing yanks it to a
-- tent mid-drop.
local function throw_in(pid)
	spawn_player(pid, drop_in(pid));
end

-- A bot's pause at the bottom before its next drop, drawn fresh every
-- time. This is the whole staggering mechanism: without it every bot's
-- lap is the same fixed length, so any two that ever touch down on the
-- same tick stay glued together from then on.
local function stagger(pid)
	redrop[pid] = get_time() + thefall_bot_delay_min
		+ math.random()*(thefall_bot_delay_max - thefall_bot_delay_min);
end

-- Somebody in the shaft touched down, or took a hit that should have
-- been the end of them. Neither is: patch them up and let go again from
-- a fresh spot at the top. The restock is not generosity, it is the only
-- thing keeping the shaft from becoming a trap -- a faller out of ammo
-- has no way left to kill, and the only door out is a kill.
--
-- set_position rather than spawn_player: they never died, so there is
-- nothing to respawn, and a CreatePlayer here would announce a death
-- that didn't happen. fall_damage.lua's apex follows a set_position
-- down, so the next lap measures from the top and not from wherever
-- they were caught.
local function recycle(pid)
	restock(pid);
	set_position(pid, drop_in(pid));
end

-- pid killed somebody, which is the one way out. Healed, restocked and
-- put back where they would have spawned if none of this had happened.
--
-- falling is cleared FIRST: our own get_spawn_position answers "the top
-- of the shaft" for anyone still marked, so asking before clearing would
-- send them right back down.
local function rescue(pid)
	falling[pid] = nil;
	spawn_player(pid, get_spawn_position(pid));
	server_msg(pid, "You killed your way out. Back in the game.");
end

-- did this kill belong to someone who is falling? Then they just bought
-- their way out. A player is never their own way out: an environmental
-- death reports the victim as its own killer.
local function try_rescue(killer, victim)
	if (killer ~= victim and falling[killer] ~= nil) then
		rescue(killer);
	end
end

-- Where the engine puts someone it is respawning. For anyone in the
-- shaft that is the top of the shaft, which is what turns an ordinary
-- death into a trip down the Fall: the death itself is left completely
-- alone, and only the destination changes.
function mod.get_spawn_position(pid)
	if (falling[pid] ~= nil) then
		return drop_pos();
	end
	return mod.next.get_spawn_position(pid);
end

-- Every death in the game comes through here.
function mod.kill(pid, type, killer)
	-- read before chaining: after it, pid is dead
	local wasalive = is_alive(pid);

	-- killing a corpse extra dead, and the bookkeeping kills behind a
	-- team or gun switch, are nobody's business but the engine's
	if (not wasalive or type >= KILL_TEAMCHANGE) then
		falling[pid] = nil;
		mod.next.kill(pid, type, killer);
		return;
	end

	-- Anything inside the shaft, sentenced player or resident bot, lives
	-- by the same rule, and it turns on who did it.
	--
	-- The shaft itself -- the floor at the bottom, the water, the drop
	-- -- reports the victim as its own killer, and it does not get to
	-- kill anybody. Not chained at all: no feed line, no point, no
	-- respawn timer, no death. They are patched up and go round again.
	-- This is what "in prison" means for both of them, and it is why the
	-- kill feed isn't a wall of bots falling to their deaths.
	--
	-- A bullet is different. That is a real kill and is chained as one,
	-- with everything a kill carries -- which is the entire reason the
	-- bots are down here to be shot at. What it does NOT do is let the
	-- victim out: a player keeps their falling mark, so the respawn it
	-- schedules lands them right back at the top (get_spawn_position),
	-- and a bot is dropped in again after its pause. Being killed in
	-- here costs you your height, not your sentence. The shooter, if
	-- they were falling too, gets the only thing worth having: the door.
	local bot = bot_get(pid);
	local faller = bot ~= nil and bot.data.faller;

	if (falling[pid] ~= nil or faller) then
		if (killer == pid) then
			recycle(pid);
			return;
		end

		mod.next.kill(pid, type, killer);
		try_rescue(killer, pid);
		if (faller) then stagger(pid); end
		return;
	end

	-- another script's bots, which know nothing about any of this and
	-- respawn the way that script meant them to
	if (bot ~= nil) then
		mod.next.kill(pid, type, killer);
		try_rescue(killer, pid);
		return;
	end

	-- An ordinary death, and it counts for everything a death normally
	-- counts for: the feed, the killer's point, the gamemode's own
	-- cleanup (a carried intel dropping where they fell), the respawn
	-- timer. All of it is the engine's, untouched. The only thing this
	-- mode changes is where that respawn lands -- see
	-- get_spawn_position above.
	mod.next.kill(pid, type, killer);
	try_rescue(killer, pid);
	falling[pid] = true;
	server_msg(pid, "You're going into the Fall. Kill someone to get out.");
end

function mod.after.on_join(pid)
	falling[pid] = nil;
	redrop[pid] = nil;
	if (not bot_is_bot(pid)) then
		server_msg(pid, "warning: here your first death drops you into the "
			.."Fall, and only a kill gets you out.");
	end
end

--=============================== BOTS ===============================--
-- Scenery with a pulse: they do nothing but fall, die and fall again, so
-- that whoever is dropping past them always has something to shoot at.
-- The cycle is driven from tick() below rather than from the engine's
-- respawn, so that each drop can be held back by a random moment and the
-- four of them don't fall in formation. They still carry a spawn_at, for
-- the respawns this script isn't the one asking for -- coming back from
-- map-change limbo, most of all.

-- how many fallers there are, how they are split over the two real
-- teams, and which name slots are taken
local function faller_census()
	local n, per, used = 0, {0, 0}, {};

	for i in piditer(PID_BROADCAST) do
		local b = bot_get(i);
		if (b ~= nil and b.data.faller) then
			n = n + 1;
			per[b.team] = per[b.team] + 1;
			-- nil-guarded: a faller left behind by an older build of
			-- this module has no slot, and `used[nil] = true` is a hard
			-- error that would take the tick down every frame from then
			-- on -- with the sweep that should have cleared it already
			-- past
			if (b.data.slot ~= nil) then
				used[b.data.slot] = true;
			end
		end
	end

	return n, per, used;
end

-- A splatted faller does not use the engine's respawn at all: its next
-- drop is timed by hand in tick() below, so this switches the engine's
-- own timer off and leaves the slot dead until then. Humans are left
-- alone -- their death is a real one and should cost what one costs.
--
-- Returning 0 is the documented way to say "don't respawn this one",
-- and it is also the only value that is safe to return from here.
-- get_spawn_time is the one clk in the Lua API that is NOT in seconds:
-- every other one crosses the boundary through push_clk/check_clk
-- (grenade fuses, send_kill's respawn delta), but luaawk.h's
-- lget_spawn_time and cget_spawn_time push and read the raw clk. A
-- `get_time() + 2` returned from here is read as 2938226 NANOSECONDS,
-- lands three decades in the past, and the engine respawns the bot on
-- the very next tick -- which looks exactly like the delay being
-- ignored. 0 means 0 in any unit.
function mod.get_spawn_time(pid)
	local b = bot_get(pid);
	if (b ~= nil and b.data.faller) then
		return 0;
	end
	return mod.next.get_spawn_time(pid);
end

function mod.after.spawn_player(pid)
	-- head first, so they read as falling rather than standing in
	-- mid-air. Once per drop rather than per tick: orientation is
	-- broadcast.
	if (is_faller(pid)) then
		bot_look_toward(pid, {x=0, y=0, z=1});
		return;
	end

	-- A human just spawned, and this is the only moment we are told
	-- about a team switch: on_switch sets the team a player WILL have,
	-- and it isn't theirs until they respawn into it. Their client is
	-- still holding whatever side it was told the fallers were on last
	-- time, which is now the side it thinks it is on -- so it would
	-- refuse to shoot them. Re-announce every faller to that one client
	-- and let send_spawn_player below pick the new opposite.
	--
	-- CreatePlayer is what tells a client somebody changed sides
	-- (spawn_player broadcasts one on every respawn, which is exactly
	-- how a switch reaches everyone else), so this is that same
	-- mechanism, aimed at one viewer. Only for fallers that are up: one
	-- for a bot waiting at the bottom would draw a corpse standing
	-- there until its next drop.
	for i in piditer(PID_BROADCAST) do
		if (is_faller(i) and is_alive(i)) then
			send_spawn_player(pid, get_position(i), get_gun(i),
				get_team(i), get_name(i), i);
		end
	end
end

-- Two jobs a tick: drop the fallers whose wait at the bottom is up, and
-- top the population back up to thefall_bots, one bot per tick. A dead
-- faller still counts towards that (it is only waiting its turn), so
-- this never over-spawns, and bot_create returning nil on a full server
-- or a loading map just means we try again next tick.
function mod.after.tick()
	local now = get_time();

	for i in piditer(PID_BROADCAST) do
		-- a shot bot's pause is up: back on its feet at the top
		if (redrop[i] ~= nil and now >= redrop[i]) then
			redrop[i] = nil;
			throw_in(i);
		end

		if ((falling[i] ~= nil or is_faller(i)) and is_alive(i)) then
			local p = get_position(i);

			-- The catch, and the end of every lap: near enough to the
			-- floor and they are snatched back to the top with clear air
			-- still under them. Nobody in the Fall ever touches the
			-- bottom -- no landing, no impact, no standing about down
			-- there. Checked by height rather than by contact precisely
			-- so that it happens BEFORE contact: waiting for the feet to
			-- land is waiting one tick too long.
			--
			-- Height alone would be a trap for the drop tick itself,
			-- when they are placed at the top with nothing under them
			-- yet -- but the top is nowhere near CATCH_Z, so it can't
			-- fire there.
			if (p.z >= CATCH_Z) then
				recycle(i);

			-- Feet down anywhere else. The top of the shaft is high
			-- above the terrain, so a player with enough air control can
			-- drift out over open ground and come down outside it, from
			-- a height that may not even hurt -- and would then be
			-- walking around a live game while still serving a sentence.
			-- Feet down is feet down; back you go.
			--
			-- Here the drop tick DOES need excluding: freshly placed at
			-- DROP_Z, the physics has not called them airborne yet.
			elseif (not is_airborne(i) and p.z > DROP_Z + 2) then
				recycle(i);
			end
		end
	end

	local n, per, used = faller_census();
	if (n < thefall_bots) then
		-- the thinner side, to keep the real split even -- nothing in
		-- the game can see it (the disguise overwrites the team on the
		-- way out to every client), but an even split keeps both halves
		-- of the damage overrides in use instead of one going cold.
		--
		-- the name must not leak it either: "Faller-Blue-1" rendered in
		-- green is the one thing that would give the trick away.
		local slot = 1;
		while (used[slot]) do slot = slot + 1; end

		bot_create{
			team = per[1] <= per[2] and 1 or 2,
			name = "Faller-"..slot,
			gun = 0,
			tool = "gun",
			spawn_at = drop_pos,
			data = {faller=true, slot=slot},
		};
	end
end

--============================= DISGUISE =============================--
-- Every faller is everyone's enemy. A player's team reaches a client in
-- exactly two packets -- CreatePlayer (send_spawn_player) and
-- ExistingPlayer (send_existing_player, sent once per player to whoever
-- is joining) -- so rewriting the team in both, per recipient, is the
-- whole of the illusion. ffa.lua does the same thing to put everybody on
-- opposite sides; this is that trick pointed at four bots.
--
-- What it is NOT is a change of team: server-side the bot is still on
-- team 1 or 2, and the server's own damage rules go by that. So half the
-- time a client shoots what it has been told is an enemy and the server
-- sees a teammate and drops the damage on the floor -- which is worse
-- than no disguise at all, since the bot visibly shrugs off a magazine.
-- on_hit and detonate_grenade below close that hole; between them they
-- are every way one player hurts another.

-- The team a faller must LOOK like to `viewer`: never the viewer's own.
-- Spectators have no side to be an enemy of, so they get the truth.
-- 1-based, the base get_team() and send_spawn_player() both speak.
local function enemy_of(viewer, real)
	local t = get_team(viewer);

	if (t ~= 1 and t ~= 2) then
		return real;
	end
	return t == 1 and 2 or 1;
end

-- All four hooks below sit in the LATE chain, i.e. underneath every
-- other module and just above the C implementation. That is deliberate,
-- and it is what makes this compose with the rest of the server:
--
--   * the two send_ hooks fan a broadcast out into one packet per
--     recipient. Being last means no other module ever has to deal with
--     that form -- they still see the single broadcast they expect.
--   * on_hit is a damage rule, and it must be the LAST word on damage,
--     never the first. shotgun_are_grenade_launchers.lua swallows
--     shotgun pellet hits up in the std chain so that only its grenade
--     hurts; from down here we never see a swallowed hit, so pellets
--     stay harmless against fallers exactly like against anyone else.
--     Same for toggles.lua's nodamage cap. Put this in std and it would
--     quietly hand shotguns their pellet damage back, but only against
--     half the bots.

-- CreatePlayer. Fan the broadcast out by hand so each client can be told
-- a different team; everyone else's spawns go out untouched, as one
-- broadcast, the way they came in.
function mod.late.send_spawn_player(pid, pos, gun, team, name, from)
	if (not is_faller(from)) then
		return mod.late.next.send_spawn_player(pid, pos, gun, team, name, from);
	end

	for i in piditer(pid) do
		mod.late.next.send_spawn_player(i, pos, gun, enemy_of(i, team), name, from);
	end
end

-- ExistingPlayer, i.e. what a joining client is told about everyone
-- already here. Same rewrite -- and mind the base: this team is 0-based
-- (luaawk.h's csend/lsend_existing_player pass it raw both ways) while
-- send_spawn_player's above is 1-based. Same concept, two bases, no
-- warning in the apidoc.
function mod.late.send_existing_player(pid, team, gun, tool, score, color, name, from)
	if (not is_faller(from)) then
		return mod.late.next.send_existing_player(pid, team, gun, tool, score,
			color, name, from);
	end

	for i in piditer(pid) do
		mod.late.next.send_existing_player(i, enemy_of(i, team + 1) - 1, gun,
			tool, score, color, name, from);
	end
end

-- Bullets and the spade. The stock on_hit (funcs_event.c) drops any hit
-- where shooter and target share a team, which for a disguised faller is
-- half of them; deal the damage ourselves in that case. The damage and
-- the kill type are the stock ones -- get_hit_damage is what the engine
-- would have asked for, and the type mapping is lifted from ffa.lua,
-- which overrides on_hit for the same reason.
--
-- Still chained afterwards rather than returned out of: the C on_hit
-- will drop this hit on the same team check that made it our problem,
-- so it costs nothing, and anything below us keeps seeing the hit.
function mod.late.on_hit(pid, type, hitPlayer)
	if (is_faller(hitPlayer) and get_team(pid) == get_team(hitPlayer)) then
		damage_player_directional(
			hitPlayer,
			get_hit_damage(pid, type),
			get_position(pid),
			type == HIT_MELEE and 2 or (type == HIT_HEAD and 1 or 0),
			pid
		);
	end
	mod.late.next.on_hit(pid, type, hitPlayer);
end

-- Grenades, which the server resolves itself and gates on the team the
-- same way. main.c's detonate_grenade skips every player on the
-- thrower's team; this is that loop again, run over the fallers it
-- skipped, with its numbers: within 16 on each axis, a clear line to the
-- body, 4096/d2 damage with d2 floored at 1 (safe_sqr_dist3). If those
-- ever drift apart, a grenade will hurt half the fallers differently
-- from the other half -- which is exactly the tell this section exists
-- to remove.
local function blast_fallers(at, team, from)
	for i in piditer(PID_BROADCAST) do
		if (is_faller(i) and is_alive(i) and get_team(i) == team) then
			local p = get_position(i);
			local dx, dy, dz = p.x-at.x, p.y-at.y, p.z-at.z;

			if (math.abs(dx) < BLAST_REACH and math.abs(dy) < BLAST_REACH
			    and math.abs(dz) < BLAST_REACH
			    -- line of sight is symmetric, so ask from the bot's end:
			    -- bot_can_see wants a pid for the eye it looks out of
			    and bot_can_see(i, at)) then
				local d2 = dx*dx + dy*dy + dz*dz;
				if (d2 == 0) then d2 = 1; end

				damage_player_directional(i, BLAST_SCALE/d2, at, KILL_GRENADE, from);
			end
		end
	end
end

function mod.late.detonate_grenade(index)
	-- read first: chaining removes the grenade
	local at = get_grenade_position(index);
	local team = get_grenade_team(index);
	local from = get_grenade_pid(index);

	mod.late.next.detonate_grenade(index);
	blast_fallers(at, team, from);
end

-- collect first, then destroy: bot_destroy disconnects the slot, and
-- mutating the player set mid-piditer would skip some
local function sweep_fallers()
	local doomed = {};
	for i in piditer(PID_BROADCAST) do
		local b = bot_get(i);
		if (b ~= nil and b.data.faller) then
			doomed[#doomed+1] = i;
		end
	end
	for _,i in ipairs(doomed) do
		bot_destroy(i);
	end
end

function mod.on_load()
	if (bot_create == nil) then
		error("the_fall needs lib_bot loaded first "
			.."(config.lua loads it, or: lsdctl load lib_bot the_fall)", 0);
	end
	sweep_fallers(); -- clear fallers from a previous life; tick respawns them
	carve_if_empty();
end

function mod.on_unload()
	sweep_fallers();
end

return mod;
