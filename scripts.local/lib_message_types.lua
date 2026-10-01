-- lib_message_types.lua -- The Message Types protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Message Types extension (id 193, version 1):
-- four more chat types on top of the three the base protocol has, so a
-- server can say something a player will actually notice instead of
-- putting everything through the same grey line that scrolls away.
--
--   0 MSG_ALL      the base protocol's three, unchanged
--   1 MSG_TEAM
--   2 MSG_SYSTEM
--   3 MSG_BIG      drawn across the middle of the screen
--   4 MSG_INFO     a notice
--   5 MSG_WARNING  a warning
--   6 MSG_ERROR    an error
--
-- PACKETLESS, which here means it adds no packet of its own: it widens
-- the type byte of the Chat Message the base protocol already has. So
-- there is nothing to parse and nothing to send but chat, and this
-- module is the registration plus one function that picks the type.
--
-- Negotiation belongs to lib_ext, which announces every extension this
-- server speaks in one ExtensionInfo; load lib_ext before this.
--
-- HOW IT DEGRADES IS THE WHOLE POINT. A client that has not negotiated
-- 193 has no idea what a type 5 is, and what it does with one is its
-- own business -- quite possibly nothing at all, which would mean the
-- message was never delivered. That failure is silent and on the far
-- end, so it is not one to risk: every one of these falls back to
-- MSG_SYSTEM for a client that has not agreed, through server_msg,
-- which is the path every other module in this tree already uses and
-- every client already renders.
--
-- So a caller never has to ask. msg_warning() reaches everybody; it is
-- merely louder for the clients that can be loud.
--
-- API (globals):
--   msg_supported(pid)        -> true once ext 193 is agreed
--   msg_send(pid, type, text)    one message at that type
--   msg_big / msg_info / msg_warning / msg_error (pid, text)
--        the four, by name. pid may be a broadcast pid.
--
--   MSG_ALL / MSG_TEAM / MSG_SYSTEM
--   MSG_BIG / MSG_INFO / MSG_WARNING / MSG_ERROR
local mod = init_mod();

local EXT_ID = 193;
local EXT_VERSION = 1;

MSG_ALL = 0;
MSG_TEAM = 1;
MSG_SYSTEM = 2;
MSG_BIG = 3;
MSG_INFO = 4;
MSG_WARNING = 5;
MSG_ERROR = 6;

-- The types this extension adds, as against the three that need no
-- agreement. Anything in here is downgraded for a client that has not
-- negotiated; anything outside it is the base protocol's and goes as
-- asked.
local EXTENDED = {
	[MSG_BIG] = true,
	[MSG_INFO] = true,
	[MSG_WARNING] = true,
	[MSG_ERROR] = true,
};

-- Who an extended message comes from. 255 is the id the Player Limit
-- extension reserves for the server and never gives to a player, which
-- is what the Kick Reason extension also uses for a message the server
-- itself is saying -- so a client looking the sender up finds nobody
-- rather than crediting whoever holds a nearby id.
--
-- The MSG_SYSTEM fallback does NOT use it: that path goes through
-- server_msg, which has always sent from 0 (main.c:1343-1345), and the
-- one thing a fallback must not do is differ from the behaviour it is
-- falling back to.
local SERVER_FROM = 255;

getcfg("message_types_debug", false);

local function negotiated(pid)
	return ext_supported ~= nil and ext_supported(pid, EXT_ID) ~= nil;
end

--=============================== API ================================--

function msg_supported(pid)
	return negotiated(pid);
end

-- Send `text` to `pid` at `type`. `pid` may be a broadcast pid, which
-- is why this iterates rather than sending once: the type a client gets
-- depends on what that client agreed to, so a broadcast is a per-client
-- decision and cannot be one packet.
function msg_send(pid, type, text)
	text = tostring(text);

	if (not EXTENDED[type]) then
		-- the base protocol's own types, which need no agreement from
		-- anybody. Straight out, as asked.
		send_chat(pid, text, type, SERVER_FROM);
		return;
	end

	for i in piditer(pid) do
		if (negotiated(i)) then
			send_chat(i, text, type, SERVER_FROM);
		else
			server_msg(i, text);
		end
	end

	if (message_types_debug) then
		log("lib_message_types: type %d to %s: %q", type, tostring(pid),
			text);
	end
end

function msg_big(pid, text) msg_send(pid, MSG_BIG, text); end
function msg_info(pid, text) msg_send(pid, MSG_INFO, text); end
function msg_warning(pid, text) msg_send(pid, MSG_WARNING, text); end
function msg_error(pid, text) msg_send(pid, MSG_ERROR, text); end

--============================ LIFECYCLE =============================--

-- No ready callback: a packetless extension has nothing to send when a
-- client turns out to speak it. The first thing it ever sends is the
-- first message somebody wants noticed.
function mod.on_load()
	if (ext_register == nil) then
		error("lib_message_types needs lib_ext loaded first "
			.."(config.lua loads it, or: lsdctl <instance> load lib_ext "
			.."lib_message_types)", 0);
	end

	ext_register("lib_message_types", EXT_ID, EXT_VERSION, nil,
		"Message Types");
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
	"msg_supported", "msg_send",
	"msg_big", "msg_info", "msg_warning", "msg_error",
	"MSG_ALL", "MSG_TEAM", "MSG_SYSTEM",
	"MSG_BIG", "MSG_INFO", "MSG_WARNING", "MSG_ERROR",
};

function mod.on_unload()
	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end

	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
