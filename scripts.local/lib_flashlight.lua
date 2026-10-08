-- lib_flashlight.lua -- The Flashlight protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Flashlight extension (id 0x32, version 1): a
-- light a player carries, switched by the server and drawn by every
-- client that can see them. The vanilla client has no flashlight at
-- all, and OpenSpades' is private to whoever switched it on -- this is
-- the same light made everybody's.
--
-- THREE SUB-PACKETS AND NOTHING ELSE: Light, Light State, Light Config,
-- all three inside packet 0x72. Light is the only one a client may
-- send, and it may only ask about itself.
--
-- Nothing in LSd's core knows about any of this. PacketTypeExtensionInfo
-- is declared in protocol.h:804 and the ExtensionID enum lives at :916 --
-- which names 0, 1 and the packetless ones, and nothing near 0x32 --
-- while nothing in funcs_packetrecv.c, funcs_send.c, main.c or lua.c
-- ever touches packet 0x72. So the negotiation is unclaimed, and lib_ext
-- claims it for every extension at once. This module owns packet 0x72
-- and nothing else; load lib_ext before it.
--
-- API (globals):
--   flashlight_supported(pid)      -> true once ext 0x32 is agreed
--   flashlight_get(pid)            -> is their light on
--   flashlight_set(pid, on)        switch it, and tell everyone
--   flashlight_get_config(pid)     -> the beam we hold for them, or nil
--   flashlight_config(pid, opts)   set their beam and tell everyone
--        opts.reach    blocks at which the light reaches zero (0-255)
--        opts.cone     full angle of the cone in degrees (0 to ~179.3)
--        opts.color    LSd's {b=,g=,r=}, linear, 255 being full
--        opts.flicker  0 steady; dark about flicker/512 of the time
--        any of them left out comes from the flashlight_* defaults
--   flashlight_get_default()       -> the default beam, or nil when off
--   flashlight_announce_default()  re-announce it after changing the
--        flashlight_reach/cone/red/green/blue/flicker globals
--   flashlight_listen_request(name, fn) / flashlight_unlisten_request
--        fn(pid, want) for every light a client asks for. Return false
--        to refuse it; the spec has a refused request simply not
--        relayed, so the asker is not told and nothing changes. A
--        listener that throws is dropped and refuses that request --
--        a veto that cannot answer is not read as consent.
--
-- THE LAMP GIVES THE CARRIER AWAY, and that is the client's work
-- entirely -- there is nothing extra on the wire for it. A client draws
-- a glare at the lamp of every lit player but its own, and derives the
-- whole thing from what this module already sends: the beam's colour,
-- and Reach and Cone out of the Light Config.
--
-- Which quietly turns those two into gameplay. Cone sets the angle the
-- glare is visible through (the spec's Beam term falls off over
-- Cone/2), and Reach sets how far (Distance is 1/(1+(d/Reach)^2)). So a
-- wider, longer beam does not merely light more -- it shows its carrier
-- to more people, from further away. A narrow beam is the stealthy one,
-- and a flickering one goes dark glare and all for Flicker/512 of the
-- time.
--
-- And the glare brightens as the world darkens: the spec scales it by a
-- dark adaptation of 1 in daylight up to 8 in total darkness. Switch
-- lib_daytime to night and a lit player is not subtly visible, they are
-- a beacon. Which is the point on a map played in the dark -- see
-- hallwayatnight's guards, who carry theirs lit on purpose.
--
-- A LIGHT IS NOT ADDRESSED TO ANYBODY, which is what makes this
-- different from lib_teamplay. A mark is drawn for one viewer and is
-- that viewer's alone; a light belongs to the player carrying it and
-- every client draws every lit player, whichever team they are on. So
-- flashlight_set takes the carrier and not a viewer, the carrier need
-- not have negotiated anything -- a bot can carry a light nobody but
-- the humans can see -- and the relay goes to everyone who speaks the
-- extension.
--
-- WHOSE STATE IT IS. Every half is held here as well as on the client,
-- because the client's copy is not askable and a client that negotiates
-- late has to be told what it missed. They expire differently, and this
-- is the whole of it:
--
--   on/off   off on Create Player, Kill Action and Player Left for that
--            player, and every light off on Map Start
--   config   lasts until Player Left, surviving death, respawn and Map
--            Start
--   default  lasts for the connection, and belongs to no player at all
--            -- so nothing ends it but the client going away
--
-- The client applies those rules by itself and the spec has the server
-- apply the same ones and send nothing for them -- so the hooks below
-- that mirror a spawn, a kill and a map load touch the table and put
-- nothing on the wire. A light wanted back on after a respawn is the
-- server asking for it again, not this module remembering.
--
-- WHAT THIS DOES NOT DO: anything for clients that don't speak it. A
-- client that does not name ext 0x32 never gets a packet 0x72 and sees
-- an unlit world, which is exactly what it saw before.
local mod = init_mod();
local bit = require("bit");

local EXT_ID = 0x32;
local EXT_VERSION = 1;

-- Flashlight. The packet id is 64 + the extension id, so 0x72.
local PKT = 64 + EXT_ID;
local SUB_LIGHT = 0;  -- S<->C [PKT][0][pid][state]
local SUB_STATE = 1;  -- S->C  [PKT][1][bitmap ...]
local SUB_CONFIG = 2; -- S->C  [PKT][2][pid][reach][cone][r][g][b][flicker]

-- Direction is part of the specification, not a detail of it. Light is
-- the only sub-packet a client may send, and even that one it may only
-- send about itself. Light State and Light Config are Server to Client,
-- one way: a client sending a Config would be choosing how its own
-- light looks to everybody else, and a client sending a State would be
-- claiming every light on the server at once. Nothing outside this
-- table is read at all, let alone acted on.
local CLIENT_MAY_SEND = {[SUB_LIGHT] = true};

-- Light is a fixed four bytes and Config a fixed nine. Light is the
-- only one that arrives, so it is the only size checked on the way in;
-- the others are built a field at a time and never measured.
local LIGHT_SIZE = 4;

-- The Player ID a Light Config carries to mean "every player who has no
-- Light Config of their own, including the ones who join later". It is
-- the one id that is never a player: the Player Limit extension
-- reserves 255 for the server, and LSd agrees on its own account --
-- MAX_PLAYERS is 255 (protocol.h:20), so a player id stops at 254 and
-- 255 is the first handle new_fakepid hands out (commands.lua:116-120).
--
-- Which is what makes one packet do the work of a roster. The default
-- is not held against any player, so nothing has to be sent when
-- somebody joins, and it "lasts for the connection" -- it outlives
-- death, respawn and Map Start, since none of those end a connection,
-- and there is nothing to clear until the client goes away with it.
local DEFAULT_ID = 255;

-- The Cone field is not degrees: it is the full angle in units of
-- pi/256, so 128 is 90 degrees and 255, the widest a byte holds, is
-- about 179.3 -- the unit is chosen so the cone can never open out into
-- a half space, which would not be a spotlight any more. Degrees stay
-- the unit of the API and of flashlight_cone, because that is how
-- anybody writing a setting thinks of a beam; this is the one place
-- they turn into the field and back.
--
-- Converted on the way out and stored as sent, for the same reason
-- every other field is -- a cone of 200 degrees and one of 179.3 are
-- the same light, and the one that goes in a packet log and comes back
-- out of flashlight_get_config should be the one that gets drawn.
--
-- Nothing is capped at the bottom. A Cone or Reach of 0 "gives no
-- light", which is a sayable thing to want and not a degenerate value
-- -- a flashlight that is on and illuminating nothing is how a server
-- spells a dead battery.
local CONE_UNITS_PER_DEGREE = 256/180;

-- The legacy OpenSpades flashlight, which is what a player who has ever
-- pressed F already expects a flashlight to look like. Every number
-- here is read off that light rather than invented
-- (ClientPlayer.cpp:681-684 in yvt/openspades):
--
--   light.radius   = 60.f                  -> flashlight_reach
--   light.spotAngle = 90.f * M_PI / 180.f  -> flashlight_cone
--   light.color    = (1.0, 0.7, 0.5) * brightness
--
-- The colour needs the one conversion. OpenSpades multiplies it by a
-- brightness that settles at 1.5, or 3.0 with HDR on, so its channels
-- run past 1.0 and cannot go in a byte where 255 is 1.0. Dividing
-- through by the largest of them keeps the hue and spends the whole
-- range on it: (1.0, 0.7, 0.5) becomes (255, 178.5, 127.5), and the
-- rounding is what the spec's own example says -- 255, 179, 128.
getcfg("flashlight_reach", 60,
	"Blocks at which the beam reaches zero. OpenSpades' own light uses "
		.."60. Also how far off the carrier's lamp glare is visible.");
getcfg("flashlight_cone", 90,
	"Full angle of the beam in degrees, 0 to 179.3. Also the angle the "
		.."carrier's lamp glare is visible through, so a narrow beam "
		.."is the stealthy one.");
getcfg("flashlight_red", 255,
	"Beam colour, red channel. 255/179/128 is OpenSpades' warm "
		.."white.");
getcfg("flashlight_green", 179,
	"Beam colour, green channel.");
getcfg("flashlight_blue", 128,
	"Beam colour, blue channel.");
-- A failing bulb: the light drops out in short irregular bursts, dark
-- about flashlight_flicker/512 of the time, so 255 is out roughly half
-- of it. The glare drops out with the beam, which makes a flickering
-- carrier harder to track as well as harder to see by. The pattern is
-- the client's; only the duty is on the wire.
getcfg("flashlight_flicker", 0,
	"0 is a steady beam. Otherwise the beam drops out in bursts, dark "
		.."about flicker/512 of the time (255 is roughly half).");
-- Announce the beam above as the default config, so that every client
-- draws the same light rather than falling back on whatever it would
-- have used -- the spec does not say what an unconfigured light looks
-- like, and this is how a server has an opinion. One packet to the
-- reserved id covers every player at once, now and later; see
-- DEFAULT_ID. Off means an unconfigured player's beam is the client's
-- business until flashlight_config says otherwise.
getcfg("flashlight_send_default", true,
	"Announce the beam above as every player's default, so all "
		.."clients draw the same light.");
-- Relay a client's own request to switch its light. This is the F key
-- working: OpenSpades toggles its flashlight locally, and under this
-- extension a client asks instead and draws nothing until the server
-- agrees. Off makes every light the server's to switch.
getcfg("flashlight_allow_requests", true,
	"Let a client switch its own light. This is the F key working.");
-- Seconds between accepted requests from one player. A toggle is a
-- keypress and a quarter second is far longer than anybody can press a
-- key usefully, while still being short enough that an honest toggle
-- never feels refused. Only a request that would actually change
-- something is rated: asking for the state you are already in costs
-- nothing and is not held against the next one.
getcfg("flashlight_request_interval", 0.25,
	"Seconds between accepted requests from one player.");
-- Log every light switched and every request refused. Noisy; off
-- unless you are asking why a client's light is not coming on.
getcfg("flashlight_debug", false,
	"Log every light switched and every request refused.");
-- (Which clients are new enough to be told about extensions at all is
-- lib_ext's ext_min_major/minor/patch, since it is one announcement for
-- every extension and cannot be per-module.)

-- Whether this client and this server have both named ext 0x32 at
-- version 1. lib_ext holds the agreement -- one table for every
-- extension, keyed by the pid it belongs to and dropped when that pid
-- does -- so there is nothing to keep here beyond asking it.
local function negotiated(pid)
	return ext_supported ~= nil and ext_supported(pid, EXT_ID) ~= nil;
end

-- Both tables are pid_connected_tables, which is Player Left exactly:
-- they are cleared on disconnect (pid_tables.lua:87-94), which is the
-- one event that ends a config and the last of the four that ends a
-- light. Ids are recycled, and an inherited light would be a new player
-- arriving already lit.
local lit = pid_connected_table(false);
local cfg = pid_connected_table();
local asked_at = pid_connected_table(0);

local listeners = {};

--============================== BYTES ===============================--

-- A byte, clamped rather than wrapped: every field in this extension is
-- a quantity, so the honest thing to say about a reach of 400 is the
-- largest reach the field can hold, not the 144 that 400 becomes if the
-- top bits are simply dropped.
local function to_byte(v, default)
	v = math.floor((tonumber(v) or default) + 0.5);
	return math.max(0, math.min(255, v));
end

-- A beam as it goes on the wire, from one in the API's units: every
-- field a byte, and the cone turned from degrees into pi/256ths. See
-- CONE_UNITS_PER_DEGREE.
local function to_wire(b)
	return {
		reach = to_byte(b.reach, flashlight_reach),
		cone = to_byte((tonumber(b.cone) or flashlight_cone)
			* CONE_UNITS_PER_DEGREE, 0),
		r = to_byte(b.r, flashlight_red),
		g = to_byte(b.g, flashlight_green),
		b = to_byte(b.b, flashlight_blue),
		flicker = to_byte(b.flicker, flashlight_flicker),
	};
end

-- And back, for answering what a beam is: the cone in the degrees the
-- clients will actually draw, which is the asked-for angle rounded to
-- the nearest pi/256.
local function from_wire(w)
	return {reach = w.reach, cone = w.cone / CONE_UNITS_PER_DEGREE,
		r = w.r, g = w.g, b = w.b, flicker = w.flicker};
end

-- One bit per player id, bit n of byte n/8, low bit first. Only the
-- bytes up to the highest lit id are sent: "an id past the end of the
-- array is off", so the tail is implied and a server with nobody lit
-- sends the shortest packet the extension has -- one zero byte, since
-- the size is given as "2+" and a bitmap of no bytes is not a bitmap.
local function build_state()
	local bytes, top = {}, 0;

	for i in piditer(PID_BROADCAST) do
		if (lit[i]) then
			local idx = math.floor(i/8) + 1;

			bytes[idx] = bit.bor(bytes[idx] or 0, bit.lshift(1, i % 8));
			if (idx > top) then
				top = idx;
			end
		end
	end

	local out = {string.char(PKT, SUB_STATE)};
	for i = 1, math.max(top, 1) do
		out[#out+1] = string.char(bytes[i] or 0);
	end

	return table.concat(out);
end

-- Real players only: 0 to MAX_PLAYERS-1, which is what the valid pid
-- range is (macros:9) and what piditer walks (lua_misc:2).
--
-- Narrower than the field, deliberately. The Player ID is a byte, so
-- 255 would go on the wire perfectly well -- and 255 is exactly the
-- first fake pid new_fakepid hands out (commands.lua:116-120 returns
-- #takenfakepid+1 over a table seeded with 0..MAX_PLAYERS-1, so 255,
-- then 256, then upwards and straight out of the byte). Admitting them
-- would be the worst of both: a fake pid is a book-keeping handle with
-- no body, no eye and no orientation, so there is nothing for a
-- spotlight to hang off, and a light set on one would be broadcast and
-- then never appear in build_state nor be cleared by a map load, since
-- neither walks past MAX_PLAYERS-1. So the line is drawn where the
-- players are.
local function sane_pid(pid)
	pid = tonumber(pid);
	return pid ~= nil and pid == pid and pid >= 0 and pid < MAX_PLAYERS
		and pid % 1 == 0;
end

--=========================== THE DEFAULTS ===========================--

-- The configured beam, as a stored (wire) config. Read out of the
-- globals every time rather than captured once, so changing
-- flashlight_reach and re-announcing works the way the other modules'
-- knobs do.
local function default_config()
	return to_wire({});
end

-- Red, Green, Blue -- in that order, which is NOT the order the rest of
-- this server writes a colour in. The base protocol puts Set Colour and
-- State Data on the wire as Blue Green Red, and LSd's own colour tables
-- are stored to match (lua.c:219-232), so get_team_color hands back
-- {b=,g=,r=} and lib_teamplay writes it straight out. This sub-packet
-- reverses it. The field names in the spec are the authority and the
-- table is read by name here for exactly that reason.
local function send_config(viewer, target, w)
	send_packet(viewer, string.char(PKT, SUB_CONFIG, target,
		w.reach, w.cone, w.r, w.g, w.b, w.flicker));
end

local function describe(w)
	return string.format("reach %d, cone %d (%.1f deg), rgb %d/%d/%d,"
		.. " flicker %d", w.reach, w.cone, w.cone / CONE_UNITS_PER_DEGREE,
		w.r, w.g, w.b, w.flicker);
end

-- The default beam, as one packet addressed to the reserved id, sent to
-- everybody who has negotiated. One packet for the whole server rather
-- than one per player: the client applies it to every player without a
-- config of their own, joiners included, so there is nothing to repeat
-- when somebody arrives.
local function announce_default(pid)
	if (not flashlight_send_default) then
		return;
	end

	local c = default_config();

	if (pid ~= nil) then
		send_config(pid, DEFAULT_ID, c);
		return;
	end

	for i in piditer(PID_BROADCAST) do
		if (negotiated(i)) then
			send_config(i, DEFAULT_ID, c);
		end
	end

	if (flashlight_debug) then
		log("lib_flashlight: default beam is %s", describe(c));
	end
end

local function send_light(viewer, target, on)
	send_packet(viewer,
		string.char(PKT, SUB_LIGHT, target, on and 1 or 0));
end

--=========================== NEGOTIATION ============================--

-- Handled by lib_ext, and deliberately not here. The server announces
-- everything it supports in ONE ExtensionInfo -- [60][count][(id,
-- version) x count] -- so a module that sent its own would be claiming
-- to be the whole list. This module says "id 0x32, version 1" to
-- lib_ext and lib_ext does the talking.
--
-- Called for every client that turns out to speak it. Everything this
-- extension holds is owed to a client that has only just negotiated,
-- and it goes out widest first: the default beam, then the players who
-- have one of their own, then who is lit.
--
-- That order is the whole of it. The default under the exceptions,
-- because a per-player config overrides it and arriving second is the
-- simplest way to be the one that wins. Light State last, so no light
-- is ever drawn in a beam its carrier has already been given a
-- different one for -- and it is also the packet the spec has arriving
-- "after State Data", which this is well after, since negotiation
-- finishes long after a join.
local function on_ready(pid)
	announce_default(pid);

	for i in piditer(PID_BROADCAST) do
		if (cfg[i] ~= nil) then
			send_config(pid, i, cfg[i]);
		end
	end

	send_packet(pid, build_state());

	if (flashlight_debug) then
		log("lib_flashlight: #%d negotiated, sent the beams and the state",
			pid);
	end
end

--============================ THE RULES =============================--
-- The four events that end a light, mirrored here and sent nowhere. The
-- client does all four by itself and the spec has the server apply the
-- same rules and send nothing for them, so these only keep our copy
-- honest -- which matters because our copy is what a late client is
-- told and what build_state is built from.

-- Create Player. The client drops that player's light; so do we.
function mod.after.spawn_player(pid)
	lit[pid] = false;
end

-- Kill Action. Every kill, including the bookkeeping ones behind a team
-- or gun switch -- the client turns the light off on any of them, so
-- drawing the line somewhere else here is how the two copies drift.
function mod.after.kill(pid)
	lit[pid] = false;
end

-- Map Start: every light off, every config kept. The asymmetry is the
-- spec's and it is the sensible half of it -- a new world is a reason
-- to stop carrying a light, not a reason to forget what the light looks
-- like, so nothing has to be re-sent after a map change.
function mod.after.finish_map_load()
	for i in piditer(PID_BROADCAST) do
		lit[i] = false;
	end
end

-- Player Left is the one this module does not hook: both tables are
-- pid_connected_tables and are cleared for it already.

-- And a join is not hooked either, which is worth saying because it
-- looks like it ought to be. A player arriving needs a beam, and the
-- obvious way to give them one is to send them a config on on_join --
-- which is how this module did it before the default id existed, and it
-- was wrong twice over. Once because on_join is not only a join: a map
-- rotation boots everybody to limbo and clears their joined flag
-- (main.c:1181-1190), their clients re-send the same packet, and with
-- joined clear it arrives as another on_join rather than an on_switch
-- (funcs_packetrecv.c:549-553) -- so it fires for every player on every
-- rotation and would reset a beam a server had chosen for them, which
-- the spec has surviving Map Start untouched. And once because it was a
-- packet per player per client to say the same thing every time.
--
-- The default config says it once, to the id that is nobody, and the
-- client applies it to whoever has nothing of their own -- including
-- players who have not arrived yet. So there is nothing to do on a join
-- at all.

--========================== CLIENT REQUESTS =========================--

-- "A client sends it to ask for its own light; the server ignores
-- Player ID and uses the sender's." So the third byte is read past, not
-- read: it is the sender's to fill and ours to ignore, exactly like the
-- originating id on a teamplay ping. A client that puts somebody else
-- in it is asking about itself in a confused way, not asking about them.
local function on_light_request(pid, data)
	if (flashlight_debug) then
		log("lib_flashlight: request from #%d, %d bytes, state %s",
			pid, #data, tostring(string.byte(data, 4)));
	end

	-- a fixed four bytes; anything else is not this sub-packet
	if (#data ~= LIGHT_SIZE) then
		return;
	end

	-- Asking is for clients that agreed to the extension. One that
	-- never named ext 0x32 is sending bytes on a packet id it has not
	-- claimed to understand, and acting on them would relay a light to
	-- everybody on the word of a client we cannot read back -- it draws
	-- nothing itself either, since drawing is the half it did not sign
	-- up for. So the negotiation is a precondition for being heard, not
	-- only for being told.
	if (not negotiated(pid)) then
		if (flashlight_debug) then
			log("lib_flashlight: request #%d ignored: never negotiated"
				.. " ext 0x%x", pid, EXT_ID);
		end
		return;
	end

	if (not flashlight_allow_requests) then
		if (flashlight_debug) then
			log("lib_flashlight: request #%d refused: asking is not"
				.. " permitted", pid);
		end
		return;
	end

	-- A dead man carries no light and neither does a spectator, which
	-- is_alive settles at once (SPECTATORs are not alive,
	-- lua_playerget:8). OpenSpades refuses its own toggle on exactly
	-- these two (Client_Input.cpp:567-569), so this is the same answer
	-- the player is used to -- and the client has the light off anyway,
	-- having turned it off itself on the Kill Action.
	if (not is_alive(pid)) then
		if (flashlight_debug) then
			log("lib_flashlight: request #%d refused: not alive", pid);
		end
		return;
	end

	-- "0 off, 1 on. Any other value is on."
	local want = string.byte(data, 4) ~= 0;

	-- Asking for the state you are already in is not a request to
	-- refuse, it is nothing to do: no packet, and no mark against the
	-- interval below. A client that strobes its key generates no
	-- traffic at all once the first toggle is in.
	if (want == lit[pid]) then
		return;
	end

	local now = get_time();
	if (now - asked_at[pid] < flashlight_request_interval) then
		if (flashlight_debug) then
			log("lib_flashlight: request #%d refused, too soon: %.2fs"
				.. " since the last (need %.2fs)", pid,
				now - asked_at[pid], flashlight_request_interval);
		end
		return;
	end

	-- Stamped here, before anybody is asked, so that the interval
	-- governs requests considered rather than requests granted. A
	-- refused request is still a request: stamping only on success
	-- would leave a client whose every ask is vetoed unthrottled
	-- forever, running the whole listener loop once per inbound packet
	-- -- which is other people's code, called as fast as a client cares
	-- to send.
	asked_at[pid] = now;

	-- The server decides whether to relay, and this is where a server
	-- decides. One listener saying no is a no: a refusal is the
	-- conservative answer and a module that cares enough to veto is not
	-- outvoted by the ones with no opinion.
	--
	-- A listener that throws refuses too, and that is the whole reason
	-- the refusal is spelled out rather than fallen through to. A veto
	-- hook exists to say no; one that crashes has failed to answer, and
	-- reading "no answer" as "yes" means the first crash grants the
	-- request and dropping the listener grants every one after it. So a
	-- crash costs its author the hook and costs the asker this one
	-- request.
	for name,fn in pairs(listeners) do
		local ok, allow = pcall(fn, pid, want);

		if (not ok) then
			listeners[name] = nil;
			log("lib_flashlight: %s crashed on a request, dropped, and the"
				.. " request refused: %s", name, tostring(allow));
			return;
		end

		if (allow == false) then
			if (flashlight_debug) then
				log("lib_flashlight: request #%d refused by %s", pid, name);
			end
			return;
		end
	end

	flashlight_set(pid, want);
end

--============================= INTAKE ===============================--
-- Packet 0x72 is unknown to the core, which would log it as "Unknown
-- packet ID" crap (funcs_packetrecv.c:484). Returning 0 hands it to
-- on_sane_packet instead, whose switch has no default case, so it is
-- silently dropped there having already been dealt with here.
function mod.on_any_packet(pid, data)
	local id = string.byte(data, 1);

	if (id == PKT) then
		local sub = string.byte(data, 2);

		-- one way only, see CLIENT_MAY_SEND
		if (sub == nil or not CLIENT_MAY_SEND[sub]) then
			return 0;
		end

		if (sub == SUB_LIGHT) then
			on_light_request(pid, data);
		end
		return 0;
	end

	return mod.next.on_any_packet(pid, data);
end

--=============================== API ================================--

function flashlight_supported(pid)
	return negotiated(pid);
end

function flashlight_get(pid)
	return sane_pid(pid) and lit[pid] == true;
end

function flashlight_get_config(pid)
	local c = sane_pid(pid) and cfg[pid] or nil;

	if (c == nil) then
		return nil;
	end

	-- a copy, because the caller editing the table in place would
	-- change what every later Light Config says without sending one
	return from_wire(c);
end

-- Switch pid's light and tell everyone who can see it. `on` is the
-- state wanted, not a toggle.
--
-- The carrier does not have to speak the extension and does not have to
-- be alive: a bot carries a light the humans see, and a server that
-- wants a corpse still holding one is entitled to it -- the spec has
-- the client clear a light on the Kill Action, so turning it back on
-- afterwards is a thing the server is allowed to say and this module
-- does not second-guess. What is mirrored automatically is only what
-- the client does on its own.
function flashlight_set(pid, on)
	if (not sane_pid(pid)) then
		return false;
	end

	on = on and true or false;

	-- Nothing to say. Not an optimisation that risks a client missing
	-- it either: whoever negotiates later is sent the whole bitmap, so
	-- the only clients that could have missed this packet are the ones
	-- that get the state a different way.
	if (lit[pid] == on) then
		return true;
	end

	lit[pid] = on;

	for i in piditer(PID_BROADCAST) do
		if (negotiated(i)) then
			send_light(i, pid, on);
		end
	end

	if (flashlight_debug) then
		log("lib_flashlight: #%d's light is %s", pid, on and "on" or "off");
	end

	return true;
end

-- Set pid's beam and tell everyone who can see it. Anything left out of
-- `opts` comes from the flashlight_* defaults, so flashlight_config(pid)
-- with nothing else is "give them the standard beam".
--
-- There is no way to un-configure a player: the extension has no packet
-- for it, and a client holds a config until Player Left. A server that
-- wants a different light sends a different config, which is this
-- again.
function flashlight_config(pid, opts)
	if (not sane_pid(pid)) then
		return false;
	end

	opts = opts or {};
	local color = opts.color or {};

	-- stored as it goes out, clamped and rounded once, so that
	-- flashlight_get_config answers with the beam the clients have
	-- rather than the one that was asked for
	local c = to_wire({reach = opts.reach, cone = opts.cone,
		r = color.r, g = color.g, b = color.b, flicker = opts.flicker});

	cfg[pid] = c;

	for i in piditer(PID_BROADCAST) do
		if (negotiated(i)) then
			send_config(i, pid, c);
		end
	end

	if (flashlight_debug) then
		log("lib_flashlight: #%d's beam is %s", pid, describe(c));
	end

	return true;
end

-- The beam every player without one of their own is drawn in, as it
-- stands in the flashlight_* globals. A copy, like flashlight_get_config.
function flashlight_get_default()
	if (not flashlight_send_default) then
		return nil;
	end

	return from_wire(default_config());
end

-- Re-announce the default beam to everybody who has negotiated. The
-- server may send a Light Config whenever it likes and the client
-- applies each one in full, which is how a policy change lands
-- mid-session. Set flashlight_reach, flashlight_cone, the colour or
-- flashlight_flicker and
-- then call this; without the call the new values only reach clients
-- that negotiate afterwards.
--
-- Which is why the beam lives in globals rather than being passed here:
-- whatever is in them is what every Light Config says, including the
-- one on_ready sends. Exactly teamplay_send_config's bargain.
--
-- It does not touch a player who has a config of their own -- the
-- client only applies the default where there is nothing more specific,
-- and so does flashlight_get_config. Re-beaming those is
-- flashlight_config, one at a time, because that is what asking for
-- them by name meant in the first place.
function flashlight_announce_default()
	announce_default();
end

function flashlight_listen_request(name, fn)
	if (type(name) ~= "string" or type(fn) ~= "function") then
		error("flashlight_listen_request: name and fn required", 2);
	end
	listeners[name] = fn;
end

function flashlight_unlisten_request(name)
	listeners[name] = nil;
end

--============================ LIFECYCLE =============================--

-- Registering is also what re-announces. Whatever a client agreed with
-- the last copy of this module is not something the new copy has any
-- record of, and the client will not repeat itself -- so lib_ext sends
-- the list again to everybody connected, and their replies re-establish
-- the agreement and run on_ready.
--
-- Which also repairs the state across a hot load, in the one direction
-- that can be repaired: the new copy's tables are empty, so every light
-- is off here and the bitmap it sends says so, and every client is put
-- back in step with it. A light that was on before the reload goes out,
-- which is the right way round -- the alternative is a light nothing on
-- the server knows how to switch off.
function mod.on_load()
	if (ext_register == nil) then
		error("lib_flashlight needs lib_ext loaded first "
			.."(config.lua loads it, or: lsdctl <instance> load lib_ext "
			.."lib_flashlight)", 0);
	end

	-- And nothing to hand out here. Everybody already in the game is
	-- covered by the default config on_ready sends them, and giving them
	-- a config of their own instead -- which is what this did before the
	-- default id existed -- would be worse than redundant: a per-player
	-- config overrides the default, so it would pin every player present
	-- at load time to the beam of that moment and leave later
	-- flashlight_announce_default calls unable to move them.
	ext_register("lib_flashlight", EXT_ID, EXT_VERSION, on_ready, "Flashlight");
end

-- Everything this module put in the global table, taken back out again.
--
-- Unloading a module does not undo its globals -- the functions keep
-- working, closed over the state of a module nothing is calling any
-- more -- and consumers ask "is flashlight_set nil?" to find out
-- whether the extension is available at all. Left behind, those names
-- answer yes forever and the guard is dead code.
--
-- The list is exhaustive on purpose: a name added to the API above and
-- forgotten here outlives its own module, and goes on answering for it.
local EXPORTS = {
	"flashlight_supported",
	"flashlight_get", "flashlight_set",
	"flashlight_get_config", "flashlight_config",
	"flashlight_get_default", "flashlight_announce_default",
	"flashlight_listen_request", "flashlight_unlisten_request",
};

-- Every light out on the way down, while there is still something that
-- knows how to say so. Lights are the one piece of this extension a
-- client cannot be talked out of on its own: a config is only ever
-- replaced and a bitmap is only ever re-sent, but a light stays lit
-- until a Light says otherwise, and after this returns there is nothing
-- left to send one. So the last thing this module does is turn them off.
function mod.on_unload()
	for i in piditer(PID_BROADCAST) do
		if (lit[i]) then
			flashlight_set(i, false);
		end
	end

	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end

	listeners = {};

	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
