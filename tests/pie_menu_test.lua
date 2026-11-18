-- pie_menu_test.lua -- the Pie Menu encoder, its validation, and what is sent
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/pie_menu_test.lua      (from the repository root)
--
-- A client applies a Menu whole or not at all, so one stray byte costs
-- the player every pie. These check the bytes against the spec's
-- layout, run every menu sent through a parser that refuses what a
-- client refuses, and drive lib_pie_menu against a stubbed server.

package.path = "catalog/core/?.lua;" .. package.path;
local F = require "settings_format";

local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what) else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end
local function eq(got, want, what)
	check(got == want, what, string.format("got %q, want %q",
		tostring(got), tostring(want)));
end
local function hex(s)
	return (string.gsub(s, ".", function(c)
		return string.format("%02x ", string.byte(c)); end));
end

--============================ THE STUBS =============================--

local PLAYERS = {0, 1};
local sent, ready;
local agreed;     -- pid -> {ext id -> true}
local langs;      -- pid -> what get_client_ext_language says

local function setup(settings)
	sent, agreed, langs = {}, {[0] = {[0x31] = true}, [1] = {}}, {};
	MAX_PLAYERS = 255; PID_BROADCAST = 255;
	pie_menu_mode, pie_menu, pie_menu_hide_unavailable = nil, nil, nil;
	pie_menu_fallback_lang, pie_menu_debug = nil, nil;
	can_see_command = nil;
	commands = {ratio = {name = "ratio"}, ping = {name = "ping"},
		ignore = {name = "ignore"}, client = {name = "client"},
		who = {name = "who"}};
	for k, v in pairs(settings or {}) do _G[k] = v; end

	function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
		before={}, after={}, next={on_any_packet = function() return "next"; end},
		early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
	function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
	function log() end
	function pid_connected_table(d) return setmetatable({}, {__index = function() return d; end}); end
	function piditer() local i = 0; return function() i = i + 1; return PLAYERS[i]; end; end
	function send_packet(pid, data) sent[#sent+1] = {to = pid, data = data}; end
	function ext_supported(pid, id) return agreed[pid][id] and 1 or nil; end
	function ext_register(_, id, _, on_ready) ready = on_ready; end
	function ext_unregister() end
	function get_client_ext_language(pid) return langs[pid] or ""; end

	local mod = dofile("catalog/extensions/pie_menu/lib_pie_menu.lua");
	mod.on_load();
	return mod;
end

-- Load once for the codec; the codec reads no globals.
local P = setup().codec;

--============================ A CLIENT ==============================--
-- The spec's "Validation", as a client would apply it: parse the whole
-- packet, refuse on a string or record that runs past the end, on bytes
-- after the last pie, and on malformed UTF-8 behind 0xff. Returns the
-- menu, or nil and why.
local function client_parse(b)
	local pos = 1;
	local function u8()
		local c = string.byte(b, pos);
		if (c == nil) then error("record runs past the end", 0); end
		pos = pos + 1;
		return c;
	end
	local function str()
		local z = string.find(b, "\0", pos, true);
		if (z == nil) then error("string runs past the end", 0); end
		local s = string.sub(b, pos, z - 1);
		pos = z + 1;
		if (string.byte(s, 1) == 0xff) then
			s = string.sub(s, 2);
			if (not P.utf8_valid(s)) then error("bad UTF-8", 0); end
			return s, true;
		end
		return s, false;
	end

	local ok, menu = pcall(function()
		if (u8() ~= 0x71 or u8() ~= 0) then error("not a Menu", 0); end
		local m = {};
		for p = 1, u8() do
			local pie = {contexts = u8(), msgid = u8(), slices = {}};
			pie.theme, pie.theme_utf8 = str();
			for s = 1, 6 do
				local sl = {msgid = u8(), flags = u8()};
				sl.text, sl.text_utf8 = str();
				sl.label, sl.label_utf8 = str();
				sl.tooltip = str();
				pie.slices[s] = sl;
			end
			m[p] = pie;
		end
		if (pos <= #b) then error("bytes after the last pie", 0); end
		return m;
	end);
	if (not ok) then return nil, menu; end
	return menu;
end

local function slice(text, label, tooltip, global)
	return {text = text or "", label = label or "", tooltip = tooltip or "",
		global = global or false};
end
local function blanks(pie, from)
	for i = from, 6 do pie.slices[i] = slice(); end
	return pie;
end

--========================= 1. BYTE LAYOUT ===========================--
print("\n1. a known menu, byte for byte");

local known = P.encode_menu({
	blanks({contexts = P.BLOCK + P.SKY, theme = "Hi", slices = {
		slice("/x %p", "X", "tip", false),
		slice("gg", "", "", true),
	}}, 3),
});
local want = "\113\0\1"            -- 0x71, sub 0, one pie
	.. "\33\0Hi\0"                  -- contexts 0b100001, theme msgid 0, "Hi"
	.. "\0\0/x %p\0X\0tip\0"        -- slice 1: msgid, flags, text, label, tooltip
	.. "\0\1gg\0\0\0"               -- slice 2: GLOBAL
	.. string.rep("\0\0\0\0\0", 4); -- slices 3-6 blank
eq(known and hex(known), hex(want), "header, pie, six slices, nothing after");

eq(hex(P.encode_menu({})), hex("\113\0\0"), "Pie Count 0 is three bytes");

--========================= 2. BLANK SLICES ==========================--
print("\n2. blank slices");

local pie = P.normalize_pie({theme = "T", when = "teammate",
	slices = {"/a", "", {}, nil, {text = "b", label = "B"}}});
eq(#pie.slices, 6, "a pie with five written gets six");
local r = P.resolve({pie}, nil, "en");
local m = client_parse(P.encode_menu(r));
check(m ~= nil, "it parses");
eq(m[1].slices[1].text, "/a", "a bare string is the text");
for _, i in ipairs({2, 3, 4, 6}) do
	local s = m[1].slices[i];
	check(s.text == "" and s.label == "" and s.flags == 0, "slice " .. i .. " is blank");
end
eq(m[1].slices[5].label, "B", "and the slice after the hole is still slice 5");

local all_blank = P.normalize_pie({when = "sky", slices = {"", ""}});
eq(#P.resolve({all_blank, pie}, nil, "en"), 1, "a pie with nothing on it is not sent");
local hidden = P.resolve({pie}, nil, "en", function(s) return s.text ~= "/a"; end);
eq(hidden[1].slices[1].text, "", "keep() blanks a slice in place, keeping the others where they are");

--=========================== 3. UTF-8 ===============================--
print("\n3. strings");

eq(P.encode_string("Attack"), "Attack\0", "printable ASCII goes as CP437, as it is");
eq(P.encode_string("Défendre"), "\255Défendre\0", "anything else goes as UTF-8 behind 0xff");
eq(P.encode_string("\6red"), "\255\6red\0", "a colour code in a label goes the UTF-8 way");
eq(P.encode_string("日本語 🙂"), "\255日本語 🙂\0", "3- and 4-byte sequences");
eq(P.encode_string(""), "\0", "empty is a lone NUL");

local loc = P.normalize_pie({theme = {en = "Mark", fr = "Marquer"}, when = "block",
	slices = {{text = "/m", label = {en = "Defend", ["FR-fr"] = "Défendre fort", fr = "Défendre"}}}});
local function label_for(lang)
	return P.resolve({loc}, lang, "en")[1].slices[1].label;
end
eq(label_for("fr_fr"), "Défendre fort", "an exact locale, however it was written");
eq(label_for("fr_ca"), "Défendre", "else the language alone");
eq(label_for("de_de"), "Defend", "else the fallback");
eq(label_for(nil), "Defend", "and the fallback while the locale is unknown");
eq(P.resolve({P.normalize_pie({when = "sky", slices = {{text = "x", label = {fr = "a", de = "b"}}}})},
	"es", "it")[1].slices[1].label, "b", "with no English either, the first alphabetically");
m = client_parse(P.encode_menu(P.resolve({loc}, "fr", "en")));
check(m and m[1].theme_utf8 == false and m[1].slices[1].label_utf8 == true,
	"the client reads each string by its own prefix");

--========================== 4. REFUSALS =============================--
print("\n4. what is refused before it can reach a client");

local bad_utf8 = {
	["\192\128"] = "an overlong NUL", ["\224\128\128"] = "an overlong 3-byte",
	["\237\160\128"] = "a UTF-16 surrogate", ["\244\144\128\128"] = "past U+10FFFF",
	["\245\128\128\128"] = "0xf5", ["\255x"] = "a raw 0xff", ["é"] = nil,
	["\195"] = "a truncated sequence", ["\128"] = "a lone continuation byte",
	["a\226\130"] = "a truncated 3-byte at the end",
};
for s, what in pairs(bad_utf8) do
	check(P.encode_string(s) == nil, what .. " is refused");
end
check(P.utf8_valid("\244\143\191\191") and P.utf8_valid("\239\191\191"),
	"U+10FFFF and U+FFFF are fine");

check(P.encode_string("a\0b") == nil, "a NUL inside a string is refused");
check(P.encode_string("say\7hi", true) == nil, "a control byte in a Text is refused");
check(P.encode_string("say\31", true) == nil, "0x1f in a Text too");
check(P.encode_string("say\7hi", false) ~= nil, "but allowed in a Label, as a colour");

local function refuses(spec, what, needle)
	local ok, err = pcall(P.normalize_pie, spec, "p");
	check(not ok and (needle == nil or string.find(err, needle, 1, true)),
		what, ok and "accepted" or err);
end
refuses({when = "block", slices = {1, 2, 3, 4, 5, 6, 7}}, "seven slices", "a pie has 6");
refuses({when = "nowhere", slices = {}}, "an unknown context", "unknown context");
refuses({slices = {"x"}}, "no contexts at all", "`when`");
refuses({when = 0, slices = {"x"}}, "a context mask of 0");
refuses({when = 64, slices = {"x"}}, "a reserved context bit");
refuses({when = "sky", slices = {{text = "x", lable = "y"}}}, "a misspelt field", "lable");
refuses({when = "sky", theme = "t", slises = {}}, "a misspelt pie field", "slises");
refuses({when = "sky", slices = {{label = "Orphan"}}}, "a label with nothing to send", "no text");
refuses({when = "sky", slices = {{text = "bad \1 text"}}}, "a control byte in a text", "control");
refuses({when = "sky", slices = {{text = "x", tooltip = "\200"}}}, "bad UTF-8 in a tooltip", "UTF-8");
refuses({when = "sky", theme = {fr = "\255"}, slices = {"x"}}, "bad UTF-8 in one translation", "theme[fr]");
refuses({when = "sky", slices = {{text = "x", label = {["?!"] = "y"}}}}, "a key that is no locale", "locale");

local too_many = {};
for i = 1, 256 do too_many[i] = blanks({contexts = 1, theme = "", slices = {}}, 1); end
check(P.encode_menu(too_many) == nil, "256 pies do not fit a Pie Count");
check(P.encode_menu({blanks({contexts = 1, slices = {}}, 1), {contexts = 1, slices = {}}}) == nil,
	"the encoder itself refuses a pie short of six slices");
check(P.encode_menu({blanks({contexts = 0, slices = {}}, 1)}) == nil,
	"and a pie offered nowhere");

-- the parser this test uses must itself refuse what a client refuses
check(client_parse(known .. "\0") == nil, "(the test client refuses trailing bytes)");
check(client_parse(string.sub(known, 1, -2)) == nil, "(and a truncated packet)");

--===================== 5. THE SETTINGS FILE =========================--
print("\n5. pies written in the settings file");

local cfg = F.parse([[
pie_menu = [
    {theme: 'Orders', when: 'block enemy', slices: [
        {text: '/pingmark %h Attack', label: 'Attack'},
        {text: '/pingmark %h Defend', label: {en: 'Defend', fr: 'Défendre'}},
        '',
        {text: 'Need backup!', label: 'Backup', tooltip: 'Team chat'},
    ]},
    {theme: 'Chat', when: ['sky', 'spectator', 'dead'], slices: [
        {text: 'gg', label: 'Good game', global: True},
    ]},
    {when: 'nowhere', slices: ['oops']},
]
]]);
check(type(cfg.pie_menu) == "table" and #cfg.pie_menu == 3, "it parses as a list of maps");
for i = 1, 2 do
	local ok, p = pcall(P.normalize_pie, cfg.pie_menu[i]);
	check(ok, "settings pie " .. i .. " is accepted", p);
end
eq(P.normalize_pie(cfg.pie_menu[2]).contexts, P.SKY + P.SPECTATOR + P.DEAD, "`when` as a list");
check(P.normalize_pie(cfg.pie_menu[2]).slices[1].global, "global: True");
check(not pcall(P.normalize_pie, cfg.pie_menu[3]), "a bad pie in the file is refused");

--====================== 6. THE BUILT-IN MENU ========================--
print("\n6. the built-in menu");

for _, lang in ipairs({"en", "fr", "de"}) do
	local ok, err = pcall(function()
		local list = {};
		for i, v in ipairs(P.BUILTIN) do list[i] = P.normalize_pie(v, "built-in " .. i); end
		local b = assert(P.encode_menu(P.resolve(list, lang, "en")));
		assert(client_parse(b));
	end);
	check(ok, "it is valid and a client accepts it, in " .. lang, err);
end

--========================= 7. THE SERVER ============================--
print("\n7. lib_pie_menu against a stubbed server");

local function menu_to(pid)
	local got;
	for _, p in ipairs(sent) do
		if (p.to == pid and string.byte(p.data, 1) == 0x71) then got = p.data; end
	end
	return got;
end
local function texts(b)
	local out = {};
	for _, pie in ipairs(assert(client_parse(b))) do
		for _, s in ipairs(pie.slices) do
			if (s.text ~= "") then out[s.text] = s.label; end
		end
	end
	return out;
end

local mod = setup();
ready(0);
local b = menu_to(0);
check(b ~= nil and client_parse(b) ~= nil, "a negotiated client is sent a valid menu");
check(#sent == 1, "and only that client", #sent);
local t = texts(b);
check(t["/ratio %p"] ~= nil and t["Thanks!"] ~= nil, "built from stock commands and chat");
check(t["/votekick %p"] == nil, "no /votekick on a server without it");
check(t["/pingmark %h Enemy"] == nil, "no /pingmark on a server without it");
eq(string.byte(b, 3), 3, "so the Mark pie, left empty, is not sent");

-- the locale arrives after the menu went out
sent = {};
langs[0] = "fr_fr";
mod.after.on_version_ext(0, 1, 0, 0, 1, "OpenSpades", "fr_fr");
b = menu_to(0);
check(b ~= nil, "the menu is sent again once the locale arrives");
sent = {};
mod.after.on_version_ext(0, 1, 0, 0, 1, "OpenSpades", "fr_fr");
check(#sent == 0, "and not a third time for the same locale");

-- Teamplay and votekick turn up, each putting itself in the menu, as
-- their scripts declare it
commands.votekick = {name = {"votekick", "vk"},
	pie = {pie = "player", slot = 1, args = "%p", label = {en = "Vote kick"}}};
commands.pingmark = {name = "pingmark", pie = {
	{pie = "mark", args = "%h Enemy", label = {en = "Enemy"}},
	{pie = "mark", args = "%h Attack", label = {en = "Attack"}},
}};
sent = {};
pie_menu_refresh();
t = texts(menu_to(0) or "");
check(t["/votekick %p"] ~= nil, "a refresh picks up /votekick");
check(t["/pingmark %h Enemy"] == nil, "/pingmark stays out for a client without Teamplay");
agreed[0][48] = true;
pie_menu_refresh();
t = texts(menu_to(0) or "");
check(t["/pingmark %h Enemy"] ~= nil, "and comes in once it has Teamplay");
sent = {};
pie_menu_refresh();
check(#sent == 0, "a refresh that changes nothing sends nothing");

-- caps
can_see_command = function(pid, cmd) return cmd.name ~= "ignore"; end
pie_menu_refresh();
check(texts(menu_to(0))["/ignore %p"] == nil, "a command the player may not run is blanked");
can_see_command = nil;
pie_menu_refresh();

-- the API
sent = {};
pie_menu_add("ctf", {theme = "Flag", when = "any", slices = {"/drop"}}, 10);
check(menu_to(0) == nil, "a pie of nothing but unknown commands is not sent", hex(menu_to(0) or ""));
commands.drop = {name = "drop"};
pie_menu_add("ctf", {theme = "Flag", when = "any", slices = {"/drop"}}, 10);
local first = client_parse(menu_to(0))[1];
eq(first and first.theme, "Flag", "an add with a lower order comes first");
check(not pcall(pie_menu_add, "x", {when = "sky", slices = {{text = "\1"}}}),
	"pie_menu_add raises on a pie that could not be sent");
sent = {};
pie_menu_remove("ctf");
check(menu_to(0) ~= nil and client_parse(menu_to(0))[1].theme ~= "Flag", "pie_menu_remove takes it out again");
local only = {theme = "Only", when = "sky", slices = {{text = "hi", show = function(pid) return pid == 0; end}}};
pie_menu_add("shown", only);
check(texts(pie_menu_build(0))["hi"] ~= nil, "show() offers a slice to whom it answers true");
check(pie_menu_build(1) == nil or texts(pie_menu_build(1))["hi"] == nil, "and to nobody else");
pie_menu_remove("shown");

print("\n7b. registering actions into pies");
local function pie_of(b, theme)
	for _, pie in ipairs(assert(client_parse(b))) do
		if (pie.theme == theme) then return pie; end
	end
end
local function count(b, theme)
	local n = 0;
	for _, pie in ipairs(assert(client_parse(b))) do
		if (pie.theme == theme) then n = n + 1; end
	end
	return n;
end
commands.pie_a = {name = "pie_a"};
commands.pie_b = {name = "pie_b"};
eq(pie_of(pie_menu_build(0), "Player").slices[1].text, "/votekick %p",
	"a command takes the slot it asks for");
pie_menu_slice("x", {pie = "player", text = "/pie_a", label = {en = "A"}});
eq(pie_of(pie_menu_build(0), "Player").slices[6].text, "/pie_a",
	"a registered slice stacks into the first free wedge");
pie_menu_slice("y", {{pie = "player", text = "/pie_b", label = {en = "B"}},
	{pie = "player", text = "hello", label = {en = "Hi"}}});
eq(count(pie_menu_build(0), "Player"), 2, "a full pie goes on in a second one");
local second = client_parse(pie_menu_build(0));
local i1, i2;
for i, pie in ipairs(second) do
	if (pie.theme == "Player") then if (i1 == nil) then i1 = i; else i2 = i; end end
end
eq(i2, i1 and i1 + 1, "right after the first");
eq(second[i2].slices[2].text, "hello", "the second filled in order");
eq(second[i2].contexts, second[i1].contexts, "offered where the first is");
pie_menu_remove("y");
eq(count(pie_menu_build(0), "Player"), 1, "removing it takes the second pie away");
check(not pcall(pie_menu_slice, "z", {pie = "nope", text = "hi", label = {en = "x"}}),
	"a pie nothing defines is refused");
pie_menu_slice("z", {pie = {id = "flag", theme = {en = "Flag"}, when = "sky"},
	text = "hi", label = {en = "Hi"}});
check(pie_of(pie_menu_build(0), "Flag") ~= nil, "a pie that is not there is created");
pie_menu_slice("z2", {pie = "flag", text = "bye", label = {en = "Bye"}});
eq(pie_of(pie_menu_build(0), "Flag").slices[2].text, "bye", "and others stack into it");
pie_menu_remove("z"); pie_menu_remove("z2"); pie_menu_remove("x");
check(not pcall(pie_menu_slice, "w", {pie = "chat", text = "\1"}),
	"a slice that could not be sent is refused");
check(not pcall(pie_menu_slice, "w", {pie = "chat", text = "x", slot = 9}),
	"so is a slot that is not 1-6");
commands.bad = {name = "bad", pie = {pie = "chat", text = "/other"}};
check(pcall(pie_menu_build, 0), "a bad cmd.pie is logged and left out, not raised");
commands.bad = nil;
-- a command registered after the menu went out
sent = {};
commands.late = {name = "late", pie = {pie = "watching", label = {en = "Late"}}};
commands_register_hook(commands.late);
check(menu_to(0) ~= nil and texts(menu_to(0))["/late"] ~= nil,
	"a command registered later is sent to whoever has a menu");
commands.late = nil;
pie_menu_refresh();

print("\n7c. language through lib_l10n");
local chosen = {};
l10n_get_lang = function(pid) return chosen[pid] or "en"; end
l10n_default_lang = "en";
local FR = {Thanks = "Merci", ["Quick chat"] = "Messages", ["Vote kick"] = "Voter l'exclusion"};
l10n_get_str_lang = function(lang, v)
	local en = type(v) == "table" and v.en or v;
	if (lang == "fr" and type(v) == "table" and v.fr) then return v.fr; end
	return (lang == "fr" and FR[en]) or en;
end
chosen[0] = "fr";
sent = {};
mod.after.l10n_lang_changed(0);
b = menu_to(0);
check(b ~= nil, "/lang re-sends the menu");
eq(texts(b)["Thanks!"], "Merci", "with the labels translated by lib_l10n");
eq(texts(b)["/votekick %p"], "Voter l'exclusion", "a command's label too");
check(pie_of(b, "Messages") ~= nil, "and the themes");
eq(texts(b)["Thanks!"] and "Thanks!", "Thanks!", "the text itself is not translated");
sent = {};
mod.after.l10n_lang_changed(0);
check(#sent == 0, "the same language again sends nothing");
l10n_get_lang, l10n_get_str_lang, l10n_default_lang = nil, nil, nil;

-- incoming
eq(mod.on_any_packet(0, "\113\0\0"), 0, "a Menu from a client is dropped");
eq(mod.on_any_packet(0, "\113\5junk"), 0, "and anything else on 0x71");
eq(mod.on_any_packet(0, "\114\0"), "next", "other packets go on down the chain");

-- the modes
mod = setup({pie_menu_mode = "none"});
ready(0);
eq(menu_to(0), "\113\0\0", "mode none: Pie Count 0");
mod = setup({pie_menu_mode = "client"});
ready(0);
check(#sent == 0, "mode client: nothing at all");

-- the operator's menu replaces the built-in one
mod = setup({pie_menu = cfg.pie_menu});
ready(0);
t = texts(menu_to(0));
check(t["Need backup!"] ~= nil and t["gg"] ~= nil, "pie_menu from the settings is what is sent");
check(t["Thanks!"] == nil, "instead of the built-in menu");
eq(string.byte(menu_to(0), 3), 2, "both good pies sent, the bad one skipped");
check(t["/pingmark %h Attack"] == nil, "its /pingmark slices blanked without Teamplay");

-- a per-player override
mod = setup();
commands.answer = {name = "answer"};
ready(0);
sent = {};
pie_menu_override(0, {theme = "Ask?", when = "any", slices = {"/answer yes", "/answer no"}});
local ob = menu_to(0);
check(ob ~= nil and client_parse(ob) ~= nil, "an override re-sends the menu at once");
local op = client_parse(ob);
check(#op == 1 and op[1].theme == "Ask?" and op[1].contexts == P.ALL_CONTEXTS,
	"and it is the only pie, in every context");
check(pie_menu_build(0) == ob, "pie_menu_build gives the same");
check(pie_menu_build(1) ~= ob, "another player keeps the normal menu");
sent = {};
pie_menu_refresh();
check(#sent == 0, "a refresh keeps it");
check(not pcall(pie_menu_override, 0, {when = "sky", slices = {{text = "\1"}}}),
	"an override that could not be sent raises");
sent = {};
pie_menu_override(0, nil);
check(menu_to(0) ~= nil and #client_parse(menu_to(0)) > 1,
	"cleared, the normal menu is re-sent");
pie_menu_override(0, {theme = "Ask?", when = "any", slices = {"/answer yes"}});
mod.after.on_disconnect(0);
check(pie_menu_build(0) ~= ob, "a disconnect clears it");

-- unloading takes the API with it
mod.on_unload();
check(pie_menu_add == nil and pie_menu_supported == nil and pie_menu_override == nil, "unload clears every global");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
