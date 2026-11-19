-- ask_player_test.lua -- lib_ask_player: one question at a time, by chat or pie
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/ask_player_test.lua      (from the repository root)

local passed, failed = 0, 0;
local function check(ok, what, detail)
	if (ok) then passed = passed + 1; print("  PASS " .. what);
	else failed = failed + 1; print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or "")); end
end

--============================= STUBS ================================--
function init_mod() return {after = {}, before = {}, next = {}}; end
function getcfg(k, d) if (_G[k] == nil) then _G[k] = d; end end
function log() end
local now = 100;
function get_time() return now; end
MAX_PLAYERS = 32;
PID_BROADCAST = 0x20000000;

-- the real lib_l10n: server_msg and l10n_send_chat are what players read
local chat = {};
local L = dofile("tests/support/l10n_env.lua").load{
	server_msg = function(pid, line, via_l10n)
		if (not via_l10n) then chat[#chat+1] = {pid = pid, line = line}; end
	end,
};
local said = L.chat;

local override = {};
local overrides = 0;
function pie_menu_override(pid, pies) override[pid] = pies; overrides = overrides + 1; end

local cmd;
function register_command(c) cmd = c; end

local mod = dofile("catalog/libs/ask_player/lib_ask_player.lua");
local function answer(pid, arg) cmd.func(pid, {arg}); end

local choices = {{key = "yes", label = {en = "Yes"}}, {key = "no", label = {en = "No"}}};
local got = {};
local function cb(tag)
	return function(pid, key) got[#got+1] = {tag = tag, pid = pid, key = key}; end
end
local function last() return got[#got]; end
local Q = {en = "Switch team?"};

--============================= CHECKS ===============================--
print("\n1. asking: the chat and the pie");
local id = ask_player(0, Q, choices, cb("a"));
check(id ~= nil and ask_player_open(0).id == id, "ask returns an id, and the question is open");
check(chat[1].line == "Switch team?" and chat[2].line
	== "1) Yes  2) No -- answer with /answer <number>", "the question, then the numbered choices");
local pie = override[0];
check(pie ~= nil and pie.id == "ask_player" and pie.theme == Q and pie.when == "any",
	"the pie menu is overridden: the question as theme, every context");
check(#pie.slices == 2 and pie.slices[2].text == "/answer no" and pie.slices[1].label.en == "Yes",
	"its wedges send /answer <key>");
check(ask_player_open(1) == nil, "nobody else has one");

print("\n2. a wrong answer re-states the choices");
local c = #chat;
answer(0, "7"); answer(0, "maybe"); answer(0, "1.5");
check(#said == 3 and said[1].m == "That is not one of the answers.", "told it is wrong");
check(#chat == c + 3 and chat[#chat].line:find("1) Yes", 1, true), "the choices said again");
check(#got == 0 and ask_player_open(0) ~= nil, "and the question is still open");
answer(2, "1");
check(said[#said].m == "Nobody has asked you anything.", "no question open: told so");

print("\n3. answering by number, and the menu comes back");
answer(0, "2");
check(#got == 1 and last().tag == "a" and last().pid == 0 and last().key == "no",
	"by number");
check(ask_player_open(0) == nil and override[0] == nil, "closed, and the override cleared");
ask_player(0, Q, choices, cb("b"));
answer(0, "YES");
check(last().tag == "b" and last().key == "yes", "by key, in any case");

print("\n4. timeout");
now = 100;
ask_player(0, Q, choices, cb("t"), {secs = 5});
now = 104; mod.after.tick();
check(ask_player_open(0) ~= nil, "not before its time");
now = 105; mod.after.tick();
check(last().tag == "t" and last().key == nil and ask_player_open(0) == nil
	and override[0] == nil, "nil at the deadline, the menu back");
ask_player(0, Q, choices, cb("d"));
now = 134; mod.after.tick();
check(last().tag == "t", "ask_player_secs defaults to 30: still open at 29");
now = 135; mod.after.tick();
check(last().tag == "d" and last().key == nil, "and over at 30");

print("\n5. the queue");
got = {};
now = 200;
local a = ask_player(0, {en = "First?"}, choices, cb("1"));
local b = ask_player(0, {en = "Second?"}, choices, cb("2"));
check(ask_player_open(0).id == a and #chat > 0 and chat[#chat].line ~= nil
	and override[0].theme.en == "First?", "the second waits");
answer(0, "yes");
check(got[1].tag == "1" and ask_player_open(0).id == b, "answered, the second is put");
check(override[0].theme.en == "Second?" and chat[#chat - 1].line == "Second?",
	"with its own pie and chat");
now = 220;
mod.after.tick();
check(#got == 1, "its timeout started when it was put");
now = 230;
mod.after.tick();
check(got[2].tag == "2" and got[2].key == nil, "and runs out then");
local x = ask_player(0, Q, choices, cb("x"));
local y = ask_player(0, Q, choices, cb("y"));
check(ask_player_cancel(0, y) == 1 and last().tag == "y" and last().key == nil
	and ask_player_open(0).id == x, "cancel by id takes a waiting one");
ask_player(0, Q, choices, cb("z"));
check(ask_player_cancel(0) == 2 and ask_player_open(0) == nil and override[0] == nil
	and got[#got].tag == "x", "cancel without id takes all");

print("\n6. disconnect");
got = {};
ask_player(1, Q, choices, cb("p"));
ask_player(1, Q, choices, cb("q"));
mod.after.on_disconnect(1);
check(#got == 2 and got[1].tag == "p" and got[2].tag == "q"
	and got[1].key == nil and got[2].key == nil, "every callback gets nil");
check(ask_player_open(1) == nil, "nothing left open");
answer(1, "1");
check(#got == 2, "and nothing answers later");

print("\n7. callbacks and bad calls");
ask_player(0, Q, choices, function() error("boom"); end);
local ok = pcall(answer, 0, "yes");
check(ok and ask_player_open(0) == nil, "a callback that raises is contained");
ask_player(0, Q, choices, function(pid) ask_player(pid, {en = "Again?"}, choices, cb("n")); end);
answer(0, "yes");
check(ask_player_open(0) ~= nil and ask_player_open(0).question.en == "Again?",
	"a callback may ask again");
ask_player_cancel(0);
check(ask_player(0, Q, {choices[1]}, cb("")) == nil, "one choice: refused");
check(ask_player(0, Q, {choices[1], {key = "2", label = {en = "x"}}}, cb("")) == nil,
	"a numeric key: refused");
check(ask_player(0, Q, {choices[1], {key = "YES", label = {en = "x"}}}, cb("")) == nil,
	"a repeated key: refused");
check(ask_player(0, Q, choices, nil) == nil, "no callback: refused");

print("\n8. unload");
ask_player(0, Q, choices, cb("u"));
mod.on_unload();
check(ask_player == nil and ask_player_open == nil and override[0] == nil,
	"the globals go, the override with them");

L.clean(check);
print(string.format("\n%d checks, %d failed", passed + failed, failed));
os.exit(failed == 0 and 0 or 1);
