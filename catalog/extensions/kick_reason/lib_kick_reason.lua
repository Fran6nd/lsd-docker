-- lib_kick_reason.lua -- The Kick Reason protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Kick Reason extension (id 194, version 1,
-- PACKETLESS): before the server disconnects a client, it sends that
-- client a Chat Message of type 2 (CHAT_SYSTEM) from player id 255
-- carrying the reason as text. A client that agreed to the extension
-- shows that text as the reason it was disconnected, instead of the bare
-- disconnect code -- and does not show it as chat.
--
-- WHERE THE REASON COMES FROM. LSd has no textual kick reason anywhere:
-- every kick in it is disconnect(pid, code) with an integer (lua.c:853),
-- from command_kick (2), bans (1), afkick (2), votekick (2). So every
-- one of those is covered by hooking disconnect itself, and the text is
-- the code's name from kick_reason_texts -- the codes of protocol075.md
-- "Disconnect Reasons" plus LSd's own 2 for "kicked". A script that has
-- a better reason than the code says so first with kick_reason_set(pid,
-- text), or kicks with kick_reason_kick(pid, text). Code 0 is "no
-- reason", and gets no message unless a text was set.
--
-- WHY THE DISCONNECT WAITS. disconnect() is enet_peer_disconnect, and
-- ENet's enet_peer_disconnect starts by resetting the peer's outgoing
-- queues (enet_peer_reset_queues) -- so a chat message queued in the
-- same tick as the disconnect is thrown away before it is ever sent.
-- That is the whole difficulty with this extension. So for a client
-- that agreed to it, the message goes out now and the real disconnect
-- follows kick_reason_delay seconds later, from the tick: the event loop
-- services the host between ticks (main.c:246), which puts the message
-- on the wire, and the delay leaves room for one reliable resend if the
-- first datagram is lost. Clients that did not agree are disconnected
-- exactly as before, with no delay.
--
-- disconnect_now is NOT covered and cannot be: it is immediate by
-- contract (no on_disconnect, peer gone at once -- lua.c:865-876), and
-- enet_peer_disconnect_now drops queued packets too. Its callers are
-- the connection-time refusals (bans.lua:331, funcs_event.c:32 for a
-- full server) and the shutdown (main.c:1682), all of which happen
-- before a client could have agreed to anything or from C, out of
-- reach -- so no negotiated client is kicked that way by stock LSd.
--
-- API (globals):
--   kick_reason_supported(pid)    -> true once ext 194 is agreed
--   kick_reason_set(pid, text)    the text the next disconnect of `pid`
--                                 sends, over the code's own name
--   kick_reason_kick(pid, text, code)
--        kick_reason_set then disconnect(pid, code or 2)
local mod = init_mod();

local EXT_ID = 194;
local EXT_VERSION = 1;

-- What the spec prescribes: a system message from the server's id.
local CHAT_SYSTEM = 2;
local SERVER_FROM = 255;

-- Kept short on purpose: BetterSpades limits the reason it displays to
-- 16 octets (apidoc/src/send, send_chat). The spec sets no limit, so a
-- longer text set by a script is sent whole.
getcfg("kick_reason_texts", {
	[1] = "Banned",
	[2] = "Kicked",
	[3] = "Wrong version",
	[4] = "Server full",
	[5] = "Server shutdown",
	[10] = "Kicked",
}, "The reason sent for each disconnect code. A code not named here "
	.."sends nothing unless a script set a text.");
getcfg("kick_reason_delay", 0.3,
	"Seconds between sending the reason and disconnecting, so the "
		.."message reaches the client first (ENet drops what is still "
		.."queued at a disconnect).");

local function negotiated(pid)
	return ext_supported ~= nil and ext_supported(pid, EXT_ID) ~= nil;
end

-- pid -> text a script asked for. Cleared on disconnect, so it can never
-- reach the next occupant of the slot.
local explicit = pid_connected_table();

-- pid -> {reason=, at=} for a disconnect that has sent its message and is
-- waiting to happen. A plain table rather than a pid table, cleared by
-- hand below, so that the tick can skip it with one next() when empty.
local pending = {};

-- Ticks counted, so that "later" can mean at least one service of the
-- host later, whatever the clock says. See mod.after.tick.
local ticks = 0;

--=============================== API ================================--

function kick_reason_supported(pid)
	return negotiated(pid);
end

function kick_reason_set(pid, text)
	if (type(pid) ~= "number" or pid < 0 or pid >= MAX_PLAYERS) then
		return;
	end
	-- a lib_l10n message is kept as one: send_chat translates it for
	-- the player being kicked
	if (text ~= nil and not (l10n_is_msg ~= nil and l10n_is_msg(text))) then
		text = tostring(text);
	end
	explicit[pid] = text;
end

function kick_reason_kick(pid, text, code)
	kick_reason_set(pid, text);
	disconnect(pid, code or 2);
end

-- The text a disconnect with `code` sends to `pid`, or nil for none.
local function reason_text(pid, code)
	local text = explicit[pid];
	if (text == nil and type(kick_reason_texts) == "table") then
		text = kick_reason_texts[code];
	end
	if (text == nil or text == "") then
		return nil;
	end
	if (l10n_is_msg ~= nil and l10n_is_msg(text)) then
		return text;
	end
	return tostring(text);
end

--============================ THE HOOKS =============================--

-- mod.late, as close to the C as a script gets: every ordinary hook on
-- disconnect has already run and decided this is really happening, so a
-- message sent here is never for a kick that something then cancelled.
function mod.late.disconnect(pid, reason)
	-- already on its way out; the first reason stands
	if (pending[pid] ~= nil) then
		return;
	end

	local text = reason_text(pid, reason);
	explicit[pid] = nil;

	if (text == nil or not negotiated(pid)) then
		return mod.late.next.disconnect(pid, reason);
	end

	send_chat(pid, text, CHAT_SYSTEM, SERVER_FROM);

	pending[pid] = {reason = reason, tick = ticks,
		at = get_time() + math.max(0, tonumber(kick_reason_delay) or 0)};
end

-- A slot that empties some other way takes its pending kick with it, so
-- a stale one can never hit whoever connects into it next.
function mod.late.disconnect_now(pid, reason)
	pending[pid] = nil;
	return mod.late.next.disconnect_now(pid, reason);
end

function mod.after.on_disconnect(pid)
	pending[pid] = nil;
end

-- Never in the tick the kick was asked for, whatever kick_reason_delay
-- says: a kick asked for earlier in this same tick (votekick and afkick
-- both kick from their tick hooks) has not had its message sent yet,
-- and the host is only serviced between ticks. So a kick stamped with
-- the count as it stands is due only once the count has moved on, and
-- the count moves on at the END of this hook.
function mod.after.tick()
	if (next(pending) == nil) then
		ticks = ticks + 1;
		return;
	end

	local now = get_time();
	local due = {};

	for pid, p in pairs(pending) do
		if (ticks > p.tick and now >= p.at) then
			due[#due+1] = pid;
		end
	end
	ticks = ticks + 1;

	for _, pid in ipairs(due) do
		local p = pending[pid];
		pending[pid] = nil;
		mod.late.next.disconnect(pid, p.reason);
	end
end

--============================ LIFECYCLE =============================--

function mod.on_load()
	if (ext_register == nil) then
		error("lib_kick_reason needs lib_ext loaded first "
			.."(its script pulls lib_ext in; check with: lsdctl status)", 0);
	end

	-- nothing to say to a client that has just agreed: the first and
	-- only message is the one before it is kicked
	ext_register("lib_kick_reason", EXT_ID, EXT_VERSION, nil,
		"Kick Reason");
end

local EXPORTS = {
	"kick_reason_supported",
	"kick_reason_set",
	"kick_reason_kick",
};

function mod.on_unload()
	-- Kicks already announced are carried out now rather than forgotten:
	-- once this module is gone nothing would ever do them. on_unload runs
	-- before the chains are unlinked (core.lua unregister), so `next` is
	-- still the rest of the chain.
	for pid, p in pairs(pending) do
		pending[pid] = nil;
		mod.late.next.disconnect(pid, p.reason);
	end

	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end

	for _, name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
