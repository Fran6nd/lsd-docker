-- dev/l10n_mt.lua -- machine translation into the .po files, for review
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit dev/l10n_mt.lua <lang> [--url URL] [--accept] [<path>...]
--
-- Fills every EMPTY entry of each locales/<lang>.po (under the paths,
-- or the whole catalog) from a LibreTranslate server -- self-hosted,
-- open source; dev/l10n_mt.sh runs one in Docker. A translation already
-- there, human or machine, is never touched.
--
-- What it writes is marked: a "# machine-translated (LibreTranslate)"
-- comment, and "#, fuzzy" unless --accept -- and lib_l10n does not use a
-- fuzzy entry, so without --accept nothing reaches a player until a
-- translator has looked at it (Poedit: Next Fuzzy, fix, clear the flag).
--
-- What a machine must not translate is taken out first and put back
-- after: %(name) placeholders, /commands, %p and %h, {x=...}-style
-- braces, and the words of dev/l10n_glossary/<lang>.tsv ("english<TAB>
-- translation" per line, matched as written), which go in as their
-- translation so that game words -- intel, tent, the Fall -- read the
-- same everywhere, and the words the engine gets wrong are fixed once. A result that lost or
-- gained a placeholder is thrown away and the entry left empty, which
-- is the rule tests/l10n_test.lua enforces too.
package.path = "catalog/core/?.lua;" .. package.path;
local P = require "l10n_po";

--================================ JSON ==============================--
-- Only what LibreTranslate's requests and replies need.

local function json_str(s)
	return '"' .. string.gsub(s, '[%c"\\]', function(c)
		local map = {['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n",
			["\r"] = "\\r", ["\t"] = "\\t"};
		return map[c] or string.format("\\u%04x", string.byte(c));
	end) .. '"';
end

local function json_encode(v)
	if (type(v) == "string") then return json_str(v); end
	if (type(v) == "number" or type(v) == "boolean") then return tostring(v); end
	if (v[1] ~= nil or next(v) == nil) then
		local out = {};
		for i, x in ipairs(v) do out[i] = json_encode(x); end
		return "[" .. table.concat(out, ",") .. "]";
	end
	local out = {};
	for k, x in pairs(v) do out[#out+1] = json_str(k) .. ":" .. json_encode(x); end
	return "{" .. table.concat(out, ",") .. "}";
end

local function utf8_char(cp)
	if (cp < 0x80) then return string.char(cp); end
	if (cp < 0x800) then
		return string.char(0xc0 + math.floor(cp / 0x40), 0x80 + cp % 0x40);
	end
	if (cp < 0x10000) then
		return string.char(0xe0 + math.floor(cp / 0x1000),
			0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40);
	end
	return string.char(0xf0 + math.floor(cp / 0x40000),
		0x80 + math.floor(cp / 0x1000) % 0x40,
		0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40);
end

local function json_decode(s)
	local i = 1;
	local value;
	local function ws() i = string.find(s, "[^%s]", i) or #s + 1; end
	local function str()
		i = i + 1;
		local out = {};
		while (true) do
			local c = string.sub(s, i, i);
			if (c == "") then error("unfinished JSON string", 0); end
			if (c == '"') then i = i + 1; break; end
			if (c == "\\") then
				local e = string.sub(s, i + 1, i + 1);
				if (e == "u") then
					local cp = tonumber(string.sub(s, i + 2, i + 5), 16);
					i = i + 6;
					if (cp >= 0xd800 and cp < 0xdc00 and string.sub(s, i, i + 1) == "\\u") then
						local lo = tonumber(string.sub(s, i + 2, i + 5), 16);
						cp = 0x10000 + (cp - 0xd800) * 0x400 + (lo - 0xdc00);
						i = i + 6;
					end
					out[#out+1] = utf8_char(cp);
				else
					local map = {n = "\n", r = "\r", t = "\t", b = "\b", f = "\f"};
					out[#out+1] = map[e] or e;
					i = i + 2;
				end
			else
				out[#out+1] = c;
				i = i + 1;
			end
		end
		return table.concat(out);
	end
	function value()
		ws();
		local c = string.sub(s, i, i);
		if (c == '"') then return str(); end
		if (c == "{") then
			local t = {};
			i = i + 1; ws();
			if (string.sub(s, i, i) == "}") then i = i + 1; return t; end
			while (true) do
				ws();
				local k = str();
				ws(); i = i + 1; -- :
				t[k] = value();
				ws();
				local d = string.sub(s, i, i);
				i = i + 1;
				if (d == "}") then return t; end
			end
		end
		if (c == "[") then
			local t = {};
			i = i + 1; ws();
			if (string.sub(s, i, i) == "]") then i = i + 1; return t; end
			while (true) do
				t[#t+1] = value();
				ws();
				local d = string.sub(s, i, i);
				i = i + 1;
				if (d == "]") then return t; end
			end
		end
		local lit = string.match(s, "^[%w%.%-+]+", i);
		if (lit == nil) then error("bad JSON at " .. i, 0); end
		i = i + #lit;
		if (lit == "true") then return true; end
		if (lit == "false") then return false; end
		if (lit == "null") then return nil; end
		return tonumber(lit);
	end
	return value();
end

--================================ HTTP ==============================--

local SCRATCH = os.tmpname();

local function q(p) return "'" .. string.gsub(p, "'", "'\\''") .. "'"; end

local function http(url, body)
	local cmd;
	if (body ~= nil) then
		local f = assert(io.open(SCRATCH, "w"));
		f:write(body);
		f:close();
		cmd = "curl -sS --fail -X POST -H 'Content-Type: application/json' --data-binary @"
			.. q(SCRATCH) .. " " .. q(url);
	else
		cmd = "curl -sS --fail " .. q(url);
	end
	local p = io.popen(cmd);
	local out = p:read("*a");
	local ok = p:close();
	if (not ok or out == "") then
		error("no answer from " .. url, 0);
	end
	return json_decode(out);
end

--============================ PROTECTION ============================--

-- The pieces of a text no machine may touch, in the order they are
-- looked for: placeholders first, so a /command's %(arg) stays one.
local PROTECT = {
	"%%%b()",            -- %(name)
	"{[^{}]*}",          -- {x=%(x), ...} and the like, whole
	"/[%a_][%w_]*",      -- /commands
	"%%[ph]%f[%W]",      -- the pie menu's %p and %h
	"<[^<>]*>",          -- <player> and the like in usage lines
	"%[LSd%]",           -- the server's name in the motd
};

-- The text with every protected piece a token, Z901, Z902...: plain
-- text, not HTML, which the engine handles worse (it hallucinated around
-- tags), and a token shape every target language leaves alone -- an "X1"
-- came back with a Cyrillic X. Glossary words become tokens too, which
-- put back their translation. Matched as written (case and all), so
-- "Type" opening an instruction is not "type" inside a sentence.
local function protect(text, glossary)
	local pieces = {};
	local marks = {};

	local function mark(s, e, value)
		for _, m in ipairs(marks) do
			if (s <= m.e and e >= m.s) then return; end
		end
		marks[#marks+1] = {s = s, e = e, value = value};
	end

	for _, pat in ipairs(PROTECT) do
		local at = 1;
		while (true) do
			local s, e = string.find(text, pat, at);
			if (s == nil) then break; end
			mark(s, e, string.sub(text, s, e));
			at = e + 1;
		end
	end

	for _, g in ipairs(glossary) do
		local at = 1;
		while (true) do
			local s, e = string.find(text, g.find, at, true);
			if (s == nil) then break; end
			local before = s > 1 and string.sub(text, s - 1, s - 1) or " ";
			local after = string.sub(text, e + 1, e + 1);
			if (not string.find(before, "[%w_]") and not string.find(after, "[%w_]")) then
				mark(s, e, g.to);
			end
			at = e + 1;
		end
	end

	table.sort(marks, function(a, b) return a.s < b.s; end);
	local out, at = {}, 1;
	for n, m in ipairs(marks) do
		out[#out+1] = string.sub(text, at, m.s - 1);
		out[#out+1] = string.format("Z9%02d", n);
		pieces[n] = m.value;
		at = m.e + 1;
	end
	out[#out+1] = string.sub(text, at);
	return table.concat(out), pieces;
end

-- The translation with its pieces back, or nil when one went missing or
-- came back twice.
local function restore(text, pieces)
	local seen, bad = {}, false;
	local s = string.gsub(text, "Z9(%d%d)", function(n)
		n = tonumber(n);
		if (pieces[n] == nil or seen[n]) then bad = true; return ""; end
		seen[n] = true;
		return pieces[n];
	end);
	for n in pairs(pieces) do
		if (not seen[n]) then bad = true; end
	end
	if (bad) then
		return nil;
	end
	s = string.gsub(s, "^%s+", "");
	s = string.gsub(s, "%s+$", "");
	return s;
end

--================================ MAIN ==============================--

local lang, url, accept, paths = nil, "http://127.0.0.1:5055", false, {};
local i = 1;
while (arg[i]) do
	if (arg[i] == "--url") then url = arg[i+1]; i = i + 1;
	elseif (arg[i] == "--accept") then accept = true;
	elseif (lang == nil) then lang = P.norm_lang(arg[i]);
	else paths[#paths+1] = (string.gsub(arg[i], "/$", ""));
	end
	i = i + 1;
end
if (lang == nil) then
	io.stderr:write("usage: luajit dev/l10n_mt.lua <lang> [--url URL] [--accept] [<path>...]\n");
	os.exit(2);
end

-- the engine's code for our language: zh is Simplified Chinese, which
-- newer LibreTranslate calls zh-Hans
local target;
for _, l in ipairs(http(url .. "/languages")) do
	local code = string.lower(l.code);
	if (code == lang or (lang == "zh" and code == "zh-hans")) then target = l.code; end
end
if (target == nil and lang == "zh") then
	for _, l in ipairs(http(url .. "/languages")) do
		if (l.code == "zh") then target = "zh"; end
	end
end
if (target == nil) then
	error("the server at " .. url .. " does not translate into " .. lang
		.. " (start it with --load-only en," .. lang .. ")", 0);
end

local glossary = {};
local gf = io.open("dev/l10n_glossary/" .. lang .. ".tsv");
if (gf) then
	for line in gf:lines() do
		local en, to = string.match(line, "^([^\t#][^\t]*)\t(.+)$");
		if (en) then glossary[#glossary+1] = {find = en, to = to}; end
	end
	gf:close();
	-- longest first, so "intel carrier" wins over "intel"
	table.sort(glossary, function(a, b) return #a.find > #b.find; end);
end

local files = {};
for f in io.popen("find catalog -path '*/locales/" .. lang .. ".po' | sort"):lines() do
	local wanted = #paths == 0;
	for _, p in ipairs(paths) do
		if (string.sub(f, 1, #p + 1) == p .. "/") then wanted = true; end
	end
	if (wanted) then files[#files+1] = f; end
end
if (#files == 0) then
	error("no locales/" .. lang .. ".po: start them with luajit dev/l10n.lua --new "
		.. lang, 0);
end

local MARK = "# machine-translated (LibreTranslate)";
local BATCH = 40;
local done, dropped, long = 0, {}, {};

for _, path in ipairs(files) do
	local f = io.open(path);
	local cat = P.parse(f:read("*a"));
	f:close();

	-- the texts to send: each empty entry's msgid, and its plural
	local jobs = {};
	for _, e in ipairs(cat.list) do
		local empty = (e.str == nil or e.str == "") and #e.forms == 0;
		if (empty) then
			jobs[#jobs+1] = {e = e, text = e.msgid, which = "one"};
			if (e.plural) then
				jobs[#jobs+1] = {e = e, text = e.plural, which = "other"};
			end
		end
	end

	for b = 1, #jobs, BATCH do
		local qs, metas = {}, {};
		for k = b, math.min(b + BATCH - 1, #jobs) do
			local text, pieces = protect(jobs[k].text, glossary);
			qs[#qs+1] = text;
			metas[#metas+1] = {job = jobs[k], pieces = pieces};
		end
		local reply = http(url .. "/translate", json_encode({q = qs, source = "en",
			target = target, format = "text"}));
		local outs = reply.translatedText;
		if (type(outs) ~= "table") then
			error(path .. ": unexpected reply from " .. url, 0);
		end
		for k, m in ipairs(metas) do
			local s = outs[k] and restore(outs[k], m.pieces);
			local job = m.job;
			if (s ~= nil and table.concat(P.placeholders(s), ",")
			    ~= table.concat(P.placeholders(job.text), ",")) then
				s = nil;
			end
			if (s == nil or s == "") then
				dropped[#dropped+1] = path .. ": " .. job.text;
			else
				job.result = s;
				if (#s > 200) then long[#long+1] = path .. ": " .. s; end
			end
		end
	end

	-- write back: an entry is filled only if every text it needs came
	for _, e in ipairs(cat.list) do
		local mine = {};
		for _, j in ipairs(jobs) do
			if (j.e == e) then mine[j.which] = j; end
		end
		local one, other = mine.one, mine.other;
		if (one and one.result and (not e.plural or (other and other.result))) then
			if (e.plural) then
				-- the singular for form 0, the plural for every other
				e.forms = {};
				for n = 1, cat.nplurals do
					e.forms[n] = (n == 1 and cat.nplurals > 1) and one.result or other.result;
				end
			else
				e.str = one.result;
			end
			e.fuzzy = not accept;
			local c = {};
			for _, x in ipairs(e.comments or {}) do
				if (x ~= MARK) then c[#c+1] = x; end
			end
			c[#c+1] = MARK;
			e.comments = c;
			done = done + 1;
		end
	end

	local w = assert(io.open(path, "w"));
	w:write(P.write(cat.header, cat.list));
	w:close();
end

os.remove(SCRATCH);
print(string.format("%s: %d entr%s machine-translated%s", lang, done,
	done == 1 and "y" or "ies", accept and "" or " (fuzzy: review, then clear the flag)"));
if (#dropped > 0) then
	print(#dropped .. " left empty (a placeholder was lost or mangled):");
	for _, d in ipairs(dropped) do print("  " .. d); end
end
if (#long > 0) then
	print(#long .. " longer than 200 bytes, check they fit a chat line:");
	for _, d in ipairs(long) do print("  " .. d); end
end
