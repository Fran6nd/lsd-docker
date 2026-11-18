-- dev/l10n.lua -- the translation templates, and the .po files kept in step
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit dev/l10n.lua            rewrite every template and .po
--   luajit dev/l10n.lua --check    fail if any is out of date (CI)
--   luajit dev/l10n.lua --new fr [<path>...]
--                                  also start locales/fr.po, in every
--                                  entry or those under the paths
--
-- Every message a script can send is in its own Lua, written the way
-- lib_l10n reads it: a table with en= (and maybe en_plural=, ctx=), or
-- l10n_msg("..."); and every command's desc = "...", in the "command"
-- context. This finds them -- with a small Lua lexer, not a
-- pattern, so comments and other strings are not mistaken for one --
-- and writes them per script:
--
--   <entry>/locales/template.pot   what there is to translate
--   <entry>/locales/<lang>.po      merged: new texts added untranslated,
--                                  gone ones kept commented out (#~)
--
-- An entry is a catalog/<category>/<id>/ directory; upstream LSd's own
-- scripts and image/config.lua (the stock tips and motd) are one more,
-- catalog/overrides, whose translations the
-- entrypoint installs as scripts/locales/<lang>/lsd.po.
--
-- xgettext cannot read en= tables, which is why this exists; the files
-- it writes are ordinary gettext, for any .po editor or msgfmt -c.
package.path = "catalog/core/?.lua;" .. package.path;
local P = require "l10n_po";

--=============================== LEXER ==============================--

-- Lua tokens: {k="str", v=<value>} | {k="name", v=} | {k=<symbol>},
-- each with its line. Comments are dropped.
local ESC = {n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f",
	v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n"};

local function lex(src)
	local toks, i, line = {}, 1, 1;
	local n = #src;

	local function long_bracket(at)
		local eqs = string.match(src, "^%[(=*)%[", at);
		if (eqs == nil) then return nil; end
		local open = 2 + #eqs;
		local close = "]" .. eqs .. "]";
		local e = string.find(src, close, at + open, true);
		if (e == nil) then error("unfinished long string at line " .. line, 0); end
		local body = string.sub(src, at + open, e - 1);
		body = string.gsub(body, "^\n", "");
		return body, e + #close;
	end

	while (i <= n) do
		local c = string.sub(src, i, i);
		if (c == "\n") then
			line = line + 1;
			i = i + 1;
		elseif (string.find(c, "%s")) then
			i = i + 1;
		elseif (string.sub(src, i, i+1) == "--") then
			local body, after = long_bracket(i + 2);
			if (body ~= nil) then
				for _ in string.gmatch(string.sub(src, i, after - 1), "\n") do line = line + 1; end
				i = after;
			else
				local e = string.find(src, "\n", i, true) or n + 1;
				i = e;
			end
		elseif (c == '"' or c == "'") then
			local buf, j = {}, i + 1;
			while (true) do
				local d = string.sub(src, j, j);
				if (d == "") then error("unfinished string at line " .. line, 0); end
				if (d == c) then break; end
				if (d == "\\") then
					local e = string.sub(src, j+1, j+1);
					if (string.find(e, "%d")) then
						local digits = string.match(src, "^%d%d?%d?", j+1);
						buf[#buf+1] = string.char(tonumber(digits));
						j = j + 1 + #digits;
					else
						buf[#buf+1] = ESC[e] or e;
						if (e == "\n") then line = line + 1; end
						j = j + 2;
					end
				else
					buf[#buf+1] = d;
					j = j + 1;
				end
			end
			toks[#toks+1] = {k = "str", v = table.concat(buf), line = line};
			i = j + 1;
		elseif (c == "[" and string.find(src, "^%[=*%[", i)) then
			local body, after = long_bracket(i);
			toks[#toks+1] = {k = "str", v = body, line = line};
			for _ in string.gmatch(string.sub(src, i, after - 1), "\n") do line = line + 1; end
			i = after;
		elseif (string.find(c, "[%a_]")) then
			local w = string.match(src, "^[%w_]+", i);
			toks[#toks+1] = {k = "name", v = w, line = line};
			i = i + #w;
		elseif (string.find(c, "%d")) then
			local w = string.match(src, "^[%w_%.]+", i);
			toks[#toks+1] = {k = "num", line = line};
			i = i + #w;
		else
			local three = string.sub(src, i, i+2);
			local two = string.sub(src, i, i+1);
			local sym = (three == "...") and three
				or ((two == ".." or two == "==" or two == "~=" or two == "<="
				     or two == ">=" or two == "::") and two) or c;
			toks[#toks+1] = {k = sym, line = line};
			i = i + #sym;
		end
	end
	return toks;
end

--============================== MESSAGES ============================--

-- A string expression made only of literals: "a" .. "b". Returns its
-- value and the token after it, or nil if it is anything else.
local function literal(toks, at)
	if (toks[at] == nil or toks[at].k ~= "str") then return nil; end
	local parts = {toks[at].v};
	at = at + 1;
	while (toks[at] and toks[at].k == ".." and toks[at+1] and toks[at+1].k == "str") do
		parts[#parts+1] = toks[at+1].v;
		at = at + 2;
	end
	-- "a" .. var is not a literal: its text is not known here
	if (toks[at] and toks[at].k == "..") then return nil; end
	return table.concat(parts), at;
end

-- Every message in one file: {ctx=, msgid=, plural=, line=}, plus the
-- en= values that were not literals, so they can be reported.
local function messages(src)
	local toks = lex(src);
	local found, skipped = {}, {};
	local stack = {};

	for i, t in ipairs(toks) do
		if (t.k == "{") then
			stack[#stack+1] = {line = t.line};
		elseif (t.k == "}") then
			local tab = table.remove(stack);
			if (tab and tab.en ~= nil) then
				found[#found+1] = {ctx = tab.ctx, msgid = tab.en,
					plural = tab.en_plural, line = tab.en_line};
			end
		elseif (t.k == "name" and (t.v == "en" or t.v == "en_plural" or t.v == "ctx")
		        and toks[i+1] and toks[i+1].k == "=" and #stack > 0
		        and toks[i-1] and (toks[i-1].k == "{" or toks[i-1].k == ","
		                           or toks[i-1].k == ";")) then
			local v = literal(toks, i + 2);
			local top = stack[#stack];
			if (v ~= nil) then
				top[t.v] = v;
				if (t.v == "en") then top.en_line = t.line; end
			elseif (t.v == "en") then
				skipped[#skipped+1] = t.line;
			end
		elseif (t.k == "name" and t.v == "desc" and toks[i+1]
		        and toks[i+1].k == "=" and #stack > 0 and toks[i-1]
		        and (toks[i-1].k == "{" or toks[i-1].k == "," or toks[i-1].k == ";")) then
			-- a command's description, shown by /cmds and /help in the
			-- reader's language (command_cmds, overridden)
			local v = literal(toks, i + 2);
			if (v ~= nil) then
				found[#found+1] = {ctx = "command", msgid = v, line = t.line};
			end
		elseif (t.k == "name" and t.v == "l10n_msg" and toks[i+1]
		        and toks[i+1].k == "(") then
			local v = literal(toks, i + 2);
			if (v ~= nil) then
				found[#found+1] = {msgid = v, line = t.line};
			end
		end
	end
	return found, skipped;
end

--=============================== FILES ==============================--

local function sh_lines(cmd)
	local out = {};
	for l in io.popen(cmd):lines() do out[#out+1] = l; end
	return out;
end

local function read(p)
	local f = io.open(p);
	if (f == nil) then return nil; end
	local s = f:read("*a");
	f:close();
	return s;
end

local function q(p) return "'" .. string.gsub(p, "'", "'\\''") .. "'"; end

-- Every entry, with the Lua files that are its own.
local function entries()
	local out = {};
	for _, s in ipairs(sh_lines("find catalog -name script.lua | sort")) do
		local dir = string.match(s, "^(.*)/script%.lua$");
		out[#out+1] = {dir = dir,
			files = sh_lines("find " .. q(dir) .. " -name '*.lua' ! -name script.lua | sort")};
	end
	out[#out+1] = {dir = "catalog/overrides", upstream = true,
		files = sh_lines("ls lsd/scripts/*.lua catalog/overrides/*.lua image/config.lua | sort")};
	return out;
end

local TEMPLATE_HEADER = table.concat({
	"Project-Id-Version: lsd-docker\n",
	"MIME-Version: 1.0\n",
	"Content-Type: text/plain; charset=UTF-8\n",
	"Content-Transfer-Encoding: 8bit\n",
}, "");

-- What a new <lang>.po starts with. The plural rule is gettext's for the
-- common languages; anything else gets English's, to be corrected.
local PLURALS = {
	en = "nplurals=2; plural=(n != 1);", de = "nplurals=2; plural=(n != 1);",
	es = "nplurals=2; plural=(n != 1);", it = "nplurals=2; plural=(n != 1);",
	nl = "nplurals=2; plural=(n != 1);", pt = "nplurals=2; plural=(n != 1);",
	fr = "nplurals=2; plural=(n > 1);", pt_br = "nplurals=2; plural=(n > 1);",
	ja = "nplurals=1; plural=0;", ko = "nplurals=1; plural=0;",
	zh = "nplurals=1; plural=0;", vi = "nplurals=1; plural=0;",
	ru = "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
	uk = "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
	pl = "nplurals=3; plural=(n==1 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
	cs = "nplurals=3; plural=(n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2;",
};

local function new_header(lang)
	return TEMPLATE_HEADER .. "Language: " .. lang .. "\n"
		.. "Plural-Forms: " .. (PLURALS[lang] or PLURALS[string.match(lang, "^[^_]+")]
		                        or PLURALS.en) .. "\n";
end

-- The template of one entry: every message once, with where it is.
local function template(entry)
	local list, by_key, skipped = {}, {}, {};
	for _, f in ipairs(entry.files) do
		local src = read(f);
		local ok, found, skip = pcall(messages, src);
		if (not ok) then
			error(f .. ": " .. tostring(found), 0);
		end
		for _, l in ipairs(skip) do skipped[#skipped+1] = f .. ":" .. l; end
		for _, m in ipairs(found) do
			local key = P.key(m.ctx, m.msgid);
			local e = by_key[key];
			if (e == nil) then
				e = {ctx = m.ctx, msgid = m.msgid, plural = m.plural, refs = {}};
				by_key[key] = e;
				list[#list+1] = e;
			end
			-- the file, not the line: a line number would make every
			-- unrelated edit above a message a stale template
			if (e.refs[#e.refs] ~= f) then
				e.refs[#e.refs+1] = f;
			end
		end
	end
	return list, by_key, skipped;
end

-- The .po for `lang` brought in line with the template: translations
-- kept by key, new texts added empty, gone ones kept as #~.
local function merge(old, list, lang)
	local cat = old and P.parse(old) or nil;
	local have = {};
	for _, e in ipairs(cat and cat.list or {}) do
		have[P.key(e.ctx, e.msgid)] = e;
	end
	local np = cat and cat.nplurals or P.parse("msgid \"\"\nmsgstr " ..
		P.quote(new_header(lang)) .. "\n").nplurals;

	local out, used = {}, {};
	for _, t in ipairs(list) do
		local key = P.key(t.ctx, t.msgid);
		local o = have[key];
		used[key] = true;
		out[#out+1] = {ctx = t.ctx, msgid = t.msgid, plural = t.plural,
			refs = t.refs, nplurals = np,
			str = o and o.str or nil, forms = o and o.forms or nil,
			fuzzy = o and o.fuzzy or false, comments = o and o.comments or {}};
	end

	local gone = {};
	for _, e in ipairs(cat and cat.list or {}) do
		local key = P.key(e.ctx, e.msgid);
		local translated = (e.str ~= nil and e.str ~= "") or #e.forms > 0;
		if (not used[key] and translated) then
			gone[#gone+1] = e;
		end
	end


	return P.write(cat and cat.header or new_header(lang), out, gone);
end

--================================ MAIN ==============================--

local check, new_lang, only = false, nil, {};
local i = 1;
while (arg[i]) do
	if (arg[i] == "--check") then
		check = true;
	elseif (arg[i] == "--new" and arg[i+1]) then
		new_lang = P.norm_lang(arg[i+1]) or error("--new: not a language code", 0);
		i = i + 1;
	elseif (new_lang ~= nil and not string.find(arg[i], "^%-")) then
		only[#only+1] = (string.gsub(arg[i], "/$", ""));
	else
		io.stderr:write("usage: luajit dev/l10n.lua [--check] [--new <lang> [<path>...]]\n");
		os.exit(2);
	end
	i = i + 1;
end

local stale, written, total = {}, 0, 0;

local function put(path, text)
	if (read(path) == text) then return; end
	if (check) then
		stale[#stale+1] = path;
		return;
	end
	os.execute("mkdir -p " .. q(string.match(path, "^(.*)/")));
	local f = assert(io.open(path, "w"));
	f:write(text);
	f:close();
	written = written + 1;
end

for _, e in ipairs(entries()) do
	local list, _, skipped = template(e);
	for _, s in ipairs(check and {} or skipped) do
		io.stderr:write("note: " .. s .. ": en= is not a literal, so it cannot be translated\n");
	end

	local loc = e.dir .. "/locales";
	if (#list > 0) then
		total = total + #list;
		put(loc .. "/template.pot", P.write(TEMPLATE_HEADER, list));

		local langs = {};
		for _, f in ipairs(sh_lines("ls " .. q(loc) .. " 2>/dev/null")) do
			local l = string.match(f, "^(.+)%.po$");
			if (l) then langs[l] = true; end
		end
		local wanted = #only == 0;
		for _, p in ipairs(only) do
			if (e.dir == p or string.sub(e.dir, 1, #p + 1) == p .. "/") then
				wanted = true;
			end
		end
		if (new_lang and wanted) then langs[new_lang] = true; end

		for l in pairs(langs) do
			local path = loc .. "/" .. l .. ".po";
			put(path, merge(read(path), list, l));
		end
	elseif (read(loc .. "/template.pot") ~= nil) then
		-- nothing to translate any more
		if (check) then stale[#stale+1] = loc .. "/template.pot";
		else os.remove(loc .. "/template.pot"); end
	end
end

if (check) then
	if (#stale > 0) then
		io.stderr:write("translation files out of date (run: luajit dev/l10n.lua):\n  "
			.. table.concat(stale, "\n  ") .. "\n");
		os.exit(1);
	end
	print(string.format("translation templates up to date (%d messages)", total));
else
	print(string.format("%d messages; %d file(s) written", total, written));
end
