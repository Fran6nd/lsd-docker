-- hostage.lua -- The Hostage gamemode. Each team has a hostage (a
-- lib_bot) held prisoner at the enemy tent, standing with a block in
-- its team's color. Come closer than hostage_engage_dist and it walks
-- after you (hostages are too weary to run); stray past
-- hostage_lose_dist (or die) and it stops where it stands. Walk it
-- into its own tent to score its team a point, and the keepers
-- executing it hands its team a point too; either way the hostage
-- respawns back at the enemy tent, facing the map center.
--
-- It plays like team deathmatch over ctf's bones: ctf is loaded
-- underneath for tents, spawns and team score, but the flags are
-- stashed in the sky where nobody can reach them, the masterlist
-- advertises "Hostage", and joining players get told the rules.
--
-- COMMUNICATION -- two voices, both localized via lib_l10n:
-- * the hostage itself speaks in chat, attributed to it and rendered
--   in each listener's language: a private "thanks" to a new escort,
--   a public "I'm lost" while stranded, nervous/urging chatter while
--   being walked home, a cheer on arrival and a cry when executed
--   (hostage_say/_to).
-- * the server announces scores as system messages to everyone
--   (l10n_send_chat): a rescue, an execution, and the rules on join.
-- Add a language by dropping another key into the message tables
-- below (en/fr are provided).
--
-- /hostage shows each hostage's status; /hostage reset (needs the
-- "hostage" cap) despawns and respawns them.
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
-- DEPENDENCIES: needs lib_bot, lib_l10n, and a tent gamemode (ctf)
-- loaded FIRST -- config.lua does this. The script never load()s them
-- itself: a load() at file-execution time re-registers an
-- already-loaded module, which points one of its hook's `next` at
-- itself and stack-overflows the tick chain. We only check the
-- globals those modules export and bail cleanly if they are missing.
local mod = init_mod();

getcfg("hostage_engage_dist", 5);    -- follow when a teammate gets this close
getcfg("hostage_lose_dist", 10);     -- stop when the escort is this far
getcfg("hostage_home_radius", 3);    -- how close to home counts as a rescue
getcfg("hostage_tent_radius", 4);    -- how close to a tent counts as "safe"
getcfg("hostage_lost_interval", 10); -- seconds between "I'm lost" calls
getcfg("hostage_chatter_interval", 8);-- seconds between while-escorted lines
getcfg("hostage_scared_dist", 8);    -- enemy within this = nervous chatter

-- flags get stashed here: negative z is high in the sky, unreachable,
-- and safely non-solid to everything (is_solid() guards z < 0)
local HIDDEN = {x=0.5, y=0.5, z=-100};

-- every AoS map is 512x512, so the middle is here
local CENTER = {x=256, y=256};

local byteam = {}; -- team -> hostage pid

-- Player-facing text. Server announcements (system messages) and the
-- hostage's own lines (chat attributed to it) share the same table
-- shape: one string per language, %(key) filled from an interp table.
local welcome_msg = {
	en="This is HOSTAGE mode: free the hostage held at the enemy tent. "
		.."Get close and it follows; walk it home to score.",
	fr="Mode OTAGE : libere l'otage retenu au camp ennemi. Approche-toi "
		.."et il te suit ; ramene-le chez toi pour marquer.",
};
local thanks_msg = {
	en="Thanks for picking me up!",
	fr="Merci de me sauver !",
};
local saved_msg = {
	en="%(hero) brought the %(team) hostage home! +1 %(team)",
	fr="%(hero) a ramene l'otage %(team) ! +1 %(team)",
};
local executed_msg = {
	en="%(killer) executed the %(team) hostage! +1 %(team)",
	fr="%(killer) a execute l'otage %(team) ! +1 %(team)",
};
local lost_msgs = {
	{en="I'm lost! Somebody come get me!",
	 fr="Je suis perdu ! Que quelqu'un vienne me chercher !"},
	{en="Hello? Anyone? I'm stranded out here!",
	 fr="Ohe ? Il y a quelqu'un ? Je suis coince ici !"},
	{en="Help, I don't know the way home!",
	 fr="A l'aide, je ne trouve pas le chemin du retour !"},
};
-- the hostage's own reactions: a cheer at home, a cry when executed,
-- and while-escorted chatter (nervous if a foe is near, else urging)
local saved_cheer_msg = {
	en="Home at last -- thank you!",
	fr="Enfin rentre -- merci !",
};
local executed_cry_msg = {
	en="Argh -- they got me!",
	fr="Argh -- ils m'ont eu !",
};
local nervous_msgs = {
	{en="They're right behind us!", fr="Ils sont juste derriere nous !"},
	{en="Hurry, enemies close!", fr="Vite, des ennemis tout pres !"},
	{en="Watch out -- keepers!", fr="Attention -- des gardiens !"},
};
local urge_msgs = {
	{en="This way, we're almost there!", fr="Par ici, on y est presque !"},
	{en="Keep going, take me home!", fr="Continue, ramene-moi a la base !"},
	{en="Don't leave me behind!", fr="Ne me laisse pas derriere !"},
};

-- the hostage speaks, attributed to it (from = its pid), each listener
-- served in their own language
local function hostage_say(hpid, msgtab, interptab)
	for i in piditer(PID_BROADCAST) do
		if (not bot_is_bot(i)) then
			send_chat(i, l10n_get_str_pid(i, msgtab, interptab or {}), 0, hpid);
		end
	end
end

local function hostage_say_to(hpid, target, msgtab, interptab)
	send_chat(target, l10n_get_str_pid(target, msgtab, interptab or {}), 0, hpid);
end

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

-- one shared tent test (within_cylinder mutates pos, so callers hand
-- it a fresh get_position each time)
local function near_tent(pos, tentpos, radius)
	return tentpos ~= nil and within_cylinder(pos, tentpos, radius, 2, -4);
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

-- standing near either tent (its spawn post, or home)?
local function near_a_tent(pid)
	local t = get_tentloc();
	return near_tent(get_position(pid), t[1], hostage_tent_radius)
	    or near_tent(get_position(pid), t[2], hostage_tent_radius);
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

	-- reached home: score for whoever walked it in (falling back to a
	-- remembered hero if the escort died on the doorstep), reset to post
	if (near_tent(get_position(pid), get_tentloc()[me.team], hostage_home_radius)) then
		local hero = mem.escort or mem.hero or pid;

		hostage_say(pid, saved_cheer_msg); -- the hostage's own relief
		award_point(hero);
		l10n_send_chat(PID_BROADCAST, saved_msg,
			{hero=get_name(hero), team=get_team_name(me.team)});

		mem.escort = nil;
		mem.hero = nil;
		mem.thanked = nil;
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
	end
	mem.escort = escort;

	if (escort == nil) then
		-- idle: stand guard while at a tent (also the fresh-spawn
		-- pose), but if stranded in the open, crouch and call out
		-- for a rescuer in general chat every so often
		if (near_a_tent(pid)) then
			bot_stop(pid);
		else
			bot_crouch(pid);
			if (get_time() - (mem.lastlost or 0) >= hostage_lost_interval) then
				mem.lastlost = get_time();
				hostage_say(pid, lost_msgs[math.random(#lost_msgs)]);
			end
		end
		return;
	end

	-- greet a newly-acquired escort once, and remember them as the
	-- hero to credit even if they die in the final stretch
	if (mem.thanked ~= escort) then
		mem.thanked = escort;
		hostage_say_to(pid, escort, thanks_msg);
	end
	mem.hero = escort;

	-- chatter while being walked home: nervous if a foe is near,
	-- otherwise urging the escort onward
	if (get_time() - (mem.lastchatter or 0) >= hostage_chatter_interval) then
		mem.lastchatter = get_time();
		if (bot_nearest_player(pid, {team=3-me.team, within=hostage_scared_dist}) ~= nil) then
			hostage_say(pid, nervous_msgs[math.random(#nervous_msgs)]);
		else
			hostage_say(pid, urge_msgs[math.random(#urge_msgs)]);
		end
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
	local b = bot_get(pid);
	if (b == nil or not b.data.hostage) then
		return;
	end

	b.data.escort = nil;
	b.data.hero = nil;
	b.data.thanked = nil;

	-- only a real execution by the enemy (gun/melee/grenade), not a
	-- fall, a drowning or a team/gun switch
	if (ktype <= 3 and killer ~= pid and get_team(killer) == 3 - b.team) then
		hostage_say(pid, executed_cry_msg); -- a last word before it drops
		award_point(pid);
		l10n_send_chat(PID_BROADCAST, executed_msg,
			{killer=get_name(killer), team=get_team_name(b.team)});
	end
end

function mod.after.on_join(pid)
	if (not bot_is_bot(pid)) then
		l10n_send_chat(pid, welcome_msg);
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
	if (l10n_send_chat == nil) then
		error("hostage needs lib_l10n loaded first", 0);
	end

	sweep_stale_hostages();
	advertise();
	-- catch anyone already connected up on the rules (on a fresh boot
	-- there is nobody yet, so this is a no-op then)
	l10n_send_chat(PID_BROADCAST, welcome_msg);
end

function mod.on_unload()
	for team=1,2 do
		if (byteam[team] ~= nil) then
			bot_destroy(byteam[team]);
		end
	end
end

-- one status line per hostage: whose it is, what it's doing, how far
-- from home it still is
local function hostage_status_line(team)
	local name = get_team_name(team);
	local hpid = byteam[team];

	if (hpid == nil) then
		return name.." hostage: not spawned (no tents?)";
	end
	if (not is_alive(hpid)) then
		return name.." hostage: down, respawning";
	end

	local mem = bot_get(hpid).data;
	local home = get_tentloc()[team];
	local dist = home ~= nil and math.floor(bot_distance_to(hpid, home)) or -1;

	local state;
	if (mem.escort ~= nil and is_alive(mem.escort)) then
		state = "following "..get_name(mem.escort);
	elseif (near_a_tent(hpid)) then
		state = "waiting at a tent";
	else
		state = "stranded";
	end

	return string.format("%s hostage: %s (%d blocks from home)",
		name, state, dist);
end

local function reset_hostages()
	for team=1,2 do
		if (byteam[team] ~= nil) then
			bot_destroy(byteam[team]); -- our on_disconnect clears byteam
			byteam[team] = nil;        -- and clear now so tick respawns it
		end
	end
end

-- /hostage [reset] -- status is open to all; reset needs the hostage cap
local cmd = {name="hostage", fakepid=true, usage="[reset]",
	desc="Show hostage status, or 'reset' them (needs the hostage cap)."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv <= 1);

	if (argv[1] == "reset") then
		if (not has_cap(pid, "hostage")) then
			server_msg(pid, "you lack the 'hostage' cap");
			return;
		end
		reset_hostages();
		server_msg(pid, "hostages reset");
		return;
	end

	for team=1,2 do
		server_msg(pid, hostage_status_line(team));
	end
end
register_command(cmd, mod);

return mod;
