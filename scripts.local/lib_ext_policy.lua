-- lib_ext_policy.lua -- What a missing protocol extension costs a client
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- lib_ext announces what this server speaks and records what each
-- client speaks back. It does not care what the answer is. This does:
-- it puts a price on each extension, from none at all up to not being
-- allowed to play.
--
-- THREE LEVELS, and every extension has one:
--
--   EXT_APPLIED      silent. The extension is announced and used by
--                    whoever has it; a client without it is never told
--                    and never hindered.
--   EXT_RECOMMENDED  the default. A client without it is told what it
--                    is missing and what that costs, and told again
--                    every ext_policy_warn_interval for as long as it
--                    is still missing. Nothing is withheld -- the point
--                    is to tell a player why their screen looks
--                    plainer than someone else's, and to find out what
--                    clients really implement.
--   EXT_REQUIRED     a client without it cannot leave spectator. It is
--                    told what is missing and that its client needs
--                    updating -- whenever it tries to join, and on the
--                    same interval while it sits there, since a player
--                    who gave up on the menu still needs to know why.
--
-- One message per round either way, and the worse news wins: a client
-- that cannot play at all is not also told about cosmetics.
--
-- Set them in config.lua BEFORE this module loads. The default covers
-- every extension at once; ext_policy names the exceptions:
--
--   ext_policy_default = "recommended"
--   ext_policy = {
--       [0x32] = "required",   -- Flashlight, and only it
--       [192]  = "applied",    -- Player Limit, never mentioned
--   }
--
-- Names, not the EXT_* constants: those are globals this module creates
-- when it loads, and config.lua runs before that, so EXT_REQUIRED there
-- is nil and the entry disappears. In Lua that runs after the load,
-- either spelling works.
--
-- Names for the messages come from lib_ext's registry, which is why
-- ext_register takes a title.
--
-- A POLICY ON AN EXTENSION NOBODY REGISTERED DOES NOTHING, loudly. It
-- is the worst failure this module could have: requiring an id this
-- server never announces would mean no client can ever satisfy it, and
-- every player sits in spectator with no way out -- from one typo in a
-- config table. So the question is never asked that way round. Verdicts
-- walk lib_ext's registry and consult the policy per registered id, so
-- an id nothing registered is never consulted and cannot fail anybody;
-- the audit on the first tick only says so in the log.
--
-- BOTS ARE NOT CLIENTS and are exempt, which is not a special case so
-- much as the absence of one: there is nothing on the other end of a
-- bot to ask. lib_bot's bots reach on_join by calling it (lib_bot.lua:
-- 120), so without this every hostage and every faller would be frozen
-- in spectator and both gamemodes would stop working. Two tests, either
-- of which exempts:
--
--   bot_is_bot(pid)      lib_bot saying so, when it is loaded
--   get_ipaddr(pid) == 0 no ENet peer at all (lua.c:1087-1096 answers 0
--                        rather than failing), which covers a bot from
--                        any other source, and anything else holding a
--                        player id with nobody behind it
--
-- WHAT COUNTS AS AN ANSWER. ext_supported is nil both for a client that
-- said "not that one" and for one that has not spoken yet, so a verdict
-- cannot be read off it alone -- see ext_replied. A client gets
-- ext_policy_grace seconds from connecting to answer; until then it is
-- undecided, and an undecided client is treated as failing a
-- requirement but is not told anything, because there is nothing to
-- tell it yet and it has very likely just not got there.
--
-- Which makes the join a race, and the race is handled rather than
-- avoided: a client that picks a team before its answer arrives is put
-- in spectator and has the team it asked for remembered, and the moment
-- the answer lands and passes, it is put on that team. So a good client
-- that clicked early sees a flicker, not a refusal.
--
-- API (globals):
--   ext_policy_of(id)        -> the level in force for that extension
--   ext_policy_missing(pid, level)
--        -> list of titles the client is missing at that level, and
--           whether it has answered yet. Empty list and answered=false
--           means undecided
--   ext_policy_ok(pid)       -> may this client leave spectator
--
--   EXT_APPLIED / EXT_RECOMMENDED / EXT_REQUIRED
local mod = init_mod();

EXT_APPLIED = 0;
EXT_RECOMMENDED = 1;
EXT_REQUIRED = 2;

local LEVEL_NAME = {
	[EXT_APPLIED] = "applied",
	[EXT_RECOMMENDED] = "recommended",
	[EXT_REQUIRED] = "required",
};

-- A level may also be written as its name, and in config.lua it has to
-- be. The EXT_* constants above are globals this module creates when it
-- loads, and config.lua sets the policy BEFORE that -- so a config
-- saying `[0x32] = EXT_REQUIRED` is saying `[0x32] = nil`, which reads
-- as "no entry" and quietly does the opposite of what was written.
--
-- Strings have no such ordering to get wrong, so they are what the
-- config uses and what the default below is written as. The numbers
-- stay valid for Lua that runs after the load.
local LEVEL_BY_NAME = {
	applied = EXT_APPLIED,
	recommended = EXT_RECOMMENDED,
	required = EXT_REQUIRED,
};

local function resolve_level(v)
	if (type(v) == "string") then
		return LEVEL_BY_NAME[string.lower(v)];
	end
	if (type(v) == "number" and LEVEL_NAME[v] ~= nil) then
		return v;
	end
	return nil;
end

-- The level of any extension not named in ext_policy below, which with
-- an empty ext_policy means every extension this server speaks.
--
-- EXT_RECOMMENDED for now. Nothing is withheld from anybody at that
-- level and nobody is kept out; a client missing something is told
-- once, which is the only way to find out what clients actually
-- implement these -- the specifications are days old, and the honest
-- answer today is that most clients will be told they are missing most
-- of them. That is the point of running it this way round first: when
-- the warnings stop arriving for a client you expected to be fine, the
-- extension is worth requiring, and not before.
--
-- Set it to EXT_APPLIED for silence, or name individual extensions in
-- ext_policy to take them out of whatever this says.
getcfg("ext_policy_default", "recommended");
-- id -> level, for the extensions that are exceptions to the default
-- above. Empty is the normal state. Set it in config.lua before loading.
getcfg("ext_policy", {});
-- Seconds a client gets to answer the extension announcement before it
-- is judged on the silence. It has to outlast a slow map download on a
-- bad line, since the version request rides the end of the map transfer
-- (funcs_send.c:198-208) and the answer cannot come before the client
-- has got through it. 30 is generous; the honest answers arrive in one
-- round trip.
getcfg("ext_policy_grace", 30);
-- Seconds between re-telling a player what they are missing, so that a
-- client hammering the team menu is answered once rather than per press.
getcfg("ext_policy_remind", 10);
-- Seconds between the unprompted re-tellings. A player missing
-- something is told again on this interval for as long as it is still
-- missing -- recommended or required alike, since a player who walked
-- away from the team menu and is sitting in spectator needs to find out
-- why, and one who was told at connect has long since lost it up the
-- chat. 60 is often enough to be noticed and seldom enough not to be
-- the only thing in the chat log.
getcfg("ext_policy_warn_interval", 60);
getcfg("ext_policy_debug", false);

-- pid -> the team they asked for while undecided, put on hold
local pending_team = pid_connected_table();
-- pid -> when we last said anything to them about extensions, which
-- paces both the answer to a menu press and the periodic nag
local told_at = pid_connected_table(0);
-- pid -> when they connected, which is when the clock starts
local since = pid_connected_table();

--============================== WHO ==================================--

-- Nobody on the other end: no client to announce to, no answer to wait
-- for, and nothing an extension could mean. Exempt from everything.
--
-- The peer test is the general one and the bot test is the explicit
-- one, and both are here because they fail in opposite directions: a
-- bot library other than lib_bot would pass bot_is_bot and still have
-- no peer, while a future lib_bot bot given a real connection would
-- have a peer and still be a bot.
local function is_clientless(pid)
	if (bot_is_bot ~= nil and bot_is_bot(pid)) then
		return true;
	end

	local ok, addr = pcall(get_ipaddr, pid);
	return ok and addr == 0;
end

--============================= VERDICT ===============================--

-- Every registered extension carrying `level`, as {id, title} pairs.
-- Read from lib_ext's registry each time rather than cached, so that a
-- hot-loaded extension counts from the moment it registers.
-- The level in force for one extension: its own entry, else the
-- default. One place, so that the audit, the verdict and the public
-- ext_policy_of cannot disagree about what the policy says.
local function level_of(id)
	-- An unrecognisable value falls back to applied rather than to
	-- something stricter: a typo should cost a feature, never a player's
	-- ability to play. The audit names anything that landed here.
	return resolve_level(ext_policy[id])
		or resolve_level(ext_policy_default)
		or EXT_APPLIED;
end

local function wanted(level)
	local out = {};

	if (ext_each == nil) then
		return out;
	end

	ext_each(function(id, reg)
		if (level_of(id) == level) then
			out[#out+1] = {id = id, title = reg.title or reg.name};
		end
	end);

	return out;
end

-- What this client is missing at `level`, and whether it has answered.
-- An unanswered client is missing everything by this reckoning, which
-- is the safe reading, but `answered` is returned alongside so a caller
-- can tell "has not said" from "said no".
function ext_policy_missing(pid, level)
	local missing = {};
	local answered = ext_replied ~= nil and ext_replied(pid);

	for _,e in ipairs(wanted(level)) do
		if (ext_supported == nil or ext_supported(pid, e.id) == nil) then
			missing[#missing+1] = e.title;
		end
	end

	table.sort(missing);
	return missing, answered;
end

function ext_policy_of(id)
	return level_of(id);
end

-- Has this client run out of time to answer? Until it has, silence is
-- not yet a no.
local function decided(pid)
	if (ext_replied ~= nil and ext_replied(pid)) then
		return true;
	end

	local t = since[pid];
	return t ~= nil and get_time() - t >= ext_policy_grace;
end

-- May this client leave spectator? Clientless ids always may; everyone
-- else needs every required extension. An undecided client may not yet,
-- which is why the caller holds their team rather than refusing it.
function ext_policy_ok(pid)
	if (is_clientless(pid)) then
		return true;
	end

	local missing = ext_policy_missing(pid, EXT_REQUIRED);
	return #missing == 0;
end

--============================= TELLING ===============================--

local function say(pid, fmt, ...)
	server_msg(pid, string.format(fmt, ...));
end

local function list(titles)
	return table.concat(titles, ", ");
end

-- One clock for everything said to a player, read with two different
-- minimum gaps: ext_policy_remind when they just pressed the team menu
-- and are owed an answer promptly, ext_policy_warn_interval for the
-- nagging that happens on its own. Sharing the clock is what keeps the
-- two from talking over each other -- a player who was just told why
-- they cannot join does not also get the periodic version of it a
-- second later.
local function may_tell(pid, min_gap)
	local now = get_time();

	if (now - told_at[pid] < min_gap) then
		return false;
	end

	told_at[pid] = now;
	return true;
end

local function tell_required(pid, missing, answered)
	if (not answered) then
		-- Never answered the announcement at all, which is what an old
		-- client looks like from here: it is not that it declined the
		-- extension, it is that it never heard the question. Naming the
		-- extensions would be beside the point.
		say(pid, "Your client is too old for this server and cannot join.");
		say(pid, "It never answered the extension handshake. Update it,"
			.. " or use ZeroSpades.");
		return;
	end

	say(pid, "You cannot join: your client is missing %s.",
		list(missing));
	say(pid, "Update your client -- ZeroSpades supports %s --"
		.. " then reconnect.",
		#missing == 1 and "it" or "them");
end

local function tell_recommended(pid, missing)
	say(pid, "Heads up: your client is missing %s.", list(missing));
	say(pid, "You can play without %s, but you will not see"
		.. " everything other players do.",
		#missing == 1 and "it" or "them");
end

--============================== GATE =================================--

-- The team a client asked for, honoured or held. Returns the team to
-- actually use, which is SPECTATOR when they may not play yet.
local function gate(pid, team, gun)
	if (team == SPECTATOR or is_clientless(pid)) then
		return team;
	end

	if (ext_policy_ok(pid)) then
		return team;
	end

	local missing, answered = ext_policy_missing(pid, EXT_REQUIRED);

	-- Hold the team they wanted, and the gun with it. If this is only
	-- the handshake being slow, the tick below puts them on both as soon
	-- as the answer lands and they never find out this happened.
	--
	-- The gun is remembered rather than read back later because by then
	-- there is nothing to read back: get_gun reports what the last
	-- spawn_player set (lua_playerget:67-68), and a player held in
	-- spectator from the moment they arrived has never had one.
	pending_team[pid] = {team = team, gun = gun};

	if (decided(pid) and may_tell(pid, ext_policy_remind)) then
		tell_required(pid, missing, answered);
	end

	if (ext_policy_debug) then
		log("lib_ext_policy: #%d held in spectator, missing %s (answered %s)",
			pid, list(missing), tostring(answered));
	end

	return SPECTATOR;
end

function mod.on_join(pid, team, gun, name)
	return mod.next.on_join(pid, gate(pid, team, gun), gun, name);
end

function mod.on_switch(pid, team, gun)
	local use = gate(pid, team, gun);

	-- A refused switch is declined outright rather than chained with the
	-- team rewritten, and that is not tidiness. on_switch applied to a
	-- player who is already a spectator takes the team == 255 branch and
	-- calls spawn_player (funcs_event.c:100-106) -- so chaining
	-- "spectator wants to be a spectator" would spawn the very player we
	-- are keeping out, once per press of the menu. team_balance declines
	-- by returning for the same reason.
	if (use ~= team and use == SPECTATOR and get_team(pid) == SPECTATOR) then
		return;
	end

	return mod.next.on_switch(pid, use, gun);
end

--============================== AUDIT ================================--

-- Says what the policy came out as, and names anything in it that no
-- module registered.
--
-- It reports and changes nothing, which is the important part. An
-- ext_policy entry for an unregistered id is already harmless by
-- construction: `wanted` walks lib_ext's REGISTRY and asks the policy
-- about each id, never the other way round, so an id nothing registered
-- is never looked at and can never make a client fail. Deleting such an
-- entry would be the actively worse move -- the extension may simply
-- not have loaded yet, and a policy deleted at startup would not come
-- back when it does.
--
-- Deferred to a tick rather than run from on_load for exactly the same
-- reason. config.lua may load this before or after the extensions it
-- names, and which it is should not change what gets logged, let alone
-- what gets enforced. By the first tick they have all registered.
local audited = false;

local function audit()
	local known = {};
	local lines = {};

	-- every registered extension and the level actually in force for it,
	-- which with a non-applied default is most of the interesting
	-- information -- an operator reading ext_policy alone would see an
	-- empty table and learn nothing
	ext_each(function(id, reg)
		known[id] = reg;
		lines[#lines+1] = string.format("%s=%s", reg.title or reg.name,
			LEVEL_NAME[level_of(id)]);
	end);

	table.sort(lines);
	log("lib_ext_policy: default %s; %s",
		LEVEL_NAME[level_of(-1)] or tostring(ext_policy_default),
		#lines > 0 and table.concat(lines, ", ") or "nothing registered yet");

	-- and the entries that name something nobody speaks
	for id,level in pairs(ext_policy) do
		if (known[id] == nil) then
			log("lib_ext_policy: ext_policy names extension %d as %s, but"
				.. " nothing registered it -- no client can be judged on"
				.. " it, so it does nothing. Load that extension's"
				.. " module.", id, LEVEL_NAME[level] or tostring(level));
		end
	end
end

--============================== CLOCK ================================--

-- The moment a client's clock starts. on_successful_connect is before
-- the map goes out, so the grace period covers the whole download.
function mod.after.on_successful_connect(pid)
	since[pid] = get_time();
end

-- Everything that has to happen after an answer arrives, and the answer
-- arrives in a packet, not in a hook we own -- lib_ext's ready callback
-- only fires for extensions that matched, so a client supporting
-- nothing produces no callback at all. Hence a poll, over the few pids
-- actually waiting on something rather than over everybody.
local last_sweep = 0;

function mod.after.tick()
	local now = get_time();

	if (not audited) then
		audited = true;
		audit();
	end

	if (now - last_sweep < 0.25) then
		return;
	end
	last_sweep = now;

	for pid in piditer(PID_BROADCAST) do
		local want = pending_team[pid];
		local due = now - told_at[pid] >= ext_policy_warn_interval;

		-- Two table lookups and a subtraction before anything costly.
		-- In the steady state nothing below runs for anybody: no held
		-- team, and the warning clock not yet due. is_clientless costs a
		-- pcall and ext_policy_missing walks the registry, so neither is
		-- reached until there is a reason.
		if ((want ~= nil or due) and not is_clientless(pid)) then
			-- a held team, now allowed: put them on it, with the gun
			-- they asked for at the time
			if (want ~= nil and ext_policy_ok(pid)) then
				pending_team[pid] = nil;
				on_switch(pid, want.team, want.gun);

				if (ext_policy_debug) then
					log("lib_ext_policy: #%d answered in time, released"
						.. " onto team %d", pid, want.team);
				end

				want = nil;
			end

			-- The periodic telling, once they have answered or run out
			-- of time to. One message per round, the worse news first: a
			-- player who cannot play at all is told that and not also
			-- told what they are missing cosmetically, which would bury
			-- the part they can act on.
			if (due and decided(pid)) then
				local req, answered = ext_policy_missing(pid, EXT_REQUIRED);

				if (#req > 0) then
					if (may_tell(pid, ext_policy_warn_interval)) then
						tell_required(pid, req, answered);
					end
				else
					local rec = ext_policy_missing(pid, EXT_RECOMMENDED);

					if (#rec > 0
					    and may_tell(pid, ext_policy_warn_interval)) then
						tell_recommended(pid, rec);
					end
				end
			end
		end
	end
end

--============================= LIFECYCLE =============================--

function mod.on_load()
	if (ext_replied == nil or ext_each == nil) then
		error("lib_ext_policy needs lib_ext loaded first, and a version of"
			.." it providing ext_replied/ext_each "
			.."(config.lua loads it, or: lsdctl <instance> load lib_ext "
			.."lib_ext_policy)", 0);
	end

	-- Anybody already connected never had an on_successful_connect under
	-- this module, so start their clock now rather than leaving them
	-- undecided forever with a nil `since`. Generous by exactly one
	-- grace period, which is the right way to be wrong on a hot load.
	local now = get_time();
	for pid in piditer(PID_BROADCAST) do
		if (since[pid] == nil) then
			since[pid] = now;
		end
	end
end

local EXPORTS = {
	"ext_policy_of", "ext_policy_missing", "ext_policy_ok",
	"EXT_APPLIED", "EXT_RECOMMENDED", "EXT_REQUIRED",
};

function mod.on_unload()
	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
