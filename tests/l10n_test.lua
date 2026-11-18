-- l10n_test.lua -- translation: catalogs, plurals, and per-player text
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/l10n_test.lua      (from the repository root)
--
-- l10n_po on its own, then the lib_l10n override against a stubbed
-- server with the catalogs in tests/fixtures/locales.

package.path = "catalog/core/?.lua;catalog/overrides/?.lua;" .. package.path;

local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what) else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end
local function eq(got, want, what)
	check(got == want, what, string.format("got %s, want %s", tostring(got), tostring(want)));
end
local function read(p)
	local f = assert(io.open(p));
	local s = f:read("*a");
	f:close();
	return s;
end

local P = require "l10n_po";

print("\n1. locales");
eq(P.norm_lang("FR-ca"), "fr_ca", "case and dash are normalised");
eq(P.norm_lang("pt_BR"), "pt_br", "a region is kept");
eq(P.norm_lang("../etc"), nil, "a path is not a locale");
eq(P.norm_lang(""), nil, "nor is nothing");
eq(table.concat(P.candidates("fr_ca", "de"), ","), "fr_ca,fr,de,en",
	"locale, language, default, English");
eq(table.concat(P.candidates(nil, "en"), ","), "en", "no locale: the default");
eq(P.interp("%(a) and %(b)", {a = 1}), "1 and %(b)", "a missing placeholder shows");

print("\n2. plural expressions");
local pl = P.compile_plural("(n==1 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2)");
local got = {};
for _, n in ipairs({1, 2, 4, 5, 12, 22, 25, 112}) do got[#got+1] = pl(n); end
eq(table.concat(got, ""), "01122122", "Polish: 1, 2-4 and 22, the rest (12 too)");
eq(P.compile_plural("n > 1")(0), 0, "French: 0 is singular");
eq(P.compile_plural("0")(5), 0, "Japanese: one form");
eq(P.compile_plural("n / 2")(5), 2, "integer division");
check(P.compile_plural("n +") == nil, "a broken expression is refused");
check(P.compile_plural("n ; rm") == nil, "and so is anything else");

print("\n3. .po files");
local fr = P.parse(read("tests/fixtures/locales/fr/one.po"));
eq(fr.entries["%(name) was kicked"], "%(name) a été expulsé", "a plain entry");
eq(fr.entries[P.key("door", "Open")], "Ouverte", "msgctxt keeps two Opens apart");
eq(fr.entries["Open"], "Ouvrir", "the other Open");
eq(fr.entries["%(n) bot"] and fr.entries["%(n) bot"][2], "%(n) robots", "plural forms");
eq(fr.entries["Unchecked"], nil, "a fuzzy entry is skipped");
eq(fr.entries["A long line"], "Une longue ligne\n", "continued lines and escapes");
eq(fr.entries["Untranslated"], nil, "an empty msgstr is no translation");
eq(fr.plural(2), 1, "the header's Plural-Forms is used");
check(not pcall(P.parse, 'msgid "x"\nmsgstr nonsense\n'), "a broken file is refused");

print("\n4. lib_l10n: who reads what");
-- the stubbed server: 0 sent fr_FR, 1 sent pl, 2 sent nothing, 3 sent pt_br
MAX_PLAYERS = 32; PID_BROADCAST = 0x20000001;
local LANG = {[0] = "fr_FR", [1] = "pl", [2] = "", [3] = "pt_br"};
local sent, logged, commands = {}, {}, {};
function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
	before={}, after={}, next={}, early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function pid_connected_table() return {}; end
function get_client_ext_language(pid) return LANG[pid] or ""; end
function is_fakepid(pid) return pid >= MAX_PLAYERS and pid < 0x20000000; end
function piditer(pid)
	if (pid ~= PID_BROADCAST) then
		local done = false;
		return function() if (not done) then done = true; return pid; end end;
	end
	local i = -1;
	return function() i = i + 1; if (i <= 3) then return i; end end;
end
function log(fmt, ...) logged[#logged+1] = string.format(fmt, ...); end
function register_command(cmd) commands[cmd.name] = cmd; end
function cmd_assert(_, _, ok) assert(ok); end
-- lfs over the shell, as the image's lfs.so is not on the host
package.loaded.lfs = {
	attributes = function(p, what)
		local ok = os.execute("test -d '" .. p .. "'");
		return (ok == 0 or ok == true) and "directory" or nil;
	end,
	dir = function(p)
		local t = {};
		for n in io.popen("ls '" .. p .. "'"):lines() do t[#t+1] = n; end
		local i = 0;
		return function() i = i + 1; return t[i]; end;
	end,
};
l10n_dir = "tests/fixtures/locales";

local mod = require "lib_l10n";
-- the chains LSd would link: the std hook in front of the impl
mod.next.l10n_get_lang = mod.impl.l10n_get_lang;
l10n_get_lang = mod.l10n_get_lang;
l10n_get_str_lang = mod.impl.l10n_get_str_lang;
l10n_get_str_pid = mod.impl.l10n_get_str_pid;
l10n_send_chat = mod.impl.l10n_send_chat;
l10n_log = mod.impl.l10n_log;
mod.xearly.next.server_msg = function(pid, s) sent[#sent+1] = {pid, s}; end
mod.xearly.next.send_chat = function(pid, s, t, from) sent[#sent+1] = {pid, s, t, from}; end
server_msg = mod.xearly.server_msg;
send_chat = mod.xearly.send_chat;
mod.on_load();

eq(l10n_get_lang(0), "fr_fr", "a client's locale, normalised");
eq(l10n_get_lang(2), "en", "no locale: the default");
eq(l10n_get_lang(40), "en", "the console: the default");

local kicked = l10n_msg({en = "%(name) was kicked"}, {name = "Bob"});
eq(l10n_str(0, kicked), "Bob a été expulsé", "fr_fr falls back to fr");
eq(l10n_str(2, kicked), "Bob was kicked", "English when nothing better");
eq(l10n_str(3, kicked), "Bob was kicked", "pt_br with no catalog: English");
eq(l10n_str(0, l10n_msg("Bye")), "Au revoir", "a second script's catalog is merged in");
eq(l10n_str(0, l10n_msg({en = "Open", ctx = "door"})), "Ouverte", "a context picks its entry");
eq(l10n_str(0, l10n_msg({en = "Bye", fr = "Salut"})), "Salut", "an inline translation wins");
eq(l10n_str(0, "plain"), "plain", "a plain string passes through");
eq(tostring(kicked), "Bob was kicked", "tostring is the log language");

print("\n5. plurals");
local function bots(n) return l10n_msgn({en = "%(n) bot", en_plural = "%(n) bots"}, n); end
eq(l10n_str(2, bots(1)), "1 bot", "English singular");
eq(l10n_str(2, bots(0)), "0 bots", "English plural");
eq(l10n_str(0, bots(0)), "0 robot", "French: 0 is singular");
eq(l10n_str(0, bots(2)), "2 robots", "French plural");
eq(l10n_str(1, bots(3)), "3 boty", "Polish few");
eq(l10n_str(1, bots(5)), "5 botów", "Polish many");

print("\n6. sending: each player reads their own");
server_msg(PID_BROADCAST, kicked);
eq(#sent, 4, "a broadcast becomes one send per player");
eq(sent[1][2], "Bob a été expulsé", "player 0 in French");
eq(sent[3][2], "Bob was kicked", "player 2 in English");
check(sent[1][1] == 0 and sent[4][1] == 3, "each to its own player");
sent = {};
send_chat(1, bots(2), 2, 255);
eq(sent[1][2], "2 boty", "send_chat translates too");
eq(sent[1][3], 2, "and keeps its type");
sent = {};
server_msg(0, "untouched");
eq(sent[1][2], "untouched", "a plain string goes straight through");
sent = {};
l10n_send_chat(PID_BROADCAST, {en = "%(name) was kicked"}, {name = "Al"});
eq(sent[1][2], "Al a été expulsé", "upstream's l10n_send_chat is translated");
eq(l10n_get_str_pid(0, {en = "Bye"}), "Au revoir", "and l10n_get_str_pid");
logged = {};
l10n_log({en = "Bye"});
eq(logged[1], "Bye", "logs stay in the log language");

print("\n7. /lang");
local lang = commands.lang;
check(lang ~= nil, "/lang is registered");
sent = {};
lang.func(2, {"fr"});
eq(l10n_get_lang(2), "fr", "a player can choose");
eq(sent[1][2], "Language set to fr.", "and is told");
eq(l10n_str(2, kicked), "Bob a été expulsé", "and then reads it");
sent = {};
lang.func(2, {"xx"});
check(sent[2] and sent[2][2]:find("No translations for xx"), "a language with no files is warned about",
	sent[2] and sent[2][2]);
lang.func(2, {"auto"});
eq(l10n_get_lang(2), "en", "auto: back to the client's");
sent = {};
lang.func(2, {"../x"});
check(sent[1] and sent[1][2]:find("not a language code"), "a bad code is refused");
eq(l10n_get_lang(2), "en", "and changes nothing");
sent = {};
lang.func(0, {});
check(sent[1] and sent[1][2]:find("fr_fr") and sent[1][2]:find("en, fr, pl"),
	"no argument: the current language and the installed ones", sent[1] and sent[1][2]);

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
