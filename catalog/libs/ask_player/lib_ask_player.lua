-- lib_ask_player.lua -- Ask a player a question, get one answer back
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Scripts keep needing to put a question to one player -- "join the
-- other team?", "really surrender?" -- and each would otherwise write
-- its own command, its own timeout and its own cleanup for the player
-- who leaves with the question open. This is that, once.
--
-- API (globals):
--   ask_player(pid, question, choices, callback, opts) -> id, or nil
--        question  a message, {en = "..."}, read in each player's language
--        choices   2 to 6 of {key = "yes", label = {en = "Yes"}}; a key
--                  is letters, digits, _ or -, and not a bare number
--                  (a number picks by position)
--        callback  callback(pid, key): key is nil on timeout, cancel or
--                  disconnect. Run under pcall; an error is logged.
--        opts      {secs = n}: the timeout, ask_player_secs by default
--        nil comes back, and the log says why, for a call that is wrong.
--   ask_player_cancel(pid [, id]) -> how many were cancelled
--        one question (open or waiting) by id, or all of the player's;
--        their callbacks get nil
--   ask_player_open(pid)          -> the open question {id=, question=,
--        choices=}, or nil
--
-- IN CHAT the player gets the question, then its choices numbered:
--
--   1) Yes  2) No -- answer with /answer <number>
--
-- and /answer <number or key> answers. A wrong answer is told so and
-- the choices are stated again.
--
-- IN THE PIE MENU, while a question is open, that player is shown ONE
-- pie -- the question as its theme, the choices as wedges that send
-- /answer <key> -- in every context, so it is under their hand whether
-- they are alive, dead or spectating. It is pie_menu_override's, and
-- the normal menu comes back with the answer. A client without the pie
-- menu answers in chat, which always works.
--
-- ONE QUESTION AT A TIME per player: asked while another is open, it
-- waits and is put when that one is answered, so two scripts cannot
-- overwrite each other's wedges. Its timeout starts when it is put, not
-- when it was asked. A player who leaves gets nil for all of theirs.
local mod = init_mod();

getcfg("ask_player_secs", 30,
	"Seconds a player has to answer a question before it is dropped.");

local MAX_CHOICES = 6;

local HINT = {en = "answer with /answer <number>"};
local WRONG = {en = "That is not one of the answers."};
local NONE = {en = "Nobody has asked you anything."};

-- pid -> the question put to them: {id, question, choices, callback,
-- deadline}; and pid -> the ones waiting, oldest first
local open = {};
local waiting = {};
local next_id = 0;

-- Callbacks belong to other scripts: one that raises must not take the
-- others down, nor leave a question open.
local function call(q, pid, key)
	local ok, err = pcall(q.callback, pid, key);
	if (not ok) then
		log("lib_ask_player: callback for #%d raised: %s", pid, tostring(err));
	end
end

--============================ THE ASKING ============================--

-- The choices, as one line in this player's language.
local function choices_line(pid, q)
	local parts = {};
	for i, c in ipairs(q.choices) do
		parts[i] = i .. ") " .. l10n_str(pid, c.label);
	end
	return table.concat(parts, "  ") .. " -- " .. l10n_str(pid, HINT);
end

local function pie_of(q)
	local slices = {};
	for i, c in ipairs(q.choices) do
		slices[i] = {text = "/answer " .. c.key, label = c.label};
	end
	return {id = "ask_player", theme = q.question, when = "any", slices = slices};
end

local function put(pid, q)
	open[pid] = q;
	q.deadline = get_time() + q.secs;
	server_msg(pid, l10n_str(pid, q.question));
	server_msg(pid, choices_line(pid, q));
	-- Too long a question for a pie's caption is a pie that cannot be
	-- sent; the chat has it, so that is logged and not fatal.
	if (pie_menu_override ~= nil) then
		local ok, err = pcall(pie_menu_override, pid, pie_of(q));
		if (not ok) then
			log("lib_ask_player: no pie for #%d: %s", pid, tostring(err));
		end
	end
end

-- Close the open question and put the next one, if any, before the
-- callback runs, so whatever the callback asks goes behind the queue.
local function finish(pid, key)
	local q = open[pid];
	if (q == nil) then
		return;
	end
	open[pid] = nil;
	local nxt = waiting[pid] and table.remove(waiting[pid], 1);
	if (nxt ~= nil) then
		put(pid, nxt);
	elseif (pie_menu_override ~= nil) then
		pie_menu_override(pid, nil);
	end
	call(q, pid, key);
end

local function valid(question, choices, callback)
	if (question == nil or type(callback) ~= "function"
		or type(choices) ~= "table" or #choices < 2 or #choices > MAX_CHOICES) then
		return "needs a question, 2 to " .. MAX_CHOICES .. " choices and a callback";
	end
	local seen = {};
	for _, c in ipairs(choices) do
		local k = type(c) == "table" and c.key;
		if (type(k) ~= "string" or not string.match(k, "^[%w_%-]+$")
			or string.match(k, "^%d+$") or c.label == nil) then
			return "a choice needs a label and a key of letters, digits, _ or - "
				.. "that is not a number";
		end
		if (seen[string.lower(k)]) then
			return "the key " .. k .. " is there twice";
		end
		seen[string.lower(k)] = true;
	end
	return nil;
end

function ask_player(pid, question, choices, callback, opts)
	local why = valid(question, choices, callback);
	if (why ~= nil) then
		log("lib_ask_player: not asked: %s", why);
		return nil;
	end
	next_id = next_id + 1;
	local q = {id = next_id, question = question, callback = callback,
		secs = tonumber(opts and opts.secs) or ask_player_secs,
		choices = {}};
	for i, c in ipairs(choices) do
		q.choices[i] = {key = c.key, label = c.label};
	end
	if (open[pid] == nil) then
		put(pid, q);
	else
		waiting[pid] = waiting[pid] or {};
		table.insert(waiting[pid], q);
	end
	return q.id;
end

function ask_player_open(pid)
	local q = open[pid];
	return q and {id = q.id, question = q.question, choices = q.choices} or nil;
end

function ask_player_cancel(pid, id)
	local n = 0;
	local list = waiting[pid] or {};
	-- the waiting first, so closing the open one does not put one of
	-- the questions that are being cancelled
	for i = #list, 1, -1 do
		if (id == nil or list[i].id == id) then
			local q = table.remove(list, i);
			n = n + 1;
			call(q, pid, nil);
		end
	end
	if (open[pid] ~= nil and (id == nil or open[pid].id == id)) then
		n = n + 1;
		finish(pid, nil);
	end
	return n;
end

--============================ THE ANSWER ============================--

-- A number is a position, anything else a key, in any case.
local function pick(q, arg)
	local n = tonumber(arg);
	if (n ~= nil) then
		return q.choices[n] ~= nil and n % 1 == 0 and q.choices[n].key or nil;
	end
	arg = string.lower(arg or "");
	for _, c in ipairs(q.choices) do
		if (string.lower(c.key) == arg) then
			return c.key;
		end
	end
	return nil;
end

local cmd = {name = "answer", usage = "<number|key>",
	desc = "Answer the question the server has asked you."};
function cmd.func(pid, argv)
	local q = open[pid];
	if (q == nil) then
		l10n_send_chat(pid, NONE);
		return;
	end
	local key = pick(q, argv[1]);
	if (key == nil) then
		l10n_send_chat(pid, WRONG);
		server_msg(pid, choices_line(pid, q));
		return;
	end
	finish(pid, key);
end
register_command(cmd, mod);

--============================ THE CLOCK =============================--

function mod.after.tick()
	local now = get_time();
	local late = {};
	for pid, q in pairs(open) do
		if (now >= q.deadline) then
			late[#late+1] = pid;
		end
	end
	for _, pid in ipairs(late) do
		finish(pid, nil);
	end
end

-- Nobody is left to answer, and the slot goes to someone else: every
-- question of theirs is over, the open one and the waiting. The pie
-- menu drops its own override on a disconnect, so none is cleared here.
function mod.after.on_disconnect(pid)
	local q, list = open[pid], waiting[pid] or {};
	open[pid], waiting[pid] = nil, nil;
	if (q ~= nil) then
		call(q, pid, nil);
	end
	for _, w in ipairs(list) do
		call(w, pid, nil);
	end
end

local EXPORTS = {"ask_player", "ask_player_cancel", "ask_player_open"};

function mod.on_unload()
	for pid in pairs(open) do
		if (pie_menu_override ~= nil) then
			pie_menu_override(pid, nil);
		end
	end
	open, waiting = {}, {};
	for _, name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
