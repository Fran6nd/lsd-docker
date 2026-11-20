-- lib_pie_menu.lua -- The Pie Menu protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Pie Menu extension (id 0x31, version 1): the
-- ring of six wedges a player opens around the crosshair, each wedge
-- sending one chat line. The point of the extension is that the SERVER
-- chooses what is on it, since only the server knows its commands, its
-- mode and its vocabulary -- so this module is mostly about deciding
-- what to offer, and very little about the wire.
--
-- ONE SUB-PACKET, ONE WAY: Menu, [0x71][0][pie count][pies...], server
-- to client. A client never sends anything on 0x71 and whatever arrives
-- there is dropped (see INTAKE).
--
-- Nothing in LSd's core knows about any of this. Nothing in
-- funcs_packetrecv.c, funcs_send.c, main.c or lua.c touches packet
-- 0x71, and the negotiation is lib_ext's. This module owns packet 0x71
-- and nothing else; load lib_ext before it.
--
-- API (globals):
--   pie_menu_supported(pid)       -> true once ext 0x31 is agreed
--   pie_menu_add(name, pies, order)
--        contribute one pie or a list of pies under `name` (a later
--        add under the same name replaces it). `order` sorts the
--        contributions, lower first; the operator's or the built-in
--        pies sit at PIE_MENU_BASE_ORDER (50), so 100, the default,
--        comes after them and 0 before. Raises on a pie that could not
--        be sent -- the mistake belongs to the caller, at the call.
--        Every negotiated client is re-sent its menu if it changed.
--   pie_menu_slice(name, slices, order)
--        register actions one slice at a time into pies named by id
--        (the default layout's mark, chat, player, watching), stacking
--        with what is there: the slot asked for if free, else the
--        first free one, else a new pie of the same theme after it; a
--        pie not there is created. See REGISTERED SLICES
--   pie_menu_remove(name)         take a contribution back out
--   pie_menu_override(pid, pies)  show ONE player these pies, and only
--        these, instead of the whole menu (a pie or a list, as
--        pie_menu_add takes them); nil puts the menu back. For a script
--        that needs the player's answer now (lib_ask_player): their
--        menu is re-sent when it is set or cleared, it is cleared when
--        they disconnect, and it applies in pie_menu_mode "server".
--        Raises on a pie that could not be sent.
--
-- A COMMAND PUTS ITSELF IN THE MENU by carrying a pie field when it
-- registers -- one slice, or a list:
--
--   local cmd = {name = "votekick", ...,
--       pie = {pie = "player", slot = 1, args = "%p",
--              label = {en = "Vote kick"}, tooltip = {en = "..."}}};
--   register_command(cmd, mod);
--
-- The slice sends "/votekick %p". Labels are written {en = "..."}: so
-- dev/l10n.lua puts them in that script's locales/template.pot, and
-- its locales/<lang>.po translates them -- the translation comes with
-- the registration.
--   pie_menu_refresh([pid])       rebuild and re-send where it changed;
--        for after editing pie_menu or pie_menu_mode live, or after
--        something a slice depends on (a command, a cap) came or went
--   pie_menu_build(pid)           -> the Menu bytes that pid would get,
--        or nil when nothing would be sent. For debugging
--
-- A PIE, as pie_menu_add takes it and as the settings file writes it:
--
--   {id = "social",                   -- optional: what slices register
--                                     --   into (pie_menu_slice, cmd.pie)
--    theme = "Social",                -- the centre caption, may be ""
--    when = "block sky",              -- the contexts, see CONTEXT_NAMES
--    slices = {                       -- up to six, slice 1 at the top,
--      "/ratio %p",                   --   then clockwise; missing = blank
--      {text = "Thanks!", label = "Thanks", tooltip = "To your team"},
--      "",                            -- a blank slice
--      {text = "gg", global = true},  -- to everyone, not just the team
--    }}
--
-- From Lua, a slice may also carry show = function(pid) -> offered to
-- this player?, and its label may be a function(pid) answering what
-- that player reads (a string or a message: "Rocket x3"), asked each
-- time their menu is built -- pie_menu_refresh(pid) when it changes.
--
-- `when` is a string of names ("block sky", "teammate,enemy") or a list
-- of them, or a bitmask number from Lua. Theme, label, tooltip and text
-- are each a string or a map of locale -> string, {en = "Thanks", fr =
-- "Merci"}, each player reading their own (see LANGUAGE): a theme,
-- label or tooltip written as English is also translated by the .po
-- files. From Lua a slice may also
-- carry show = function(pid) -> bool, which blanks it for whoever it
-- answers false for; a pie left with nothing on it is not sent.
--
-- SETTINGS. pie_menu_mode says what a client is sent:
--   "server"  the server's menu: the pies of the `pie_menu` setting, or
--             the built-in ones when it is unset, plus whatever other
--             scripts add
--   "none"    a Menu with no pies -- the spec's "there is no pie menu
--             here", which also switches the client's own menu off
--   "client"  nothing at all, so every client keeps its own
-- and `pie_menu` is a list of pies written as above, e.g.
--
--   pie_menu = [
--       {theme: 'Orders', when: 'block enemy', slices: [
--           {text: '/pingmark %h Attack', label: 'Attack'},
--           {text: '/pingmark %h Defend', label: {en: 'Defend', fr: 'Défendre'}},
--           '',
--           {text: 'Need backup!', label: 'Backup', tooltip: 'Team chat'},
--       ]},
--       {theme: 'Chat', when: 'sky spectator dead', slices: [
--           {text: 'gg', label: 'Good game', global: True},
--       ]},
--   ]
--
-- A blank slice is '' (or {}), not None: the settings parser drops a
-- None from a list, which would move every later slice round by one.
--
-- WHAT IS OFFERED IS CHECKED PER PLAYER. A slice whose text is a
-- /command this server does not have, or that this player may not run
-- (caps.lua's can_see_command), is sent blank instead -- a wedge that
-- only ever answers "unknown command" is worse than an empty one. And
-- /pingmark is Teamplay's, which exists only for a client that
-- negotiated Teamplay, so it is offered only to those. Settable off
-- with pie_menu_hide_unavailable.
--
-- LANGUAGE. The spec wants Themes, Labels and Tooltips in the player's
-- locale, which is the User locale of the Version Response (Extended).
-- Which language that is, and the text in it, are lib_l10n's, as for
-- everything else the server says: /lang overrides the client's locale,
-- and the default layout's labels are translated in locales/<lang>.po.
-- The locale can arrive on either side of the extension negotiation, so
-- a Menu that went out before it is sent again once it arrives, as the
-- spec asks, and again when the player picks another language with /lang
-- -- see mod.after.on_version_ext and mod.after.l10n_lang_changed.
--
-- WHAT THIS DOES NOT DO: anything for clients that don't speak it. A
-- client that does not name ext 0x31 never gets a packet 0x71 and keeps
-- whatever menu it has of its own.

local bit = require("bit");

local EXT_ID = 0x31;
local EXT_VERSION = 1;

-- Pie Menu. The packet id is 64 + the extension id, so 0x71.
local PKT = 64 + EXT_ID;
local SUB_MENU = 0; -- S->C [PKT][0][pie count][pies...]

-- Where the operator's (or the built-in) pies sort among the ones other
-- scripts add. See pie_menu_add.
PIE_MENU_BASE_ORDER = 50;
local DEFAULT_ADD_ORDER = 100;

--============================ THE CODEC =============================--
-- Pure functions: no server API, no globals read. The test loads this
-- file against stubs and drives these directly (mod.codec), so they are
-- what decides whether a client could ever refuse what we send.
local P = {};

-- Contexts, bit by bit (spec "Contexts"). 6-7 are reserved and must be
-- 0, so a mask is 1..63; 0 would be a pie offered nowhere.
P.BLOCK, P.TEAMMATE, P.ENEMY = 1, 2, 4;
P.SPECTATOR, P.DEAD, P.SKY = 8, 16, 32;
P.ALL_CONTEXTS = 63;

-- The names `when` is written in. A few aliases, because the settings
-- file is written by people: "team" for the teammate a player aims at,
-- "alive" for every context a living player can be in, "any" for all.
local CONTEXT_NAMES = {
	block = P.BLOCK, teammate = P.TEAMMATE, team = P.TEAMMATE,
	enemy = P.ENEMY, spectator = P.SPECTATOR, spec = P.SPECTATOR,
	dead = P.DEAD, sky = P.SKY,
	alive = P.BLOCK + P.TEAMMATE + P.ENEMY + P.SKY,
	any = P.ALL_CONTEXTS, all = P.ALL_CONTEXTS,
};
P.CONTEXT_NAMES = CONTEXT_NAMES;

local SLICES = 6;      -- exactly six per pie, always (spec "Pie")
local MAX_PIES = 255;  -- Pie Count is a UByte
local FLAG_GLOBAL = 1; -- slice flag bit 0

-- Well-formed UTF-8 as RFC 3629 has it: no overlong forms, no UTF-16
-- surrogates, nothing past U+10FFFF. That is the spec's bar -- "a Menu
-- is refused when a string behind the 0xff prefix is not well-formed
-- UTF-8" -- and a refused Menu is refused WHOLE, so one bad byte in one
-- tooltip would cost the player every pie. Checked here, never there.
function P.utf8_valid(s)
	local i, n = 1, #s;

	while (i <= n) do
		local c = string.byte(s, i);
		local need, lo, hi = 0, 0x80, 0xbf;

		if (c < 0x80) then
			need = 0;
		elseif (c >= 0xc2 and c <= 0xdf) then
			need = 1;
		elseif (c == 0xe0) then
			need, lo = 2, 0xa0;       -- else overlong
		elseif (c >= 0xe1 and c <= 0xef) then
			need = 2;
			if (c == 0xed) then hi = 0x9f; end -- else a surrogate
		elseif (c == 0xf0) then
			need, lo = 3, 0x90;       -- else overlong
		elseif (c >= 0xf1 and c <= 0xf3) then
			need = 3;
		elseif (c == 0xf4) then
			need, hi = 3, 0x8f;       -- else past U+10FFFF
		else
			return false;             -- 0x80-0xc1, 0xf5-0xff
		end

		if (i + need > n) then
			return false;
		end
		for k = 1, need do
			local d = string.byte(s, i + k);
			-- only the first continuation byte has the narrowed range
			local l, h = 0x80, 0xbf;
			if (k == 1) then l, h = lo, hi; end
			if (d < l or d > h) then
				return false;
			end
		end

		i = i + 1 + need;
	end

	return true;
end

-- One String field on the wire: the bytes, NUL included, or nil and why.
--
-- Lua strings in LSd are UTF-8. Printable ASCII is the same bytes in
-- Code Page 437, so it goes as it is; anything else goes as UTF-8 behind
-- the 0xff prefix of UTF-8 Chat. Sending it raw would be read as CP437
-- and come out as box drawing, and converting to CP437 would lose every
-- character it does not have -- whereas a client parsing this packet
-- must accept the prefix, since the spec defines a Menu by it.
--
-- Which also routes colour codes right. 0x01-0x1f are colours in UTF-8
-- and symbols in CP437, and a Label is "drawn as chat, colour codes
-- included", so a string carrying one goes the UTF-8 way where it means
-- the colour it was written as.
--
-- A Text must not carry 0x01-0x1f at all (spec "Sending"): the client
-- sends it back as chat and may re-encode it on the way, turning a
-- symbol into a colour or the other way round. And no field may carry a
-- NUL, which would end it early and leave the rest of the packet
-- misaligned -- the client would then find bytes past the last pie and
-- refuse the lot.
function P.encode_string(s, is_text)
	if (type(s) ~= "string") then
		return nil, "not a string";
	end
	if (string.find(s, "\0", 1, true)) then
		return nil, "contains a NUL byte";
	end
	if (not P.utf8_valid(s)) then
		return nil, "is not well-formed UTF-8";
	end
	if (is_text and string.find(s, "[\1-\31]")) then
		return nil, "a text may not contain control bytes 0x01-0x1f";
	end

	if (string.find(s, "[^\32-\126]") == nil) then
		return s .. "\0";
	end
	return "\255" .. s .. "\0";
end

-- A Menu out of concrete pies -- every string already a string, every
-- slice present -- or nil and what was wrong with it:
--
--   {{contexts = 3, theme = "T", slices = {
--       {text = "/x", label = "", tooltip = "", global = false}, x6 }}}
--
-- Everything the spec reserves is written as the spec requires (both
-- Message IDs 0, reserved bits 0), and nothing past the last pie, since
-- trailing bytes are one of the two reasons a client refuses a Menu.
function P.encode_menu(pies)
	if (type(pies) ~= "table") then
		return nil, "pies must be a list";
	end
	if (#pies > MAX_PIES) then
		return nil, string.format("%d pies, at most %d fit", #pies, MAX_PIES);
	end

	local out = {string.char(PKT, SUB_MENU, #pies)};

	for p, pie in ipairs(pies) do
		local where = "pie " .. p;
		local ctx = pie.contexts;

		if (type(ctx) ~= "number" or ctx % 1 ~= 0 or ctx < 1
		    or ctx > P.ALL_CONTEXTS) then
			return nil, where .. ": contexts must be 1-63";
		end

		local theme, err = P.encode_string(pie.theme or "", false);
		if (theme == nil) then
			return nil, where .. " theme: " .. err;
		end
		out[#out+1] = string.char(ctx, 0) .. theme;

		local slices = pie.slices;
		if (type(slices) ~= "table" or table.maxn(slices) ~= SLICES) then
			return nil, where .. ": exactly 6 slices";
		end

		for s = 1, SLICES do
			local sl = slices[s];
			local at = where .. " slice " .. s;

			if (type(sl) ~= "table") then
				return nil, at .. ": missing";
			end

			local fields = {};
			for _, f in ipairs({"text", "label", "tooltip"}) do
				local b, e = P.encode_string(sl[f] or "", f == "text");
				if (b == nil) then
					return nil, at .. " " .. f .. ": " .. e;
				end
				fields[#fields+1] = b;
			end

			out[#out+1] = string.char(0, sl.global and FLAG_GLOBAL or 0)
				.. table.concat(fields);
		end
	end

	return table.concat(out);
end

-- "en-US", "EN_us" and "en_us" are one locale. The spec writes them
-- lowercase with "_", and a key in a settings map should match however
-- it was typed.
function P.norm_lang(l)
	if (type(l) ~= "string") then
		return nil;
	end
	l = string.lower(string.gsub(l, "-", "_"));
	if (not string.find(l, "^[a-z][a-z0-9_]*$")) then
		return nil;
	end
	return l;
end

-- A string field as written: a string, or a map of locale -> string.
-- Numbers are let through as their text, since `label: 1` in the
-- settings file means the label "1". Every variant is checked now, not
-- when some player with that locale turns up.
local function norm_text(v, is_text, what)
	if (v == nil or v == false) then
		return "";
	end
	if (type(v) == "number") then
		v = tostring(v);
	end
	if (type(v) == "string") then
		local ok, err = P.encode_string(v, is_text);
		if (ok == nil) then
			error(what .. " " .. err, 0);
		end
		return v;
	end
	if (type(v) ~= "table") then
		error(what .. " must be a string or a map of locale to string", 0);
	end

	local map, any = {}, false;
	for k, s in pairs(v) do
		local lang = P.norm_lang(k);
		if (lang == nil) then
			error(string.format("%s: %q is not a locale", what, tostring(k)), 0);
		end
		if (type(s) == "number") then s = tostring(s); end
		if (type(s) ~= "string") then
			error(string.format("%s[%s] must be a string", what, lang), 0);
		end
		local ok, err = P.encode_string(s, is_text);
		if (ok == nil) then
			error(string.format("%s[%s] %s", what, lang, err), 0);
		end
		map[lang] = s;
		any = true;
	end

	if (not any) then
		error(what .. " is an empty map", 0);
	end
	return map;
end

-- Strictly the keys a slice or a pie has, so a typo -- "lable",
-- "tooltips", "contexts: block" written as "context" -- is an error
-- naming it rather than a field silently left blank.
local SLICE_KEYS = {text = true, label = true, tooltip = true,
	global = true, show = true};
local PIE_KEYS = {id = true, theme = true, when = true, contexts = true,
	slices = true};

local function norm_slice(v, where)
	if (v == nil or v == false or v == "") then
		return {text = "", label = "", tooltip = ""};
	end
	if (type(v) == "string") then
		v = {text = v};
	end
	if (type(v) ~= "table") then
		error(where .. " must be a string or a map", 0);
	end

	for k in pairs(v) do
		if (not SLICE_KEYS[k]) then
			error(string.format("%s: unknown field %q (fields: text, label, "
				.. "tooltip, global, show)", where, tostring(k)), 0);
		end
	end
	if (v.show ~= nil and type(v.show) ~= "function") then
		error(where .. ": show must be a function", 0);
	end

	local s = {
		text = norm_text(v.text, true, where .. " text"),
		-- a label may be a function of the player, answering a string
		-- or a message (an inventory's "Rocket x3"): resolved when that
		-- player's menu is built
		label = type(v.label) == "function" and v.label or norm_text(v.label, false, where .. " label"),
		tooltip = norm_text(v.tooltip, false, where .. " tooltip"),
		global = v.global == true,
		show = v.show,
	};

	-- A label with no text draws a wedge that sends an empty chat line.
	-- Nobody means that; they meant to write the text.
	if (s.text == "" and s.label ~= "") then
		error(where .. ": has a label but no text to send", 0);
	end

	return s;
end

local function norm_contexts(v, where)
	if (type(v) == "number") then
		if (v % 1 ~= 0 or v < 1 or v > P.ALL_CONTEXTS) then
			error(where .. ": a contexts mask must be 1-63", 0);
		end
		return v;
	end

	local names = {};
	if (type(v) == "string") then
		for w in string.gmatch(v, "[^%s,|+]+") do names[#names+1] = w; end
	elseif (type(v) == "table") then
		for _, w in ipairs(v) do names[#names+1] = w; end
	else
		error(where .. ": `when` is required (e.g. 'block sky')", 0);
	end

	local mask = 0;
	for _, w in ipairs(names) do
		local b = type(w) == "string" and CONTEXT_NAMES[string.lower(w)];
		if (not b) then
			error(string.format("%s: unknown context %q (block, teammate, "
				.. "enemy, spectator, dead, sky, alive, any)", where,
				tostring(w)), 0);
		end
		mask = bit.bor(mask, b);
	end

	if (mask == 0) then
		error(where .. ": names no context, so it would never be offered", 0);
	end
	return mask;
end

-- A pie as written into one that can be sent, raising (level 0, with
-- `where` in front) on anything that could not be. The result keeps the
-- locale maps whole; resolve picks from them per player.
function P.normalize_pie(v, where)
	where = where or "pie";
	if (type(v) ~= "table") then
		error(where .. " must be a map", 0);
	end
	for k in pairs(v) do
		if (not PIE_KEYS[k]) then
			error(string.format("%s: unknown field %q (fields: id, theme, "
				.. "when, slices)", where, tostring(k)), 0);
		end
	end

	local slices = v.slices;
	if (type(slices) ~= "table") then
		error(where .. ": slices must be a list", 0);
	end
	-- maxn, not #: a Lua list with a hole in it is a blank slice in the
	-- middle, and # is free to stop at the hole
	local n = table.maxn(slices);
	if (n > SLICES) then
		error(string.format("%s: %d slices, a pie has 6 -- use another pie",
			where, n), 0);
	end
	for k in pairs(slices) do
		if (type(k) ~= "number" or k % 1 ~= 0 or k < 1) then
			error(where .. ": slices must be a list", 0);
		end
	end

	if (v.id ~= nil and (type(v.id) ~= "string" or v.id == "")) then
		error(where .. ": id must be a name", 0);
	end

	local out = {
		id = v.id,
		contexts = norm_contexts(v.when or v.contexts, where),
		theme = norm_text(v.theme, false, where .. " theme"),
		slices = {},
	};
	for i = 1, SLICES do
		out.slices[i] = norm_slice(slices[i], where .. " slice " .. i);
	end

	return out;
end

-- Which variant of a string field a player gets: their locale, then its
-- language alone ("fr" for "fr_ca"), then the server's fallback and its
-- language, then English, then whichever comes first alphabetically --
-- the last so that a map nobody wrote English into still says
-- something, and the same something every time.
function P.pick(v, lang, fallback)
	if (type(v) ~= "table") then
		return v or "";
	end

	local tried = {lang, lang and string.match(lang, "^[^_]+"),
		fallback, fallback and string.match(fallback, "^[^_]+"), "en"};
	for i = 1, 5 do
		local k = tried[i];
		if (k ~= nil and v[k] ~= nil) then
			return v[k];
		end
	end

	local keys = {};
	for k in pairs(v) do keys[#keys+1] = k; end
	table.sort(keys);
	return v[keys[1]] or "";
end

local BLANK = {text = "", label = "", tooltip = "", global = false};

-- Normalised pies into concrete ones for one player. keep(slice, src),
-- if given, is asked about every slice that is not already blank and
-- blanks those it answers false for. A pie with nothing left on it is
-- dropped: it would open as an empty ring, which is a menu that offers
-- nothing in a context where the next pie might have offered something.
--
-- pick(v, lang, fallback, field) chooses each string; P.pick unless
-- given. The server passes lib_l10n's, which also translates.
function P.resolve(pies, lang, fallback, keep, pick)
	local out = {};
	local function get(v, field)
		return (pick or P.pick)(v, lang, fallback, field);
	end

	for _, pie in ipairs(pies) do
		local slices, any = {}, false;

		for i = 1, SLICES do
			local src = pie.slices[i];
			local s = {
				text = get(src.text, "text"),
				label = get(src.label, "label"),
				tooltip = get(src.tooltip, "tooltip"),
				global = src.global,
			};

			-- blank is "Text and Label both empty, whatever its Tooltip"
			if (s.text == "" and s.label == "") then
				s = BLANK;
			elseif (keep ~= nil and not keep(s, src)) then
				s = BLANK;
			else
				any = true;
			end
			slices[i] = s;
		end

		if (any) then
			out[#out+1] = {contexts = pie.contexts,
				theme = get(pie.theme, "theme"), slices = slices};
		end
	end

	return out;
end

--=========================== THE BUILT-IN ===========================--
-- The default layout: the menu a server gets when its operator writes
-- none. Each pie has an id, which is what scripts register their
-- actions into (see pie_menu_slice and cmd.pie): lib_callouts fills
-- `mark` with the gamemode's pings, votekick takes the first wedge of
-- `player`, /lang the last of `watching`. What is here otherwise is only what any LSd has --
-- plain chat lines and the stock commands of group_commands -- so the
-- layout works on its own, and the scripts installed fill it in.
--
-- The labels are messages: each player reads them in their language,
-- from this script's locales/<lang>.po. The texts stay English, because
-- a text is chat that the REST of the server reads, in theirs.
--
-- Slice 1 is the top, then clockwise, so 4 is the bottom: the commonest
-- choice of each pie is a flick straight up.
P.BUILTIN = {
	-- First on a block or an enemy, because a ping is what a player
	-- aiming at something most often wants. Not SKY: %h is empty there.
	-- Empty here; lib_callouts registers the gamemode's pings into it.
	{id = "mark", theme = {en = "Mark"}, when = "block enemy", slices = {}},
	{id = "chat", theme = {en = "Quick chat"}, when = "alive",
	 slices = {
		{text = "Follow me!", label = {en = "Follow me"}},
		{text = "On my way!", label = {en = "On my way"}},
		{text = "Need backup!", label = {en = "Backup"}},
		{text = "Thanks!", label = {en = "Thanks"}},
		{text = "Sorry!", label = {en = "Sorry"}},
		{text = "gg", label = {en = "Good game"}, global = true,
			tooltip = {en = "To everyone"}},
	}},
	-- slice 1 is left for /votekick, which registers itself there
	{id = "player", theme = {en = "Player"}, when = "teammate enemy",
	 slices = {
		"",
		{text = "/ratio %p", label = {en = "Ratio"},
			tooltip = {en = "Their kills per death"}},
		{text = "/ping %p", label = {en = "Latency"}},
		{text = "/ignore %p", label = {en = "Ignore"},
			tooltip = {en = "Hide their chat, or show it again"}},
		{text = "/client %p", label = {en = "Client"},
			tooltip = {en = "The game client they play with"}},
		"",
	}},
	-- Dead or spectating, everything is offered on this one pie and no
	-- other (spec: those contexts are offered their own pies alone).
	-- Slice 6 is left for /lang.
	{id = "watching", theme = {en = "Watching"}, when = "spectator dead",
	 slices = {
		{text = "gg", label = {en = "Good game"}, global = true},
		{text = "/ratio %p", label = {en = "Their ratio"}},
		{text = "Nice shot!", label = {en = "Nice shot"}, global = true},
		{text = "/who", label = {en = "Who's on"}},
		{text = "/ratio", label = {en = "My ratio"}},
		"",
	}},
};

--============================ THE SERVER ============================--
-- Everything below talks to LSd. The test runs it against stubs.

local mod = init_mod();
mod.codec = P;

getcfg("pie_menu_mode", "server",
	"What a client is sent: 'server' (the pie_menu pies, else the "
		.."built-in ones), 'none' (no pie menu at all) or 'client' "
		.."(nothing; clients keep their own).");
-- No getcfg default for pie_menu itself: unset is what means "use the
-- built-in menu", so a default would hide the built-in one for good.
getcfg("pie_menu_hide_unavailable", true,
	"Blank a slice whose /command this server lacks or the player may "
		.."not run.");
getcfg("pie_menu_debug", false,
	"Log every menu sent and every pie that could not be.");

-- A command that exists only for clients that negotiated an extension,
-- so it is offered only to those (teamplay.md: "for anyone else it is
-- an unknown command"). Keyed by command name; the value is the ext id.
local COMMAND_EXT = {pingmark = 48};

local function negotiated(pid)
	return ext_supported ~= nil and ext_supported(pid, EXT_ID) ~= nil;
end

local function dbg(fmt, ...)
	if (pie_menu_debug) then
		log("lib_pie_menu: " .. fmt, ...);
	end
end

-- name -> {order=, seq=, pies={normalised...}}. What other scripts
-- added. seq breaks ties in the order they were added.
local contributions = {};
local next_seq = 0;

-- The operator's pies, normalised once per value of the pie_menu
-- global: comparing the table itself is enough to notice a live edit
-- (`/exec pie_menu = {...}` then pie_menu_refresh()), and re-checking
-- every string of every pie for every player sent to would not be.
local base_src, base_pies = {}, nil;
local builtin_pies = nil;

-- A list of written pies, normalised, the bad ones logged and skipped:
-- one typo in a settings file should cost that pie, not the menu.
local function normalize_list(list, what)
	local out = {};
	for i, v in ipairs(list) do
		local ok, pie = pcall(P.normalize_pie, v, what .. " pie " .. i);
		if (ok) then
			out[#out+1] = pie;
		else
			log("lib_pie_menu: %s; that pie is left out", tostring(pie));
		end
	end
	return out;
end

local function base()
	if (pie_menu == nil) then
		if (builtin_pies == nil) then
			builtin_pies = normalize_list(P.BUILTIN, "built-in");
		end
		return builtin_pies;
	end

	if (pie_menu ~= base_src) then
		base_src = pie_menu;
		if (type(pie_menu) ~= "table") then
			log("lib_pie_menu: pie_menu is a %s, not a list of pies; "
				.."using none of it", type(pie_menu));
			base_pies = {};
		else
			base_pies = normalize_list(pie_menu, "pie_menu");
		end
	end
	return base_pies;
end

--=========================== REGISTERED SLICES ======================--
-- One action at a time, into a pie named by its id: what a script or a
-- command adds (pie_menu_slice, cmd.pie). It takes the slot it asks for
-- if that is free, else the first free one; a full pie continues in
-- another of the same theme and contexts; a pie that is not there is
-- created -- from the definition the registration gives, else from the
-- default layout's.

-- name -> {order=, seq=, items={{pie=<id>, def=, slot=, slice=}}}
local registered = {};

-- id -> the default layout's pie of that id, normalised
local function builtin_def(id)
	if (builtin_pies == nil) then
		builtin_pies = normalize_list(P.BUILTIN, "built-in");
	end
	for _, pie in ipairs(builtin_pies) do
		if (pie.id == id) then return pie; end
	end
end

local REG_KEYS = {pie = true, slot = true, args = true, order = true};

-- One registration as written into an item, raising (level 0) on what
-- could not be sent. `text` is given for a command's own slice.
local function norm_item(spec, where, text)
	if (type(spec) ~= "table") then
		error(where .. " must be a map", 0);
	end

	local fields = {};
	for k, v in pairs(spec) do
		if (not REG_KEYS[k]) then fields[k] = v; end
	end
	if (text ~= nil) then
		if (fields.text ~= nil) then
			error(where .. ": a command's slice sends the command; give args, "
				.. "not text", 0);
		end
		fields.text = text;
	end

	local item = {slice = norm_slice(fields, where)};

	local pie = spec.pie;
	if (type(pie) == "string") then
		item.pie = pie;
	elseif (type(pie) == "table") then
		if (type(pie.id) ~= "string") then
			error(where .. ": pie needs an id", 0);
		end
		local def = {};
		for k, v in pairs(pie) do def[k] = v; end
		def.slices = {};
		item.pie, item.def = pie.id, P.normalize_pie(def, where .. " pie");
	else
		error(where .. ": pie must be a pie id, or {id=, theme=, when=}", 0);
	end

	if (spec.slot ~= nil and (type(spec.slot) ~= "number" or spec.slot % 1 ~= 0
	    or spec.slot < 1 or spec.slot > SLICES)) then
		error(where .. ": slot must be 1-6", 0);
	end
	item.slot = spec.slot;
	return item;
end

-- Commands that put themselves in the menu, from commands.lua's table:
--   cmd.pie = {pie = "player", label = {en = "Vote kick"}, args = "%p"}
-- or a list of those. The slice sends "/<name> <args>". Read every time
-- a menu is built, so a command is in it whenever it is registered,
-- loaded before this module or after. A bad cmd.pie is logged once.
local bad_cmd_pie = setmetatable({}, {__mode = "k"});

local function command_items()
	local out = {};
	if (type(commands) ~= "table") then
		return out;
	end

	local seen, names = {}, {};
	for _, cmd in pairs(commands) do
		if (type(cmd) == "table" and cmd.pie ~= nil and not seen[cmd]) then
			seen[cmd] = true;
			local name = type(cmd.name) == "table" and cmd.name[1] or cmd.name;
			names[#names+1] = {name = tostring(name), cmd = cmd};
		end
	end
	table.sort(names, function(a, b) return a.name < b.name; end);

	for _, n in ipairs(names) do
		local specs = n.cmd.pie;
		if (specs.pie ~= nil or specs.label ~= nil) then specs = {specs}; end
		for i, spec in ipairs(specs) do
			local text = "/" .. n.name .. (spec.args and (" " .. spec.args) or "");
			local ok, item = pcall(norm_item, spec, "/" .. n.name .. " pie " .. i, text);
			if (ok) then
				out[#out+1] = {order = spec.order or DEFAULT_ADD_ORDER, item = item};
			elseif (not bad_cmd_pie[n.cmd]) then
				bad_cmd_pie[n.cmd] = true;
				log("lib_pie_menu: %s; left out", tostring(item));
			end
		end
	end
	return out;
end

local function blank(sl)
	return sl.text == "" and sl.label == "";
end

local function empty_pie(def)
	local slices = {};
	for i = 1, SLICES do slices[i] = {text = "", label = "", tooltip = ""}; end
	return {id = def.id, contexts = def.contexts, theme = def.theme,
		slices = slices};
end

-- The pies with every registered slice placed in them.
local function place(pies, items)
	local out = {};
	for i, pie in ipairs(pies) do
		local slices = {};
		for k = 1, SLICES do slices[k] = pie.slices[k]; end
		out[i] = {id = pie.id, contexts = pie.contexts, theme = pie.theme,
			slices = slices};
	end

	for _, it in ipairs(items) do
		local item = it.item;
		local where = {};
		for i, pie in ipairs(out) do
			if (pie.id == item.pie) then where[#where+1] = i; end
		end

		if (#where == 0) then
			local def = item.def or builtin_def(item.pie);
			if (def == nil) then
				dbg("no pie %q for a slice; left out", item.pie);
			else
				out[#out+1] = empty_pie({id = item.pie, contexts = def.contexts,
					theme = def.theme});
				where[1] = #out;
			end
		end

		if (#where > 0) then
			local at, slot;
			local first = out[where[1]];
			if (item.slot ~= nil and blank(first.slices[item.slot])) then
				at, slot = where[1], item.slot;
			end
			for _, i in ipairs(where) do
				if (at ~= nil) then break; end
				for k = 1, SLICES do
					if (blank(out[i].slices[k])) then at, slot = i, k; break; end
				end
			end
			if (at == nil) then
				-- full: the pie goes on in another just after it
				at, slot = where[#where] + 1, 1;
				table.insert(out, at, empty_pie(first));
			end
			out[at].slices[slot] = item.slice;
		end
	end
	return out;
end

-- pid -> the pies that player is shown instead of all_pies(), normalised
local overrides = pid_connected_table();

-- Every pie on offer, in order: by `order`, then in the order added,
-- with the base pies at PIE_MENU_BASE_ORDER; then every registered
-- slice placed, by `order`, then as registered.
local function all_pies()
	local groups = {{order = PIE_MENU_BASE_ORDER, seq = -1, pies = base()}};
	for _, c in pairs(contributions) do
		groups[#groups+1] = c;
	end
	table.sort(groups, function(a, b)
		if (a.order ~= b.order) then return a.order < b.order; end
		return a.seq < b.seq;
	end);

	local out = {};
	for _, g in ipairs(groups) do
		for _, pie in ipairs(g.pies) do out[#out+1] = pie; end
	end

	local items = {};
	for _, r in pairs(registered) do
		for _, item in ipairs(r.items) do
			items[#items+1] = {order = r.order, seq = r.seq, item = item};
		end
	end
	for i, c in ipairs(command_items()) do
		items[#items+1] = {order = c.order, seq = -1000000 + i, item = c.item};
	end
	if (#items == 0) then
		return out;
	end
	-- stable: by order, then as registered (commands by name, first)
	for i, it in ipairs(items) do it.n = i; end
	table.sort(items, function(a, b)
		if (a.order ~= b.order) then return a.order < b.order; end
		if (a.seq ~= b.seq) then return a.seq < b.seq; end
		return a.n < b.n;
	end);
	return place(out, items);
end

-- Can this player run what this text sends? Plain chat always; a
-- /command only when the server has it, when it is not an extension's
-- command the client lacks, and when caps.lua lets them see it.
local function command_ok(pid, text)
	if (string.sub(text, 1, 1) ~= "/") then
		return true;
	end
	-- No commands.lua means nothing reads a /line at all; it would go
	-- out as chat, which is not what the slice was for.
	if (type(commands) ~= "table") then
		return false;
	end

	local name = string.match(text, "^/(%S+)");
	if (name == nil) then
		return false;
	end
	name = string.lower(name);

	local cmd = commands[name];
	if (cmd == nil) then
		return false;
	end

	local ext = COMMAND_EXT[name];
	if (ext ~= nil and (ext_supported == nil or ext_supported(pid, ext) == nil)) then
		return false;
	end

	if (can_see_command ~= nil) then
		local ok, yes = pcall(can_see_command, pid, cmd);
		if (ok and not yes) then
			return false;
		end
	end

	return true;
end

--============================= LANGUAGE ===============================--
-- lib_l10n's, as everything else the server says: the language the
-- player chose with /lang, else their client's, else the server's
-- default. A label, tooltip or theme is a message -- a language map, or
-- English that a script's locales/<lang>.po translates. A text is
-- picked from its map only, never translated: it is chat that the rest
-- of the server reads.
--
-- Without lib_l10n (the codec's tests), the client's own locale and
-- P.pick, as before.

-- The locale each client reported, as on_version_ext handed it over.
-- Kept here as well as asked of get_client_ext_language because this
-- module's after-hook may run before or after LSd stored it, and the
-- argument is the value either way.
local locale = pid_connected_table();

local function locale_of(pid)
	if (l10n_get_lang ~= nil) then
		return l10n_get_lang(pid);
	end
	local l = locale[pid];
	if (l == nil and get_client_ext_language ~= nil) then
		local ok, got = pcall(get_client_ext_language, pid);
		if (ok) then l = P.norm_lang(got); end
	end
	return l;
end

local function fallback_lang()
	return P.norm_lang(l10n_default_lang) or "en";
end

local function pick(v, lang, fallback, field)
	if (l10n_get_str_lang == nil or v == nil or v == "") then
		return P.pick(v, lang, fallback);
	end
	if (type(v) == "table" or field ~= "text") then
		return l10n_get_str_lang(lang, v);
	end
	return v;
end

-- The Menu bytes for one player, or nil when nothing should be sent.
-- `had` is whether they already have a Menu of ours.
local EMPTY = string.char(PKT, SUB_MENU, 0);

local function build(pid, had)
	if (pie_menu_mode == "client") then
		return nil;
	end
	if (pie_menu_mode == "none") then
		return EMPTY;
	end
	if (pie_menu_mode ~= "server") then
		log("lib_pie_menu: pie_menu_mode %q is not server, none or client; "
			.."using server", tostring(pie_menu_mode));
		pie_menu_mode = "server";
	end

	local function keep(s, src)
		if (src.show ~= nil) then
			local ok, yes = pcall(src.show, pid);
			if (not ok) then
				log("lib_pie_menu: a show() raised for #%d, slice hidden: %s",
					pid, tostring(yes));
				return false;
			end
			if (not yes) then
				return false;
			end
		end
		return not pie_menu_hide_unavailable or command_ok(pid, s.text);
	end

	-- a label that is a function is this player's: asked here
	local function pick_for(v, lang, fallback, field)
		if (type(v) == "function") then
			local ok, r = pcall(v, pid);
			if (not ok) then
				log("lib_pie_menu: a label() raised for #%d: %s", pid, tostring(r));
				r = "";
			end
			v = r or "";
		end
		return pick(v, lang, fallback, field);
	end
	local pies = P.resolve(overrides[pid] or all_pies(), locale_of(pid), fallback_lang(),
		keep, pick_for);

	-- Nothing to offer. A client that has never had a Menu of ours keeps
	-- its own, which beats replacing it with nothing; one that has had
	-- one is told there is none now, or it would go on offering slices
	-- that no longer work.
	if (#pies == 0) then
		return had and EMPTY or nil;
	end

	local bytes, err = P.encode_menu(pies);
	if (bytes == nil) then
		-- Cannot happen for pies that went through normalize_pie; if it
		-- does, sending nothing keeps the client's last good menu.
		log("lib_pie_menu: menu for #%d not sent: %s", pid, err);
		return nil;
	end
	return bytes;
end

-- pid -> {bytes=, lang=} for the last Menu sent: what lets a refresh
-- skip the clients whose menu did not change, and lets the locale
-- arriving tell whether the Menu it has was sent without one.
local sent = pid_connected_table();

local function send_menu(pid, force)
	if (not negotiated(pid)) then
		return false;
	end

	local last = sent[pid];
	local bytes = build(pid, last ~= nil);
	if (bytes == nil or (not force and last ~= nil and last.bytes == bytes)) then
		return false;
	end

	send_packet(pid, bytes);
	sent[pid] = {bytes = bytes, lang = locale_of(pid)};
	dbg("#%d sent %d bytes (%d pies, locale %s)", pid, #bytes,
		string.byte(bytes, 3), tostring(sent[pid].lang));
	return true;
end

local function refresh_all()
	for i in piditer(PID_BROADCAST) do
		send_menu(i, false);
	end
end

-- Negotiated: the first Menu, whatever the locale. If it has not come
-- yet the labels fall back, and on_version_ext sends it again.
local function on_ready(pid)
	send_menu(pid, true);
end

-- The locale arriving. A Menu sent before it "is sent again after it",
-- which is what the spec says and is done literally -- even when the
-- bytes would come out the same, since a client may be waiting on it.
function mod.after.on_version_ext(pid, major, minor, patch, flags, cli, lang)
	local l = P.norm_lang(lang);
	if (l == nil) then
		return;
	end
	locale[pid] = l;

	local last = sent[pid];
	if (last ~= nil and last.lang ~= locale_of(pid)) then
		send_menu(pid, true);
	end
end

-- The player chose another language with /lang: their menu follows.
function mod.after.l10n_lang_changed(pid)
	local last = sent[pid];
	if (last ~= nil and last.lang ~= locale_of(pid)) then
		send_menu(pid, true);
	end
end

-- A leaver's override must not meet the next player in the slot.
function mod.after.on_disconnect(pid)
	overrides[pid] = nil;
end

--============================= INTAKE ===============================--
-- Menu is server to client only and "a server that receives one drops
-- it" -- and so is anything else on 0x71, since no sub-packet goes the
-- other way. Claimed rather than left alone because the core would log
-- every one as "Unknown packet ID" (funcs_packetrecv.c:484); returning
-- 0 hands it to on_sane_packet, whose switch has no default case, so it
-- is dropped there having been dealt with here.
function mod.on_any_packet(pid, data)
	if (string.byte(data, 1) == PKT) then
		return 0;
	end

	return mod.next.on_any_packet(pid, data);
end

--=============================== API ================================--

function pie_menu_supported(pid)
	return negotiated(pid);
end

function pie_menu_add(name, pies, order)
	if (type(name) ~= "string") then
		error("pie_menu_add: name must be a string", 2);
	end
	if (type(pies) ~= "table") then
		error("pie_menu_add: pies must be a pie or a list of pies", 2);
	end
	if (order ~= nil and type(order) ~= "number") then
		error("pie_menu_add: order must be a number", 2);
	end

	-- one pie is a table with slices; a list of them is not
	if (pies.slices ~= nil) then
		pies = {pies};
	end

	local norm = {};
	for i, v in ipairs(pies) do
		local ok, pie = pcall(P.normalize_pie, v, name .. " pie " .. i);
		if (not ok) then
			error("pie_menu_add: " .. tostring(pie), 2);
		end
		norm[i] = pie;
	end

	next_seq = next_seq + 1;
	contributions[name] = {order = order or DEFAULT_ADD_ORDER,
		seq = next_seq, pies = norm};
	refresh_all();
	return true;
end

-- Whether anything defines a pie of this id: the default layout, the
-- operator's, a whole pie added, or a registration that creates it.
local function pie_known(id)
	if (builtin_def(id) ~= nil) then return true; end
	for _, pie in ipairs(base()) do
		if (pie.id == id) then return true; end
	end
	for _, c in pairs(contributions) do
		for _, pie in ipairs(c.pies) do
			if (pie.id == id) then return true; end
		end
	end
	for _, r in pairs(registered) do
		for _, item in ipairs(r.items) do
			if (item.def ~= nil and item.pie == id) then return true; end
		end
	end
	return false;
end

-- One action, or a list of them, into the pies named by id:
--   pie_menu_slice("hostage", {pie = "player", text = "/hostage",
--       label = {en = "Hostages"}, tooltip = {en = "Where they are"}})
-- `pie` is an id ("mark", "chat", "player", "watching" in the default
-- layout), or {id=, theme=, when=} to create it where it is not there.
-- `slot` asks for a wedge (1-6), `order` sorts registrations (default
-- 100). Written {en = "..."}, a label is in the registering script's
-- locales/template.pot, and is translated by its locales/<lang>.po.
-- A later call under the same name replaces it. Raises on a slice that
-- could not be sent, or a pie id nothing defines.
function pie_menu_slice(name, specs, order)
	if (type(name) ~= "string") then
		error("pie_menu_slice: name must be a string", 2);
	end
	if (type(specs) ~= "table") then
		error("pie_menu_slice: a slice, or a list of them", 2);
	end
	if (order ~= nil and type(order) ~= "number") then
		error("pie_menu_slice: order must be a number", 2);
	end
	if (specs.pie ~= nil) then
		specs = {specs};
	end

	local items = {};
	for i, spec in ipairs(specs) do
		local ok, item = pcall(norm_item, spec, name .. " slice " .. i);
		if (not ok) then
			error("pie_menu_slice: " .. tostring(item), 2);
		end
		if (item.def == nil and not pie_known(item.pie)) then
			do
				error(string.format("pie_menu_slice: %s slice %d: no pie %q; "
					.. "give pie = {id=, theme=, when=} to create it",
					name, i, item.pie), 2);
			end
		end
		items[i] = item;
	end

	next_seq = next_seq + 1;
	registered[name] = {order = order or DEFAULT_ADD_ORDER, seq = next_seq,
		items = items};
	refresh_all();
	return true;
end

-- Take back what was added under `name`: pies or slices.
function pie_menu_remove(name)
	if (contributions[name] == nil and registered[name] == nil) then
		return false;
	end
	contributions[name] = nil;
	registered[name] = nil;
	refresh_all();
	return true;
end

-- One player's menu replaced by these pies, or given back (nil). Sent
-- at once, so the player sees the change and not at the next refresh.
function pie_menu_override(pid, pies)
	if (pies == nil) then
		overrides[pid] = nil;
	else
		if (type(pies) ~= "table") then
			error("pie_menu_override: pies must be a pie or a list of pies", 2);
		end
		if (pies.slices ~= nil) then
			pies = {pies};
		end
		local norm = {};
		for i, v in ipairs(pies) do
			local ok, pie = pcall(P.normalize_pie, v, "override pie " .. i);
			if (not ok) then
				error("pie_menu_override: " .. tostring(pie), 2);
			end
			norm[i] = pie;
		end
		overrides[pid] = norm;
	end
	return send_menu(pid, false);
end

function pie_menu_refresh(pid)
	if (pid ~= nil) then
		return send_menu(pid, false);
	end
	refresh_all();
	return true;
end

function pie_menu_build(pid)
	return build(pid, sent[pid] ~= nil);
end

--============================ LIFECYCLE =============================--

local our_hook, prev_hook;

-- Registering is also what re-announces, so a hot load reaches every
-- connected client: their replies run on_ready, and each gets the menu
-- of the new copy.
function mod.on_load()
	if (ext_register == nil) then
		error("lib_pie_menu needs lib_ext loaded first "
			.."(installing the pie_menu script pulls it in: "
			.."lsdctl install pie_menu)", 0);
	end

	-- Read the operator's menu now, so a mistake in it is in the log at
	-- start rather than when the first client negotiates.
	base();

	ext_register("lib_pie_menu", EXT_ID, EXT_VERSION, on_ready, "Pie Menu");

	-- a command registered later with a cmd.pie reaches the menus sent
	-- already. commands.lua has one hook; whoever had it keeps it.
	local prev = commands_register_hook;
	our_hook = function(cmd)
		if (prev ~= nil) then prev(cmd); end
		if (type(cmd) == "table" and cmd.pie ~= nil) then
			refresh_all();
		end
	end;
	prev_hook = prev;
	commands_register_hook = our_hook;
end

-- Everything this module put in the global table, taken back out again:
-- consumers ask "is pie_menu_add nil?" to find out whether there is a
-- pie menu to add to, and a name left standing answers yes for a module
-- that is gone.
--
-- Clients keep the last Menu they were sent. Nothing is sent to take it
-- back: a Menu with no pies would not bring the client's own menu back
-- either, it would leave them with none, and the slices they have still
-- send commands the server still has.
local EXPORTS = {
	"pie_menu_supported", "pie_menu_add", "pie_menu_slice", "pie_menu_remove",
	"pie_menu_refresh", "pie_menu_build", "pie_menu_override", "PIE_MENU_BASE_ORDER",
};

function mod.on_unload()
	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end

	if (commands_register_hook == our_hook) then
		commands_register_hook = prev_hook;
	end

	contributions = {};
	registered = {};
	overrides = pid_connected_table();

	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
