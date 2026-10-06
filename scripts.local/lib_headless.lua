-- lib_headless.lua -- headless clients are not population
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Keeps a fleet of headless clients out of the player count this
-- server advertises to the public server lists.
--
-- WHY THIS IS NOT lib_bot's JOB ALREADY. lib_bot hides its own bots,
-- and does it well: advertise_humans() recomputes the published count
-- from scratch and a scripted bot is simply not in it. But a scripted
-- bot has no peer and no handshake, and lib_bot recognises one by
-- looking it up in its own registry. A headless client is the opposite
-- in every respect -- it dials in over UDP, completes the handshake,
-- has an RTT and a client identifier, and from the engine's side is a
-- player in every way that matters. Nothing lib_bot knows can tell it
-- apart from a person.
--
-- The one thing that can is the version handshake, which is why this
-- module exists and why it is this small: all it does is read the
-- os_info a client volunteers and tell lib_bot what it found.
--
-- WHY IT MATTERS, and it is not tidiness. A server that tells the
-- master list it has a hundred players when it has none is
-- indistinguishable from a server padding its numbers to climb the
-- list, and that is the kind of thing a list operator delists for. The
-- count has to be true.
--
-- WHAT IS MATCHED. aosbot sends its ident as the os_info field of the
-- VersionResponse -- "AosBot", or "AosBot key=<token>" when a token is
-- configured (BotClient.cpp's version_os_info). lsd hands that whole
-- string to on_version as `msg`, and the server log already prints it:
--
--   172.23.0.1:55029 (#59) got version: 'D' (68) v0.75.0: AosBot
--
-- so a prefix match on a configured list of idents is the whole test.
--
-- ON SPOOFING. Any client can claim to be AosBot and drop out of the
-- advertised count, and nothing here can stop that. It is worth being
-- clear about what that costs: the player count on a server list is
-- wrong by one, in the direction of under-claiming. A client cannot
-- use this to get a slot it could not otherwise have, to be invisible
-- in the game, or to affect anything a player sees -- the count is
-- published and nothing reads it back. Under-claiming is also the safe
-- direction: the failure this module exists to prevent is claiming
-- players that do not exist.
--
-- If that is not good enough, aosbot's ident can carry a shared token
-- (`ident-token` in its config, which is what `--print-ident` shows),
-- and headless_idents can be set to the full "AosBot key=<token>"
-- string. Then only a client that knows the token can claim it.
--
-- API (globals): none. The decision reaches the masterlist through
-- lib_bot's bot_mark_nonhuman, which is the only writer of that count
-- and should stay that way.
local mod = init_mod();

require "lib_bot";   -- bot_mark_nonhuman

-- os_info prefixes that mean "not a person". A list, so a second fleet
-- or a differently named build can be added without touching code.
--
-- Matched as a PREFIX, because the ident may be followed by " key=..."
-- and because a build could append its own version.
getcfg("headless_idents", {"AosBot"},
	"Clients whose version handshake starts with one of these are "
		.."headless and are left out of the player count sent to the "
		.."server lists. Matched as a prefix.");

local function is_headless(msg)
	if (msg == nil or headless_idents == nil) then
		return false;
	end

	for _, want in pairs(headless_idents) do
		if (type(want) == "string" and want ~= ""
				and msg:sub(1, #want) == want) then
			return true;
		end
	end

	return false;
end

-- on_version carries the os_info as its last argument
-- (funcs_event.c:262, and lua.c's con_version marshals it). It arrives
-- BEFORE on_join -- the server log prints "got version" then "joined
-- as" -- so the mark is already in place the first time lib_bot
-- recomputes the count for this pid.
--
-- A plain hook and not mod.after: process_before_after assigns
-- tbl[name] outright, so a mod.after.on_version here would REPLACE
-- lib_ext's, which is how the extension handshake gets answered at
-- all. Chaining through mod.next is the only safe way to share an
-- event, and it costs nothing.
function mod.on_version(pid, idChar, major, minor, patch, msg)
	if (is_headless(msg)) then
		bot_mark_nonhuman(pid, true);
	end

	return mod.next.on_version(pid, idChar, major, minor, patch, msg);
end

-- No on_disconnect hook: lib_bot clears the mark in its own, because
-- pids are recycled and the clear has to happen whether this module is
-- loaded or not.
--
-- Nothing to unregister either. Unloading this stops new clients being
-- marked; the ones already marked stay marked until they leave, which
-- is the honest state of affairs -- they are still headless.
return mod;
