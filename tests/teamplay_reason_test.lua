-- teamplay_reason_test.lua -- lib_teamplay's label and /pingmark parsing
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/teamplay_reason_test.lua      (from the repository root)
--
-- The Teamplay spec has the server validate a Reason as well-formed
-- UTF-8, drop or sanitise anything malformed, and cap it "truncating on
-- a codepoint boundary". Those are pure functions inside lib_teamplay,
-- so this loads the module against a stub of the LSd globals it touches
-- at load time and reaches them through the closures that use them --
-- no server, and no test-only export left in the module.

local failures, checks = 0, 0;

local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then
		print("  PASS " .. what);
	else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end

local function eq(got, want, what)
	check(got == want, what, string.format("got %q, want %q",
		tostring(got), tostring(want)));
end

--=========================== LOAD IT ================================--

local function hooks()
	return {before = {}, after = {}, next = {}};
end

function init_mod()
	local m = hooks();
	m.impl, m.late, m.early, m.xearly = hooks(), hooks(), hooks(), hooks();
	return m;
end

function getcfg(key, default)
	if (_G[key] == nil) then
		_G[key] = default;
	end
end

function pid_connected_table(default)
	return setmetatable({}, {__index = function() return default; end});
end

local registered = {};
function register_command(cmd, mod)
	registered[cmd.name] = cmd;
end

MAX_PLAYERS = 255;

dofile("catalog/extensions/teamplay/lib_teamplay.lua");

local function upvalue(fn, name)
	for i = 1, math.huge do
		local n, v = debug.getupvalue(fn, i);
		if (n == nil) then
			error("no upvalue " .. name, 2);
		end
		if (n == name) then
			return v;
		end
	end
end

local clean_reason = upvalue(upvalue(teamplay_mark, "reason_for"), "clean_reason");
local valid_utf8 = upvalue(clean_reason, "valid_utf8");
local utf8_truncate = upvalue(clean_reason, "utf8_truncate");
local pingmark = registered["pingmark"];
local decimal = upvalue(pingmark.func, "decimal");

--============================ CHECKS ================================--

print("\n1. well-formed UTF-8 is accepted");
check(valid_utf8(""), "the empty string (a reasonless ping)");
check(valid_utf8("enemy here"), "ASCII");
check(valid_utf8("ennemi l\xc3\xa0"), "two-byte: a with grave");
check(valid_utf8("\xe2\x82\xac"), "three-byte: euro sign");
check(valid_utf8("\xf0\x9f\x8e\xaf"), "four-byte: an emoji");
check(valid_utf8("\xf4\x8f\xbf\xbf"), "U+10FFFF, the last codepoint");

print("\n2. malformed UTF-8 is refused");
check(not valid_utf8("\xc3"), "a lead byte with nothing after it");
check(not valid_utf8("\xe2\x82"), "a three-byte sequence cut short");
check(not valid_utf8("\x80"), "a stray continuation byte");
check(not valid_utf8("\xc0\xaf"), "overlong two-byte '/'");
check(not valid_utf8("\xe0\x80\xaf"), "overlong three-byte '/'");
check(not valid_utf8("\xf0\x80\x80\xaf"), "overlong four-byte '/'");
check(not valid_utf8("\xed\xa0\x80"), "a UTF-16 surrogate");
check(not valid_utf8("\xf4\x90\x80\x80"), "past U+10FFFF");
check(not valid_utf8("\xff"), "0xff, never UTF-8");
check(not valid_utf8("ok\xe9"), "CP437/Latin-1 bytes after ASCII");

print("\n3. truncation lands on a codepoint boundary");
eq(utf8_truncate("abcdef", 4), "abcd", "ASCII is cut at the cap");
eq(utf8_truncate("abc", 4), "abc", "under the cap is untouched");
eq(utf8_truncate("ab\xe2\x82\xac", 4), "ab", "a euro sign across the cap is dropped whole");
eq(utf8_truncate("ab\xe2\x82\xac", 5), "ab\xe2\x82\xac", "and kept whole when it fits");
eq(utf8_truncate("\xf0\x9f\x8e\xaf\xf0\x9f\x8e\xaf", 7), "\xf0\x9f\x8e\xaf",
	"four-byte characters: the one across the cap goes");
check(valid_utf8(utf8_truncate(string.rep("\xc3\xa0", 100), 129)),
	"an odd cap over two-byte characters still yields valid UTF-8");

print("\n4. clean_reason: validate, then cap");
-- ZeroSpades keeps 64 bytes of a Reason (Teamplay::kMaxReasonBytes in
-- Sources/Client/Teamplay.cpp SanitizeReason), so sending more is wasted
check(teamplay_reason_max <= 64, "the default cap is no more than the client keeps",
	teamplay_reason_max);
eq(clean_reason(string.rep("a", 100)), string.rep("a", 64),
	"a 100-byte reason goes out as the 64 the client would keep");
teamplay_reason_max = 8;
eq(clean_reason(nil), "", "no reason is the empty reason");
eq(clean_reason("bad\xff"), "", "malformed is dropped, not forwarded");
eq(clean_reason("1234567\xc3\xa0"), "1234567",
	"valid but over the cap is shortened, not dropped");
eq(clean_reason("flag"), "flag", "a short valid reason passes as is");
teamplay_reason_max = 64;

print("\n5. /pingmark positions are base-10 numbers with '.'");
eq(decimal("256"), 256, "an integer");
eq(decimal("256.5"), 256.5, "a decimal");
eq(decimal("-1.25"), -1.25, "a signed decimal");
eq(decimal(".5"), 0.5, "a leading point");
eq(decimal("12."), 12, "a trailing point");
eq(decimal("0x10"), nil, "hex is not base 10");
eq(decimal("1e3"), nil, "no exponents");
eq(decimal("256,5"), nil, "a comma is not the decimal point");
eq(decimal("nan"), nil, "nan is not a number here");
eq(decimal("%h"), nil, "an unexpanded %h");
eq(decimal(nil), nil, "a missing argument");

print("\n6. a reason is a message, read through the real lib_l10n");
local reason_for = upvalue(teamplay_mark, "reason_for");
eq(reason_for(0, "plain"), "plain", "plain text as it is (no lib_l10n)");
eq(reason_for(0, {en = "Enemy here"}), "Enemy here", "a {en = ...} map without lib_l10n");
dofile("tests/support/l10n_env.lua").load{};
eq(reason_for(0, {en = "Enemy here"}), "Enemy here", "a {en = ...} map, not table: 0x...");
eq(reason_for(0, l10n_msg({en = "%(who) here"}, {who = {en = "Enemy"}})), "Enemy here",
	"a message with a map for an argument");
eq(reason_for(0, "plain"), "plain", "plain text as it is");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
