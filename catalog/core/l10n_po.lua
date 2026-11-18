-- l10n_po.lua -- gettext catalogs, plural forms and locales, in pure Lua
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- The parts of translation that need no server, so lib_l10n, lsdctl and
-- the tests share one copy. The file format is gettext's, as zerospades
-- uses it (Resources/Locales/<lang>/zerospades.po): the English text is
-- the key, an optional msgctxt tells two identical English strings
-- apart, and the header's Plural-Forms says which plural a count takes.
-- Placeholders are LSd's own, %(name), filled from a table.
--
--   P.parse(text)           -> {entries = {key -> msgstr or {forms}},
--                               plural = fn(n) -> index, nplurals}
--   P.key(ctx, msgid)       -> the entries key
--   P.compile_plural(expr)  -> fn(n) -> index, or nil, err
--   P.norm_lang(l)          -> "fr_ca", or nil if it is not a locale
--   P.candidates(lang, default) -> {"fr_ca", "fr", <default>, "en"}
--   P.interp(str, tab)      -> str with %(name) filled from tab
local P = {};

--============================== LOCALES =============================--

-- "fr-CA", "FR_ca" and "fr_ca" are one locale; zerospades lowercases
-- and uses "_" (Strings.cpp LoadCurrentLocale), and so does this.
function P.norm_lang(l)
	if (type(l) ~= "string") then
		return nil;
	end
	l = string.lower(string.gsub(l, "-", "_"));
	if (not string.find(l, "^[a-z][a-z][a-z]?$")
	    and not string.find(l, "^[a-z][a-z][a-z]?_[a-z0-9]+$")) then
		return nil;
	end
	return l;
end

-- The languages to try for `lang`, best first: the locale, its language
-- alone, the server's default and its language, then English -- the
-- text the scripts are written in. No duplicates.
function P.candidates(lang, default)
	local out, seen = {}, {};
	local function add(l)
		if (l ~= nil and not seen[l]) then
			seen[l] = true;
			out[#out+1] = l;
		end
	end

	lang = P.norm_lang(lang);
	default = P.norm_lang(default);
	add(lang);
	add(lang and string.match(lang, "^[^_]+"));
	add(default);
	add(default and string.match(default, "^[^_]+"));
	add("en");
	return out;
end

-- LSd's placeholders: %(name) is tab.name. One that tab does not name is
-- left as written, so a missing argument shows rather than vanishing.
function P.interp(str, tab)
	if (tab == nil) then
		return str;
	end
	return (string.gsub(str, "%%%b()", function(m)
		local v = tab[string.sub(m, 3, -2)];
		if (v == nil) then
			return nil;
		end
		return tostring(v);
	end));
end

-- The placeholders a string uses, as a sorted list, so a translation
-- can be checked against its English.
function P.placeholders(str)
	local names, seen = {}, {};
	for m in string.gmatch(str, "%%%b()") do
		local n = string.sub(m, 3, -2);
		if (not seen[n]) then
			seen[n] = true;
			names[#names+1] = n;
		end
	end
	table.sort(names);
	return names;
end

--============================ PLURAL FORMS ==========================--

-- gettext's plural expression is C: n, integers, ( ), ! - unary,
-- * / %, + -, < > <= >=, == !=, &&, ||, and ?:. Compiled to a Lua
-- closure once per catalog, by the same precedence zerospades' parser
-- uses (Strings.cpp PluralSelector), with C's integer division and
-- truthiness.
function P.compile_plural(expr)
	local toks, i = {}, 1;
	while (i <= #expr) do
		local c = string.sub(expr, i, i);
		local two = string.sub(expr, i, i+1);
		if (string.find(c, "%s")) then
			i = i + 1;
		elseif (string.find(c, "%d")) then
			local num = string.match(expr, "^%d+", i);
			toks[#toks+1] = {k = "num", v = tonumber(num)};
			i = i + #num;
		elseif (c == "n") then
			toks[#toks+1] = {k = "n"};
			i = i + 1;
		elseif (two == "&&" or two == "||" or two == "==" or two == "!="
		        or two == "<=" or two == ">=") then
			toks[#toks+1] = {k = two};
			i = i + 2;
		elseif (string.find(c, "[%+%-%*/%%<>!%?:%(%)]")) then
			toks[#toks+1] = {k = c};
			i = i + 1;
		else
			return nil, string.format("unexpected %q in plural expression", c);
		end
	end

	local pos = 1;
	local function peek() return toks[pos] and toks[pos].k; end
	local function take(k)
		if (peek() ~= k) then
			error(string.format("expected %s in plural expression", k), 0);
		end
		pos = pos + 1;
	end
	local function b(x) return x and 1 or 0; end
	local function cdiv(a, c)
		if (c == 0) then error("division by zero in plural expression", 0); end
		local q = a / c;
		return q >= 0 and math.floor(q) or math.ceil(q);
	end
	local function cmod(a, c)
		if (c == 0) then error("division by zero in plural expression", 0); end
		return a - cdiv(a, c)*c;
	end

	local ternary;

	local function value()
		local k = peek();
		if (k == "num") then
			local v = toks[pos].v;
			pos = pos + 1;
			return function() return v; end;
		elseif (k == "n") then
			pos = pos + 1;
			return function(n) return n; end;
		elseif (k == "(") then
			pos = pos + 1;
			local e = ternary();
			take(")");
			return e;
		elseif (k == "!") then
			pos = pos + 1;
			local e = value();
			return function(n) return b(e(n) == 0); end;
		elseif (k == "-") then
			pos = pos + 1;
			local e = value();
			return function(n) return -e(n); end;
		end
		error("unexpected " .. tostring(k or "end") .. " in plural expression", 0);
	end

	-- one left-associative binary level
	local function level(sub, ops)
		return function()
			local l = sub();
			while (ops[peek() or ""]) do
				local f = ops[peek()];
				pos = pos + 1;
				local r, ll = sub(), l;
				l = function(n) return f(ll(n), r(n)); end;
			end
			return l;
		end;
	end

	local term = level(value, {
		["*"] = function(a, c) return a*c; end,
		["/"] = cdiv, ["%"] = cmod});
	local sum = level(term, {
		["+"] = function(a, c) return a+c; end,
		["-"] = function(a, c) return a-c; end});
	local cmp = level(sum, {
		["<"] = function(a, c) return b(a < c); end,
		[">"] = function(a, c) return b(a > c); end,
		["<="] = function(a, c) return b(a <= c); end,
		[">="] = function(a, c) return b(a >= c); end});
	local eq = level(cmp, {
		["=="] = function(a, c) return b(a == c); end,
		["!="] = function(a, c) return b(a ~= c); end});
	local land = level(eq, {
		["&&"] = function(a, c) return b(a ~= 0 and c ~= 0); end});
	local lor = level(land, {
		["||"] = function(a, c) return b(a ~= 0 or c ~= 0); end});

	function ternary()
		local cond = lor();
		if (peek() == "?") then
			pos = pos + 1;
			local yes = ternary();
			take(":");
			local no = ternary();
			return function(n)
				if (cond(n) ~= 0) then return yes(n); end
				return no(n);
			end;
		end
		return cond;
	end

	local ok, fn = pcall(function()
		local e = ternary();
		if (pos <= #toks) then
			error("trailing " .. toks[pos].k .. " in plural expression", 0);
		end
		return e;
	end);
	if (not ok) then
		return nil, fn;
	end
	return fn;
end

--================================ .PO ===============================--

function P.key(ctx, msgid)
	if (ctx == nil or ctx == "") then
		return msgid;
	end
	return ctx .. "\4" .. msgid;
end

local ESC = {n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\"};

local function unquote(s, lineno)
	local body = string.match(s, '^"(.*)"%s*$');
	if (body == nil) then
		error(string.format("line %d: expected a quoted string", lineno), 0);
	end
	return (string.gsub(body, "\\(.)", function(c) return ESC[c] or c; end));
end

-- A gettext catalog. Fuzzy entries are skipped, as gettext skips them:
-- a fuzzy translation is a guess nobody has checked yet.
function P.parse(text)
	local entries = {};
	local header = "";
	local cur, field, fuzzy = {}, nil, false;
	local lineno = 0;

	local function flush()
		if (cur.msgid ~= nil and not fuzzy) then
			if (cur.msgid == "" and cur.ctx == nil) then
				header = cur.str or "";
			elseif (cur.plural ~= nil) then
				local forms, any = {}, false;
				for k, v in pairs(cur.forms or {}) do
					forms[k + 1] = v;
					if (v ~= "") then any = true; end
				end
				if (any) then
					entries[P.key(cur.ctx, cur.msgid)] = forms;
				end
			elseif (cur.str ~= nil and cur.str ~= "") then
				entries[P.key(cur.ctx, cur.msgid)] = cur.str;
			end
		end
		cur, field, fuzzy = {}, nil, false;
	end

	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		lineno = lineno + 1;
		line = string.gsub(line, "\r$", "");

		if (string.find(line, "^#,") and string.find(line, "fuzzy")) then
			if (cur.msgid ~= nil) then flush(); end
			fuzzy = true;
		elseif (string.find(line, "^#") or string.find(line, "^%s*$")) then
			-- comment or blank: an entry ends at its first blank line
			if (string.find(line, "^%s*$") and cur.msgid ~= nil) then
				flush();
			end
		else
			local kw, rest = string.match(line, "^(msg[%w_%[%]]+)%s+(.*)$");
			if (kw == "msgctxt") then
				if (cur.msgid ~= nil) then
					local keep = fuzzy;
					flush();
					fuzzy = keep;
				end
				cur.ctx = unquote(rest, lineno);
				field = "ctx";
			elseif (kw == "msgid") then
				if (cur.msgid ~= nil) then
					local keep = fuzzy;
					flush();
					fuzzy = keep;
				end
				cur.msgid = unquote(rest, lineno);
				field = "msgid";
			elseif (kw == "msgid_plural") then
				cur.plural = unquote(rest, lineno);
				field = "plural";
			elseif (kw == "msgstr") then
				cur.str = unquote(rest, lineno);
				field = "str";
			elseif (kw ~= nil and string.match(kw, "^msgstr%[(%d+)%]$")) then
				local k = tonumber(string.match(kw, "^msgstr%[(%d+)%]$"));
				cur.forms = cur.forms or {};
				cur.forms[k] = unquote(rest, lineno);
				field = k;
			elseif (string.find(line, '^%s*"')) then
				local more = unquote(string.match(line, '^%s*(.*)$'), lineno);
				if (field == nil) then
					error(string.format("line %d: a continued string with nothing before it", lineno), 0);
				elseif (type(field) == "number") then
					cur.forms[field] = cur.forms[field] .. more;
				else
					cur[field] = cur[field] .. more;
				end
			else
				error(string.format("line %d: cannot read %q", lineno, line), 0);
			end
		end
	end
	flush();

	local cat = {entries = entries, nplurals = 2,
		plural = function(n) return n == 1 and 0 or 1; end};

	local pf = string.match(header, "[Pp]lural%-[Ff]orms:%s*([^\n]*)");
	if (pf ~= nil) then
		local np = tonumber(string.match(pf, "nplurals%s*=%s*(%d+)"));
		local expr = string.match(pf, "plural%s*=%s*([^;]+)");
		if (np == nil or expr == nil) then
			error("Plural-Forms needs nplurals= and plural=", 0);
		end
		local fn, err = P.compile_plural(expr);
		if (fn == nil) then
			error("Plural-Forms: " .. err, 0);
		end
		cat.nplurals = np;
		cat.plural = function(n)
			local i = fn(math.floor(math.abs(tonumber(n) or 0)));
			if (i < 0 or i >= np) then
				return 0;
			end
			return i;
		end;
	end

	return cat;
end

return P;
