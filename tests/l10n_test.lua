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
eq(fr.entries["A long line\n"], "Une longue ligne\n", "continued lines and escapes");
eq(fr.entries["Untranslated"], nil, "an empty msgstr is no translation");
eq(fr.plural(2), 1, "the header's Plural-Forms is used");
check(not pcall(P.parse, 'msgid "x"\nmsgstr nonsense\n'), "a broken file is refused");

print("\n4. lib_l10n: who reads what");
-- the stubbed server: 0 sent fr_FR, 1 sent pl, 2 sent nothing, 3 sent
-- pt_br, all on ZeroSpades 0.0.9; 4 sent fr on stock OpenSpades, 5 fr
-- on an older ZeroSpades
MAX_PLAYERS = 32; PID_BROADCAST = 0x20000001;
local LANG = {[0] = "fr_FR", [1] = "pl", [2] = "", [3] = "pt_br", [4] = "fr", [5] = "fr"};
local ZS = "Darwin 25.6.0 | ZeroSpades 0.0.9 b3432453 (arm64)";
local MSG = {[0] = ZS, [1] = ZS, [2] = ZS, [3] = ZS,
	[4] = "Linux 6.1 | OpenSpades 0.1.5 (x86_64)",
	[5] = "Windows 10 | ZeroSpades 0.0.8 (x86_64)"};
local sent, logged = {}, {};
function init_mod() return {impl={before={},after={},next={}}, late={before={},after={},next={}},
	before={}, after={}, next={}, early={before={},after={},next={}}, xearly={before={},after={},next={}}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function pid_connected_table() return {}; end
function get_client_ext_language(pid) return LANG[pid] or ""; end
function get_client_msg(pid) return MSG[pid]; end
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
cmds_seen = {};
function register_command(cmd)
	local names = type(cmd.name) == "table" and cmd.name or {cmd.name};
	for _, n in ipairs(names) do commands[n] = cmd; cmds_seen[n] = cmd; end
end
commands = {};
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
local changed = {};
l10n_lang_changed = function(pid) changed[#changed+1] = pid; end
mod.xearly.next.server_msg = function(pid, s) sent[#sent+1] = {pid, s}; end
mod.xearly.next.send_chat = function(pid, s, t, from) sent[#sent+1] = {pid, s, t, from}; end
server_msg = mod.xearly.server_msg;
send_chat = mod.xearly.send_chat;
mod.on_load();

eq(l10n_get_lang(0), "fr_fr", "a client's locale, normalised");
eq(l10n_get_lang(2), "en", "no locale: the default");
eq(l10n_get_lang(40), "en", "the console: the default");

print("\n4b. the gate: translations for the current ZeroSpades only");
check(l10n_client_matches(ZS), "ZeroSpades 0.0.9 with a commit hash");
check(l10n_client_matches("x | ZeroSpades 0.0.10 (y)"), "a newer patch");
check(l10n_client_matches("x | ZeroSpades 0.1.0"), "a newer minor");
check(not l10n_client_matches(MSG[5]), "not an older ZeroSpades");
check(not l10n_client_matches(MSG[4]), "not stock OpenSpades");
check(not l10n_client_matches("x | NotZeroSpades 9.9.9"), "nor a name that only ends the same");
check(not l10n_client_matches(nil), "nor a client that never said");
eq(l10n_get_lang(4), "en", "OpenSpades asking for fr reads the default");
eq(l10n_get_lang(5), "en", "so does an older ZeroSpades");
MSG[6] = ZS;
check(not l10n_client_ok(6) == false, "a reply arriving later opens the gate");
MSG[6] = nil;
l10n_clients = {ZeroSpades = "0.0.8"};
check(l10n_client_matches(MSG[5]), "l10n_clients sets the oldest version");
l10n_clients = {ZeroSpades = "0.0.9"};

local kicked = l10n_msg({en = "%(name) was kicked"}, {name = "Bob"});
eq(l10n_str(0, kicked), "Bob a été expulsé", "fr_fr falls back to fr");
eq(l10n_str(2, kicked), "Bob was kicked", "English when nothing better");
eq(l10n_str(3, kicked), "Bob was kicked", "pt_br with no catalog: English");
eq(l10n_str(0, l10n_msg("Bye")), "Au revoir", "a second script's catalog is merged in");
eq(l10n_str(0, l10n_msg({en = "Open", ctx = "door"})), "Ouverte", "a context picks its entry");
eq(l10n_str(0, l10n_msg({en = "Bye", fr = "Salut"})), "Salut", "an inline translation wins");
eq(l10n_str(0, "plain"), "plain", "a plain string passes through");
eq(tostring(kicked), "Bob was kicked", "tostring is the log language");
local nested = l10n_msg("%(name) was kicked", {name = l10n_msg({en = "Open", ctx = "door"})});
eq(l10n_str(0, nested), "Ouverte a été expulsé", "a message inside a message: same language");
eq(l10n_str(2, nested), "Open was kicked", "in English too");

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

print("\n6b. settings: text or a language map");
check(l10n_is_map({en = "Hi", fr = "Salut"}), "a language map is one");
check(l10n_is_map({fr = "Salut"}), "even without English");
check(not l10n_is_map({"a", "b"}), "a list is not");
check(not l10n_is_map({en = "Hi", color = 3}), "nor a table with other keys");
check(not l10n_is_map(kicked), "nor a message");
eq(l10n_str(0, l10n_text({en = "Hi", fr = "Salut"})), "Salut", "a map, in the player's language");
eq(l10n_str(2, l10n_text({fr = "Salut", de = "Hallo"})), "Hallo",
	"no English: the same one every time");
eq(l10n_str(0, l10n_text("Bye")), "Au revoir", "a string is English, translated where a catalog has it");
eq(l10n_str(0, l10n_text("Welcome to %(server)", {server = "S"})), "Welcome to S", "with placeholders");
eq(l10n_text(nil), nil, "nil stays nil");
check(l10n_text(kicked) == kicked, "a message is kept");
sent = {};
server_msg(PID_BROADCAST, {en = "Hi", fr = "Salut"});
eq(sent[1][2], "Salut", "server_msg takes a map: French for player 0");
eq(sent[3][2], "Hi", "English for player 2");
sent = {};
send_chat(0, {en = "Hi", fr = "Salut"}, 2, 255);
eq(sent[1][2], "Salut", "send_chat too");

print("\n7. /lang");
local lang = cmds_seen.lang;
check(lang ~= nil, "/lang is registered");
sent = {};
lang.func(2, {"fr"});
eq(l10n_get_lang(2), "fr", "a player can choose");
eq(changed[#changed], 2, "and whoever shows them text is told (l10n_lang_changed)");
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
sent = {};
lang.func(4, {"fr"});
check(sent[1] and sent[1][2]:find("Translations need ZeroSpades 0.0.9+", 1, true),
	"/lang tells another client what translations need", sent[1] and sent[1][2]);
eq(l10n_get_lang(4), "en", "and changes nothing");
eq(l10n_get_lang(2), "en", "and changes nothing");
sent = {};
lang.func(0, {});
check(sent[1] and sent[1][2]:find("fr_fr") and sent[1][2]:find("en, fr, pl", 1, true)
	and not sent[1][2]:find("es", 1, true),
	"no argument: the current language and the installed ones, drafts-only es left out",
	sent[1] and sent[1][2]);

print("\n8. the catalog's translation files");
local r = os.execute("luajit dev/l10n.lua --check >/dev/null");
check(r == 0 or r == true, "every template is up to date (luajit dev/l10n.lua)");
local function same(a, b) return table.concat(a, ",") == table.concat(b, ","); end
for path in io.popen("find catalog -path '*/locales/*.po' | sort"):lines() do
	local ok, cat = pcall(P.parse, read(path));
	check(ok, path .. " parses", cat);
	if (ok) then
		check(read(path):find("Plural%-Forms:") ~= nil, path .. " says how its language counts");
		for _, e in ipairs(cat.list) do
			local want = P.placeholders(e.msgid .. (e.plural or ""));
			local outs = e.plural and e.forms or {e.str};
			for _, s in ipairs(outs) do
				if (s ~= nil and s ~= "" and not e.fuzzy) then
					-- a plural's singular may leave out %(n): "one bot"
					local have = P.placeholders(s .. (e.plural and "%(n)" or ""));
					if (e.plural) then table.insert(want, "n"); end
					local w = {};
					local seen = {};
					for _, x in ipairs(want) do if (not seen[x]) then seen[x] = true; w[#w+1] = x; end end
					table.sort(w);
					local h, hs = {}, {};
					for _, x in ipairs(have) do if (not hs[x]) then hs[x] = true; h[#h+1] = x; end end
					table.sort(h);
					check(same(w, h), path .. ": placeholders of " .. string.format("%q", e.msgid),
						table.concat(h, ",") .. " vs " .. table.concat(w, ","));
				end
			end
		end
	end
end

print("\n9. command help");
sent = {};
send_usage(2, commands.lang);
eq(sent[1] and sent[1][2], "usage: lang [<code>|auto]", "send_usage, through a message");
local cmds_mod = dofile("catalog/overrides/command_cmds.lua");
can_see_command = function() return true; end
local all = {lang = commands.lang};
commands = all;
local help = cmds_seen.help;
sent = {};
help.func(0, {"lang"});
check(sent[1] and sent[1][2]:find("Voir ou choisir la langue", 1, true),
	"/help shows a description in the reader's language", sent[1] and sent[1][2]);
sent = {};
help.func(2, {"lang"});
check(sent[1] and sent[1][2]:find("Show or choose the language", 1, true),
	"and in English to whoever reads English", sent[1] and sent[1][2]);
sent = {};
cmds_seen.apropos.func(0, {}, "/apropos langue");
check(sent[1] ~= nil, "/apropos searches what the player reads");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
