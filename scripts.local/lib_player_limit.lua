-- lib_player_limit.lua -- The Player Limit protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Player Limit extension (id 192, version 1):
-- "tells client server supports up to 255 players. Player ID 255 is
-- reserved for the server and is never given to a player."
--
-- PACKETLESS, which is the whole of the protocol work. There is no
-- packet id, no sub-packet and nothing to parse: the extension is the
-- announcement, and lib_ext makes it along with every other one. So
-- this module is two things -- the registration, and the one knob that
-- makes the claim true.
--
-- WHY LSd CAN MAKE THE CLAIM AT ALL, and why it is 255 rather than the
-- 256 the spec used to say. protocol.h:20-21 is the answer to both:
--
--   #define MAX_PLAYERS 255
--   #define DEFAULT_MAX_PLAYERS 32
--
-- with the comment above it reading "MAX_PLAYERS used for absolute max,
-- 1 less than 256 so get_anon_pid() still functions". So a player id
-- here runs 0 to 254 and 255 is never a player: it is the first handle
-- new_fakepid hands out (commands.lua:116-120) and what get_anon_pid
-- settles on. The reservation the spec asks for is one LSd already
-- keeps, for its own reasons, and the two agree exactly.
--
-- That reservation is also what the Flashlight extension spends: a
-- Light Config addressed to 255 is the beam of every player who has
-- none of their own. Same id, same reason -- it is the one number that
-- cannot be mistaken for somebody.
--
-- THE LIMIT ITSELF is DEFAULT_MAX_PLAYERS, 32, and announcing an
-- extension does not change it. get_effective_max_players is what
-- assign_new_pid counts up to (main.c:187-191) and what the masterlist
-- advertises as capacity (masterlist.lua:25-38, and lib_bot's
-- bot-hiding version of the same sum), so it is the one place the
-- number lives. This module hooks it, and defaults to the 32 the core
-- already returns -- so loading this changes nothing but the
-- announcement until an instance says otherwise.
--
-- A WORD BEFORE RAISING IT. A pid is assigned when a client connects,
-- by assign_new_pid out of on_any_connect, and the extension handshake
-- happens later -- a version request, a response, an ExtensionInfo each
-- way. So at the moment the server has to choose an id it does not yet
-- know whether that client can handle a big one, and there is no
-- arrangement of this module that fixes that; the extension has no
-- mechanism for it and the ordering is the protocol's, not LSd's.
--
-- In practice every Player ID field in 0.75 is already a byte, so a
-- client that simply passes them around copes. What does not cope is a
-- client holding a 32-slot array, and what it does about pid 40 is its
-- own business -- usually dropping the player, sometimes worse. Which
-- is the honest summary: raise this when you know what is connecting,
-- and treat 32 as the number that is safe with everything.
--
-- API (globals): none. Nothing calls a packetless extension; the only
-- question it answers is "is it agreed with this client", and that is
-- ext_supported(pid, 192) through lib_ext, the same as for every other
-- extension. A wrapper here would add a name to the global table and
-- nothing else, so there isn't one.
local mod = init_mod();

local EXT_ID = 192;
local EXT_VERSION = 1;

-- The most player ids this server will hand out. 32 is the core's own
-- DEFAULT_MAX_PLAYERS and the value every client copes with; anything
-- above it needs the paragraph above read first. Clamped to
-- MAX_PLAYERS, because 255 is the reserved id and not a slot, and to 1
-- at the bottom, since a server that can seat nobody is a typo rather
-- than a configuration.
getcfg("player_limit_max", 32);

-- Hooked rather than left alone even at the default, so that the number
-- has one home. An instance that sets player_limit_max gets it applied
-- everywhere the core and the scripts read this -- pid assignment, the
-- anon pid, the advertised capacity -- without hunting for the other
-- places it is spelled.
--
-- Read out of the global on every call instead of being resolved once,
-- which is what makes `player_limit_max = 64` from the console take
-- effect on the next connection rather than the next restart. The
-- masterlist recomputes capacity on every join and disconnect
-- (masterlist.lua:58-74), so the advertised number follows by itself at
-- the next one; it is only the moment between that stays stale.
function mod.get_effective_max_players()
	local n = math.floor(tonumber(player_limit_max) or 32);

	return math.max(1, math.min(n, MAX_PLAYERS));
end

-- Registering is also what re-announces: every connected client was
-- told a list that did not have this extension in it, and none of them
-- will ask again on their own. lib_ext handles that.
--
-- No ready callback. A packetless extension has nothing to send when a
-- client turns out to speak it -- that is what packetless means.
function mod.on_load()
	if (ext_register == nil) then
		error("lib_player_limit needs lib_ext loaded first "
			.."(config.lua loads it, or: lsdctl <instance> load lib_ext "
			.."lib_player_limit)", 0);
	end

	ext_register("lib_player_limit", EXT_ID, EXT_VERSION, nil);
end

-- No EXPORTS sweep, because there are no globals to sweep: see the API
-- note in the header. Unregistering is the whole teardown, and the
-- get_effective_max_players hook is taken off the chain by the module
-- system itself.
function mod.on_unload()
	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end
end

return mod;
