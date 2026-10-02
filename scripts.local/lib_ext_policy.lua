-- lib_ext_policy.lua -- What a missing protocol extension costs a client
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- lib_ext announces what this server speaks and records what each
-- client speaks back. It does not care what the answer is. This does:
-- it puts a price on each extension, from none at all up to not being
-- allowed to play.
--
-- Load lib_ext before this; it is where the registry and the agreement
-- live, and this module is nothing without them. lib_message_types is
-- optional and is used if present -- it is what turns the lockout
-- notice into an alert rather than another chat line.
--
-- THREE LEVELS, and every extension has one:
--
--   EXT_DISABLED     not offered at all. The module stays loaded, but
--                    the id is left out of the announcement, so no
--                    client can agree to it and every ext_supported
--                    about it answers no -- including for clients that
--                    had already agreed. This is how you turn an
--                    extension off from the settings file without
--                    unloading its module.
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
--                    This is the only level that raises the alert.
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
-- bot to ask. lib_bot's bots reach on_join by calling it
-- (lib_bot.lua:120), so without this every hostage and every faller
-- would be frozen in spectator and both gamemodes would stop working.
-- Two tests, either of which exempts:
--
--   bot_is_bot(pid)      lib_bot saying so, when it is loaded
--   get_ipaddr(pid) == 0 no ENet peer at all (lua.c:1087-1096 answers 0
--                        rather than failing), which covers a bot from
--                        any other source, and anything else holding a
--                        player id with nobody behind it
--
-- WHAT COUNTS AS AN ANSWER. ext_supported is nil both for a client that
-- said "not that one" and for one that has not spoken yet, so a verdict
-- cannot be read off it alone -- see ext_replied. Until a client has
-- either answered or run out of time to, it is undecided: treated as
-- failing a requirement, but told nothing, because there is nothing to
-- tell it yet and it has very likely just not got there.
--
-- Running out of time is two clocks, not one, because the thing being
-- waited for changes. A client still in limbo may be halfway through a
-- map download and gets ext_policy_grace from connecting. A client that
-- has picked a team cannot be: it got through the map and the version
-- request behind it, so its silence means something after only
-- ext_policy_grace_joined. That second clock is the one a player
-- standing in the game actually waits.
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
--   ext_policy_apply()       make lib_ext's offered list match the
--                            policy, after editing ext_policy live
--
--   EXT_APPLIED / EXT_RECOMMENDED / EXT_REQUIRED
local mod = init_mod();

-- Below applied rather than above required, which is what -1 is saying:
-- disabled is not a stricter policy, it is the absence of the extension
-- from the conversation altogether.
EXT_DISABLED = -1;
EXT_APPLIED = 0;
EXT_RECOMMENDED = 1;
EXT_REQUIRED = 2;

local LEVEL_NAME = {
	[EXT_DISABLED] = "disabled",
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
-- The base protocol's system chat type, which needs no extension and no
-- agreement. Spelled here rather than as MSG_SYSTEM because that global
-- only exists once lib_message_types has loaded, and this module works
-- whether it ever does.
local CHAT_SYSTEM = 2;

local LEVEL_BY_NAME = {
	disabled = EXT_DISABLED,
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
getcfg("ext_policy_default", "recommended",
	"Level for any extension not named in ext_policy: disabled, "
		.."applied, recommended or required.");
-- id -> level, for the extensions that are exceptions to the default
-- above. Empty is the normal state. Set it in config.lua before loading.
getcfg("ext_policy", {},
	"Per-extension levels, by protocol id. Every registered "
		.."extension should be listed.");
-- Seconds a client gets to answer the extension announcement before it
-- is judged on the silence. It has to outlast a slow map download on a
-- bad line, since the version request rides the end of the map transfer
-- -- send_map (funcs_send.c:198-208) ends in send_state (:271-275),
-- which is what calls demand_fingerprint (main.c:1204-1223) -- and the
-- answer cannot come before the client has got through it. 30 is
-- generous; the honest answers arrive in one round trip.
getcfg("ext_policy_grace", 30,
	"Seconds a client gets to answer the extension handshake while "
		.."still in limbo.");
-- Seconds of silence that count as an answer once the client has
-- joined a team, which proves it got through the map and the version
-- request behind it. Much shorter than the figure above because the
-- thing that one has to allow for -- a slow download -- has already
-- happened. This is what a player standing in the game waiting to be
-- told something actually waits.
getcfg("ext_policy_grace_joined", 3,
	"Seconds of silence that count as an answer once a client has "
		.."picked a team.");
-- Seconds between re-telling a player what they are missing, so that a
-- client hammering the team menu is answered once rather than per press.
getcfg("ext_policy_remind", 10,
	"Minimum seconds between two tellings to the same player.");
-- Seconds between the unprompted re-tellings. A player missing
-- something is told again on this interval for as long as it is still
-- missing -- recommended or required alike, since a player who walked
-- away from the team menu and is sitting in spectator needs to find out
-- why, and one who was told at connect has long since lost it up the
-- chat. 60 is often enough to be noticed and seldom enough not to be
-- the only thing in the chat log.
getcfg("ext_policy_warn_interval", 60,
	"Seconds between unprompted re-tellings of what a client is "
		.."missing.");
-- THE ALERT IS FOR BEING LOCKED OUT, AND FOR NOTHING ELSE. It goes to
-- a player held in spectator by a required extension, once, saying one
-- fixed sentence. A recommended extension never raises it: that player
-- is playing, and a banner about reduced cosmetics is out of all
-- proportion to what it costs them.
--
-- One sentence because the Message Types levels render as a transient
-- alert with a single slot, so it is no place for detail: it cannot
-- hold a list, it cannot be re-read, and a second one replaces the
-- first -- which is how a two-line message loses its first line. What
-- it is good for is making a player look at the chat, where the actual
-- list is.
--
-- Set ext_policy_alert false to drop it entirely and use chat alone.
getcfg("ext_policy_alert", true,
	"Raise a one-off alert when a client is held out. Only a "
		.."lockout raises it.");
getcfg("ext_policy_alert_text", "Your client is outdated, please update",
	"The one sentence that alert carries.");
getcfg("ext_policy_alert_type", 3,
	"Message Types value for the alert: 3 big and centre-screen, 5 "
		.."a warning, 6 an error. "); -- MSG_BIG, centre-screen
-- And the chat type the periodic listing goes out as. 2 is the ordinary
-- system line every client has always had, which is the one that
-- reliably lands IN the chat log and stays there to be read -- the
-- whole job of this half. The Message Types values are available (4 a
-- notice, 5 a warning) if your clients render those as chat lines
-- rather than as another banner, but 2 is the one that cannot surprise
-- you.
--
-- Numbers, not MSG_*: those constants do not exist until
-- lib_message_types loads, and config.lua runs first.
getcfg("ext_policy_chat_type", 2,
	"Chat type the periodic listing uses. 2 is the ordinary system "
		.."line. "); -- MSG_SYSTEM
getcfg("ext_policy_debug", false,
	"Log every verdict and every telling.");

-- pid -> the team they asked for while undecided, put on hold
local pending_team = pid_connected_table();
-- pid -> when we last said anything to them about extensions, which
-- paces both the answer to a menu press and the periodic nag. nil
-- means never, and nil has to mean never rather than 0 meaning it:
-- get_time is CLOCK_MONOTONIC (main.c:130-136), which on Linux counts
-- from boot, so 0 is a real instant that was `uptime` ago. Treating it
-- as "long ago" happens to work on a host that has been up a while and
-- silently gags every warning for the first minute after a reboot.
local told_at = pid_connected_table();
-- pid -> when they connected, which is when the slow clock starts
local since = pid_connected_table();
-- pid -> has the one fixed alert gone out to them yet
local alerted = pid_connected_table(false);
-- pid -> when they first picked a team. A client that has joined has
-- demonstrably processed the whole map and the version request that
-- rides its tail, so its silence means something much sooner than a
-- client we are still waiting on mid-download.
local caught_up = pid_connected_table();

--============================== WHO =================================--

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

--============================= VERDICT ==============================--

-- The level in force for one extension: its own entry, else the
-- default. One place, so that the audit, the verdict and the public
-- ext_policy_of cannot disagree about what the policy says.
-- Names a value nobody recognises, once per distinct value, so that a
-- typo in the settings file is heard. Silence here downgraded a
-- required extension to applied without a word -- the exact failure the
-- policy exists to prevent.
local moaned = {};

local function resolve_or_moan(v, what)
	if (v == nil) then
		return nil;
	end

	local level = resolve_level(v);

	if (level == nil and not moaned[tostring(v)]) then
		moaned[tostring(v)] = true;
		log("lib_ext_policy: %s is %q, which is not a level -- expected"
			.. " disabled, applied, recommended or required. IGNORED.",
			what, tostring(v));
	end

	return level;
end

local function level_of(id)
	-- An unrecognisable value falls back to applied rather than to
	-- something stricter: a typo should cost a feature, never a player's
	-- ability to play. It is logged rather than swallowed, though.
	return resolve_or_moan(ext_policy[id], string.format("ext_policy[0x%02x]", id))
		or resolve_or_moan(ext_policy_default, "ext_policy_default")
		or EXT_APPLIED;
end

-- Every registered extension carrying `level`, as {id, title} pairs.
-- Read from lib_ext's registry each time rather than cached, so that a
-- hot-loaded extension counts from the moment it registers.
--
-- And asked of the REGISTRY rather than of the policy, which is what
-- makes a policy entry for an extension nobody registered harmless: an
-- id that is not in the registry is never looked at here, so it can
-- never put a client in the missing list. See audit().
local function wanted(level)
	local out = {};

	if (ext_each == nil) then
		return out;
	end

	ext_each(function(id, reg)
		if (level_of(id) == level) then
			out[#out+1] = {id = id, title = reg.title};
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

	local now = get_time();

	-- They have joined, so they are not still downloading: the version
	-- request goes out at the END of the map transfer
	-- (main.c:1204-1223, reached from send_map), and a client cannot
	-- have picked a team without getting past it. Silence from here is
	-- an answer within a couple of seconds, not thirty.
	local up = caught_up[pid];
	if (up ~= nil and now - up >= ext_policy_grace_joined) then
		return true;
	end

	-- Still in limbo, possibly still pulling the map down. This is the
	-- clock that has to be generous, and the only one that was.
	local t = since[pid];
	return t ~= nil and now - t >= ext_policy_grace;
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

--============================= TELLING ==============================--

-- The alert: one fixed sentence, once per player, only on the required
-- path, and only to a client that can actually render it as an alert.
--
-- Deliberately NOT routed through msg_send's fallback. That fallback
-- turns an alert into an ordinary chat line for a client that cannot
-- render one -- which here would put a second, vaguer line directly
-- above the specific one below it. Noise, for no gain: a client that
-- cannot be alerted is told in chat, which it can read.
local function alert_once(pid)
	if (not ext_policy_alert or alerted[pid]) then
		return;
	end

	if (msg_send == nil or msg_supported == nil
	    or not msg_supported(pid)) then
		return;
	end

	alerted[pid] = true;
	msg_send(pid, ext_policy_alert_type, ext_policy_alert_text);
end

-- The chat channel, which is the other half of saying one thing loudly:
-- a toast is gone in a moment and cannot be re-read, so everything a
-- player might want to look at twice goes here as well. It does not
-- compete with the toast -- different channel, different slot -- which
-- is why the detail can be as long as it needs to be.
local function say_chat(pid, fmt, ...)
	local text = string.format(fmt, ...);

	-- Type 2 goes through server_msg rather than through msg_send, even
	-- when lib_message_types is loaded and would carry it perfectly
	-- well. The two differ in one field: server_msg has always sent from
	-- player 0 (main.c:1343-1345) and msg_send sends from the reserved
	-- 255. For the type every client has rendered since 0.75 that is not
	-- a difference worth introducing, so the default path stays exactly
	-- what every other module in this tree already sends.
	if (msg_send ~= nil and ext_policy_chat_type ~= CHAT_SYSTEM) then
		msg_send(pid, ext_policy_chat_type, text);
	else
		server_msg(pid, text);
	end
end

-- Titles as a readable series, which is all a chat line needs.
local function list(titles)
	return table.concat(titles, ", ");
end

-- One clock for everything said to a player, read with two different
-- minimum gaps: ext_policy_remind when they just pressed the team menu
-- and are owed an answer promptly, ext_policy_warn_interval for the
-- telling that happens on its own. Sharing the clock is what keeps the
-- two from talking over each other -- a player who was just told why
-- they cannot join does not also get the periodic version of it a
-- second later.
local function may_tell(pid, min_gap)
	local now = get_time();
	local last = told_at[pid];

	if (last ~= nil and now - last < min_gap) then
		return false;
	end

	told_at[pid] = now;
	return true;
end

-- The alert at most once; the list in chat, every time. The list is the
-- half worth repeating and the half worth reading twice, so it is the
-- half that recurs.
local function tell_required(pid, missing, answered)
	alert_once(pid);

	if (not answered) then
		-- Never answered the announcement at all, which is what an old
		-- client looks like from here: it is not that it declined the
		-- extension, it is that it never heard the question. Naming the
		-- extensions would be beside the point.
		say_chat(pid, "Your client never answered the extension handshake,"
			.. " so it cannot leave spectator. Update it, or use"
			.. " ZeroSpades.");
		return;
	end

	say_chat(pid, "Missing: %s. You cannot leave spectator without %s --"
		.. " update your client, then reconnect.", list(missing),
		#missing == 1 and "it" or "them");
end

-- No alert here, on purpose. A recommended extension costs a player
-- some of what the server can show them and nothing else -- they are
-- playing, and interrupting that with a banner to tell them their
-- cosmetics are reduced is out of all proportion. The chat line says it
-- and keeps saying it, which is enough for something they can ignore.
local function tell_recommended(pid, missing)
	say_chat(pid, "Missing: %s. You can play, but you will not see"
		.. " everything other players do.", list(missing));
end

--============================== GATE ================================--

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
	-- Picking a team is proof the client is caught up: it cannot have
	-- got here without processing the map and the version request behind
	-- it, so decided() may stop being patient with its silence. Stamped
	-- here and not from a mod.after.on_join, because core.lua's
	-- process_before_after assigns tbl[name] outright (core.lua:76-80)
	-- -- an `after` form of a hook this module already defines plainly
	-- would replace the gate below rather than run alongside it.
	if (caught_up[pid] == nil) then
		caught_up[pid] = get_time();
	end

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

--============================== AUDIT ===============================--

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
-- Make lib_ext's offered list match the policy. Disabling is an act,
-- not a label: lib_ext has to be told, because it is the one that
-- builds the announcement.
--
-- Called from the tick below once everything has registered, and
-- exported so an operator who edits ext_policy live can re-apply it.
function ext_policy_apply()
	if (ext_disable == nil or ext_each == nil) then
		return 0;
	end

	local changed = 0;

	ext_each(function(id)
		local want_off = level_of(id) == EXT_DISABLED;

		if (want_off and ext_disable(id)) then
			changed = changed + 1;
		elseif (not want_off and ext_enable(id)) then
			changed = changed + 1;
		end
	end);

	return changed;
end

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
		lines[#lines+1] = string.format("%s=%s", reg.title,
			LEVEL_NAME[level_of(id)]);
	end);

	table.sort(lines);
	log("lib_ext_policy: default %s; %s",
		LEVEL_NAME[resolve_level(ext_policy_default) or EXT_APPLIED],
		#lines > 0 and table.concat(lines, ", ") or "nothing registered yet");

	-- Every extension this server speaks should be named in ext_policy,
	-- so the settings file is the whole picture rather than a list of
	-- exceptions to a default nobody can see. An absent one still works
	-- -- it takes ext_policy_default -- but it is invisible to whoever
	-- is editing the file, which is the thing worth complaining about.
	local absent = {};

	for id,reg in pairs(known) do
		if (ext_policy[id] == nil) then
			absent[#absent+1] = string.format("0x%02x %s", id,
				reg.title or reg.name);
		end
	end

	if (#absent > 0) then
		table.sort(absent);
		log("lib_ext_policy: not named in ext_policy, so running at the"
			.. " default (%s): %s", LEVEL_NAME[resolve_level(
				ext_policy_default) or EXT_APPLIED],
			table.concat(absent, ", "));
	end

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

--============================== CLOCK ===============================--

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
		ext_policy_apply();
		audit();
	end

	if (now - last_sweep < 0.25) then
		return;
	end
	last_sweep = now;

	for pid in piditer(PID_BROADCAST) do
		local want = pending_team[pid];
		local last = told_at[pid];
		local due = last == nil
			or now - last >= ext_policy_warn_interval;

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
			if (ext_policy_debug and due and not decided(pid)) then
				log("lib_ext_policy: #%d still undecided -- replied %s,"
					.. " %.1fs since connect (grace %.1f), joined %s",
					pid, tostring(ext_replied(pid)),
					since[pid] ~= nil and now - since[pid] or -1,
					ext_policy_grace, tostring(caught_up[pid] ~= nil));
			end

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

						if (ext_policy_debug) then
							log("lib_ext_policy: told #%d it is missing %s",
								pid, list(rec));
						end
					elseif (ext_policy_debug and #rec == 0) then
						log("lib_ext_policy: #%d is missing nothing"
							.. " recommended", pid);
					end
				end
			end
		end
	end
end

--============================= LIFECYCLE ============================--

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

		-- and anybody already on a team is already caught up, which
		-- they plainly are, having played their way to this moment
		if (caught_up[pid] == nil and is_joined(pid)) then
			caught_up[pid] = now;
		end
	end
end


-- Settings can be reloaded without restarting (lib_settings), and the
-- policy decides what lib_ext offers. So reconcile again when the file
-- changes, or a reload would move a level in ext_policy and leave the
-- announcement built from the old one.
if (settings_listen ~= nil) then
	settings_listen("lib_ext_policy", function()
		if (ext_policy_apply ~= nil) then
			ext_policy_apply();
		end
	end);
end
-- Everything this module put in the global table, taken back out again.
--
-- Unloading a module does not undo its globals -- the functions keep
-- working, closed over the state of a module nothing is calling any
-- more -- and consumers test these names to find out whether the thing
-- is available at all. Left behind, they answer yes forever and every
-- such guard becomes dead code.
--
-- The list is exhaustive on purpose: a name added to the API above and
-- forgotten here outlives its own module, and goes on answering for it.
local EXPORTS = {
	"ext_policy_of", "ext_policy_missing", "ext_policy_ok",
	"ext_policy_apply",
	"EXT_DISABLED", "EXT_APPLIED", "EXT_RECOMMENDED", "EXT_REQUIRED",
};

function mod.on_unload()
	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
