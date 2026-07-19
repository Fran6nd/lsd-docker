-- hostage.lua -- The Hostage gamemode. Each team has a hostage (a
-- lib_bot) held prisoner at the enemy tent, standing with a block in
-- its team's color. Come closer than hostage_engage_dist and it walks
-- after you (hostages are too weary to run); stray past
-- hostage_lose_dist (or die) and it stops where it stands. Walking it
-- into its own tent scores its team a point, and the keepers
-- executing it hands its team a point too; either way the hostage
-- respawns back at the enemy tent.
--
-- It plays like team deathmatch over ctf's bones: ctf is loaded
-- underneath for tents, spawns and team score, but the flags are
-- stashed in the sky where nobody can reach them, the masterlist
-- advertises "Hostage", and joining players get told the rules.
-- Works standalone (LSD_GAMEMODE=hostage) or loaded on top of a
-- running ctf server.
--
-- LIMITATIONS:
-- * Scoring rides capture_intel -- the only Lua-reachable way to move
--   the team score -- so clients play the intel-capture fanfare and
--   the scorer gets ctf's +10 personal score. The enemy intel state
--   is snapshotted and restored around each award.
-- * Flags are hidden, not gone: the protocol has no TDM mode, so
--   clients still believe they are in ctf and may draw flag markers
--   (pointing at a map corner, high in the sky). Anything that
--   re-places intel (map load, ctf hooks) is re-stashed on the next
--   tick, so a flag can flicker in for one tick. On unload the flags
--   stay stashed until ctf next relocates them or the map changes.
-- * Needs a mode with tents: on maps/modes without them the hostages
--   simply never spawn (creation retries every tick).
-- * Escorting is straight-line walking with a hop -- no pathfinding.
--   Hostages fall off cliffs, drown, and take fall damage; route
--   your rescue accordingly. The tent spawn height is a guess
--   (tent z - 2.5), so they may drop a step on odd tents.
-- * All lib_bot limitations apply: hostages use two player slots,
--   kicks silently fail on them, and this script must be reloaded
--   together with the lib (lsdctl load lib_bot hostage).
--
-- DEPENDENCIES: needs lib_bot and a tent gamemode (ctf) loaded
-- FIRST -- config.lua does this. The script never load()s them
-- itself: a load() at file-execution time re-registers an
-- already-loaded module, which points one of its hook's `next` at
-- itself and stack-overflows the tick chain. We only check the
-- globals those modules export and bail cleanly if they are missing.
local mod = init_mod();

getcfg("hostage_engage_dist", 5);  -- follow when a teammate gets this close
getcfg("hostage_lose_dist", 10);   -- stop when the escort is this far

-- flags get stashed here: negative z is high in the sky, unreachable,
-- and safely non-solid to everything (is_solid() guards z < 0)
local HIDDEN = {x=0.5, y=0.5, z=-100};

-- every AoS map is 512x512, so the middle is here
local CENTER = {x=256, y=256};

local byteam = {}; -- team -> hostage pid

local welcome_msg = "This is HOSTAGE mode: free the hostage held at "
	.."the enemy tent. Get close and it follows; walk it home for a point.";
local thanks_msg = "Thanks for picking me up!";
local saved_msg = "%s team brought back an hostage !";
local executed_msg = "%s team executed an hostage ! +1 for %s";

local function length2(vec)
	return math.sqrt(vec.x*vec.x + vec.y*vec.y);
end

local function within_cylinder(pos, cylinderpos, radius, bottom, top)
	pos.x = pos.x - cylinderpos.x;
	pos.y = pos.y - cylinderpos.y;
	pos.z = pos.z - cylinderpos.z;

	if (length2(pos) > radius or pos.z < top or pos.z > bottom) then
		return false;
	end

	return true;
end

-- where team's hostage is held: the enemy tent
local function post(team)
	local t = get_tentloc()[3 - team];
	if (t == nil) then
		return nil;
	end
	-- tent z is ground level, internal player pos rides ~2.25 above
	return {x=t.x, y=t.y, z=t.z - 2.5};
end

-- capture_intel is the only Lua-reachable way to move the team score,
-- but it also yanks the enemy team's intel around (the C side clears
-- its carrier, ctf's after-hook relocates it); snapshot the intel
-- state and put it back afterwards
local function award_point(to)
	local enemy = 3 - get_team(to);
	local saved = get_intelloc()[enemy];

	capture_intel(to, get_team_score(get_team(to))+1 >= get_max_score());

	if (type(saved) == "number") then
		pickup_intel(saved);
	elseif (type(saved) == "table") then
		move_intel(enemy, saved);
	end
end

local function think(pid)
	local me = bot_get(pid);
	local mem = me.data;

	-- saved: the hostage stands in its own team's tent
	local home = get_tentloc()[me.team];
	if (home ~= nil and within_cylinder(get_position(pid), home, 3, 1, -4)) then
		award_point(mem.escort or pid);
		server_msg(PID_BROADCAST,
			string.format(saved_msg, get_team_name(me.team)));

		mem.escort = nil;
		bot_heal(pid);
		bot_teleport(pid, post(me.team));
		bot_stop(pid);
		return;
	end

	-- keep the escort until they die, defect or stray too far
	local escort = mem.escort;
	if (escort ~= nil and (not is_alive(escort)
	    or get_team(escort) ~= me.team
	    or bot_distance_to(pid, escort) > hostage_lose_dist)) then
		escort = nil;
	end

	if (escort == nil) then
		escort = bot_nearest_player(pid,
			{team=me.team, within=hostage_engage_dist});
		if (escort ~= nil) then
			-- a private word from the hostage to its rescuer
			send_chat(escort, thanks_msg, 0, pid);
		end
	end
	mem.escort = escort;

	if (escort == nil) then
		bot_stop(pid); -- hostages wait standing, no cowering
		return;
	end

	if (bot_distance_to(pid, escort) <= 1) then
		bot_stop(pid); -- close enough, don't headbutt the escort
		return;
	end

	bot_look_at(pid, get_position(escort));

	local v = get_velocity(pid);
	bot_walk(pid, {
		forward = true,
		-- no sprint: hostages are too weary to run
		-- hop over whatever demoncore's step-up can't clear
		jump = v.x*v.x + v.y*v.y < 0.0004 and not is_airborne(pid),
	});
end

function mod.after.tick()
	-- keep the flags stashed no matter who places them back (ctf
	-- does on map load, after captures, and on some block actions)
	for team=1,2 do
		local intel = get_intelloc()[team];
		if (type(intel) == "table" and intel.z > HIDDEN.z + 10) then
			move_intel(team, HIDDEN);
		end
	end

	for team=1,2 do
		-- adopt before creating: if a tagged hostage of this team
		-- already exists (lost byteam, earlier instance), take it
		-- over instead of spawning a duplicate
		if (byteam[team] == nil) then
			for i in piditer(PID_BROADCAST) do
				local b = bot_get(i);
				if (b ~= nil and b.data.hostage and b.team == team) then
					b.think = think;
					b.spawn_at = function() return post(team); end;
					byteam[team] = i;
					break;
				end
			end
		end

		if (byteam[team] == nil and post(team) ~= nil) then
			byteam[team] = bot_create{
				team = team,
				name = "Hostage "..get_team_name(team),
				tool = "block",
				block_color = get_team_color(team),
				spawn_at = function() return post(team); end,
				think = think,
				data = {hostage=true},
			};
		end
	end
end

-- every spawn (the C core sets orientation from team), turn the
-- hostage to look across the map at its center. Keyed off the bot's
-- own tag, not byteam: the very first spawn fires inside bot_create,
-- before byteam is assigned. think() leaves orientation alone while
-- idle, so it keeps facing in until someone comes to escort it
function mod.after.spawn_player(pid)
	local b = bot_get(pid);
	if (b ~= nil and b.data.hostage) then
		bot_look_at(pid, {x=CENTER.x, y=CENTER.y, z=get_position(pid).z});
	end
end

-- keepers executing their hostage hands its team the point
function mod.after.kill(pid, ktype, killer)
	local team = byteam[1] == pid and 1 or byteam[2] == pid and 2 or nil;
	if (team == nil) then
		return;
	end

	bot_get(pid).data.escort = nil;

	if (ktype <= 3 and killer ~= pid and get_team(killer) == 3 - team) then
		award_point(pid);
		server_msg(PID_BROADCAST, string.format(executed_msg,
			get_team_name(3 - team), get_team_name(team)));
	end
end

function mod.after.on_join(pid)
	if (not bot_is_bot(pid)) then
		server_msg(pid, welcome_msg);
	end
end

function mod.after.on_disconnect(pid)
	for team=1,2 do
		if (byteam[team] == pid) then
			byteam[team] = nil;
		end
	end
end

local function advertise()
	masterlist_set_gamemode("Hostage");
end

function mod.after.finish_map_load()
	advertise(); -- whoever re-advertised on map change, override them
end

-- loading starts from a clean slate: every hostage a previous life of
-- this script spawned gets removed. Lib bots are identified by their
-- tag or name; peerless players named like hostages (get_ipaddr 0 --
-- impossible for a real client) catch bots from older, lib-less
-- versions whose registry is long gone.
local function sweep_stale_hostages()
	for i in piditer(PID_BROADCAST) do
		local b = bot_get(i);
		if (b ~= nil and (b.data.hostage
		    or string.sub(b.name, 1, 8) == "Hostage ")) then
			bot_destroy(i);
		elseif (b == nil and get_ipaddr(i) == 0 and is_joined(i)
		        and string.sub(get_name(i), 1, 7) == "Hostage") then
			on_disconnect(i);
		end
	end
end

function mod.on_load()
	-- check, never load: erroring here unregisters us cleanly, while
	-- a stray load() would corrupt the callchain (see DEPENDENCIES)
	if (bot_create == nil) then
		error("hostage needs lib_bot loaded first "
			.."(config.lua loads it, or: lsdctl load lib_bot hostage)", 0);
	end

	sweep_stale_hostages();
	advertise();
end

function mod.on_unload()
	for team=1,2 do
		if (byteam[team] ~= nil) then
			bot_destroy(byteam[team]);
		end
	end
end

return mod;
