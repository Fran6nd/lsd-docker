-- the_fall.lua -- Death drops you down the Fall; a kill on the way buys you back
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Nobody just dies here. Every death instead puts you back on your feet
-- at the top of a bottomless shaft dug through the middle of the map --
-- at a random spot well clear of its walls -- and lets go. You keep your
-- gun on the way down: kill anyone before you hit the bottom and you are
-- teleported straight back to the spot you died on, restocked. Miss, and
-- the landing is the death you dodged.
--
-- The kill is HELD, not scored, while you fall (same trick as
-- grenades_teleport_to_eol_fall.lua, which this script replaces): the
-- shot that dropped you never kills you, it hands you to the shaft. The
-- landing at the bottom is then rewritten into that shot -- the killer's
-- name, their weapon, their one point, several seconds late. So a kill
-- counts exactly once, and redeeming yourself on the way down doesn't
-- just save you, it robs them of it. Get shot out of the air instead and
-- the kill belongs to whoever did that, not to whoever threw you in.
--
-- Bots ride the shaft permanently, thefall_bots_per_team of them on each
-- side, so whichever team you are on there is always an enemy falling
-- with you. They fall, splat, wait out a random second or three at the
-- bottom so the four of them never drop in formation, and go again --
-- which costs a steady trickle of fall deaths in the kill feed. Turn the
-- count down if it drowns out the real ones.
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
-- bots permanently riding the shaft, per team. Two a side means every
-- faller has enemies to shoot at whichever team they are on
getcfg("thefall_bots_per_team", 2);
-- seconds a splatted bot waits at the bottom before the next drop, drawn
-- fresh each time. Without the jitter they would all fall in lockstep:
-- every bot's cycle is the same fixed drop, so any two that ever splat
-- on the same tick stay glued together from then on
getcfg("thefall_bot_delay_min", 1);
getcfg("thefall_bot_delay_max", 3);
-- how long after a rescue the landing is on the house (see damage_player)
getcfg("thefall_grace", 2);

local CX = thefall_center_x;
local CY = thefall_center_y;
local R  = thefall_diameter / 2;
local R2 = R * R;
-- radius the drop points are picked inside: the shaft minus the margin,
-- floored at a point so a silly margin can't invert it
local DROP_R = math.max(R - thefall_edge_margin, 0.5);

-- z 0..62 is carved; z 63 is left as the floor they splat onto
local DIG_Z_BOTTOM = 62;
-- where a dropped player appears: the top of the shaft
local DROP_Z = 1;
-- KillType: <4 credits the killer; 4 = fall, and every other
-- environmental death; 5+ is team/gun change bookkeeping
local KILL_FALL = 4;
local KILL_TEAMCHANGE = 5;

local no_build_msg = "You can't build in the Fall.";

-- everyone currently on their way down:
--   falling[pid] = {at=<where they died>, killer=<pid>, type=<KillType>}
-- i.e. where a kill scored on the way down sends them back to, and the
-- kill that is owed at the bottom if they don't score one. Bots ride the
-- shaft too, but they owe nobody anything, so they never appear here.
local falling = pid_connected_table();
-- rescued players whose next landing must not hurt (see damage_player)
local grace = pid_connected_table();
-- splatted bots waiting at the bottom: redrop[pid] = when to drop it in
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

-- a random point at the top of the shaft, uniform over the disc of
-- radius DROP_R: the sqrt undoes the area bias a flat random radius has,
-- which would bunch everyone into the middle
local function drop_pos()
	local ang = math.random() * 2 * math.pi;
	local rad = DROP_R * math.sqrt(math.random());

	return {x = CX + rad*math.cos(ang),
	        y = CY + rad*math.sin(ang),
	        z = DROP_Z};
end

-- Dig on every map load, while the map is still "loading" so the change
-- rides along inside the map that's about to be sent -- no per-block
-- packets. Debts don't survive a map: the shaft everyone was falling
-- down is gone.
function mod.before.finish_map_load()
	for i=0,MAX_PLAYERS-1 do
		falling[i] = nil;
		grace[i] = nil;
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

-- Put pid on their feet at the top of the shaft and let go.
--
-- spawn_player rather than set_position, for all of what it hands back:
-- full HP (whoever arrives here is on 0 and never got killed for it),
-- ammo, blocks, grenades -- and it clears any respawn the engine has
-- scheduled, so nobody gets yanked to their tent mid-drop.
local function throw_in(pid)
	spawn_player(pid, drop_pos());
end

-- pid scored a kill on the way down: back to where they died, whole, and
-- the kill that was waiting for them at the bottom is written off.
local function rescue(pid)
	local back = falling[pid].at;

	falling[pid] = nil;
	restock(pid);
	set_position(pid, back);
	grace[pid] = get_time() + thefall_grace;
	server_msg(pid, "Redeemed -- back where you fell.");
end

-- did this kill belong to someone who is falling? Then they just bought
-- their way out. A player is never their own way out: an environmental
-- death reports the victim as its own killer.
local function try_rescue(killer, victim)
	if (killer ~= victim and falling[killer] ~= nil) then
		rescue(killer);
	end
end

-- A rescued player was teleported, not falling -- but fall_damage.lua
-- measures a drop from the apex it tracks, which is still the top of the
-- shaft, so it would splat them the instant they touch ground. Swallow
-- the environment for a moment after a rescue.
--
-- Kill type 4 is the environment: BOTH stock hazards report it, so this
-- one branch covers both.
--
--   * fall_damage.lua  -- damage_player(i, damage, 4, i) on landing
--   * water_damage.lua -- damage_player(i, damage, 4, i) per second of
--                         wading, on maps whose meta sets water_damage
--
-- The window is short and self-clearing: fall_damage.lua resets its own
-- apex on that first landing, so one swallowed hit is all it ever takes.
function mod.damage_player(pid, hp, type, from)
	if (type == KILL_FALL and grace[pid] ~= nil) then
		if (get_time() < grace[pid]) then
			return;
		end
		grace[pid] = nil;
	end
	mod.next.damage_player(pid, hp, type, from);
end

-- Every death in the game comes through here, and this is where it is
-- decided whether it is a death at all.
function mod.kill(pid, type, killer)
	-- read before chaining anything: after it, pid is dead and moved on
	local wasalive = is_alive(pid);
	local at = wasalive and get_position(pid) or nil;
	local debt = falling[pid];

	-- killing a corpse extra dead, and the bookkeeping kills behind a
	-- team or gun switch, drop nobody down anything
	if (not wasalive or type >= KILL_TEAMCHANGE) then
		falling[pid] = nil;
		mod.next.kill(pid, type, killer);
		return;
	end

	-- Someone already in the shaft. If this is the landing, the Fall
	-- collects: the kill it has been holding since the top is paid out
	-- now, to the player who threw them in and under the weapon that did
	-- it, so what the feed shows is the shot that started all this and
	-- not a fall. (Only if that player is still here -- a slot that has
	-- gone quiet since then may already belong to somebody else.)
	-- Anything else -- shot out of the air -- is a normal kill and
	-- belongs to whoever landed it, not to whoever threw them in.
	if (debt ~= nil) then
		falling[pid] = nil;
		if (type == KILL_FALL and killer == pid and is_joined(debt.killer)) then
			type = debt.type;
			killer = debt.killer;
		end
		mod.next.kill(pid, type, killer);
		try_rescue(killer, pid);
		return;
	end

	-- Bots are furniture: nothing is owed for them, and none of them can
	-- shoot its way back out, so they die where they are like anything
	-- else. Ours then lie at the bottom for a randomly drawn moment
	-- before tick() drops them in again; any other script's bots just
	-- respawn the way that script meant them to.
	local bot = bot_get(pid);
	if (bot ~= nil) then
		mod.next.kill(pid, type, killer);
		try_rescue(killer, pid);
		if (bot.data.faller) then
			redrop[pid] = get_time() + thefall_bot_delay_min
				+ math.random()*(thefall_bot_delay_max - thefall_bot_delay_min);
		end
		return;
	end

	-- An ordinary death, and the whole point of the mode: the kill is
	-- NOT chained. Nobody died, nobody scored, no feed line, no respawn
	-- timer -- the shot is written down and the body is dropped down the
	-- shaft to find out whether it was ever a kill at all.
	--
	-- after_player_destroy is still owed to the gamemode: it is what
	-- makes a carried intel drop, and it has to drop HERE, where they
	-- were shot, rather than at the bottom of the pit where nobody can
	-- pick it up again. ctf.lua and babel.lua both hang their try_drop
	-- off it (arena.lua only recounts the living, which is unchanged),
	-- and it is the only public way to ask for that cleanup -- try_drop
	-- itself is a local in each of them.
	--
	-- nil-checked because core.lua only publishes a global for an event
	-- some loaded module hooks: no global here means nothing is
	-- listening, and so nothing to tell.
	falling[pid] = {at=at, killer=killer, type=type};
	if (after_player_destroy ~= nil) then
		after_player_destroy(pid);
	end
	throw_in(pid);
	try_rescue(killer, pid);
	server_msg(pid, "Into the Fall. Kill someone before you land, or that death counts.");
end

function mod.after.on_join(pid)
	falling[pid] = nil;
	grace[pid] = nil;
	redrop[pid] = nil;
	if (not bot_is_bot(pid)) then
		server_msg(pid, "warning: here dying drops you down the Fall. "
			.."Kill on the way down and it never happened.");
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

local function faller_count(team)
	local n = 0;
	for i in piditer(PID_BROADCAST) do
		local b = bot_get(i);
		if (b ~= nil and b.data.faller and b.team == team) then
			n = n + 1;
		end
	end
	return n;
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

-- head first, so they read as falling rather than standing in mid-air.
-- Once per drop rather than per tick: orientation is broadcast.
function mod.after.spawn_player(pid)
	local b = bot_get(pid);
	if (b ~= nil and b.data.faller) then
		bot_look_toward(pid, {x=0, y=0, z=1});
	end
end

-- Two jobs a tick: drop the fallers whose wait at the bottom is up, and
-- top the population back up to thefall_bots_per_team a side, one bot
-- per tick. A dead faller still counts towards that (it is only waiting
-- its turn), so this never over-spawns, and bot_create returning nil on
-- a full server or a loading map just means we try again next tick.
function mod.after.tick()
	local now = get_time();

	for i in piditer(PID_BROADCAST) do
		if (redrop[i] ~= nil and now >= redrop[i]) then
			redrop[i] = nil;
			throw_in(i);
		end
	end

	for team=1,2 do
		local n = faller_count(team);
		if (n < thefall_bots_per_team) then
			bot_create{
				team = team,
				name = "Faller-"..get_team_name(team).."-"..n,
				gun = 0,
				tool = "gun",
				spawn_at = drop_pos,
				data = {faller=true},
			};
		end
	end
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
