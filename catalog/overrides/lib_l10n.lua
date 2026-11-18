-- lib_l10n.lua -- Every message in the player's own language
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Replaces upstream's lib_l10n, whose API every LSd script already uses
-- and which this keeps whole: l10n_send_chat(pid, {en="..."}, {name=x}),
-- l10n_get_str_pid, l10n_get_str_lang, l10n_log, l10n_get_lang. What it
-- adds is where the other languages come from, and messages that are
-- translated for each player they reach.
--
-- THE TEXT IS THE KEY, as in zerospades (Sources/Core/Strings.cpp): a
-- message is written in English, and its English is what a translation
-- is looked up by. Placeholders are LSd's, %(name). A message table may
-- still carry its own translations inline, {en="Hi", fr="Salut"}, which
-- win over the files; `ctx` tells two identical English strings apart.
--
-- TRANSLATIONS ARE PER SCRIPT. A catalog entry ships
-- locales/<lang>.po beside its module; the entrypoint installs it as
-- scripts/locales/<lang>/<id>.po, and every file of a language is merged
-- into one catalog the first time somebody needs that language. The
-- files are gettext's, so any .po editor works on them.
--
-- WHICH LANGUAGE. What the player chose with /lang, else the locale
-- their client reported (OpenSpades and its forks send it in the version
-- reply LSd asks every client for on connect), else l10n_default_lang.
-- A locale falls back to its language, then to the default, then to
-- English: a fr_ca player reads fr_ca, then fr.
--
-- ONLY FOR CLIENTS THAT CAN SHOW IT. Translation is gated on the client:
-- l10n_clients names the clients that get it and the oldest version of
-- each, matched in the version string the client reports (LSd's
-- get_client_msg; ZeroSpades writes "... | ZeroSpades 0.0.9 <commit>").
-- Every other client -- older ZeroSpades, OpenSpades, BetterSpades,
-- Voxlap -- reads l10n_default_lang, and /lang tells them why it cannot
-- change it.
--
-- MESSAGES, for anything that is not a one-off chat line:
--
--   local m = l10n_msg({en="%(name) was kicked"}, {name=n})  -- or a
--   local m = l10n_msg("%(name) was kicked", {name=n})  -- plain string
--   server_msg(PID_BROADCAST, m)   -- each player reads their language
--   l10n_msgn({en="%(n) bot", en_plural="%(n) bots"}, count)
--   l10n_str(pid, m)               -- the text for one player
--   l10n_text(setting, {name=x})   -- a setting's text, string or map
--
-- SETTINGS. Any text an operator writes -- motd lines, tips, kick
-- reasons -- may be a string or a language map, {en: "Hi", fr: "Salut"};
-- server_msg and send_chat take a map as they take a message.
--
-- A message is not a string: it is turned into one per recipient, when
-- it is sent. server_msg and send_chat take one anywhere a string goes,
-- to one player or a broadcast, so a script can store a message, put it
-- in `tips`, or hand it to another script, and it is still translated
-- for whoever finally reads it. tostring() gives the server's default
-- language, for logs.
local mod = init_mod();
local P = require "l10n_po";

getcfg("l10n_default_lang", "en");
getcfg("l10n_log_lang", "en");
getcfg("l10n_dir", "scripts/locales");
getcfg("l10n_clients", {ZeroSpades = "0.0.9"},
	"The clients translated for, each with its oldest version: "
		.. "{ZeroSpades: '0.0.9'}. Others read l10n_default_lang.");

-- the languages a player may pick, from what is installed; nil until
-- first asked
local installed_langs = nil;

--============================== CATALOGS ============================--

-- lang -> {entries=, plural=}, or false when there are no files for it
local catalogs = {};

local function list_dir(path)
	local ok, lfs = pcall(require, "lfs");
	local out = {};
	if (not ok or lfs.attributes(path, "mode") ~= "directory") then
		return out;
	end
	for name in lfs.dir(path) do
		if (name ~= "." and name ~= "..") then
			out[#out+1] = name;
		end
	end
	table.sort(out);
	return out;
end

local function catalog(lang)
	local cat = catalogs[lang];
	if (cat ~= nil) then
		return cat or nil;
	end

	cat = false;
	local dir = l10n_dir .. "/" .. lang;
	for _, name in ipairs(list_dir(dir)) do
		if (string.find(name, "%.po$")) then
			local f = io.open(dir .. "/" .. name);
			local text = f and f:read("*a");
			if (f) then f:close(); end

			local ok, got = pcall(P.parse, text or "");
			if (not ok) then
				log("lib_l10n: %s/%s: %s", dir, name, tostring(got));
			else
				if (not cat) then
					cat = {entries = {}, plural = got.plural};
				end
				-- the first script to translate a text keeps it
				for k, v in pairs(got.entries) do
					if (cat.entries[k] == nil) then
						cat.entries[k] = v;
					end
				end
			end
		end
	end

	catalogs[lang] = cat;
	return cat or nil;
end

-- The languages with at least one translation in use, plus English: a
-- language whose files hold only drafts (fuzzy, unreviewed) is not
-- offered, since a player choosing it would read English throughout.
function l10n_languages()
	if (installed_langs == nil) then
		installed_langs = {"en"};
		for _, name in ipairs(list_dir(l10n_dir)) do
			local l = P.norm_lang(name);
			local cat = l and l ~= "en" and catalog(l);
			if (cat and next(cat.entries) ~= nil) then
				installed_langs[#installed_langs+1] = l;
			end
		end
	end
	return installed_langs;
end

--============================== MESSAGES ============================--

local Msg = {};
Msg.__index = Msg;

function l10n_is_msg(x)
	return getmetatable(x) == Msg;
end

-- Keys a message table may have besides its languages
local META = {ctx = true, en_plural = true};

-- A language map as a settings file writes one, {en: "Hi", fr: "Salut"}:
-- a table of locale -> text, and nothing else. It need not have English
-- -- an operator writing for a French server may give only fr.
function l10n_is_map(v)
	if (type(v) ~= "table" or getmetatable(v) ~= nil or next(v) == nil) then
		return false;
	end
	for k, x in pairs(v) do
		if (not META[k] and (P.norm_lang(k) ~= k or type(x) ~= "string")) then
			return false;
		end
	end
	return true;
end

local function as_tab(msg)
	if (type(msg) == "string") then
		return {en = msg};
	end
	if (not l10n_is_map(msg)) then
		error("a message is an English string or a table of locale = text", 3);
	end
	return msg;
end

function l10n_msg(msg, interptab)
	return setmetatable({tab = as_tab(msg), args = interptab}, Msg);
end

-- A message whose words depend on a count: msg.en is the singular,
-- msg.en_plural the plural, and the .po's Plural-Forms picks for every
-- other language. %(n) is the count unless interptab says otherwise.
function l10n_msgn(msg, count, interptab)
	local tab = as_tab(msg);
	local args = {};
	for k, v in pairs(interptab or {}) do args[k] = v; end
	if (args.n == nil) then args.n = count; end
	return setmetatable({tab = tab, args = args, count = count}, Msg);
end

-- English's own rule, for the source text and for an inline plural
-- written without a catalog to say how that language counts
local function en_plural(n)
	return n == 1 and 0 or 1;
end

local function pick_form(forms, index)
	local s = forms[index + 1];
	if (s == nil or s == "") then
		s = forms[1];
	end
	return s;
end

local resolve;

-- The placeholders' values in `lang`: a value that is itself a message
-- -- "following %(name)" inside "%(team) hostage: %(state)" -- is
-- translated into the same language as the message around it.
local function args_in(m, lang)
	local args = m.args;
	if (args == nil) then
		return nil;
	end
	local out;
	for k, v in pairs(args) do
		if (l10n_is_msg(v)) then
			out = out or {};
			out[k] = resolve(v, lang);
		end
	end
	if (out == nil) then
		return args;
	end
	for k, v in pairs(args) do
		if (out[k] == nil) then out[k] = v; end
	end
	return out;
end

-- The text of `m` in `lang`, best candidate first.
function resolve(m, lang)
	local tab = m.tab;
	local key = tab.en and P.key(tab.ctx, tab.en);
	local plural = m.count ~= nil;
	m = {tab = tab, count = m.count, args = args_in(m, lang)};

	for _, l in ipairs(P.candidates(lang, l10n_default_lang)) do
		local cat = (l ~= "en") and catalog(l) or nil;
		local rule = cat and cat.plural or en_plural;

		if (l == "en") then
			if (plural and tab.en_plural ~= nil and en_plural(m.count) ~= 0) then
				return P.interp(tab.en_plural, m.args);
			end
			if (tab.en ~= nil) then
				return P.interp(tab.en, m.args);
			end
			-- no English and nothing better: whatever there is, the
			-- same one every time
			local keys = {};
			for k in pairs(tab) do
				if (not META[k]) then keys[#keys+1] = k; end
			end
			table.sort(keys);
			return P.interp(tab[keys[1]], m.args);
		end

		local inline = tab[l];
		if (type(inline) == "string") then
			return P.interp(inline, m.args);
		elseif (type(inline) == "table" and plural) then
			local s = pick_form(inline, rule(m.count));
			if (s ~= nil) then return P.interp(s, m.args); end
		end

		local e = cat and key and cat.entries[key];
		if (type(e) == "string") then
			return P.interp(e, m.args);
		elseif (type(e) == "table") then
			local s = pick_form(e, plural and rule(m.count) or 0);
			if (s ~= nil) then return P.interp(s, m.args); end
		end
	end
end

function Msg:__tostring()
	return resolve(self, l10n_log_lang);
end

-- A setting's text as a message: a language map, or a string taken as
-- English and translated where a catalog has it. %(name) placeholders
-- are filled from interptab. nil stays nil; a message is kept.
function l10n_text(v, interptab)
	if (v == nil or l10n_is_msg(v)) then
		return v;
	end
	if (type(v) == "string" or l10n_is_map(v)) then
		return l10n_msg(v, interptab);
	end
	return tostring(v);
end

-- The text of `msg` for one player. A plain string is returned as is.
function l10n_str(pid, msg)
	if (not l10n_is_msg(msg)) then
		return msg;
	end
	return resolve(msg, l10n_get_lang(pid));
end

--=========================== THE LANGUAGE ===========================--

-- pid -> what they chose with /lang; cleared when they leave
local chosen = pid_connected_table();

--============================ THE GATE ==============================--

local function version_of(s)
	local a, b, c = string.match(tostring(s), "^(%d+)%.(%d+)%.(%d+)");
	if (a == nil) then return nil; end
	return {tonumber(a), tonumber(b), tonumber(c)};
end

local function at_least(v, min)
	for i = 1, 3 do
		if (v[i] ~= min[i]) then return v[i] > min[i]; end
	end
	return true;
end

-- Whether this version string is a client l10n_clients lets translate.
-- Pure, so the tests can ask it directly.
function l10n_client_matches(msg)
	if (type(msg) ~= "string" or type(l10n_clients) ~= "table") then
		return false;
	end
	for name, min in pairs(l10n_clients) do
		local want = version_of(min);
		local escaped = string.gsub(tostring(name), "%p", "%%%0");
		for ver in string.gmatch(msg, "%f[%w]" .. escaped .. " (%d+%.%d+%.%d+)") do
			local v = version_of(ver);
			if (want ~= nil and v ~= nil and at_least(v, want)) then
				return true;
			end
		end
	end
	return false;
end

-- pid -> {msg=, ok=}: the answer for the version string it was worked
-- out from, so a reply arriving later is seen
local gate = pid_connected_table();

-- Whether `pid` gets translations at all.
function l10n_client_ok(pid)
	if (is_fakepid(pid)) then
		return false;
	end
	local ok, msg = pcall(get_client_msg, pid);
	if (not ok or type(msg) ~= "string") then
		return false;
	end
	local g = gate[pid];
	if (g == nil or g.msg ~= msg) then
		g = {msg = msg, ok = l10n_client_matches(msg)};
		gate[pid] = g;
	end
	return g.ok;
end

function mod.impl.l10n_get_lang(pid)
	return P.norm_lang(l10n_default_lang) or "en";
end

function mod.l10n_get_lang(pid)
	if (is_fakepid(pid) or not l10n_client_ok(pid)) then
		return mod.next.l10n_get_lang(pid);
	end

	if (chosen[pid] ~= nil) then
		return chosen[pid];
	end

	local ok, ext = pcall(get_client_ext_language, pid);
	local l = ok and P.norm_lang(ext) or nil;
	if (l == nil) then
		return mod.next.l10n_get_lang(pid);
	end
	return l;
end

-- Set or clear (nil) the language `pid` reads; l10n_lang_changed(pid)
-- tells whoever shows them text that outlives a message (a pie menu).
function l10n_set_lang(pid, lang)
	chosen[pid] = lang and P.norm_lang(lang) or nil;
	l10n_lang_changed(pid);
end

-- Hook it (mod.after.l10n_lang_changed) to re-send what a player holds.
function mod.impl.l10n_lang_changed(pid)
end

--======================= THE UPSTREAM API ===========================--

function mod.impl.l10n_get_str_lang(lang, msgtab, interptab)
	return resolve(l10n_msg(msgtab, interptab), lang);
end

-- Try to only pass a singular, non-broadcast PID.
function mod.impl.l10n_get_str_pid(pid, msgtab, interptab)
	return l10n_get_str_lang(l10n_get_lang(pid), msgtab, interptab);
end

function mod.impl.l10n_send_chat(pid, msgtab, interptab)
	server_msg(pid, l10n_msg(msgtab, interptab));
end

function mod.impl.l10n_log(msgtab, interptab)
	log("%s", l10n_get_str_lang(l10n_log_lang, msgtab, interptab));
end

--========================== SENDING MESSAGES ========================--

-- From the xearly chain, so every other hook on these -- the consoles,
-- /ignore, the C itself -- only ever sees the finished text, one player
-- at a time.
local function each(pid, msg, send)
	if (is_fakepid(pid)) then
		send(pid, l10n_str(pid, msg));
		return;
	end
	for i in piditer(pid) do
		send(i, l10n_str(i, msg));
	end
end

-- A language map is taken too, which is what lets a settings value --
-- a tip, a motd line -- be handed to them as it was read.
function mod.xearly.server_msg(pid, msg)
	if (l10n_is_map(msg)) then
		msg = l10n_msg(msg);
	end
	if (not l10n_is_msg(msg)) then
		return mod.xearly.next.server_msg(pid, msg);
	end
	each(pid, msg, function(i, s) mod.xearly.next.server_msg(i, s); end);
end

function mod.xearly.send_chat(pid, msg, type, from)
	if (l10n_is_map(msg)) then
		msg = l10n_msg(msg);
	end
	if (not l10n_is_msg(msg)) then
		return mod.xearly.next.send_chat(pid, msg, type, from);
	end
	each(pid, msg, function(i, s) mod.xearly.next.send_chat(i, s, type, from); end);
end

--=========================== COMMAND HELP ===========================--

-- commands.lua's send_usage, whose "usage:" was the one word of command
-- help not in a message. commands loads before this (group_deps), so
-- this definition is the one in force; the descriptions themselves are
-- translated by command_cmds (overridden) in the "command" context.
local usage_msg = {en = "usage: %(cmd)"};
local usage_args_msg = {en = "usage: %(cmd) %(args)"};

function send_usage(pid, cmd)
	local name = type(cmd.name) == "table" and cmd.name[1] or cmd.name;
	if (cmd.usage) then
		l10n_send_chat(pid, usage_args_msg, {cmd = name, args = cmd.usage});
	else
		l10n_send_chat(pid, usage_msg, {cmd = name});
	end
end

--=============================== /lang ==============================--

local lang_now = {en = "Your language: %(lang). Available: %(list). Use /lang <code>, or /lang auto for your client's."};
local lang_set = {en = "Language set to %(lang)."};
local lang_auto = {en = "Language follows your client again: %(lang)."};
local lang_none = {en = "No translations for %(lang) here; some messages stay in English."};
local lang_bad = {en = "%(lang) is not a language code (en, fr, pt_br, ...)."};
local lang_gated = {en = "Translations need %(clients); this server speaks %(lang) to your client."};

local function clients_text()
	local out = {};
	for name, min in pairs(l10n_clients or {}) do
		out[#out+1] = tostring(name) .. " " .. tostring(min) .. "+";
	end
	table.sort(out);
	return table.concat(out, ", ");
end

local cmd = {name = "lang", usage = "[<code>|auto]",
	desc = "Show or choose the language the server speaks to you.",
	-- in the pie menu's last wedge for spectators and the dead
	pie = {pie = "watching", slot = 6, label = {en = "Language"},
		tooltip = {en = "Show or change the language you read"}}};

function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv <= 1);

	if (not l10n_client_ok(pid)) then
		l10n_send_chat(pid, lang_gated, {clients = clients_text(),
			lang = l10n_get_lang(pid)});
		return;
	end

	if (argv[1] == nil) then
		l10n_send_chat(pid, lang_now, {lang = l10n_get_lang(pid),
			list = table.concat(l10n_languages(), ", ")});
		return;
	end

	if (string.lower(argv[1]) == "auto") then
		l10n_set_lang(pid, nil);
		l10n_send_chat(pid, lang_auto, {lang = l10n_get_lang(pid)});
		return;
	end

	local l = P.norm_lang(argv[1]);
	if (l == nil) then
		l10n_send_chat(pid, lang_bad, {lang = argv[1]});
		return;
	end

	l10n_set_lang(pid, l);
	l10n_send_chat(pid, lang_set, {lang = l});

	local have = false;
	for _, x in ipairs(l10n_languages()) do
		if (x == l or x == string.match(l, "^[^_]+")) then have = true; end
	end
	if (not have) then
		l10n_send_chat(pid, lang_none, {lang = l});
	end
end

-- commands loads before this (group_deps), so it is there to register
-- with; a reload re-registers over the old one
function mod.on_load()
	catalogs = {};
	installed_langs = nil;
	if (register_command ~= nil) then
		register_command(cmd, mod);
	end
end

return mod;
